import SwiftUI

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var snapshotting: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

struct PageScroll<Content: View>: View {
    @Environment(\.snapshotting) private var snapshotting
    @ViewBuilder var content: Content
    var body: some View {
        if snapshotting { VStack { content; Spacer(minLength: 0) }.frame(maxHeight: .infinity, alignment: .top).clipped() }
        else { ScrollView { content }.scrollIndicators(.never) }
    }
}

struct SnapshotSafeScroll<Content: View>: View {
    let axis: Axis.Set
    @Environment(\.snapshotting) private var snapshotting
    @ViewBuilder var content: Content
    var body: some View {
        if snapshotting {
            if axis == .horizontal {
                content.hidden().frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) { content.fixedSize(horizontal: true, vertical: false) }
                    .clipped()
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            }
        } else {
            ScrollView(axis) { content }.scrollIndicators(.never)
        }
    }
}
