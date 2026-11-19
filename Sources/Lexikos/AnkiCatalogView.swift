import SwiftUI

struct AnkiCatalogView: View {
    @Binding var route: Route?
    @Environment(DeckStore.self) private var store
    @Environment(\.windowSize) private var size
    @Environment(\.snapshotting) private var snapshotting
    @AppStorage("lang") private var lang = AppLanguage.systemDefault
    @AppStorage("accent") private var accent = Accent.moss
    @AppStorage("catalogLang") private var storedLanguage = CatalogLanguage.french.rawValue

    @State private var selectedLanguage = CatalogLanguage.french
    @State private var selectedLevel = CatalogLevel.all
    @State private var localQuery = ""
    @State private var remoteQuery: String?
    @State private var onlyAudio = false
    @State private var onlyImages = false
    @State private var sort = CatalogSort.recommended

    @State private var linkInput = ""
    @State private var linkError: String?

    @State private var decks: [AnkiWebDeckSummary] = []
    @State private var loadingList = false
    @State private var listError: String?
    @State private var staleCacheBanner = false

    @State private var selectedID: Int64?
    @State private var selectedSummary: AnkiWebDeckSummary?
    @State private var selectedDetail: AnkiWebDeckDetail?
    @State private var loadingDetail = false
    @State private var detailError: String?
    @State private var showDetailSheet = false

    @State private var downloadState = CatalogDownloadState.idle
    @State private var downloadTargetID: Int64?
    @State private var listTask: Task<Void, Never>?
    @State private var detailTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?

    struct Preset {
        var language: CatalogLanguage = .french
        var level: CatalogLevel = .a1
        var decks: [AnkiWebDeckSummary]
        var detail: AnkiWebDeckDetail
    }
    private let preset: Preset?

    init(route: Binding<Route?>, preset: Preset? = nil) {
        _route = route
        self.preset = preset
        guard let preset else { return }
        _selectedLanguage = State(initialValue: preset.language)
        _selectedLevel = State(initialValue: preset.level)
        _decks = State(initialValue: preset.decks)
        _selectedID = State(initialValue: preset.detail.id)
        _selectedSummary = State(initialValue: preset.decks.first { $0.id == preset.detail.id } ?? preset.decks.first)
        _selectedDetail = State(initialValue: preset.detail)
    }

    private var l: L { L(lang: lang) }
    private var cl: CatalogL { CatalogL(lang: lang) }

    private var filteredDecks: [AnkiWebDeckSummary] {
        AnkiCatalogFilter.apply(
            decks, language: selectedLanguage,
            level: remoteQuery == nil ? selectedLevel : .all,
            query: remoteQuery == nil ? localQuery : "",
            onlyAudio: onlyAudio, onlyImages: onlyImages, sort: sort
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar
            linkImportBar
            languageStrip
            if remoteQuery == nil { levelStrip }
            filterToolbar
            if staleCacheBanner { staleBanner }
            mainContent
        }
        .frame(maxWidth: 1200)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, size.gutter).padding(.top, size.top).padding(.bottom, 16)
        .onAppear {
            guard preset == nil else { return }
            if let restored = CatalogLanguage(rawValue: storedLanguage) { selectedLanguage = restored }
            if decks.isEmpty && !loadingList { loadCatalog(forceRefresh: false) }
        }
        .onDisappear { listTask?.cancel(); detailTask?.cancel(); downloadTask?.cancel() }
        .sheet(isPresented: $showDetailSheet) {
            detailInspector
                #if os(macOS)
                .frame(width: 520, height: 640)
                #else
                .padding(.top, 8)
                .presentationBackground(Color.bg)
                #endif
        }
    }

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button { route = nil } label: {
                Label(l["back"], systemImage: "chevron.left").font(.system(size: 13)).touchTarget(.leading)
            }
            .buttonStyle(.plain).foregroundStyle(Color.muted).keyboardShortcut(.cancelAction)

            Text(cl["title"]).font(.custom("Didot", size: size.narrow ? 22 : 26)).foregroundStyle(Color.ink)
            if !size.compact {
                Text(cl["subtitle"]).font(.system(size: 12.5)).foregroundStyle(Color.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { loadCatalog(forceRefresh: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28).touchTarget(.trailing)
            }
            .buttonStyle(.plain).foregroundStyle(Color.muted).disabled(loadingList)
            .help(cl["action.refresh"]).accessibilityLabel(cl["action.refresh"])
        }
    }

    private var linkImportBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Image(systemName: "link").font(.system(size: 12.5, weight: .medium)).foregroundStyle(accent.color)
                if snapshotting {
                    Text(linkInput.isEmpty ? cl["link.placeholder"] : linkInput)
                        .font(.system(size: 13))
                        .foregroundStyle(linkInput.isEmpty ? Color.faint : Color.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    TextField(cl["link.placeholder"], text: $linkInput)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .onSubmit { openFromLink() }
                        .onChange(of: linkInput) { if linkError != nil { linkError = nil } }
                }
                if !linkInput.isEmpty {
                    Button { linkInput = ""; linkError = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.faint)
                    }
                    .buttonStyle(.plain).accessibilityLabel("Clear")
                } else {
                    #if os(iOS)
                    Button(l["paste"]) {
                        if let text = UIPasteboard.general.string { linkInput = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .buttonStyle(.capsule(.secondary, accent))
                    #endif
                }
                Button(cl["link.open"], action: openFromLink)
                    .buttonStyle(.capsule(.soft, accent))
                    .disabled(linkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .paperCard(radius: 14)

            if let linkError {
                Text(linkError).font(.system(size: 11.5)).foregroundStyle(Color.neg).padding(.leading, 6)
            }
        }
    }

    private var languageStrip: some View {
        SnapshotSafeScroll(axis: .horizontal) {
            HStack(spacing: 7) {
                ForEach(CatalogLanguage.allCases) { item in
                    Chip(title: item.label(lang), selected: remoteQuery == nil && selectedLanguage == item, accent: accent) {
                        selectLanguage(item)
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var levelStrip: some View {
        SnapshotSafeScroll(axis: .horizontal) {
            HStack(spacing: 6) {
                ForEach(selectedLanguage.levels) { level in
                    Chip(title: level.label(lang), selected: selectedLevel == level, accent: accent) {
                        selectedLevel = level
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var filterToolbar: some View {
        let layout = size.compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            HStack(spacing: 8) {
                SearchBox(text: $localQuery, prompt: cl["search.local"])
                    .onSubmit { runRemoteSearch() }
                if let remoteQuery {
                    Button {
                        self.remoteQuery = nil
                        loadCatalog(forceRefresh: false)
                    } label: {
                        Label("\(cl["search.remoteMode"]): \(remoteQuery)", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.capsule(.secondary, accent))
                } else if !localQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(cl["search.remote"], action: runRemoteSearch)
                        .buttonStyle(.capsule(.secondary, accent))
                }
            }
            HStack(spacing: 6) {
                Chip(title: cl["filter.audio"], icon: "speaker.wave.2.fill", selected: onlyAudio, accent: accent) {
                    onlyAudio.toggle()
                }
                Chip(title: cl["filter.images"], icon: "photo.fill", selected: onlyImages, accent: accent) {
                    onlyImages.toggle()
                }
                Menu {
                    ForEach(CatalogSort.allCases) { option in
                        Button { sort = option } label: {
                            if sort == option { Label(option.label(lang), systemImage: "checkmark") }
                            else { Text(option.label(lang)) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 10.5))
                        Text(sort.label(lang)).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.well))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)

                if !size.narrow {
                    Text(String(format: cl["count.decks"], filteredDecks.count))
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.muted)
                        .padding(.leading, 4)
                }
            }
        }
    }

    private var staleBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.warn)
            Text(cl["stale.banner"])
                .font(.system(size: 12))
                .foregroundStyle(Color.ink)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.warn.opacity(0.14)))
    }

    @ViewBuilder private var mainContent: some View {
        if size.compact {
            deckListPanel
        } else {
            HStack(alignment: .top, spacing: 18) {
                deckListPanel
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                detailInspector
                    .frame(width: min(440, max(340, size.width * 0.38)))
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private var deckListPanel: some View {
        Group {
            if loadingList && decks.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 60)
                    ProgressView()
                    Text(cl["loading"]).font(.system(size: 13)).foregroundStyle(Color.muted)
                    Spacer(minLength: 60)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let listError, decks.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 60)
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 26, weight: .light)).foregroundStyle(Color.warn)
                    Text(listError).font(.system(size: 13)).foregroundStyle(Color.ink).multilineTextAlignment(.center).frame(maxWidth: 340)
                    HStack(spacing: 10) {
                        if remoteQuery != nil {
                            Button(cl["search.clearRemote"]) {
                                remoteQuery = nil
                                loadCatalog(forceRefresh: false)
                            }
                            .buttonStyle(.capsule(.primary, accent))
                        }
                        Button(cl["action.retry"]) { loadCatalog(forceRefresh: true) }
                            .buttonStyle(.capsule(.secondary, accent))
                    }
                    Spacer(minLength: 60)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredDecks.isEmpty {
                VStack(spacing: 12) {
                    Spacer(minLength: 60)
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 26, weight: .light)).foregroundStyle(Color.faint)
                    Text(cl["empty.level"]).font(.system(size: 13)).foregroundStyle(Color.muted)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                    if selectedLevel != .all || onlyAudio || onlyImages {
                        Button(CatalogLevel.all.label(lang)) { selectedLevel = .all; onlyAudio = false; onlyImages = false }
                            .buttonStyle(.capsule(.secondary, accent))
                    }
                    Spacer(minLength: 60)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PageScroll {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredDecks) { deck in
                            CatalogDeckRow(
                                deck: deck, selected: selectedID == deck.id,
                                featured: remoteQuery == nil && AnkiCatalogFilter.isFeatured(deck, language: selectedLanguage, level: selectedLevel),
                                accent: accent, l: cl
                            ) { selectDeck(deck) }
                        }
                    }
                    .padding(.vertical, 2).padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var detailInspector: some View {
        let inferredBadge: String? = {
            if let detail = selectedDetail,
               let inferred = CatalogLanguage.infer(from: detail.title + " " + detail.tags) {
                return inferred.shortCode
            }
            return remoteQuery == nil ? selectedLanguage.shortCode : nil
        }()
        let featured = selectedSummary.map {
            remoteQuery == nil && AnkiCatalogFilter.isFeatured($0, language: selectedLanguage, level: selectedLevel)
        } ?? false
        return AnkiCatalogDetailPanel(
            summary: selectedSummary,
            detail: selectedDetail,
            loading: loadingDetail,
            loadError: detailError,
            languageBadge: inferredBadge,
            isFeatured: featured,
            downloadState: downloadTargetID == selectedID ? downloadState : .idle,
            accent: accent,
            l: cl,
            onRetryLoad: { if let id = selectedID { loadDetail(sharedID: id, forceRefresh: true) } },
            onDownload: { startDownload($0) },
            onCancelDownload: {
                downloadTask?.cancel()
                downloadTargetID = nil
                downloadState = .idle
            },
            onOpenDeck: { deck in
                showDetailSheet = false
                route = .overview(deck)
            },
            onClose: showDetailSheet ? { showDetailSheet = false } : nil
        )
    }

    private func selectLanguage(_ language: CatalogLanguage) {
        selectedLanguage = language; storedLanguage = language.rawValue
        selectedLevel = .all; remoteQuery = nil; localQuery = ""
        loadCatalog(forceRefresh: false)
    }

    private func runRemoteSearch() {
        let trimmed = localQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        remoteQuery = trimmed
        loadCatalog(forceRefresh: false)
    }

    private func openFromLink() {
        guard let sharedID = AnkiWebClient.parseSharedID(linkInput) else { linkError = cl["err.invalidLink"]; return }
        linkError = nil; selectedID = sharedID; selectedSummary = decks.first { $0.id == sharedID }; selectedDetail = nil
        if size.compact { showDetailSheet = true }
        loadDetail(sharedID: sharedID, forceRefresh: false)
    }

    private func selectDeck(_ deck: AnkiWebDeckSummary) {
        selectedID = deck.id; selectedSummary = deck
        if selectedDetail?.id != deck.id { selectedDetail = nil }
        if size.compact { showDetailSheet = true }
        loadDetail(sharedID: deck.id, forceRefresh: false)
    }

    private func loadCatalog(forceRefresh: Bool) {
        listTask?.cancel()
        let query = remoteQuery ?? selectedLanguage.searchQuery
        loadingList = true
        listError = nil
        listTask = Task { @MainActor in
            do {
                let result = try await AnkiWebClient.shared.listDecks(query: query, forceRefresh: forceRefresh)
                guard !Task.isCancelled else { return }
                decks = result.decks
                staleCacheBanner = result.fromStaleCache
                loadingList = false
                if !size.compact, selectedID == nil, let first = filteredDecks.first {
                    selectDeck(first)
                }
            } catch let err as AnkiWebError {
                guard !Task.isCancelled else { return }
                loadingList = false
                listError = cl.errorMessage(err)
            } catch {
                guard !Task.isCancelled else { return }
                loadingList = false
                listError = error.localizedDescription
            }
        }
    }

    private func loadDetail(sharedID: Int64, forceRefresh: Bool) {
        detailTask?.cancel()
        loadingDetail = true
        detailError = nil
        detailTask = Task { @MainActor in
            do {
                let detail = try await AnkiWebClient.shared.itemInfo(sharedID: sharedID, forceRefresh: forceRefresh)
                guard !Task.isCancelled, selectedID == sharedID else { return }
                selectedDetail = detail
                loadingDetail = false
            } catch let err as AnkiWebError {
                guard !Task.isCancelled, selectedID == sharedID else { return }
                loadingDetail = false
                detailError = cl.errorMessage(err)
            } catch {
                guard !Task.isCancelled, selectedID == sharedID else { return }
                loadingDetail = false
                detailError = error.localizedDescription
            }
        }
    }

    private func startDownload(_ detail: AnkiWebDeckDetail) {
        downloadTask?.cancel()
        downloadTargetID = detail.id
        downloadState = .downloading(received: 0, expected: detail.sizeBytes)
        let targetLanguage = CatalogLanguage.infer(from: detail.title + " " + detail.tags)?.speechCode
            ?? (remoteQuery == nil ? selectedLanguage.speechCode : nil)
        downloadTask = Task { @MainActor in
            do {
                let tempURL = try await AnkiWebClient.shared.downloadDeck(
                    sharedID: detail.id,
                    initialKey: detail.downloadKey
                ) { received, expected in
                    Task { @MainActor in
                        if downloadTargetID == detail.id, case .downloading = downloadState {
                            downloadState = .downloading(received: received, expected: expected)
                        }
                    }
                }
                defer { try? FileManager.default.removeItem(at: tempURL) }
                guard !Task.isCancelled else { downloadState = .idle; return }
                downloadState = .importing
                let beforeIDs = Set(store.decks.map(\.id))
                try await store.loadFile(tempURL, nameOverride: detail.title, language: targetLanguage)
                if let imported = store.decks.first(where: { !beforeIDs.contains($0.id) })
                    ?? store.decks.first(where: { $0.name == detail.title }) {
                    downloadState = .imported(imported)
                } else {
                    downloadState = .failed(cl["err.importUnreadable"])
                }
            } catch AnkiWebError.cancelled {
                downloadState = .idle
            } catch is CancellationError {
                downloadState = .idle
            } catch let err as AnkiWebError {
                downloadState = .failed(cl.errorMessage(err))
            } catch let err as ImportError {
                downloadState = .failed(err == .empty ? cl["err.importEmpty"] : cl["err.importUnreadable"])
            } catch {
                downloadState = .failed(error.localizedDescription)
            }
        }
    }
}
