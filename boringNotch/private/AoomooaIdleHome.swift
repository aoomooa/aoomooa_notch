//
//  AoomooaIdleHome.swift
//  boringNotch (aoomooa fork)
//
//  The Home page: now playing (music or video, any app) · favourite sites · live system status.
//

import AppKit
import Darwin
import Defaults
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Favourite sites

struct FavouriteSite: Codable, Hashable, Identifiable {
    var title: String
    var url: String
    /// Your own picture for this site (overrides the website's favicon)
    var iconPath: String? = nil
    var id: String { url }
    var host: String { URL(string: url)?.host ?? url }
}

@MainActor
final class FavouriteSitesModel: ObservableObject {
    static let shared = FavouriteSitesModel(
        key: "aoomooaFavouriteSites.v3",
        defaults: FavouriteSitesModel.defaultSites,
        promptTitle: "添加常用网站",
        promptHint: "输入网址，比如 aoomooa.art",
        migrateFromKey: "aoomooaFavouriteSites.v2",
        droppingHosts: ["bilibili.com", "www.bilibili.com", "chat.deepseek.com", "deepseek.com"]
    )

    /// 独立的 AI 入口列表（首页右侧独立模块）
    static let ai = FavouriteSitesModel(
        key: "aoomooaAISites.v1",
        defaults: FavouriteSitesModel.defaultAISites,
        promptTitle: "添加 AI 网站",
        promptHint: "输入网址，比如 chat.deepseek.com",
        carryIconsFromKey: "aoomooaFavouriteSites.v2"
    )

    private let key: String
    let defaultList: [FavouriteSite]
    private let promptTitle: String
    private let promptHint: String

    /// 首页常用网站默认列表（2×2）
    static let defaultSites: [FavouriteSite] = [
        .init(title: "aoomooa.art", url: "https://aoomooa.art"),
        .init(title: "GitHub", url: "https://github.com"),
        .init(title: "Cloudflare", url: "https://dash.cloudflare.com"),
        .init(title: "X", url: "https://x.com"),
    ]

    /// 首页独立 AI 模块默认列表
    static let defaultAISites: [FavouriteSite] = [
        .init(title: "DeepSeek", url: "https://chat.deepseek.com/"),
        .init(title: "Gemini", url: "https://gemini.google.com/app?hl=zh"),
    ]

    /// 兼容旧引用
    static var defaults: [FavouriteSite] { defaultSites }

    @Published private(set) var sites: [FavouriteSite]
    /// 右键“重新获取图标”后加一，图标视图据此重新加载
    @Published private(set) var iconRevision = 0

    private init(
        key: String,
        defaults: [FavouriteSite],
        promptTitle: String,
        promptHint: String,
        migrateFromKey: String? = nil,
        droppingHosts: Set<String> = [],
        carryIconsFromKey: String? = nil
    ) {
        self.key = key
        self.defaultList = defaults
        self.promptTitle = promptTitle
        self.promptHint = promptHint

        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([FavouriteSite].self, from: data) {
            sites = saved
        } else if let oldKey = migrateFromKey,
                  let oldData = UserDefaults.standard.data(forKey: oldKey),
                  let oldSites = try? JSONDecoder().decode([FavouriteSite].self, from: oldData) {
            // 从旧版本迁移：保留用户自定义图标与其他网站，剔除已下线/移出的条目
            let migrated = oldSites.filter { !droppingHosts.contains($0.host.lowercased()) }
            sites = migrated.isEmpty ? defaults : migrated
            save()
        } else {
            var initial = defaults
            // 若旧列表里为相同域名设置过自定义图标，一并带过来
            if let carryKey = carryIconsFromKey,
               let oldData = UserDefaults.standard.data(forKey: carryKey),
               let oldSites = try? JSONDecoder().decode([FavouriteSite].self, from: oldData) {
                let iconByHost = Dictionary(uniqueKeysWithValues: oldSites.compactMap { s in
                    s.iconPath.map { (s.host.lowercased(), $0) }
                })
                for i in initial.indices {
                    if let customPath = iconByHost[initial[i].host.lowercased()] {
                        initial[i].iconPath = customPath
                    }
                }
            }
            sites = initial
        }
        refreshIcons()
    }

    private var refreshingIcons = false

    /// 在后台检查图标：没有缓存或缓存超过一天的才联网；网站换了 logo 会自动换上。
    /// force = 不管缓存新旧，全部重新检查（设置里的“重新获取所有图标”）
    func refreshIcons(force: Bool = false) {
        guard !refreshingIcons else { return }
        refreshingIcons = true
        let list = sites.filter { $0.iconPath == nil }
        Task.detached(priority: .utility) { [weak self] in
            var changed = false
            for site in list {
                if await SiteIconCache.shared.refresh(site: site, force: force) != nil { changed = true }
            }
            let didChange = changed
            await MainActor.run {
                guard let self else { return }
                self.refreshingIcons = false
                if didChange || force { self.iconRevision += 1 }
            }
        }
    }

    /// 清掉这个网站的缓存，马上重新联网取
    func refetchIcon(for site: FavouriteSite) {
        SiteIconCache.shared.clear(host: site.host)
        iconRevision += 1
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sites) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(title: String, url: String) {
        guard !sites.contains(where: { $0.url == url }) else { return }
        let site = FavouriteSite(title: title, url: url)
        withAnimation(DS.Motion.micro) { sites.append(site) }
        save()
        Task.detached(priority: .utility) { _ = await SiteIconCache.shared.load(site: site) }
    }

    func remove(_ site: FavouriteSite) {
        withAnimation(DS.Motion.micro) { sites.removeAll { $0.url == site.url } }
        save()
    }

    /// 上移 / 下移（设置页排序用）
    func move(_ site: FavouriteSite, by offset: Int) {
        guard let i = sites.firstIndex(where: { $0.url == site.url }) else { return }
        let j = i + offset
        guard sites.indices.contains(j) else { return }
        withAnimation(DS.Motion.micro) { sites.swapAt(i, j) }
        save()
    }

    /// 恢复成第一次打开时的网站列表
    func resetToDefaults() {
        withAnimation(DS.Motion.micro) { sites = defaultList }
        save()
    }

    /// 把输入的网址整理好再添加；返回是否添加成功
    @discardableResult
    func add(title: String, address: String) -> Bool {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host else { return false }
        guard !sites.contains(where: { $0.url == text }) else { return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        add(title: name.isEmpty ? host.replacingOccurrences(of: "www.", with: "") : name, url: text)
        return true
    }

    /// Ask for a web address and add it
    func promptAdd() {
        let alert = NSAlert()
        alert.messageText = promptTitle
        alert.informativeText = promptHint
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        add(title: "", address: field.stringValue)
    }

    /// Pick any image (png / jpg / svg / icns …) to use as this site's icon
    func chooseIcon(for site: FavouriteSite) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "用作图标"
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let picked = panel.url else { return }
            Task { @MainActor in self?.storeIcon(from: picked, for: site) }
        }
    }

    func resetIcon(for site: FavouriteSite) {
        guard let i = sites.firstIndex(where: { $0.url == site.url }) else { return }
        sites[i].iconPath = nil
        save()
    }

    private func storeIcon(from source: URL, for site: FavouriteSite) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let i = sites.firstIndex(where: { $0.url == site.url }) else { return }
        let dir = support.appendingPathComponent("aoomooa-site-icons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let target = dir.appendingPathComponent("\(site.host)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try fm.copyItem(at: source, to: target)
            withAnimation(DS.Motion.micro) { sites[i].iconPath = target.path }
            save()
        } catch {
            NSLog("aoomooa: could not copy site icon: \(error)")
        }
    }

    func open(_ site: FavouriteSite) {
        if let url = URL(string: site.url) { NSWorkspace.shared.open(url) }
    }
}

// MARK: - System status

@MainActor
final class SystemStatusModel: ObservableObject {
    static let shared = SystemStatusModel()

    @Published private(set) var cpu: Double = 0          // 0…1
    @Published private(set) var memoryUsed: Double = 0   // bytes
    @Published private(set) var memoryTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published private(set) var downPerSec: Double = 0
    @Published private(set) var upPerSec: Double = 0
    @Published private(set) var diskFree: Double = 0     // bytes
    @Published private(set) var diskTotal: Double = 0    // bytes
    @Published private(set) var thermal: ProcessInfo.ThermalState = .nominal

    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastNet: (down: UInt64, up: UInt64, at: Date)?
    private var timer: Timer?

    func start() {
        sample()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in SystemStatusModel.shared.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        // CPU (all cores)
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r1 = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if r1 == KERN_SUCCESS {
            let user = UInt64(load.cpu_ticks.0), system = UInt64(load.cpu_ticks.1)
            let idle = UInt64(load.cpu_ticks.2), nice = UInt64(load.cpu_ticks.3)
            let busy = user + system + nice
            let total = busy + idle
            if let last = lastTicks, total > last.total {
                cpu = Double(busy - last.busy) / Double(total - last.total)
            }
            lastTicks = (busy, total)
        }

        // Memory (roughly what Activity Monitor calls "Memory Used")
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r2 = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if r2 == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            memoryUsed = (app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page
        }

        // Network (Wi-Fi / Ethernet)
        var down: UInt64 = 0, up: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = p {
                let ifa = cur.pointee
                if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                   let data = ifa.ifa_data, String(cString: ifa.ifa_name).hasPrefix("en") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    down += UInt64(d.ifi_ibytes)
                    up += UInt64(d.ifi_obytes)
                }
                p = ifa.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        let now = Date()
        if let last = lastNet, down >= last.down, up >= last.up {
            let dt = max(now.timeIntervalSince(last.at), 0.5)
            downPerSec = Double(down - last.down) / dt
            upPerSec = Double(up - last.up) / dt
        }
        lastNet = (down, up, now)

        // Disk (the startup volume)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                      .volumeAvailableCapacityForImportantUsageKey]) {
            diskTotal = Double(v.volumeTotalCapacity ?? 0)
            diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
        }

        // Heat — macOS's own thermal pressure reading
        thermal = ProcessInfo.processInfo.thermalState
    }
}

// MARK: - View (页面 1：播放 · 常用网站 · 独立 AI 模块)

struct AoomooaIdleHomeView: View {
    @ObservedObject private var sites = FavouriteSitesModel.shared
    @ObservedObject private var aiSites = FavouriteSitesModel.ai
    @EnvironmentObject var vm: BoringViewModel

    /// 三个模块的宽度比例：播放 · 常用网站 ·（剩下给）独立 AI
    private let playerShare: CGFloat = 0.35
    private let sitesShare: CGFloat = 0.37

    var body: some View {
        GeometryReader { g in
            // 模块之间只用间距隔开，不画线
            let usable = g.size.width - DS.Space.l * 2
            HStack(alignment: .top, spacing: DS.Space.l) {
                NowPlayingColumn()
                    .aoomooaModule()
                    .frame(width: usable * playerShare)
                sitesGrid
                    .aoomooaModule()
                    .frame(width: usable * sitesShare)
                aiColumn
                    .aoomooaModule()
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            sites.refreshIcons()
            aiSites.refreshIcons()
        }
    }

    // 常用网站：启动器式图标网格（默认 4 个自动排 2×2）
    private var sitesGrid: some View {
        GeometryReader { g in
            let grid = AoomooaIconGrid(count: sites.sites.count, size: g.size)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: grid.columns),
                      spacing: DS.Space.s) {
                ForEach(sites.sites) { site in
                    AoomooaIconTile(title: site.title, iconSize: grid.iconSize, action: {
                        sites.open(site)
                        withAnimation(AoomooaHover.collapseAnimation) { vm.close() }
                    }) {
                        SiteIconView(site: site, size: grid.iconSize, revision: sites.iconRevision)
                    }
                    .contextMenu {
                        siteContextMenu(for: site, in: sites, addLabel: "添加网站…")
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .contextMenu {
                Button("添加网站…") { sites.promptAdd() }
            }
        }
        // 模块底边再多留一点，图标离下边至少 DS.Space.l
        .padding(.bottom, DS.Space.l - DS.Space.m)
    }

    // 独立 AI 模块：默认 2 个横向大胶囊卡片，3 个以上自动切图标网格（不加多余标题）
    private var aiColumn: some View {
        Group {
            if aiSites.sites.count <= 2 {
                VStack(spacing: DS.Space.s) {
                    ForEach(aiSites.sites) { site in
                        AoomooaAICardRow(site: site, revision: aiSites.iconRevision) {
                            aiSites.open(site)
                            withAnimation(AoomooaHover.collapseAnimation) { vm.close() }
                        }
                        .contextMenu {
                            siteContextMenu(for: site, in: aiSites, addLabel: "添加 AI…")
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { g in
                    let grid = AoomooaIconGrid(count: aiSites.sites.count, size: g.size)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: grid.columns),
                              spacing: DS.Space.s) {
                        ForEach(aiSites.sites) { site in
                            AoomooaIconTile(title: site.title, iconSize: grid.iconSize, action: {
                                aiSites.open(site)
                                withAnimation(AoomooaHover.collapseAnimation) { vm.close() }
                            }) {
                                SiteIconView(site: site, size: grid.iconSize, revision: aiSites.iconRevision)
                            }
                            .contextMenu {
                                siteContextMenu(for: site, in: aiSites, addLabel: "添加 AI…")
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("添加 AI…") { aiSites.promptAdd() }
        }
    }

    @ViewBuilder
    private func siteContextMenu(for site: FavouriteSite, in model: FavouriteSitesModel, addLabel: String) -> some View {
        Button("更换图标…") { model.chooseIcon(for: site) }
        if site.iconPath != nil {
            Button("恢复网站自带图标") { model.resetIcon(for: site) }
        } else {
            Button("重新获取图标") { model.refetchIcon(for: site) }
        }
        Divider()
        Button(addLabel) { model.promptAdd() }
        Button("移除") { model.remove(site) }
    }
}

/// 首页 AI 模块里的横向大按钮（图标 + 名称 + 轻箭头）
private struct AoomooaAICardRow: View {
    let site: FavouriteSite
    let revision: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                SiteIconView(site: site, size: DS.Size.aiIcon, revision: revision)
                Text(site.title)
                    .font(DS.Fonts.body(.medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(DS.Fonts.caption(.semibold))
                    .foregroundStyle(hovering ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            }
            .padding(.horizontal, DS.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(hovering ? DS.Colors.fillHover : DS.Colors.fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(AoomooaPressStyle())
        .onHover { h in withAnimation(DS.Motion.micro) { hovering = h } }
        .help(site.title)
    }
}

// MARK: - System status view (页面 2 左侧：系统状态)

struct AoomooaSystemStatusView: View {
    @ObservedObject private var status = SystemStatusModel.shared
    /// 用量超过这个比例就标成警告色
    static let warnFraction: Double = 0.85

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatRow(label: "CPU", value: "\(Int((status.cpu * 100).rounded()))%", fraction: status.cpu)
            Spacer(minLength: DS.Space.xs)
            StatRow(label: "内存",
                    value: String(format: "%.1f / %.0f GB", status.memoryUsed / 1_073_741_824, status.memoryTotal / 1_073_741_824),
                    fraction: status.memoryTotal > 0 ? status.memoryUsed / status.memoryTotal : 0)
            Spacer(minLength: DS.Space.xs)
            StatRow(label: "磁盘",
                    value: String(format: "剩 %.0f GB", status.diskFree / 1_000_000_000),
                    fraction: status.diskTotal > 0 ? 1 - status.diskFree / status.diskTotal : 0)
            Spacer(minLength: DS.Space.xs)
            HStack {
                Text("网络").font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                Spacer(minLength: DS.Space.xs)
                Text(verbatim: "↓\(speed(status.downPerSec))  ↑\(speed(status.upPerSec))")
                    .font(DS.Fonts.caption(.medium).monospacedDigit())
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: DS.Space.xs)
            HStack {
                Text("温度").font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                Spacer(minLength: DS.Space.xs)
                thermalIndicator
            }
        }
        .onAppear { status.start() }
        .onDisappear { status.stop() }
    }

    /// 成功色 = 正常；警告色 = 偏热；强调色 = 过热（只用规范里的语义色）
    private var thermalIndicator: some View {
        let (text, color): (String, Color) = {
            switch status.thermal {
            case .nominal: return ("正常", DS.Colors.success)
            case .fair: return ("略热", DS.Colors.warning)
            case .serious: return ("很热", DS.Colors.warning)
            case .critical: return ("过热", DS.Colors.accent)
            @unknown default: return ("正常", DS.Colors.success)
            }
        }()
        return HStack(spacing: DS.Space.xs) {
            Circle().fill(color).frame(width: DS.Size.statusDot, height: DS.Size.statusDot)
            Text(text).font(DS.Fonts.caption(.medium)).foregroundStyle(color)
        }
    }

    private func speed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 { return String(format: "%.1fM", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1024 { return String(format: "%.0fK", bytesPerSec / 1024) }
        return String(format: "%.0fB", bytesPerSec)
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(label).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                Spacer(minLength: DS.Space.xs)
                Text(value)
                    .font(DS.Fonts.caption(.medium).monospacedDigit())
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.separator)
                    Capsule()
                        .fill(fraction > AoomooaSystemStatusView.warnFraction ? DS.Colors.warning : DS.Colors.indicator)
                        .frame(width: g.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: DS.Size.bar)
            .animation(DS.Motion.panel, value: fraction)
        }
    }
}

// MARK: - Now playing (compact player for the left column)

private struct NowPlayingColumn: View {
    @ObservedObject private var music = MusicManager.shared
    @State private var scrubbing: Double?
    private static let pausedArtOpacity: Double = 0.6
    private static let progressTick: TimeInterval = 0.5

    var body: some View {
        Group {
            if music.isPlayerIdle && !music.isPlaying {
                placeholder
            } else {
                player
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var accent: Color {
        Defaults[.playerColorTinting]
            ? Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.6)
            : DS.Colors.indicator
    }

    private var placeholder: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "music.note")
                .font(DS.Fonts.title)
                .foregroundStyle(DS.Colors.textSecondary)
            Text("没有在播放")
                .font(DS.Fonts.body(.medium))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var player: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                Button { music.openMusicApp() } label: {
                    Image(nsImage: music.albumArt)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: DS.Size.artwork, height: DS.Size.artwork)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                        .opacity(music.isPlaying ? 1 : Self.pausedArtOpacity)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(music.songTitle)
                        .font(DS.Fonts.body(.semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(2)
                    Text(music.artistName)
                        .font(DS.Fonts.caption)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: Self.progressTick)) { context in
                let duration = max(music.songDuration, 0)
                let live = min(music.estimatedPlaybackPosition(at: context.date), duration)
                let position = scrubbing ?? live
                VStack(spacing: DS.Space.xs) {
                    GeometryReader { g in
                        let fraction = duration > 0 ? position / duration : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Colors.separator)
                            Capsule().fill(accent)
                                .frame(width: g.size.width * CGFloat(min(max(fraction, 0), 1)))
                        }
                        .frame(height: scrubbing == nil ? DS.Size.bar : DS.Size.barActive)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    guard duration > 0 else { return }
                                    scrubbing = Double(min(max(v.location.x / g.size.width, 0), 1)) * duration
                                }
                                .onEnded { _ in
                                    if let target = scrubbing { music.seek(to: target) }
                                    scrubbing = nil
                                }
                        )
                    }
                    .frame(height: DS.Size.barHitArea)
                    HStack {
                        Text(clock(position))
                        Spacer()
                        Text(clock(duration))
                    }
                    .font(DS.Fonts.caption.monospacedDigit())
                    .foregroundStyle(DS.Colors.textSecondary)
                }
            }

            HStack(spacing: DS.Space.l) {
                Spacer(minLength: 0)
                control("backward.fill", font: DS.Fonts.body(.semibold)) { music.previousTrack() }
                control(music.isPlaying ? "pause.fill" : "play.fill", font: DS.Fonts.title) { music.togglePlay() }
                control("forward.fill", font: DS.Fonts.body(.semibold)) { music.nextTrack() }
                Spacer(minLength: 0)
            }
        }
    }

    private func control(_ symbol: String, font: Font, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(DS.Colors.textPrimary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: DS.Size.mediaButton, height: DS.Size.mediaButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func clock(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
