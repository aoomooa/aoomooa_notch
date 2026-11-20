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
    static let shared = FavouriteSitesModel()
    private let key = "aoomooaFavouriteSites.v2"

    /// First-run list — right-click a site to add, change the icon, or remove
    static let defaults: [FavouriteSite] = [
        .init(title: "aoomooa.art", url: "https://aoomooa.art"),
        .init(title: "哔哩哔哩", url: "https://www.bilibili.com"),
        .init(title: "GitHub", url: "https://github.com"),
        .init(title: "Cloudflare", url: "https://dash.cloudflare.com"),
        .init(title: "DeepSeek", url: "https://chat.deepseek.com/"),
        .init(title: "X", url: "https://x.com"),
    ]

    @Published private(set) var sites: [FavouriteSite]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([FavouriteSite].self, from: data) {
            sites = saved
        } else {
            sites = Self.defaults
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sites) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(title: String, url: String) {
        guard !sites.contains(where: { $0.url == url }) else { return }
        withAnimation(DS.Motion.micro) { sites.append(.init(title: title, url: url)) }
        save()
    }

    func remove(_ site: FavouriteSite) {
        withAnimation(DS.Motion.micro) { sites.removeAll { $0.url == site.url } }
        save()
    }

    /// Ask for a web address and add it
    func promptAdd() {
        let alert = NSAlert()
        alert.messageText = "添加常用网站"
        alert.informativeText = "输入网址，比如 aoomooa.art"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host else { return }
        add(title: host.replacingOccurrences(of: "www.", with: ""), url: text)
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

// MARK: - View

struct AoomooaIdleHomeView: View {
    @ObservedObject private var sites = FavouriteSitesModel.shared
    @ObservedObject private var status = SystemStatusModel.shared
    @EnvironmentObject var vm: BoringViewModel

    /// 三栏宽度比例：播放 · 网站 ·（剩下给）状态
    private let playerShare: CGFloat = 0.42
    private let sitesShare: CGFloat = 0.28
    private let siteColumns = 3
    /// 用量超过这个比例就标成警告色
    static let warnFraction: Double = 0.85

    var body: some View {
        GeometryReader { g in
            HStack(alignment: .top, spacing: 0) {
                NowPlayingColumn()
                    .frame(width: g.size.width * playerShare)
                divider
                sitesColumn
                    .frame(width: g.size.width * sitesShare)
                divider
                statusColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { status.start() }
        .onDisappear { status.stop() }
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Colors.separator)
            .frame(width: DS.Size.hairline)
            .padding(.vertical, DS.Space.m)
    }

    private func header(_ text: String, _ icon: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon)
            Text(text)
        }
        .font(DS.Fonts.caption(.semibold))
        .foregroundStyle(DS.Colors.textSecondary)
    }

    // Favourite sites
    private var sitesColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            header("常用网站", "star")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: siteColumns),
                      spacing: DS.Space.s) {
                ForEach(sites.sites) { site in
                    SiteTile(site: site) {
                        sites.open(site)
                        withAnimation(AoomooaHover.collapseAnimation) { vm.close() }
                    }
                    .contextMenu {
                        Button("更换图标…") { sites.chooseIcon(for: site) }
                        if site.iconPath != nil {
                            Button("恢复网站自带图标") { sites.resetIcon(for: site) }
                        }
                        Divider()
                        Button("添加网站…") { sites.promptAdd() }
                        Button("移除") { sites.remove(site) }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // System status
    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                header("系统状态", "gauge.with.dots.needle.33percent")
                Spacer(minLength: DS.Space.xs)
                thermalBadge
            }
            StatRow(label: "CPU", value: "\(Int((status.cpu * 100).rounded()))%", fraction: status.cpu)
            StatRow(label: "内存",
                    value: String(format: "%.1f / %.0f GB", status.memoryUsed / 1_073_741_824, status.memoryTotal / 1_073_741_824),
                    fraction: status.memoryTotal > 0 ? status.memoryUsed / status.memoryTotal : 0)
            StatRow(label: "磁盘",
                    value: String(format: "剩 %.0f GB", status.diskFree / 1_000_000_000),
                    fraction: status.diskTotal > 0 ? 1 - status.diskFree / status.diskTotal : 0)
            HStack {
                Text("网络").font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                Spacer(minLength: DS.Space.xs)
                Text(verbatim: "↓\(speed(status.downPerSec))  ↑\(speed(status.upPerSec))")
                    .font(DS.Fonts.caption(.medium).monospacedDigit())
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 成功色 = 正常；警告色 = 偏热；强调色 = 过热（只用规范里的语义色）
    private var thermalBadge: some View {
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
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(DS.Colors.fill))
    }

    private func speed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 { return String(format: "%.1fM", bytesPerSec / 1_048_576) }
        if bytesPerSec >= 1024 { return String(format: "%.0fK", bytesPerSec / 1024) }
        return String(format: "%.0fB", bytesPerSec)
    }
}

private struct SiteTile: View {
    let site: FavouriteSite
    let action: () -> Void
    @State private var hovering = false
    private static let hoverScale: CGFloat = 1.08

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs) {
                Favicon(host: site.host, size: DS.Size.favicon, customPath: site.iconPath)
                    .padding(DS.Space.s)
                    .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(hovering ? DS.Colors.fillHover : DS.Colors.fill))
                    .scaleEffect(hovering ? Self.hoverScale : 1)
                Text(site.title)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(hovering ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.micro) { hovering = h } }
    }
}

private struct Favicon: View {
    let host: String
    let size: CGFloat
    var customPath: String? = nil

    var body: some View {
        Group {
            if let path = customPath, let custom = NSImage(contentsOfFile: path) {
                Image(nsImage: custom).resizable().interpolation(.high)
            } else {
                remote
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
    }

    /// DuckDuckGo returns nothing when a site has no icon, so we fall back to a letter badge
    private var remote: some View {
        AsyncImage(url: URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(DS.Colors.fillHover)
                    Text(String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                        .font(DS.Fonts.body(.semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
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
                        .fill(fraction > AoomooaIdleHomeView.warnFraction ? DS.Colors.warning : DS.Colors.indicator)
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
        .padding(.horizontal, DS.Space.m)
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
