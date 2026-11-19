# MyVocab AnkiWeb Multi-Language Catalog, Link Import & `.anki21b` Implementation Plan

> **For agentic workers:** Implement this plan task-by-task natively in this session. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app multi-language AnkiWeb Shared Decks catalog (with per-language proficiency levels, audio/image/size/sample previews, and direct link/ID import), native `.anki21b` (zstd + `unicase`) import, and multi-language TTS while preserving existing CloudKit Production sync.

**Architecture:** Fetch each language's full shared deck listing from AnkiWeb's public Protobuf endpoint once per 15-minute cache window, perform all level/media/sort/search filtering locally in memory to prevent `HTTP 429` rate limits, lazily fetch `item-info` (size, description, sample notes, `download_key`), stream `.apkg` downloads with progress, decompress modern `collection.anki21b` via `facebook/zstd` (`libzstd`), and store optional `Deck.language` locally without changing the deployed CloudKit Production schema.

**Tech Stack:** Swift 5.9+, SwiftUI, Foundation (`URLSession`), SQLite3 C API, `ZIPFoundation` `0.9.20`, `facebook/zstd` `1.5.7` (`libzstd`), AVFoundation, NaturalLanguage, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-19-ankiweb-catalog-and-anki21b-design.md`

## Global Constraints
- macOS 14.0+ (Universal `x86_64` + `arm64`, Developer ID + CloudKit Production) and iOS 17.0+.
- Absolute zero comments in all touched code/test/script files; only `Package.swift` line 1 `// swift-tools-version:` and `#!` shebangs are exempt.
- Every Swift file strictly under 500 lines (`swiftlint lint --strict` 0 warnings / 0 errors) and every line `<= 200` chars (L1–L7 code health).
- CloudKit `Deck` record continues writing ONLY `name` and `cards` (no Production schema change).
- Zero live network requests in unit tests or `--snapshot` mode; never touch `~/Library/Application Support/Lexikos` during tests.

## Review Focus
1. AnkiWeb `HTTP 429` burst rate limiting -> single-fetch-per-language + disk/memory cache + stale-cache fallback on 429, pinned in `AnkiCatalogTests.testRateLimitFallsBackToStaleCache`.
2. `.anki21b` zstd decompression bomb or truncated/corrupt zstd payload -> hard 256 MiB streaming cap + clean `ImportError.unreadable` without crash, pinned in `ImportTests.testCorruptAnki21bThrowsUnreadable`.
3. Modern Anki SQLite `COLLATE unicase` query failure -> custom `unicase` collation registered on `sqlite3_open_v2`, pinned in `ImportTests.testAnki21bZstdWithUnicaseCollationImportsCards`.
4. Expired AnkiWeb `download_key` during download -> auto-refresh `item-info` once and retry download, pinned in `AnkiCatalogTests.testDownloadRetriesWithFreshKeyOnForbidden`.
5. Backward compatibility for existing decks (`language == nil`) and CloudKit sync -> legacy JSON decodes cleanly with `language == nil`, non-French decks speak in their language without breaking French default, pinned in `AnkiCatalogTests.testLegacyDeckDecodesWithoutLanguageAndSelectsVoice`.

---

### Task 1: Exempt `Package.swift` Line-1 `// swift-tools-version:` in Global No-Comments Checker & Add `facebook/zstd` Dependency

**Files:**
- Modify: `/Users/Yixuan/.gemini/config/agents/software-engineer/scripts/check_no_comments.py`
- Modify: `/Users/Yixuan/.gemini/config/agents/software-engineer/tests/test-lint-gate.sh`
- Modify: `Package.swift`
- Modify: `project.yml`

**Interfaces:**
- Produces: `libzstd` C library importable as `import libzstd` in `Sources/Lexikos/` and `Tests/LexikosTests/`.

- [ ] **Step 1:** Update `scan_swift` / `check_file` in `check_no_comments.py` to exempt ONLY line 1 matching `^//\s*swift-tools-version:` when basename is `Package.swift`; keep all other Swift comments forbidden (including line 2+ in `Package.swift` and line 1 in any other `.swift` file).
- [ ] **Step 2:** Add positive + negative assertions in `test-lint-gate.sh` and run it to verify all assertions pass.
- [ ] **Step 3:** Add `.package(url: "https://github.com/facebook/zstd.git", exact: "1.5.7")` and `.product(name: "libzstd", package: "zstd")` to `Package.swift` (removing line 4 comment) and `project.yml` (`Lexikos-macOS` & `Lexikos-iOS` targets).
- [ ] **Step 4:** Verify `swift package resolve` and `xcodegen generate -q` succeed cleanly.

---

### Task 2: Native `.anki21b` Zstd Decompression, SQLite `unicase` Collation & `Deck.language`

**Files:**
- Create: `Sources/Lexikos/ZstdDecompress.swift`
- Modify: `Sources/Lexikos/Decks.swift`
- Modify: `Tests/LexikosTests/ImportTests.swift`

**Interfaces:**
- Produces:
  - `ZstdDecompress.decompress(_ source: URL, to destination: URL, maxBytes: Int = 256 * 1024 * 1024) throws`
  - `ZstdDecompress.compress(_ data: Data) throws -> Data` (for deterministic tests)
  - `Deck.language: String?`
  - `DeckStore.loadFile(_ url: URL, replacing id: UUID? = nil, nameOverride: String? = nil, language: String? = nil) async throws`
  - `Importer.anki(_ url: URL) throws -> [Card]` supporting `collection.anki21b` (zstd) -> `collection.anki21` -> `collection.anki2` with `unicase` SQLite collation.

- [ ] **Step 1:** Write failing tests in `Tests/LexikosTests/ImportTests.swift`:
  - `testAnki21bZstdWithUnicaseCollationImportsCards`: creates SQLite DB with `notetypes` / `fields` / `templates` / `notes` using `COLLATE unicase`, compresses via `ZstdDecompress.compress`, zips with a 1-row stub `collection.anki2`, verifies `Importer.anki` returns the real cards from `collection.anki21b`.
  - `testCorruptAnki21bThrowsUnreadable`: verifies corrupt bytes in `collection.anki21b` throw `ImportError.unreadable`.
- [ ] **Step 2:** Implement `ZstdDecompress.swift` using `libzstd` `ZSTD_DStream` streaming API with `maxBytes` cap and Zstd magic `0x28 0xB5 0x2F 0xFD` detection.
- [ ] **Step 3:** Update `Decks.swift` to add optional `Deck.language`, prioritize `collection.anki21b` decompression, register SQLite `unicase` collation via `sqlite3_create_collation_v2`, and accept optional `nameOverride` & `language` on `DeckStore.loadFile`.
- [ ] **Step 4:** Run `swift test --filter ImportTests` -> PASS.

---

### Task 3: AnkiWeb Protobuf Client, Link/ID Parser, Caching & Streaming Download

**Files:**
- Create: `Sources/Lexikos/AnkiWebClient.swift`
- Test: `Tests/LexikosTests/AnkiCatalogTests.swift`

**Interfaces:**
- Produces:
  - `struct AnkiWebDeckSummary: Identifiable, Hashable, Codable` (`id: Int64`, `title: String`, `thumbsUp: Int`, `thumbsDown: Int`, `modified: Date`, `notes: Int`, `audio: Int`, `images: Int`)
  - `struct AnkiWebSampleNote: Hashable, Codable` (`fields: [(name: String, value: String)]` via `Codable` `Field` struct)
  - `struct AnkiWebDeckDetail: Identifiable, Hashable, Codable` (`id`, `title`, `tags`, `sizeBytes`, `lastUpdated`, `description`, `notes`, `audio`, `images`, `thumbsUp`, `thumbsDown`, `originalDeckName`, `sampleNotes`, `downloadKey`)
  - `enum AnkiWebError: Error, Equatable` (`invalidLink`, `notFound`, `accessDenied`, `rateLimited`, `network`, `http(Int)`, `badResponse`, `cancelled`)
  - `final class AnkiWebClient`:
    - `static func parseSharedID(_ input: String) -> Int64?`
    - `static func decodeListDecks(_ data: Data) throws -> [AnkiWebDeckSummary]`
    - `static func decodeItemInfo(_ data: Data, sharedID: Int64) throws -> AnkiWebDeckDetail`
    - `func listDecks(query: String, forceRefresh: Bool = false) async throws -> (decks: [AnkiWebDeckSummary], fromStaleCache: Bool)`
    - `func itemInfo(sharedID: Int64, forceRefresh: Bool = false) async throws -> AnkiWebDeckDetail`
    - `func downloadDeck(sharedID: Int64, initialKey: String?, onProgress: @Sendable @escaping (Int64, Int64) -> Void) async throws -> URL`

- [ ] **Step 1:** Write failing unit tests in `AnkiCatalogTests.swift` covering `parseSharedID` (full URL, www URL, query/slash, raw ID, invalid strings), protobuf decoding for `ListDecksResponse` and `ItemInfoResponse` (including `sample_notes`, `missing`, `access_denied`), `HTTP 429` stale-cache fallback, and `downloadDeck` 403/404 fresh-key retry.
- [ ] **Step 2:** Implement `AnkiWebClient.swift` with safe bounds-checked protobuf wire reader, memory + `Caches/com.yixuanwu.lexikos/ankiweb` disk cache, and streaming `.apkg` download with progress + retry.
- [ ] **Step 3:** Run `swift test --filter AnkiCatalogTests` -> PASS.

---

### Task 4: Multi-Language Level Catalog Engine & Multi-Language TTS

**Files:**
- Create: `Sources/Lexikos/AnkiCatalog.swift`
- Modify: `Sources/Lexikos/Speaker.swift`
- Modify: `Sources/Lexikos/CardLayout.swift`
- Modify: `Sources/Lexikos/PracticeView.swift`
- Test: `Tests/LexikosTests/AnkiCatalogTests.swift`

**Interfaces:**
- Produces:
  - `enum CatalogLanguage: String, CaseIterable, Identifiable` (10 AnkiWeb languages with localized names, AnkiWeb search query, BCP-47 speech locale, and language-specific `levels: [CatalogLevel]`)
  - `struct CatalogLevel: Identifiable, Hashable` (`id`, localized label, match patterns, preferred note range)
  - `enum CatalogSort: String, CaseIterable, Identifiable` (`recommended`, `rating`, `recent`, `compact`, `largest`)
  - `enum AnkiCatalogFilter`: `static func apply(decks: [AnkiWebDeckSummary], language: CatalogLanguage, level: CatalogLevel, query: String, onlyAudio: Bool, onlyImages: Bool, sort: CatalogSort) -> [AnkiWebDeckSummary]` and `static func isFeatured(_ id: Int64, language: CatalogLanguage, levelID: String) -> Bool`
  - `CatalogL`: localized UI strings (zh / en / fr) for the catalog so `Theme.swift` stays under 500 lines.
  - Multi-language `PracticeView.speak(slow:)` using `deck.language` with French default fallback.

- [ ] **Step 1:** Write tests in `AnkiCatalogTests.swift` verifying all 10 languages have valid levels, CEFR A1/A2/B1/B2/C1-C2 & JLPT N5-N1 & HSK & TOPIK & English exam filtering, `onlyAudio` / `onlyImages` media filters, sorting modes, and `Deck` backward-compatible decoding (`language == nil`).
- [ ] **Step 2:** Implement `AnkiCatalog.swift` and update `Speaker.swift` / `CardLayout.swift` / `PracticeView.swift` for multi-language TTS while preserving French defaults.
- [ ] **Step 3:** Run `swift test` -> PASS.

---

### Task 5: AnkiWeb Catalog UI & Detail Preview (Mac Split View + Narrow/iOS Adaptive Sheet)

**Files:**
- Create: `Sources/Lexikos/AnkiCatalogView.swift`
- Create: `Sources/Lexikos/AnkiCatalogDetail.swift`
- Modify: `Sources/Lexikos/LexikosApp.swift`
- Modify: `Sources/Lexikos/Theme.swift` (minimal 3-4 Home entry strings only, keeping < 470 lines)

**Interfaces:**
- Consumes: `AnkiWebClient`, `AnkiCatalog`, `CatalogLanguage`, `CatalogLevel`, `CatalogL`, `DeckStore.loadFile(..., nameOverride:, language:)`.
- Produces: `Route.catalog`, `AnkiCatalogView(route:)`, Home entry tile `"发现 AnkiWeb 词库"` alongside `"导入词库"`.

- [ ] **Step 1:** Implement `AnkiCatalogDetail.swift`: metadata grid (size MB, notes, audio count with speaker badge, image count with photo badge, thumbs up/down, last updated), cleaned description, `sample_notes` preview cards, lightweight-sync hint, Download & Import primary CTA with live progress bar & Cancel button, and "Open on AnkiWeb" link.
- [ ] **Step 2:** Implement `AnkiCatalogView.swift`: top bar with Back + link/ID direct import field, horizontal 10-language chips, dynamic per-language level chips, search box (instant local filter + explicit remote search action), `🔊 含发音` / `🖼 含图片` filter chips, sort menu, Mac wide split-view / narrow & iOS sheet presentation, loading/empty/429-stale/error states, and downloaded toast/feedback.
- [ ] **Step 3:** Wire `.catalog` route in `LexikosApp.swift` and add the `"发现 AnkiWeb 词库"` tile in `HomeView` next to `ImportTile`.

---

### Task 6: Full Verification — Lint Gate, Unit Tests, Real Live AnkiWeb Import Spike, Universal Release & iOS Build

**Files:**
- Modify: `scripts/check.sh` (add `Package.swift` to no-comments check now that line 1 directive is properly handled!)

- [ ] **Step 1:** Run `/Users/Yixuan/.gemini/config/agents/software-engineer/tests/test-lint-gate.sh` to verify global lint suite passes.
- [ ] **Step 2:** Run `./scripts/check.sh` and global `lint-gate.sh` -> 0 errors, 0 warnings.
- [ ] **Step 3:** Run `LEXIKOS_DATA=<tmp copy> swift test --filter RealDataTests` -> PASS.
- [ ] **Step 4:** Run `./release.sh --export-only` (Universal `x86_64` + `arm64`, Developer ID, CloudKit Production) and `xcodebuild -scheme Lexikos-iOS -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` -> PASS.
- [ ] **Step 5:** Run isolated `--snapshot` + live CLI/test verification importing a real small AnkiWeb French deck into `/tmp` to verify end-to-end download + import + card rendering!
