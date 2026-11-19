import Foundation
import CryptoKit

enum Grade: Int, Codable, CaseIterable { case forgot = 1, vague, remembered }

struct Review: Codable, Hashable { var date: Date; var grade: Grade; var stability: Double }

struct CardState: Codable, Hashable {
    var stability: Double
    var due: Date
    var lapses = 0
    var reviews: [Review] = []
    var ease: Double = 2.5
    var step: Int = 0

    static let proficientDays = 21.0
    static let step1Seconds: TimeInterval = 60
    static let step2Seconds: TimeInterval = 600

    var lastReview: Date {
        if let last = reviews.last?.date { return last }
        if step > 0 { return due.addingTimeInterval(-Self.step1Seconds) }
        return due
    }
    var isLearning: Bool { step > 0 || stability < 1.0 }
    var isProficient: Bool { step == 0 && stability >= Self.proficientDays }

    init(stability: Double, due: Date, lapses: Int = 0, reviews: [Review] = [], ease: Double = 2.5, step: Int = 0) {
        self.stability = stability
        self.due = due
        self.lapses = lapses
        self.reviews = reviews
        self.ease = ease
        self.step = step
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stability = try c.decode(Double.self, forKey: .stability)
        due = try c.decode(Date.self, forKey: .due)
        lapses = (try? c.decode(Int.self, forKey: .lapses)) ?? 0
        reviews = (try? c.decode([Review].self, forKey: .reviews)) ?? []
        ease = (try? c.decode(Double.self, forKey: .ease)) ?? 2.5
        if let decodedStep = try? c.decode(Int.self, forKey: .step) {
            step = decodedStep
        } else if reviews.count <= 1 && reviews.first?.grade == .forgot {
            step = 1
        } else if reviews.last?.grade == .forgot {
            step = 2
        } else {
            step = 0
            if stability < 1.0, let last = reviews.last {
                stability = 1.0
                due = last.date.addingTimeInterval(86400)
            }
        }
    }

    func retention(at date: Date) -> Double {
        let effStability = max(0.3, stability)
        return Self.retention(days: max(0, date.timeIntervalSince(lastReview) / 86400), stability: effStability)
    }

    static func retention(days: Double, stability: Double) -> Double {
        1 / (1 + days / (9 * max(0.1, stability)))
    }

    static func introduce(_ s: CardState?, now: Date = .now) -> CardState {
        if let s { return s }
        return CardState(stability: 0.4, due: now.addingTimeInterval(step1Seconds), lapses: 0, reviews: [], ease: 2.5, step: 1)
    }

    static func next(_ s: CardState?, _ g: Grade, now: Date = .now) -> CardState {
        let priorReviews = s?.reviews ?? []
        var lapses = s?.lapses ?? 0
        var ease = s?.ease ?? 2.5

        if s == nil || (s?.step ?? 0) > 0 {
            let priorS = s?.stability ?? 0.4
            let wasGraduatedReview = priorS >= 1.0 && priorReviews.contains(where: { $0.stability >= 1.0 })
            let hadMissInStep = (s?.step ?? 1) >= 2

            switch g {
            case .forgot:
                let wait = wasGraduatedReview ? step2Seconds : step1Seconds
                let curveS = wasGraduatedReview ? max(0.5, priorS * 0.25) : 0.3
                var out = CardState(stability: priorS, due: now.addingTimeInterval(wait),
                                    lapses: lapses, reviews: priorReviews, ease: ease, step: 2)
                out.reviews.append(Review(date: now, grade: .forgot, stability: curveS))
                return out

            case .vague:
                let st = 1.0
                var out = CardState(stability: st, due: now.addingTimeInterval(st * 86400),
                                    lapses: lapses, reviews: priorReviews, ease: ease, step: 0)
                out.reviews.append(Review(date: now, grade: .vague, stability: st))
                return out

            case .remembered:
                let st: Double
                if wasGraduatedReview {
                    st = max(1.0, (priorS * 0.25).rounded())
                } else if hadMissInStep {
                    st = 1.0
                } else {
                    st = 3.0
                }
                var out = CardState(stability: st, due: now.addingTimeInterval(st * 86400),
                                    lapses: lapses, reviews: priorReviews, ease: ease, step: 0)
                out.reviews.append(Review(date: now, grade: .remembered, stability: st))
                return out
            }
        }

        let cur = s!
        let r = cur.retention(at: now)
        let elapsed = max(0, now.timeIntervalSince(cur.lastReview) / 86400)

        switch g {
        case .forgot:
            lapses += 1
            ease = max(1.3, ease - 0.20)
            let curveS = max(0.3, cur.stability * 0.25)
            var out = CardState(stability: max(1.0, cur.stability), due: now.addingTimeInterval(step2Seconds),
                                lapses: lapses, reviews: priorReviews, ease: ease, step: 2)
            out.reviews.append(Review(date: now, grade: .forgot, stability: curveS))
            return out

        case .vague:
            ease = max(1.3, ease - 0.15)
            let st: Double = cur.stability < 1.0
                ? 1.0
                : min(3650, max(cur.stability + 1.0, cur.stability * (1.2 + 0.3 * (1 - r))))
            var out = CardState(stability: st, due: now.addingTimeInterval(st * 86400),
                                lapses: lapses, reviews: priorReviews, ease: ease, step: 0)
            out.reviews.append(Review(date: now, grade: .vague, stability: st))
            return out

        case .remembered:
            let st: Double
            if cur.stability < 1.0 {
                st = cur.lapses > 0 ? 1.5 : 3.0
            } else {
                let effectiveS = cur.stability + max(0, elapsed - cur.stability) * 0.5
                let factor = ease + max(0, (0.9 - r) * 1.5)
                st = min(3650, max(cur.stability < 2.0 ? 3.0 : cur.stability + 1.0, effectiveS * factor))
            }
            var out = CardState(stability: st, due: now.addingTimeInterval(st * 86400),
                                lapses: lapses, reviews: priorReviews, ease: ease, step: 0)
            out.reviews.append(Review(date: now, grade: .remembered, stability: st))
            return out
        }
    }
}

struct ReviewEvent: Codable, Hashable, Identifiable {
    enum Kind: Codable, Hashable {
        case introduce
        case grade(Grade)
        case reset
        case seed(CardState)
    }
    var id = UUID()
    var deck: UUID
    var card: String
    var date: Date
    var kind: Kind

    static func < (a: Self, b: Self) -> Bool { (a.date, a.id.uuidString) < (b.date, b.id.uuidString) }

    static func replay(_ events: [ReviewEvent], onto start: [String: CardState] = [:]) -> [String: CardState] {
        var out = start
        for e in events.sorted(by: <) {
            switch e.kind {
            case .introduce: out[e.card] = CardState.introduce(out[e.card], now: e.date)
            case .grade(let g): out[e.card] = CardState.next(out[e.card], g, now: e.date)
            case .reset: out = [:]
            case .seed(let s): out[e.card] = s
            }
        }
        return out
    }
}

extension Card {
    var key: String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in (front + "\u{1F}" + back).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 36)
    }
}

extension Deck {
    var keys: [String] {
        var seen: [String: Int] = [:]
        return cards.map { c in
            let k = c.key, n = seen[k, default: 0] + 1
            seen[k] = n
            return n == 1 ? k : "\(k)#\(n)"
        }
    }
}

@Observable final class ProgressStore {
    private(set) var events: [UUID: [ReviewEvent]] = [:]
    private var replayed: [UUID: [String: CardState]] = [:]
    @ObservationIgnored private(set) var byID: [UUID: ReviewEvent] = [:]
    @ObservationIgnored var onRecord: ((ReviewEvent) -> Void)?
    var storageRoot: URL { dir.deletingLastPathComponent() }
    private let dir: URL

    var lastError: String?
    private var blockedDecks: Set<UUID> = []

    init(dir: URL = Runtime.current.root.appendingPathComponent("progress")) {
        self.dir = dir
        do {
            if dir.path == Runtime.current.root.appendingPathComponent("progress").path && Runtime.current.migrationEnabled {
                try Migration.run()
            }
            if !Runtime.current.readOnly {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Self.migrateSnapshots(in: dir)
            }
        } catch { lastError = error.localizedDescription }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        for f in files where f.pathExtension == "jsonl" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { continue }
            guard let text = try? String(contentsOf: f, encoding: .utf8) else {
                blockedDecks.insert(id)
                lastError = "无法读取进度：" + f.lastPathComponent
                continue
            }
            var loaded: [ReviewEvent] = []
            var seen: Set<UUID> = []
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                do {
                    let e = try decoder.decode(ReviewEvent.self, from: Data(line.utf8))
                    guard e.deck == id else { throw CocoaError(.fileReadCorruptFile) }
                    if seen.insert(e.id).inserted { loaded.append(e) }
                } catch {
                    blockedDecks.insert(id)
                    lastError = "进度日志损坏，已保留原文件并停止写入：" + f.lastPathComponent
                }
            }
            events[id] = loaded
            replayed[id] = ReviewEvent.replay(loaded)
            for e in loaded { byID[e.id] = e }
        }
        if Runtime.current.readOnly {
            let decksDir = dir.deletingLastPathComponent().appendingPathComponent("decks")
            for f in files where f.pathExtension == "json" {
                guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent), events[id] == nil else { continue }
                do {
                    let old = try decoder.decode([Int: CardState].self, from: Data(contentsOf: f))
                    let deck = try decoder.decode(Deck.self, from: Data(contentsOf: decksDir.appendingPathComponent(f.lastPathComponent)))
                    let keys = deck.keys
                    let seeds = old.filter { keys.indices.contains($0.key) }.map { i, state in
                        ReviewEvent(id: Self.seedID(deck: id, card: keys[i], state), deck: id, card: keys[i], date: state.lastReview, kind: .seed(state))
                    }
                    events[id] = seeds
                    replayed[id] = ReviewEvent.replay(seeds)
                    for e in seeds { byID[e.id] = e }
                } catch { lastError = error.localizedDescription }
            }
        }
    }

    func states(_ deck: Deck) -> [Int: CardState] {
        guard let raw = replayed[deck.id] else { return [:] }
        var out: [Int: CardState] = [:]
        for (i, k) in deck.keys.enumerated() { if let s = raw[k] { out[i] = s } }
        return out
    }

    @discardableResult func introduce(_ deck: Deck, card: Int, now: Date = .now) -> Bool {
        guard deck.cards.indices.contains(card) else { return false }
        return record(ReviewEvent(deck: deck.id, card: deck.keys[card], date: now, kind: .introduce))
    }

    @discardableResult func grade(_ deck: Deck, card: Int, _ g: Grade, now: Date = .now) -> Bool {
        guard deck.cards.indices.contains(card) else { return false }
        return record(ReviewEvent(deck: deck.id, card: deck.keys[card], date: now, kind: .grade(g)))
    }

    @discardableResult func forget(_ deck: Deck, now: Date = .now) -> Bool {
        record(ReviewEvent(deck: deck.id, card: "", date: now, kind: .reset))
    }

    @discardableResult func merge(_ incoming: [ReviewEvent]) -> Int {
        var added = 0
        for (deck, batch) in Dictionary(grouping: incoming, by: \.deck) {
            var known = Set(byID.keys)
            let fresh = batch.filter { known.insert($0.id).inserted }
            guard !fresh.isEmpty else { continue }
            guard persist(fresh, deck: deck) else { continue }
            events[deck, default: []] += fresh
            for e in fresh { byID[e.id] = e }
            replayed[deck] = ReviewEvent.replay(events[deck] ?? [])
            added += fresh.count
        }
        return added
    }

    private func record(_ e: ReviewEvent) -> Bool {
        guard persist([e], deck: e.deck) else { return false }
        events[e.deck, default: []].append(e)
        byID[e.id] = e
        if let last = events[e.deck]?.dropLast().max(by: <), !(last < e) {
            replayed[e.deck] = ReviewEvent.replay(events[e.deck] ?? [])
        } else {
            replayed[e.deck] = ReviewEvent.replay([e], onto: replayed[e.deck] ?? [:])
        }
        onRecord?(e)
        return true
    }

    private static func encodeJSONLines(_ items: [ReviewEvent]) throws -> Data {
        let encoder = JSONEncoder()
        var data = Data()
        for item in items {
            data.append(try encoder.encode(item))
            data.append(0x0A)
        }
        return data
    }

    private func persist(_ batch: [ReviewEvent], deck: UUID) -> Bool {
        guard !Runtime.current.readOnly, !blockedDecks.contains(deck) else { return false }
        do {
            let url = dir.appendingPathComponent("\(deck.uuidString).jsonl")
            let data = try Self.encodeJSONLines(events[deck, default: []] + batch)
            try data.write(to: url, options: .atomic)
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    static func migrateSnapshots(in dir: URL) throws {
        let fm = FileManager.default
        let decksDir = dir.deletingLastPathComponent().appendingPathComponent("decks")
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        for f in files where f.pathExtension == "json" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { continue }
            let log = dir.appendingPathComponent("\(id.uuidString).jsonl")
            guard !fm.fileExists(atPath: log.path),
                  let old = try? decoder.decode([Int: CardState].self, from: Data(contentsOf: f)),
                  let deck = try? decoder.decode(Deck.self, from: Data(contentsOf: decksDir.appendingPathComponent(f.lastPathComponent)))
            else { continue }
            let keys = deck.keys
            let seeds = old.sorted { $0.key < $1.key }.filter { keys.indices.contains($0.key) }.map { i, s in
                ReviewEvent(id: seedID(deck: id, card: keys[i], s), deck: id, card: keys[i], date: s.lastReview, kind: .seed(s))
            }
            let data = try encodeJSONLines(seeds)
            try data.write(to: log, options: .atomic)
            try fm.moveItem(at: f, to: f.appendingPathExtension("legacy"))
        }
    }

    static func seedID(deck: UUID, card: String, _ s: CardState) -> UUID {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var bytes = Array(SHA256.hash(data: Data("\(deck.uuidString)|\(card)|".utf8) + ((try? enc.encode(s)) ?? Data())).prefix(16))
        bytes[6] = bytes[6] & 0x0F | 0x50
        bytes[8] = bytes[8] & 0x3F | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    struct Plan {
        var due: [Int]
        var new: [Int]
        var groupDue: [Int]
        var groupNew: [Int]
        var unseenCount: Int
        var learnedToday: Int

        var groupQueue: [Int] { groupDue + groupNew }
    }

    func plan(_ deck: Deck, newPerDay: Int, groupSize: Int = 10, now: Date = .now) -> Plan {
        let s = states(deck), cal = Calendar.current
        let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let due = s.filter { $0.value.step > 0 ? $0.value.due <= now : $0.value.due < endOfDay }
            .sorted { a, b in
                let aLearn = a.value.step > 0, bLearn = b.value.step > 0
                if aLearn != bLearn { return aLearn }
                return a.value.due < b.value.due
            }
            .map(\.key)

        let introducedToday = s.values.filter {
            if let first = $0.reviews.first { return cal.isDate(first.date, inSameDayAs: now) }
            return $0.step > 0 && cal.isDate($0.lastReview, inSameDayAs: now)
        }.count

        let allUnseen = deck.cards.indices.filter { s[$0] == nil }
        let freshDaily = allUnseen.prefix(max(0, newPerDay - introducedToday))

        let size = max(1, groupSize)
        let groupDue = Array(due.prefix(size))
        let groupNew = Array(freshDaily.prefix(max(0, size - groupDue.count)))

        let learnedToday = s.values.filter {
            $0.reviews.contains { cal.isDate($0.date, inSameDayAs: now) }
        }.count

        return Plan(due: due,
                    new: Array(freshDaily),
                    groupDue: groupDue,
                    groupNew: groupNew,
                    unseenCount: allUnseen.count,
                    learnedToday: learnedToday)
    }
}
