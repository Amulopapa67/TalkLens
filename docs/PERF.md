# 性能实测

> 预算见下表（项目目标里的质量预算）。每次实测写清楚：日期、机器、macOS、KakaoTalk 版本、方法、样本数、结果。

| 指标 | 预算 | 实测 | 方法 | 日期 |
|---|---|---|---|---|
| 新消息 → 译文 p50 / p95 | ≤ 600 / 1500 ms | **82 / 84 ms**（n=2，样本偏少，需补到 ≥ 20） | App 内打点（D-027 的采样规则），`log stream` 读 stats 行 | 2026-10-11 |
| 快照解析 p95（≤ 200 行） | ≤ 30 ms | **4.1 ms**（合成 205 行，全部行；真机 8 行 1.1–1.3 ms） | `tlctl bench fixtures/snapshots`（release，50 次）；`tlctl probe --summary` | 2026-10-10 |
| diff p95 | ≤ 5 ms | **0.03 ms** | `tlctl bench fixtures/snapshots` | 2026-10-10 |
| Apple 翻译单条 p50 / p95 | （记录） | **21.9 / 65.7 ms**（28 条逐条）；批量 28 条 500 ms | `tlctl selftest --engine apple --source ko --target zh-Hans --input fixtures/test_messages_ko.txt`（debug 构建，冷启动首条 111 ms） | 2026-10-10 |
| 空闲 CPU（60 s） | ≤ 1% | **0.0%**（TalkLens，KakaoTalk 开着 1 个窗口、无变化时） | `ps -o %cpu,rss -p <pid>`（单点采样） | 2026-10-11 |
| 常驻内存 | ≤ 120 MB | **71 MB** RSS | `ps -o rss`（多窗口会话版本） | 2026-10-11 |
| 侧栏跟随延迟 | ≤ 100 ms | | | |

## 记录

### 2026-10-10 — Apple 翻译 selftest

- 机器：Apple Silicon，macOS 27.2，KakaoTalk 26.8.0（不涉及），翻译语言 ko、zh-Hans 已安装，走 macOS 26+ 的无 UI session。
- 结果：28/28 成功；逐条 p50 21.9 ms、p95 65.7 ms、最大 111 ms（首条，含 session 建立）；28 条一批 500 ms。
- 观察（决定了预处理的必要性，见 D-010）：
  - `ㅇㅋ ㄱㄱ` 被翻成乱码 → 走 jamoOnly + 词表注释，不送翻译。
  - URL 首字母被改成大写 `Https://` → URL 作为 keep 段不送翻译。
  - `@린루이` 被音译成 `@林瑞` → @提及作为 keep 段。
  - 多行消息的每个换行被翻成两个 → 按换行切段后拼回。
  - `랩미팅`、`보강` 有误译（"说唱会议"出现在 translation_check 的单句测试里，`보강` 被翻成"强化"）→ 词表 chip。

### 2026-10-11 — App 内实测读取耗时（`log stream` 抓取 30 s 一次的 stats 行，只有数字）

- 读取（增量读取、行缓存）：25 次，p50 **6.8 ms**、p95 305 ms（p95 来自冷读：第一次定位并分析可见行）；失败 0 次。
- 每次读取分析的行数：p50 1、p95 13（行缓存命中时为 0–1）。
- ingest（diff + 预处理）：p50 0.9 ms、p95 1.9 ms。
- 覆盖层快速跟踪：221 帧，重新对齐 25 次。
- KakaoTalk 重启后读 나와의 채팅：`tlctl probe` 显示 parse 2.3 ms；商业账号窗口第一次增量读取 186 ms（分析 6 行），第二次 1.8 ms。
- 还没测：新消息 → 译文的 p50/p95（这段时间没有新消息到达，样本数为 0）、侧栏跟随延迟。测法：运行中执行 `log stream --level info --predicate 'subsystem == "dev.lipper.TalkLens" AND eventMessage CONTAINS "stats"'`，看 `translation[...]` 和 `follow[...]`；需要 ≥ 20 条新消息。

### 2026-10-11 — 启动时间线和新消息延迟（D-027 之后）

- 冷启动（距 App 启动的毫秒数）：
  - firstEnumeration 208、firstReadStarted 214；
  - warmUp 232（预热翻译 58 ms）；
  - firstRead 464、firstIngest 467；
  - **firstTranslation 966**。
- 改之前：聊天窗口被完全遮挡时一直不读，第一批译文要等约 12 s，第一批翻译 619 ms（冷模型）。
- 新消息 → 译文（Lipper 在 나와의 채팅 连发消息）：p50 82 ms、p95 84 ms。
  - 拆分：等待读取 41 ms（40 ms 防抖）、读取 4.6 ms、翻译 11 ms、绘制 3.8 ms。
  - 只有 n = 2 条符合新的采样规则（快速连发时，多条消息会在一次读取里一起出现），需要更长时间使用来补足 ≥ 20 个样本。
- 读取：9 次，p50 4.2 ms、p95 232 ms（冷读）；失败 0 次。
