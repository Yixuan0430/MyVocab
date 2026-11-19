import SwiftUI

struct PracticeSoftPill: View {
    let title: String
    let icon: String
    let accent: Accent
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .buttonStyle(.capsule(.soft, accent)).focusable(false)
    }
}

struct PracticeHeaderBar: View {
    let isNumbers: Bool
    let isStudy: Bool
    let isFree: Bool
    let deck: Deck?
    @Binding var level: Level
    let accent: Accent
    let l: L
    let narrow: Bool
    let finished: Bool
    let settingUpFree: Bool
    let groupIndex: Int
    let counts: (review: Int, learning: Int, new: Int)
    let remainingStudy: Int
    let remainingFree: Int
    let freeTotal: Int
    let onBack: () -> Void
    let onLevelChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Label(l["back"], systemImage: "chevron.left").font(.system(size: 13)).touchTarget(.leading)
                }
                .buttonStyle(.plain).focusable(false).foregroundStyle(Color.muted).fixedSize().accessibilityLabel(l["back"])
                Spacer()
                if isNumbers {
                    HStack(spacing: 4) {
                        ForEach(Level.allCases) { lv in
                            Chip(title: lv.label, selected: level == lv, accent: accent) { level = lv }
                        }
                    }
                    .padding(3).background(Capsule().fill(Color.panel)).overlay(Capsule().strokeBorder(Color.lineSoft))
                    .onChange(of: level) { onLevelChange() }
                } else if let d = deck {
                    if !(narrow && isStudy && !finished) {
                        Text(d.displayName)
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted).lineLimit(1)
                    }
                    if isStudy && !finished {
                        if narrow {
                            HStack(spacing: 6) {
                                Text("\(l["group.label"]) #\(groupIndex)")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted).fixedSize()
                                Text("(\(l["remaining"]) \(remainingStudy))")
                                    .font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit().fixedSize()
                            }
                        } else {
                            HStack(spacing: 10) {
                                Text("· \(l["group.label"]) #\(groupIndex)")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted).fixedSize()
                                studyBadges
                                Text("(\(l["remaining"]) \(remainingStudy))")
                                    .font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit().fixedSize()
                            }
                        }
                    } else if isFree && !settingUpFree && !finished {
                        Text("· \(l["remaining"]) \(remainingFree) / \(freeTotal)")
                            .font(.system(size: 13)).foregroundStyle(Color.muted).monospacedDigit().fixedSize()
                    }
                }
            }
            if narrow && isStudy && !finished && deck != nil {
                studyBadges.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var studyBadges: some View {
        HStack(spacing: 6) {
            badgeCount(counts.review, color: Color.pos, label: l["badge.review"])
            badgeCount(counts.learning, color: Color.warn, label: l["badge.learning"])
            badgeCount(counts.new, color: accent.fill, label: l["badge.new"])
        }
    }

    private func badgeCount(_ n: Int, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 12)).foregroundStyle(Color.muted)
            Text("\(n)").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.panel)).overlay(Capsule().strokeBorder(Color.lineSoft))
        .opacity(n == 0 ? 0.55 : 1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

struct FreeSetupPanel: View {
    let deck: Deck
    let accent: Accent
    let l: L
    @Binding var freeCount: Int
    let onStart: () -> Void

    var body: some View {
        let total = max(1, deck.cards.count)
        let basePresets = [10, 20, 30, 50, 100].filter { $0 < total }
        VStack(spacing: 22) {
            Image(systemName: "shuffle.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(accent.color)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(l["free.setup.title"])
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .foregroundStyle(Color.ink)
                Text("\(l["free.setup.sub"])（\(total) \(l["cards"])）")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text(l["free.count"])
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.muted)

                HStack(spacing: 8) {
                    ForEach(basePresets, id: \.self) { p in
                        Chip(title: "\(p)", selected: freeCount == p, accent: accent) { freeCount = p }.focusable(false)
                    }
                    Chip(title: "\(l["free.all"]) (\(total))", selected: freeCount == total, accent: accent) { freeCount = total }.focusable(false)
                }

                HStack(spacing: 8) {
                    Text(l["custom"])
                        .font(.system(size: 13))
                        .foregroundStyle(Color.muted)
                    Spacer()
                    stepButton("-10") { freeCount = min(max(1, freeCount - 10), total) }
                    stepButton("−") { freeCount = min(max(1, freeCount - 1), total) }
                    Text("\(min(max(1, freeCount), total))")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .monospacedDigit()
                        .foregroundStyle(Color.ink)
                        .frame(minWidth: 52)
                        .padding(.vertical, 5).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.well))
                    stepButton("+") { freeCount = min(max(1, freeCount + 1), total) }
                    stepButton("+10") { freeCount = min(max(1, freeCount + 10), total) }
                }
            }
            .padding(20)
            .frame(maxWidth: 440)
            .paperCard(radius: 18)

            Button(action: onStart) {
                Label("\(l["free.start"])（\(min(max(1, freeCount), total)) \(l["group.words"])）", systemImage: "play.fill")
            }
            .buttonStyle(.capsule(.primary, accent, large: true))
            .focusable(false)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 32)
                .padding(.vertical, 6).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.well))
                .foregroundStyle(Color.ink)
        }
        .buttonStyle(.plain).focusable(false)
    }
}

struct CardDetailsPanel: View {
    let parts: CardParts
    let accent: Accent
    let l: L
    let scale: CGFloat
    let windowHeight: CGFloat
    @Binding var section: String
    let onSpeak: (String, Bool) -> Void

    private var currentSection: CardParts.Section? {
        parts.sections.first { $0.id == section } ?? parts.sections.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SnapshotSafeScroll(axis: .horizontal) {
                HStack(spacing: 4) {
                    ForEach(parts.sections) { s in
                        let on = s.id == (currentSection?.id ?? "")
                        Button { section = s.id } label: {
                            Text(s.category == .other ? s.title : l["cat.\(s.category.rawValue)"])
                                .font(.system(size: 12, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(on ? accent.soft : .clear))
                                .foregroundStyle(on ? accent.color : Color.muted)
                        }
                        .buttonStyle(.plain).focusable(false)
                    }
                }
                .padding(10)
            }
            Rectangle().fill(Color.lineSoft).frame(height: 1)
            SnapshotSafeScroll(axis: .vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array((currentSection?.items ?? []).enumerated()), id: \.offset) { _, item in
                        noteLine(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxHeight: max(140, windowHeight * 0.36))
        }
        .frame(maxWidth: 640 * scale)
        .paperCard(radius: 14)
        .padding(.top, 6)
        .onTapGesture {}
    }

    private func noteLine(_ item: CardParts.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let fr = item.fr {
                let speakButton = Button { onSpeak(fr, false) } label: {
                    Image(systemName: "speaker.wave.1").font(.system(size: 11))
                }
                .buttonStyle(.plain).focusable(false).foregroundStyle(Color.muted).accessibilityLabel(l["listen"])
                #if os(macOS)
                speakButton.simultaneousGesture(TapGesture().modifiers(.option).onEnded { onSpeak(fr, true) })
                #else
                speakButton.simultaneousGesture(LongPressGesture().onEnded { _ in onSpeak(fr, true) })
                #endif
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fr ?? item.text).font(.system(size: item.fr == nil ? 14 : 15))
                    .foregroundStyle(item.fr == nil ? Color.ink.opacity(0.85) : Color.ink)
                    .lineSpacing(3)
                if let g = item.gloss { Text(g).font(.system(size: 13)).foregroundStyle(Color.muted) }
            }
            .textSelection(.enabled)
        }
    }
}

struct PracticeLearnBar: View {
    let accent: Accent
    let l: L
    let onContinue: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Label(l["learn.badge"], systemImage: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(accent.color)
            Spacer()
            Button(action: onContinue) { Text(l["learn.continue"]) }
                .buttonStyle(.capsule(.primary, accent, large: true)).focusable(false)
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .frame(maxWidth: 560)
        .paperCard(radius: 16)
    }
}

struct PracticeGradeBar: View {
    let accent: Accent
    let l: L
    let preview: (Grade) -> String
    let onGrade: (Grade) -> Void

    var body: some View {
        #if os(iOS)
        let (title, sub, dot, pad, keys): (CGFloat, CGFloat, CGFloat, CGFloat, Bool) = (18, 14, 10, 30, false)
        #else
        let (title, sub, dot, pad, keys): (CGFloat, CGFloat, CGFloat, CGFloat, Bool) = (14, 11, 8, 10, true)
        #endif
        HStack(spacing: 12) {
            ForEach(Grade.allCases, id: \.self) { g in
                Button { onGrade(g) } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(gradeColor(g)).frame(width: dot, height: dot)
                            Text(l["grade.\(g)"]).font(.system(size: title, weight: .medium)).foregroundStyle(Color.ink)
                            if keys { Text("\(g.rawValue)").font(.system(size: 11)).foregroundStyle(Color.muted) }
                        }
                        Text(preview(g)).font(.system(size: sub)).foregroundStyle(Color.muted)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, pad)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.panel))
                    .overlay(alignment: .top) { Capsule().fill(gradeColor(g)).frame(height: 3).padding(.horizontal, 28) }
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.lineSoft))
                    .shadow(color: Color.shade.opacity(0.05), radius: 8, y: 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusable(false)
                .accessibilityLabel("\(l["grade.\(g)"])，\(preview(g))")
            }
        }
        .frame(maxWidth: 560)
    }
}

struct PracticeDonePanel: View {
    let isFree: Bool
    let freeTotal: Int
    let hasDeck: Bool
    let groupIndex: Int
    let reviewedCount: Int
    let newLearned: Int
    let tally: [Grade: Int]
    let nextPlan: ProgressStore.Plan?
    let accent: Accent
    let l: L
    let onFreeAgain: () -> Void
    let onNextGroup: () -> Void
    let onOverview: () -> Void
    let onFreeMode: () -> Void

    var body: some View {
        if isFree {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(accent.color)
                Text(l["free.done.title"]).font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
                Text("\(freeTotal) \(l["cards"])")
                    .font(.system(size: 14)).foregroundStyle(Color.muted).monospacedDigit()
                HStack(spacing: 12) {
                    Button(action: onFreeAgain) { Label(l["free.again"], systemImage: "shuffle") }
                        .buttonStyle(.capsule(.primary, accent)).focusable(false)
                    PracticeSoftPill(title: l["back.overview"], icon: "chart.xyaxis.line", accent: accent, action: onOverview)
                }
                .padding(.top, 6)
            }
        } else {
            let hasMore = !(nextPlan?.groupQueue.isEmpty ?? true)
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(accent.color)
                Text(hasMore ? "\(l["group.done"]) (#\(groupIndex))" : l["done.title"])
                    .font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(Color.ink)

                HStack(spacing: 20) {
                    if reviewedCount > 0 {
                        Text("\(l["review"]) \(reviewedCount)").font(.system(size: 13)).foregroundStyle(Color.muted)
                    }
                    if newLearned > 0 {
                        Text("\(l["new"]) \(newLearned)").font(.system(size: 13)).foregroundStyle(Color.muted)
                    }
                    ForEach(Grade.allCases, id: \.self) { g in
                        HStack(spacing: 6) {
                            Circle().fill(gradeColor(g)).frame(width: 8, height: 8)
                            Text("\(l["grade.\(g)"]) \(tally[g] ?? 0)").font(.system(size: 13)).foregroundStyle(Color.muted)
                        }
                    }
                }

                if let np = nextPlan, hasMore {
                    VStack(spacing: 12) {
                        if !np.due.isEmpty {
                            Text("\(l["stat.due"]) \(np.due.count) · \(l["group.nextInfo"])：\(l["review"]) \(np.groupDue.count)" +
                                 (np.groupNew.count > 0 ? " + \(l["new"]) \(np.groupNew.count)" : ""))
                                .font(.system(size: 13)).foregroundStyle(Color.muted)
                        } else {
                            Text("\(l["group.reviewsClear"])（\(l["stat.unseen"]) \(np.unseenCount)）")
                                .font(.system(size: 13)).foregroundStyle(Color.muted)
                        }

                        Button(action: onNextGroup) {
                            let labelText = !np.groupDue.isEmpty
                                ? "\(l["group.next"])（\(l["review"]) \(np.groupDue.count)\(np.groupNew.count > 0 ? " · \(l["new"]) \(np.groupNew.count)" : "")）"
                                : "\(l["group.next.new"])（\(np.groupNew.count) \(l["group.words"])）"
                            Label(labelText, systemImage: "play.fill")
                        }
                        .buttonStyle(.capsule(.primary, accent, large: true)).focusable(false)
                    }
                    .padding(.top, 4)
                }

                HStack(spacing: 10) {
                    PracticeSoftPill(title: l["back.overview"], icon: "chart.xyaxis.line", accent: accent, action: onOverview)
                    if hasDeck {
                        PracticeSoftPill(title: l["free"], icon: "shuffle", accent: accent, action: onFreeMode)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
