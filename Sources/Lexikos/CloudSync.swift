import SwiftUI

extension View {
    func cloudSync(decks: DeckStore, progress: ProgressStore) -> some View {
        modifier(CloudSyncModifier(decks: decks, progress: progress))
    }
}

private struct CloudSyncModifier: ViewModifier {
    let decks: DeckStore
    let progress: ProgressStore
    @Environment(\.scenePhase) private var phase
    #if CLOUDKIT
    @State private var sync: Sync?
    @State private var settings: SettingsSync?
    #endif

    func body(content: Content) -> some View {
        #if CLOUDKIT
        content
            .task {
                guard Runtime.current.syncEnabled, sync == nil else { return }
                settings = SettingsSync()
                sync = Sync(decks: decks, progress: progress)
                await sync?.syncNow()
            }
            .onChange(of: phase) {
                if phase == .active { Task { await sync?.syncNow() } }
            }
        #else
        content
        #endif
    }
}
