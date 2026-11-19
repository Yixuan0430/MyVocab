import XCTest
import ZIPFoundation
import SQLite3
@testable import Lexikos

final class ImportTests: XCTestCase {
    func testCleanStripsMarkup() {
        XCTAssertEqual(Importer.clean("un<br>deux&nbsp;[sound:x.mp3]"), "un\ndeux")
    }

    func testAnki21bZstdWithUnicaseCollationImportsCards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let modernDB = root.appendingPathComponent("modern.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(modernDB.path, &db), SQLITE_OK)
        let testCompare: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafeRawPointer?) -> Int32 = { _, _, _, _, _ in 0 }
        XCTAssertEqual(sqlite3_create_collation_v2(db, "unicase", SQLITE_UTF8, nil, testCompare, nil), SQLITE_OK)
        let schema = """
        CREATE TABLE col (models TEXT);
        CREATE TABLE notetypes (id INTEGER PRIMARY KEY, name TEXT COLLATE unicase UNIQUE);
        CREATE TABLE fields (ntid INTEGER, name TEXT COLLATE unicase, ord INTEGER);
        CREATE TABLE templates (ntid INTEGER, ord INTEGER, config BLOB);
        CREATE TABLE notes (id INTEGER PRIMARY KEY, mid INTEGER, flds TEXT);
        CREATE INDEX idx_nt_name ON notetypes(name COLLATE unicase);
        INSERT INTO col VALUES ('{}');
        INSERT INTO notetypes VALUES (100, 'FrenchBasic');
        INSERT INTO fields VALUES (100, 'French', 0), (100, 'English', 1);
        INSERT INTO templates VALUES (100, 0, X'0A0A7B7B4672656E63687D7D120B7B7B456E676C6973687D7D');
        INSERT INTO notes VALUES (1, 100, 'salut\u{1f}hi'), (2, 100, 'merci\u{1f}thanks');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let compressed = try ZstdDecompress.compress(Data(contentsOf: modernDB))
        XCTAssertTrue(ZstdDecompress.isZstd(compressed))
        try compressed.write(to: root.appendingPathComponent("collection.anki21b"))

        let stubDB = root.appendingPathComponent("collection.anki2")
        var stub: OpaquePointer?
        XCTAssertEqual(sqlite3_open(stubDB.path, &stub), SQLITE_OK)
        let stubSQL = """
        CREATE TABLE col (models TEXT);
        CREATE TABLE notes (id INTEGER, mid INTEGER, flds TEXT);
        INSERT INTO col VALUES ('{}');
        INSERT INTO notes VALUES (1, 1, 'Please update\u{1f}Old Anki');
        """
        XCTAssertEqual(sqlite3_exec(stub, stubSQL, nil, nil, nil), SQLITE_OK)
        sqlite3_close(stub)

        let file = root.appendingPathComponent("modern.apkg")
        let archive = try Archive(url: file, accessMode: .create)
        try archive.addEntry(with: "collection.anki21b", relativeTo: root)
        try archive.addEntry(with: "collection.anki2", relativeTo: root)

        let cards = try Importer.anki(file)
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards[0].front, "salut")
        XCTAssertEqual(cards[0].back, "hi")
        XCTAssertEqual(cards[1].front, "merci")
        XCTAssertEqual(cards[1].back, "thanks")
    }

    func testCorruptAnki21bThrowsUnreadable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x28, 0xB5, 0x2F, 0xFD, 0xFF, 0xFF, 0x00]).write(to: root.appendingPathComponent("collection.anki21b"))
        let file = root.appendingPathComponent("corrupt.apkg")
        let archive = try Archive(url: file, accessMode: .create)
        try archive.addEntry(with: "collection.anki21b", relativeTo: root)
        XCTAssertThrowsError(try Importer.anki(file)) { error in
            guard case ImportError.unreadable = error else { return XCTFail("Expected unreadable error, got \(error)") }
        }
    }

    func testDeckLegacyJSONAndUpsertPreservesLocalLanguage() throws {
        let id = UUID()
        let legacyJSON = Data("""
        {"id":"\(id.uuidString)","name":"Legacy","cards":[{"front":"bonjour","back":"hello","hint":""}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(Deck.self, from: legacyJSON)
        XCTAssertEqual(decoded.id, id)
        XCTAssertNil(decoded.language)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeckStore(root: root)
        let localDeck = Deck(id: id, name: "Japanese N5", cards: [Card(front: "水", back: "water")], language: "ja-JP")
        XCTAssertTrue(store.upsert(localDeck))
        let cloudDeck = Deck(id: id, name: "Japanese N5", cards: [Card(front: "水", back: "water")], language: nil)
        XCTAssertTrue(store.upsert(cloudDeck))
        XCTAssertEqual(store.deck(id)?.language, "ja-JP")
    }

    func testSingleTypedAnkiCardKeepsNamedFieldMapping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("collection.anki2")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let models = #"{"1":{"flds":[{"ord":0,"name":"Rank"},{"ord":1,"name":"French"},{"ord":2,"name":"Meaning"}],"tmpls":[{"qfmt":"{{French}}","afmt":"{{Meaning}}"}]}}"#
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE col (models TEXT); CREATE TABLE notes (id INTEGER, mid INTEGER, flds TEXT);", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO col VALUES ('\(models)'); INSERT INTO notes VALUES (1, 1, '1\u{1f}bonjour\u{1f}hello');", nil, nil, nil), SQLITE_OK)
        let file = root.appendingPathComponent("test.apkg")
        let archive = try Archive(url: file, accessMode: .create)
        try archive.addEntry(with: "collection.anki2", relativeTo: root)
        let cards = try Importer.anki(file)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.front, "bonjour")
        XCTAssertEqual(cards.first?.back, "hello")
    }

    func testNoteTypesRejectsNonNumericAndParameterizedLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("collection.anki21")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE col (models TEXT);
        CREATE TABLE notetypes (id TEXT, name TEXT);
        CREATE TABLE fields (ntid INTEGER, name TEXT, ord INTEGER);
        CREATE TABLE templates (ntid INTEGER, ord INTEGER, config BLOB);
        INSERT INTO col VALUES ('{}');
        INSERT INTO notetypes VALUES ('1 OR 1=1', 'bad');
        INSERT INTO notetypes VALUES ('42', 'good');
        INSERT INTO fields VALUES (42, 'French', 0), (42, 'Meaning', 1);
        INSERT INTO templates VALUES (42, 0, X'0A0A7B7B4672656E63687D7D120B7B7B4D65616E696E677D7D');
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        let types = AnkiImport.noteTypes(db)
        XCTAssertEqual(Array(types.keys), [42])
        XCTAssertEqual(types[42]?.fields, ["French", "Meaning"])
        XCTAssertEqual(types[42]?.qfmt, "{{French}}")
        XCTAssertEqual(types[42]?.afmt, "{{Meaning}}")
    }
}
