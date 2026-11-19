import Foundation

struct WidgetSnapshot: Codable {
    struct Word: Codable, Hashable { var front: String; var back: String }

    var written = Date()
    var lang = "zh"
    var accent = "moss"
    var deckName = ""
    var due = 0
    var new = 0
    var done = 0
    var dueTomorrow = 0
    var newTomorrow = 0
    var week: [Int] = Array(repeating: 0, count: 7)
    var streak = 0
    var words: [Word] = []

    static let groupID: String = {
        #if os(macOS)
        "BGM8P5U985.com.yixuanwu.lexikos"
        #else
        "group.com.yixuanwu.lexikos"
        #endif
    }()

    private static var file: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("widget.json")
    }

    static func load() -> WidgetSnapshot? {
        file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func save() {
        guard let file = Self.file, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: .atomic)
    }

    func at(_ date: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        let writtenDay = calendar.startOfDay(for: written)
        let targetDay = calendar.startOfDay(for: date)
        let dayGap = calendar.dateComponents([.day], from: writtenDay, to: targetDay).day ?? 0
        guard dayGap > 0 else { return self }
        var s = self
        s.written = date
        s.due = dayGap == 1 ? dueTomorrow : max(dueTomorrow, due)
        s.new = newTomorrow
        s.done = 0
        let shift = min(7, dayGap)
        let kept = week.count > shift ? Array(week.dropFirst(shift)) : []
        s.week = kept + Array(repeating: 0, count: 7 - kept.count)
        if dayGap >= 2 || week.last == 0 {
            s.streak = 0
        }
        return s
    }
}
