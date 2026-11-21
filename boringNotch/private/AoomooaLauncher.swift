//
//  AoomooaLauncher.swift
//  boringNotch (aoomooa fork)
//
//  页面 2（控制台）：左边系统状态，右边常用工具启动器（支持本地 App 与网页快捷方式混排）。
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LauncherItem: Codable, Hashable, Identifiable {
    /// 本地 App 路径（/Applications/...）或网页地址（https://...）
    var target: String
    /// 自定义显示名称；留空时 App 自动读系统显示名，网址自动读域名
    var title: String? = nil
    /// 网页快捷方式的自定义图标路径（覆盖 favicon）
    var iconPath: String? = nil

    var id: String { target }

    var isURL: Bool {
        target.hasPrefix("https://") || target.hasPrefix("http://")
    }

    var displayName: String {
        if let custom = title?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if isURL {
            return (URL(string: target)?.host ?? target).replacingOccurrences(of: "www.", with: "")
        }
        let n = FileManager.default.displayName(atPath: target)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    /// 供 SiteIconView / SiteIconCache 使用
    var asFavouriteSite: FavouriteSite {
        FavouriteSite(title: displayName, url: target, iconPath: iconPath)
    }
}

@MainActor
final class NotchLauncherModel: ObservableObject {
    static let shared = NotchLauncherModel()

    private let legacyStorageKey = "aoomooaLauncherApps"
    private let storageKey = "aoomooaLauncherItems.v2"

    static let googleDriveItem = LauncherItem(
        target: "https://drive.google.com/drive/home",
        title: "Google Drive"
    )

    /// 默认 8 格（4×2 满格）：7 个常用工具 App + Google Drive
    static let defaultItems: [LauncherItem] = [
        LauncherItem(target: "/Applications/Shadowrocket.app"),
        LauncherItem(target: "/Applications/Tailscale.app"),
        LauncherItem(target: "/System/Applications/Utilities/Screen Sharing.app"),
        LauncherItem(target: "/System/Applications/Utilities/Terminal.app"),
        LauncherItem(target: "/Applications/Xcode.app"),
        LauncherItem(target: "/Applications/Visual Studio Code.app"),
        LauncherItem(target: "/Applications/Obsidian.app"),
        googleDriveItem,
    ]

    @Published private(set) var items: [LauncherItem]
    @Published private(set) var iconRevision = 0
    private var refreshingIcons = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([LauncherItem].self, from: data) {
            items = saved
        } else if let legacy = UserDefaults.standard.stringArray(forKey: legacyStorageKey) {
            // 从旧版纯 App 路径列表迁移，并自动补上 Google Drive
            var migrated = legacy.map { LauncherItem(target: $0) }
            if !migrated.contains(where: { $0.target == Self.googleDriveItem.target }) {
                migrated.append(Self.googleDriveItem)
            }
            items = migrated
            save()
        } else {
            items = Self.defaultItems
        }
        refreshURLIcons()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    func refreshURLIcons(force: Bool = false) {
        guard !refreshingIcons else { return }
        let urlItems = items.filter { $0.isURL && $0.iconPath == nil }
        guard !urlItems.isEmpty else { return }
        refreshingIcons = true
        let sites = urlItems.map(\.asFavouriteSite)
        Task.detached(priority: .utility) { [weak self] in
            var changed = false
            for site in sites {
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

    func refetchIcon(for item: LauncherItem) {
        guard item.isURL else { return }
        SiteIconCache.shared.clear(host: item.asFavouriteSite.host)
        iconRevision += 1
    }

    func open(_ item: LauncherItem) {
        if item.isURL {
            if let url = URL(string: item.target) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.target), configuration: config) { _, _ in }
    }

    func remove(_ item: LauncherItem) {
        withAnimation(DS.Motion.micro) {
            items.removeAll { $0.target == item.target }
        }
        save()
    }

    func addViaPicker() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加到刘海"
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let picked = panel.urls.map { $0.path }
            Task { @MainActor in
                guard let self else { return }
                withAnimation(DS.Motion.micro) {
                    for p in picked where !self.items.contains(where: { $0.target == p }) {
                        self.items.append(LauncherItem(target: p))
                    }
                }
                self.save()
            }
        }
    }

    func promptAddURL() {
        let alert = NSAlert()
        alert.messageText = "添加网站快捷方式"
        alert.informativeText = "输入网址（可选填名称）"
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
        nameField.placeholderString = "名称（可不填，如 Google Drive）"
        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        urlField.placeholderString = "https://"
        container.addSubview(nameField)
        container.addSubview(urlField)
        alert.accessoryView = container
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        alert.window.initialFirstResponder = urlField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var text = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard URL(string: text)?.host != nil else { return }
        guard !items.contains(where: { $0.target == text }) else { return }
        let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = LauncherItem(target: text, title: title.isEmpty ? nil : title)
        withAnimation(DS.Motion.micro) { items.append(item) }
        save()
        let site = item.asFavouriteSite
        Task.detached(priority: .utility) { _ = await SiteIconCache.shared.load(site: site) }
    }

    func promptRename(_ item: LauncherItem) {
        let alert = NSAlert()
        alert.messageText = "重命名"
        alert.informativeText = "留空则恢复默认名称"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = item.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let i = items.firstIndex(where: { $0.target == item.target }) else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(DS.Motion.micro) {
            items[i].title = newName.isEmpty ? nil : newName
        }
        save()
    }

    func chooseIcon(for item: LauncherItem) {
        guard item.isURL else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "用作图标"
        NSApp.activate()
        panel.begin { [weak self] response in
            guard response == .OK, let picked = panel.url else { return }
            Task { @MainActor in self?.storeIcon(from: picked, for: item) }
        }
    }

    func resetIcon(for item: LauncherItem) {
        guard let i = items.firstIndex(where: { $0.target == item.target }) else { return }
        items[i].iconPath = nil
        save()
    }

    private func storeIcon(from source: URL, for item: LauncherItem) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let i = items.firstIndex(where: { $0.target == item.target }) else { return }
        let dir = support.appendingPathComponent("aoomooa-site-icons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let host = item.asFavouriteSite.host
        let target = dir.appendingPathComponent("\(host)-\(Int(Date().timeIntervalSince1970)).\(ext)")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try fm.copyItem(at: source, to: target)
            withAnimation(DS.Motion.micro) { items[i].iconPath = target.path }
            save()
        } catch {
            NSLog("aoomooa: could not copy launcher icon: \(error)")
        }
    }

    func appIcon(_ item: LauncherItem) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.target)
    }
}

struct NotchLauncherView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var model = NotchLauncherModel.shared

    var body: some View {
        // 和启动台一样：图标 + 名字。悬停底色轻微变亮，按下轻微缩小，没有放大、跳动、发光
        GeometryReader { g in
            let grid = AoomooaIconGrid(count: model.items.count, size: g.size, minColumns: 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: grid.columns),
                      spacing: DS.Space.s) {
                ForEach(model.items) { item in
                    AoomooaIconTile(title: item.displayName, iconSize: grid.iconSize, action: { launch(item) }) {
                        if item.isURL {
                            SiteIconView(site: item.asFavouriteSite, size: grid.iconSize, revision: model.iconRevision)
                        } else {
                            Image(nsImage: model.appIcon(item))
                                .resizable()
                                .interpolation(.high)
                        }
                    }
                    .contextMenu {
                        if item.isURL {
                            Button("更换图标…") { model.chooseIcon(for: item) }
                            if item.iconPath != nil {
                                Button("恢复网站自带图标") { model.resetIcon(for: item) }
                            } else {
                                Button("重新获取图标") { model.refetchIcon(for: item) }
                            }
                            Divider()
                        }
                        Button("重命名…") { model.promptRename(item) }
                        Button("从刘海移除") { model.remove(item) }
                        Divider()
                        Button("添加 App…") { model.addViaPicker() }
                        Button("添加网站…") { model.promptAddURL() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .contextMenu {
                Button("添加 App…") { model.addViaPicker() }
                Button("添加网站…") { model.promptAddURL() }
            }
        }
        .onAppear { model.refreshURLIcons() }
    }

    private func launch(_ item: LauncherItem) {
        model.open(item)
        withAnimation(AoomooaHover.collapseAnimation) { vm.close() }
    }
}

/// aoomooa 页面 2（控制台）：左边系统状态，右边工具启动器（7 App + Google Drive）
struct NotchWorkspaceView: View {
    /// 左边系统状态占的宽度比例（~30%，右侧 70% 给 4×2 启动器）
    private let statusShare: CGFloat = 0.30

    var body: some View {
        GeometryReader { g in
            HStack(spacing: DS.Space.l) {
                AoomooaSystemStatusView()
                    .aoomooaModule()
                    .frame(width: (g.size.width - DS.Space.l) * statusShare)
                NotchLauncherView()
                    .aoomooaModule()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
