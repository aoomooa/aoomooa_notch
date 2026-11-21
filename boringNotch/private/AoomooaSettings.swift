//
//  AoomooaSettings.swift — 设置窗口里的「aoomooa」页
//
//  所有项都存在 UserDefaults（@AppStorage），改完立即生效，重启后保留。
//

import AppKit
import Security
import SwiftUI

struct AoomooaSettingsView: View {
    @AppStorage(AoomooaPrefs.Key.hoverDelay) private var hoverDelay = AoomooaPrefs.Default.hoverDelay
    @AppStorage(AoomooaPrefs.Key.collapseDelay) private var collapseDelay = AoomooaPrefs.Default.collapseDelay
    @AppStorage(AoomooaPrefs.Key.swipeSensitivity) private var swipeSensitivity = AoomooaPrefs.Default.swipeSensitivity
    @AppStorage(AoomooaPrefs.Key.tintStrength) private var tintStrength = AoomooaPrefs.Default.tintStrength
    @AppStorage(AoomooaPrefs.Key.animationSpeed) private var animationSpeed = AoomooaPrefs.Default.animationSpeed
    @AppStorage(AoomooaPrefs.Key.timerMinutes) private var timerMinutes = AoomooaPrefs.Default.timerMinutes
    @AppStorage(AoomooaPrefs.Key.timerShowWhenClosed) private var timerShowWhenClosed = AoomooaPrefs.Default.timerShowWhenClosed
    @AppStorage(AoomooaPrefs.Key.weatherCity) private var weatherCity = AoomooaPrefs.Default.weatherCity

    @ObservedObject private var sites = FavouriteSitesModel.shared
    @ObservedObject private var aiSites = FavouriteSitesModel.ai
    @ObservedObject private var weather = WeatherModel.shared
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    @State private var accessibilityGranted: Bool?
    @State private var cleanupMessage: String?
    @State private var cleaning = false
    @State private var confirmReset = false

    var body: some View {
        Form {
            gestureSection
            appearanceSection
            SiteListSettingsSection(
                title: "常用网站",
                placeholder: "网址，比如 aoomooa.art",
                resetLabel: "恢复默认网站",
                footer: "图标会按顺序找：网页里声明的 apple-touch-icon / icon → 网站根目录的 apple-touch-icon.png → Google / DuckDuckGo 图标服务。缓存超过一天会自动重新检查；网站刚换 logo 可以点 ↻ 立即更新。在刘海首页右键网站也能更换图标。",
                model: sites
            )
            SiteListSettingsSection(
                title: "AI 入口",
                placeholder: "网址，比如 chat.deepseek.com",
                resetLabel: "恢复默认 AI",
                footer: "显示在首页右侧独立 AI 模块，与常用网站分开排列。",
                model: aiSites
            )
            timerSection
            weatherSection
            diagnosticsSection
            resetSection
        }
        .formStyle(.grouped)
        .navigationTitle(Text(verbatim: "aoomooa"))
        .task { accessibilityGranted = await XPCHelperClient.shared.isAccessibilityAuthorized() }
    }

    // MARK: 手势

    private var gestureSection: some View {
        Section {
            Slider(value: $hoverDelay, in: AoomooaPrefs.Limits.hoverDelay, step: 0.1) {
                valueRow("悬停多久后展开", String(format: "%.1f 秒", hoverDelay))
            }
            Slider(value: $collapseDelay, in: AoomooaPrefs.Limits.collapseDelay, step: 0.5) {
                valueRow("移开多久后收起", String(format: "%.1f 秒", collapseDelay))
            }
            Slider(value: $swipeSensitivity, in: AoomooaPrefs.Limits.swipeSensitivity, step: 0.1) {
                valueRow("左右滑切页灵敏度", "滑 \(Int(AoomooaPrefs.tabSwipeDistance)) pt 切页")
            } minimumValueLabel: {
                Text("迟钝")
            } maximumValueLabel: {
                Text("灵敏")
            }
            Toggle("展开时记住上次停留的页面", isOn: $coordinator.openLastTabByDefault)
        } header: {
            Text("手势")
        } footer: {
            Text("悬停时先立刻显示音乐，再等上面这段时间展开；流光走完一圈的时间也一样。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        Section {
            Slider(value: $tintStrength, in: AoomooaPrefs.Limits.tintStrength, step: 0.05) {
                valueRow("封面取色强度", "\(Int((tintStrength * 100).rounded()))%")
            }
            Slider(value: $animationSpeed, in: AoomooaPrefs.Limits.animationSpeed, step: 0.25) {
                valueRow("动画速度", String(format: "%.2g×", animationSpeed))
            } minimumValueLabel: {
                Text("慢")
            } maximumValueLabel: {
                Text("快")
            }
        } header: {
            Text("外观")
        } footer: {
            Text("取色强度 0% 是纯黑；动画速度同时影响展开、收起、切页和所有小动画。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 计时器

    private var timerSection: some View {
        Section {
            Stepper(value: $timerMinutes, in: AoomooaPrefs.Limits.timerMinutes) {
                valueRow("默认时长", "\(timerMinutes) 分钟")
            }
            Toggle("收起时在刘海上显示倒计时", isOn: $timerShowWhenClosed)
        } header: {
            Text("计时器")
        } footer: {
            Text("点顶栏的 ⏱ 或双指左右滑到时间页（日历与天气 · 计时器），选 5 / 10 / 15 / 25 分钟，或用滚轮选 1–60 分钟；滚轮默认停在上面的时长。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 天气

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
            Text("数据来自 wttr.in，每 30 分钟更新一次。开着代理时自动定位可能不准，填上城市名（比如 Münster）就好。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 诊断

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
            Text(AoomooaDiagnostics.accessibilityExplanation)
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("打开“辅助功能”设置") { AoomooaDiagnostics.openAccessibilitySettings() }
                Button("重新检查") {
                    accessibilityGranted = nil
                    Task { accessibilityGranted = await XPCHelperClient.shared.isAccessibilityAuthorized() }
                }
            }

            LabeledContent("后台子进程", value: "\(AoomooaProcessGuard.shared.trackedCount) 个（本次启动的音乐读取进程）")
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
                        case .none: cleanupMessage = "现在没法检查（后台助手未响应）"
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
            Text("只会结束“父进程已经退出”的 mediaremote-adapter.pl，不会影响正在运行的其它 App。")
                .font(DS.Fonts.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 恢复默认

    private var resetSection: some View {
        Section {
            Button("恢复默认设置…") { confirmReset = true }
                .confirmationDialog("把手势、外观、计时器和天气城市恢复成默认值？", isPresented: $confirmReset) {
                    Button("恢复默认", role: .destructive, action: resetPrefs)
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("常用网站不会被清空（它有自己的“恢复默认网站”）。")
                }
        }
    }

    private func resetPrefs() {
        hoverDelay = AoomooaPrefs.Default.hoverDelay
        collapseDelay = AoomooaPrefs.Default.collapseDelay
        swipeSensitivity = AoomooaPrefs.Default.swipeSensitivity
        tintStrength = AoomooaPrefs.Default.tintStrength
        animationSpeed = AoomooaPrefs.Default.animationSpeed
        timerMinutes = AoomooaPrefs.Default.timerMinutes
        timerShowWhenClosed = AoomooaPrefs.Default.timerShowWhenClosed
        weatherCity = AoomooaPrefs.Default.weatherCity
        coordinator.openLastTabByDefault = true
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
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
