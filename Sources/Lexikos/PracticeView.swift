import SwiftUI
import AVFoundation
import NaturalLanguage

struct PracticeView: View {
    enum Source { case numbers, free(Deck), study(Deck) }
    let source: Source
    @Binding var route: Route?

    @AppStorage("lang") private var lang = AppLanguage.systemDefault
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
    @State private var learning = false
    @State private var newLearned = 0
    @State private var reviewedCount = 0
    @Environment(\.windowSize) private var size
    private var k: CGFloat { size.cardScale }
    @Environment(ProgressStore.self) private var progress
    @AppStorage("newPerDay") private var newPerDay = 20
    @AppStorage("groupSize") private var groupSize = 10
    @AppStorage("freeCount") private var freeCount = 20

    @State private var queue: [Int] = []
    @State private var current: Int?
    @State private var gradedOnce: Set<Int> = []
    @State private var tally: [Grade: Int] = [:]
    @State private var finished = false
    @State private var groupIndex = 1
    @State private var gradeTick = 0

    @State private var settingUpFree = false
    @State private var freeTotal = 0

    struct Preset { var index: Int; var revealed = false, learning = false, details = false, finished = false, free = false }
    private var preset: Preset?

    #if os(iOS)
    private let pageBottom: CGFloat = 4
    #else
    private let pageBottom: CGFloat = 24
    #endif

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
        switch source {
        case .numbers:
            return nil
        case .free(let d), .study(let d):
            return d
        }
    }
    private var detailsOpen: Bool { revealed && showDetails && !parts.sections.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 16)
            VStack(spacing: 28) {
                if settingUpFree, let d = deck {
                    FreeSetupPanel(deck: d, accent: accent, l: l, freeCount: $freeCount) {
                        startFreePractice(d)
                    }
                } else if finished {
                    PracticeDonePanel(
                        isFree: isFree,
                        freeTotal: freeTotal,
                        hasDeck: deck != nil,
                        groupIndex: groupIndex,
                        reviewedCount: reviewedCount,
                        newLearned: newLearned,
                        tally: tally,
                        nextPlan: deck.map { progress.plan($0, newPerDay: newPerDay, groupSize: groupSize) },
                        accent: accent,
                        l: l,
                        onFreeAgain: {
                            settingUpFree = true
                            finished = false
                            focused = true
                        },
                        onNextGroup: { startGroup(resetGroupIndex: false) },
                        onOverview: { goBack() },
                        onFreeMode: { if let d = deck { route = .free(d) } }
                    )
                } else {
                    #if os(iOS)
                    touchCard
                    #else
                    cardView
                    #endif
                }
                if isStudy && revealed && !finished && !settingUpFree {
                    Group {
                        if learning {
                            PracticeLearnBar(accent: accent, l: l, onContinue: continueLearning)
                        } else {
                            PracticeGradeBar(accent: accent, l: l, preview: preview, onGrade: grade)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            Spacer(minLength: 16)
            #if os(macOS)
            footer
            #else
            if !settingUpFree && !finished {
                Text(learning ? l["tap.learn"] : revealed ? (isStudy ? l["tap.ios.grade"] : l["tap.ios.next"]) : l["tap.ios.reveal"])
                    .font(.system(size: 11.5)).foregroundStyle(Color.faint).padding(.top, 6)
            }
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
        .onDisappear { speaker.stop() }
        .onKeyPress("1") { grade(.forgot); return .handled }
        .onKeyPress("2") { grade(.vague); return .handled }
        .onKeyPress("3") { grade(.remembered); return .handled }
        .onKeyPress("a") {
            guard !settingUpFree, !finished else { return .ignored }
            speak(slow: true)
            return .handled
        }
        .onKeyPress(.space) { advance(); return .handled }
        .onKeyPress(.return) { advance(); return .handled }
        .onKeyPress(.rightArrow) { if !settingUpFree && !finished { next() }; return .handled }
        .onKeyPress(.escape) { goBack(); return .handled }
        .onKeyPress("s") {
            guard !settingUpFree, !finished else { return .ignored }
            speak()
            return .handled
        }
        .onKeyPress("d") { toggleDetails(); return .handled }
        .sensoryFeedback(.impact(weight: .light), trigger: gradeTick)
        .overlay(alignment: .bottom) {
            if let error = speaker.lastError {
                Text(l["err.speak"] + error).font(.callout).foregroundStyle(Color.ink).padding().paperCard(radius: 12).padding(.bottom, 60)
            }
        }
    }

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
        PracticeHeaderBar(
            isNumbers: isNumbers,
            isStudy: isStudy,
            isFree: isFree,
            deck: deck,
            level: $level,
            accent: accent,
            l: l,
            narrow: size.narrow,
            finished: finished,
            settingUpFree: settingUpFree,
            groupIndex: groupIndex,
            counts: deck.map(groupCounts) ?? (0, 0, 0),
            remainingStudy: queue.count + (current == nil ? 0 : 1),
            remainingFree: order.count + 1,
            freeTotal: freeTotal,
            onBack: goBack,
            onLevelChange: next
        )
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
                let multiLineTable = parts.answer.contains("\n") && parts.answer.contains(" · ")
                Text(parts.answer)
                    .font(.system(size: (isNumbers ? 34 : multiLineTable ? 19 : 28) * k, design: .serif))
                    .lineSpacing(multiLineTable ? 5 : 2)
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
                    PracticeSoftPill(title: l["listen"], icon: "speaker.wave.2", accent: accent) { speak() }
                    PracticeSoftPill(title: l["slow"], icon: "tortoise", accent: accent) { speak(slow: true) }
                    if !parts.sections.isEmpty {
                        PracticeSoftPill(title: showDetails ? l["details.hide"] : l["details.show"],
                                         icon: showDetails ? "chevron.up" : "text.alignleft",
                                         accent: accent) { toggleDetails() }
                    }
                }
                .padding(.top, 4)
                if detailsOpen {
                    CardDetailsPanel(parts: parts, accent: accent, l: l, scale: k, windowHeight: size.height, section: $section) { text, slow in
                        speaker.say(text, language: deck?.inferredSpeechLanguage ?? "fr-FR", slow: slow)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
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
        speaker.stop()
        if let d = deck { route = .overview(d) } else { route = nil }
    }

    private func startGroup(resetGroupIndex: Bool) {
        guard case .study(let d) = source else { return }
        let plan = progress.plan(d, newPerDay: newPerDay, groupSize: groupSize)
        if resetGroupIndex { groupIndex = 1 } else { groupIndex += 1 }
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
        if !gradedOnce.contains(i) {
            gradedOnce.insert(i)
            tally[g, default: 0] += 1
        }
        gradeTick += 1
        if g == .forgot {
            queue.insert(i, at: min(4, queue.count))
        }
        next()
    }

    private func continueLearning() {
        guard let d = deck, let i = current else { return }
        guard progress.introduce(d, card: i) else { return }
        newLearned += 1
        queue.insert(i, at: min(5, queue.count))
        next()
    }

    private func preview(_ g: Grade) -> String {
        guard let d = deck, let i = current else { return "" }
        if g == .forgot { return l["again.soon"] }
        let s = CardState.next(progress.states(d)[i], g)
        return Self.interval(s.stability, l)
    }

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
        if isNumbers { return speaker.say(card.back, language: "fr-FR", slow: slow) }
        let speech = Speaker.resolveSpeech(front: parts.front, answer: parts.answer, deckLanguage: deck?.inferredSpeechLanguage)
        speaker.say(speech.text, language: speech.language, slow: slow)
    }
}

func gradeColor(_ g: Grade) -> Color {
    switch g {
    case .forgot: Color.neg
    case .vague: Color.warn
    case .remembered: Color.pos
    }
}
