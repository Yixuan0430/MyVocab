import SwiftUI

@main
struct LexikosApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = DeckStore()
    @State private var progress = ProgressStore()
    @AppStorage("lang", store: Runtime.current.defaults) private var lang = AppLanguage.zh
    @AppStorage("appearance", store: Runtime.current.defaults) private var appearance = Appearance.system

    init() { AppTheme.shared.load(from: Runtime.current.defaults) }

    var body: some Scene {
        WindowGroup {
            RootView()
                .defaultAppStorage(Runtime.current.defaults)
                .environment(\.locale, Locale(identifier: lang.rawValue))
                .environment(store)
                .environment(progress)
                .preferredColorScheme(appearance.scheme)
                .cloudSync(decks: store, progress: progress)
                .widgetFeed(decks: store, progress: progress)
        }
    }
}

/// CloudKit announces changes from other devices with silent pushes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if Runtime.current.syncEnabled { application.registerForRemoteNotifications() }
        return true
    }
}
