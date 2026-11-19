import SwiftUI

@MainActor enum Snapshot {
    static func run(to dir: URL) {
        precondition(Runtime.current.isolated, "Snapshots require isolated storage")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { fputs("Snapshot: \(error)\n", stderr); exit(1) }
        let store = DeckStore(), progress = ProgressStore()
        let env = ProcessInfo.processInfo.environment
        let theme = AppTheme.shared
        let savedAccent = theme.accent
        let modes: [Appearance] = (env["SNAPSHOT_MODES"]?.split(separator: ",").compactMap { Appearance(rawValue: String($0)) })
            ?? [.light, .dark, .warm]
        let accents: [Accent] = (env["SNAPSHOT_ACCENTS"]?.split(separator: ",").compactMap { Accent(rawValue: String($0)) }) ?? [savedAccent]
        let deck = store.decks.max { $0.cards.count < $1.cards.count }
        let card = deck.flatMap { d in d.cards.indices.first { CardParts(d.cards[$0]).sections.count >= 2 } } ?? 0

        for accent in accents {
            theme.accent = accent
            Runtime.current.defaults.set(accent.rawValue, forKey: "accent")
            for mode in modes {
                theme.appearance = mode
                let dark = mode == .dark
                let tag = accents.count > 1 ? "\(accent.rawValue)-\(mode.rawValue)" : mode.rawValue
                for size in [CGSize(width: 520, height: 680), CGSize(width: 820, height: 640), CGSize(width: 1400, height: 900)] {
                    var pages: [(String, AnyView, Bool)] = [("home", AnyView(HomeView(route: .constant(nil))), true)]
                    if let d = deck {
                        let s = { (p: PracticeView.Preset) in AnyView(PracticeView(source: .study(d), route: .constant(nil), preset: p)) }
                        pages += [
                            ("overview", AnyView(OverviewView(deck: d, route: .constant(nil))), true),
                            ("study-front", s(.init(index: card)), false),
                            ("study-revealed", s(.init(index: card, revealed: true)), false),
                            ("study-notes", s(.init(index: card, revealed: true, details: true)), false),
                            ("study-learning", s(.init(index: card, revealed: true, learning: true)), false),
                            ("study-done", s(.init(index: card, finished: true)), false),
                            ("free-setup", AnyView(PracticeView(source: .free(d), route: .constant(nil), preset: .init(index: card, free: true))), false),
                        ]
                    }
                    pages.append(("numbers", AnyView(PracticeView(source: .numbers, route: .constant(nil), preset: .init(index: 1987, revealed: true))), false))
                    if size.width == 820 { pages.append(("settings", AnyView(SettingsView().environment(store).environment(progress)), true)) }

                    for (name, page, long) in pages {
                        render(page, size: size, dark: dark, store: store, progress: progress,
                               to: dir.appendingPathComponent("\(tag)-\(name)-\(Int(size.width)).png"))
                        if long {
                            render(page, size: CGSize(width: size.width, height: name == "overview" ? (size.width < 700 ? 2600 : 2000) : 1300), dark: dark,
                                   store: store, progress: progress, to: dir.appendingPathComponent("\(tag)-\(name)-\(Int(size.width))-full.png"))
                        }
                    }
                }
            }
        }
        theme.accent = savedAccent
    }

    private static func render(_ page: AnyView, size: CGSize, dark: Bool, store: DeckStore, progress: ProgressStore, to url: URL) {
        let view = ZStack(alignment: .top) { AmbientBackground(); page }
            .defaultAppStorage(Runtime.current.defaults)
            .environment(\.windowSize, size).environment(\.snapshotting, true)
            .environment(store).environment(progress).environment(Updater())
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height, alignment: .top).clipped()
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let r = ImageRenderer(content: view)
            r.scale = 1
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
        }
    }
}
