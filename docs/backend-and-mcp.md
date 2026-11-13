# MyVocab 后端运行与本地查询

应用展示名、SwiftPM 产品和应用可执行文件为 MyVocab，版本 1.1.0。保留 Swift 模块/工程/目标名 Lexikos，避免无必要的源路径变更。保留原图标、Bundle ID `com.yixuanwu.lexikos`、数据目录 `~/Library/Application Support/Lexikos`、原偏好键、CloudKit、App Group 和 Widget kind。URL scheme 同时接受 `lexikos://` 和 `myvocab://`。

## 隔离验收

```sh
swift build
"$(swift build --show-bin-path)/MyVocab" --snapshot /tmp/myvocab-png --data-dir /tmp/myvocab-fixture --no-sync --no-migration
```

数据根目录优先级：`--data-dir` > `MYVOCAB_DATA_DIR` > `LEXIKOS_DATA` > 原 Lexikos 目录。提供自定义根目录或使用 `--snapshot` 时，自动禁用旧目录迁移、CloudKit、iCloud 设置同步、Widget 写入和自动更新检查，并使用独立的临时偏好域。截图未指定根目录时读取临时空目录。可用 `--defaults-domain <独立域名>` 指定复用的测试偏好；不要将正式偏好域用于截图。

`--no-migration`、`--no-sync` 也能单独使用。传给 `DeckStore(root:)` 和 `ProgressStore(dir:)` 的自定义路径不会运行全局旧目录迁移。

## 只读 MCP

提供一个 stdio 适配器 `scripts/myvocab-mcp.py`（Python 3，无第三方依赖）。打包后同一脚本位于 `MyVocab.app/Contents/Resources/`。它通过可执行文件的 `--learning-report` 查询磁盘，读取期间不创建目录、不转换旧快照、不启动窗口、不写学习数据、不联网同步。报告包含最近 1–365 天（默认 7 天）的复习次数、今日复习次数、词库概况和最多 1000 条近期事件。事件按日期和 UUID 倒序；截断时 `eventsTruncated=true`。时间为 ISO 8601，今日按本机日历；`grade` 为 1 忘记、2 模糊、3 记住，`seed` 为旧快照载入而非复习。卡片只输出稳定标识，不输出词条内容。

MCP 客户端配置示例（安装后）：

```json
{
  "mcpServers": {
    "myvocab": {
      "command": "python3",
      "args": [
        "/Applications/MyVocab.app/Contents/Resources/myvocab-mcp.py",
        "--executable", "/Applications/MyVocab.app/Contents/MacOS/MyVocab",
        "--data-dir", "/Users/Yixuan/Library/Application Support/Lexikos"
      ]
    }
  }
}
```

工具：`myvocab_recent_learning`，参数 `{"days": 7}`。支持 initialize / ping / tools/list / tools/call，以及 2024-11-05 至 2025-11-25 的握手版本；未声明新版无握手协议支持。工具执行错误以 `isError=true` 返回。接口仅本机标准输入输出，不监听网络端口；权限等同启动进程的本机用户。本次不改任何客户端现有配置。

也可直接查询：

```sh
/Applications/MyVocab.app/Contents/MacOS/MyVocab --learning-report --days 7
```

接口结构遵循 [MCP 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) 和 [工具协议](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)。

## 持久化和迁移

词库及进度日志使用原子文件提交，成功后才改变内存并通知同步；失败通过 Store.lastError 和界面提示显露，学习队列不前进。为避免半行和失败追加污染，进度目前原子重写单词库日志；较大历史下应测量后再实现日志检查点，不能把性能优化替代可靠提交。

损坏日志保留原文件，阻止继续写入对应词库并给出诊断，避免重写时丢弃无法解析行。旧快照转换保留 `.json.legacy`；转换失败可重启重试。更旧 Nombres 目录复制至暂存目录、逐文件字节比对后再提交 Lexikos 目录，保留来源；若 Lexikos 已存在，不覆盖、不合并。

删除词库在 `deleted-decks.json` 持久保存 UUID 墓碑（以墓碑为提交点，词库 JSON 暂保留用于恢复）。同步启动重发删除，并将不可变删除标记写入现有 CloudKit Event 类型的独立记录（无需新增记录类型）；新客户端先应用删除标记，阻止旧设备重新上传同 UUID；重新导入新 UUID 可重新添加。复习日志仍保留。

云端下载只有本地提交成功才记为已处理。写入失败删除同步游标并禁止保存后续游标，下次启动完整重新抓取；当前进程没有自动重建引擎，磁盘修复后需重启。CloudKit 仍需真实账号验证。账户切换行为沿用原策略：保留本地数据，后续登录会上传至新账户。

## 更新与打包

更新器从 `Yixuan0430/MyVocab` 获取发布，拒绝失败 HTTP 状态；检查 Team ID、Bundle ID、发布版本及版本递增。兼容 DMG 中 MyVocab.app / Lexikos.app，同卷暂存新版；退出后将原包移动至唯一备份，再将新版移至 MyVocab.app，失败恢复原位置。路径使用静态脚本的独立参数传入。若同目录已存在另一个 MyVocab.app，则拒绝覆盖。备份保留供回退。

`bundle.sh` 是不含 CloudKit/Widget 的快速包；正式发布走 `release.sh` / Xcode，输出 `MyVocab-1.1.0.dmg`。正式发布缺少公证凭据时以失败退出。本轮不运行发布、安装替换或实际更新。
