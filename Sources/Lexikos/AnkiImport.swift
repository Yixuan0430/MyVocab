import Foundation
import SQLite3

enum AnkiImport {
    struct NoteType { var fields: [String]; var qfmt: String; var afmt: String }

    struct FieldMap {
        var front: [Int] = []
        var answer: [Int] = []
        var tag: Int?
        var hint: Int?
        var examples: [(fr: Int, en: Int?)] = []
        var extras: [Int] = []
    }

    static func cards(db: OpaquePointer?) -> [Card]? {
        let types = noteTypes(db)
        guard !types.isEmpty else { return nil }
        var maps: [Int64: FieldMap] = [:]
        var out: [Card] = []
        for (mid, flds) in rows(db, "SELECT mid, flds FROM notes ORDER BY id") {
            guard let mid = Int64(mid), let type = types[mid] else { continue }
            let values = flds.components(separatedBy: "\u{1F}").map(Importer.clean)
            let map = maps[mid] ?? fieldMap(type)
            maps[mid] = map
            if let card = card(values, type, map) { out.append(card) }
        }
        return out
    }

    private static func usable(_ v: String) -> Bool {
        !v.isEmpty && v.range(of: #"^[\d\s.,#-]+$"#, options: .regularExpression) == nil
    }

    private static func uniqueOrdered(_ items: [Int]) -> [Int] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0).inserted }
    }

    private static func card(_ v: [String], _ t: NoteType, _ m: FieldMap) -> Card? {
        func val(_ i: Int) -> String? { i < v.count && usable(v[i]) ? v[i] : nil }
        var front = m.front.compactMap(val).joined(separator: " ")
        if front.isEmpty { front = v.first(where: usable) ?? "" }
        guard !front.isEmpty else { return nil }
        if let tag = m.tag.flatMap(val) { front += " (\(tag))" }

        var lines: [String] = []
        let answer = m.answer.compactMap(val)
        lines.append(answer.first ?? "")
        lines += answer.dropFirst()
        let examples = m.examples.compactMap { ex -> String? in
            guard let fr = val(ex.fr) else { return nil }
            return ex.en.flatMap(val).map { "\(fr) (\($0))" } ?? fr
        }
        if !examples.isEmpty { lines.append("Example:"); lines += examples }
        for i in m.extras { if let x = val(i) { lines.append("\(t.fields[i]):"); lines.append(x) } }
        if lines[0].isEmpty { lines.removeFirst() }
        guard !lines.isEmpty else { return nil }
        return Card(front: front, back: lines.joined(separator: "\n"), hint: m.hint.flatMap(val) ?? "")
    }

    private static func has(_ name: String, _ words: [String]) -> Bool { words.contains { name.contains($0) } }
    private static let skipWords = ["audio", "sound", "image", "picture", "img", "photo", "rank", "freq", "index", "s.l", "sl no", "id"]
    private static let tagWords = ["part of speech", "pos", "gender", "word type", "wordtype", "class", "genre", "nature"]
    private static let hintWords = ["ipa", "phonetic", "pronunciation", "prononciation", "transcription"]
    private static let sentenceWords = ["sentence", "example", "exemple", "phrase", "usage example", "context"]
    private static let meaningWords = [
        "meaning", "definition", "english", "translation", "traduction", "sens", "signification",
        "back", "answer", "verso", "释义", "中文", "翻译", "意思"
    ]

    static func fieldMap(_ t: NoteType) -> FieldMap {
        let names = t.fields.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func refs(_ tmpl: String) -> [Int] {
            tmpl.matches(of: #/\{\{([^}]+)\}\}/#).compactMap { m in
                let raw = String(m.1).split(separator: ":").last.map(String.init) ?? ""
                let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#/^ ")).lowercased()
                return names.firstIndex(of: name)
            }
        }
        let skip = Set(names.indices.filter {
            names[$0] == "no" || names[$0] == "#" || has(names[$0], skipWords) && !has(names[$0], sentenceWords)
        })
        var m = FieldMap()
        let q = refs(t.qfmt).filter { !skip.contains($0) }
        m.front = q.isEmpty ? (t.fields.isEmpty ? [] : [0]) : uniqueOrdered(q)

        var rest = refs(t.afmt).filter { !m.front.contains($0) && !skip.contains($0) }
        if rest.isEmpty { rest = names.indices.filter { !m.front.contains($0) && !skip.contains($0) } }
        rest = uniqueOrdered(rest).sorted()

        var used = Set<Int>()
        for i in rest where has(names[i], tagWords) && m.tag == nil { m.tag = i; used.insert(i) }
        for i in rest where has(names[i], hintWords) && m.hint == nil { m.hint = i; used.insert(i) }
        for i in rest where !used.contains(i) && has(names[i], sentenceWords) {
            used.insert(i)
            let next = rest.first {
                $0 > i && !used.contains($0) && has(names[$0], ["translation", "english", "traduction", "meaning"])
            }
            if let n = next, !has(names[n], sentenceWords) || has(names[n], ["translation", "english"]) {
                used.insert(n)
                m.examples.append((i, n))
            } else {
                m.examples.append((i, nil))
            }
        }
        let meanings = rest.filter { !used.contains($0) && has(names[$0], meaningWords) }
        m.answer = meanings.isEmpty ? Array(rest.filter { !used.contains($0) }.prefix(1)) : meanings
        used.formUnion(m.answer)
        m.extras = rest.filter { !used.contains($0) }
        return m
    }

    static func noteTypes(_ db: OpaquePointer?) -> [Int64: NoteType] {
        var out: [Int64: NoteType] = [:]
        if let json = rows(db, "SELECT models FROM col").first?.0, let data = json.data(using: .utf8),
           let models = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (id, m) in models {
                guard let numericID = Int64(id) else { continue }
                let flds = (m["flds"] as? [[String: Any]] ?? []).sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
                let tmpl = (m["tmpls"] as? [[String: Any]])?.first
                out[numericID] = NoteType(fields: flds.compactMap { $0["name"] as? String },
                                          qfmt: tmpl?["qfmt"] as? String ?? "",
                                          afmt: tmpl?["afmt"] as? String ?? "")
            }
        }
        if out.isEmpty {
            for (ntid, _) in rows(db, "SELECT id, name FROM notetypes") {
                guard let id = Int64(ntid) else { continue }
                let fields = rows(db, "SELECT name, ord FROM fields WHERE ntid = ? ORDER BY ord", int64Param: id).map(\.0)
                let (q, a) = templateFormats(db, id)
                out[id] = NoteType(fields: fields, qfmt: q, afmt: a)
            }
        }
        return out
    }

    private static func templateFormats(_ db: OpaquePointer?, _ ntid: Int64) -> (String, String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT config FROM templates WHERE ntid = ? ORDER BY ord LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return ("", "")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, ntid)
        guard sqlite3_step(stmt) == SQLITE_ROW, let p = sqlite3_column_blob(stmt, 0) else { return ("", "") }
        let bytes = Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: Int(sqlite3_column_bytes(stmt, 0))))
        return decodeFormats(bytes)
    }

    static func decodeFormats(_ bytes: [UInt8]) -> (String, String) {
        var i = 0, strings: [Int: String] = [:]
        func varint() -> Int? {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard i < bytes.count else { return nil }
                let byte = bytes[i]; i += 1
                guard shift < 63 || byte <= 1 else { return nil }
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return Int(exactly: result) }
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint(), key > 0 else { return ("", "") }
            let field = key >> 3
            switch key & 7 {
            case 0: guard varint() != nil else { return ("", "") }
            case 2:
                guard let n = varint(), n >= 0, n <= bytes.count - i else { return ("", "") }
                guard let text = String(bytes: bytes[i..<i + n], encoding: .utf8) else { return ("", "") }
                strings[field] = text
                i += n
            case 1: guard bytes.count - i >= 8 else { return ("", "") }; i += 8
            case 5: guard bytes.count - i >= 4 else { return ("", "") }; i += 4
            default: return ("", "")
            }
        }
        return (strings[1] ?? "", strings[2] ?? "")
    }

    private static func rows(_ db: OpaquePointer?, _ sql: String, int64Param: Int64? = nil) -> [(String, String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let param = int64Param { sqlite3_bind_int64(stmt, 1, param) }
        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let a = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let b = sqlite3_column_count(stmt) > 1 ? sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "" : ""
            out.append((a, b))
        }
        return out
    }
}
