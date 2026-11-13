import Foundation
import SQLite3
import ZIPFoundation

struct Card: Codable, Hashable { var front: String; var back: String; var hint: String = "" }

struct Deck: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var cards: [Card]

    /// First letter of the name, for the deck's tile ("1000 Essential…" → "E").
    var glyph: String { name.first(where: \.isLetter).map { String($0).uppercased() } ?? "#" }
}

/// Stored as an immutable payload in the existing CloudKit Event record type.
struct DeckDeletion: Codable { var deletedDeck: UUID }

enum ImportError: Error { case anki21b, empty, unreadable }

/// Imported decks, one JSON file each in Application Support.
@Observable final class DeckStore {
    private(set) var decks: [Deck] = []
    /// Called when this device adds, changes or deletes a deck (the sync engine uploads it).
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
        decks = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Deck.self, from: Data(contentsOf: $0)) }
            .filter { !deletedIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func importFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let cards = url.pathExtension.lowercased() == "apkg" ? try Importer.anki(url) : try Importer.text(url)
        guard !cards.isEmpty else { throw ImportError.empty }
        let deck = Deck(name: url.deletingPathExtension().lastPathComponent, cards: cards)
        try JSONEncoder().encode(deck).write(to: file(deck), options: .atomic)
        decks.append(deck)
        onSave?(deck)
    }

    /// Parse, encode and write on a worker; publish to the observed store only after persistence.
    @MainActor func loadFile(_ url: URL, replacing id: UUID? = nil) async throws {
        let existing = id.flatMap { deck($0) }
        if id != nil && existing == nil { throw ImportError.unreadable }
        let directory = dir
        let saved = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let cards = url.pathExtension.lowercased() == "apkg" ? try Importer.anki(url) : try Importer.text(url)
            guard !cards.isEmpty else { throw ImportError.empty }
            let result = Deck(id: existing?.id ?? UUID(), name: existing?.name ?? url.deletingPathExtension().lastPathComponent, cards: cards)
            try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("\(result.id.uuidString).json"), options: .atomic)
            return result
        }.value
        // The deck could have been deleted while parsing; a durable tombstone still wins.
        guard !deletedIDs.contains(saved.id) else { return }
        if let index = decks.firstIndex(where: { $0.id == saved.id }) { decks[index] = saved }
        else { decks.append(saved) }
        onSave?(saved)
    }

    /// Re-read a deck's source file, keeping its id so study progress stays attached.
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

    /// Applies a deck from another device.
    @discardableResult func upsert(_ deck: Deck) -> Bool {
        // Persistent delete wins over stale devices, even after a restart.
        guard !deletedIDs.contains(deck.id) else { return true }
        do {
            try JSONEncoder().encode(deck).write(to: file(deck), options: .atomic)
            if let i = decks.firstIndex(where: { $0.id == deck.id }) { decks[i] = deck } else { decks.append(deck) }
            decks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult func remove(_ id: UUID) -> Bool {
        do {
            var deleted = deletedIDs
            deleted.insert(id)
            // Tombstone is the commit point; retained JSON is harmless and recoverable.
            try JSONEncoder().encode(deleted).write(to: tombstoneFile, options: .atomic)
            deletedIDs = deleted
            decks.removeAll { $0.id == id }
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    private func file(_ deck: Deck) -> URL { dir.appendingPathComponent("\(deck.id.uuidString).json") }
}

enum Importer {
    /// Anki package: a zip holding a SQLite collection; note fields are separated by 0x1F.
    static func anki(_ url: URL) throws -> [Card] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let archive = try Archive(url: url, accessMode: .read)
        for name in ["collection.anki21", "collection.anki2", "collection.anki21b"] {
            if let entry = archive[name] {
                guard entry.uncompressedSize <= 256 * 1024 * 1024 else { throw ImportError.unreadable }
                _ = try archive.extract(entry, to: tmp.appendingPathComponent(name))
            }
        }

        let fm = FileManager.default
        let legacy = ["collection.anki21", "collection.anki2"].map { tmp.appendingPathComponent($0) }
            .first { fm.fileExists(atPath: $0.path) }
        guard let db = legacy else {
            throw fm.fileExists(atPath: tmp.appendingPathComponent("collection.anki21b").path) ? ImportError.anki21b : ImportError.unreadable
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(db.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw ImportError.unreadable }
        defer { sqlite3_close(handle) }
        if let typed = AnkiImport.cards(db: handle), !typed.isEmpty,
           typed.count > 1 || !fm.fileExists(atPath: tmp.appendingPathComponent("collection.anki21b").path) { return typed }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT flds FROM notes ORDER BY id", -1, &stmt, nil) == SQLITE_OK else { throw ImportError.unreadable }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            rows.append(String(cString: c).components(separatedBy: "\u{1F}"))
        }
        // A stub collection that only says "please update Anki" means the real data is in anki21b.
        if rows.count <= 1, fm.fileExists(atPath: tmp.appendingPathComponent("collection.anki21b").path) { throw ImportError.anki21b }
        return cards(rows)
    }

    /// Anki text export, TSV or CSV: front, back, optional hint per line; "#" lines are headers.
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
            let f = f.map(clean)
            guard f.count >= 2, !f[0].isEmpty, !f[1].isEmpty else { return nil }
            return Card(front: f[0], back: f[1], hint: f.count > 2 ? f[2] : "")
        }
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<br\\s*/?>|<div[^>]*>|</div>|</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]+>|\\[sound:[^\\]]*\\]", with: "", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&amp;": "&"] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func splitCSV(_ line: String, _ sep: Character) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        var it = Array(line).makeIterator(), pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if ch == "\"" {
                if quoted, let n = it.next() { if n == "\"" { cur.append("\"") } else { quoted = false; pending = n } }
                else { quoted.toggle() }
            } else if ch == sep && !quoted { out.append(cur); cur = "" }
            else { cur.append(ch) }
        }
        out.append(cur)
        return out
    }
}
