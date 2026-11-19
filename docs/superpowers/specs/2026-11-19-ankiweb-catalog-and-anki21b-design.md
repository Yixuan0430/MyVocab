# MyVocab AnkiWeb 多语言词库广场、链接直导与 `.anki21b` 支持设计文档

## 1. 目标与背景

用户希望在 MyVocab（macOS 与 iOS 共享源码）中不再局限于手动到浏览器寻找并下载本地 `.apkg` 文件，而是能够：
1. **直接通过 AnkiWeb 共享词库链接或 ID 导入**（如 `https://ankiweb.net/shared/info/893324022` 或 `893324022`）。
2. **在应用内浏览多语言 AnkiWeb 词库排行与分级推荐**，按目标语言自动切换对应的水平分级体系（如法/德/西按 CEFR `A1–C2`，日语按 JLPT `N5–N1`，英语按 `A1–C2 / 雅思托福 / GRE`，韩语按 `TOPIK I/II`，中文按 `HSK 1–6` 等）。
3. **在 Mac 端清晰预览词库元信息后再决定是否下载**：直接展示评分（👍）、卡片数、是否含发音及音频数（🔊）、是否含图片及图片数（🖼）、更新时间，并在详情区显示下载体积（MB）、简介与示例卡片预览。
4. **原生支持现代 `.anki21b`（zstd 压缩 SQLite）词库格式**，避免从 AnkiWeb 下载的新版词库导入报错。
5. **完整保留现有 CloudKit Production 同步与纯文字轻量化数据模型**，无需修改或重新部署 CloudKit Schema。

### 非目标与反目标
- **非目标**：不内置 AnkiWeb 账号登录、不上传/分享词库到 AnkiWeb、不提取或同步 `.apkg` 内的音频/图片媒体文件。
- **反目标**：不得在切换等级或输入搜索词时高频触发 AnkiWeb 网络请求导致 `HTTP 429` 限流；不得因新增词库语言字段破坏现有 CloudKit Production 同步或历史 `decks/*.json` 兼容性；不得在隔离测试或 `--snapshot` 模式下发起真实网络请求。

---

## 2. 方案对比与选型结论

- **方案 A（已选定）**：AnkiWeb 多语言分层词库广场 + 链接直导 + 原生 `.anki21b`（`libzstd`）解压 + 多语言自动系统语音朗读；保留纯文本卡片与现有 CloudKit 轻量同步，词库广场中的音频/图片计数作为选卡与体积评估信息。
- **方案 B（未选）**：在方案 A 基础上额外提取并本机缓存 `.apkg` 原声 mp3 与图片。复杂度显著上升，且多台 Mac 经 CloudKit 同步后另一台设备缺少原包媒体文件会导致跨端体验割裂。

用户已确认采用 **方案 A**，并同意为全局 `check_no_comments.py` 仅豁免 `Package.swift` 第 1 行 SwiftPM 强制语法头 `// swift-tools-version:`（以便接入官方 `facebook/zstd` 依赖）。

---

## 3. 架构与核心设计

### 3.1 AnkiWeb 公开协议层（`AnkiWebClient.swift`）
基于对 `ankiweb.net` 实测验证的公开免登录 Protobuf 接口：
- **排行列表**：`GET https://ankiweb.net/svc/shared/list-decks?search=<query>`
  - 返回 `ListDecksResponse`（field `1` 重复 `DeckRow`）：`1:id`、`2:title`、`3:thumbs_up`、`4:thumbs_down`、`5:mtime`、`6:notes`、`7:audio`、`8:images`。
  - 单次请求即可返回该语言的全部共享词库（如 `french` 一次返回 ~764 条，仅约 43 KB）。
- **词库详情**：`GET https://ankiweb.net/svc/shared/item-info?sharedId=<id>`
  - 返回 `ItemInfoResponse`（`1:available` / `2:missing` / `3:access_denied`），内含 `title`、`tags`、`size`（字节）、`last_updated`、`description`、`thumbs_up`、`thumbs_down`、`original_deck_name`，以及 `deck`（`notes`、`audio`、`images`、`sample_notes` 字段名/值、`download_key`）。
- **直链下载**：`GET https://ankiweb.net/svc/shared/download-deck/<id>?t=<downloadKey>`
  - 返回 `.apkg` ZIP 字节流；流式写入临时目录并实时上报字节下载进度，支持取消任务；导入完成或失败后自动清理临时 `.apkg`。
- **链接与 ID 解析**：接受以下输入格式并提取 `sharedId`（正整数）：
  - `https://ankiweb.net/shared/info/893324022`（含 query / trailing slash / `http` / `www.`）
  - `/shared/info/893324022`
  - 纯数字 ID `893324022`
- **抗限流与缓存策略（关键）**：
  - 实测 AnkiWeb 对短时间连续请求会返回 `HTTP 429`。
  - 按语言查询 `list-decks` 结果同时缓存于内存和 `~/Library/Caches/com.yixuanwu.lexikos/ankiweb/`（TTL 15 分钟）；切换等级、过滤音频/图片、排序、实时输入搜索**全部在本地内存中完成（0 额外网络请求）**。
  - `item-info` 按 `sharedId` 缓存于内存（TTL 10 分钟）；点击下载时若缓存超过 4 分钟或 `download-deck` 返回 403/404，自动刷新一次 `item-info` 获取新 `download_key` 后重试。
  - 遇到 `HTTP 429` 时：优先展示过期缓存并提示“AnkiWeb 请求频繁，已显示缓存列表”；无缓存时给出清晰的多语言限流提示，不静默失败。
  - 构造器支持注入自定义 `URLSession` / 数据获取闭包，便于单测离线验证并确保 `--snapshot` / 测试不发外网请求。

### 3.2 多语言与分级推荐引擎（`AnkiCatalog.swift`）
- **支持语言（AnkiWeb 全部 10 个语言分类）**：
  - 法语（`fr` / `fr-FR`）、英语（`en` / `en-US`）、日语（`ja` / `ja-JP`）、德语（`de` / `de-DE`）、西班牙语（`es` / `es-ES`）、韩语（`ko` / `ko-KR`）、中文（`zh` / `zh-CN`）、俄语（`ru` / `ru-RU`）、阿拉伯语（`ar` / `ar-SA`）、希伯来语（`he` / `he-IL`）。
- **按语言匹配的等级筛选器**：
  - 法语 / 德语 / 西班牙语：`全部排行`、`A1`、`A2`、`B1`、`B2`、`C1–C2`、`高频核心`、`动词与语法`
  - 日语：`全部排行`、`入门/假名`、`N5`、`N4`、`N3`、`N2`、`N1`、`高频核心`
  - 英语：`全部排行`、`A1–A2`、`B1–B2`、`C1–C2`、`IELTS / TOEFL`、`GRE / SAT`、`高频核心`
  - 韩语：`全部排行`、`入门/韩文`、`TOPIK I`、`TOPIK II`、`高频核心`
  - 中文：`全部排行`、`HSK 1–2`、`HSK 3–4`、`HSK 5–6`、`高频核心`
  - 俄语 / 阿拉伯语 / 希伯来语：`全部排行`、`入门 A1–A2`、`进阶 B1–B2`、`高阶 C1–C2`、`高频核心`
- **本地多信号分级匹配与排序**：
  - 结合标题显式等级关键词（正则词边界，如 `\bA1\b`、`DELF A1`、`JLPT N5`、`HSK 1`、`TOPIK I`、`beginner`、`essential`、`starter`、`débutant`、`Anfänger`、`básico` 等）、词库规模适配度（如 A1 优先小中体量 100–2,500 词入门包）与社区高口碑词库加权（基于实测存在的高分 `sharedId` 标记「推荐」徽章，元数据仍全部实时来自 AnkiWeb）。
  - 筛选开关：`🔊 含发音`（`audio > 0`）、`🖼 含图片`（`images > 0`）；排序方式：`综合推荐`、`评分最高`、`最近更新`、`入门精简（卡片较少）`、`词量最多`。
  - 顶部搜索框默认即时过滤当前语言列表；当用户按回车且本地结果少时，提供显式按钮「在 AnkiWeb 全站搜索」触发单次远端查询。

### 3.3 原生 `.anki21b`（zstd）与 SQLite `unicase` 解析（`ZstdDecompress.swift` + `Decks.swift` + `AnkiImport.swift`）
- **依赖接入**：在 `Package.swift` 与 `project.yml` 接入官方 `https://github.com/facebook/zstd.git`（锁定精确版本 `1.5.7`，产品 `libzstd`），兼容 macOS Universal（`x86_64` + `arm64`）与 iOS。
- **流式安全解压（`ZstdDecompress.swift`）**：
  - 校验 Zstd 魔数 `0x28 0xB5 0x2F 0xFD`（若非 zstd 则直接按原始 SQLite 处理）。
  - 使用 `ZSTD_createDStream` / `ZSTD_decompressStream` 分块解压写入临时文件，强制上限 **256 MiB** 防解压炸弹。
- **解析优先级修正（`Decks.swift`）**：
  - `.apkg` 解压后优先检查 `collection.anki21b`（因为新版 Anki 导出的包里 `collection.anki2` 往往只是 1 条“请更新 Anki”占位记录，真实数据在 `collection.anki21b`），解压成功即打开 SQLite；若不存在则依次回退 `collection.anki21`、`collection.anki2`。
- **SQLite `unicase` 排序规则（`Decks.swift`）**：
  - `sqlite3_open_v2` 打开后通过 `sqlite3_create_collation_v2` 注册 `unicase`（UTF-8 大小写不敏感比较），避免现代 Anki SQLite 查询因缺少自定义 collation 失败。
- **卡片字段映射（`AnkiImport.swift`）**：
  - 兼容 `.anki21b` 的 `notetypes` / `fields` / `templates` 表结构，保持现有参数化绑定查询与安全 protobuf 模板解码。

### 3.4 多语言数据模型与系统朗读适配（`Decks.swift`、`Speaker.swift`、`PracticeView.swift`、`CardLayout.swift`）
- `Deck` 新增向后兼容可选属性 `var language: String?`（默认 `nil`），本地持久化于 `decks/*.json`，从词库广场按语言下载导入时自动写入对应 BCP-47 代码（如 `"fr-FR"`、`"ja-JP"`、`"de-DE"`）。
- **CloudKit 零破坏**：`Sync.swift` 继续仅读写现有 Production Schema 的 `Deck.name` 与 `Deck.cards`，不新增 CloudKit 字段；跨设备拉取后若本地 `language == nil`，`PracticeView` 与 `Speaker` 根据卡片内容自动识别语言（法语词库保持原 `fr-FR` 行为，非拉丁语系或明确其他语种自动使用对应语言朗读）。
- `CardParts` 支持传入目标语言提示（默认法语），确保例句朗读按钮与语音语言一致。

### 3.5 交互与界面设计（`AnkiCatalogView.swift`、`AnkiCatalogDetail.swift`、`LexikosApp.swift`）
- **入口**：首页 `HomeView` 的「已导入」分区中，除原有「导入本地文件（.apkg / CSV / TXT）」外，新增并列卡片 **「发现 AnkiWeb 词库」**（以及导入菜单/快捷按钮支持直接粘贴链接），延续 MyVocab 现有纸张质感卡片（`paperCard`）、`Didot` 标题、胶囊按钮与 11 套主题配色体系，适配白天 / 夜间 / 护眼三种模式与中/英/法三语界面。
- **Mac 端双栏布局（宽屏 >= 760pt）与窄屏/iOS 自适应**：
  - 顶部栏：返回按钮 + 标题「AnkiWeb 词库广场」+ **链接/ID 直导输入框**（输入链接或 ID 点「解析/查看」立即在右侧展开详情并一键下载）。
  - 筛选区：横向语言胶囊条（10 语种）→ 该语言专属等级胶囊条 → 搜索框 + `🔊 含发音` / `🖼 含图片` 过滤芯片 + 排序下拉菜单。
  - 左栏列表：显示词库名称、精选推荐徽章、已导入标记、卡片数、**🔊 音频数徽章**（有音频高亮/无音频弱化）、**🖼 图片数徽章**、👍 评分与更新时间。
  - 右栏详情（窄屏或 iOS 点击列表项以 Sheet 弹出）：
    - 词库名、AnkiWeb 原页链接、标签
    - 信息卡片：文件体积（MB）、卡片数、发音音频数、图片数、好评数、最后更新
    - 简介文本（清理 HTML）+ **示例卡片预览**（直接展示 AnkiWeb `sample_notes` 前几张卡）
    - 底部轻量提示（仅导入文字并经系统语音朗读、轻量同步 iCloud）+ 主操作按钮「下载并导入（xx MB）」/ 实时进度条 + 取消按钮。
  - 覆盖完整状态：首次加载态、空筛选态（附一键重置筛选 / 全站搜索）、限流 429 降级态、网络失败重试态、下载中进度态、导入成功反馈态。

---

## 4. 模块与文件拆分（符合 L1–L7 与零注释门禁）

| 文件 | 职责 | 预计行数 |
| --- | --- | --- |
| `Sources/Lexikos/ZstdDecompress.swift`（新增） | `libzstd` 流式解压与 256 MiB 防护 | ~75 |
| `Sources/Lexikos/AnkiWebClient.swift`（新增） | Protobuf 解码、链接/ID 解析、API 请求、磁盘缓存、带进度下载 | ~260 |
| `Sources/Lexikos/AnkiCatalog.swift`（新增） | 10 语言定义、分级体系、本地匹配评分与媒体过滤引擎 | ~270 |
| `Sources/Lexikos/AnkiCatalogView.swift`（新增） | 词库广场主页面、链接直导栏、语言/等级/媒体筛选与列表 | ~340 |
| `Sources/Lexikos/AnkiCatalogDetail.swift`（新增） | 详情面板、示例卡片预览、下载进度条与导入触发 | ~230 |
| `Sources/Lexikos/Decks.swift`（修改） | `Deck.language`、`.anki21b` 优先解析、SQLite `unicase` 注册、按语言导入 | ~280 |
| `Sources/Lexikos/PracticeView.swift` / `Speaker.swift` / `CardLayout.swift`（修改） | 多语言朗读选择（保留法语默认兼容） | 各 <480 |
| `Sources/Lexikos/LexikosApp.swift` / `Theme.swift`（修改） | 新增 `.catalog` 路由、首页入口与中英法三语文案 | 各 <500 |
| `Package.swift` & `project.yml`（修改） | 引入 `facebook/zstd` `1.5.7`（`libzstd`） | — |
| `Tests/LexikosTests/AnkiCatalogTests.swift`（新增） | Protobuf 解码、链接解析、多语言分级筛选、媒体过滤、`.anki21b` zstd + `unicase` 端到端单测、429 缓存降级单测 | ~220 |

---

## 5. 验证标准

1. **单元测试**：`swift test` 覆盖真实 zstd 压缩的 `.anki21b`（含 `unicase` 排序规则）导入、Protobuf 列表/详情/示例卡解析、链接与 ID 提取、10 语言分级与音频/图片过滤、429 缓存降级与网络错误恢复。
2. **全仓静态门禁**：`./scripts/check.sh` 与全局 `lint-gate.sh` 零错误零警告通过（含 `check_no_comments.py` 仅豁免 `Package.swift` 第 1 行 `// swift-tools-version:` 后的全套回归测试 `test-lint-gate.sh`）。
3. **跨架构与跨平台构建**：`./release.sh --export-only`（macOS Universal `x86_64` + `arm64` Developer ID + CloudKit Production）与 `xcodebuild -scheme Lexikos-iOS CODE_SIGNING_ALLOWED=NO build` 均编译通过。
4. **实机与真包验证**：隔离目录 `--snapshot` 视觉验证 + 真实从 AnkiWeb 链接下载导入一款法语 A1 词库验证端到端闭环（不触碰正式学习数据）。
