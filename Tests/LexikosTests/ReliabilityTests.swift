import XCTest
import CloudKit
@testable import Lexikos

final class ReliabilityTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var deck: Deck { Deck(name: "test", cards: (0..<6).map { Card(front: "f\($0)", back: "b\($0)") }) }

    func testFailedProgressWriteDoesNotAdvanceOrSync() throws {
        let dir = root.appendingPathComponent("progress")
        let store = ProgressStore(dir: dir), d = deck
        var callbacks = 0
        store.onRecord = { _ in callbacks += 1 }
        try FileManager.default.removeItem(at: dir)
        try Data().write(to: dir) // deterministic ENOTDIR, including when tests run as root
        XCTAssertFalse(store.grade(d, card: 0, .remembered))
        XCTAssertTrue(store.states(d).isEmpty)
        XCTAssertTrue(store.byID.isEmpty)
        XCTAssertEqual(callbacks, 0)
        XCTAssertNotNil(store.lastError)
        let e = ReviewEvent(deck: d.id, card: d.keys[0], date: .now, kind: .introduce)
        XCTAssertEqual(store.merge([e]), 0)
        XCTAssertNil(store.byID[e.id])
    }

    func testMergeDeduplicatesWithinSingleBatch() {
        let store = ProgressStore(dir: root.appendingPathComponent("progress")), d = deck
        let event = ReviewEvent(deck: d.id, card: d.keys[0], date: .now, kind: .grade(.remembered))
        XCTAssertEqual(store.merge([event, event, event]), 1)
        XCTAssertEqual(store.states(d)[0]?.reviews.count, 1)
        XCTAssertEqual(ProgressStore(dir: root.appendingPathComponent("progress")).events[d.id]?.count, 1)
    }

    func testDeckWriteFailureAndOfflineDeletion() throws {
        let store = DeckStore(root: root), d = deck
        XCTAssertTrue(store.upsert(d))
        XCTAssertTrue(store.delete(d))
        let restarted = DeckStore(root: root)
        XCTAssertTrue(restarted.deletedIDs.contains(d.id))
        XCTAssertTrue(restarted.upsert(d))
        XCTAssertTrue(restarted.decks.isEmpty)
        let next = deck
        try FileManager.default.removeItem(at: root.appendingPathComponent("decks"))
        try Data().write(to: root.appendingPathComponent("decks"))
        XCTAssertFalse(restarted.upsert(next))
        XCTAssertTrue(restarted.decks.isEmpty)
        XCTAssertNotNil(restarted.lastError)
    }

    func testNewQuotaAndLearningDueTime() {
        let store = ProgressStore(dir: root.appendingPathComponent("progress")), d = deck
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(store.plan(d, newPerDay: 2, groupSize: 10, now: now).groupNew.count, 2)
        store.introduce(d, card: 0, now: now)
        let waiting = store.plan(d, newPerDay: 2, groupSize: 10, now: now + 59)
        XCTAssertEqual(waiting.groupDue, [])
        XCTAssertEqual(waiting.groupNew.count, 1)
        XCTAssertEqual(store.plan(d, newPerDay: 2, now: now + 60).groupDue, [0])
        XCTAssertTrue(store.plan(d, newPerDay: 0, now: now).groupNew.isEmpty)
    }

    func testSchedulerIndependentBoundaries() {
        let now = Date(timeIntervalSince1970: 0)
        let introduced = CardState.introduce(nil, now: now)
        XCTAssertEqual(introduced.due, now + 60)
        XCTAssertEqual(introduced.lapses, 0)
        let good = CardState.next(introduced, .remembered, now: now + 60)
        XCTAssertEqual(good.stability, 3)
        XCTAssertEqual(good.due, now + 60 + 3 * 86400)
        let missed = CardState.next(good, .forgot, now: good.due)
        XCTAssertEqual(missed.step, 2)
        XCTAssertEqual(missed.lapses, 1)
        XCTAssertEqual(missed.due, good.due + 600)
        XCTAssertEqual(CardState.retention(days: 3, stability: 3), 0.9, accuracy: 0.00001)
    }

    func testMultilineCSVAndMalformedQuotes() throws {
        XCTAssertEqual(try Importer.csv("\"hello\nworld\",\"a, b\",\"say \"\"hi\"\"\"\r\nx,y,\r\n"),
                       [["hello\nworld", "a, b", "say \"hi\""], ["x", "y", ""]])
        XCTAssertThrowsError(try Importer.csv("\"unfinished,x"))
        XCTAssertThrowsError(try Importer.csv("\"a\"junk,b"))
        let file = root.appendingPathComponent("test.csv")
        try "\"hello\nworld\",bonjour\r\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Importer.text(file).first?.front, "hello\nworld")
    }

    func testCSVWhitespaceAfterClosingQuote() throws {
        XCTAssertEqual(try Importer.csv("\"bonjour\" \t,hello\n\"salut\"  \n"), [["bonjour", "hello"], ["salut"]])
        XCTAssertThrowsError(try Importer.csv("\"bonjour\" x,hello"))
    }

    func testCSVUnquotedLiteralQuotes() throws {
        XCTAssertEqual(try Importer.csv("<span class=\"x\">,5\" screen\nplain,ok"),
                       [["<span class=\"x\">", "5\" screen"], ["plain", "ok"]])
    }

    func testTemporaryDefaultsCleanupAndProductionDefaults() {
        let runtime = Runtime(arguments: ["MyVocab", "--data-dir", root.path], environment: [:])
        let domain = runtime.temporaryDefaultsDomain!
        runtime.defaults.set("value", forKey: "cleanup-probe")
        runtime.defaults.synchronize()
        XCTAssertEqual(runtime.defaults.persistentDomain(forName: domain)?["cleanup-probe"] as? String, "value")
        runtime.cleanup()
        XCTAssertNil(runtime.defaults.persistentDomain(forName: domain)?["cleanup-probe"])
        let production = Runtime(arguments: ["MyVocab"], environment: [:])
        XCTAssertTrue(production.defaults === UserDefaults.standard)
        XCTAssertNil(production.temporaryDefaultsDomain)
    }

    func testIsolationDefaults() {
        let runtime = Runtime(arguments: ["MyVocab", "--snapshot", "/tmp/out"], environment: [:])
        defer { runtime.cleanup() }
        XCTAssertTrue(runtime.isolated)
        XCTAssertFalse(runtime.syncEnabled)
        XCTAssertFalse(runtime.migrationEnabled)
        XCTAssertFalse(runtime.root.path.hasSuffix("Application Support/Lexikos"))
        let explicit = Runtime(arguments: ["MyVocab", "--data-dir", root.path], environment: [:])
        defer { explicit.cleanup() }
        XCTAssertEqual(explicit.root.path, root.path)
        XCTAssertFalse(explicit.migrationEnabled)
    }

    func testMigrationRetainsSourceAndIsIdempotent() throws {
        let old = root.appendingPathComponent("Nombres")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("progress".utf8).write(to: old.appendingPathComponent("marker"))
        let domain = root.appendingPathComponent("myvocab-test-" + UUID().uuidString).path
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        try Migration.run(support: root, defaults: defaults)
        try Migration.run(support: root, defaults: defaults)
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("marker")), Data("progress".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Lexikos/marker")), Data("progress".utf8))
        XCTAssertTrue(defaults.bool(forKey: "migratedFromLocalId"))
    }

    func testMalformedProtobufDoesNotTrap() {
        XCTAssertEqual(AnkiImport.decodeFormats([0x0a, 0x7f]).0, "")
        XCTAssertEqual(AnkiImport.decodeFormats(Array(repeating: 0xff, count: 100)).0, "")
        XCTAssertEqual(AnkiImport.decodeFormats([0x0a, 1, 65, 0x12, 1, 66]).0, "A")
        XCTAssertEqual(AnkiImport.decodeFormats([0x0a, 1, 65, 0x12, 1, 66]).1, "B")
    }

    func testCorruptLogIsPreservedOnNextGrade() throws {
        let dir = root.appendingPathComponent("progress"), d = deck
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(d.id.uuidString).jsonl")
        let data = Data("{partial".utf8)
        try data.write(to: file)
        let store = ProgressStore(dir: dir)
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.grade(d, card: 0, .remembered))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    @MainActor func testCloudDeletionMarkerWinsOverStaleDeck() throws {
        let decks = DeckStore(root: root), progress = ProgressStore(dir: root.appendingPathComponent("progress")), d = deck
        XCTAssertTrue(decks.upsert(d))
        let sync = Sync(decks: decks, progress: progress, enabled: false)
        let asset = root.appendingPathComponent("cards.json")
        try JSONEncoder().encode(d.cards).write(to: asset)
        let stale = CKRecord(recordType: "Deck", recordID: CKRecord.ID(recordName: "deck-" + d.id.uuidString))
        stale["name"] = d.name; stale["cards"] = CKAsset(fileURL: asset)
        let deletion = CKRecord(recordType: "Event", recordID: CKRecord.ID(recordName: "deleted-deck-" + d.id.uuidString))
        deletion["payload"] = try JSONEncoder().encode(DeckDeletion(deletedDeck: d.id))
        XCTAssertEqual(sync.apply([stale, deletion], deleted: []).count, 2)
        XCTAssertTrue(decks.decks.isEmpty)
        XCTAssertTrue(DeckStore(root: root).deletedIDs.contains(d.id))
    }

    @MainActor func testCloudFetchWriteFailureIsNotAcknowledged() throws {
        let decks = DeckStore(root: root), dir = root.appendingPathComponent("progress")
        let progress = ProgressStore(dir: dir), d = deck
        let sync = Sync(decks: decks, progress: progress, enabled: false)
        try FileManager.default.removeItem(at: dir)
        try Data().write(to: dir)
        let event = ReviewEvent(deck: d.id, card: d.keys[0], date: .now, kind: .grade(.remembered))
        let record = CKRecord(recordType: "Event", recordID: CKRecord.ID(recordName: "event-" + event.id.uuidString))
        record["payload"] = try JSONEncoder().encode(event)
        XCTAssertEqual(sync.apply([record], deleted: []), [])
        XCTAssertTrue(progress.byID.isEmpty)
    }

    @MainActor func testUpdateValidation() throws {
        XCTAssertTrue(Updater.validIdentity(bundleID: "com.yixuanwu.lexikos", version: "1.2.0", expected: "1.2.0", current: "1.1.0"))
        XCTAssertFalse(Updater.validIdentity(bundleID: "other", version: "1.2.0", expected: "1.2.0", current: "1.1.0"))
        XCTAssertFalse(Updater.validIdentity(bundleID: "com.yixuanwu.lexikos", version: "1.0.0", expected: "1.2.0", current: "1.1.0"))
        let url = URL(string: "https://github.com")!
        XCTAssertThrowsError(try Updater.validateHTTP(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!))
        XCTAssertNoThrow(try Updater.validateHTTP(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        XCTAssertFalse(Updater.signedByUs(root))
    }

    func testUpdateRollbackWithQuotedPaths() throws {
        let old = root.appendingPathComponent("old '$().app"), staged = root.appendingPathComponent("missing.app")
        let backup = root.appendingPathComponent("backup.app"), dest = root.appendingPathComponent("MyVocab.app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: old.appendingPathComponent("marker"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", UpdateReplacement.script, "test", "99999999", old.path, staged.path, dest.path, backup.path, root.path]
        process.environment = ["MYVOCAB_UPDATE_TEST": "1"]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("marker")), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let success = Process()
        success.executableURL = process.executableURL; success.arguments = process.arguments; success.environment = process.environment
        try success.run(); success.waitUntilExit()
        XCTAssertEqual(success.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }
}
