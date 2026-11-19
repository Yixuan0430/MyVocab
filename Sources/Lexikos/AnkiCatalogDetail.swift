import SwiftUI

enum CatalogDownloadState: Equatable {
    case idle
    case downloading(received: Int64, expected: Int64)
    case importing
    case imported(Deck)
    case failed(String)
}

struct AnkiCatalogDetailPanel: View {
    let summary: AnkiWebDeckSummary?
    let detail: AnkiWebDeckDetail?
    let loading: Bool
    let loadError: String?
    let languageBadge: String?
    let isFeatured: Bool
    let downloadState: CatalogDownloadState
    let accent: Accent
    let l: CatalogL
    let onRetryLoad: () -> Void
    let onDownload: (AnkiWebDeckDetail) -> Void
    let onCancelDownload: () -> Void
    let onOpenDeck: (Deck) -> Void

    var body: some View {
        Group {
            if loading && detail == nil {
                loadingState
            } else if let loadError, detail == nil {
                errorState(loadError)
            } else if let detail {
                detailContent(detail)
            } else if let summary {
                summaryPlaceholder(summary)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 40)
            Image(systemName: "books.vertical")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.faint)
            Text(l["empty.select"])
                .font(.system(size: 13))
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .paperCard(radius: 18)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 48)
            ProgressView()
                .controlSize(.regular)
            Text(l["loading.detail"])
                .font(.system(size: 13))
                .foregroundStyle(Color.muted)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .paperCard(radius: 18)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.warn)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button(l["action.retry"], action: onRetryLoad)
                .buttonStyle(.capsule(.secondary, accent))
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .paperCard(radius: 18)
    }

    private func summaryPlaceholder(_ summary: AnkiWebDeckSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary.title)
                .font(.system(size: 19, weight: .medium, design: .serif))
                .foregroundStyle(Color.ink)
            ProgressView()
                .controlSize(.small)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(radius: 18)
    }

    private func detailContent(_ detail: AnkiWebDeckDetail) -> some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                headerSection(detail)
                metaGrid(detail)
                actionSection(detail)
                if !detail.sampleNotes.isEmpty {
                    samplesSection(detail.sampleNotes)
                }
                if !detail.description.isEmpty {
                    descriptionSection(detail.description)
                }
            }
            .padding(22)
        }
        .paperCard(radius: 18)
    }

    private func headerSection(_ detail: AnkiWebDeckDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let badge = languageBadge {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(accent.soft))
                        .foregroundStyle(accent.color)
                }
                if isFeatured {
                    Label(l["badge.featured"], systemImage: "sparkles")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.warm.opacity(0.24)))
                        .foregroundStyle(Color.ink)
                }
                Spacer(minLength: 4)
                Link(destination: detail.pageURL) {
                    Label(l["detail.openWeb"], systemImage: "arrow.up.right.square")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.muted)
                }
                .buttonStyle(.plain)
            }
            Text(detail.title)
                .font(.system(size: 20, weight: .medium, design: .serif))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.tags.isEmpty {
                Text(detail.tags)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.muted)
                    .lineLimit(2)
            }
        }
    }

    private func metaGrid(_ detail: AnkiWebDeckDetail) -> some View {
        let cols = [GridItem(.adaptive(minimum: 104), spacing: 8)]
        let sizeText = detail.sizeBytes > 0
            ? ByteCountFormatter.string(fromByteCount: detail.sizeBytes, countStyle: .file)
            : "—"
        let updatedText = detail.lastUpdated.timeIntervalSince1970 > 0
            ? detail.lastUpdated.formatted(date: .abbreviated, time: .omitted)
            : "—"
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            metaTile(
                title: l["meta.audio"],
                value: detail.hasAudio ? "\(detail.audio.formatted())" : l["meta.none"],
                icon: detail.hasAudio ? "speaker.wave.2.fill" : "speaker.slash",
                highlight: detail.hasAudio
            )
            metaTile(
                title: l["meta.images"],
                value: detail.hasImages ? "\(detail.images.formatted())" : l["meta.none"],
                icon: detail.hasImages ? "photo.fill" : "photo",
                highlight: detail.hasImages
            )
            metaTile(title: l["meta.notes"], value: "\(detail.notes.formatted())", icon: "rectangle.stack", highlight: false)
            metaTile(title: l["meta.size"], value: sizeText, icon: "doc.zipper", highlight: false)
            metaTile(
                title: l["meta.rating"],
                value: "+\(detail.thumbsUp) / -\(detail.thumbsDown)",
                icon: "hand.thumbsup",
                highlight: false
            )
            metaTile(title: l["meta.updated"], value: updatedText, icon: "calendar", highlight: false)
        }
    }

    private func metaTile(title: String, value: String, icon: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(highlight ? accent.color : Color.faint)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.muted)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(highlight ? accent.color : Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(highlight ? accent.faint : Color.well))
    }

    private func actionSection(_ detail: AnkiWebDeckDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch downloadState {
            case .idle:
                Button { onDownload(detail) } label: {
                    Label(l["action.download"], systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.capsule(.primary, accent, large: true))
            case .downloading(let received, let expected):
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(l["action.downloading"])
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.ink)
                        Spacer()
                        Text(progressLabel(received: received, expected: expected > 0 ? expected : detail.sizeBytes))
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Color.muted)
                        Button(l["action.cancel"], action: onCancelDownload)
                            .buttonStyle(.capsule(.secondary, accent))
                    }
                    let denom = expected > 0 ? expected : detail.sizeBytes
                    if denom > 0 {
                        ProgressView(value: min(1, Double(received) / Double(denom)))
                            .tint(accent.fill)
                    } else {
                        ProgressView().tint(accent.fill)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.well))
            case .importing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(l["action.importing"])
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ink)
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.well))
            case .imported(let deck):
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.pos)
                        Text("\(l["imported.ok"])（\(deck.cards.count)）")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }
                    Button { onOpenDeck(deck) } label: {
                        Label(l["action.openDeck"], systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.capsule(.primary, accent, large: true))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.pos.opacity(0.12)))
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.neg)
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { onDownload(detail) } label: {
                        Label(l["action.retry"], systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.capsule(.primary, accent))
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.neg.opacity(0.1)))
            }

            Text(l["detail.note"])
                .font(.system(size: 11))
                .foregroundStyle(Color.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func samplesSection(_ notes: [AnkiWebSampleNote]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: l["detail.samples"])
            ForEach(Array(notes.prefix(4).enumerated()), id: \.offset) { _, note in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(note.fields.prefix(4).enumerated()), id: \.offset) { idx, field in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if !field.name.isEmpty {
                                Text(field.name)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(Color.muted)
                                    .frame(width: 72, alignment: .leading)
                                    .lineLimit(1)
                            }
                            Text(field.value)
                                .font(.system(size: idx == 0 ? 13.5 : 12.5, weight: idx == 0 ? .medium : .regular))
                                .foregroundStyle(idx == 0 ? Color.ink : Color.muted)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.well))
            }
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: l["detail.description"])
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.muted)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressLabel(received: Int64, expected: Int64) -> String {
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard expected > 0 else { return got }
        let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        return "\(got) / \(total)"
    }
}

struct CatalogDeckRow: View {
    let deck: AnkiWebDeckSummary
    let selected: Bool
    let featured: Bool
    let accent: Accent
    let l: CatalogL
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(deck.title)
                        .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.ink)
                        .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if featured {
                        Text(l["badge.featured"]).font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.warm.opacity(0.24))).foregroundStyle(Color.ink)
                    }
                }
                HStack(spacing: 6) {
                    if deck.hasAudio {
                        mediaBadge(icon: "speaker.wave.2.fill", text: "\(l["badge.audio"]) \(deck.audio.formatted())", active: true)
                    }
                    if deck.hasImages {
                        mediaBadge(icon: "photo.fill", text: "\(l["badge.images"]) \(deck.images.formatted())", active: true)
                    }
                    if !deck.hasAudio && !deck.hasImages {
                        mediaBadge(icon: "text.alignleft", text: l["badge.textOnly"], active: false)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 10) {
                        Label("\(deck.notes.formatted())", systemImage: "rectangle.stack")
                        Label("\(deck.thumbsUp)", systemImage: "hand.thumbsup")
                        if deck.modified.timeIntervalSince1970 > 0 {
                            Text(deck.modified.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.muted)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? accent.faint : Color.panel))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? accent.fill : (hover ? Color.line : Color.lineSoft), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func mediaBadge(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(active ? accent.color : Color.muted)
        .background(Capsule().fill(active ? accent.soft : Color.well))
    }
}
