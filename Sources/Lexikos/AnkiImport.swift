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
        var isCloze = false
    }

    static func cards(db: OpaquePointer?) -> [Card]? {
        let types = noteTypes(db)
        guard !types.isEmpty else { return nil }
        var maps: [Int64: FieldMap] = [:]
        var out: [Card] = []
        for (mid, flds) in rows(db, "SELECT mid, flds FROM notes ORDER BY id") {
            guard let mid = Int64(mid), let type = types[mid] else { continue }
            let map = maps[mid] ?? fieldMap(type)
            maps[mid] = map
            let rawFields = flds.components(separatedBy: "\u{1F}")
            let values = rawFields.map { Importer.clean($0, expandCloze: !map.isCloze) }
            if let card = card(values, type, map) { out.append(card) }
        }
        return out
    }

    private static let uuidRegex = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
    private static let clozePattern = #"\{\{c\d+::([^:}]+)(?:::([^}]*))?\}\}"#

    private static func usable(_ v: String, allowNumeric: Bool = false) -> Bool {
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if trimmed.range(of: uuidRegex, options: .regularExpression) != nil { return false }
        if trimmed.range(of: #"^[\p{P}\p{S}\s]+$"#, options: .regularExpression) != nil { return false }
        if !allowNumeric && trimmed.range(of: #"^[\d\s.,#|/-]+$"#, options: .regularExpression) != nil { return false }
        return true
    }

    private static func uniqueOrdered(_ items: [Int]) -> [Int] {
        var seen = Set<Int>()
        return items.filter { seen.insert($0).inserted }
    }

    private static func card(_ v: [String], _ t: NoteType, _ m: FieldMap) -> Card? {
        if m.isCloze, let clozeCard = makeClozeCard(v, t, m) {
            return clozeCard
        }
        let plain = m.isCloze ? v.map { expandClozeText($0) } : v
        func val(_ i: Int, allowNumeric: Bool = false) -> String? {
            i < plain.count && usable(plain[i], allowNumeric: allowNumeric) ? plain[i] : nil
        }
        var frontIndices: [Int] = m.front.filter { val($0) != nil }
        if frontIndices.isEmpty, let fallback = plain.indices.first(where: { val($0) != nil }) {
            frontIndices = [fallback]
        }
        var front = frontIndices.compactMap { val($0) }.joined(separator: " ")
        guard !front.isEmpty else { return nil }
        let usedFront = Set(frontIndices)
        if let tagIdx = m.tag, !usedFront.contains(tagIdx), let tag = val(tagIdx) { front += " (\(tag))" }

        var answer = m.answer.filter { !usedFront.contains($0) }.compactMap { val($0, allowNumeric: true) }
        var extras = m.extras.filter { !usedFront.contains($0) && val($0) != nil }
        if answer.isEmpty, let firstExtra = extras.first, let text = val(firstExtra, allowNumeric: true) {
            answer = [text]
            extras.removeFirst()
        }
        var lines = answer
        let examples = m.examples.compactMap { ex -> String? in
            guard !usedFront.contains(ex.fr), let fr = val(ex.fr) else { return nil }
            let en = ex.en.flatMap { usedFront.contains($0) ? nil : val($0) }
            return en.map { "\(fr) (\($0))" } ?? fr
        }
        if !examples.isEmpty { lines.append("Example:"); lines += examples }
        for i in extras {
            if let x = val(i) {
                let heading = t.fields[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if heading.contains(where: \.isLetter) { lines.append("\(heading):") }
                lines.append(x)
            }
        }
        guard !lines.isEmpty else { return nil }
        let hint = m.hint.flatMap { usedFront.contains($0) ? nil : val($0) } ?? ""
        return Card(front: front, back: lines.joined(separator: "\n"), hint: hint)
    }

    private static func makeClozeCard(_ v: [String], _ t: NoteType, _ m: FieldMap) -> Card? {
        guard let regex = try? NSRegularExpression(pattern: clozePattern) else { return nil }
        let clozeIdx = m.front.first { idx in
            idx < v.count && regex.firstMatch(in: v[idx], range: NSRange(location: 0, length: (v[idx] as NSString).length)) != nil
        }
        guard let idx = clozeIdx else { return nil }
        let source = v[idx]
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var answers: [String] = []
        let masked = NSMutableString(string: source)
        for match in matches.reversed() {
            let ans = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ans.isEmpty { answers.insert(ans, at: 0) }
            let hintText = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""
            masked.replaceCharacters(in: match.range, with: hintText.isEmpty ? "[…]" : "[\(hintText)]")
        }
        let front = (masked as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !answers.isEmpty else { return nil }

        var lines: [String] = [answers.joined(separator: " · ")]
        let fullSentence = expandClozeText(source)
        if fullSentence != lines[0] && !fullSentence.isEmpty {
            lines.append("Example:")
            lines.append(fullSentence)
        }
        for extraIdx in (m.answer + m.extras) where extraIdx != idx && extraIdx < v.count {
            let text = expandClozeText(v[extraIdx])
            guard usable(text) else { continue }
            let heading = t.fields[extraIdx].trimmingCharacters(in: .whitespacesAndNewlines)
            if heading.contains(where: \.isLetter) { lines.append("\(heading):") }
            lines.append(text)
        }
        let hint = m.hint.flatMap { $0 != idx && $0 < v.count && usable(v[$0]) ? expandClozeText(v[$0]) : nil } ?? ""
        return Card(front: front, back: lines.joined(separator: "\n"), hint: hint)
    }

    private static func expandClozeText(_ text: String) -> String {
        text.replacingOccurrences(of: clozePattern, with: "$1", options: .regularExpression)
    }

    static func fieldTokens(_ name: String) -> [String] {
        let decamel = name.replacingOccurrences(of: "(?<=[a-z])(?=[A-Z])", with: " ", options: .regularExpression)
        return decamel.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    private static func matchesAny(_ name: String, tokens: Set<String>, phrases: [String]) -> Bool {
        let split = fieldTokens(name)
        if split.contains(where: { tokens.contains($0) }) { return true }
        let joined = split.joined(separator: " ")
        return phrases.contains { joined.contains($0) }
    }

    private static let skipTokens: Set<String> = [
        "audio", "sound", "image", "images", "picture", "pictures", "img", "photo", "photos",
        "rank", "freq", "frequency", "index", "id", "uid", "uuid", "guid", "link", "url",
        "order", "sort", "sl", "diagram", "svg", "stroke", "copyright", "license", "source",
        "wiktionary", "suborder", "totalorder"
    ]
    private static let skipPhrases = ["sl no", "word audio", "sentence audio", "note id", "card id"]
    private static let tagTokens: Set<String> = ["pos", "gender", "wordtype", "class", "genre", "nature", "level", "honorific"]
    private static let tagPhrases = ["part of speech", "word type"]
    private static let hintTokens: Set<String> = [
        "ipa", "phonetic", "pronunciation", "prononciation", "transcription",
        "reading", "kana", "furigana", "hiragana", "katakana", "romaji",
        "pinyin", "zhuyin", "romanization", "pitch", "accent"
    ]
    private static let sentenceTokens: Set<String> = ["sentence", "sentences", "example", "examples", "exemple", "exemples", "phrase", "context", "sample"]
    private static let sentencePhrases = ["usage example", "example sentence"]
    private static let meaningTokens: Set<String> = [
        "meaning", "meanings", "definition", "definitions", "def", "gloss",
        "english", "eng", "translation", "translations", "traduction", "sens",
        "signification", "back", "answer", "verso", "explain", "explanation",
        "chinese", "zh", "cn", "释义", "中文", "翻译", "意思", "解释"
    ]
    private static let translationTokens: Set<String> = [
        "translation", "translations", "english", "eng", "traduction",
        "meaning", "meanings", "chinese", "zh", "cn", "翻译", "中文", "释义"
    ]

    private static func templateRefs(_ tmpl: String, names: [String]) -> [Int] {
        let builtIns: Set<String> = ["frontside", "tags", "type", "deck", "subdeck", "card", "cardflag"]
        return tmpl.matches(of: #/\{\{([^}]+)\}\}/#).compactMap { m in
            let token = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = token.first, !"#/^!".contains(first) else { return nil }
            let raw = token.split(separator: ":").last.map(String.init) ?? token
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !builtIns.contains(name) else { return nil }
            return names.firstIndex(of: name)
        }
    }

    private static func skipIndices(for fields: [String]) -> Set<Int> {
        Set(fields.indices.filter { idx in
            let raw = fields[idx].lowercased().trimmingCharacters(in: .whitespaces)
            if raw == "no" || raw == "#" || raw == "s.l" { return true }
            let isSkip = matchesAny(fields[idx], tokens: skipTokens, phrases: skipPhrases)
            let isSentence = matchesAny(fields[idx], tokens: sentenceTokens, phrases: sentencePhrases)
            return isSkip && !isSentence
        })
    }

    static func fieldMap(_ t: NoteType) -> FieldMap {
        let names = t.fields.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let skip = skipIndices(for: t.fields)
        var m = FieldMap()
        m.isCloze = t.qfmt.range(of: #"\{\{[^}]*cloze:"#, options: [.regularExpression, .caseInsensitive]) != nil
        let q = templateRefs(t.qfmt, names: names).filter { !skip.contains($0) }
        if q.isEmpty {
            let firstNonSkip = t.fields.indices.first { !skip.contains($0) }
            m.front = firstNonSkip.map { [$0] } ?? (t.fields.isEmpty ? [] : [0])
        } else {
            m.front = uniqueOrdered(q)
        }

        var rest = templateRefs(t.afmt, names: names).filter { !m.front.contains($0) && !skip.contains($0) }
        if rest.isEmpty { rest = t.fields.indices.filter { !m.front.contains($0) && !skip.contains($0) } }
        rest = uniqueOrdered(rest).sorted()

        var used = Set<Int>()
        for i in rest where matchesAny(t.fields[i], tokens: tagTokens, phrases: tagPhrases) && m.tag == nil {
            m.tag = i; used.insert(i)
        }
        for i in rest where matchesAny(t.fields[i], tokens: hintTokens, phrases: [])
            && !matchesAny(t.fields[i], tokens: sentenceTokens, phrases: sentencePhrases)
            && m.hint == nil {
            m.hint = i; used.insert(i)
        }
        for i in rest where !used.contains(i)
            && matchesAny(t.fields[i], tokens: sentenceTokens, phrases: sentencePhrases)
            && !matchesAny(t.fields[i], tokens: translationTokens, phrases: []) {
            used.insert(i)
            let next = rest.first { j in
                j > i && !used.contains(j) && matchesAny(t.fields[j], tokens: translationTokens, phrases: [])
            }
            if let n = next {
                used.insert(n)
                m.examples.append((i, n))
            } else {
                m.examples.append((i, nil))
            }
        }
        let meanings = rest.filter { !used.contains($0) && matchesAny(t.fields[$0], tokens: meaningTokens, phrases: []) }
        m.answer = meanings.isEmpty ? Array(rest.filter { !used.contains($0) }.prefix(1)) : meanings
        used.formUnion(m.answer)
        m.extras = rest.filter { !used.contains($0) }
        return m
    }

    private static func pickTemplate(_ templates: [(String, String)], fields: [String]) -> (String, String) {
        guard !templates.isEmpty else { return ("", "") }
        let names = fields.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        let skip = skipIndices(for: fields)
        if let textFirst = templates.first(where: { tmpl in
            !templateRefs(tmpl.0, names: names).filter({ !skip.contains($0) }).isEmpty
        }) {
            return textFirst
        }
        return templates[0]
    }

    static func noteTypes(_ db: OpaquePointer?) -> [Int64: NoteType] {
        var out: [Int64: NoteType] = [:]
        if let json = rows(db, "SELECT models FROM col").first?.0, let data = json.data(using: .utf8),
           let models = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (id, m) in models {
                guard let numericID = Int64(id) else { continue }
                let flds = (m["flds"] as? [[String: Any]] ?? []).sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
                let fieldNames = flds.compactMap { $0["name"] as? String }
                let tmpls = (m["tmpls"] as? [[String: Any]] ?? [])
                    .sorted { ($0["ord"] as? Int ?? 0) < ($1["ord"] as? Int ?? 0) }
                    .map { ($0["qfmt"] as? String ?? "", $0["afmt"] as? String ?? "") }
                let chosen = pickTemplate(tmpls, fields: fieldNames)
                out[numericID] = NoteType(fields: fieldNames, qfmt: chosen.0, afmt: chosen.1)
            }
        }
        if out.isEmpty {
            for (ntid, _) in rows(db, "SELECT id, name FROM notetypes") {
                guard let id = Int64(ntid) else { continue }
                let fieldNames = rows(db, "SELECT name, ord FROM fields WHERE ntid = ? ORDER BY ord", int64Param: id).map(\.0)
                let chosen = pickTemplate(allTemplateFormats(db, id), fields: fieldNames)
                out[id] = NoteType(fields: fieldNames, qfmt: chosen.0, afmt: chosen.1)
            }
        }
        return out
    }

    private static func allTemplateFormats(_ db: OpaquePointer?, _ ntid: Int64) -> [(String, String)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT config FROM templates WHERE ntid = ? ORDER BY ord", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, ntid)
        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let p = sqlite3_column_blob(stmt, 0) else { continue }
            let bytes = Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: Int(sqlite3_column_bytes(stmt, 0))))
            out.append(decodeFormats(bytes))
        }
        return out
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
