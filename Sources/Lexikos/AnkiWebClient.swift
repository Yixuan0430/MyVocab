import CryptoKit
import Foundation

struct AnkiWebDeckSummary: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String
    let thumbsUp: Int, thumbsDown: Int
    let modified: Date
    let notes: Int, audio: Int, images: Int

    var ratingScore: Int { thumbsUp - thumbsDown }
    var hasAudio: Bool { audio > 0 }
    var hasImages: Bool { images > 0 }
    var pageURL: URL { URL(string: "https://ankiweb.net/shared/info/\(id)")! }
}

struct AnkiWebSampleNote: Hashable, Codable, Sendable {
    struct Field: Hashable, Codable, Sendable {
        let name: String
        let value: String
        let images: [String]
        let sounds: [String]

        init(name: String, value: String, images: [String] = [], sounds: [String] = []) {
            self.name = name
            self.value = value
            self.images = images
            self.sounds = sounds
        }
    }
    let fields: [Field]
}

struct AnkiWebDeckDetail: Identifiable, Hashable, Codable, Sendable {
    let id: Int64
    let title: String, tags: String
    let sizeBytes: Int64
    let lastUpdated: Date
    let description: String
    let notes: Int, audio: Int, images: Int
    let thumbsUp: Int, thumbsDown: Int
    let originalDeckName: String
    let sampleNotes: [AnkiWebSampleNote]
    let downloadKey: String

    var pageURL: URL { URL(string: "https://ankiweb.net/shared/info/\(id)")! }
    var hasAudio: Bool { audio > 0 }
    var hasImages: Bool { images > 0 }

    func mediaPreviewURL(for filename: String) -> URL? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("..") else {
            return nil
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let stamp = Int64(lastUpdated.timeIntervalSince1970)
        return URL(string: "https://ankiweb.net/shared/mpreview/\(id)/\(encoded)?\(stamp)")
    }
}

enum AnkiWebError: Error, Equatable {
    case invalidLink, notFound, accessDenied, rateLimited, network, http(Int), badResponse, cancelled
}

final class AnkiWebClient: @unchecked Sendable {
    struct ListResult: Sendable {
        let decks: [AnkiWebDeckSummary]
        let fromStaleCache: Bool
        let fetchedAt: Date
    }

    typealias DataFetcher = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias FileDownloader = @Sendable (URLRequest, @Sendable @escaping (Int64, Int64) -> Void) async throws -> (URL, HTTPURLResponse)

    private struct CachedList: Codable {
        let fetchedAt: Date
        let decks: [AnkiWebDeckSummary]
    }

    private struct CachedDetail {
        let fetchedAt: Date
        let detail: AnkiWebDeckDetail
    }

    static let shared = AnkiWebClient()
    private static let listTTL: TimeInterval = 86_400
    private static let detailTTL: TimeInterval = 600
    private static let maxDownloadBytes: Int64 = 512 * 1024 * 1024

    private let fetcher: DataFetcher
    private let downloader: FileDownloader
    private let cacheDir: URL?
    private let seed: AnkiCatalogSeed?
    private let lock = NSLock()
    private var memoryLists: [String: CachedList] = [:]
    private var memoryDetails: [Int64: CachedDetail] = [:]

    init(
        cacheDir: URL? = AnkiWebClient.defaultCacheDir(),
        seed: AnkiCatalogSeed? = AnkiCatalogSeed.bundled,
        fetcher: DataFetcher? = nil,
        downloader: FileDownloader? = nil
    ) {
        self.cacheDir = cacheDir
        self.seed = seed
        self.fetcher = fetcher ?? { try await Self.liveFetch($0) }
        self.downloader = downloader ?? { try await Self.liveDownload($0, onProgress: $1) }
    }

    private static func defaultCacheDir() -> URL? {
        guard !Runtime.current.isolated, !Runtime.current.readOnly else { return nil }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.yixuanwu.lexikos/ankiweb", isDirectory: true)
    }

    static func parseSharedID(_ raw: String) -> Int64? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber), let id = Int64(trimmed), id > 0 { return id }
        let normalized = trimmed.hasPrefix("/shared/") ? "https://ankiweb.net" + trimmed : trimmed
        guard let url = URL(string: normalized), let host = url.host?.lowercased(),
              host == "ankiweb.net" || host.hasSuffix(".ankiweb.net") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let infoIdx = parts.firstIndex(of: "info"), infoIdx + 1 < parts.count,
              let id = Int64(parts[infoIdx + 1]), id > 0 else { return nil }
        return id
    }

    func listDecks(query: String, forceRefresh: Bool = false, now: Date = .now) async throws -> ListResult {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cached = loadCachedList(key: normalized)
        if !forceRefresh, let cached, now.timeIntervalSince(cached.fetchedAt) < Self.listTTL {
            return ListResult(decks: cached.decks, fromStaleCache: false, fetchedAt: cached.fetchedAt)
        }
        let seeded = seed?.decks(for: normalized)
        if !forceRefresh, cached == nil, let seeded, let seedDate = seed?.fetchedAt {
            return ListResult(decks: seeded, fromStaleCache: false, fetchedAt: seedDate)
        }
        func fallback() -> ListResult? {
            if let cached { return ListResult(decks: cached.decks, fromStaleCache: true, fetchedAt: cached.fetchedAt) }
            if let seeded, let seedDate = seed?.fetchedAt {
                return ListResult(decks: seeded, fromStaleCache: true, fetchedAt: seedDate)
            }
            return nil
        }
        var components = URLComponents(string: "https://ankiweb.net/svc/shared/list-decks")!
        if !normalized.isEmpty {
            components.queryItems = [URLQueryItem(name: "search", value: normalized)]
        }
        guard let url = components.url else { throw AnkiWebError.badResponse }
        do {
            let (data, response) = try await fetcher(Self.request(url))
            if response.statusCode == 429 {
                if let fb = fallback() { return fb }
                throw AnkiWebError.rateLimited
            }
            guard (200...299).contains(response.statusCode) else { throw AnkiWebError.http(response.statusCode) }
            let decks = try Self.decodeListDecks(data)
            saveCachedList(CachedList(fetchedAt: now, decks: decks), key: normalized)
            return ListResult(decks: decks, fromStaleCache: false, fetchedAt: now)
        } catch let error as AnkiWebError {
            if error == .rateLimited, let fb = fallback() { return fb }
            throw error
        } catch is CancellationError {
            throw AnkiWebError.cancelled
        } catch {
            if let fb = fallback() { return fb }
            throw AnkiWebError.network
        }
    }

    func itemInfo(sharedID: Int64, forceRefresh: Bool = false, now: Date = .now) async throws -> AnkiWebDeckDetail {
        if !forceRefresh, let cached = loadCachedDetail(sharedID: sharedID),
           now.timeIntervalSince(cached.fetchedAt) < Self.detailTTL {
            return cached.detail
        }
        guard let url = URL(string: "https://ankiweb.net/svc/shared/item-info?sharedId=\(sharedID)") else {
            throw AnkiWebError.badResponse
        }
        do {
            let (data, response) = try await fetcher(Self.request(url))
            if response.statusCode == 429 { throw AnkiWebError.rateLimited }
            if response.statusCode == 404 { throw AnkiWebError.notFound }
            guard (200...299).contains(response.statusCode) else { throw AnkiWebError.http(response.statusCode) }
            let detail = try Self.decodeItemInfo(data, sharedID: sharedID)
            saveCachedDetail(CachedDetail(fetchedAt: now, detail: detail), sharedID: sharedID)
            return detail
        } catch let error as AnkiWebError {
            throw error
        } catch is CancellationError {
            throw AnkiWebError.cancelled
        } catch {
            throw AnkiWebError.network
        }
    }

    func downloadDeck(
        sharedID: Int64,
        initialKey: String? = nil,
        onProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        var key = initialKey ?? ""
        var refreshed = false
        if key.isEmpty {
            let detail = try await itemInfo(sharedID: sharedID, forceRefresh: true)
            key = detail.downloadKey
            refreshed = true
        }
        guard !key.isEmpty else { throw AnkiWebError.badResponse }
        do {
            return try await performDownload(sharedID: sharedID, key: key, onProgress: onProgress)
        } catch AnkiWebError.http(let code) where (code == 403 || code == 404) && !refreshed {
            let fresh = try await itemInfo(sharedID: sharedID, forceRefresh: true)
            guard !fresh.downloadKey.isEmpty else { throw AnkiWebError.badResponse }
            return try await performDownload(sharedID: sharedID, key: fresh.downloadKey, onProgress: onProgress)
        }
    }

    private func performDownload(
        sharedID: Int64,
        key: String,
        onProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> URL {
        var components = URLComponents(string: "https://ankiweb.net/svc/shared/download-deck/\(sharedID)")!
        components.queryItems = [URLQueryItem(name: "t", value: key)]
        guard let url = components.url else { throw AnkiWebError.badResponse }
        let (fileURL, response): (URL, HTTPURLResponse)
        do {
            (fileURL, response) = try await downloader(Self.request(url), onProgress)
        } catch let error as AnkiWebError {
            throw error
        } catch is CancellationError {
            throw AnkiWebError.cancelled
        } catch {
            throw AnkiWebError.network
        }
        guard (200...299).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: fileURL)
            if response.statusCode == 429 { throw AnkiWebError.rateLimited }
            throw AnkiWebError.http(response.statusCode)
        }
        guard Self.isZipFile(fileURL) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw AnkiWebError.badResponse
        }
        return fileURL
    }

    private static func isZipFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 2), header.count == 2 else { return false }
        return header[0] == 0x50 && header[1] == 0x4B
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("MyVocab", forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func liveFetch(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw AnkiWebError.badResponse }
        return (data, http)
    }

    private static func liveDownload(
        _ req: URLRequest,
        onProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> (URL, HTTPURLResponse) {
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw AnkiWebError.badResponse }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("ankiweb-\(UUID().uuidString).apkg")
        guard (200...299).contains(http.statusCode) else { return (dest, http) }
        let expected = response.expectedContentLength
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        do {
            let handle = try FileHandle(forWritingTo: dest)
            defer { try? handle.close() }
            var buffer = Data()
            buffer.reserveCapacity(65536)
            var received: Int64 = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= 65536 {
                    received += Int64(buffer.count)
                    guard received <= maxDownloadBytes else { throw AnkiWebError.badResponse }
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    onProgress(received, expected)
                }
            }
            if !buffer.isEmpty {
                received += Int64(buffer.count)
                guard received <= maxDownloadBytes else { throw AnkiWebError.badResponse }
                try handle.write(contentsOf: buffer)
                onProgress(received, expected)
            }
            return (dest, http)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    private func cacheFile(for key: String) -> URL? {
        guard let cacheDir else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("list-\(digest).json")
    }

    private func loadCachedList(key: String) -> CachedList? {
        lock.lock()
        let mem = memoryLists[key]
        lock.unlock()
        if let mem { return mem }
        guard let file = cacheFile(for: key),
              let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(CachedList.self, from: data) else { return nil }
        lock.lock()
        memoryLists[key] = decoded
        lock.unlock()
        return decoded
    }

    private func saveCachedList(_ entry: CachedList, key: String) {
        lock.lock()
        memoryLists[key] = entry
        lock.unlock()
        guard let cacheDir, let file = cacheFile(for: key) else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func loadCachedDetail(sharedID: Int64) -> CachedDetail? {
        lock.lock()
        defer { lock.unlock() }
        return memoryDetails[sharedID]
    }

    private func saveCachedDetail(_ entry: CachedDetail, sharedID: Int64) {
        lock.lock()
        memoryDetails[sharedID] = entry
        lock.unlock()
    }

    static func decodeListDecks(_ data: Data) throws -> [AnkiWebDeckSummary] {
        let fields = try ProtoWire.fields(in: data)
        var out: [AnkiWebDeckSummary] = []
        for field in fields where field.number == 1 {
            guard case .bytes(let rowData) = field.value else { continue }
            if let row = try decodeDeckRow(rowData) { out.append(row) }
        }
        return out
    }

    private static func decodeDeckRow(_ data: Data) throws -> AnkiWebDeckSummary? {
        var id: Int64 = 0
        var title = ""
        var up = 0
        var down = 0
        var mtime: Int64 = 0
        var notes = 0
        var audio = 0
        var images = 0
        for field in try ProtoWire.fields(in: data) {
            switch (field.number, field.value) {
            case (1, .varint(let v)): id = Int64(bitPattern: v)
            case (2, .bytes(let b)): title = String(data: b, encoding: .utf8) ?? ""
            case (3, .varint(let v)): up = Int(clamping: v)
            case (4, .varint(let v)): down = Int(clamping: v)
            case (5, .varint(let v)): mtime = Int64(bitPattern: v)
            case (6, .varint(let v)): notes = Int(clamping: v)
            case (7, .varint(let v)): audio = Int(clamping: v)
            case (8, .varint(let v)): images = Int(clamping: v)
            default: break
            }
        }
        guard id > 0, !title.isEmpty else { return nil }
        return AnkiWebDeckSummary(
            id: id,
            title: title,
            thumbsUp: up,
            thumbsDown: down,
            modified: Date(timeIntervalSince1970: TimeInterval(mtime)),
            notes: notes,
            audio: audio,
            images: images
        )
    }

    static func decodeItemInfo(_ data: Data, sharedID: Int64) throws -> AnkiWebDeckDetail {
        let outer = try ProtoWire.fields(in: data)
        var available: Data?
        for field in outer {
            switch (field.number, field.value) {
            case (1, .bytes(let b)): available = b
            case (2, .varint(let v)) where v != 0: throw AnkiWebError.notFound
            case (3, .varint(let v)) where v != 0: throw AnkiWebError.accessDenied
            default: break
            }
        }
        guard let inner = available else { throw AnkiWebError.badResponse }
        var title = "", tags = "", desc = "", origName = ""
        var size: Int64 = 0, updated: Int64 = 0
        var up = 0, down = 0, notes = 0, audio = 0, images = 0
        var samples: [AnkiWebSampleNote] = []
        var downloadKey = ""
        for field in try ProtoWire.fields(in: inner) {
            switch (field.number, field.value) {
            case (5, .bytes(let b)): title = String(data: b, encoding: .utf8) ?? ""
            case (6, .bytes(let b)): tags = String(data: b, encoding: .utf8) ?? ""
            case (7, .varint(let v)): size = Int64(bitPattern: v)
            case (8, .varint(let v)): updated = Int64(bitPattern: v)
            case (9, .bytes(let b)): desc = Importer.clean(String(data: b, encoding: .utf8) ?? "")
            case (18, .varint(let v)): up = Int(clamping: v)
            case (19, .varint(let v)): down = Int(clamping: v)
            case (20, .bytes(let b)): origName = String(data: b, encoding: .utf8) ?? ""
            case (10, .bytes(let deckBytes)):
                for df in try ProtoWire.fields(in: deckBytes) {
                    switch (df.number, df.value) {
                    case (1, .varint(let v)): notes = Int(clamping: v)
                    case (2, .varint(let v)): audio = Int(clamping: v)
                    case (3, .varint(let v)): images = Int(clamping: v)
                    case (4, .bytes(let noteBytes)):
                        if let sample = try decodeSampleNote(noteBytes) { samples.append(sample) }
                    case (5, .bytes(let b)): downloadKey = String(data: b, encoding: .utf8) ?? ""
                    default: break
                    }
                }
            default: break
            }
        }
        guard !title.isEmpty else { throw AnkiWebError.badResponse }
        return AnkiWebDeckDetail(
            id: sharedID,
            title: title,
            tags: tags,
            sizeBytes: size,
            lastUpdated: Date(timeIntervalSince1970: TimeInterval(updated)),
            description: desc,
            notes: notes,
            audio: audio,
            images: images,
            thumbsUp: up,
            thumbsDown: down,
            originalDeckName: origName,
            sampleNotes: samples,
            downloadKey: downloadKey
        )
    }

    private static func decodeSampleNote(_ data: Data) throws -> AnkiWebSampleNote? {
        var out: [AnkiWebSampleNote.Field] = []
        for field in try ProtoWire.fields(in: data) where field.number == 1 {
            guard case .bytes(let pairBytes) = field.value else { continue }
            var name = "", raw = ""
            for pf in try ProtoWire.fields(in: pairBytes) {
                switch (pf.number, pf.value) {
                case (1, .bytes(let b)): name = String(data: b, encoding: .utf8) ?? ""
                case (2, .bytes(let b)): raw = String(data: b, encoding: .utf8) ?? ""
                default: break
                }
            }
            let images = extractTags(in: raw, prefix: "image")
            let sounds = extractTags(in: raw, prefix: "sound")
            let stripped = raw.replacingOccurrences(of: #"\[(image|sound):[^\]]+\]"#, with: "", options: .regularExpression)
            let value = Importer.clean(stripped)
            if !value.isEmpty || !images.isEmpty || !sounds.isEmpty {
                out.append(.init(name: name, value: value, images: images, sounds: sounds))
            }
        }
        return out.isEmpty ? nil : AnkiWebSampleNote(fields: out)
    }

    private static func extractTags(in text: String, prefix: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\["# + prefix + #":([^\]]+)\]"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let val = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return val.isEmpty ? nil : val
        }
    }
}
