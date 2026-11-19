import SwiftUI
import Observation

extension Color {
    static func dyn(_ light: UInt32, _ dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> Color {
        #if os(macOS)
        Color(NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(hex: dark, alpha: alpha.1) : NSColor(hex: light, alpha: alpha.0) })
        #else
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: alpha.1) : UIColor(hex: light, alpha: alpha.0) })
        #endif
    }
    private static var t: AppTheme { AppTheme.shared }
    static var bg: Color { t.color(\.bg) }
    static var panel: Color { t.color(\.card) }
    static var well: Color { t.color(\.well) }
    static var ink: Color { t.color(\.ink) }
    static var muted: Color { t.color(\.ink2) }
    static var faint: Color { t.color(\.ink3) }
    static var line: Color { t.color(\.line) }
    static var lineSoft: Color { t.color(\.lineSoft) }
    static var warm: Color { t.color(\.warm) }
    static var cool: Color { t.color(\.cool) }
    static var pos: Color { t.color(\.pos) }
    static var neg: Color { t.color(\.neg) }
    static var warn: Color { t.color(\.warn) }
}

struct ThemeTokens {
    var bg, card, well, ink, ink2, ink3, line, lineSoft: UInt32
    var accent, accentInk, accentText, accentSoft, accentFaint: UInt32
    var warm, cool, pos, neg, warn: UInt32
}

struct Paper { let bg, surface, strong, muted, line, lineStrong, ink, mutedText: UInt32 }

struct Palette {
    let key: String, zh: String, en: String, fr: String
    let swatches: [UInt32]
    let accent: UInt32, warm: UInt32, cool: UInt32
    let paper: Paper

    static let night = Paper(bg: 0x131211, surface: 0x181716, strong: 0x1D1C1A, muted: 0x262422, line: 0x2B2926,
                             lineStrong: 0x3B3834, ink: 0xECE6DF, mutedText: 0xA0978D)
    static let eyeCare = Paper(bg: 0xF4ECDC, surface: 0xF8F1E3, strong: 0xFBF6EA, muted: 0xEFE5D1, line: 0xE2D5BB,
                               lineStrong: 0xD3C3A3, ink: 0x3B3226, mutedText: 0x7A6C58)

    enum Mode { case light, dark, eyeCare }

    func tokens(_ mode: Mode) -> ThemeTokens {
        let dark = mode == .dark
        let s = mode == .light ? paper : mode == .eyeCare ? Self.eyeCare : Self.night
        let mid = Hex.mix(warm, cool, 0.5)
        let surf = { (c: UInt32) in dark ? Hex.mix(c, mid, 0.03) : c }
        let bg = mode == .light ? Hex.mix(s.muted, mid, 0.06) : surf(s.bg)
        let card = surf(s.strong)
        let fill = dark && Hex.contrast(accent) == 0xFFFFFF ? Hex.mix(accent, 0xFFFFFF, 0.35) : accent
        let text = dark ? Hex.mix(accent, 0xFFFFFF, 0.5) : Hex.mix(accent, 0x000000, Hex.contrast(accent) == 0xFFFFFF ? 0.12 : 0.34)
        return ThemeTokens(
            bg: bg, card: card,
            well: dark ? surf(s.muted) : Hex.mix(s.muted, s.line, 0.35),
            ink: s.ink,
            ink2: Hex.mix(s.ink, s.mutedText, dark ? 0.7 : 0.62),
            ink3: s.mutedText,
            line: mode == .light ? Hex.mix(s.line, s.lineStrong, 0.55) : surf(s.line),
            lineSoft: mode == .light ? s.line : surf(dark ? s.muted : Hex.mix(s.line, s.strong, 0.5)),
            accent: fill, accentInk: Hex.contrast(fill), accentText: text,
            accentSoft: Hex.mix(fill, card, dark ? 0.78 : 0.84),
            accentFaint: Hex.mix(fill, card, dark ? 0.88 : 0.93),
            warm: warm, cool: cool,
            pos: dark ? 0x8CC7A8 : 0x4F8A6F, neg: dark ? 0xEB9A86 : 0xBF604B, warn: dark ? 0xE6BB6E : 0xB0802C)
    }
}

enum Hex {
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double(v >> s & 0xFF) }
        func m(_ s: UInt32) -> UInt32 { UInt32(max(0, min(255, (ch(a, s) + (ch(b, s) - ch(a, s)) * t).rounded()))) << s }
        return m(16) | m(8) | m(0)
    }
    static func contrast(_ c: UInt32) -> UInt32 {
        let l = (Double(c >> 16 & 0xFF) * 0.299 + Double(c >> 8 & 0xFF) * 0.587 + Double(c & 0xFF) * 0.114) / 255
        return l > 0.48 ? 0x1F2B28 : 0xFFFFFF
    }
}

@Observable final class AppTheme: @unchecked Sendable {
    static let shared = AppTheme()
    var accent: Accent = .moss
    var appearance: Appearance = .system

    func load(from defaults: UserDefaults) {
        accent = defaults.string(forKey: "accent").flatMap(Accent.init(rawValue:)) ?? .moss
        appearance = defaults.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
    }

    var pair: (ThemeTokens, ThemeTokens) {
        let p = accent.palette
        return (p.tokens(appearance == .warm ? .eyeCare : .light), p.tokens(.dark))
    }

    func color(_ k: KeyPath<ThemeTokens, UInt32>) -> Color {
        let (l, d) = pair
        return Color.dyn(l[keyPath: k], d[keyPath: k])
    }
}

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension View {
    func touchTarget(_ alignment: Alignment = .center) -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44, alignment: alignment).contentShape(Rectangle())
        #else
        self
        #endif
    }
}

private struct WindowSizeKey: EnvironmentKey { static let defaultValue = CGSize(width: 820, height: 600) }
extension EnvironmentValues {
    var windowSize: CGSize {
        get { self[WindowSizeKey.self] }
        set { self[WindowSizeKey.self] = newValue }
    }
}

extension CGSize {
    var gutter: CGFloat { width < 640 ? 20 : width < 1100 ? 36 : 56 }
    var compact: Bool { width < 760 }
    var narrow: Bool { width < 500 }
    var top: CGFloat {
        #if os(iOS)
        8
        #else
        40
        #endif
    }
    var cardScale: CGFloat { min(1.5, max(0.72, min(width / 820, height / 600))) }
}

enum Accent: String, CaseIterable, Identifiable {
    case moss, pinegold, sunecho, hazeapricot, apricotmist, roseSage, dusklavender, hazelamp, deepsea, seablue, cloudsand
    case sage, blue, gold, rose, violet, terracotta
    var id: String { rawValue }

    static let choices: [Accent] = [
        .moss, .pinegold, .sunecho, .hazeapricot, .apricotmist, .roseSage,
        .dusklavender, .hazelamp, .deepsea, .seablue, .cloudsand
    ]

    var resolved: Accent {
        switch self {
        case .sage: .moss
        case .blue: .deepsea
        case .gold: .pinegold
        case .rose: .roseSage
        case .violet: .dusklavender
        case .terracotta: .apricotmist
        default: self
        }
    }

    var palette: Palette {
        func paper(_ v: [UInt32]) -> Paper {
            Paper(bg: v[0], surface: v[1], strong: v[2], muted: v[3], line: v[4], lineStrong: v[5], ink: v[6], mutedText: v[7])
        }
        return switch resolved {
        case .sunecho: Palette(key: "sunecho", zh: "暖阳回响", en: "Sunny echo", fr: "Écho solaire", swatches: [0xF8F3EA, 0xEDDCC6, 0xE7B99A, 0x7C90A6],
            accent: 0xDDA583, warm: 0xEDB08A, cool: 0x8FA3B5, paper: paper([0xFEFCFB, 0xFFFEFD, 0xFFFEFE, 0xFBF8F6, 0xF3EEE8, 0xE6DFD3, 0x2E2620, 0x81766A]))
        case .pinegold: Palette(key: "pinegold", zh: "松间麦金", en: "Pine & wheat", fr: "Pin et blé", swatches: [0xF7F3EA, 0xDCE7DC, 0x7FA591, 0xD8BD80],
            accent: 0x7FA591, warm: 0xD8BD80, cool: 0x8FB0A0, paper: paper([0xFDFCFA, 0xFEFEFC, 0xFFFEFC, 0xFAF8F5, 0xF2EEE4, 0xE3DCCA, 0x2B2A22, 0x7A7565]))
        case .hazeapricot: Palette(key: "hazeapricot", zh: "海雾杏粉", en: "Sea fog apricot", fr: "Brume abricot", swatches: [0xF5F3EF, 0xDCE6F1, 0x7C9CC4, 0xEBC3AB],
            accent: 0x7C9CC4, warm: 0xECC3AB, cool: 0x9FB6D0, paper: paper([0xFCFCFC, 0xFEFEFD, 0xFFFEFE, 0xFAF8F6, 0xF1EEEB, 0xE1DDD4, 0x232A36, 0x6F7784]))
        case .apricotmist: Palette(key: "apricotmist", zh: "杏桃雾蓝", en: "Apricot mist", fr: "Abricot brumeux", swatches: [0xFBF5EE, 0xF6DCCB, 0xE8A98D, 0xA3B5CF],
            accent: 0xE8A98D, warm: 0xF0BF9A, cool: 0xA3B5CF, paper: paper([0xFEFCFB, 0xFFFEFC, 0xFFFEFC, 0xFCF8F5, 0xF7EFE8, 0xECDFD1, 0x3B2A25, 0x8C7468]))
        case .roseSage: Palette(key: "roseSage", zh: "莓茶青野", en: "Rose & sage", fr: "Rose et sauge", swatches: [0xF8F2F1, 0xEBD3D6, 0xC88FA0, 0xA9BDA9],
            accent: 0xC88FA0, warm: 0xE2B3A4, cool: 0xA9BDA9, paper: paper([0xFEFCFC, 0xFEFDFD, 0xFFFEFE, 0xFBF8F7, 0xF4EDEC, 0xE7DBD9, 0x3A2B30, 0x86737A]))
        case .dusklavender: Palette(key: "dusklavender", zh: "暮紫蜂蜜", en: "Dusk lavender", fr: "Lavande au miel", swatches: [0xF6F4F8, 0xE3DCEE, 0xA99BC6, 0xECD3A4],
            accent: 0xA99BC6, warm: 0xECD3A4, cool: 0xB9B0CF, paper: paper([0xFDFCFE, 0xFEFEFE, 0xFEFEFF, 0xFAF9FB, 0xF2EEF5, 0xE2DEEA, 0x2C2836, 0x7A7488]))
        case .hazelamp: Palette(key: "hazelamp", zh: "夜航灯火", en: "Night lights", fr: "Feux de nuit", swatches: [0xF1F3F7, 0xD9E1EE, 0x8EA6CC, 0xE3CB9C],
            accent: 0x8EA6CC, warm: 0xE3CB9C, cool: 0x94A8C4, paper: paper([0xFCFCFD, 0xFDFEFE, 0xFEFEFF, 0xF8F9FB, 0xEDF0F5, 0xDAE0E9, 0x232A38, 0x6A7387]))
        case .deepsea: Palette(key: "deepsea", zh: "深海月夜", en: "Deep sea moon", fr: "Lune marine", swatches: [0x010736, 0x0D1C42, 0x22396F, 0xFCF1D0],
            accent: 0x50659A, warm: 0xE3C88E, cool: 0x7189B3, paper: paper([0xFBFCFD, 0xFDFDFE, 0xFEFEFF, 0xF7F8FB, 0xEBEEF4, 0xD7DDE9, 0x141C38, 0x56607D]))
        case .seablue: Palette(key: "seablue", zh: "海雾晴蓝", en: "Sea fog blue", fr: "Bleu marin", swatches: [0x3368A0, 0x66A3BF, 0xC8DFDB, 0xF2EFE7],
            accent: 0x7099C2, warm: 0xDCC39E, cool: 0x8FB0CC, paper: paper([0xFCFCFE, 0xFDFEFE, 0xFEFEFF, 0xF7FAFC, 0xE9F0F4, 0xD4E0E9, 0x1A2C3E, 0x577084]))
        case .cloudsand: Palette(key: "cloudsand", zh: "云蓝浅沙", en: "Cloud & sand", fr: "Nuage et sable", swatches: [0x81A6C6, 0xAACDDC, 0xF3E3D0, 0xD2C4B4],
            accent: 0x9DB9D2, warm: 0xDDBB94, cool: 0xA2BAD0, paper: paper([0xFCFCFB, 0xFEFEFD, 0xFFFEFE, 0xFAF8F6, 0xF1EDE7, 0xE3DBD1, 0x2A3440, 0x707784]))
        default: Palette(key: "moss", zh: "青苔微雨", en: "Mossy drizzle", fr: "Mousse et bruine", swatches: [0x659287, 0x88BDA4, 0xB1D3B9, 0xE6F2DD],
            accent: 0x88AEA0, warm: 0xCDBE8E, cool: 0x8FB3A8, paper: paper([0xFBFCFC, 0xFDFEFD, 0xFEFEFE, 0xF7FAF7, 0xE9F0EB, 0xD4E2D8, 0x1F2E28, 0x5A6F66]))
        }
    }

    func name(_ lang: AppLanguage) -> String { [AppLanguage.zh: palette.zh, .en: palette.en, .fr: palette.fr][lang]! }

    private func token(_ k: KeyPath<ThemeTokens, UInt32>) -> Color {
        let p = palette, mode = AppTheme.shared.appearance
        return Color.dyn(p.tokens(mode == .warm ? .eyeCare : .light)[keyPath: k], p.tokens(.dark)[keyPath: k])
    }
    var color: Color { token(\.accentText) }
    var fill: Color { token(\.accent) }
    var onFill: Color { token(\.accentInk) }
    var soft: Color { token(\.accentSoft) }
    var faint: Color { token(\.accentFaint) }
}

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, warm, system
    var id: String { rawValue }
    var scheme: ColorScheme? { [.system: nil, .light: .light, .warm: .light, .dark: .dark][self]! }
    var icon: String { [.light: "sun.max", .dark: "moon", .warm: "leaf", .system: "circle.lefthalf.filled"][self]! }
    #if os(macOS)
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light, .warm: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case zh, en, fr
    var id: String { rawValue }
    var label: String { ["zh": "中文", "en": "English", "fr": "Français"][rawValue]! }
}

struct L {
    let lang: AppLanguage
    subscript(_ key: String) -> String { L.table[key]?[lang.rawValue] ?? key }

    private static let table: [String: [String: String]] = [
        "slow": ["zh": "慢速", "en": "Slow", "fr": "Lent"],
        "remaining": ["zh": "剩余", "en": "left", "fr": "restantes"],
        "tap.grade": ["zh": "选择记忆程度", "en": "Rate how well you knew it", "fr": "Évaluez votre mémoire"],
        "keys.study": [
            "zh": "空格 显示/继续 · 1 没记住 · 2 模糊 · 3 记住了 · S 朗读 · A 慢速",
            "en": "Space reveal · 1 forgot · 2 vague · 3 knew it · S listen · A slow",
            "fr": "Espace révéler · 1 oublié · 2 flou · 3 su · S écouter · A lent"
        ],
        "grade.forgot": ["zh": "没记住", "en": "Forgot", "fr": "Oublié"],
        "grade.vague": ["zh": "模糊", "en": "Vague", "fr": "Flou"],
        "grade.remembered": ["zh": "记住了", "en": "Knew it", "fr": "Su"],
        "again.soon": ["zh": "本组重现", "en": "In this group", "fr": "Ce groupe"],
        "unit.mins": ["zh": "分钟后", "en": "min", "fr": "min"],
        "unit.hours": ["zh": "小时后", "en": "h", "fr": "h"],
        "unit.days": ["zh": "天后", "en": "days", "fr": "j"],
        "unit.months": ["zh": "个月后", "en": "months", "fr": "mois"],
        "unit.d": ["zh": "天", "en": "d", "fr": "j"],
        "done.title": ["zh": "今天的任务完成了", "en": "All done for today", "fr": "Terminé pour aujourd’hui"],
        "group.done": ["zh": "本组学习完成", "en": "Group complete", "fr": "Groupe terminé"],
        "group.next": ["zh": "学习下一组", "en": "Study next group", "fr": "Groupe suivant"],
        "group.next.new": ["zh": "再学一组新词", "en": "Next group of new words", "fr": "Nouveau groupe"],
        "group.size": ["zh": "每组词数", "en": "Words per group", "fr": "Mots par groupe"],
        "group.per": ["zh": "每组", "en": "Group", "fr": "Groupe"],
        "group.words": ["zh": "词", "en": "words", "fr": "mots"],
        "group.label": ["zh": "本组", "en": "Group", "fr": "Groupe"],
        "group.nextInfo": ["zh": "下一组", "en": "Next group", "fr": "Prochain groupe"],
        "group.reviewsClear": [
            "zh": "待复习已全部清零，可继续按组学习新词",
            "en": "All due reviews cleared; continue with new word groups anytime",
            "fr": "Révisions à jour ; continuez par groupes de nouveaux mots"
        ],
        "start.group": ["zh": "开始本组学习", "en": "Start group", "fr": "Commencer le groupe"],
        "start.nextGroup": ["zh": "再学一组", "en": "Study another group", "fr": "Encore un groupe"],
        "free.setup.title": ["zh": "自由练习", "en": "Free practice", "fr": "Entraînement libre"],
        "free.setup.sub": [
            "zh": "设置本次练习随机抽取的单词数量",
            "en": "Choose how many random words to practice this session",
            "fr": "Choisissez le nombre de mots pour cette séance"
        ],
        "free.count": ["zh": "本次练习词数", "en": "Words to practice", "fr": "Nombre de mots"],
        "free.all": ["zh": "全部", "en": "All", "fr": "Tout"],
        "free.start": ["zh": "开始自由练习", "en": "Start practice", "fr": "Commencer"],
        "free.done.title": ["zh": "本次自由练习完成", "en": "Free practice complete", "fr": "Séance libre terminée"],
        "free.again": ["zh": "再来一轮（重设数量）", "en": "Practice again (set count)", "fr": "Recommencer (choisir le nombre)"],
        "relearn.badge": ["zh": "本组巩固", "en": "Relearning", "fr": "Consolidation"],
        "back.overview": ["zh": "查看记忆曲线", "en": "See memory curve", "fr": "Voir la courbe"],
        "free": ["zh": "自由练习", "en": "Free practice", "fr": "Entraînement libre"],
        "start": ["zh": "开始今日学习", "en": "Start today", "fr": "Commencer"],
        "today": ["zh": "今日", "en": "Today", "fr": "Aujourd’hui"],
        "today.plan": ["zh": "今日计划", "en": "Today’s plan", "fr": "Programme du jour"],
        "today.clear": ["zh": "今日已完成", "en": "All caught up", "fr": "À jour"],
        "review": ["zh": "复习", "en": "Review", "fr": "Révision"],
        "new": ["zh": "新词", "en": "New", "fr": "Nouveaux"],
        "stat.due": ["zh": "待复习", "en": "Due", "fr": "À revoir"],
        "stat.learning": ["zh": "巩固中", "en": "Learning", "fr": "En cours"],
        "stat.total": [
            "zh": "共 %d 张卡片：待复习 + 巩固中 + 已掌握 + 未学",
            "en": "%d cards: due + learning + mastered + unseen",
            "fr": "%d cartes : à revoir + en cours + maîtrisés + non vus"
        ],
        "today.new": ["zh": "今日新词", "en": "New today", "fr": "Nouveaux"],
        "badge.review": ["zh": "复习", "en": "Review", "fr": "Révision"],
        "badge.learning": ["zh": "巩固", "en": "Learning", "fr": "En cours"],
        "badge.new": ["zh": "新词", "en": "New", "fr": "Nouveaux"],
        "forecast.backlog": ["zh": "今日待复习", "en": "Due today", "fr": "À revoir aujourd’hui"],
        "forecast.week": ["zh": "未来 7 天", "en": "Next 7 days", "fr": "7 prochains jours"],
        "forecast.fortnight": ["zh": "未来 14 天", "en": "Next 14 days", "fr": "14 prochains jours"],
        "forecast.empty": ["zh": "未来两周暂无新的到期词", "en": "Nothing else comes due in the next two weeks", "fr": "Rien d’autre dans les deux semaines"],
        "words.search": ["zh": "搜索单词或释义", "en": "Search words", "fr": "Rechercher"],
        "words.all": ["zh": "全部", "en": "All", "fr": "Tous"],
        "words.weak": ["zh": "记忆薄弱", "en": "Weak", "fr": "Fragiles"],
        "words.strong": ["zh": "记得牢", "en": "Strong", "fr": "Solides"],
        "words.more": ["zh": "展开全部（%d）", "en": "Show all (%d)", "fr": "Tout afficher (%d)"],
        "words.less": ["zh": "只看前 20 个", "en": "Show top 20", "fr": "Afficher les 20 premiers"],
        "words.none": ["zh": "没有匹配的单词", "en": "No matching words", "fr": "Aucun mot"],
        "words.count": ["zh": "显示 %d / %d", "en": "%d of %d", "fr": "%d sur %d"],
        "stat.mastered": ["zh": "已掌握", "en": "Mastered", "fr": "Maîtrisés"],
        "stat.unseen": ["zh": "未学", "en": "Unseen", "fr": "Non vus"],
        "stat.today": ["zh": "今日已学", "en": "Studied today", "fr": "Vus aujourd’hui"],
        "curve.title": ["zh": "遗忘曲线", "en": "Forgetting curve", "fr": "Courbe de l’oubli"],
        "curve.sub": ["zh": "如果从现在起不再复习，你的平均记忆保留率", "en": "Your average recall if you stop reviewing now", "fr": "Votre rétention moyenne sans révision"],
        "curve.ebbinghaus": ["zh": "艾宾浩斯（不复习）", "en": "Ebbinghaus (no review)", "fr": "Ebbinghaus (sans révision)"],
        "curve.yours": ["zh": "你的记忆", "en": "Your memory", "fr": "Votre mémoire"],
        "forecast.title": ["zh": "复习计划", "en": "Review schedule", "fr": "Planning"],
        "forecast.sub": [
            "zh": "今天的积压单独计数，柱状图为之后每天到期的词数",
            "en": "Today’s backlog on its own; bars show what comes due each day after",
            "fr": "Retard du jour à part ; barres : cartes à revoir ensuite"
        ],
        "words.title": ["zh": "单词记忆", "en": "Word memory", "fr": "Mémoire par mot"],
        "words.sub": ["zh": "最需要复习的排在前面，点击查看单词的遗忘曲线", "en": "Sorted by current recall; click a word for its curve", "fr": "Triés par rétention ; cliquez pour la courbe"],
        "words.empty": ["zh": "还没有学过的词。点「开始今日学习」开始吧。", "en": "No words studied yet. Press Start today.", "fr": "Aucun mot étudié. Appuyez sur Commencer."],
        "due.now": ["zh": "现在复习", "en": "Due now", "fr": "À revoir"],
        "now": ["zh": "现在", "en": "now", "fr": "maint."],
        "word.sub": [
            "zh": "每次复习把记忆拉回 100%，曲线越来越平缓 = 记得越来越牢。圆点颜色是当次的记忆程度。",
            "en": "Each review resets recall to 100%; flatter curves mean stronger memory. Dot colour shows your rating.",
            "fr": "Chaque révision remet à 100 % ; plus la courbe est plate, plus la mémoire est solide."
        ],
        "word.retention": ["zh": "当前记忆", "en": "Recall now", "fr": "Rétention"],
        "word.stability": ["zh": "记忆强度", "en": "Stability", "fr": "Stabilité"],
        "word.reviews": ["zh": "复习次数", "en": "Reviews", "fr": "Révisions"],
        "word.lapses": ["zh": "遗忘次数", "en": "Lapses", "fr": "Oublis"],
        "word.next": ["zh": "下次复习", "en": "Next review", "fr": "Prochaine"],
        "newPerDay": ["zh": "每日新词数", "en": "New words per day", "fr": "Nouveaux mots par jour"],
        "dur.hours": ["zh": "小时", "en": "h", "fr": "h"],
        "dur.days": ["zh": "天", "en": "days", "fr": "j"],
        "dur.months": ["zh": "个月", "en": "months", "fr": "mois"],
        "cat.examples": ["zh": "例句", "en": "Examples", "fr": "Exemples"],
        "cat.usage": ["zh": "用法说明", "en": "Usage", "fr": "Usage"],
        "cat.expressions": ["zh": "常用表达", "en": "Expressions", "fr": "Expressions"],
        "cat.related": ["zh": "相关词汇", "en": "Related", "fr": "Vocabulaire lié"],
        "cat.grammar": ["zh": "语法", "en": "Grammar", "fr": "Grammaire"],
        "tap.learn": ["zh": "新词：先看一遍，记住它", "en": "New word: take a look first", "fr": "Nouveau mot : regardez-le"],
        "learn.badge": ["zh": "新词 · 学习中", "en": "New word · learning", "fr": "Nouveau · apprentissage"],
        "learn.continue": ["zh": "认识了，继续", "en": "Got it, next", "fr": "Compris, suivant"],
        "autoSpeak": ["zh": "翻开时自动朗读", "en": "Speak when revealed", "fr": "Lecture automatique"],
        "on": ["zh": "开", "en": "On", "fr": "Oui"],
        "off": ["zh": "关", "en": "Off", "fr": "Non"],
        "start.from": ["zh": "从这个词库开始", "en": "Study deck", "fr": "Paquet"],
        "start.go": ["zh": "开始学习", "en": "Start", "fr": "Commencer"],
        "custom": ["zh": "自定义", "en": "Custom", "fr": "Perso"],
        "reimport": ["zh": "重新导入（保留进度）", "en": "Re-import (keep progress)", "fr": "Réimporter (garder la progression)"],
        "update": ["zh": "更新", "en": "Updates", "fr": "Mises à jour"],
        "update.auto": ["zh": "自动检查更新", "en": "Check automatically", "fr": "Vérifier automatiquement"],
        "update.check": ["zh": "检查更新", "en": "Check now", "fr": "Vérifier"],
        "update.checking": ["zh": "正在检查…", "en": "Checking…", "fr": "Vérification…"],
        "update.latest": ["zh": "已是最新版本", "en": "Up to date", "fr": "À jour"],
        "update.current": ["zh": "当前版本", "en": "Current", "fr": "Version"],
        "update.available": ["zh": "新版本可用：", "en": "New version:", "fr": "Nouvelle version :"],
        "update.install": ["zh": "更新并重启", "en": "Update & restart", "fr": "Mettre à jour"],
        "update.later": ["zh": "稍后", "en": "Later", "fr": "Plus tard"],
        "update.downloading": ["zh": "正在下载更新…", "en": "Downloading update…", "fr": "Téléchargement…"],
        "update.installing": ["zh": "正在安装，即将重启…", "en": "Installing, restarting…", "fr": "Installation…"],
        "update.page": ["zh": "打开下载页", "en": "Open download page", "fr": "Page de téléchargement"],
        "update.err.check": ["zh": "无法连接 GitHub 检查更新", "en": "Couldn’t reach GitHub", "fr": "GitHub injoignable"],
        "update.err.download": ["zh": "更新下载失败，请稍后再试", "en": "Download failed, try again later", "fr": "Échec du téléchargement"],
        "update.err.signature": ["zh": "更新包签名校验失败，已取消安装", "en": "Update signature check failed; not installed", "fr": "Signature invalide, installation annulée"],
        "update.err.location": ["zh": "请先把 MyVocab 拖进「应用程序」文件夹再更新", "en": "Move MyVocab to Applications first", "fr": "Déplacez MyVocab dans Applications"],
        "err.save": ["zh": "保存失败，请重试：", "en": "Save failed, please retry: ", "fr": "Échec de l’enregistrement : "],
        "err.speak": ["zh": "朗读失败：", "en": "Speech failed: ", "fr": "Échec de la lecture : "],
        "home.title": ["zh": "词库", "en": "Decks", "fr": "Paquets"],
        "home.subtitle": ["zh": "法语词汇与记忆", "en": "French words, remembered", "fr": "Le français, mot à mot"],
        "builtin": ["zh": "内置", "en": "Built-in", "fr": "Intégré"],
        "imported": ["zh": "已导入", "en": "Imported", "fr": "Importés"],
        "numbers.name": ["zh": "法语数字", "en": "French numbers", "fr": "Les nombres"],
        "numbers.desc": ["zh": "0 – 9999，四档随机", "en": "0 – 9999 in four levels", "fr": "0 – 9999, quatre niveaux"],
        "import": ["zh": "导入本地词库", "en": "Import local deck", "fr": "Importer un fichier"],
        "import.desc": ["zh": "Anki .apkg · CSV · TXT", "en": "Anki .apkg · CSV · TXT", "fr": "Anki .apkg · CSV · TXT"],
        "catalog": ["zh": "浏览 AnkiWeb 词库", "en": "Browse AnkiWeb", "fr": "Catalogue AnkiWeb"],
        "catalog.desc": ["zh": "多语言等级筛选 · 粘贴链接直导", "en": "By language & level · paste link", "fr": "Par langue et niveau · lien direct"],
        "import.failed": ["zh": "导入失败", "en": "Import failed", "fr": "Échec de l’importation"],
        "err.anki21b": [
            "zh": "这是新版 Anki 格式。请在 Anki 导出时勾选「支持旧版 Anki」后再导入。",
            "en": "This is the newer Anki format. Re-export with “Support older Anki versions” checked.",
            "fr": "Format Anki récent. Réexportez en cochant « Prise en charge des anciennes versions »."
        ],
        "err.empty": ["zh": "没有找到卡片。", "en": "No cards found.", "fr": "Aucune carte trouvée."],
        "err.unreadable": ["zh": "无法读取这个文件。", "en": "Could not read this file.", "fr": "Fichier illisible."],
        "cards": ["zh": "张卡片", "en": "cards", "fr": "cartes"],
        "delete": ["zh": "删除", "en": "Delete", "fr": "Supprimer"],
        "ok": ["zh": "好", "en": "OK", "fr": "OK"],
        "settings": ["zh": "设置", "en": "Settings", "fr": "Réglages"],
        "language": ["zh": "界面语言", "en": "Language", "fr": "Langue"],
        "appearance": ["zh": "外观", "en": "Appearance", "fr": "Apparence"],
        "system": ["zh": "跟随系统", "en": "System", "fr": "Système"],
        "light": ["zh": "白天", "en": "Light", "fr": "Jour"],
        "dark": ["zh": "夜间", "en": "Dark", "fr": "Nuit"],
        "warm": ["zh": "护眼", "en": "Eye care", "fr": "Confort"],
        "accent": ["zh": "主题配色", "en": "Theme", "fr": "Thème"],
        "mode": ["zh": "显示模式", "en": "Display", "fr": "Affichage"],
        "sec.look": ["zh": "外观", "en": "Appearance", "fr": "Apparence"],
        "sec.study": ["zh": "学习", "en": "Study", "fr": "Étude"],
        "sec.general": ["zh": "通用", "en": "General", "fr": "Général"],
        "sec.data": ["zh": "数据与同步", "en": "Data & sync", "fr": "Données et synchro"],
        "data.location": ["zh": "数据位置", "en": "Data folder", "fr": "Dossier des données"],
        "data.reveal": ["zh": "在访达中显示", "en": "Show in Finder", "fr": "Afficher dans le Finder"],
        "data.decks": ["zh": "词库", "en": "Decks", "fr": "Paquets"],
        "data.summary": ["zh": "%d 个词库 · %d 张卡片 · 已学 %d", "en": "%d decks · %d cards · %d studied", "fr": "%d paquets · %d cartes · %d vues"],
        "sync": ["zh": "iCloud 同步", "en": "iCloud sync", "fr": "Synchro iCloud"],
        "sync.on": ["zh": "已开启，词库与复习记录自动同步", "en": "On; decks and reviews sync automatically", "fr": "Activée ; paquets et révisions synchronisés"],
        "sync.unavailable": ["zh": "此版本未启用 iCloud（本地构建），数据仅保存在本机", "en": "Not available in this build; data stays on this Mac", "fr": "Indisponible dans cette version ; données locales"],
        "sync.isolated": ["zh": "隔离运行中，同步已关闭", "en": "Isolated run; sync is off", "fr": "Exécution isolée ; synchro désactivée"],
        "settings.sub.group": ["zh": "每组先复习到期词，再补新词", "en": "Due words first, then new ones", "fr": "Révisions d’abord, puis nouveaux mots"],
        "settings.sub.new": ["zh": "每天最多引入的新词", "en": "Most new words introduced each day", "fr": "Nouveaux mots maximum par jour"],
        "settings.sub.speak": ["zh": "显示答案时朗读法语", "en": "Read the French aloud on reveal", "fr": "Lire le français à l’affichage"],
        "back": ["zh": "词库", "en": "Decks", "fr": "Paquets"],
        "tap.reveal": ["zh": "点击显示答案", "en": "Click to reveal", "fr": "Cliquez pour révéler"],
        "tap.next": ["zh": "点击下一个", "en": "Click for next", "fr": "Cliquez pour le suivant"],
        "keys.deck": [
            "zh": "空格 显示/下一个 · D 说明 · → 跳过 · S 朗读",
            "en": "Space reveal/next · D notes · → skip · S listen",
            "fr": "Espace révéler/suivant · D notes · → passer · S écouter"
        ],
        "details.show": ["zh": "展开说明", "en": "Show notes", "fr": "Voir les notes"],
        "details.hide": ["zh": "收起说明", "en": "Hide notes", "fr": "Masquer les notes"],
        "keys": [
            "zh": "空格 显示/下一个 · → 跳过 · S 朗读",
            "en": "Space reveal/next · → skip · S listen",
            "fr": "Espace révéler/suivant · → passer · S écouter"
        ],
        "seen": ["zh": "已看", "en": "seen", "fr": "vus"],
        "listen": ["zh": "朗读", "en": "Listen", "fr": "Écouter"],
        "accent.sage": ["zh": "鼠尾草", "en": "Sage", "fr": "Sauge"],
        "accent.blue": ["zh": "雾蓝", "en": "Blue", "fr": "Bleu"],
        "accent.gold": ["zh": "琥珀", "en": "Gold", "fr": "Or"],
        "accent.rose": ["zh": "玫瑰", "en": "Rose", "fr": "Rose"],
        "accent.violet": ["zh": "紫藤", "en": "Violet", "fr": "Violet"],
        "accent.terracotta": ["zh": "陶土", "en": "Terracotta", "fr": "Terre cuite"],
    ]
}
