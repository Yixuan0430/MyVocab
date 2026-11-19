import XCTest
@testable import Lexikos

final class RealDataTests: XCTestCase {
    private func copyRoot() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LEXIKOS_DATA"] else { throw XCTSkip("LEXIKOS_DATA not set") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let live = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lexikos").resolvingSymlinksInPath()
        guard root.path != live.path, !root.path.hasPrefix(live.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
        return root
    }

    func testRealLogsReplayAndRestartLosslessly() throws {
        let root = try copyRoot(), dir = root.appendingPathComponent("progress")
        let decks = DeckStore(root: root)
        XCTAssertNil(decks.lastError)
        let first = ProgressStore(dir: dir), second = ProgressStore(dir: dir)
        XCTAssertNil(first.lastError)
        XCTAssertNil(second.lastError)
        for deck in decks.decks {
            let log = dir.appendingPathComponent("\(deck.id.uuidString).jsonl")
            let raw = try Data(contentsOf: log)
            let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
            let events = try text.split(separator: "\n").map {
                try JSONDecoder().decode(ReviewEvent.self, from: Data($0.utf8))
            }
            XCTAssertEqual(Set(first.events[deck.id, default: []].map(\.id)), Set(events.map(\.id)))
            let replay = ReviewEvent.replay(events)
            var expected: [Int: CardState] = [:]
            for (index, key) in deck.keys.enumerated() { expected[index] = replay[key] }
            XCTAssertEqual(first.states(deck), expected)
            XCTAssertEqual(second.states(deck), expected)
            XCTAssertEqual(try Data(contentsOf: log), raw)
            print("real log:", deck.cards.count, "cards;", expected.count, "states;", events.count, "events")
        }
    }

    func testRealSnapshotsMigrateLosslessly() throws {
        let source = try copyRoot(), fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("myvocab-legacy-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: source.appendingPathComponent("decks"), to: root.appendingPathComponent("decks"))
        let progressDir = root.appendingPathComponent("progress")
        try fm.createDirectory(at: progressDir, withIntermediateDirectories: true)
        let decks = DeckStore(root: root).decks
        var before: [UUID: [Int: CardState]] = [:]
        for d in decks {
            let filename = "\(d.id.uuidString).json"
            let current = source.appendingPathComponent("progress/" + filename)
            let old = fm.fileExists(atPath: current.path) ? current : current.appendingPathExtension("legacy")
            let data = try Data(contentsOf: old)
            before[d.id] = try JSONDecoder().decode([Int: CardState].self, from: data).filter { d.cards.indices.contains($0.key) }
            try data.write(to: progressDir.appendingPathComponent(filename))
        }
        let store = ProgressStore(dir: progressDir)
        XCTAssertNil(store.lastError)
        for d in decks { XCTAssertEqual(store.states(d), before[d.id]); print("real legacy:", before[d.id]!.count, "states") }
        let restart = ProgressStore(dir: progressDir)
        for d in decks { XCTAssertEqual(restart.states(d), before[d.id]) }
    }
}
