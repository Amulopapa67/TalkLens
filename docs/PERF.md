# 性能实测

> 预算来自 GOAL.md 第 5 节。每次实测写清楚：日期、机器、macOS、KakaoTalk 版本、方法、样本数、结果。

| 指标 | 预算 | 实测 | 方法 | 日期 |
|---|---|---|---|---|
| 新消息 → 译文 p50 / p95 | ≤ 600 / 1500 ms | | | |
| 快照解析 p95（≤ 200 行） | ≤ 30 ms | **4.1 ms**（合成 205 行，全部行；真机 8 行 1.1–1.3 ms） | `tlctl bench fixtures/snapshots`（release，50 次）；`tlctl probe --summary` | 2026-10-10 |
| diff p95 | ≤ 5 ms | **0.03 ms** | `tlctl bench fixtures/snapshots` | 2026-10-10 |
| Apple 翻译单条 p50 / p95 | （记录） | **21.9 / 65.7 ms**（28 条逐条）；批量 28 条 500 ms | `tlctl selftest --engine apple --source ko --target zh-Hans --input fixtures/test_messages_ko.txt`（debug 构建，冷启动首条 111 ms） | 2026-10-10 |
| 空闲 CPU（60 s） | ≤ 1% | | | |
| 常驻内存 | ≤ 120 MB | | | |
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
