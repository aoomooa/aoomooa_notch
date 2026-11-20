//
//  AoomooaSiteIcons.swift — 常用网站的图标：多来源获取 + 内存缓存（NSCache）+ 磁盘缓存
//
//  取图标的顺序：
//    1. 网站自己 HTML 里声明的 apple-touch-icon / icon（优先大图）
//    2. https://域名/apple-touch-icon.png
//    3. Google 的图标服务（先子域名，再主域名）
//    4. DuckDuckGo 的图标服务（只认 HTTP 200，不会再拿到灰色箭头占位图）
//  都拿不到就显示首字母，一天后再试。成功的图标存在 Application Support，下次打开不再联网、不闪烁。
//

import AppKit
import SwiftUI

final class SiteIconCache: @unchecked Sendable {
    static let shared = SiteIconCache()

    /// 一个图标；fullBleed = 本身就是方形 App 图标（apple-touch-icon），可以铺满
    final class Icon: NSObject, @unchecked Sendable {
        let image: NSImage
        let fullBleed: Bool
        init(image: NSImage, fullBleed: Bool) {
            self.image = image
            self.fullBleed = fullBleed
        }
    }

    /// 全部来源都失败后，多久再试（秒）
    static let retryFailedAfter: TimeInterval = 24 * 60 * 60
    /// 单个请求超时（秒）
    static let timeout: TimeInterval = 8
    /// 只读网页开头这么多字节找 <link>
    static let htmlLimit = 512 * 1024
    /// 太小的图标不要（像素）
    static let minTouchIconPixels = 57
    static let minFaviconPixels = 16
    static let preferredFaviconPixels = 32
    /// 有些网站不给非浏览器返回正常页面
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private let memory = NSCache<NSString, Icon>()
    private let lock = NSLock()
    private var inflight: [String: Task<Icon?, Never>] = [:]

    private init() {}

    // MARK: 读取

    /// 只查缓存（内存 → 磁盘），不联网；可以在 body 里直接调用
    func cached(host: String) -> Icon? {
        if let hit = memory.object(forKey: host as NSString) { return hit }
        for full in [true, false] {
            if let url = fileURL(host: host, fullBleed: full), let image = NSImage(contentsOf: url) {
                let icon = Icon(image: image, fullBleed: full)
                memory.setObject(icon, forKey: host as NSString)
                return icon
            }
        }
        return nil
    }

    /// 用户自己选的图片，也走内存缓存
    func custom(path: String) -> NSImage? {
        let key = ("custom:" + path) as NSString
        if let hit = memory.object(forKey: key) { return hit.image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        memory.setObject(Icon(image: image, fullBleed: true), forKey: key)
        return image
    }

    /// 先查缓存，没有就联网取（同一个域名同时只取一次）
    func load(site: FavouriteSite) async -> Icon? {
        let host = site.host
        if let hit = cached(host: host) { return hit }
        if recentlyFailed(host: host) { return nil }

        lock.lock()
        if let running = inflight[host] {
            lock.unlock()
            return await running.value
        }
        let task = Task { await self.fetch(site) }
        inflight[host] = task
        lock.unlock()

        let result = await task.value
        lock.lock()
        inflight[host] = nil
        lock.unlock()
        if result == nil { markFailed(host: host) }
        return result
    }

    /// 删掉这个域名的缓存（右键“重新获取图标”）
    func clear(host: String) {
        memory.removeObject(forKey: host as NSString)
        for full in [true, false] {
            if let url = fileURL(host: host, fullBleed: full) { try? FileManager.default.removeItem(at: url) }
        }
        if let url = failedMarkerURL(host: host) { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: 联网

    private func fetch(_ site: FavouriteSite) async -> Icon? {
        let host = site.host
        guard let page = URL(string: site.url) else { return nil }

        // 1. 网页里声明的图标
        for candidate in await linkedIcons(page: page) {
            let min = candidate.fullBleed ? Self.minTouchIconPixels : Self.minFaviconPixels
            if let image = await download(candidate.url, minPixels: min) {
                return store(image, host: host, fullBleed: candidate.fullBleed)
            }
        }
        // 2. 约定位置的 apple-touch-icon
        if let url = URL(string: "https://\(host)/apple-touch-icon.png"),
           let image = await download(url, minPixels: Self.minTouchIconPixels) {
            return store(image, host: host, fullBleed: true)
        }
        // 3 / 4. 图标服务：子域名，再主域名
        for domain in Self.domains(for: host) {
            if let url = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128"),
               let image = await download(url, minPixels: Self.preferredFaviconPixels) {
                return store(image, host: host, fullBleed: false)
            }
        }
        for domain in Self.domains(for: host) {
            if let url = URL(string: "https://icons.duckduckgo.com/ip3/\(domain).ico"),
               let image = await download(url, minPixels: Self.minFaviconPixels) {
                return store(image, host: host, fullBleed: false)
            }
        }
        return nil
    }

    private struct Candidate {
        let url: URL
        let fullBleed: Bool
        let size: Int
    }

    /// 从网页 <link rel="apple-touch-icon"> / <link rel="icon"> 里找图标，大的、App 图标优先
    private func linkedIcons(page: URL) async -> [Candidate] {
        var request = URLRequest(url: page, timeoutInterval: Self.timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        let html = String(decoding: result.0.prefix(Self.htmlLimit), as: UTF8.self)
        let base = http.url ?? page

        guard let tagRegex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        var found: [Candidate] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in tagRegex.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let tag = String(html[r])
            guard let rel = Self.attribute("rel", in: tag)?.lowercased(),
                  let href = Self.attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
            let isTouch = rel.contains("apple-touch-icon")
            let isIcon = rel.split(separator: " ").contains("icon") || rel.contains("shortcut")
            guard isTouch || isIcon, !rel.contains("mask-icon") else { continue }
            let size = Self.attribute("sizes", in: tag)
                .flatMap { $0.lowercased().split(separator: "x").first }
                .flatMap { Int($0) } ?? (isTouch ? 180 : Self.preferredFaviconPixels)
            found.append(Candidate(url: url, fullBleed: isTouch, size: size))
        }
        return found.sorted { a, b in
            if a.fullBleed != b.fullBleed { return a.fullBleed }
            return a.size > b.size
        }
    }

    private func download(_ url: URL, minPixels: Int) async -> NSImage? {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse, http.statusCode == 200,
              let image = NSImage(data: result.0) else { return nil }
        let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        return pixels >= minPixels ? image : nil
    }

    // MARK: 磁盘

    private var directory: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("aoomooa-site-icons/cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(host: String, fullBleed: Bool) -> URL? {
        directory?.appendingPathComponent("\(host).\(fullBleed ? "touch" : "icon").png")
    }

    private func failedMarkerURL(host: String) -> URL? {
        directory?.appendingPathComponent("\(host).failed")
    }

    /// 存成 PNG（ICO 里有多张就取最大的那张）
    private func store(_ image: NSImage, host: String, fullBleed: Bool) -> Icon {
        let best = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide }
        let rep = best ?? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        if let png = rep?.representation(using: .png, properties: [:]),
           let url = fileURL(host: host, fullBleed: fullBleed) {
            try? png.write(to: url, options: .atomic)
        }
        let icon = Icon(image: image, fullBleed: fullBleed)
        memory.setObject(icon, forKey: host as NSString)
        return icon
    }

    private func recentlyFailed(host: String) -> Bool {
        guard let url = failedMarkerURL(host: host),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) < Self.retryFailedAfter
    }

    private func markFailed(host: String) {
        guard let url = failedMarkerURL(host: host) else { return }
        try? Data().write(to: url, options: .atomic)
    }

    // MARK: 小工具

    /// chat.deepseek.com → [chat.deepseek.com, deepseek.com]
    static func domains(for host: String) -> [String] {
        let clean = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let parts = clean.split(separator: ".")
        var result = [clean]
        if parts.count > 2 { result.append(parts.suffix(2).joined(separator: ".")) }
        return result
    }

    /// 取 HTML 标签里的属性值
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for i in 1...3 {
            if let r = Range(match.range(at: i), in: tag) { return String(tag[r]) }
        }
        return nil
    }
}

/// 一个网站的图标：系统圆角 + 轻阴影。拿不到图标时显示首字母，不会再出现灰色箭头
struct SiteIconView: View {
    let site: FavouriteSite
    let size: CGFloat
    /// 右键“重新获取图标”后变化，触发重新加载
    var revision: Int = 0
    @State private var loaded: SiteIconCache.Icon?

    var body: some View {
        let icon = loaded ?? SiteIconCache.shared.cached(host: site.host)
        content(icon)
            .frame(width: size, height: size)
            .clipShape(AoomooaSquircle())
            .aoomooaIconShadow()
            .task(id: "\(site.url)#\(revision)") {
                if revision > 0 { loaded = nil }
                if SiteIconCache.shared.cached(host: site.host) == nil {
                    loaded = await SiteIconCache.shared.load(site: site)
                }
            }
    }

    @ViewBuilder
    private func content(_ icon: SiteIconCache.Icon?) -> some View {
        if let path = site.iconPath, let custom = SiteIconCache.shared.custom(path: path) {
            Image(nsImage: custom).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else if let icon, icon.fullBleed {
            Image(nsImage: icon.image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else if let icon {
            ZStack {
                DS.Colors.iconPlate
                Image(nsImage: icon.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * DS.Size.faviconInset, height: size * DS.Size.faviconInset)
            }
        } else {
            ZStack {
                DS.Colors.fillHover
                Text(String(site.title.prefix(1)).uppercased())
                    .font(DS.Fonts.title)
                    .foregroundStyle(DS.Colors.textPrimary)
            }
        }
    }
}
