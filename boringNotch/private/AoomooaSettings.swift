//
//  AoomooaSettings.swift — 极简三栏设置（常规 · 模块 · 诊断与关于）
//
//  只保留真正生效的核心配置；所有项存在 UserDefaults / Defaults，改完立即生效、重启后保留。
//

import AppKit
import Defaults
import LaunchAtLogin
import Security
import SwiftUI

// MARK: - 1. 常规（系统 · 手势 · 外观与联动）

struct AoomooaGeneralSettingsView: View {
    @AppStorage(AoomooaPrefs.Key.hoverDelay) private var hoverDelay = AoomooaPrefs.Default.hoverDelay
    @AppStorage(AoomooaPrefs.Key.collapseDelay) private var collapseDelay = AoomooaPrefs.Default.collapseDelay
    @AppStorage(AoomooaPrefs.Key.swipeSensitivity) private var swipeSensitivity = AoomooaPrefs.Default.swipeSensitivity
    @AppStorage(AoomooaPrefs.Key.tintStrength) private var tintStrength = AoomooaPrefs.Default.tintStrength
    @AppStorage(AoomooaPrefs.Key.animationSpeed) private var animationSpeed = AoomooaPrefs.Default.animationSpeed

    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @Default(.showOnAllDisplays) private var showOnAllDisplays
    @Default(.mediaController) private var mediaController
    @Default(.hudReplacement) private var hudReplacement

    @State private var screens: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
        guard let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }
    @State private var accessibilityAuthorized = false

    private var availableMediaControllers: [MediaControllerType] {
        MusicManager.shared.isNowPlayingDeprecated
            ? MediaControllerType.allCases.filter { $0 != .nowPlaying }
            : MediaControllerType.allCases
    }

    var body: some View {
        Form {
            systemSection
            gestureSection
            appearanceAndSystemSection
        }
        .formStyle(.grouped)
        .navigationTitle("常规")
        .task {
            accessibilityAuthorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        }
        .onAppear {
            XPCHelperClient.shared.startMonitoringAccessibilityAuthorization()
        }
        .onDisappear {
            XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
        }
        .onReceive(NotificationCenter.default.publisher(for: .accessibilityAuthorizationChanged)) { note in
            if let granted = note.userInfo?["granted"] as? Bool {
                accessibilityAuthorized = granted
            }
        }
    }

    private var systemSection: some View {
        Section("系统") {
            LaunchAtLogin.Toggle("开机自动启动")
            Toggle("在菜单栏显示图标", isOn: Binding(
                get: { Defaults[.menubarIcon] },
                set: { Defaults[.menubarIcon] = $0 }
            ))
            Defaults.Toggle(key: .showOnAllDisplays) {
                Text("在所有显示器上显示")
            }
            .onChange(of: showOnAllDisplays) {
                NotificationCenter.default.post(name: .showOnAllDisplaysChanged, object: nil)
            }
            if !showOnAllDisplays && screens.count > 1 {
                Picker("首选显示器", selection: $coordinator.preferredScreenUUID) {
                    ForEach(screens, id: \.uuid) { screen in
                        Text(screen.name).tag(screen.uuid as String?)
                    }
                }
                .onChange(of: coordinator.preferredScreenUUID) {
                    NotificationCenter.default.post(name: .selectedScreenChanged, object: nil)
                }
            }
            Defaults.Toggle(key: .hideFromScreenRecording) {
                Text("录屏与共享屏幕时隐藏")
            }
            Defaults.Toggle(key: .showOnLockScreen) {
                Text("锁屏时显示")
            }
        }
    }

    private var gestureSection: some View {
        Section {
            Slider(value: $hoverDelay, in: AoomooaPrefs.Limits.hoverDelay, step: 0.1) {
                aoomooaValueRow("悬停多久后展开", String(format: "%.1f 秒", hoverDelay))
            }
            Slider(value: $collapseDelay, in: AoomooaPrefs.Limits.collapseDelay, step: 0.5) {
                aoomooaValueRow("移开多久后收起", String(format: "%.1f 秒", collapseDelay))
            }
            Slider(value: $swipeSensitivity, in: AoomooaPrefs.Limits.swipeSensitivity, step: 0.1) {
                aoomooaValueRow("左右滑切页灵敏度", "滑 \(Int(AoomooaPrefs.tabSwipeDistance)) pt 切页")
            } minimumValueLabel: {
                Text("迟钝")
            } maximumValueLabel: {
                Text("灵敏")
            }
            Toggle("展开时记住上次停留的页面", isOn: $coordinator.openLastTabByDefault)
            Defaults.Toggle(key: .enableHaptics) {
                Text("触感反馈")
            }
        } header: {
            Text("手势与交互")
        } footer: {
            Text("在刘海任意空白处右键可随时打开设置或退出应用。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appearanceAndSystemSection: some View {
        Section("外观与系统联动") {
            Slider(value: $tintStrength, in: AoomooaPrefs.Limits.tintStrength, step: 0.05) {
                aoomooaValueRow("封面取色强度", "\(Int((tintStrength * 100).rounded()))%")
            }
            Slider(value: $animationSpeed, in: AoomooaPrefs.Limits.animationSpeed, step: 0.25) {
                aoomooaValueRow("动画速度", String(format: "%.2g×", animationSpeed))
            } minimumValueLabel: {
                Text("慢")
            } maximumValueLabel: {
                Text("快")
            }
            Picker("音乐来源", selection: $mediaController) {
                ForEach(availableMediaControllers) { controller in
                    Text(controller.displayName).tag(controller)
                }
            }
            .onChange(of: mediaController) { _, _ in
                NotificationCenter.default.post(name: .mediaControllerChanged, object: nil)
            }
            Defaults.Toggle(key: .hudReplacement) {
                Text("替换系统音量 / 亮度浮窗")
            }
            .disabled(!accessibilityAuthorized)
            if !accessibilityAuthorized {
                HStack {
                    Text("替换系统浮窗需要“辅助功能”权限")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("前往授权") {
                        XPCHelperClient.shared.requestAccessibilityAuthorization()
                    }
                    .controlSize(.small)
                }
            }
            Defaults.Toggle(key: .showPowerStatusNotifications) {
                Text("充电状态提醒")
            }
        }
    }
}

// MARK: - 2. 模块（AI 哨兵 · 常用网站 · AI 入口 · 计时器 · 天气）

struct AoomooaModulesSettingsView: View {
    @AppStorage(AoomooaPrefs.Key.timerMinutes) private var timerMinutes = AoomooaPrefs.Default.timerMinutes
    @AppStorage(AoomooaPrefs.Key.timerShowWhenClosed) private var timerShowWhenClosed = AoomooaPrefs.Default.timerShowWhenClosed
    @AppStorage(AoomooaPrefs.Key.weatherCity) private var weatherCity = AoomooaPrefs.Default.weatherCity
    @AppStorage(AoomooaPrefs.Key.sentinelEnabled) private var sentinelEnabled = AoomooaPrefs.Default.sentinelEnabled
    @AppStorage(AoomooaPrefs.Key.sentinelTimeoutAntigravity) private var timeoutAntigravity = AoomooaPrefs.Default.sentinelTimeoutAntigravity
    @AppStorage(AoomooaPrefs.Key.sentinelTimeoutDeepSeek) private var timeoutDeepSeek = AoomooaPrefs.Default.sentinelTimeoutDeepSeek
    @AppStorage(AoomooaPrefs.Key.sentinelTimeoutClaude) private var timeoutClaude = AoomooaPrefs.Default.sentinelTimeoutClaude

    @ObservedObject private var sites = FavouriteSitesModel.shared
    @ObservedObject private var aiSites = FavouriteSitesModel.ai
    @ObservedObject private var weather = WeatherModel.shared
    @ObservedObject private var sentinel = AoomooaSentinelModel.shared
    @State private var copiedTokenPath = false

    var body: some View {
        Form {
            sentinelSection
            SiteListSettingsSection(
                title: "常用网站",
                placeholder: "网址，比如 aoomooa.art",
                resetLabel: "恢复默认网站",
                footer: "在刘海首页右键网站图标也可更换自定义图片或重新获取图标。",
                model: sites
            )
            SiteListSettingsSection(
                title: "AI 入口",
                placeholder: "网址，比如 chat.deepseek.com",
                resetLabel: "恢复默认 AI",
                footer: "显示在首页右侧独立模块，与常用网站分开排列。",
                model: aiSites
            )
            timerSection
            weatherSection
        }
        .formStyle(.grouped)
        .navigationTitle("模块")
    }

    private var sentinelSection: some View {
        Section {
            Toggle("启用 AI 状态小灯", isOn: $sentinelEnabled)
                .onChange(of: sentinelEnabled) { _, on in
                    sentinel.setEnabled(on)
                }

            LabeledContent("监听状态") {
                if !sentinelEnabled {
                    Text("已关闭").foregroundStyle(.secondary)
                } else if sentinel.isListening {
                    Text("127.0.0.1:\(AoomooaPrefs.sentinelPort) · 运行中")
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.success)
                } else if let err = sentinel.listenError {
                    Text("失败：\(err)")
                        .foregroundStyle(DS.Colors.warning)
                        .lineLimit(1)
                } else {
                    Text("启动中…").foregroundStyle(.secondary)
                }
            }

            Stepper(value: $timeoutAntigravity, in: AoomooaPrefs.Limits.sentinelTimeout) {
                aoomooaValueRow("Antigravity「很久没消息」超时", "\(timeoutAntigravity) 分钟")
            }
            .onChange(of: timeoutAntigravity) { _, _ in sentinel.rescheduleTimers() }

            Stepper(value: $timeoutDeepSeek, in: AoomooaPrefs.Limits.sentinelTimeout) {
                aoomooaValueRow("DeepSeek「很久没消息」超时", "\(timeoutDeepSeek) 分钟")
            }
            .onChange(of: timeoutDeepSeek) { _, _ in sentinel.rescheduleTimers() }

            Stepper(value: $timeoutClaude, in: AoomooaPrefs.Limits.sentinelTimeout) {
                aoomooaValueRow("Claude「很久没消息」超时", "\(timeoutClaude) 分钟")
            }
            .onChange(of: timeoutClaude) { _, _ in sentinel.rescheduleTimers() }

            LabeledContent("口令文件（0600）") {
                HStack(spacing: DS.Space.s) {
                    Text(sentinel.tokenFilePath)
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(copiedTokenPath ? "已复制" : "复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(sentinel.tokenFilePath, forType: .string)
                        copiedTokenPath = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedTokenPath = false
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.s) {
                    Button("灰·工作中") { sentinel.simulate(source: .antigravity, state: .working) }
                    Button("绿·已完成") { sentinel.simulate(source: .claude, state: .done) }
                    Button("红·需确认") { sentinel.simulate(source: .deepseek, state: .attention) }
                    Button("橙·长时间") { sentinel.simulate(source: .claude, state: .stale) }
                }
                HStack(spacing: DS.Space.s) {
                    Button("三灯齐亮") {
                        sentinel.simulate(source: .antigravity, state: .working)
                        sentinel.simulate(source: .claude, state: .done)
                        sentinel.simulate(source: .deepseek, state: .attention)
                    }
                    Button("熄灭") { sentinel.clearAll() }
                }
            }
            .disabled(!sentinelEnabled)
        } header: {
            Text("AI 哨兵")
        } footer: {
            Text("仅监听本机回环 127.0.0.1，强制校验 X-Notch-Token 并拒绝浏览器 Origin；空闲 0% CPU，不写日志、不落盘内容。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var timerSection: some View {
        Section("计时器") {
            Stepper(value: $timerMinutes, in: AoomooaPrefs.Limits.timerMinutes) {
                aoomooaValueRow("滚轮默认时长", "\(timerMinutes) 分钟")
            }
            Toggle("收起时在刘海上显示倒计时", isOn: $timerShowWhenClosed)
        }
    }

    private var weatherSection: some View {
        Section {
            LabeledContent("城市") {
                TextField("城市", text: $weatherCity, prompt: Text("留空 = 按网络位置自动判断"))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .onSubmit { weather.refresh() }
            }
            HStack {
                Button(weather.isLoading ? "刷新中…" : "立即刷新") { weather.refresh() }
                    .disabled(weather.isLoading)
                if let s = weather.snapshot {
                    Text("上次：\(s.city) \(s.temperature)° \(s.condition)")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("天气")
        } footer: {
            Text("数据来自 wttr.in（每 30 分钟缓存刷新），显示在第 3 页日历顶部。开代理时填城市名（如 Münster）更准。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 3. 诊断与关于（权限 · 后台进程 · 恢复默认 · 退出）

struct AoomooaAboutSettingsView: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var sentinel = AoomooaSentinelModel.shared

    @State private var accessibilityGranted: Bool?
    @State private var cleanupMessage: String?
    @State private var cleaning = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            aboutSection
            diagnosticsSection
            actionsSection
        }
        .formStyle(.grouped)
        .navigationTitle("诊断与关于")
        .task { accessibilityGranted = await XPCHelperClient.shared.isAccessibilityAuthorized() }
    }

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("应用名称", value: "aoomooa🉐刘海屏")
            LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            LabeledContent("开源协议", value: "GNU GPLv3（基于 Boring Notch）")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("安装路径") {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Bundle.main.bundlePath).textSelection(.enabled)
                    if !AoomooaDiagnostics.isInstalledAtFixedPath {
                        Text("不是 \(AoomooaDiagnostics.fixedInstallPath)，辅助功能权限可能反复失效")
                            .font(DS.Fonts.caption)
                            .foregroundStyle(DS.Colors.warning)
                    }
                }
            }
            LabeledContent("应用标识", value: Bundle.main.bundleIdentifier ?? "—")
            LabeledContent("签名") {
                Text(AoomooaDiagnostics.signingSummary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("辅助功能权限") {
                switch accessibilityGranted {
                case .some(true): Text("已授权").foregroundStyle(DS.Colors.success)
                case .some(false): Text("未授权").foregroundStyle(DS.Colors.warning)
                case .none: Text("检查中…").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("打开“辅助功能”设置") { AoomooaDiagnostics.openAccessibilitySettings() }
                Button("重新检查") {
                    accessibilityGranted = nil
                    Task { accessibilityGranted = await XPCHelperClient.shared.isAccessibilityAuthorized() }
                }
            }

            LabeledContent("后台子进程", value: "\(AoomooaProcessGuard.shared.trackedCount) 个（音乐读取进程）")
            HStack {
                Button(cleaning ? "清理中…" : "清理残留后台进程") {
                    cleaning = true
                    cleanupMessage = nil
                    Task {
                        let n = await AoomooaProcessGuard.shared.cleanupOrphansNow()
                        cleaning = false
                        switch n {
                        case .some(0): cleanupMessage = "没有发现残留进程"
                        case .some(let count): cleanupMessage = "已清理 \(count) 个残留的 mediaremote-adapter.pl"
                        case .none: cleanupMessage = "后台助手未响应"
                        }
                    }
                }
                .disabled(cleaning)
                if let cleanupMessage {
                    Text(cleanupMessage)
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("诊断")
        } footer: {
            Text(AoomooaDiagnostics.accessibilityExplanation)
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                Button("恢复默认设置…") { confirmReset = true }
                    .confirmationDialog("把手势、外观、计时器、天气与 AI 哨兵恢复成默认值？", isPresented: $confirmReset) {
                        Button("恢复默认", role: .destructive, action: resetPrefs)
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("常用网站与 AI 入口不会被清空（各自有独立的“恢复默认”）。")
                    }
                Spacer()
                Button("退出应用", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    private func resetPrefs() {
        AoomooaPrefs.resetAll()
        coordinator.openLastTabByDefault = true
        sentinel.setEnabled(AoomooaPrefs.Default.sentinelEnabled)
        sentinel.rescheduleTimers()
    }
}

// MARK: - 共用小组件

private func aoomooaValueRow(_ title: String, _ value: String) -> some View {
    HStack {
        Text(title)
        Spacer()
        Text(value)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

/// 常用网站 / AI 入口共用的设置列表区块
private struct SiteListSettingsSection: View {
    let title: String
    let placeholder: String
    let resetLabel: String
    let footer: String
    @ObservedObject var model: FavouriteSitesModel

    @State private var newTitle = ""
    @State private var newAddress = ""
    @State private var addFailed = false

    private static let siteTitleWidth: CGFloat = 140

    var body: some View {
        Section {
            ForEach(Array(model.sites.enumerated()), id: \.element.id) { index, site in
                HStack(spacing: DS.Space.s) {
                    SiteIconView(site: site, size: DS.Size.appIconMin, revision: model.iconRevision)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(site.title)
                        Text(site.url)
                            .font(DS.Fonts.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("图标：" + (site.iconPath != nil ? "自己选的图片" : SiteIconCache.shared.sourceDescription(host: site.host)))
                            .font(DS.Fonts.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: DS.Space.s)
                    Button { model.move(site, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(index == 0)
                        .help("上移")
                    Button { model.move(site, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(index == model.sites.count - 1)
                        .help("下移")
                    Button { model.refetchIcon(for: site) } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(site.iconPath != nil)
                        .help("重新获取图标")
                    Button { model.remove(site) } label: { Image(systemName: "trash") }
                        .help("删除")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: DS.Space.s) {
                TextField("名称", text: $newTitle, prompt: Text("名称（可不填）"))
                    .labelsHidden()
                    .frame(maxWidth: Self.siteTitleWidth)
                TextField("网址", text: $newAddress, prompt: Text(placeholder))
                    .labelsHidden()
                    .onSubmit(add)
                Button("添加", action: add)
                    .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if addFailed {
                Text("网址无效，或者已经在列表里了")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.warning)
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Button("重新获取所有图标") { model.refreshIcons(force: true) }
                    .buttonStyle(.borderless)
                    .font(DS.Fonts.caption)
                Button(resetLabel) { model.resetToDefaults() }
                    .buttonStyle(.borderless)
                    .font(DS.Fonts.caption)
            }
        } footer: {
            Text(footer)
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        addFailed = !model.add(title: newTitle, address: newAddress)
        if !addFailed {
            newTitle = ""
            newAddress = ""
        }
    }
}

// MARK: - 诊断信息

enum AoomooaDiagnostics {
    static let fixedInstallPath = "/Applications/aoomooa🉐刘海屏.app"

    static var isInstalledAtFixedPath: Bool {
        Bundle.main.bundlePath == fixedInstallPath
    }

    static let accessibilityExplanation = """
    替换系统音量 / 亮度浮窗需要“辅助功能”权限。macOS 把这个权限记在「应用标识 + 签名」上：\
    用 scripts/build-install.sh 安装到 /Applications/aoomooa🉐刘海屏.app、并用固定的 Apple 开发证书签名，重新编译后就不用再授权。\
    如果是临时签名（ad-hoc），每次编译签名都会变，需要在 系统设置 → 隐私与安全性 → 辅助功能 里删掉旧的 aoomooa 再重新勾选。
    """

    /// 当前运行的这份 App 是用什么签名的
    static var signingSummary: String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "无法读取" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "无法读取" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "无法读取" }

        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        if let certificates = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
           let leaf = certificates.first {
            var commonName: CFString?
            SecCertificateCopyCommonName(leaf, &commonName)
            let name = (commonName as String?) ?? "开发证书"
            return team.map { "\(name)（团队 \($0)）" } ?? name
        }
        return "临时签名（ad-hoc）：每次编译都会变"
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
