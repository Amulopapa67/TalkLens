#!/usr/bin/env swift
// kakao_ax_probe.swift — 只读探测 KakaoTalk for Mac 的辅助功能（Accessibility）结构
//
// 用途：在写翻译伴侣之前，先搞清楚三件事
//   1. 消息气泡在 AX 树里长什么样（角色、层级、文本放在哪个属性）
//   2. 列表是不是虚拟化的（屏幕外的行还在不在树里）
//   3. 来新消息时 KakaoTalk 会不会发 AX 通知（决定能否事件驱动，而不是轮询）
//
// 安全：本脚本只读取，不点击、不输入、不发送任何东西，也不碰网络。
// 隐私：默认把所有消息文本和聊天窗口标题替换成 <text len=.. ko> 这样的占位，只有时间格式原样保留；
//       加 --show-text-for "<窗口标题>" 才输出「标题包含该字符串」的那个窗口里的原文。
//       只对自己的 나와의 채팅 使用（TalkLens 工作区的 CLAUDE.md 红线）。
//
// 用法（在终端里）：
//   swift tools/kakao_ax_probe.swift dump                 # 导出 AX 树到 kakao_ax_dump.json，并打印摘要
//   swift tools/kakao_ax_probe.swift dump --depth 30 --max-nodes 8000
//   swift tools/kakao_ax_probe.swift dump --show-text-for "<나와의 채팅 窗口标题>" --out self_chat_dump.json
//   swift tools/kakao_ax_probe.swift watch --seconds 90   # 监听 AX 通知 90 秒，期间在 나와의 채팅 发一条消息
//
// 前置：
//   - 需要 Swift（Xcode 或 Command Line Tools：xcode-select --install）
//   - 运行脚本的终端（Terminal / iTerm）要在「系统设置 → 隐私与安全性 → 辅助功能」里打勾
//   - KakaoTalk 已打开，并且至少打开一个聊天窗口（不要最小化）
//
// 注意：本脚本由 Claude 编写，尚未在真机上运行验证。若编译报错，把报错原文发回来即可。

import AppKit
import ApplicationServices
import Foundation

let bundleID = "com.kakao.KakaoTalkMac"

// MARK: - 参数

let argv = CommandLine.arguments
func argValue(_ name: String) -> String? {
    if let i = argv.firstIndex(of: name), i + 1 < argv.count { return argv[i + 1] }
    return nil
}
let mode = argv.count > 1 ? argv[1] : "dump"
if argv.contains("--show-text") {
    print("✗ --show-text 已移除（隐私）。请用 --show-text-for \"<나와의 채팅 窗口标题>\"。")
    exit(1)
}
let showTextFor = argValue("--show-text-for").flatMap { $0.isEmpty ? nil : $0 }
var currentWindowShowsText = false   // set per window in runDump(); always false in watch mode
let maxDepth = Int(argValue("--depth") ?? "") ?? 40
let maxNodes = Int(argValue("--max-nodes") ?? "") ?? 6000
let watchSeconds = Double(argValue("--seconds") ?? "") ?? 60
let outPath = argValue("--out") ?? "kakao_ax_dump.json"

// MARK: - 权限与目标进程

if !AXIsProcessTrusted() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    print("✗ 还没有辅助功能权限。")
    print("  打开「系统设置 → 隐私与安全性 → 辅助功能」，给你正在用的终端打勾，然后重新运行。")
    exit(1)
}

guard let kakao = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("✗ 没找到正在运行的 KakaoTalk（\(bundleID)）。请先打开 KakaoTalk，并打开一个聊天窗口。")
    exit(1)
}
let pid = kakao.processIdentifier
let appElement = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appElement, 1.0)

let kakaoVersion = (kakao.bundleURL.flatMap { Bundle(url: $0) }?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
print("✓ KakaoTalk pid=\(pid) version=\(kakaoVersion)")

// MARK: - AX 小工具

func axAttr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return err == .success ? value : nil
}

func axString(_ el: AXUIElement, _ name: String) -> String? {
    if let s = axAttr(el, name) as? String, !s.isEmpty { return s }
    return nil
}

func axChildren(_ el: AXUIElement, _ name: String = "AXChildren") -> [AXUIElement] {
    return (axAttr(el, name) as? [AXUIElement]) ?? []
}

func axFrame(_ el: AXUIElement) -> [Double]? {
    guard let p = axAttr(el, "AXPosition"), let s = axAttr(el, "AXSize"),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var pt = CGPoint.zero
    var sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return [Double(pt.x), Double(pt.y), Double(sz.width), Double(sz.height)].map { ($0 * 10).rounded() / 10 }
}

let timeRegex = try! NSRegularExpression(pattern: #"(오전|오후|上午|下午|AM|PM)\s*\d{1,2}:\d{2}|^\d{1,2}:\d{2}$|\d{4}\.\s*\d{1,2}\.\s*\d{1,2}\.?|\d{1,2}월\s*\d{1,2}일"#)

func redact(_ s: String) -> String {
    if currentWindowShowsText { return s }
    let range = NSRange(s.startIndex..., in: s)
    if timeRegex.firstMatch(in: s, range: range) != nil && s.count <= 24 { return s }  // 时间/日期原样保留
    let hasHangul = s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
    let hasCJK = s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    var tags = ["len=\(s.count)"]
    if hasHangul { tags.append("ko") }
    if hasCJK { tags.append("zh") }
    if s.contains("http") { tags.append("url") }
    return "<text \(tags.joined(separator: " "))>"
}

/// Window titles are chat names (often people's names), so they are redacted too,
/// except KakaoTalk's own main-window title and the allowlisted self-chat title.
func redactTitle(_ s: String) -> String {
    if currentWindowShowsText { return s }
    if ["KakaoTalk", "카카오톡"].contains(s) { return s }
    if let t = showTextFor, s.contains(t) { return s }
    let hasHangul = s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    return "<title len=\(s.count)\(hasHangul ? " ko" : "")>"
}

// MARK: - dump

var nodeCount = 0
var roleCounter: [String: Int] = [:]
var listLike: [[String: Any]] = []

func dumpNode(_ el: AXUIElement, depth: Int, path: String) -> [String: Any] {
    nodeCount += 1
    var d: [String: Any] = [:]
    let role = axString(el, "AXRole") ?? "?"
    d["role"] = role
    roleCounter[role, default: 0] += 1
    if let v = axString(el, "AXSubrole") { d["subrole"] = v }
    if let v = axString(el, "AXIdentifier") { d["identifier"] = v }
    if let v = axString(el, "AXTitle") { d["title"] = (role == "AXWindow") ? redactTitle(v) : redact(v) }
    if let raw = axAttr(el, "AXValue") {
        if let s = raw as? String, !s.isEmpty { d["value"] = redact(s) }
        else if let n = raw as? NSNumber { d["value"] = n }
    }
    if let v = axString(el, "AXDescription") { d["description"] = redact(v) }
    if let v = axString(el, "AXHelp") { d["help"] = redact(v) }
    if let f = axFrame(el) { d["frame"] = f }
    if depth <= 2 {
        var names: CFArray?
        if AXUIElementCopyAttributeNames(el, &names) == .success, let n = names as? [String] { d["attributeNames"] = n }
    }
    if ["AXTable", "AXOutline", "AXList", "AXScrollArea", "AXCollection"].contains(role) {
        let rows = axChildren(el, "AXRows").count
        let visible = axChildren(el, "AXVisibleRows").count
        d["rows"] = rows
        d["visibleRows"] = visible
        listLike.append(["path": path, "role": role, "rows": rows, "visibleRows": visible,
                         "children": axChildren(el).count, "frame": axFrame(el) ?? []])
    }
    let kids = axChildren(el)
    d["childCount"] = kids.count
    if depth < maxDepth && nodeCount < maxNodes && !kids.isEmpty {
        var arr: [[String: Any]] = []
        for (i, k) in kids.enumerated() {
            if nodeCount >= maxNodes { d["truncated"] = true; break }
            arr.append(dumpNode(k, depth: depth + 1, path: "\(path)/\(i)"))
        }
        d["children"] = arr
    }
    return d
}

func runDump() {
    let windows = axChildren(appElement, "AXWindows")
    print("✓ 找到 \(windows.count) 个 KakaoTalk 窗口")
    var out: [String: Any] = [
        "tool": "kakao_ax_probe",
        "kakaoVersion": kakaoVersion,
        "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "textShownOnlyForTitleContaining": showTextFor ?? "",
        "generatedAt": ISO8601DateFormatter().string(from: Date()),
    ]
    var wins: [[String: Any]] = []
    for (i, w) in windows.enumerated() {
        let title = axString(w, "AXTitle") ?? "(无标题)"
        let minimized = (axAttr(w, "AXMinimized") as? NSNumber)?.boolValue ?? false
        currentWindowShowsText = showTextFor.map { title.contains($0) } ?? false
        print("  窗口[\(i)] 标题=\(redactTitle(title)) 最小化=\(minimized) 原文=\(currentWindowShowsText ? "显示" : "脱敏") frame=\(axFrame(w) ?? [])")
        wins.append(dumpNode(w, depth: 0, path: "w\(i)"))
        currentWindowShowsText = false
    }
    out["windows"] = wins
    out["nodeCount"] = nodeCount
    out["roleCounts"] = roleCounter
    out["listLike"] = listLike

    do {
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
        print("✓ 已写出 \(outPath)（\(data.count / 1024) KB，节点 \(nodeCount) 个\(nodeCount >= maxNodes ? "，已达上限被截断" : "")）")
    } catch {
        print("✗ 写文件失败：\(error)")
    }

    print("\n— 角色统计（前 15）—")
    for (k, v) in roleCounter.sorted(by: { $0.value > $1.value }).prefix(15) { print("  \(k): \(v)") }
    print("\n— 列表类容器（候选消息区）—")
    for l in listLike.sorted(by: { (($0["children"] as? Int) ?? 0) > (($1["children"] as? Int) ?? 0) }).prefix(8) {
        print("  \(l["role"] ?? "") rows=\(l["rows"] ?? 0) visibleRows=\(l["visibleRows"] ?? 0) children=\(l["children"] ?? 0) path=\(l["path"] ?? "") frame=\(l["frame"] ?? [])")
    }
    print("\n提示：rows 明显大于 visibleRows → 屏幕外的行仍在树里；两者相近 → 列表被虚拟化，只能读可见部分。")
    print("把上面的摘要（不含聊天内容）贴回给 Claude 即可；JSON 文件默认已脱敏，也可以一起发。")
}

// MARK: - watch

let notificationNames = [
    "AXCreated", "AXUIElementDestroyed", "AXValueChanged", "AXRowCountChanged",
    "AXSelectedRowsChanged", "AXSelectedChildrenChanged", "AXLayoutChanged",
    "AXFocusedUIElementChanged", "AXFocusedWindowChanged", "AXMainWindowChanged",
    "AXWindowCreated", "AXMoved", "AXResized", "AXTitleChanged",
    "AXWindowMiniaturized", "AXWindowDeminiaturized", "AXApplicationActivated", "AXApplicationDeactivated",
]
var eventCounter: [String: Int] = [:]
let startTime = Date()

let observerCallback: AXObserverCallback = { _, element, notification, _ in
    let name = notification as String
    eventCounter[name, default: 0] += 1
    let role = axString(element, "AXRole") ?? "?"
    let sub = axString(element, "AXSubrole").map { "/\($0)" } ?? ""
    let t = String(format: "%6.2f", Date().timeIntervalSince(startTime))
    var extra = ""
    if name == "AXValueChanged", let s = axString(element, "AXValue") { extra = " value=\(redact(s))" }
    if name == "AXRowCountChanged" { extra = " rows=\(axChildren(element, "AXRows").count)" }
    print("[\(t)s] \(name)  \(role)\(sub)\(extra)")
}

func runWatch() {
    var observerRef: AXObserver?
    guard AXObserverCreate(pid, observerCallback, &observerRef) == .success, let observer = observerRef else {
        print("✗ 创建 AXObserver 失败"); exit(1)
    }
    var targets: [AXUIElement] = [appElement]
    for w in axChildren(appElement, "AXWindows") {
        targets.append(w)
        // 也直接挂到窗口里的列表类容器上（有的通知只发给具体元素）
        var stack: [(AXUIElement, Int)] = [(w, 0)]
        var visited = 0
        while visited < 3000, let item = stack.popLast() {
            let (el, depth) = item
            visited += 1
            let role = axString(el, "AXRole") ?? ""
            if ["AXTable", "AXOutline", "AXList", "AXScrollArea"].contains(role) { targets.append(el) }
            if depth < 25 { for k in axChildren(el) { stack.append((k, depth + 1)) } }
        }
    }
    var registered = 0
    for el in targets {
        for n in notificationNames {
            if AXObserverAddNotification(observer, el, n as CFString, nil) == .success { registered += 1 }
        }
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
    print("✓ 监听中：\(targets.count) 个元素，成功注册 \(registered) 个通知，持续 \(Int(watchSeconds)) 秒")
    print("  现在请让别人给你发一条消息（或用手机给自己发），也可以滚动、切换聊天窗口看看会出现什么事件。\n")
    _ = CFRunLoopRunInMode(.defaultMode, watchSeconds, false)
    print("\n— 通知统计 —")
    if eventCounter.isEmpty { print("  （没有收到任何通知 → 很可能只能用轮询）") }
    for (k, v) in eventCounter.sorted(by: { $0.value > $1.value }) { print("  \(k): \(v)") }
    print("\n关键看：收到新消息的那一刻，有没有 AXRowCountChanged / AXCreated / AXValueChanged / AXLayoutChanged。")
}

switch mode {
case "dump": runDump()
case "watch": runWatch()
default:
    print("用法：swift tools/kakao_ax_probe.swift dump|watch [--show-text-for TITLE] [--depth N] [--max-nodes N] [--seconds S] [--out file]")
}
