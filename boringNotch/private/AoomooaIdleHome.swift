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
        withAnimation(.smooth) { sites.append(.init(title: title, url: url)) }
        save()
    }

    func remove(_ site: FavouriteSite) {
        withAnimation(.smooth) { sites.removeAll { $0.url == site.url } }
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
            withAnimation(.smooth) { sites[i].iconPath = target.path }
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

    var body: some View {
        GeometryReader { g in
            HStack(alignment: .top, spacing: 0) {
                NowPlayingColumn()
                    .frame(width: g.size.width * 0.42)
                divider
                sitesColumn
                    .frame(width: g.size.width * 0.28)
                divider
                statusColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 2)
        .onAppear { status.start() }
        .onDisappear { status.stop() }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1)
            .padding(.vertical, 8)
    }

    private func header(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.gray)
    }

    // Favourite sites
    private var sitesColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            header("常用网站", "star")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
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
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // System status
    private var statusColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                header("系统状态", "gauge.with.dots.needle.33percent")
                Spacer(minLength: 4)
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
                Text("网络").font(.system(size: 11)).foregroundStyle(Color.gray)
                Spacer(minLength: 4)
                Text("↓\(speed(status.downPerSec))  ↑\(speed(status.upPerSec))")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Green / yellow / orange / red dot from macOS's thermal pressure
    private var thermalBadge: some View {
        let (text, color): (String, Color) = {
            switch status.thermal {
            case .nominal: return ("正常", Color(nsColor: .systemGreen))
            case .fair: return ("略热", Color(nsColor: .systemYellow))
            case .serious: return ("很热", Color(nsColor: .systemOrange))
            case .critical: return ("过热", Color(nsColor: .systemRed))
            @unknown default: return ("正常", Color(nsColor: .systemGreen))
            }
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Color.gray)
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

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Favicon(host: site.host, size: 24, customPath: site.iconPath)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.14 : 0.07)))
                    .scaleEffect(hovering ? 1.08 : 1)
                Text(site.title)
                    .font(.system(size: 9.5))
                    .foregroundStyle(hovering ? Color.white : Color.gray)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
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
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    /// DuckDuckGo returns nothing when a site has no icon, so we fall back to a letter badge
    private var remote: some View {
        AsyncImage(url: URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high)
            } else {
                ZStack {
                    Circle().fill(Color.white.opacity(0.15))
                    Text(String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 11)).foregroundStyle(Color.gray)
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(fraction > 0.85 ? Color(nsColor: .systemRed) : Color.white.opacity(0.75))
                        .frame(width: g.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 3)
            .animation(.smooth(duration: 0.4), value: fraction)
        }
    }
}

// MARK: - Now playing (compact player for the left column)

private struct NowPlayingColumn: View {
    @ObservedObject private var music = MusicManager.shared
    @State private var scrubbing: Double?

    var body: some View {
        Group {
            if music.isPlayerIdle && !music.isPlaying {
                placeholder
            } else {
                player
            }
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var accent: Color {
        Defaults[.playerColorTinting]
            ? Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.6)
            : Color.white
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "music.note")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.gray)
            Text("没有在播放")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var player: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { music.openMusicApp() } label: {
                    Image(nsImage: music.albumArt)
                        .resizable()
                        .aspectRatio(1, contentMode: .fill)
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(music.isPlaying ? 1 : 0.6)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(music.songTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                    Text(music.artistName)
                        .font(.system(size: 11))
                        .foregroundStyle(accent.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let duration = max(music.songDuration, 0)
                let live = min(music.estimatedPlaybackPosition(at: context.date), duration)
                let position = scrubbing ?? live
                VStack(spacing: 3) {
                    GeometryReader { g in
                        let fraction = duration > 0 ? position / duration : 0
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.15))
                            Capsule().fill(accent)
                                .frame(width: g.size.width * CGFloat(min(max(fraction, 0), 1)))
                        }
                        .frame(height: scrubbing == nil ? 4 : 6)
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
                    .frame(height: 10)
                    HStack {
                        Text(clock(position))
                        Spacer()
                        Text(clock(duration))
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.gray)
                }
            }

            HStack(spacing: 26) {
                Spacer(minLength: 0)
                control("backward.fill", size: 14) { music.previousTrack() }
                control(music.isPlaying ? "pause.fill" : "play.fill", size: 20) { music.togglePlay() }
                control("forward.fill", size: 14) { music.nextTrack() }
                Spacer(minLength: 0)
            }
        }
    }

    private func control(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Color.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 26)
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
