# fixtures

| 路径 | 内容 | 来源规则 |
|---|---|---|
| `test_messages_ko.txt` | 28 条合成韩语测试句（课程、实验室、俚语、链接、表情、多行、中文、韩英混写） | Claude 编写的合成文本；Lipper 手动发到 나와의 채팅 |
| `glossary.ko-zh.json` | 起步词表：俚语、校园、实验室，共 56 条 | 合成 |
| `snapshots/*.axjson` | 聊天窗口 AX 子树录制 | `meta.source` 只能是 `self-chat`（나와의 채팅，标题在 allowlist）或 `synthetic`（手工构造） |
| `golden/*.json` | `tlctl replay --update-golden` 的期望输出 | 人工审阅后提交；改动必须在 docs/journal.md 写原因 |

**禁止**放入任何来自真实群聊或私聊的内容，包括消息、聊天名和人名。
