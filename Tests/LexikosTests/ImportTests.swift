import XCTest
import ZIPFoundation
import SQLite3
@testable import Lexikos

final class ImportTests: XCTestCase {
    func testCleanStripsMarkup() {
        XCTAssertEqual(Importer.clean("un<br>deux&nbsp;[sound:x.mp3]"), "un\ndeux")
    }

    func testAnki21bIsExplicitlyRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: root.appendingPathComponent("collection.anki21b"))
        let file = root.appendingPathComponent("test.apkg")
        let archive = try Archive(url: file, accessMode: .create)
        try archive.addEntry(with: "collection.anki21b", relativeTo: root)
        XCTAssertThrowsError(try Importer.anki(file)) { error in
            guard case ImportError.anki21b = error else { return XCTFail("Expected explicit anki21b error, got \(error)") }
        }
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
