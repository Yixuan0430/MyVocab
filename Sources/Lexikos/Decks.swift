import Foundation
import NaturalLanguage
import SQLite3
import ZIPFoundation

struct Card: Codable, Hashable { var front: String; var back: String; var hint: String = "" }

struct Deck: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var cards: [Card]
    var language: String?

    var glyph: String { name.first(where: \.isLetter).map { String($0).uppercased() } ?? "#" }

    var inferredSpeechLanguage: String {
        if let explicit = language?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let byName = CatalogLanguage.infer(from: name) {
            return byName.speechCode
        }
        return Self.detectLanguageFromCards(cards) ?? "fr-FR"
    }

    static func detectLanguageFromCards(_ cards: [Card]) -> String? {
        let sample = cards.prefix(24).map(\.front).filter { !$0.isEmpty }
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        var votes: [NLLanguage: Int] = [:]
        for text in sample {
            recognizer.reset()
            recognizer.processString(text)
            if let dom = recognizer.dominantLanguage, dom != .undetermined {
                votes[dom, default: 0] += 1
            }
        }
        guard let top = votes.max(by: { $0.value < $1.value })?.key else { return nil }
        let map: [NLLanguage: String] = [
            .french: "fr-FR", .english: "en-US", .japanese: "ja-JP", .german: "de-DE",
            .spanish: "es-ES", .korean: "ko-KR", .simplifiedChinese: "zh-CN",
            .traditionalChinese: "zh-TW", .russian: "ru-RU", .arabic: "ar-SA", .hebrew: "he-IL"
        ]
        return map[top] ?? top.rawValue
    }
}

struct DeckDeletion: Codable { var deletedDeck: UUID }

enum ImportError: Error { case anki21b, empty, unreadable }

@Observable final class DeckStore {
    private(set) var decks: [Deck] = []
    @ObservationIgnored var onSave: ((Deck) -> Void)?
    @ObservationIgnored var onDelete: ((UUID) -> Void)?
    var storageRoot: URL { dir.deletingLastPathComponent() }
    private let dir: URL
    private let tombstoneFile: URL
    private(set) var deletedIDs: Set<UUID> = []
    var lastError: String?

    init(root: URL = Runtime.current.root) {
        dir = root.appendingPathComponent("decks", isDirectory: true)
        tombstoneFile = root.appendingPathComponent("deleted-decks.json")
        do {
            if root.path == Runtime.current.root.path && Runtime.current.migrationEnabled { try Migration.run() }
            if !Runtime.current.readOnly { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            if FileManager.default.fileExists(atPath: tombstoneFile.path) {
                deletedIDs = try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: tombstoneFile))
            }
        } catch { lastError = error.localizedDescription }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Deck] = []
        for url in files where url.pathExtension == "json" {
            do {
                let deck = try JSONDecoder().decode(Deck.self, from: Data(contentsOf: url))
                if !deletedIDs.contains(deck.id) { loaded.append(deck) }
            } catch {
                lastError = error.localizedDescription
            }
        }
        decks = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func importFile(_ url: URL, nameOverride: String? = nil, language: String? = nil) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let cards = url.pathExtension.lowercased() == "apkg" ? try Importer.anki(url) : try Importer.text(url)
        guard !cards.isEmpty else { throw ImportError.empty }
        let name = nameOverride ?? url.deletingPathExtension().lastPathComponent
        let resolvedLanguage = language ?? CatalogLanguage.infer(from: name)?.speechCode ?? Deck.detectLanguageFromCards(cards)
        let deck = Deck(name: name, cards: cards, language: resolvedLanguage)
        try JSONEncoder().encode(deck).write(to: file(deck), options: .atomic)
        decks.append(deck)
        sortDecks()
        onSave?(deck)
    }

    @MainActor func loadFile(_ url: URL, replacing id: UUID? = nil, nameOverride: String? = nil, language: String? = nil) async throws {
        let existing = id.flatMap { deck($0) }
        if id != nil && existing == nil { throw ImportError.unreadable }
        let directory = dir
        let resolvedName = existing?.name ?? nameOverride ?? url.deletingPathExtension().lastPathComponent
        let explicitLanguage = language ?? existing?.language
        let saved = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let cards = url.pathExtension.lowercased() == "apkg" ? try Importer.anki(url) : try Importer.text(url)
            guard !cards.isEmpty else { throw ImportError.empty }
            let finalLanguage = explicitLanguage
                ?? CatalogLanguage.infer(from: resolvedName)?.speechCode
                ?? Deck.detectLanguageFromCards(cards)
            let result = Deck(id: existing?.id ?? UUID(), name: resolvedName, cards: cards, language: finalLanguage)
            try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("\(result.id.uuidString).json"), options: .atomic)
            return result
        }.value
        guard !deletedIDs.contains(saved.id) else { return }
        if let index = decks.firstIndex(where: { $0.id == saved.id }) { decks[index] = saved }
        else { decks.append(saved); sortDecks() }
        onSave?(saved)
    }

    func reimport(_ id: UUID, from url: URL) throws {
        guard let i = decks.firstIndex(where: { $0.id == id }) else { throw ImportError.unreadable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let cards = url.pathExtension.lowercased() == "apkg" ? try Importer.anki(url) : try Importer.text(url)
        guard !cards.isEmpty else { throw ImportError.empty }
        var updated = decks[i]
        updated.cards = cards
        try JSONEncoder().encode(updated).write(to: file(updated), options: .atomic)
        decks[i] = updated
        onSave?(updated)
    }

    @discardableResult func delete(_ deck: Deck) -> Bool {
        guard remove(deck.id) else { return false }
        onDelete?(deck.id)
        return true
    }

    func deck(_ id: UUID) -> Deck? { decks.first { $0.id == id } }

    @discardableResult func upsert(_ deck: Deck) -> Bool {
        guard !deletedIDs.contains(deck.id) else { return true }
        do {
            var merged = deck
            if merged.language == nil, let existing = self.deck(deck.id) {
                merged.language = existing.language
            }
            try JSONEncoder().encode(merged).write(to: file(merged), options: .atomic)
            if let i = decks.firstIndex(where: { $0.id == merged.id }) { decks[i] = merged } else { decks.append(merged) }
            sortDecks()
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult func remove(_ id: UUID) -> Bool {
        do {
            var deleted = deletedIDs
            deleted.insert(id)
            try JSONEncoder().encode(deleted).write(to: tombstoneFile, options: .atomic)
            deletedIDs = deleted
            decks.removeAll { $0.id == id }
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    private func sortDecks() {
        decks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func file(_ deck: Deck) -> URL { dir.appendingPathComponent("\(deck.id.uuidString).json") }
}

private let sqliteUnicaseCompare: @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafeRawPointer?
) -> Int32 = { _, lhsLen, lhsPtr, rhsLen, rhsPtr in
    let lhs = lhsPtr.flatMap { ptr in
        String(bytes: UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: Int(lhsLen)), encoding: .utf8)
    } ?? ""
    let rhs = rhsPtr.flatMap { ptr in
        String(bytes: UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: Int(rhsLen)), encoding: .utf8)
    } ?? ""
    switch lhs.caseInsensitiveCompare(rhs) {
    case .orderedAscending:
        return -1
    case .orderedSame:
        return 0
    case .orderedDescending:
        return 1
    }
}

enum Importer {
    static func anki(_ url: URL) throws -> [Card] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let archive = try Archive(url: url, accessMode: .read)
        for name in ["collection.anki21b", "collection.anki21", "collection.anki2"] {
            if let entry = archive[name] {
                guard entry.uncompressedSize <= 256 * 1024 * 1024 else { throw ImportError.unreadable }
                _ = try archive.extract(entry, to: tmp.appendingPathComponent(name))
            }
        }

        let fm = FileManager.default
        let db: URL
        let anki21b = tmp.appendingPathComponent("collection.anki21b")
        if fm.fileExists(atPath: anki21b.path) {
            let unpacked = tmp.appendingPathComponent("collection.anki21b.sqlite")
            try ZstdDecompress.decompress(anki21b, to: unpacked)
            db = unpacked
        } else if let legacy = ["collection.anki21", "collection.anki2"]
            .map({ tmp.appendingPathComponent($0) })
            .first(where: { fm.fileExists(atPath: $0.path) }) {
            db = legacy
        } else {
            throw ImportError.unreadable
        }

        var handle: OpaquePointer?
        defer { if let handle { sqlite3_close(handle) } }
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw ImportError.unreadable }
        sqlite3_create_collation_v2(handle, "unicase", SQLITE_UTF8, nil, sqliteUnicaseCompare, nil)
        if let typed = AnkiImport.cards(db: handle), !typed.isEmpty { return typed }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT flds FROM notes ORDER BY id", -1, &stmt, nil) == SQLITE_OK else { throw ImportError.unreadable }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            rows.append(String(cString: c).components(separatedBy: "\u{1F}"))
        }
        return cards(rows)
    }

    static func text(_ url: URL) throws -> [Card] {
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { throw ImportError.unreadable }
        let raw = original.hasPrefix("\u{FEFF}") ? String(original.dropFirst()) : original
        let first = raw.split(whereSeparator: \.isNewline).first(where: { !$0.hasPrefix("#") }) ?? ""
        let sep: Character = first.contains("\t") ? "\t" : first.contains(";") ? ";" : ","
        return cards(try csv(raw, separator: sep))
    }

    static func csv(_ raw: String, separator: Character = ",") throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false
        let chars = Array(raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var i = 0
        func finishRow() {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty), !row[0].hasPrefix("#") { rows.append(row) }
            row = []; field = ""; closed = false
        }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append(c); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == separator { row.append(field); field = ""; closed = false }
            else if c == "\n" { finishRow() }
            else if c == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                if closed {
                    guard c.isWhitespace else { throw ImportError.unreadable }
                    i += 1
                    continue
                }
                field.append(c)
            }
            i += 1
        }
        guard !quoted else { throw ImportError.unreadable }
        if !field.isEmpty || !row.isEmpty || closed { finishRow() }
        return rows
    }

    private static func cards(_ rows: [[String]]) -> [Card] {
        rows.compactMap { f in
            let f = f.map { clean($0) }
            guard f.count >= 2, !f[0].isEmpty, !f[1].isEmpty else { return nil }
            return Card(front: f[0], back: f[1], hint: f.count > 2 ? f[2] : "")
        }
    }

    static func clean(_ s: String, expandCloze: Bool = true) -> String {
        var t = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<(style|script)[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<rp[^>]*>[\\s\\S]*?</rp>", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<rt[^>]*>([\\s\\S]*?)</rt>", with: "($1)", options: [.regularExpression, .caseInsensitive])
        if expandCloze {
            t = t.replacingOccurrences(of: #"\{\{c\d+::([^:}]+)(?:::[^}]*)?\}\}"#, with: "$1", options: .regularExpression)
        }
        t = flattenTableCells(t)
        t = t.replacingOccurrences(of: "</t[dh]>\\s*<t[dh][^>]*>", with: " · ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(
            of: "<br\\s*/?>|<hr[^>]*>|<div[^>]*>|</div>|</p>|</tr>|</li>|</h[1-6]>|</dt>|</dd>|</blockquote>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        t = t.replacingOccurrences(of: "<[^>]+>|\\[(?:sound|image):[^\\]]*\\]", with: "", options: [.regularExpression, .caseInsensitive])
        t = decodeHTMLEntities(t)
        return t.split(separator: "\n")
            .map { line in
                line.replacingOccurrences(of: "(?:\\s*·\\s*)+", with: " · ", options: .regularExpression)
                    .replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "^(?:·\\s*)+|(?:\\s*·)+$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func flattenTableCells(_ html: String) -> String {
        guard html.range(of: "<t[dh]\\b", options: [.regularExpression, .caseInsensitive]) != nil,
              let regex = try? NSRegularExpression(pattern: "<(t[dh])([^>]*)>([\\s\\S]*?)</\\1>", options: .caseInsensitive) else {
            return html
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }
        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            let tag = ns.substring(with: match.range(at: 1))
            let attrs = ns.substring(with: match.range(at: 2))
            let inner = ns.substring(with: match.range(at: 3))
                .replacingOccurrences(of: "<br\\s*/?>|<div[^>]*>|</div>|<p[^>]*>|</p>|\\r?\\n", with: " ", options: [.regularExpression, .caseInsensitive])
            mutable.replaceCharacters(in: match.range, with: "<\(tag)\(attrs)>\(inner)</\(tag)>")
        }
        return mutable as String
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var t = input
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&apos;", "'"), ("&#39;", "'"), ("&rsquo;", "’"), ("&lsquo;", "‘"),
            ("&ldquo;", "“"), ("&rdquo;", "”"), ("&ndash;", "–"), ("&mdash;", "—"),
            ("&hellip;", "…"), ("&amp;", "&")
        ]
        for (entity, replacement) in named {
            t = t.replacingOccurrences(of: entity, with: replacement)
        }
        guard let regex = try? NSRegularExpression(pattern: #"&#(?:x([0-9A-Fa-f]+)|(\d+));"#) else { return t }
        let ns = t as NSString
        let matches = regex.matches(in: t, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return t }
        let mutable = NSMutableString(string: t)
        for match in matches.reversed() {
            let codePoint: UInt32?
            if match.range(at: 1).location != NSNotFound {
                codePoint = UInt32(ns.substring(with: match.range(at: 1)), radix: 16)
            } else if match.range(at: 2).location != NSNotFound {
                codePoint = UInt32(ns.substring(with: match.range(at: 2)), radix: 10)
            } else {
                codePoint = nil
            }
            if let cp = codePoint, let scalar = UnicodeScalar(cp) {
                mutable.replaceCharacters(in: match.range, with: String(scalar))
            }
        }
        return mutable as String
    }
}
