import SwiftUI
import AVFoundation
import NaturalLanguage
import UniformTypeIdentifiers

enum Level: Int, CaseIterable, Identifiable {
    case units, tens, hundreds, thousands
    var id: Int { rawValue }
    var range: ClosedRange<Int> { [0...10, 11...99, 100...999, 1000...9999][rawValue] }
    var label: String { "\(range.lowerBound)–\(range.upperBound)" }
}

enum Route: Hashable { case numbers, overview(Deck), study(Deck), free(Deck) }

struct RootView: View {
    @Environment(DeckStore.self) private var store
    @Environment(ProgressStore.self) private var progress
    @AppStorage("lang") private var lang = AppLanguage.zh
    @AppStorage("accent") private var accent = Accent.moss
    @AppStorage("appearance") private var appearance = Appearance.system
    @State private var route: Route?

    var body: some View {
        let l = L(lang: lang)
        GeometryReader { geo in
            ZStack {
                AmbientBackground()
                content
            }
            .environment(\.windowSize, geo.size)
        }
        .overlay(alignment: .bottom) {
            if let message = store.lastError ?? progress.lastError {
                Label(l["err.save"] + message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Color.ink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .paperCard(radius: 12)
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: route)
        .onAppear { AppTheme.shared.accent = accent; AppTheme.shared.appearance = appearance }
        .onChange(of: accent) { AppTheme.shared.accent = accent }
        .onChange(of: appearance) { AppTheme.shared.appearance = appearance }
    }

    @ViewBuilder private var content: some View {
        switch route {
        case nil: HomeView(route: $route)
        case .numbers: PracticeView(source: .numbers, route: $route)
        case .overview(let d): OverviewView(deck: d, route: $route)
        case .study(let d): PracticeView(source: .study(d), route: $route).id("study-\(d.id)")
        case .free(let d): PracticeView(source: .free(d), route: $route).id("free-\(d.id)")
        }
    }
}

struct HomeView: View {
    @Binding var route: Route?
    @Environment(DeckStore.self) private var store
    @Environment(ProgressStore.self) private var progress
    #if os(macOS)
    @Environment(Updater.self) private var updater
    #endif
    @AppStorage("newPerDay") private var newPerDay = 20
    @AppStorage("groupSize") private var groupSize = 10
    @AppStorage("startDeck") private var startDeck = ""
    @Environment(\.windowSize) private var size
    @AppStorage("lang") private var lang = AppLanguage.zh
    @AppStorage("accent") private var accent = Accent.moss
    @State private var importing = false
    @State private var reimportTarget: UUID?
    @State private var showSettings = false
    @State private var error: String?

    private var l: L { L(lang: lang) }
    private let cols = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("MyVocab").font(.custom("Didot", size: 30)).foregroundStyle(Color.ink)
                if !size.narrow {
                    Text(l["home.subtitle"]).font(.system(size: 13)).foregroundStyle(Color.muted)
                }
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 15)).frame(width: 30, height: 30).touchTarget(.trailing)
                }
                .buttonStyle(.plain).foregroundStyle(Color.muted).help(l["settings"]).accessibilityLabel(l["settings"])
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.bottom, 24)

            PageScroll {
                VStack(alignment: .leading, spacing: 28) {
                    #if os(macOS)
                    UpdateBanner(l: l, accent: accent)
                    #endif
                    todaySummary
                    section(l["builtin"]) {
                        DeckTile(title: l["numbers.name"], detail: l["numbers.desc"], glyph: "123", accent: accent) {
                            route = .numbers
                        }
                    }
                    section(l["imported"]) {
                        ForEach(store.decks) { deck in
                            let p = progress.plan(deck, newPerDay: newPerDay, groupSize: groupSize)
                            let detailText: String = {
                                if p.groupQueue.isEmpty { return "\(deck.cards.count) \(l["cards"]) · \(l["today.clear"])" }
                                if !p.due.isEmpty {
                                    return "\(l["stat.due"]) \(p.due.count) · \(l["group.nextInfo"]) \(p.groupQueue.count) \(l["group.words"])"
                                }
                                return "\(l["group.nextInfo"])：\(l["new"]) \(p.groupNew.count) · \(l["stat.unseen"]) \(p.unseenCount)"
                            }()
                            DeckTile(title: deck.displayName, detail: detailText, glyph: deck.glyph, accent: accent,
                                     progress: deck.cards.isEmpty ? nil : Double(deck.cards.count - p.unseenCount) / Double(deck.cards.count)) {
                                route = .overview(deck)
                            }
                            .contextMenu {
                                Button(l["reimport"]) { reimportTarget = deck.id; importing = true }
                                Button(l["delete"], role: .destructive) { if store.delete(deck) { progress.forget(deck) } }
                            }
                        }
                        ImportTile(title: l["import"], detail: l["import.desc"], accent: accent) { importing = true }
                    }
                }
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: 1200)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, size.gutter).padding(.top, size.top)
        .fileImporter(isPresented: $importing, allowedContentTypes: [
            UTType(filenameExtension: "apkg") ?? .data,
            .commaSeparatedText, .tabSeparatedText, .plainText
        ]) { result in
            guard case .success(let url) = result else { return }
            let target = reimportTarget
            reimportTarget = nil
            load(url, into: target)
        }
        .onOpenURL { url in
            guard ["lexikos", "myvocab"].contains(url.scheme ?? "") else { return load(url, into: nil) }
            if url.host == "study", let d = store.decks.first(where: { $0.id.uuidString == startDeck }) ?? store.decks.first {
                route = .study(d)
            }
        }
        .alert(l["import.failed"], isPresented: .constant(error != nil)) {
            Button(l["ok"]) { error = nil }
        } message: { Text(error ?? "") }
        .sheet(isPresented: $showSettings) {
            settings
                .overlay(alignment: .topTrailing) {
                    Button { showSettings = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(Color.muted).padding(14)
                        .keyboardShortcut(.cancelAction).accessibilityLabel(l["ok"])
                }
        }
    }

    private func load(_ url: URL, into target: UUID?) {
        Task { @MainActor in
            do { try await store.loadFile(url, replacing: target) }
            catch let e as ImportError {
                error = l[["anki21b": "err.anki21b", "empty": "err.empty"]["\(e)"] ?? "err.unreadable"]
            } catch { self.error = error.localizedDescription }
        }
    }

    private var settings: some View {
        #if os(macOS)
        SettingsView().environment(updater).environment(store).environment(progress).frame(width: 540, height: 640)
        #else
        SettingsView().environment(store).environment(progress).presentationBackground(Color.bg)
        #endif
    }

    private var todaySummary: some View {
        let plans = store.decks.map { progress.plan($0, newPerDay: newPerDay, groupSize: groupSize) }
        let due = plans.map(\.due.count).reduce(0, +), new = plans.map(\.new.count).reduce(0, +)
        let done = plans.map(\.learnedToday).reduce(0, +)
        let heading = VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(Locale(identifier: lang.rawValue))))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted)
            Text(due + new == 0 ? l["today.clear"] : l["today.plan"])
                .font(.system(size: 24, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
        }
        .fixedSize()
        let numbers = HStack(spacing: 26) {
            ForEach([(l["stat.due"], due, Color.neg), (l["today.new"], new, accent.color), (l["stat.today"], done, Color.pos)], id: \.0) { k, v, c in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(v)").font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(Color.ink).monospacedDigit()
                        .lineLimit(1).fixedSize()
                    HStack(spacing: 5) {
                        Circle().fill(c).frame(width: 6, height: 6)
                        Text(k).font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(1).fixedSize()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                heading
                Spacer(minLength: 12)
                numbers
                startPanel.frame(width: 280)
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) { heading; Spacer(minLength: 16); numbers }
                startPanel
            }
            VStack(alignment: .leading, spacing: 16) { heading; numbers; startPanel }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LinearGradient(
                colors: [Color.warm.opacity(0.22), accent.faint, Color.cool.opacity(0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.panel))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.lineSoft))
        .shadow(color: Color.shade.opacity(0.06), radius: 16, y: 10)
    }

    @ViewBuilder private var startPanel: some View {
        if let chosen = store.decks.first(where: { $0.id.uuidString == startDeck }) ?? store.decks.first {
            let p = progress.plan(chosen, newPerDay: newPerDay, groupSize: groupSize)
            VStack(spacing: 10) {
                Menu {
                    ForEach(store.decks) { d in
                        Button { startDeck = d.id.uuidString } label: {
                            if d.id == chosen.id { Label(d.displayName, systemImage: "checkmark") }
                            else { Text(d.displayName) }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(chosen.glyph)
                            .font(.custom("Didot", size: 16)).foregroundStyle(accent.color)
                            .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(accent.soft))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chosen.displayName)
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
                            Text("\(l["group.nextInfo"])：\(l["review"]) \(p.groupDue.count) · \(l["new"]) \(p.groupNew.count)")
                                .font(.system(size: 11.5)).foregroundStyle(Color.muted).monospacedDigit().lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.muted)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.line))
                    .contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .help(l["start.from"]).accessibilityLabel(l["start.from"])

                Button { route = .study(chosen) } label: {
                    let btnText = p.due.isEmpty && p.learnedToday > 0 ? l["start.nextGroup"] : l["start.group"]
                    Label(btnText, systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.primary, accent))
                .keyboardShortcut(.defaultAction)
                .disabled(p.groupQueue.isEmpty)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: title)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 16) { content() }
        }
    }
}

struct DeckTile: View {
    let title: String, detail: String, glyph: String, accent: Accent
    var progress: Double?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(glyph).font(.custom("Didot", size: 22)).foregroundStyle(accent.color)
                    .frame(width: 48, height: 48).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.soft))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit().lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let progress {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.well)
                            Capsule().fill(accent.fill).frame(width: max(3, 140 * progress))
                        }
                        .frame(width: 140, height: 4).padding(.top, 2)
                        .accessibilityLabel("\(Int(progress * 100))%")
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.faint)
                    .opacity(hover ? 1 : 0.5)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.panel))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(hover ? accent.fill : Color.lineSoft))
            .shadow(color: Color.shade.opacity(hover ? 0.09 : 0.05), radius: hover ? 16 : 10, y: hover ? 8 : 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .accessibilityElement(children: .combine)
    }
}

struct ImportTile: View {
    let title: String, detail: String, accent: Accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(Color.muted)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.line, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @AppStorage("lang") private var lang = AppLanguage.zh
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage("accent") private var accent = Accent.moss
    @AppStorage("newPerDay") private var newPerDay = 20
    @AppStorage("groupSize") private var groupSize = 10
    @AppStorage("autoSpeak") private var autoSpeak = true
    @Environment(DeckStore.self) private var store: DeckStore?
    @Environment(ProgressStore.self) private var progress: ProgressStore?
    private var l: L { L(lang: lang) }

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 22) {
                Text(l["settings"]).font(.custom("Didot", size: 26)).foregroundStyle(Color.ink)

                group(l["sec.look"]) {
                    row(l["mode"]) {
                        HStack(spacing: 6) {
                            ForEach(Appearance.allCases) { a in
                                Chip(title: l[a.rawValue], icon: a.icon, selected: appearance == a, accent: accent) { appearance = a }
                            }
                        }
                    }
                    divider
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(l["accent"]).font(.system(size: 13)).foregroundStyle(Color.ink)
                            Spacer()
                            Text(accent.name(lang)).font(.system(size: 12)).foregroundStyle(Color.muted)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(Accent.choices) { a in paletteTile(a) }
                        }
                    }
                    .padding(.vertical, 12)
                }

                group(l["sec.study"]) {
                    row(l["group.size"], l["settings.sub.group"]) {
                        NumberStepper(value: $groupSize, range: 1...200, presets: [5, 10, 15, 20, 30], label: l["group.size"])
                    }
                    divider
                    row(l["newPerDay"], l["settings.sub.new"]) {
                        NumberStepper(value: $newPerDay, range: 1...500, presets: [5, 10, 20, 30, 50], label: l["newPerDay"])
                    }
                    divider
                    row(l["autoSpeak"], l["settings.sub.speak"]) { PaperToggle(isOn: $autoSpeak, label: l["autoSpeak"], accent: accent) }
                }

                group(l["sec.general"]) {
                    row(l["language"]) {
                        HStack(spacing: 6) {
                            ForEach(AppLanguage.allCases) { g in Chip(title: g.label, selected: lang == g, accent: accent) { lang = g } }
                        }
                    }
                    #if os(macOS)
                    divider
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l["update"]).font(.system(size: 13)).foregroundStyle(Color.ink)
                        UpdateSettings(l: l)
                    }
                    .padding(.vertical, 12)
                    #endif
                }

                group(l["sec.data"]) { dataRows }
            }
            .padding(28)
        }
        .background(AmbientBackground())
    }

    @ViewBuilder private var dataRows: some View {
        let path = Runtime.current.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l["data.location"]).font(.system(size: 13)).foregroundStyle(Color.ink)
                Spacer()
                #if os(macOS)
                Button(l["data.reveal"]) { NSWorkspace.shared.activateFileViewerSelecting([Runtime.current.root]) }
                    .buttonStyle(.capsule(.secondary, accent))
                #endif
            }
            Text(path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.muted)
                .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            if let store {
                let cards = store.decks.map(\.cards.count).reduce(0, +)
                let studied = progress.map { p in store.decks.map { p.states($0).count }.reduce(0, +) } ?? 0
                Text(String(format: l["data.summary"], store.decks.count, cards, studied))
                    .font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit()
            }
        }
        .padding(.vertical, 12)
        divider
        row(l["sync"]) {
            HStack(spacing: 6) {
                Circle().fill(syncState.1).frame(width: 7, height: 7)
                Text(syncState.0).font(.system(size: 12)).foregroundStyle(Color.muted).multilineTextAlignment(.trailing)
            }
        }
    }

    private var syncState: (String, Color) {
        if Runtime.current.isolated { return (l["sync.isolated"], Color.faint) }
        #if CLOUDKIT
        return Runtime.current.syncEnabled ? (l["sync.on"], Color.pos) : (l["sync.isolated"], Color.faint)
        #else
        return (l["sync.unavailable"], Color.warn)
        #endif
    }

    private func paletteTile(_ a: Accent) -> some View {
        let p = a.palette, on = accent.resolved == a
        return Button { accent = a } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(Array(p.swatches.enumerated()), id: \.offset) { _, c in Color(PlatformColor(hex: c)) }
                }
                .frame(height: 22).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(a.name(lang)).font(.system(size: 11.5, weight: on ? .semibold : .regular)).foregroundStyle(Color.ink).lineLimit(1)
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? accent.faint : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? accent.fill : Color.lineSoft, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(a.name(lang))
        .accessibilityLabel(a.name(lang))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var divider: some View { Rectangle().fill(Color.lineSoft).frame(height: 1) }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { c() }
                .padding(.horizontal, 16)
                .paperCard(radius: 14)
        }
    }

    private func row<C: View>(_ title: String, _ sub: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Color.ink)
                if let sub { Text(sub).font(.system(size: 11.5)).foregroundStyle(Color.muted) }
            }
            Spacer(minLength: 8)
            c()
        }
        .padding(.vertical, 11)
    }
}
