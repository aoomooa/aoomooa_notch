//
//  AoomooaSentinel.swift — AI 任务哨兵（Antigravity · Claude · DeepSeek Harness）
//
//  · 纯事件驱动：通过仅限本机回环（127.0.0.1）的 NWListener 接收状态，空闲 0.0% CPU
//  · 安全加固：每次启动复用 0600 权限的 256-bit 随机口令（X-Notch-Token），强制拒绝携带 Origin 的请求
//  · 隐私边界：仅内存保存当前状态与简短标签，绝不写日志、不落盘任何消息内容
//  · 按来源独立超时：Antigravity 5 分钟 · DeepSeek 5 分钟 · Claude 20 分钟，超时温和提示“很久没消息”
//  · 前台不失效：绝不因 App 在前台就吞掉亮灯；仅在跨 App 切回（B → A）、新一轮任务或手动点击时消灯
//  · 视觉形态：收起态左侧显示 AI 原生 Logo，右侧显示极简状态小灯
//

import AppKit
import Defaults
import Network
import Security
import SwiftUI

// MARK: - 来源与状态定义

enum SentinelSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case antigravity
    case claude
    case deepseek

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .antigravity: return "com.google.antigravity"
        case .claude: return "com.anthropic.claudefordesktop"
        case .deepseek: return "com.deepseek.dsh"
        }
    }

    var appPath: String {
        switch self {
        case .antigravity: return "/Applications/Antigravity.app"
        case .claude: return "/Applications/Claude.app"
        case .deepseek: return "/Applications/DeepSeek Harness.app"
        }
    }

    var fallbackSymbol: String {
        switch self {
        case .antigravity: return "sparkles"
        case .claude: return "bubble.left.and.text.bubble.right.fill"
        case .deepseek: return "cpu"
        }
    }

    var timeoutPrefKey: String {
        switch self {
        case .antigravity: return AoomooaPrefs.Key.sentinelTimeoutAntigravity
        case .claude: return AoomooaPrefs.Key.sentinelTimeoutClaude
        case .deepseek: return AoomooaPrefs.Key.sentinelTimeoutDeepSeek
        }
    }

    var defaultTimeoutMinutes: Int {
        switch self {
        case .antigravity: return AoomooaPrefs.Default.sentinelTimeoutAntigravity
        case .claude: return AoomooaPrefs.Default.sentinelTimeoutClaude
        case .deepseek: return AoomooaPrefs.Default.sentinelTimeoutDeepSeek
        }
    }

    var timeoutSeconds: TimeInterval {
        TimeInterval(AoomooaPrefs.sentinelTimeoutMinutes(key: timeoutPrefKey, fallback: defaultTimeoutMinutes) * 60)
    }

    static func from(raw: String) -> SentinelSource? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "antigravity", "agy": return .antigravity
        case "claude", "cowork", "claude-code": return .claude
        case "deepseek", "dsh", "deepseek-harness": return .deepseek
        default: return nil
        }
    }

    static func from(bundleID: String) -> SentinelSource? {
        allCases.first { $0.bundleIdentifier == bundleID }
    }
}

enum SentinelState: String, Codable, Equatable, Sendable {
    case idle
    case working
    case stale      // 超过该来源独立超时阈值未收到更新
    case attention  // 明确需要审批 / 报错
    case done       // 任务完成，等待阅读

    /// 展示优先级：需要确认 > 很久没消息 > 已完成 > 工作中 > 空闲
    var priority: Int {
        switch self {
        case .attention: return 4
        case .stale: return 3
        case .done: return 2
        case .working: return 1
        case .idle: return 0
        }
    }

    /// 紧急/可阅读态：即便正在放歌或看视频，也应立即在收起态刘海提示
    var isUrgent: Bool {
        self == .attention || self == .stale || self == .done
    }

    var defaultLabel: String {
        switch self {
        case .idle: return ""
        case .working: return "工作中"
        case .stale: return "很久没消息"
        case .attention: return "需要确认"
        case .done: return "已完成"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .clear
        case .working: return DS.Colors.textSecondary   // 灰色：工作中
        case .stale: return DS.Colors.warning           // 橙色：长时间没消息
        case .attention: return DS.Colors.accent        // 红色：需要确认 / 出错
        case .done: return DS.Colors.success            // 绿色：已完成
        }
    }
}

struct SentinelRecord: Equatable, Identifiable {
    let source: SentinelSource
    var state: SentinelState
    var label: String
    var startedAt: Date
    var updatedAt: Date
    var lastHeartbeatAt: Date

    var id: SentinelSource { source }
}

// MARK: - 状态机 + 安全回环接收器

@MainActor
final class AoomooaSentinelModel: ObservableObject {
    static let shared = AoomooaSentinelModel()

    /// 限制单个请求包体，防止恶意大包
    private static let maxRequestBytes = 2048

    @Published private(set) var records: [SentinelSource: SentinelRecord] = [:]
    @Published private(set) var isListening = false
    @Published private(set) var listenError: String?
    @Published var isPopoverActive = false

    private(set) var token: String = ""
    @Published private(set) var tokenFilePath: String = ""

    private var server: SentinelLoopbackServer?
    private var watchdogTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var lastActiveBundleID: String?
    private var iconCache: [SentinelSource: NSImage] = [:]

    private init() {
        (token, tokenFilePath) = Self.loadOrCreateToken()
        lastActiveBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: 派生状态

    /// 按固定来源顺序排列的活跃记录（左1↔右1、左2↔右2、左3↔右3 位置稳定不乱跳）
    var orderedActiveRecords: [SentinelRecord] {
        SentinelSource.allCases.compactMap { source in
            guard let record = records[source], record.state != .idle else { return nil }
            return record
        }
    }

    /// 按紧急度排列的活跃记录（用于浮卡列表与主优先级判定）
    var activeRecords: [SentinelRecord] {
        records.values
            .filter { $0.state != .idle }
            .sorted { lhs, rhs in
                if lhs.state.priority != rhs.state.priority {
                    return lhs.state.priority > rhs.state.priority
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var primary: SentinelRecord? { activeRecords.first }
    var hasActive: Bool { primary != nil }
    var showsOnClosedNotch: Bool { AoomooaPrefs.sentinelEnabled && hasActive }
    var isUrgent: Bool { primary?.state.isUrgent ?? false }

    // MARK: 生命周期

    func start() {
        guard AoomooaPrefs.sentinelEnabled else {
            stop()
            return
        }
        installWorkspaceObserverIfNeeded()
        startServerIfNeeded()
        let currentToken = token
        Task { [weak self] in
            if let mirrored = await XPCHelperClient.shared.syncSentinelToken(currentToken) {
                self?.tokenFilePath = mirrored
            }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
        listenError = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
        if let obs = terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            terminateObserver = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            clearAll()
            stop()
        }
    }

    func restartServer() {
        server?.stop()
        server = nil
        isListening = false
        listenError = nil
        if AoomooaPrefs.sentinelEnabled {
            startServerIfNeeded()
        }
    }

    // MARK: 状态更新与操作

    func update(source: SentinelSource, state: SentinelState, label: String? = nil) {
        guard AoomooaPrefs.sentinelEnabled else { return }
        let now = Date()

        if state == .idle {
            withAnimation(DS.Motion.micro) {
                records.removeValue(forKey: source)
            }
            rescheduleTimers()
            return
        }

        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedLabel = trimmed.isEmpty ? state.defaultLabel : String(trimmed.prefix(32))

        withAnimation(DS.Motion.micro) {
            if var existing = records[source] {
                if state == .working && existing.state != .working {
                    existing.startedAt = now
                }
                existing.state = state
                existing.label = resolvedLabel
                existing.updatedAt = now
                if state == .working {
                    existing.lastHeartbeatAt = now
                }
                records[source] = existing
            } else {
                records[source] = SentinelRecord(
                    source: source,
                    state: state,
                    label: resolvedLabel,
                    startedAt: now,
                    updatedAt: now,
                    lastHeartbeatAt: now
                )
            }
        }
        rescheduleTimers()
    }

    func dismiss(_ source: SentinelSource) {
        update(source: source, state: .idle)
    }

    func clearAll() {
        withAnimation(DS.Motion.micro) {
            records.removeAll()
        }
        rescheduleTimers()
    }

    /// 激活对应 AI 应用；非 working 状态顺手消灯
    func activate(_ source: SentinelSource) {
        if let record = records[source], record.state != .working {
            dismiss(source)
        }
        isPopoverActive = false

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier).first {
            running.activate(options: [.activateAllWindows])
            return
        }
        if FileManager.default.fileExists(atPath: source.appPath) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: source.appPath), configuration: config) { _, _ in }
        }
    }

    /// 获取并缓存该 AI 对应的原生 macOS App 图标
    func appIcon(for source: SentinelSource) -> NSImage? {
        if let hit = iconCache[source] { return hit }
        guard FileManager.default.fileExists(atPath: source.appPath) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: source.appPath)
        iconCache[source] = img
        return img
    }

    /// 设置页试灯用
    func simulate(source: SentinelSource, state: SentinelState) {
        update(source: source, state: state, label: state.defaultLabel)
    }

    // MARK: 跨 App 切回自动消灯（前台不失效）

    private func installWorkspaceObserverIfNeeded() {
        if workspaceObserver == nil {
            lastActiveBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in
                    self?.handleAppActivation(bundleID)
                }
            }
        }
        if terminateObserver == nil {
            terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                Task { @MainActor in
                    // Claude 任务跑在云端，退出桌面 App 不代表云端任务停止，因此退出时不自动清 Claude 的灯；
                    // 仅对本机运行的桌面宿主（Antigravity / DeepSeek Harness.app）在退出时清灯。
                    if let bundleID,
                       let source = SentinelSource.from(bundleID: bundleID),
                       source != .claude {
                        self?.dismiss(source)
                    }
                }
            }
        }
    }

    private func handleAppActivation(_ newBundleID: String?) {
        let previous = lastActiveBundleID
        lastActiveBundleID = newBundleID

        // 仅当真正发生跨 App 切换（B → A）时消灯；若 App 原本就在前台，绝不自动吞掉提醒灯
        guard let newBundleID, newBundleID != previous,
              let source = SentinelSource.from(bundleID: newBundleID),
              let existing = records[source],
              existing.state == .done || existing.state == .attention || existing.state == .stale
        else { return }

        dismiss(source)
    }

    // MARK: 按需定时：看门狗（分源独立超时；绿灯 done 绝不自动淡出，确保离开电脑回来仍看得到）

    func rescheduleTimers() {
        watchdogTask?.cancel()
        watchdogTask = nil

        let now = Date()

        // 仅为 working 中的源安排单次最早超时任务（无 working 源时零任务、0% CPU）
        let workingDeadlines: [(SentinelSource, Date)] = records.values
            .filter { $0.state == .working }
            .map { ($0.source, $0.lastHeartbeatAt.addingTimeInterval($0.source.timeoutSeconds)) }

        if let next = workingDeadlines.min(by: { $0.1 < $1.1 }) {
            let wait = max(0.5, next.1.timeIntervalSince(now))
            watchdogTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.evaluateStaleWorking()
            }
        }
    }

    private func evaluateStaleWorking() {
        let now = Date()
        var changed = false
        for (source, var record) in records where record.state == .working {
            if now.timeIntervalSince(record.lastHeartbeatAt) >= source.timeoutSeconds - 0.5 {
                record.state = .stale
                record.label = SentinelState.stale.defaultLabel
                record.updatedAt = now
                records[source] = record
                changed = true
            }
        }
        if changed {
            withAnimation(DS.Motion.micro) { objectWillChange.send() }
        }
        rescheduleTimers()
    }

    // MARK: 回环监听启动

    private func startServerIfNeeded() {
        guard server == nil else { return }
        let port = AoomooaPrefs.sentinelPort
        let expectedToken = token
        let srv = SentinelLoopbackServer(
            port: port,
            token: expectedToken,
            maxBytes: Self.maxRequestBytes,
            onStateChange: { [weak self] listening, err in
                Task { @MainActor in
                    self?.isListening = listening
                    self?.listenError = err
                }
            },
            onStatus: { [weak self] source, state, label in
                Task { @MainActor in
                    self?.update(source: source, state: state, label: label)
                }
            },
            onClear: { [weak self] source in
                Task { @MainActor in
                    if let source {
                        self?.dismiss(source)
                    } else {
                        self?.clearAll()
                    }
                }
            }
        )
        server = srv
        srv.start()
    }

    // MARK: 随机 256-bit Token（0600 仅本机当前用户可读）

    private static func loadOrCreateToken() -> (String, String) {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = support.appendingPathComponent("aoomooa-sentinel", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let file = dir.appendingPathComponent("token")
        if let existing = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           existing.count >= 32 {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return (existing, file.path)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try? Data(hex.utf8).write(to: file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (hex, file.path)
    }
}

// MARK: - 极简回环 HTTP 监听（127.0.0.1 only · 拒 Origin · 校验 X-Notch-Token）

private final class SentinelLoopbackServer: @unchecked Sendable {
    private let port: UInt16
    private let token: String
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.aoomooa.notch.sentinel", qos: .utility)
    private var listener: NWListener?

    private let onStateChange: @Sendable (Bool, String?) -> Void
    private let onStatus: @Sendable (SentinelSource, SentinelState, String?) -> Void
    private let onClear: @Sendable (SentinelSource?) -> Void

    init(
        port: UInt16,
        token: String,
        maxBytes: Int,
        onStateChange: @escaping @Sendable (Bool, String?) -> Void,
        onStatus: @escaping @Sendable (SentinelSource, SentinelState, String?) -> Void,
        onClear: @escaping @Sendable (SentinelSource?) -> Void
    ) {
        self.port = port
        self.token = token
        self.maxBytes = maxBytes
        self.onStateChange = onStateChange
        self.onStatus = onStatus
        self.onClear = onClear
    }

    func start() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onStateChange(false, "端口无效")
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let listener = try NWListener(using: params)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onStateChange(true, nil)
                case .failed(let error):
                    self.onStateChange(false, error.localizedDescription)
                case .cancelled:
                    self.onStateChange(false, nil)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(connection: conn)
            }
            listener.start(queue: queue)
        } catch {
            onStateChange(false, error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            if error != nil {
                connection.cancel()
                return
            }

            var acc = buffer
            if let data { acc.append(data) }
            if acc.count > self.maxBytes {
                self.reply(connection, status: "413 Payload Too Large", body: #"{"error":"too_large"}"#)
                return
            }

            if let parsed = Self.tryParseHTTP(acc) {
                self.dispatch(parsed, on: connection)
                return
            }

            if isComplete {
                self.reply(connection, status: "400 Bad Request", body: #"{"error":"incomplete"}"#)
            } else {
                self.receive(connection: connection, buffer: acc)
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func tryParseHTTP(_ data: Data) -> HTTPRequest? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let range = data.range(of: sep) else { return nil }
        let headerData = data[..<range.lowerBound]
        let bodyData = data[range.upperBound...]

        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        if let lenStr = headers["content-length"], let expected = Int(lenStr), bodyData.count < expected {
            return nil // 等 body 收齐
        }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(bodyData))
    }

    private func dispatch(_ req: HTTPRequest, on connection: NWConnection) {
        // 1. 凡携带 Origin 头一律拒绝（阻断任何浏览器跨站请求）
        if req.headers["origin"] != nil {
            reply(connection, status: "403 Forbidden", body: #"{"error":"origin_not_allowed"}"#)
            return
        }

        // 2. 强制校验自定义口令头（常时间比较）
        guard let provided = req.headers["x-notch-token"],
              Self.constantTimeEquals(provided, token) else {
            reply(connection, status: "401 Unauthorized", body: #"{"error":"unauthorized"}"#)
            return
        }

        switch (req.method, req.path) {
        case ("GET", "/health"):
            reply(connection, status: "200 OK", body: #"{"ok":true}"#)

        case ("POST", "/status"):
            struct Payload: Decodable {
                let source: String
                let state: String
                let label: String?
            }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: req.body),
                  let source = SentinelSource.from(raw: payload.source),
                  let state = SentinelState(rawValue: payload.state.lowercased()) else {
                reply(connection, status: "400 Bad Request", body: #"{"error":"invalid_payload"}"#)
                return
            }
            onStatus(source, state, payload.label)
            reply(connection, status: "200 OK", body: #"{"ok":true}"#)

        case ("POST", "/clear"):
            struct ClearPayload: Decodable { let source: String? }
            let source = (try? JSONDecoder().decode(ClearPayload.self, from: req.body))?.source
                .flatMap(SentinelSource.from(raw:))
            onClear(source)
            reply(connection, status: "200 OK", body: #"{"ok":true}"#)

        default:
            reply(connection, status: "404 Not Found", body: #"{"error":"not_found"}"#)
        }
    }

    private func reply(_ connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(bodyData)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}

// MARK: - 收起态刘海视图：同心三层镜像共存
//   左耳：[⏱ 铃声] · [🎬 视频封面] ── (12pt 留白) ── [AI Logo 1..3]
//   中间：[ 硬件刘海 ]
//   右耳：[AI 呼吸灯 1..3] ── (12pt 留白) ── [〰️ 视频小波浪] · [0:23 铃的时间]

struct AoomooaSentinelLiveActivity: View {
    @ObservedObject private var sentinel = AoomooaSentinelModel.shared
    @ObservedObject private var musicManager = MusicManager.shared
    let height: CGFloat
    let middleWidth: CGFloat
    var showsMedia: Bool = false
    var showsTimer: Bool = false

    private static let timerCoexistWing: CGFloat = 40

    /// 仅 AI 区域单侧宽度（count == 0 时为 0）
    static func aiClusterWidth(for count: Int, withOuter: Bool) -> CGFloat {
        guard count > 0 else { return 0 }
        if withOuter {
            switch count {
            case 1: return 24
            case 2: return 40
            default: return 56
            }
        }
        switch count {
        case 1: return DS.Size.sentinelSide   // 34 pt
        case 2: return 48
        default: return 64
        }
    }

    /// 根据活跃 AI 数量、媒体播放与计时器状态，计算严格对称的单侧耳宽（保证硬件刘海绝对居中）
    static func sideWidth(for count: Int, withMedia: Bool = false, withTimer: Bool = false) -> CGFloat {
        // 仅计时器单独运行
        if count == 0 && !withMedia && withTimer {
            return DS.Size.timerSide
        }
        let hasOuter = withMedia || withTimer
        let ai = aiClusterWidth(for: count, withOuter: hasOuter)
        let aiToOuterGap: CGFloat = (count > 0 && hasOuter) ? DS.Space.m : (count == 0 && hasOuter ? DS.Space.s : 0)
        let mediaW: CGFloat = withMedia ? DS.Size.sentinelMediaWing : 0
        let pairGap: CGFloat = (withMedia && withTimer) ? DS.Space.xs : 0
        let timerW: CGFloat = withTimer ? timerCoexistWing : 0
        return ai + aiToOuterGap + mediaW + pairGap + timerW
    }

    var body: some View {
        let records = sentinel.showsOnClosedNotch ? Array(sentinel.orderedActiveRecords.prefix(3)) : []
        let hasAI = !records.isEmpty
        let hasOuter = showsMedia || showsTimer
        let isSoloTimer = !hasAI && !showsMedia && showsTimer
        let aiWidth = Self.aiClusterWidth(for: records.count, withOuter: hasOuter)
        let earWidth = Self.sideWidth(for: records.count, withMedia: showsMedia, withTimer: showsTimer)
        let aiToOuterGap: CGFloat = (hasAI && hasOuter) ? DS.Space.m : (!hasAI && hasOuter && !isSoloTimer ? DS.Space.s : 0)
        let iconSize: CGFloat = {
            switch records.count {
            case ...1: return max(16, min(hasOuter ? 18 : 20, height - 12))
            case 2: return max(15, min(16, height - 14))
            default: return max(14, min(15, height - 15))
            }
        }()
        let artworkSize = max(16, min(18, height - 14))
        let auraColor = AoomooaMediaAuraArtwork.resolvedAuraColor(from: musicManager.avgColor)

        HStack(spacing: 0) {
            // 左耳：[⏱ 铃声图标（左1）] + 4pt + [🎬 媒体封面（左2）] + 12pt 留白 + [内侧 AI Logo]
            HStack(spacing: 0) {
                if showsTimer {
                    AoomooaTimerWingIcon()
                        .frame(
                            width: isSoloTimer ? DS.Size.timerSide : Self.timerCoexistWing,
                            height: height,
                            alignment: showsMedia ? .trailing : .center
                        )
                        .padding(.trailing, showsMedia ? 2 : 0)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }

                if showsTimer && showsMedia {
                    Spacer(minLength: 0)
                        .frame(width: DS.Space.xs)
                }

                if showsMedia {
                    AoomooaMediaAuraArtwork(
                        image: musicManager.albumArt,
                        auraColor: auraColor,
                        size: artworkSize,
                        isPlaying: musicManager.isPlaying
                    )
                    .frame(width: DS.Size.sentinelMediaWing, height: height)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }

                if aiToOuterGap > 0 {
                    Spacer(minLength: 0)
                        .frame(width: aiToOuterGap)
                }

                if hasAI {
                    HStack(spacing: DS.Space.xs) {
                        ForEach(records) { record in
                            SentinelLogoView(source: record.source, size: iconSize)
                        }
                    }
                    .frame(width: aiWidth, height: height)
                }
            }
            .frame(width: earWidth, height: height)

            // 中间：硬件刘海黑色桥接
            Rectangle()
                .fill(DS.Colors.background)
                .frame(width: max(0, middleWidth), height: height)

            // 右耳：[内侧 AI 呼吸灯（右123）] + 12pt 留白 + [〰️ 媒体小波浪] + 4pt + [0:23 铃的时间]
            HStack(spacing: 0) {
                if hasAI {
                    SentinelLightsCluster(records: records)
                        .frame(width: aiWidth, height: height)
                }

                if aiToOuterGap > 0 {
                    Spacer(minLength: 0)
                        .frame(width: aiToOuterGap)
                }

                if showsMedia {
                    AoomooaMediaSpectrumWing(
                        isPlaying: $musicManager.isPlaying,
                        auraColor: auraColor,
                        coexisting: true
                    )
                    .frame(width: DS.Size.sentinelMediaWing, height: height)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }

                if showsMedia && showsTimer {
                    Spacer(minLength: 0)
                        .frame(width: DS.Space.xs)
                }

                if showsTimer {
                    AoomooaTimerWingLabel()
                        .frame(
                            width: isSoloTimer ? DS.Size.timerSide : Self.timerCoexistWing,
                            height: height,
                            alignment: showsMedia ? .leading : .center
                        )
                        .padding(.leading, showsMedia ? 2 : 0)
                        .transition(.opacity.combined(with: .scale(scale: 0.82)))
                }
            }
            .frame(width: earWidth, height: height)
        }
        .frame(height: height)
        .animation(DS.Motion.panel, value: records.count)
        .animation(DS.Motion.panel, value: showsMedia)
        .animation(DS.Motion.panel, value: showsTimer)
    }
}

/// 收起态媒体小封面：1（柔波扩散环）+ 2（银幕主色呼吸溢光），兼顾视频与音乐且不旋转
struct AoomooaMediaAuraArtwork: View {
    let image: NSImage
    let auraColor: Color
    let size: CGFloat
    let isPlaying: Bool

    @State private var glowBreathe = false
    @State private var rippleExpand = false

    static func resolvedAuraColor(from nsColor: NSColor) -> Color {
        Defaults[.coloredSpectrogram]
            ? Color(nsColor: nsColor).ensureMinimumBrightness(factor: 0.65)
            : Color.white.opacity(0.75)
    }

    var body: some View {
        ZStack {
            // 效果 2：银幕呼吸溢光（柔和环境底光，随播放慢速呼吸）
            AoomooaSquircle()
                .fill(auraColor)
                .frame(width: size, height: size)
                .scaleEffect(isPlaying ? (glowBreathe ? 1.24 : 1.06) : 1.0)
                .opacity(isPlaying ? (glowBreathe ? 0.48 : 0.22) : 0.10)
                .blur(radius: 5)
                .allowsHitTesting(false)

            // 效果 1：柔波扩散环（从圆角边缘向外荡开一圈极淡波纹，传达“正在播放”）
            if isPlaying {
                AoomooaSquircle()
                    .stroke(auraColor, lineWidth: 1.1)
                    .frame(width: size, height: size)
                    .scaleEffect(rippleExpand ? 1.40 : 0.98)
                    .opacity(rippleExpand ? 0.0 : 0.50)
                    .allowsHitTesting(false)
            }

            // 封面本体（保持端正清晰，加极细内高光防止暗画面融入黑底）
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(AoomooaSquircle())
                .overlay(
                    AoomooaSquircle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                )
        }
        .id(isPlaying)
        .onAppear { restartAnimations() }
        .onChange(of: isPlaying) { _, _ in restartAnimations() }
    }

    private func restartAnimations() {
        withTransaction(DS.Motion.instant) {
            glowBreathe = false
            rippleExpand = false
        }
        guard isPlaying else { return }
        DispatchQueue.main.async {
            guard isPlaying else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                glowBreathe = true
            }
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                rippleExpand = true
            }
        }
    }
}

/// 右耳外侧媒体波形翼：与左耳封面共享同一主色微光实现镜像对称；与 AI 共存时适度降噪不抢灯
struct AoomooaMediaSpectrumWing: View {
    @Binding var isPlaying: Bool
    let auraColor: Color
    var coexisting: Bool = false

    @Default(.useMusicVisualizer) private var useMusicVisualizer

    var body: some View {
        let barW: CGFloat = coexisting ? 14 : 16
        let barH: CGFloat = coexisting ? 10 : 12

        ZStack {
            if isPlaying {
                Capsule()
                    .fill(auraColor)
                    .frame(width: barW, height: barH)
                    .opacity(coexisting ? 0.22 : 0.30)
                    .blur(radius: 4)
                    .allowsHitTesting(false)
            }

            if useMusicVisualizer {
                Rectangle()
                    .fill(auraColor.gradient)
                    .frame(width: 24, height: 16)
                    .mask {
                        AudioSpectrumView(isPlaying: $isPlaying)
                            .frame(width: barW, height: barH)
                    }
                    .opacity(coexisting ? 0.78 : 0.95)
            } else {
                LottieAnimationContainer()
                    .frame(width: barW + 4, height: barH + 4)
                    .opacity(coexisting ? 0.78 : 0.95)
            }
        }
    }
}

/// 音乐或计时器占着左右耳时，叠加在边缘的极简状态小圆点
struct AoomooaSentinelEdgeDot: View {
    @ObservedObject private var sentinel = AoomooaSentinelModel.shared

    var body: some View {
        if sentinel.showsOnClosedNotch, let primary = sentinel.primary {
            SentinelLightDot(state: primary.state, diameter: DS.Size.sentinelDotSmall)
        }
    }
}

/// AI 原生 App Logo（读不到本地 App 时退回 SF Symbol）
struct SentinelLogoView: View {
    @ObservedObject private var sentinel = AoomooaSentinelModel.shared
    let source: SentinelSource
    let size: CGFloat

    var body: some View {
        if let image = sentinel.appIcon(for: source) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(AoomooaSquircle())
        } else {
            Image(systemName: source.fallbackSymbol)
                .font(.system(size: size * 0.72, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .frame(width: size, height: size)
        }
    }
}

/// 右耳小灯组：纯水平横排，与左耳 Logo 一一对应（右1 ↔ 左1，右2 ↔ 左2，右3 ↔ 左3）
private struct SentinelLightsCluster: View {
    let records: [SentinelRecord]

    var body: some View {
        let shown = Array(records.prefix(3))
        let dotSize: CGFloat = shown.count <= 2 ? DS.Size.sentinelLight : 7
        let gap: CGFloat = shown.count == 1 ? 0 : DS.Space.s
        HStack(spacing: gap) {
            ForEach(shown) { record in
                SentinelLightDot(state: record.state, diameter: dotSize)
            }
        }
    }
}

/// 单颗状态小灯：仅灰色 working 轻呼吸；绿（完成）/ 红（确认）/ 橙（长时间）全部安静常亮不闪烁
struct SentinelLightDot: View {
    let state: SentinelState
    let diameter: CGFloat
    @State private var pulse = false

    var body: some View {
        let isWorking = state == .working
        Circle()
            .fill(state.color)
            .frame(width: diameter, height: diameter)
            .shadow(color: state.color.opacity(isWorking ? 0.2 : 0.65), radius: diameter * 0.45)
            .opacity(isWorking ? (pulse ? 0.45 : 1.0) : 1.0)
            .id(isWorking)
            .onAppear { restartPulse() }
            .onChange(of: state) { _, _ in restartPulse() }
    }

    private func restartPulse() {
        withTransaction(DS.Motion.instant) { pulse = false }
        guard state == .working else { return }
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - 展开态顶栏按钮与浮卡（仅在有活跃 AI 状态时出现，平时 0 占位）

struct AoomooaSentinelHeaderButton: View {
    @ObservedObject private var sentinel = AoomooaSentinelModel.shared
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        if sentinel.showsOnClosedNotch, let primary = sentinel.primary {
            Button {
                sentinel.isPopoverActive.toggle()
            } label: {
                HStack(spacing: DS.Space.xs) {
                    SentinelLogoView(source: primary.source, size: 15)
                    SentinelLightDot(state: primary.state, diameter: DS.Size.sentinelDotSmall)
                }
                .padding(.horizontal, DS.Space.s)
                .frame(height: DS.Size.control)
                .background(
                    Capsule().fill(sentinel.isPopoverActive ? DS.Colors.fillHover : DS.Colors.fill)
                )
            }
            .buttonStyle(AoomooaPressStyle())
            .help("\(primary.source.displayName) · \(primary.label)")
            .popover(isPresented: $sentinel.isPopoverActive, arrowEdge: .bottom) {
                SentinelPopoverContent(onCloseNotch: {
                    withAnimation(AoomooaHover.collapseAnimation) { vm.close() }
                })
            }
        }
    }
}

private struct SentinelPopoverContent: View {
    @ObservedObject private var sentinel = AoomooaSentinelModel.shared
    let onCloseNotch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("AI 任务状态")
                    .font(DS.Fonts.caption(.semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                if sentinel.activeRecords.count > 1 {
                    Button("全部清除") {
                        sentinel.clearAll()
                        sentinel.isPopoverActive = false
                    }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                }
            }

            ForEach(sentinel.activeRecords) { record in
                HStack(spacing: DS.Space.s) {
                    Button {
                        sentinel.activate(record.source)
                        onCloseNotch()
                    } label: {
                        HStack(spacing: DS.Space.s) {
                            SentinelLogoView(source: record.source, size: 22)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(record.source.displayName)
                                    .font(DS.Fonts.body(.medium))
                                    .foregroundStyle(DS.Colors.textPrimary)
                                Text("\(record.label) · \(elapsed(since: record.updatedAt))")
                                    .font(DS.Fonts.caption)
                                    .foregroundStyle(DS.Colors.textSecondary)
                            }
                            Spacer(minLength: DS.Space.s)
                            SentinelLightDot(state: record.state, diameter: DS.Size.sentinelLight)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        sentinel.dismiss(record.source)
                        if !sentinel.hasActive { sentinel.isPopoverActive = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(DS.Fonts.caption(.semibold))
                            .foregroundStyle(DS.Colors.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("熄灭此灯")
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                        .fill(DS.Colors.fill)
                )
            }
        }
        .padding(DS.Space.m)
        .frame(width: 240)
    }

    private func elapsed(since date: Date) -> String {
        let sec = max(0, Int(Date().timeIntervalSince(date)))
        if sec < 60 { return "\(sec) 秒前" }
        return "\(sec / 60) 分钟前"
    }
}
