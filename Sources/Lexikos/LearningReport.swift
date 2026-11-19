import Foundation

enum LearningReport {
    static func write(decks: DeckStore, progress: ProgressStore, now: Date = .now) throws {
        let args = CommandLine.arguments
        let index = args.firstIndex(of: "--days")
        let days = max(1, min(365, index.flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 7))
        let since = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        let recent = progress.byID.values.filter { $0.date >= since && $0.date <= now }.sorted { $1 < $0 }
        let today = Calendar.current.startOfDay(for: now)
        let liveRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lexikos")
        let defaults = Runtime.current.root.resolvingSymlinksInPath() == liveRoot.resolvingSymlinksInPath()
            ? UserDefaults.standard : Runtime.current.defaults
        let rows: [[String: Any]] = decks.decks.map { deck in
            let plan = progress.plan(deck, newPerDay: defaults.object(forKey: "newPerDay") as? Int ?? 20, now: now)
            return [
                "id": deck.id.uuidString,
                "name": deck.name,
                "cards": deck.cards.count,
                "due": plan.due.count,
                "new": plan.new.count,
                "learnedToday": plan.learnedToday
            ]
        }
        let formatter = ISO8601DateFormatter()
        let events: [[String: Any]] = recent.prefix(1000).map { e in
            let kind: String
            switch e.kind {
            case .introduce:
                kind = "introduce"
            case .grade:
                kind = "grade"
            case .reset:
                kind = "reset"
            case .seed:
                kind = "seed"
            }
            var row: [String: Any] = [
                "id": e.id.uuidString,
                "deck": e.deck.uuidString,
                "card": e.card,
                "date": formatter.string(from: e.date),
                "kind": kind
            ]
            if case .grade(let g) = e.kind { row["grade"] = g.rawValue }
            return row
        }
        let grades = recent.filter {
            if case .grade = $0.kind { return true }
            return false
        }
        let report: [String: Any] = [
            "schemaVersion": 1,
            "days": days,
            "readOnly": true,
            "generatedAt": formatter.string(from: now),
            "decks": rows,
            "events": events,
            "reviewCount": grades.count,
            "todayReviewCount": grades.filter { $0.date >= today }.count,
            "eventsTruncated": recent.count > 1000,
            "diagnostics": [decks.lastError, progress.lastError].compactMap { $0 }
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
