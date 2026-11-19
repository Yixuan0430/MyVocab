import Foundation

enum CatalogLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case french, english, japanese, german, spanish, korean, chinese, russian, arabic, hebrew

    var id: String { rawValue }
    var searchQuery: String { rawValue }

    var speechCode: String {
        switch self {
        case .french: "fr-FR"
        case .english: "en-US"
        case .japanese: "ja-JP"
        case .german: "de-DE"
        case .spanish: "es-ES"
        case .korean: "ko-KR"
        case .chinese: "zh-CN"
        case .russian: "ru-RU"
        case .arabic: "ar-SA"
        case .hebrew: "he-IL"
        }
    }

    var shortCode: String {
        switch self {
        case .french: "FR"
        case .english: "EN"
        case .japanese: "JA"
        case .german: "DE"
        case .spanish: "ES"
        case .korean: "KO"
        case .chinese: "ZH"
        case .russian: "RU"
        case .arabic: "AR"
        case .hebrew: "HE"
        }
    }

    func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.french, .zh): "法语"
        case (.french, .en): "French"
        case (.french, .fr): "Français"
        case (.english, .zh): "英语"
        case (.english, .en): "English"
        case (.english, .fr): "Anglais"
        case (.japanese, .zh): "日语"
        case (.japanese, .en): "Japanese"
        case (.japanese, .fr): "Japonais"
        case (.german, .zh): "德语"
        case (.german, .en): "German"
        case (.german, .fr): "Allemand"
        case (.spanish, .zh): "西班牙语"
        case (.spanish, .en): "Spanish"
        case (.spanish, .fr): "Espagnol"
        case (.korean, .zh): "韩语"
        case (.korean, .en): "Korean"
        case (.korean, .fr): "Coréen"
        case (.chinese, .zh): "中文"
        case (.chinese, .en): "Chinese"
        case (.chinese, .fr): "Chinois"
        case (.russian, .zh): "俄语"
        case (.russian, .en): "Russian"
        case (.russian, .fr): "Russe"
        case (.arabic, .zh): "阿拉伯语"
        case (.arabic, .en): "Arabic"
        case (.arabic, .fr): "Arabe"
        case (.hebrew, .zh): "希伯来语"
        case (.hebrew, .en): "Hebrew"
        case (.hebrew, .fr): "Hébreu"
        }
    }

    var levels: [CatalogLevel] {
        switch self {
        case .french, .german, .spanish:
            [.all, .a1, .a2, .b1, .b2, .c1c2, .core, .grammar]
        case .japanese:
            [.all, .kana, .n5, .n4, .n3, .n2, .n1, .core]
        case .english:
            [.all, .a1a2, .b1b2, .c1c2, .ielts, .gre, .core]
        case .korean:
            [.all, .hangul, .topik1, .topik2, .core]
        case .chinese:
            [.all, .hsk12, .hsk34, .hsk56, .core]
        case .russian, .arabic, .hebrew:
            [.all, .a1, .a2, .b1, .b2, .c1c2, .core]
        }
    }

    static func infer(from text: String) -> CatalogLanguage? {
        let lower = text.lowercased()
        let checks: [(CatalogLanguage, [String])] = [
            (.french, ["french", "français", "francais", "französisch", "delf", "dalf"]),
            (.japanese, ["japanese", "jlpt", "hiragana", "katakana", "kanji", "genki", "日本語"]),
            (.german, ["german", "deutsch", "goethe", "allemand"]),
            (.spanish, ["spanish", "español", "espanol", "espagnol", "dele"]),
            (.korean, ["korean", "topik", "hangul", "hangeul", "한국어"]),
            (.chinese, ["chinese", "mandarin", "hsk", "pinyin", "中文", "汉语"]),
            (.russian, ["russian", "русский", "russe"]),
            (.arabic, ["arabic", "arabe", "العربية"]),
            (.hebrew, ["hebrew", "hébreu", "עברית"]),
            (.english, ["english", "ielts", "toefl", "gre", "anglais"])
        ]
        for (lang, words) in checks where words.contains(where: { lower.contains($0) }) {
            return lang
        }
        return nil
    }
}

enum CatalogLevel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all
    case a1, a2, b1, b2, c1c2
    case a1a2, b1b2, ielts, gre
    case kana, n5, n4, n3, n2, n1
    case hangul, topik1, topik2
    case hsk12, hsk34, hsk56
    case core, grammar

    var id: String { rawValue }

    func label(_ lang: AppLanguage) -> String {
        switch self {
        case .all:
            return lang == .zh ? "全部" : lang == .fr ? "Tous" : "All"
        case .a1: return "A1"
        case .a2: return "A2"
        case .b1: return "B1"
        case .b2: return "B2"
        case .c1c2: return "C1–C2"
        case .a1a2: return "A1–A2"
        case .b1b2: return "B1–B2"
        case .ielts: return "IELTS / TOEFL"
        case .gre: return "GRE / SAT"
        case .kana:
            return lang == .zh ? "五十音" : "Kana"
        case .n5: return "JLPT N5"
        case .n4: return "JLPT N4"
        case .n3: return "JLPT N3"
        case .n2: return "JLPT N2"
        case .n1: return "JLPT N1"
        case .hangul:
            return lang == .zh ? "韩文字母" : "Hangul"
        case .topik1: return "TOPIK I"
        case .topik2: return "TOPIK II"
        case .hsk12: return "HSK 1–2"
        case .hsk34: return "HSK 3–4"
        case .hsk56: return "HSK 5–6"
        case .core:
            return lang == .zh ? "高频核心" : lang == .fr ? "Fréquence" : "Core / Freq"
        case .grammar:
            return lang == .zh ? "语法动词" : lang == .fr ? "Grammaire" : "Grammar"
        }
    }

    var patterns: [String] {
        switch self {
        case .all: []
        case .a1: [
            #"\ba1\b"#, #"delf\s*a1"#, #"goethe\s*a1"#, #"dele\s*a1"#,
            #"\bbeginner\b"#, #"\bbeginners\b"#, #"débutant"#, #"debutant"#,
            #"\bstarter\b"#, #"\bessential\b"#, #"\bbasic\b"#, #"\bintro\b"#,
            #"\b500\b"#, #"top\s*500"#, #"first\s*500"#, #"a1[\s/\-–]+a2"#
        ]
        case .a2: [
            #"\ba2\b"#, #"delf\s*a2"#, #"goethe\s*a2"#, #"dele\s*a2"#,
            #"\belementary\b"#, #"\b1000\b"#, #"\b1500\b"#, #"\b2000\b"#,
            #"a1[\s/\-–]+a2"#, #"a2[\s/\-–]+b1"#
        ]
        case .b1: [
            #"\bb1\b"#, #"delf\s*b1"#, #"goethe\s*b1"#, #"dele\s*b1"#,
            #"\bintermediate\b"#, #"intermédiaire"#, #"\b3000\b"#,
            #"a2[\s/\-–]+b1"#, #"b1[\s/\-–]+b2"#
        ]
        case .b2: [
            #"\bb2\b"#, #"delf\s*b2"#, #"goethe\s*b2"#, #"dele\s*b2"#,
            #"upper[\s\-]?intermediate"#, #"\b4000\b"#, #"\b5000\b"#,
            #"b1[\s/\-–]+b2"#, #"b2[\s/\-–]+c1"#
        ]
        case .c1c2: [
            #"\bc1\b"#, #"\bc2\b"#, #"c1[\s/\-–]+c2"#, #"\bdalf\b"#,
            #"\badvanced\b"#, #"avancé"#, #"proficiency"#, #"\b10000\b"#
        ]
        case .a1a2: [
            #"\ba1\b"#, #"\ba2\b"#, #"\bbeginner\b"#, #"\belementary\b"#,
            #"\bbasic\b"#, #"\bessential\b"#, #"\bket\b"#, #"\bpet\b"#
        ]
        case .b1b2: [
            #"\bb1\b"#, #"\bb2\b"#, #"\bintermediate\b"#, #"\bfce\b"#,
            #"\b3000\b"#, #"\b4000\b"#, #"\b5000\b"#
        ]
        case .ielts: [#"\bielts\b"#, #"\btoefl\b"#, #"\btoeic\b"#, #"\bcambridge\b"#]
        case .gre: [#"\bgre\b"#, #"\bsat\b"#, #"\bgmat\b"#, #"\bacademic\b"#]
        case .kana: [#"hiragana"#, #"katakana"#, #"\bkana\b"#, #"五十音"#, #"かな"#]
        case .n5: [#"\bn5\b"#, #"jlpt\s*5"#, #"genki\s*(i|1)\b"#, #"minna.*1"#, #"\bbeginner\b"#]
        case .n4: [#"\bn4\b"#, #"jlpt\s*4"#, #"genki\s*(ii|2)\b"#, #"minna.*2"#]
        case .n3: [#"\bn3\b"#, #"jlpt\s*3"#, #"tobira"#, #"\bintermediate\b"#]
        case .n2: [#"\bn2\b"#, #"jlpt\s*2"#, #"sou\s*matome"#, #"shinkanzen"#]
        case .n1: [#"\bn1\b"#, #"jlpt\s*1"#, #"\badvanced\b"#]
        case .hangul: [#"hangul"#, #"hangeul"#, #"alphabet"#, #"한글"#]
        case .topik1: [#"topik\s*(i\b|1\b|2\b)"#, #"\bbeginner\b"#, #"ttmik\s*[1-3]"#]
        case .topik2: [#"topik\s*(ii\b|[3-6]\b)"#, #"\bintermediate\b"#, #"\badvanced\b"#]
        case .hsk12: [#"hsk\s*[12]\b"#, #"hsk[12]\b"#, #"\bbeginner\b"#, #"pinyin"#]
        case .hsk34: [#"hsk\s*[34]\b"#, #"hsk[34]\b"#, #"\bintermediate\b"#]
        case .hsk56: [#"hsk\s*[56]\b"#, #"hsk[56]\b"#, #"\badvanced\b"#]
        case .core: [
            #"frequen"#, #"most\s+common"#, #"most\s+used"#, #"\bcore\b"#,
            #"\bessential\b"#, #"top\s*\d+"#, #"\b5000\b"#, #"\b3000\b"#,
            #"\b2000\b"#, #"\b1000\b"#, #"sentences"#, #"courants"#
        ]
        case .grammar: [
            #"grammar"#, #"grammaire"#, #"grammatik"#, #"gramática"#,
            #"conjugat"#, #"conjugais"#, #"\bverb"#, #"\bverbes\b"#,
            #"tense"#, #"gender"#, #"subjonctif"#, #"article"#
        ]
        }
    }
}

enum CatalogSort: String, CaseIterable, Identifiable, Sendable {
    case recommended, rating, recent, compact, largest

    var id: String { rawValue }

    func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.recommended, .zh): "推荐排序"
        case (.recommended, .en): "Recommended"
        case (.recommended, .fr): "Recommandés"
        case (.rating, .zh): "好评最多"
        case (.rating, .en): "Top rated"
        case (.rating, .fr): "Mieux notés"
        case (.recent, .zh): "最近更新"
        case (.recent, .en): "Recently updated"
        case (.recent, .fr): "Récents"
        case (.compact, .zh): "小巧精炼"
        case (.compact, .en): "Smallest first"
        case (.compact, .fr): "Plus compacts"
        case (.largest, .zh): "词量最大"
        case (.largest, .en): "Largest first"
        case (.largest, .fr): "Plus complets"
        }
    }
}

enum AnkiCatalogFilter {
    static let featuredIDs: [CatalogLanguage: [CatalogLevel: Set<Int64>]] = [
        .french: [
            .all: [893324022, 1089240419, 629972372, 397151029, 212040160, 899883645, 1677131827],
            .a1: [629972372, 397151029, 212040160],
            .a2: [1089240419, 899883645, 397151029],
            .b1: [1089240419, 899883645, 893324022],
            .b2: [893324022, 1677131827],
            .core: [893324022, 1089240419, 899883645, 629972372, 397151029]
        ]
    ]

    static func matchesLevel(_ deck: AnkiWebDeckSummary, language: CatalogLanguage, level: CatalogLevel) -> Bool {
        if level == .all { return true }
        if featuredIDs[language]?[level]?.contains(deck.id) == true { return true }
        let normalized = fold(deck.title)
        return level.patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    static func isFeatured(_ deck: AnkiWebDeckSummary, language: CatalogLanguage, level: CatalogLevel) -> Bool {
        featuredIDs[language]?[level]?.contains(deck.id) == true
    }

    static func apply(
        _ decks: [AnkiWebDeckSummary],
        language: CatalogLanguage,
        level: CatalogLevel,
        query: String,
        onlyAudio: Bool,
        onlyImages: Bool,
        sort: CatalogSort
    ) -> [AnkiWebDeckSummary] {
        let tokens = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = decks.filter { deck in
            if onlyAudio && !deck.hasAudio { return false }
            if onlyImages && !deck.hasImages { return false }
            if !matchesLevel(deck, language: language, level: level) { return false }
            if !tokens.isEmpty {
                let hay = fold(deck.title)
                if !tokens.allSatisfy({ hay.contains($0) }) { return false }
            }
            return true
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .recommended:
                let ls = recommendationScore(lhs, language: language, level: level)
                let rs = recommendationScore(rhs, language: language, level: level)
                if ls != rs { return ls > rs }
                return lhs.thumbsUp > rhs.thumbsUp
            case .rating:
                if lhs.ratingScore != rhs.ratingScore { return lhs.ratingScore > rhs.ratingScore }
                return lhs.thumbsUp > rhs.thumbsUp
            case .recent:
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
                return lhs.ratingScore > rhs.ratingScore
            case .compact:
                let ln = lhs.notes > 0 ? lhs.notes : Int.max
                let rn = rhs.notes > 0 ? rhs.notes : Int.max
                if ln != rn { return ln < rn }
                return lhs.ratingScore > rhs.ratingScore
            case .largest:
                if lhs.notes != rhs.notes { return lhs.notes > rhs.notes }
                return lhs.ratingScore > rhs.ratingScore
            }
        }
    }

    private static func recommendationScore(_ deck: AnkiWebDeckSummary, language: CatalogLanguage, level: CatalogLevel) -> Double {
        var score = Double(deck.ratingScore)
        if isFeatured(deck, language: language, level: level) { score += 10_000 }
        if deck.hasAudio { score += 35 }
        if deck.hasImages { score += 18 }
        if deck.notes >= 50 && deck.notes <= 6000 { score += 12 }
        return score
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

struct CatalogL {
    let lang: AppLanguage
    subscript(_ key: String) -> String { Self.table[key]?[lang.rawValue] ?? key }

    func errorMessage(_ err: AnkiWebError) -> String {
        switch err {
        case .invalidLink: self["err.invalidLink"]
        case .notFound: self["err.notFound"]
        case .accessDenied: self["err.accessDenied"]
        case .rateLimited: self["err.rateLimited"]
        case .network: self["err.network"]
        case .http(let code): "\(self["err.badResponse"]) (HTTP \(code))"
        case .badResponse, .cancelled: self["err.badResponse"]
        }
    }

    private static let table: [String: [String: String]] = [
        "title": ["zh": "AnkiWeb 词库", "en": "AnkiWeb Catalog", "fr": "Catalogue AnkiWeb"],
        "subtitle": [
            "zh": "按语言与阶段筛选共享词库，或直接粘贴 AnkiWeb 链接导入",
            "en": "Browse shared decks by language & level, or paste any AnkiWeb link",
            "fr": "Parcourez par langue et niveau, ou collez un lien AnkiWeb"
        ],
        "link.placeholder": [
            "zh": "粘贴 AnkiWeb 链接或 ID（如 ankiweb.net/shared/info/893324022）",
            "en": "Paste AnkiWeb link or ID (e.g. ankiweb.net/shared/info/893324022)",
            "fr": "Coller un lien ou ID AnkiWeb (ex. ankiweb.net/shared/info/893324022)"
        ],
        "link.open": ["zh": "打开链接", "en": "Open link", "fr": "Ouvrir"],
        "search.local": ["zh": "在当前语言列表内筛选…", "en": "Filter decks in this language…", "fr": "Filtrer dans cette langue…"],
        "search.remote": ["zh": "搜全站 AnkiWeb", "en": "Search AnkiWeb", "fr": "Chercher sur AnkiWeb"],
        "search.remoteMode": ["zh": "全站搜索结果", "en": "AnkiWeb search", "fr": "Recherche AnkiWeb"],
        "search.clearRemote": ["zh": "返回语言分类", "en": "Back to language", "fr": "Retour à la langue"],
        "filter.audio": ["zh": "含发音", "en": "Audio", "fr": "Audio"],
        "filter.images": ["zh": "含图片", "en": "Images", "fr": "Images"],
        "badge.audio": ["zh": "发音", "en": "Audio", "fr": "Audio"],
        "badge.images": ["zh": "图片", "en": "Images", "fr": "Images"],
        "badge.textOnly": ["zh": "纯文本", "en": "Text only", "fr": "Texte seul"],
        "badge.featured": ["zh": "精选", "en": "Featured", "fr": "Sélection"],
        "count.decks": ["zh": "%d 个词库", "en": "%d decks", "fr": "%d paquets"],
        "loading": ["zh": "正在从 AnkiWeb 获取词库列表…", "en": "Loading decks from AnkiWeb…", "fr": "Chargement depuis AnkiWeb…"],
        "loading.detail": ["zh": "正在加载词库详情与示例卡片…", "en": "Loading deck details & sample cards…", "fr": "Chargement des détails et exemples…"],
        "stale.banner": [
            "zh": "AnkiWeb 访问频率受限，当前显示本地缓存",
            "en": "AnkiWeb rate-limited; showing cached results",
            "fr": "Limite AnkiWeb atteinte ; affichage du cache"
        ],
        "empty.level": [
            "zh": "该阶段下暂无匹配的词库，可切换到「全部」或尝试搜索全站",
            "en": "No decks match this filter. Try “All” or search AnkiWeb.",
            "fr": "Aucun paquet pour ce filtre. Essayez « Tous » ou recherchez."
        ],
        "empty.select": [
            "zh": "选择一个词库查看是否含发音、图片、体积与示例卡片",
            "en": "Select a deck to inspect audio, images, file size, and sample cards",
            "fr": "Sélectionnez un paquet pour voir audio, images, taille et exemples"
        ],
        "meta.size": ["zh": "文件大小", "en": "Size", "fr": "Taille"],
        "meta.notes": ["zh": "卡片数", "en": "Notes", "fr": "Cartes"],
        "meta.audio": ["zh": "原库发音", "en": "Deck audio", "fr": "Audio"],
        "meta.images": ["zh": "原库图片", "en": "Deck images", "fr": "Images"],
        "meta.rating": ["zh": "社区评分", "en": "Rating", "fr": "Avis"],
        "meta.updated": ["zh": "更新时间", "en": "Updated", "fr": "Mis à jour"],
        "meta.none": ["zh": "无", "en": "None", "fr": "Aucun"],
        "detail.description": ["zh": "词库简介", "en": "Description", "fr": "Description"],
        "detail.samples": ["zh": "示例卡片", "en": "Sample cards", "fr": "Exemples de cartes"],
        "detail.note": [
            "zh": "说明：原库媒体数量供选词库参考；MyVocab 会提取文本卡片并用系统语音朗读，以保持轻量与 iCloud 快速同步。",
            "en": "Note: Media counts reflect the AnkiWeb package. MyVocab imports card text and uses system TTS for lightweight iCloud sync.",
            "fr": "Note : MyVocab importe le texte des cartes et utilise la synthèse vocale système pour une synchro iCloud légère."
        ],
        "detail.openWeb": ["zh": "在 AnkiWeb 打开", "en": "Open on AnkiWeb", "fr": "Ouvrir sur AnkiWeb"],
        "action.download": ["zh": "下载并导入", "en": "Download & import", "fr": "Télécharger et importer"],
        "action.downloading": ["zh": "正在下载…", "en": "Downloading…", "fr": "Téléchargement…"],
        "action.importing": ["zh": "正在解析卡片…", "en": "Importing cards…", "fr": "Importation…"],
        "action.cancel": ["zh": "取消", "en": "Cancel", "fr": "Annuler"],
        "action.retry": ["zh": "重试", "en": "Retry", "fr": "Réessayer"],
        "action.refresh": ["zh": "刷新", "en": "Refresh", "fr": "Actualiser"],
        "action.openDeck": ["zh": "立即学习此词库", "en": "Open imported deck", "fr": "Ouvrir le paquet"],
        "imported.ok": ["zh": "已成功导入到我的词库", "en": "Imported into your library", "fr": "Importé dans votre bibliothèque"],
        "err.invalidLink": [
            "zh": "请输入有效的 AnkiWeb 词库链接或数字 ID（如 893324022）",
            "en": "Enter a valid AnkiWeb deck URL or numeric ID (e.g. 893324022)",
            "fr": "Saisissez un lien ou ID AnkiWeb valide (ex. 893324022)"
        ],
        "err.notFound": ["zh": "未找到该 AnkiWeb 词库（可能已下架）", "en": "Deck not found on AnkiWeb", "fr": "Paquet introuvable sur AnkiWeb"],
        "err.accessDenied": ["zh": "该词库暂不允许公开下载", "en": "Access to this deck is restricted", "fr": "Accès restreint à ce paquet"],
        "err.rateLimited": [
            "zh": "AnkiWeb 暂时限流，请稍等几秒后重试",
            "en": "AnkiWeb rate limit reached. Please retry in a few seconds.",
            "fr": "Limite AnkiWeb atteinte. Réessayez dans quelques secondes."
        ],
        "err.network": ["zh": "网络连接失败，请检查网络后重试", "en": "Network error. Check connection and retry.", "fr": "Erreur réseau. Vérifiez la connexion."],
        "err.badResponse": ["zh": "AnkiWeb 返回了意外的数据格式", "en": "Unexpected response from AnkiWeb", "fr": "Réponse inattendue d’AnkiWeb"],
        "err.importEmpty": ["zh": "该词库中没有可导入的文本卡片", "en": "No text cards found in this deck", "fr": "Aucune carte texte trouvée"],
        "err.importUnreadable": ["zh": "无法解析下载的 .apkg 文件", "en": "Could not parse the downloaded .apkg file", "fr": "Impossible de lire le fichier .apkg"]
    ]
}
