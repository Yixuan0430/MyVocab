import XCTest
@testable import Lexikos

final class AnkiCatalogTests: XCTestCase {
    func testParseSharedIDSupportsLinksPathsAndPlainIDs() {
        XCTAssertEqual(AnkiWebClient.parseSharedID("https://ankiweb.net/shared/info/893324022"), 893324022)
        XCTAssertEqual(AnkiWebClient.parseSharedID("https://ankiweb.net/shared/info/893324022?cb=123"), 893324022)
        XCTAssertEqual(AnkiWebClient.parseSharedID("https://www.ankiweb.net/shared/info/1089240419/"), 1089240419)
        XCTAssertEqual(AnkiWebClient.parseSharedID("/shared/info/629972372"), 629972372)
        XCTAssertEqual(AnkiWebClient.parseSharedID("  893324022  "), 893324022)
        XCTAssertNil(AnkiWebClient.parseSharedID(""))
        XCTAssertNil(AnkiWebClient.parseSharedID("0"))
        XCTAssertNil(AnkiWebClient.parseSharedID("https://example.com/shared/info/893324022"))
        XCTAssertNil(AnkiWebClient.parseSharedID("https://ankiweb.net/shared/decks?search=french"))
    }

    func testDecodeListDecksParsesMediaCountsAndRatings() throws {
        var row = Data()
        row.append(pbVarintField(1, 893324022))
        row.append(pbStringField(2, "French 5000 A1-B2"))
        row.append(pbVarintField(3, 891))
        row.append(pbVarintField(4, 12))
        row.append(pbVarintField(5, 1_700_000_000))
        row.append(pbVarintField(6, 5000))
        row.append(pbVarintField(7, 4800))
        row.append(pbVarintField(8, 240))
        let payload = pbBytesField(1, row)

        let decks = try AnkiWebClient.decodeListDecks(payload)
        XCTAssertEqual(decks.count, 1)
        let deck = try XCTUnwrap(decks.first)
        XCTAssertEqual(deck.id, 893324022)
        XCTAssertEqual(deck.title, "French 5000 A1-B2")
        XCTAssertEqual(deck.thumbsUp, 891)
        XCTAssertEqual(deck.thumbsDown, 12)
        XCTAssertEqual(deck.ratingScore, 879)
        XCTAssertEqual(deck.notes, 5000)
        XCTAssertEqual(deck.audio, 4800)
        XCTAssertEqual(deck.images, 240)
        XCTAssertTrue(deck.hasAudio)
        XCTAssertTrue(deck.hasImages)
        XCTAssertEqual(deck.modified.timeIntervalSince1970, 1_700_000_000)
    }

    func testDecodeItemInfoParsesDetailSamplesAndErrors() throws {
        let pair1 = pbStringField(1, "Front") + pbStringField(2, "[image:1.jpg]")
        let pair2 = pbStringField(1, "French") + pbStringField(2, "bonjour [sound:0.mp3]")
        let pair3 = pbStringField(1, "English") + pbStringField(2, "<b>hello</b>")
        let note = pbBytesField(1, pair1) + pbBytesField(1, pair2) + pbBytesField(1, pair3)

        let deckMsg = pbVarintField(1, 500)
            + pbVarintField(2, 480)
            + pbVarintField(3, 120)
            + pbBytesField(4, note)
            + pbStringField(5, "tok_abc123")

        let item = pbStringField(5, "Essential French A1")
            + pbStringField(6, "french a1 audio")
            + pbVarintField(7, 2_417_022)
            + pbVarintField(8, 1_710_000_000)
            + pbStringField(9, "<p>Core A1 deck</p>")
            + pbBytesField(10, deckMsg)
            + pbVarintField(18, 235)
            + pbVarintField(19, 3)
            + pbStringField(20, "Essential::French")

        let detail = try AnkiWebClient.decodeItemInfo(pbBytesField(1, item), sharedID: 1089240419)
        XCTAssertEqual(detail.id, 1089240419)
        XCTAssertEqual(detail.title, "Essential French A1")
        XCTAssertEqual(detail.tags, "french a1 audio")
        XCTAssertEqual(detail.sizeBytes, 2_417_022)
        XCTAssertEqual(detail.description, "Core A1 deck")
        XCTAssertEqual(detail.notes, 500)
        XCTAssertEqual(detail.audio, 480)
        XCTAssertEqual(detail.images, 120)
        XCTAssertEqual(detail.thumbsUp, 235)
        XCTAssertEqual(detail.thumbsDown, 3)
        XCTAssertEqual(detail.originalDeckName, "Essential::French")
        XCTAssertEqual(detail.downloadKey, "tok_abc123")
        XCTAssertEqual(detail.sampleNotes.count, 1)
        XCTAssertEqual(detail.sampleNotes[0].fields.map(\.name), ["Front", "French", "English"])
        XCTAssertEqual(detail.sampleNotes[0].fields.map(\.value), ["", "bonjour", "hello"])
        XCTAssertEqual(detail.sampleNotes[0].fields[0].images, ["1.jpg"])
        XCTAssertEqual(detail.sampleNotes[0].fields[1].sounds, ["0.mp3"])
        XCTAssertEqual(
            detail.mediaPreviewURL(for: "1.jpg")?.absoluteString,
            "https://ankiweb.net/shared/mpreview/1089240419/1.jpg?1710000000"
        )
        XCTAssertNil(detail.mediaPreviewURL(for: "../secret.jpg"))
        XCTAssertNil(detail.mediaPreviewURL(for: "a/b.jpg"))

        XCTAssertThrowsError(try AnkiWebClient.decodeItemInfo(pbVarintField(2, 1), sharedID: 1)) { err in
            XCTAssertEqual(err as? AnkiWebError, .notFound)
        }
        XCTAssertThrowsError(try AnkiWebClient.decodeItemInfo(pbVarintField(3, 1), sharedID: 1)) { err in
            XCTAssertEqual(err as? AnkiWebError, .accessDenied)
        }
    }

    func testListDecksFallsBackToStaleCacheOn429() async throws {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let row = pbVarintField(1, 123) + pbStringField(2, "French A1") + pbVarintField(6, 300)
        let listPayload = pbBytesField(1, row)
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()

        let client = AnkiWebClient(cacheDir: cacheDir, seed: nil, fetcher: { req in
            counter.calls += 1
            let status = counter.calls == 1 ? 200 : 429
            let resp = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (status == 200 ? listPayload : Data(), resp)
        })

        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await client.listDecks(query: "french", now: t0)
        XCTAssertFalse(first.fromStaleCache)
        XCTAssertEqual(first.decks.count, 1)
        XCTAssertEqual(counter.calls, 1)

        let cached = try await client.listDecks(query: "french", now: t0.addingTimeInterval(3600))
        XCTAssertFalse(cached.fromStaleCache)
        XCTAssertEqual(counter.calls, 1)

        let stale = try await client.listDecks(query: "french", now: t0.addingTimeInterval(90_000))
        XCTAssertTrue(stale.fromStaleCache)
        XCTAssertEqual(stale.decks.first?.id, 123)
        XCTAssertEqual(counter.calls, 2)
    }

    func testBundledSeedCoversAllTenLanguagesAndAvoidsRateLimit() async throws {
        let seed = try XCTUnwrap(AnkiCatalogSeed.bundled)
        XCTAssertEqual(Set(seed.availableLanguages), Set(CatalogLanguage.allCases.map(\.searchQuery)))
        var total = 0
        for lang in CatalogLanguage.allCases {
            let list = try XCTUnwrap(seed.decks(for: lang.searchQuery))
            XCTAssertGreaterThan(list.count, 50)
            total += list.count
        }
        XCTAssertGreaterThan(total, 10_000)

        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let client = AnkiWebClient(cacheDir: nil, seed: seed, fetcher: { req in
            counter.calls += 1
            let resp = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (Data("Please log in to perform more searches.".utf8), resp)
        })

        let initial = try await client.listDecks(query: "french")
        XCTAssertFalse(initial.fromStaleCache)
        XCTAssertGreaterThan(initial.decks.count, 500)
        XCTAssertEqual(counter.calls, 0)

        let refreshed = try await client.listDecks(query: "french", forceRefresh: true)
        XCTAssertTrue(refreshed.fromStaleCache)
        XCTAssertEqual(refreshed.decks.count, initial.decks.count)
        XCTAssertEqual(counter.calls, 1)
    }

    func testDownloadDeckRefreshesExpiredKeyOn403AndRejectsNonZip() async throws {
        let deckMsg = pbVarintField(1, 10) + pbStringField(5, "fresh_key")
        let itemPayload = pbBytesField(1, pbStringField(5, "Test") + pbBytesField(10, deckMsg))

        final class State: @unchecked Sendable {
            var infoCalls = 0
            var downloadKeys: [String] = []
        }
        let state = State()

        let client = AnkiWebClient(
            cacheDir: nil,
            fetcher: { req in
                state.infoCalls += 1
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (itemPayload, resp)
            },
            downloader: { req, onProgress in
                let key = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "t" })?.value ?? ""
                state.downloadKeys.append(key)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".apkg")
                if key == "stale_key" {
                    try Data().write(to: tmp)
                    let resp = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                    return (tmp, resp)
                }
                let zipHeader = Data([0x50, 0x4B, 0x03, 0x04])
                try zipHeader.write(to: tmp)
                onProgress(4, 4)
                let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (tmp, resp)
            }
        )

        let fileURL = try await client.downloadDeck(sharedID: 555, initialKey: "stale_key") { _, _ in }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        XCTAssertEqual(state.infoCalls, 1)
        XCTAssertEqual(state.downloadKeys, ["stale_key", "fresh_key"])

        let badClient = AnkiWebClient(cacheDir: nil, downloader: { req, _ in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".apkg")
            try Data("<html>not a zip</html>".utf8).write(to: tmp)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (tmp, resp)
        })
        do {
            _ = try await badClient.downloadDeck(sharedID: 555, initialKey: "k") { _, _ in }
            XCTFail("Expected badResponse for non-ZIP download")
        } catch let error as AnkiWebError {
            XCTAssertEqual(error, .badResponse)
        }
    }

    func testAllTenLanguagesHaveDistinctLevelsAndSpeechCodes() {
        XCTAssertEqual(CatalogLanguage.allCases.count, 10)
        for lang in CatalogLanguage.allCases {
            XCTAssertEqual(lang.levels.first, .all)
            XCTAssertGreaterThanOrEqual(lang.levels.count, 5)
            XCTAssertFalse(lang.speechCode.isEmpty)
            for uiLang in AppLanguage.allCases {
                XCTAssertFalse(lang.label(uiLang).isEmpty)
            }
        }
        XCTAssertTrue(CatalogLanguage.french.levels.contains(.a1))
        XCTAssertTrue(CatalogLanguage.japanese.levels.contains(.n5))
        XCTAssertTrue(CatalogLanguage.english.levels.contains(.ielts))
        XCTAssertTrue(CatalogLanguage.korean.levels.contains(.topik1))
        XCTAssertTrue(CatalogLanguage.chinese.levels.contains(.hsk12))
        XCTAssertEqual(CatalogLanguage.infer(from: "DELF A1 Français"), .french)
        XCTAssertEqual(CatalogLanguage.infer(from: "JLPT N5 Vocabulary"), .japanese)
        XCTAssertEqual(CatalogLanguage.infer(from: "HSK 1-2 Mandarin"), .chinese)
    }

    func testCatalogFilterMatchesLevelsMediaSearchAndSort() {
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let decks = [
            AnkiWebDeckSummary(
                id: 629972372,
                title: "French 500 coloured words with pictures and audio",
                thumbsUp: 101,
                thumbsDown: 2,
                modified: now.addingTimeInterval(-86400),
                notes: 491,
                audio: 480,
                images: 487
            ),
            AnkiWebDeckSummary(
                id: 1,
                title: "Français A1 Débutant Vocabulaire",
                thumbsUp: 40,
                thumbsDown: 0,
                modified: now,
                notes: 320,
                audio: 300,
                images: 0
            ),
            AnkiWebDeckSummary(
                id: 2,
                title: "DELF B2 Expressions",
                thumbsUp: 90,
                thumbsDown: 1,
                modified: now.addingTimeInterval(-3600),
                notes: 1200,
                audio: 0,
                images: 0
            ),
            AnkiWebDeckSummary(
                id: 3,
                title: "French Grammar & Conjugation",
                thumbsUp: 120,
                thumbsDown: 5,
                modified: now.addingTimeInterval(-7200),
                notes: 850,
                audio: 200,
                images: 10
            )
        ]

        let a1 = AnkiCatalogFilter.apply(decks, language: .french, level: .a1, query: "", onlyAudio: false, onlyImages: false, sort: .recommended)
        XCTAssertEqual(a1.map(\.id), [629972372, 1])

        let audioAndImages = AnkiCatalogFilter.apply(decks, language: .french, level: .all, query: "", onlyAudio: true, onlyImages: true, sort: .rating)
        XCTAssertEqual(audioAndImages.map(\.id), [3, 629972372])

        let accentInsensitive = AnkiCatalogFilter.apply(decks, language: .french, level: .all, query: "francais debutant", onlyAudio: false, onlyImages: false, sort: .recommended)
        XCTAssertEqual(accentInsensitive.map(\.id), [1])

        let compact = AnkiCatalogFilter.apply(decks, language: .french, level: .all, query: "", onlyAudio: false, onlyImages: false, sort: .compact)
        XCTAssertEqual(compact.first?.id, 1)

        let recent = AnkiCatalogFilter.apply(decks, language: .french, level: .all, query: "", onlyAudio: false, onlyImages: false, sort: .recent)
        XCTAssertEqual(recent.first?.id, 1)

        let grammar = AnkiCatalogFilter.apply(decks, language: .french, level: .grammar, query: "", onlyAudio: false, onlyImages: false, sort: .recommended)
        XCTAssertEqual(grammar.map(\.id), [3])
    }

    @MainActor func testSpeakerResolvesMultiLanguageDeckSpeech() {
        let frDefault = Speaker.resolveSpeech(front: "bonjour tout le monde", answer: "hello everyone", deckLanguage: nil)
        XCTAssertEqual(frDefault.language, "fr-FR")
        XCTAssertEqual(frDefault.text, "bonjour tout le monde")

        let ja = Speaker.resolveSpeech(front: "おはようございます", answer: "good morning", deckLanguage: "ja-JP")
        XCTAssertEqual(ja.language, "ja-JP")
        XCTAssertEqual(ja.text, "おはようございます")

        let jaFlipped = Speaker.resolveSpeech(front: "good morning everyone", answer: "おはようございます", deckLanguage: "ja-JP")
        XCTAssertEqual(jaFlipped.language, "ja-JP")
        XCTAssertEqual(jaFlipped.text, "おはようございます")

        let en = Speaker.resolveSpeech(front: "ephemeral", answer: "短暂的", deckLanguage: "en-US")
        XCTAssertEqual(en.language, "en-US")
        XCTAssertEqual(en.text, "ephemeral")
    }

    private func pbVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private func pbVarintField(_ num: Int, _ value: UInt64) -> Data {
        pbVarint(UInt64(num << 3)) + pbVarint(value)
    }

    private func pbBytesField(_ num: Int, _ bytes: Data) -> Data {
        pbVarint(UInt64((num << 3) | 2)) + pbVarint(UInt64(bytes.count)) + bytes
    }

    private func pbStringField(_ num: Int, _ value: String) -> Data {
        pbBytesField(num, Data(value.utf8))
    }
}
