import SwiftUI

@main
struct LexikosApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = DeckStore()
    @State private var progress = ProgressStore()
    @State private var updater = Updater()
    @AppStorage("lang", store: Runtime.current.defaults) private var lang = AppLanguage.systemDefault
    @AppStorage("appearance", store: Runtime.current.defaults) private var appearance = Appearance.system.rawValue

    init() {
        AppTheme.shared.load(from: Runtime.current.defaults)
        if CommandLine.arguments.contains("--learning-report") {
            do { try LearningReport.write(decks: store, progress: progress); exit(0) }
            catch { fputs("学习报告失败: \(error)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--dump") {
            for n in 0...9999 { let e = FrenchNumbers.entry(n); print("\(n)\t\(e.word)\t/\(e.ipa)/") }
            exit(0)
        }
        if CommandLine.arguments.contains("--parse") {
            for d in DeckStore().decks {
                for c in d.cards {
                    let p = CardParts(c)
                    print("\(p.front) [\(p.tag ?? "")] → \(p.answer) | \(p.sections.map { "\($0.id)(\($0.items.count))" }.joined(separator: ", "))")
                    for sec in p.sections {
                        for it in sec.items {
                            print("   \(sec.id): \(it.fr.map { "FR[\($0)] EN[\(it.gloss ?? "")]" } ?? "TXT[\(it.text)]")")
                        }
                    }
                }
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--verify-signature"), i + 1 < CommandLine.arguments.count {
            print(MainActor.assumeIsolated { Updater.signedByUs(URL(fileURLWithPath: CommandLine.arguments[i + 1])) } ? "trusted" : "rejected")
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
            let cards = (try? Importer.anki(URL(fileURLWithPath: CommandLine.arguments[i + 1]))) ?? []
            print(cards.count, "cards")
            let limit = CommandLine.arguments.last.flatMap(Int.init) ?? 4
            for c in cards.prefix(limit) {
                let p = CardParts(c)
                print("── \(p.front) [\(p.tag ?? "")] /\(p.hint)/ → \(p.answer)")
                for s in p.sections { for it in s.items { print("     \(s.id): \(it.fr ?? it.text)  ⟶ \(it.gloss ?? "")") } }
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--reimport"), i + 2 < CommandLine.arguments.count {
            guard let id = UUID(uuidString: CommandLine.arguments[i + 1]) else {
                fputs("failed: invalid deck UUID\n", stderr)
                exit(1)
            }
            do {
                try DeckStore().reimport(id, from: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
                print("reimported")
            } catch {
                fputs("failed: \(error)\n", stderr)
                exit(1)
            }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--import"), i + 1 < CommandLine.arguments.count {
            do {
                try DeckStore().importFile(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                print("imported")
            } catch {
                fputs("failed: \(error)\n", stderr)
                exit(1)
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("MyVocab") {
            RootView()
                .defaultAppStorage(Runtime.current.defaults)
                .environment(\.locale, Locale(identifier: lang.rawValue))
                .environment(store)
                .environment(progress)
                .environment(updater)
                .task { await updater.checkIfDue() }
                .cloudSync(decks: store, progress: progress)
                .widgetFeed(decks: store, progress: progress)
                .frame(minWidth: 480, minHeight: 520)
                .onAppear { (Appearance(rawValue: appearance) ?? .system).apply() }
                .onChange(of: appearance) { (Appearance(rawValue: appearance) ?? .system).apply() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 600)

        Settings {
            SettingsView()
                .defaultAppStorage(Runtime.current.defaults)
                .environment(\.locale, Locale(identifier: lang.rawValue))
                .environment(updater).environment(store).environment(progress)
                .frame(width: 540, height: 640)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        if Runtime.current.syncEnabled { NSApplication.shared.registerForRemoteNotifications() }
    }
}
