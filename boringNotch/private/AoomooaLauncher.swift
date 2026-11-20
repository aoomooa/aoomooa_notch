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

    @State private var hover: CGPoint?
    @State private var bouncing: String?
    @State private var running: Set<String> = []

    // Grid + Dock feel — tweak freely
    private let maxIcon: CGFloat = DS.Size.appIcon   // largest resting icon size
    private let minColumns = 4              // at least this many per row
    private let maxRows = 3                 // grows to 2–3 rows (4 when you add lots)
    private let maxScale: CGFloat = 1.32    // magnification right under the cursor
    private let spread: CGFloat = 36        // how far the magnification reaches
    private let labelShowsAt: CGFloat = 1.2 // show the name once an icon is this big
    private let bounceDepth: CGFloat = 8    // launch bounce distance

    var body: some View {
        GeometryReader { geo in
            let n = max(model.paths.count, 1)
            let cols = max(minColumns, Int((Double(n) / Double(maxRows)).rounded(.up)))
            let rows = max(1, Int((Double(n) / Double(cols)).rounded(.up)))
            let cellW = geo.size.width / CGFloat(cols)
            let cellH = min(geo.size.height / CGFloat(rows), cellW)
            let icon = max(DS.Size.appIconMin, min(maxIcon, cellW - DS.Space.l - DS.Space.xs, cellH - DS.Space.m - DS.Space.xs))
            let top = max(0, (geo.size.height - cellH * CGFloat(rows)) / 2)

            ZStack(alignment: .topLeading) {
                ForEach(Array(model.paths.enumerated()), id: \.element) { index, path in
                    let center = CGPoint(x: (CGFloat(index % cols) + 0.5) * cellW,
                                         y: top + (CGFloat(index / cols) + 0.5) * cellH)
                    let s = scale(at: center)
                    tile(path, size: icon * s, scale: s)
                        .position(center)
                        .zIndex(Double(s))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = point
                case .ended: hover = nil
                }
            }
            .animation(DS.Motion.micro, value: hover)
            .contextMenu {
                Button("添加 App…") { model.addViaPicker() }
            }
        }
        .padding(.horizontal, DS.Space.xs)
        .onAppear { refreshRunning() }
    }

    /// 2-D Gaussian falloff around the cursor, like Dock magnification but for a grid
    private func scale(at center: CGPoint) -> CGFloat {
        guard let h = hover else { return 1 }
        let dx = h.x - center.x
        let dy = h.y - center.y
        return 1 + (maxScale - 1) * exp(-(dx * dx + dy * dy) / (2 * spread * spread))
    }

    @ViewBuilder
    private func tile(_ path: String, size: CGFloat, scale s: CGFloat) -> some View {
        VStack(spacing: DS.Space.xs) {
            Image(nsImage: model.icon(path))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .offset(y: bouncing == path ? bounceDepth : 0)
            Circle()
                .fill(running.contains(path) ? DS.Colors.indicator : Color.clear)
                .frame(width: DS.Size.dot, height: DS.Size.dot)
        }
        .overlay(alignment: .bottom) {
            Text(model.name(path))
                .font(DS.Fonts.caption(.medium))
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(DS.Colors.overlay))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .strokeBorder(DS.Colors.separator, lineWidth: DS.Size.hairline))
                .offset(y: DS.Space.l + DS.Space.xs)
                .opacity(s > labelShowsAt ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap(path) }
        .contextMenu {
            Button("从刘海移除") { model.remove(path) }
            Button("添加 App…") { model.addViaPicker() }
        }
    }

    private func tap(_ path: String) {
        // Dock-style launch bounce (away from the edge, i.e. downward), then open and tuck away
        Task { @MainActor in
            withAnimation(DS.Motion.micro) { bouncing = path }
            model.open(path)
            try? await Task.sleep(for: .seconds(DS.Motion.microDuration))
            withAnimation(DS.Motion.panel) { bouncing = nil }
            try? await Task.sleep(for: .seconds(DS.Motion.panelDuration))
            withAnimation(AoomooaHover.collapseAnimation) { vm.close() }
            refreshRunning()
        }
    }

    private func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
    }
}

/// aoomooa: Reminders on the left, the app dock on the right
struct NotchWorkspaceView: View {
    /// 左边提醒事项占的宽度比例
    private let remindersShare: CGFloat = 0.44

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                NotchRemindersView()
                    .frame(width: g.size.width * remindersShare)
                Rectangle()
                    .fill(DS.Colors.separator)
                    .frame(width: DS.Size.hairline)
                    .padding(.vertical, DS.Space.m)
                NotchLauncherView()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
