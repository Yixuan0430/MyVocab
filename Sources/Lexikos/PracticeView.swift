import SwiftUI
import AVFoundation
import NaturalLanguage

struct PracticeView: View {
    enum Source { case numbers, free(Deck), study(Deck) }
    let source: Source
    @Binding var route: Route?

    @AppStorage("lang") private var lang = AppLanguage.zh
    @AppStorage("accent") private var accent = Accent.moss
    @AppStorage("level") private var level = Level.units
    @AppStorage("showDetails") private var showDetails = false
    @State private var card = Card(front: "", back: "")
    @State private var parts = CardParts(Card(front: "", back: ""))
    @State private var section = ""
    @State private var revealed = false
    @State private var seen = 0
    @State private var order: [Int] = []
    @FocusState private var focused: Bool
    @State private var speaker = Speaker()
    @AppStorage("autoSpeak") private var autoSpeak = true
    @State private var learning = false // first sight of a new word: shown with its answer
    @State private var newLearned = 0
    @State private var reviewedCount = 0
    @Environment(\.windowSize) private var size
    private var k: CGFloat { size.cardScale }
    @Environment(ProgressStore.self) private var progress
    @AppStorage("newPerDay") private var newPerDay = 20
    @AppStorage("groupSize") private var groupSize = 10
    @AppStorage("freeCount") private var freeCount = 20

    // Study session: remaining queue in current group, current card index, cards already graded once in this group.
    @State private var queue: [Int] = []
    @State private var current: Int?
    @State private var gradedOnce: Set<Int> = []
    @State private var tally: [Grade: Int] = [:]
    @State private var finished = false
    @State private var groupIndex = 1
    @State private var gradeTick = 0 // drives haptic feedback

    // Free practice setup state: asks user for word count before each free practice round.
    @State private var settingUpFree = false
    @State private var freeTotal = 0

    /// A frozen state for offscreen snapshots; nil in the app.
    struct Preset { var index: Int; var revealed = false, learning = false, details = false, finished = false, free = false }
    private var preset: Preset?

    init(source: Source, route: Binding<Route?>, preset: Preset? = nil) {
        self.source = source; _route = route; self.preset = preset
        guard let p = preset else { return }
        var c: Card?
        switch source {
        case .numbers:
            let e = FrenchNumbers.entry(p.index); c = Card(front: "\(p.index)", back: e.word, hint: "/\(e.ipa)/")
        case .study(let d):
            if d.cards.indices.contains(p.index) { c = d.cards[p.index] }
            _current = State(initialValue: p.index); _queue = State(initialValue: Array(d.cards.indices.prefix(9)))
        case .free(let d):
            if d.cards.indices.contains(p.index) { c = d.cards[p.index] }
            _freeTotal = State(initialValue: 20); _order = State(initialValue: Array(d.cards.indices.prefix(12)))
        }
        if let c {
            _card = State(initialValue: c); _parts = State(initialValue: CardParts(c))
            _section = State(initialValue: CardParts(c).sections.first?.id ?? "")
        }
        _revealed = State(initialValue: p.revealed); _learning = State(initialValue: p.learning)
        _showDetails = AppStorage(wrappedValue: p.details, "snapshot.details.\(p.details)")
        _finished = State(initialValue: p.finished); _settingUpFree = State(initialValue: p.free)
        _seen = State(initialValue: 7); _groupIndex = State(initialValue: 2)
        _tally = State(initialValue: [.forgot: 2, .vague: 3, .remembered: 5]); _newLearned = State(initialValue: 4)
        _reviewedCount = State(initialValue: 6)
    }

    private var l: L { L(lang: lang) }
    private var isNumbers: Bool { if case .numbers = source { true } else { false } }
    private var isStudy: Bool { if case .study = source { true } else { false } }
    private var isFree: Bool { if case .free = source { true } else { false } }
    private var deck: Deck? {
        switch source { case .numbers: nil; case .free(let d), .study(let d): d }
    }
    private var detailsOpen: Bool { revealed && showDetails && !parts.sections.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 16)
            VStack(spacing: 28) {
                if settingUpFree, let d = deck {
                    freeSetupView(d)
                } else if finished {
                    doneView
                } else {
                    #if os(iOS)
                    touchCard
                    #else
                    cardView
                    #endif
                }
                // The action bar sits right under the card instead of at the window's bottom edge.
                if isStudy && revealed && !finished && !settingUpFree {
                    Group { if learning { learnBar } else { gradeBar } }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            Spacer(minLength: 16)
            #if os(macOS)
            footer
            #endif
        }
        .padding(.horizontal, size.gutter).padding(.top, size.top).padding(.bottom, pageBottom)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear {
            if preset != nil { return }
            focused = true
            switch source {
            case .study:
                startGroup(resetGroupIndex: true)
            case .free(let d):
                freeCount = min(max(1, freeCount), max(1, d.cards.count))
                settingUpFree = true
            case .numbers:
                next()
            }
        }
        .onKeyPress("1") { grade(.forgot); return .handled }
        .onKeyPress("2") { grade(.vague); return .handled }
        .onKeyPress("3") { grade(.remembered); return .handled }
        .onKeyPress("a") { speak(slow: true); return .handled }
        .onKeyPress(.space) { advance(); return .handled }
        .onKeyPress(.return) { advance(); return .handled }
        .onKeyPress(.rightArrow) { if !settingUpFree && !finished { next() }; return .handled }
        .onKeyPress(.escape) { goBack(); return .handled }
        .onKeyPress("s") { speak(); return .handled }
        .onKeyPress("d") { toggleDetails(); return .handled }
        .sensoryFeedback(.impact(weight: .light), trigger: gradeTick)
        .overlay(alignment: .bottom) {
            if let error = speaker.lastError {
                Text("朗读失败：" + error).font(.callout).foregroundStyle(Color.ink).padding().paperCard(radius: 12).padding(.bottom, 60)
            }
        }
    }

    /// Touch controls: tap the card to reveal or continue; once revealed, swipe right for
    /// "remembered" and left for "forgot".
    private var touchCard: some View {
        cardView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { advance() }
            .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                guard abs(v.translation.width) > abs(v.translation.height) * 2 else { return }
                if isStudy && revealed && !learning {
                    grade(v.translation.width > 0 ? .remembered : .forgot)
                } else if !isStudy && v.translation.width < 0 {
                    advance()
                }
            })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Label(l["back"], systemImage: "chevron.left").font(.system(size: 13)).touchTarget(.leading)
            }
            .buttonStyle(.plain).focusable(false).foregroundStyle(Color.muted).accessibilityLabel(l["back"])
            Spacer()
            if isNumbers {
                HStack(spacing: 4) {
                    ForEach(Level.allCases) { lv in
                        Chip(title: lv.label, selected: level == lv, accent: accent) { level = lv }
                    }
                }
                .padding(3).background(Capsule().fill(Color.panel)).overlay(Capsule().strokeBorder(Color.lineSoft))
                .onChange(of: level) { next() }
            } else if let d = deck {
                // On a phone the deck name gives way to the group counters.
                if !(size.narrow && isStudy && !finished) {
                    Text(d.displayName)
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.muted).lineLimit(1)
                }
                if isStudy && !finished {
                    let counts = groupCounts(d)
                    HStack(spacing: 10) {
                        Text("\(size.narrow ? "" : "· ")\(l["group.label"]) #\(groupIndex)")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.muted).fixedSize()
                        HStack(spacing: 6) {
                            badgeCount(counts.review, color: Color.pos, label: l["badge.review"])
                            badgeCount(counts.learning, color: Color.warn, label: l["badge.learning"])
                            badgeCount(counts.new, color: accent.fill, label: l["badge.new"])
                        }
                        Text("(\(l["remaining"]) \(queue.count + (current == nil ? 0 : 1)))")
                            .font(.system(size: 12)).foregroundStyle(Color.muted).monospacedDigit().fixedSize()
                    }
                } else if isFree && !settingUpFree && !finished {
                    Text("· \(l["remaining"]) \(order.count + 1) / \(freeTotal)")
                        .font(.system(size: 13)).foregroundStyle(Color.muted).monospacedDigit()
                }
            }
        }
    }

    /// "复习 9" with a colour dot: the label says what the number counts, the dot only echoes the grade colours.
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

    private func groupCounts(_ d: Deck) -> (review: Int, learning: Int, new: Int) {
        let s = progress.states(d)
        let active = (current.map { [$0] } ?? []) + queue
        var rev = 0, lrn = 0, nw = 0
        for idx in Set(active) {
            guard let st = s[idx] else { nw += 1; continue }
            if st.step > 0 { lrn += 1 } else { rev += 1 }
        }
        return (rev, lrn, nw)
    }

    // MARK: Free Practice Setup

    private func freeSetupView(_ d: Deck) -> some View {
        let total = max(1, d.cards.count)
        let basePresets = [10, 20, 30, 50, 100].filter { $0 < total }
        return VStack(spacing: 22) {
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
                        presetPill("\(p)", selected: freeCount == p) { freeCount = p }
                    }
                    presetPill("\(l["free.all"]) (\(total))", selected: freeCount == total) { freeCount = total }
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

            Button { startFreePractice(d) } label: {
                Label("\(l["free.start"])（\(min(max(1, freeCount), total)) \(l["group.words"])）", systemImage: "play.fill")
            }
            .buttonStyle(.capsule(.primary, accent, large: true))
            .focusable(false)
        }
        .frame(maxWidth: .infinity)
    }

    private func presetPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Chip(title: title, selected: selected, accent: accent, action: action).focusable(false)
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

    private func startFreePractice(_ d: Deck) {
        let count = min(max(1, freeCount), max(1, d.cards.count))
        freeCount = count
        order = Array(d.cards.indices.shuffled().prefix(count))
        freeTotal = order.count
        seen = 0
        finished = false
        settingUpFree = false
        focused = true
        next()
    }

    // MARK: Card

    private var cardView: some View {
        VStack(spacing: detailsOpen ? 14 : 22) {
            VStack(spacing: 10) {
                if isStudy, let d = deck, let i = current, let st = progress.states(d)[i], st.step > 0, !learning {
                    Text(l["relearn.badge"])
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(Color.neg.opacity(0.14)))
                        .foregroundStyle(Color.neg)
                }
                Text(parts.front)
                    .font(frontFont)
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                if let tag = parts.tag {
                    Text(tag).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(accent.soft)).foregroundStyle(accent.color)
                }
            }

            VStack(spacing: 10) {
                Text(parts.answer)
                    .font(.system(size: (isNumbers ? 34 : 28) * k, design: .serif))
                    .foregroundStyle(Color.ink.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640 * k)
                if let note = parts.answerNote {
                    Text(note).font(.system(size: 15)).foregroundStyle(Color.muted)
                        .multilineTextAlignment(.center).frame(maxWidth: 560)
                }
                if !parts.hint.isEmpty {
                    Text(parts.hint)
                        .font(.system(size: 19 * k, design: .serif))
                        .foregroundStyle(Color.muted)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    pill(l["listen"], "speaker.wave.2") { speak() }
                    pill(l["slow"], "tortoise") { speak(slow: true) }
                    if !parts.sections.isEmpty {
                        pill(showDetails ? l["details.hide"] : l["details.show"],
                             showDetails ? "chevron.up" : "text.alignleft") { toggleDetails() }
                    }
                }
                .padding(.top, 4)
                if detailsOpen { details.transition(.opacity.combined(with: .move(edge: .bottom))) }
            }
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 6)
            .frame(minHeight: 150, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { advance() }
    }

    private var frontFont: Font {
        if isNumbers { return .custom("Didot", size: (parts.front.count > 3 ? 128 : 148) * k) }
        let n = parts.front.count, pt: CGFloat = detailsOpen ? (n < 16 ? 44 : 32) : (n < 16 ? 64 : n < 32 ? 46 : 32)
        return .system(size: pt * k, weight: .medium, design: .serif)
    }

    private func pill(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon) }
            .buttonStyle(.capsule(.soft, accent)).focusable(false)
    }

    // MARK: Notes panel

    private var details: some View {
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
                    ForEach(Array((currentSection?.items ?? []).enumerated()), id: \.offset) { _, item in noteLine(item) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .frame(maxHeight: max(140, size.height * 0.36))
        }
        .frame(maxWidth: 640 * k)
        .paperCard(radius: 14)
        .padding(.top, 6)
        .onTapGesture {} // keep clicks inside the panel from advancing the card
    }

    private var currentSection: CardParts.Section? {
        parts.sections.first { $0.id == section } ?? parts.sections.first
    }

    /// French phrase (speakable, French only) with its translation underneath, or a plain note.
    private func noteLine(_ item: CardParts.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let fr = item.fr {
                let speak = Button { speaker.say(fr, language: "fr-FR") } label: { Image(systemName: "speaker.wave.1").font(.system(size: 11)) }
                    .buttonStyle(.plain).focusable(false).foregroundStyle(Color.muted).accessibilityLabel(l["listen"])
                #if os(macOS)
                speak.simultaneousGesture(TapGesture().modifiers(.option).onEnded { speaker.say(fr, language: "fr-FR", slow: true) })
                #else
                // No Option key on a phone: long-press speaks slowly.
                speak.simultaneousGesture(LongPressGesture().onEnded { _ in speaker.say(fr, language: "fr-FR", slow: true) })
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

    // MARK: Footer & actions

    private var footer: some View {
        HStack {
            if settingUpFree {
                Text(l["free.setup.sub"])
            } else {
                Text(learning ? l["tap.learn"] : revealed ? (isStudy ? l["tap.grade"] : l["tap.next"]) : l["tap.reveal"])
            }
            Spacer()
            if !size.compact && !settingUpFree {
                Text(isNumbers ? l["keys"] : isStudy ? l["keys.study"] : l["keys.deck"]).lineLimit(1)
                Spacer()
            }
            Text("\(seen) \(l["seen"])").monospacedDigit()
        }
        .font(.system(size: 11)).foregroundStyle(Color.muted)
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(Color.lineSoft).frame(height: 1) }
    }

    private func toggleDetails() {
        guard revealed, !parts.sections.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.22)) { showDetails.toggle() }
    }

    private func advance() {
        if settingUpFree, let d = deck {
            startFreePractice(d)
            return
        }
        if finished {
            if isStudy, let d = deck {
                let nextPlan = progress.plan(d, newPerDay: newPerDay, groupSize: groupSize)
                if !nextPlan.groupQueue.isEmpty { startGroup(resetGroupIndex: false) }
            }
            return
        }
        if learning { return continueLearning() }
        if !revealed { reveal() } else if !isStudy { next() }
    }

    private func goBack() {
        if let d = deck { route = .overview(d) } else { route = nil }
    }

    private func startGroup(resetGroupIndex: Bool) {
        guard case .study(let d) = source else { return }
        let plan = progress.plan(d, newPerDay: newPerDay, groupSize: groupSize)
        if resetGroupIndex {
            groupIndex = 1
        } else {
            groupIndex += 1
        }
        queue = plan.groupQueue
        gradedOnce = []
        tally = [:]
        newLearned = 0
        reviewedCount = plan.groupDue.count
        finished = false
        focused = true
        next()
    }

    private func grade(_ g: Grade) {
        guard isStudy, revealed, !learning, !settingUpFree, !finished, let d = deck, let i = current else { return }
        guard progress.grade(d, card: i, g) else { return }
        // Record first-attempt rating in the group summary tally.
        if !gradedOnce.contains(i) {
            gradedOnce.insert(i)
            tally[g, default: 0] += 1
        }
        // Always update CardState so Anki learning/relearning steps graduate properly when recalled.
        gradeTick += 1
        if g == .forgot {
            queue.insert(i, at: min(4, queue.count))
        }
        next()
    }

    /// New word seen once: enter Anki Learning Step 1 (1 min) and bring it back in a few cards for its first test.
    private func continueLearning() {
        guard let d = deck, let i = current else { return }
        guard progress.introduce(d, card: i) else { return }
        newLearned += 1
        queue.insert(i, at: min(5, queue.count))
        next()
    }

    private var learnBar: some View {
        HStack(spacing: 14) {
            Label(l["learn.badge"], systemImage: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(accent.color)
            Spacer()
            Button(action: continueLearning) { Text(l["learn.continue"]) }
                .buttonStyle(.capsule(.primary, accent, large: true)).focusable(false)
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .frame(maxWidth: 560)
        .paperCard(radius: 16)
    }

    // MARK: Grading

    /// Space under the action bar and the page; on iPhone the home indicator's safe area already separates them from the edge.
    #if os(iOS)
    private let pageBottom: CGFloat = 4
    #else
    private let pageBottom: CGFloat = 24
    #endif

    private var gradeBar: some View {
        #if os(iOS)
        // Thumb-sized: taller buttons, larger type, no keyboard-shortcut digits.
        let (title, sub, dot, pad, keys): (CGFloat, CGFloat, CGFloat, CGFloat, Bool) = (18, 14, 10, 30, false)
        #else
        let (title, sub, dot, pad, keys): (CGFloat, CGFloat, CGFloat, CGFloat, Bool) = (14, 11, 8, 10, true)
        #endif
        return HStack(spacing: 12) {
            ForEach(Grade.allCases, id: \.self) { g in
                Button { grade(g) } label: {
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

    /// When the card would come back after this grade, e.g. "本组重现", "1 天后", "3 天后".
    private func preview(_ g: Grade) -> String {
        guard let d = deck, let i = current else { return "" }
        if g == .forgot { return l["again.soon"] }
        let s = CardState.next(progress.states(d)[i], g)
        return Self.interval(s.stability, l)
    }

    /// "3 天后" (later = true) or "3 天" (a duration).
    static func interval(_ days: Double, _ l: L, later: Bool = true) -> String {
        let p = later ? "unit" : "dur"
        if days < 1.0 / 24.0 {
            return later ? "\(max(1, Int((days * 1440).rounded()))) \(l["unit.mins"])"
                         : "\(max(1, Int((days * 1440).rounded()))) min"
        }
        return days < 0.85 ? "\(max(1, Int((days * 24).rounded()))) \(l["\(p).hours"])"
            : days < 60 ? "\(max(1, Int(days.rounded()))) \(l["\(p).days"])"
            : "\(Int((days / 30).rounded())) \(l["\(p).months"])"
    }

    @ViewBuilder private var doneView: some View {
        if isFree {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle").font(.system(size: 44, weight: .light)).foregroundStyle(accent.color)
                Text(l["free.done.title"]).font(.system(size: 28, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
                Text("\(freeTotal) \(l["cards"])")
                    .font(.system(size: 14)).foregroundStyle(Color.muted).monospacedDigit()
                HStack(spacing: 12) {
                    Button {
                        settingUpFree = true
                        finished = false
                        focused = true
                    } label: {
                        Label(l["free.again"], systemImage: "shuffle")
                    }
                    .buttonStyle(.capsule(.primary, accent)).focusable(false)

                    pill(l["back.overview"], "chart.xyaxis.line") { goBack() }
                }
                .padding(.top, 6)
            }
        } else {
            let nextPlan = deck.map { progress.plan($0, newPerDay: newPerDay, groupSize: groupSize) }
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

                        Button { startGroup(resetGroupIndex: false) } label: {
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
                    pill(l["back.overview"], "chart.xyaxis.line") { goBack() }
                    if let d = deck { pill(l["free"], "shuffle") { route = .free(d) } }
                }
                .padding(.top, 4)
            }
        }
    }

    private func reveal() {
        withAnimation(.easeOut(duration: 0.28)) { revealed = true }
        seen += 1
        if autoSpeak { speak() }
    }

    private func next() {
        let c: Card
        switch source {
        case .numbers:
            var n = Int.random(in: level.range)
            while "\(n)" == card.front { n = Int.random(in: level.range) }
            let e = FrenchNumbers.entry(n)
            c = Card(front: "\(n)", back: e.word, hint: "/\(e.ipa)/")
        case .free(let d):
            guard !order.isEmpty else {
                withAnimation { finished = true; current = nil }
                return
            }
            let i = order.removeLast()
            current = i
            c = d.cards[i]
        case .study(let d):
            guard !queue.isEmpty else {
                learning = false
                withAnimation { finished = true; current = nil }
                return
            }
            let i = queue.removeFirst()
            current = i
            c = d.cards[i]
        }
        var isNew = false
        if case .study(let d) = source, let i = current { isNew = progress.states(d)[i] == nil }
        speaker.stop()
        card = c
        parts = CardParts(c)
        section = parts.sections.first?.id ?? ""
        withAnimation(.snappy(duration: 0.25)) {
            learning = isNew
            revealed = isNew
        }
        if isNew { seen += 1; if autoSpeak { speak() } }
    }

    private func speak(slow: Bool = false) {
        // Numbers: read the French word. Decks: read whichever side is French, else the front.
        if isNumbers { return speaker.say(card.back, language: "fr-FR", slow: slow) }
        let text = CardParts.lang(parts.front) != .english ? parts.front
            : CardParts.lang(parts.answer) == .french ? parts.answer : parts.front
        speaker.say(text, language: "fr-FR", slow: slow)
    }
}

func gradeColor(_ g: Grade) -> Color {
    switch g {
    case .forgot: Color.neg
    case .vague: Color.warn
    case .remembered: Color.pos
    }
}
