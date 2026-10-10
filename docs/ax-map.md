# KakaoTalk for Mac — AX 结构图

> 由 ax-explorer 在 M0 填写。每条结论标 **[观察]**（附命令和脱敏输出摘要）或 **[推断]**。
> kmsg 文档里的记录只是起点，标为 **[kmsg]**。

## 环境

| 项 | 值 |
|---|---|
| KakaoTalk 版本 | ? |
| macOS 版本 | ? |
| 记录日期 | ? |

## 已知（来自 kmsg，待核对）

- **[kmsg]** 主窗口 `identifier = "Main Window"`，导航为 `friends` / `chatrooms` / `more`；列表结构 `AXScrollArea > AXTable > AXRow > AXCell`。
- **[kmsg]** 聊天窗口 `title` = 聊天名；消息区 `AXScrollArea > AXTable > AXRow`；输入框是 `AXTextArea` 或 `AXTextField`。
- **[kmsg]** 消息时间 label 的 `AXHelp` 带日期 tooltip，格式 `YYYY-MM-DD`。
- **[kmsg]** transcript root 用空间打分找：在输入框上方、面积大、含较多 `AXRow` / `AXStaticText` 的容器。

## 待填

| 问题 | 结论 | 证据 |
|---|---|---|
| 聊天窗口里 transcript 容器路径 | | |
| 一行（AXRow）的子结构 | | |
| 作者名在哪（只在一组消息的第一条出现？） | | |
| 正文在哪个属性（value / title / description） | | |
| 时间 label、AXHelp 日期 | | |
| "我发的"怎么判断（frame.x 靠右？subrole？） | | |
| 系统消息、日期分隔行长什么样 | | |
| 图片 / 链接 / 文件 / 表情贴图 | | |
| 多行消息、长消息（"全文"折叠？） | | |
| 回复 / 引用消息 | | |
| 虚拟化：rows vs visibleRows；滚动到中间时离屏行是否在树里 | | |
| 新消息到达时实际触发的通知及其目标元素 | | |
| 移动 / 缩放 / 切换聊天时的通知 | | |
| 单次读取耗时（行数 → ms） | | |
