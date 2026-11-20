//
//  AoomooaLauncher.swift
//  boringNotch (aoomooa fork)
//
//  An "Apps" tab in the notch: one click opens the tools you use most
//  (VPN, remote access, Terminal, Xcode …). Add with “+”, right-click to remove.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class NotchLauncherModel: ObservableObject {
    static let shared = NotchLauncherModel()

    private let storageKey = "aoomooaLauncherApps"

    /// First-run list. Edit freely, or use “+” / right-click in the notch.
    static let defaultApps: [String] = [
        "/Applications/Shadowrocket.app",
        "/Applications/Tailscale.app",
        "/System/Applications/Utilities/Screen Sharing.app",
        "/System/Applications/Utilities/Terminal.app",
        "/Applications/Xcode.app",
        "/Applications/Visual Studio Code.app",
        "/Applications/Obsidian.app",
    ]

    @Published private(set) var paths: [String]

    private init() {
        paths = UserDefaults.standard.stringArray(forKey: storageKey) ?? Self.defaultApps
    }

    private func save() {
        UserDefaults.standard.set(paths, forKey: storageKey)
    }

    func open(_ path: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, _ in }
    }

    func remove(_ path: String) {
        withAnimation(DS.Motion.micro) {
            paths.removeAll { $0 == path }
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
                    for p in picked where !self.paths.contains(p) {
                        self.paths.append(p)
                    }
                }
                self.save()
            }
        }
    }

    func name(_ path: String) -> String {
        let n = FileManager.default.displayName(atPath: path)
        return n.hasSuffix(".app") ? String(n.dropLast(4)) : n
    }

    func icon(_ path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}

struct NotchLauncherView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var model = NotchLauncherModel.shared

    var body: some View {
        // 和启动台一样：图标 + 名字。悬停底色轻微变亮，按下轻微缩小，没有放大、跳动、发光
        GeometryReader { g in
            let grid = AoomooaIconGrid(count: model.paths.count, size: g.size, minColumns: 4)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: grid.columns),
                      spacing: DS.Space.s) {
                ForEach(model.paths, id: \.self) { path in
                    AoomooaIconTile(title: model.name(path), iconSize: grid.iconSize, action: { launch(path) }) {
                        Image(nsImage: model.icon(path))
                            .resizable()
                            .interpolation(.high)
                    }
                    .contextMenu {
                        Button("从刘海移除") { model.remove(path) }
                        Button("添加 App…") { model.addViaPicker() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .contextMenu {
                Button("添加 App…") { model.addViaPicker() }
            }
        }
    }

    private func launch(_ path: String) {
        model.open(path)
        withAnimation(AoomooaHover.collapseAnimation) { vm.close() }
    }
}

/// aoomooa: 左边提醒事项，右边应用 —— 两个模块，用间距分开，不画线
struct NotchWorkspaceView: View {
    /// 左边提醒事项占的宽度比例
    private let remindersShare: CGFloat = 0.48

    var body: some View {
        GeometryReader { g in
            HStack(spacing: DS.Space.l) {
                NotchRemindersView()
                    .aoomooaModule()
                    .frame(width: (g.size.width - DS.Space.l) * remindersShare)
                NotchLauncherView()
                    .aoomooaModule()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
