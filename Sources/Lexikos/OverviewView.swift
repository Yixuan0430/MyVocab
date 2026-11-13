import SwiftUI
import Charts

/// A deck's home: today's plan, memory stats, forgetting curves and per-word retention.
struct OverviewView: View {
    let deck: Deck
    @Binding var route: Route?
    @Environment(ProgressStore.self) private var progress
    @AppStorage("lang") private var lang = AppLanguage.zh
    @AppStorage("accent") private var accent = Accent.moss
    @AppStorage("newPerDay") private var newPerDay = 20
    @AppStorage("groupSize") private var groupSize = 10
    @State private var selected: Int?
    @State private var query = ""
    @State private var filter = WordFilter.all
    @State private var showAll = false
    @Environment(\.windowSize) private var size

    enum WordFilter: String, CaseIterable { case all, weak, strong }
    private static let topCount = 20

    private var l: L { L(lang: lang) }
    private var states: [Int: CardState] { progress.states(deck) }
    private var plan: ProgressStore.Plan { progress.plan(deck, newPerDay: newPerDay, groupSize: groupSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { route = nil } label: { Label(l["back"], systemImage: "chevron.left").font(.system(size: 13)).touchTarget(.leading) }
                    .buttonStyle(.plain).foregroundStyle(Color.muted).keyboardShortcut(.cancelAction)
                Spacer()
            }
            .padding(.bottom, 18)

            PageScroll {
                VStack(alignment: .leading, spacing: 22) {
                    today
                    stats
                    let layout = size.compact ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    layout {
                        panel(l["curve.title"], l["curve.sub"]) { curve }
                        panel(l["forecast.title"], l["forecast.sub"]) { forecast }
                    }
                    panel(l["words.title"], l["words.sub"]) { words }
                }
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: 1200)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, size.gutter).padding(.top, size.top)
        .sheet(item: Binding(get: { selected.map { IdentifiedInt(id: $0) } }, set: { selected = $0?.id })) { item in
            if deck.cards.indices.contains(item.id), let st = states[item.id] {
                WordCurveSheet(card: deck.cards[item.id], state: st, accent: accent, l: l)
            }
        }
    }

    // MARK: Today

    private var today: some View {
        let p = plan
        let layout = size.compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 24))
        let subtitle: String = {
            if p.groupQueue.isEmpty { return l["today.clear"] }
            if !p.due.isEmpty {
                return "\(l["stat.due"]) \(p.due.count) · \(l["group.nextInfo"])：\(l["review"]) \(p.groupDue.count)" +
                    (p.groupNew.count > 0 ? " + \(l["new"]) \(p.groupNew.count)" : "")
            }
            return "\(l["group.reviewsClear"]) · \(l["group.nextInfo"])：\(l["new"]) \(p.groupNew.count)"
        }()
        return layout {
            VStack(alignment: .leading, spacing: 6) {
                Text(deck.displayName)
                    .font(.system(size: 26, weight: .medium, design: .serif)).foregroundStyle(Color.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 13)).foregroundStyle(Color.muted).monospacedDigit()
            }
            if !size.compact { Spacer() }
            HStack(spacing: 10) {
                Menu {
                    ForEach([5, 10, 15, 20, 30], id: \.self) { n in
                        Button { groupSize = n } label: {
                            if groupSize == n { Label("\(l["group.per"]) \(n) \(l["group.words"])", systemImage: "checkmark") }
                            else { Text("\(l["group.per"]) \(n) \(l["group.words"])") }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 12))
                        Text("\(l["group.per"]) \(groupSize) \(l["group.words"])").font(.system(size: 13, weight: .medium)).monospacedDigit()
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.muted)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Color.panel)).overlay(Capsule().strokeBorder(Color.line)).foregroundStyle(Color.ink)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(l["group.size"])

                Button { route = .free(deck) } label: { Label(l["free"], systemImage: "shuffle") }
                    .buttonStyle(.capsule(.secondary, accent))

                Button { route = .study(deck) } label: {
                    Label(p.due.isEmpty && p.learnedToday > 0 ? l["start.nextGroup"] : l["start.group"], systemImage: "play.fill")
                }
                .buttonStyle(.capsule(.primary, accent))
                .keyboardShortcut(.defaultAction)
                .disabled(p.groupQueue.isEmpty)
            }
        }
    }

    /// Five disjoint-or-labelled counts in equal columns. Due, learning, mastered and unseen add up to the deck;
    /// "studied today" is an activity count shown apart from that total.
    private var stats: some View {
        let dueSet = Set(plan.due)
        let rest = states.filter { !dueSet.contains($0.key) }.values
        let unseen = max(0, deck.cards.count - states.count)
        let items: [(String, Int, Color)] = [
            (l["stat.due"], dueSet.count, Color.neg),
            (l["stat.learning"], rest.filter { !$0.mastered }.count, Color.warn),
            (l["stat.mastered"], rest.filter(\.mastered).count, Color.pos),
            (l["stat.unseen"], unseen, Color.faint),
            (l["stat.today"], plan.learnedToday, accent.fill),
        ]
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: size.width < 640 ? 3 : 5)
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { k, item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(item.2).frame(width: 7, height: 7)
                            Text(item.0).font(.system(size: 12)).foregroundStyle(Color.muted).lineLimit(1)
                        }
                        Text("\(item.1)").font(.system(size: 26, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(k == 4 ? accent.faint : Color.panel))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.lineSoft))
                    .accessibilityElement(children: .combine)
                }
            }
            Text(String(format: l["stat.total"], deck.cards.count))
                .font(.system(size: 11.5)).foregroundStyle(Color.muted).monospacedDigit().padding(.leading, 4)
        }
    }

    private func panel<C: View>(_ title: String, _ sub: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            Text(sub).font(.system(size: 12)).foregroundStyle(Color.muted).padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
            c()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }

    // MARK: Charts

    /// Ebbinghaus (1885) savings data: hours since learning → % retained.
    private static let ebbinghaus: [(Double, Double)] = [(0, 100), (0.33, 58.2), (1, 44.2), (8.8, 35.8),
                                                         (24, 33.7), (48, 27.8), (144, 25.4), (744, 21.1)]

    private struct CurvePoint: Identifiable { let id = UUID(); let day: Double; let value: Double; let series: String }

    private var curvePoints: [CurvePoint] {
        let now = Date.now, learned = Array(states.values)
        var pts = Self.ebbinghaus.map { CurvePoint(day: $0.0 / 24, value: $0.1, series: l["curve.ebbinghaus"]) }
        if !learned.isEmpty {
            for step in 0...60 {
                let d = Double(step) / 2, at = now.addingTimeInterval(d * 86400)
                let avg = learned.map { $0.retention(at: at) }.reduce(0, +) / Double(learned.count)
                pts.append(CurvePoint(day: d, value: avg * 100, series: l["curve.yours"]))
            }
        }
        return pts
    }

    private var curve: some View {
        Chart {
            ForEach(curvePoints) { p in
                LineMark(x: .value("day", p.day), y: .value("%", p.value))
                    .foregroundStyle(by: .value("series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: p.series == l["curve.ebbinghaus"] ? 1.5 : 2.5,
                                           dash: p.series == l["curve.ebbinghaus"] ? [4, 4] : []))
                    .interpolationMethod(.monotone)
            }
            RuleMark(y: .value("90", 90)).foregroundStyle(Color.pos.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        .chartForegroundStyleScale([l["curve.ebbinghaus"]: Color.faint, l["curve.yours"]: accent.fill])
        .chartXScale(domain: 0...30)
        .chartYScale(domain: 0...100)
        .chartXAxis { AxisMarks(values: [0, 7, 14, 21, 30]) { v in
            AxisGridLine().foregroundStyle(Color.lineSoft)
            AxisValueLabel { Text("\(v.as(Int.self) ?? 0)\(l["unit.d"])").foregroundStyle(Color.muted) }
        } }
        .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 90]) { v in
            AxisGridLine().foregroundStyle(Color.lineSoft)
            AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").foregroundStyle(Color.muted) }
        } }
        .chartLegend(position: .bottom, alignment: .leading)
        .frame(height: 200)
    }

    /// Today's backlog (which can be hundreds) is a number of its own so it doesn't flatten the bars for the days after.
    private var forecast: some View {
        let cal = Calendar.current, start = cal.startOfDay(for: .now)
        var counts = Array(repeating: 0, count: 14)
        for st in states.values {
            let day = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: st.due)).day ?? 0
            counts[min(13, max(0, day))] += day <= 13 ? 1 : 0
        }
        let backlog = counts[0], next = Array(counts.dropFirst())
        let week = next.prefix(7).reduce(0, +), fortnight = next.reduce(0, +)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 22) {
                figure(l["forecast.backlog"], backlog, backlog > 0 ? Color.neg : Color.pos)
                figure(l["forecast.week"], week, accent.fill)
                figure(l["forecast.fortnight"], fortnight, Color.faint)
                Spacer(minLength: 0)
            }
            if fortnight == 0 {
                Text(l["forecast.empty"]).font(.system(size: 12)).foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, minHeight: 112)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.well))
            } else {
                Chart(Array(next.enumerated()), id: \.offset) { k, n in
                    BarMark(x: .value("day", k + 1), y: .value("n", n), width: 12)
                        .foregroundStyle(k < 7 ? accent.fill : accent.fill.opacity(0.45))
                        .cornerRadius(3)
                }
                .chartXScale(domain: 0.4...13.6)
                .chartXAxis { AxisMarks(values: [1, 4, 7, 10, 13]) { v in
                    AxisValueLabel { Text("+\(v.as(Int.self) ?? 0)\(l["unit.d"])").foregroundStyle(Color.muted) }
                } }
                .chartYAxis { AxisMarks { v in
                    AxisGridLine().foregroundStyle(Color.lineSoft)
                    AxisValueLabel { Text("\(v.as(Int.self) ?? 0)").foregroundStyle(Color.muted) }
                } }
                .frame(height: 130)
            }
        }
    }

    private func figure(_ k: String, _ v: Int, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(v)").font(.system(size: 22, weight: .medium, design: .serif)).foregroundStyle(Color.ink).monospacedDigit()
            HStack(spacing: 5) {
                Circle().fill(c).frame(width: 6, height: 6)
                Text(k).font(.system(size: 11.5)).foregroundStyle(Color.muted).lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    // MARK: Words

    private func retentionColor(_ r: Double) -> Color { r < 0.5 ? Color.neg : r < 0.8 ? Color.warn : Color.pos }

    private var words: some View {
        let now = Date.now, cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let all = states.map { ($0.key, $0.value, $0.value.retention(at: now)) }.sorted { $0.2 < $1.2 }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = all.filter { i, _, r in
            switch filter {
            case .all: break
            case .weak: if r >= 0.8 { return false }
            case .strong: if r < 0.8 { return false }
            }
            guard !q.isEmpty, deck.cards.indices.contains(i) else { return true }
            return deck.cards[i].front.lowercased().contains(q) || deck.cards[i].back.lowercased().contains(q)
        }
        let rows = showAll || !q.isEmpty ? matched : Array(matched.prefix(Self.topCount))
        return VStack(spacing: 0) {
            if !all.isEmpty {
                HStack(spacing: 8) {
                    SearchBox(text: $query, prompt: l["words.search"]).frame(maxWidth: 260)
                    ForEach(WordFilter.allCases, id: \.self) { f in
                        Chip(title: l["words.\(f.rawValue)"], selected: filter == f, accent: accent) { filter = f }
                    }
                    Spacer(minLength: 0)
                    if !size.narrow {
                        Text(String(format: l["words.count"], rows.count, all.count))
                            .font(.system(size: 11.5)).foregroundStyle(Color.muted).monospacedDigit()
                    }
                }
                .padding(.bottom, 8)
            }
            if all.isEmpty {
                Text(l["words.empty"]).font(.system(size: 13)).foregroundStyle(Color.muted).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if rows.isEmpty {
                Text(l["words.none"]).font(.system(size: 13)).foregroundStyle(Color.muted).padding(.vertical, 14)
            }
            ForEach(rows, id: \.0) { i, st, r in
                let isDueToday = st.step > 0 || st.due < endOfDay
                let calDays = Double(max(1, cal.dateComponents([.day], from: todayStart, to: cal.startOfDay(for: st.due)).day ?? 1))
                Button { selected = i } label: {
                    HStack(spacing: 14) {
                        Text(CardParts.splitGloss(deck.cards[i].front).0.replacingOccurrences(of: "\n", with: " / "))
                            .font(.system(size: 14)).foregroundStyle(Color.ink).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.well)
                            Capsule().fill(retentionColor(r)).frame(width: max(3, 120 * r))
                        }
                        .frame(width: size.narrow ? 60 : 120, height: 6)
                        Text("\(Int(r * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.muted)
                            .frame(width: 38, alignment: .trailing)
                        Text(isDueToday ? l["due.now"] : PracticeView.interval(calDays, l))
                            .font(.system(size: 12, weight: isDueToday ? .medium : .regular))
                            .foregroundStyle(isDueToday ? Color.neg : Color.muted).monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Color.faint)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                Rectangle().fill(Color.lineSoft).frame(height: 1)
            }
            if q.isEmpty && matched.count > Self.topCount {
                Button { withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() } } label: {
                    Label(showAll ? l["words.less"] : String(format: l["words.more"], matched.count),
                          systemImage: showAll ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.capsule(.soft, accent))
                .padding(.top, 12)
            }
        }
    }
}

private struct IdentifiedInt: Identifiable { let id: Int }

/// One word's full memory history: the sawtooth of forgetting and each review that reset it.
struct WordCurveSheet: View {
    let card: Card, state: CardState, accent: Accent, l: L
    @Environment(\.dismiss) private var dismiss

    private struct Pt: Identifiable { let id = UUID(); let date: Date; let value: Double; let segment: Int }

    private var points: [Pt] {
        let reviews = state.reviews.isEmpty
            ? [Review(date: state.lastReview, grade: .remembered, stability: max(0.3, state.stability))]
            : state.reviews
        let end = max(Date.now, state.due).addingTimeInterval(7 * 86400)
        var out: [Pt] = []
        for (k, r) in reviews.enumerated() {
            let stop = k + 1 < reviews.count ? reviews[k + 1].date : end
            let span = max(0, stop.timeIntervalSince(r.date))
            for step in 0...40 {
                let t = r.date.addingTimeInterval(span * Double(step) / 40)
                out.append(Pt(date: t, value: CardState.retention(days: max(0, t.timeIntervalSince(r.date)) / 86400, stability: r.stability) * 100, segment: k))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(CardParts.splitGloss(card.front).0).font(.system(size: 26, weight: .medium, design: .serif)).foregroundStyle(Color.ink)
                Text(CardParts(card).answer).font(.system(size: 15)).foregroundStyle(Color.muted).lineLimit(1)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).accessibilityLabel(l["ok"]).foregroundStyle(Color.muted).keyboardShortcut(.cancelAction)
            }
            Text(l["word.sub"]).font(.system(size: 12)).foregroundStyle(Color.muted).padding(.bottom, 8)
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("t", p.date), y: .value("%", p.value), series: .value("s", p.segment))
                        .foregroundStyle(accent.fill.opacity(0.12))
                    LineMark(x: .value("t", p.date), y: .value("%", p.value), series: .value("s", p.segment))
                        .foregroundStyle(accent.fill)
                }
                ForEach(state.reviews, id: \.date) { r in
                    PointMark(x: .value("t", r.date), y: .value("%", 100))
                        .foregroundStyle(gradeColor(r.grade)).symbolSize(60)
                }
                RuleMark(x: .value("now", Date.now)).foregroundStyle(Color.muted.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .bottom, alignment: .leading) { Text(l["now"]).font(.system(size: 10)).foregroundStyle(Color.muted) }
                RuleMark(y: .value("90", 90)).foregroundStyle(Color.line)
            }
            .chartYScale(domain: 0...105)
            .chartYAxis { AxisMarks(values: [0, 50, 90]) { v in
                AxisGridLine().foregroundStyle(Color.line)
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%").foregroundStyle(Color.muted) }
            } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel(format: .dateTime.month().day()).foregroundStyle(Color.muted) } }
            .frame(height: 220)

            HStack(spacing: 18) {
                fact(l["word.retention"], "\(Int(state.retention(at: .now) * 100))%")
                fact(l["word.stability"], PracticeView.interval(state.stability, l, later: false))
                fact(l["word.reviews"], "\(state.reviews.count)")
                fact(l["word.lapses"], "\(state.lapses)")
                fact(l["word.next"], state.due.formatted(.dateTime.month().day().hour().minute()))
            }
            PageScroll {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.reviews.reversed(), id: \.date) { r in
                        HStack(spacing: 8) {
                            Circle().fill(gradeColor(r.grade)).frame(width: 7, height: 7)
                            Text(l["grade.\(r.grade)"]).font(.system(size: 12)).foregroundStyle(Color.ink).frame(width: 70, alignment: .leading)
                            Text(r.date.formatted(.dateTime.year().month().day().hour().minute()))
                                .font(.system(size: 12)).foregroundStyle(Color.muted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
        .padding(24)
        .frame(width: 620)
        .background(Color.bg)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.system(size: 11)).foregroundStyle(Color.muted)
            Text(v).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink).monospacedDigit()
        }
    }
}
