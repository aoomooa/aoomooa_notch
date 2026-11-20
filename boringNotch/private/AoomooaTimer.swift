//
//  AoomooaTimer.swift — 计时器第一版
//
//  · 顶栏 ⏱ 打开计时器页：5 / 10 / 15 / 25 分钟或自定义
//  · 收起后刘海两侧显示 ⏱ 和 mm:ss（设置 → aoomooa 可关）
//  · 到点响一声，刘海显示“时间到”，可以“再来一次”
//  · 以后加番茄钟：作为新的“预设模式”放在 presetMinutes 旁边，不改这里的流程
//

import AppKit
import SwiftUI

@MainActor
final class NotchTimerModel: ObservableObject {
    static let shared = NotchTimerModel()

    enum Phase: Equatable { case idle, running, paused, finished }

    /// 第一版的快捷时长（分钟）
    static let presetMinutes = [5, 10, 15, 25]
    /// “时间到”在刘海上停留多久后自动收起（秒）
    static let finishedBannerDuration: TimeInterval = 120
    /// 到点提示音（系统自带声音）
    static let finishSound = "Hero"

    @Published private(set) var phase: Phase = .idle
    /// 本轮总时长（秒，含中途 +1 分钟）
    @Published private(set) var duration: TimeInterval = 0
    /// 上一次开始时选的分钟数（“再来一次”用）
    @Published private(set) var lastMinutes: Int = 0
    /// 自定义时长（分钟），默认取设置里的“默认时长”
    @Published var customMinutes: Int = AoomooaPrefs.timerMinutes

    private var endDate: Date?
    private var pausedRemaining: TimeInterval = 0
    private var finishTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?

    private init() {}

    var isActive: Bool { phase == .running || phase == .paused }

    /// 收起时要不要在刘海上显示
    func showsOnClosedNotch(showWhileRunning: Bool) -> Bool {
        phase == .finished || (isActive && showWhileRunning)
    }

    func remaining(at date: Date = Date()) -> TimeInterval {
        switch phase {
        case .running: return max(0, (endDate ?? date).timeIntervalSince(date))
        case .paused: return pausedRemaining
        case .idle, .finished: return 0
        }
    }

    /// 已经走过的比例 0…1
    func progress(at date: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(1 - remaining(at: date) / duration, 0), 1)
    }

    // MARK: 操作

    func start(minutes: Int) {
        let limits = AoomooaPrefs.Limits.timerMinutes
        let m = min(max(minutes, limits.lowerBound), limits.upperBound)
        lastMinutes = m
        duration = TimeInterval(m * 60)
        run(for: duration)
    }

    func pause() {
        guard phase == .running else { return }
        pausedRemaining = remaining()
        finishTask?.cancel()
        endDate = nil
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        run(for: pausedRemaining)
    }

    func togglePause() {
        phase == .running ? pause() : resume()
    }

    func addMinute() {
        switch phase {
        case .running:
            let left = remaining() + 60
            duration += 60
            run(for: left)
        case .paused:
            pausedRemaining += 60
            duration += 60
        case .idle, .finished:
            break
        }
    }

    /// 再来一次：用上一次的时长重新开始
    func again() {
        start(minutes: lastMinutes > 0 ? lastMinutes : AoomooaPrefs.timerMinutes)
    }

    /// 结束 / 完成
    func cancel() {
        finishTask?.cancel()
        bannerTask?.cancel()
        endDate = nil
        pausedRemaining = 0
        phase = .idle
    }

    // MARK: 内部

    private func run(for seconds: TimeInterval) {
        bannerTask?.cancel()
        endDate = Date().addingTimeInterval(seconds)
        phase = .running
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        guard phase == .running else { return }
        endDate = nil
        pausedRemaining = 0
        phase = .finished
        NSSound(named: NSSound.Name(Self.finishSound))?.play()
        // 下次展开直接看到“时间到”和“再来一次”
        withAnimation(DS.Motion.page) { BoringViewCoordinator.shared.currentView = .timer }
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedBannerDuration))
            guard !Task.isCancelled, self?.phase == .finished else { return }
            self?.cancel()
        }
    }

    /// mm:ss（超过一小时显示总分钟，比如 125:00）
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - 展开后的计时器页

struct NotchTimerView: View {
    @ObservedObject private var timer = NotchTimerModel.shared

    /// 时间的刷新间隔（秒）
    private static let tick: TimeInterval = 1

    var body: some View {
        Group {
            switch timer.phase {
            case .idle: picker
            case .running, .paused: running
            case .finished: finished
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(DS.Motion.micro, value: timer.phase)
    }

    // 选时长
    private var picker: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            sectionHeader("计时器", "timer")
            HStack(spacing: DS.Space.s) {
                ForEach(NotchTimerModel.presetMinutes, id: \.self) { minutes in
                    TimerPresetTile(minutes: minutes) { timer.start(minutes: minutes) }
                }
                customTile
            }
        }
        .onAppear { timer.customMinutes = AoomooaPrefs.timerMinutes }
    }

    private var customTile: some View {
        VStack(spacing: DS.Space.xs) {
            Text("自定义")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.Colors.textSecondary)
            HStack(spacing: DS.Space.xs) {
                stepButton("minus") { changeCustom(by: -1) }
                Text("\(timer.customMinutes)")
                    .font(DS.Fonts.title)
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.textPrimary)
                    .contentTransition(.numericText())
                stepButton("plus") { changeCustom(by: 1) }
            }
            AoomooaPillButton(title: "开始", icon: "play.fill", prominent: true) {
                timer.start(minutes: timer.customMinutes)
            }
        }
        .padding(DS.Space.s)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Colors.fill))
    }

    private func changeCustom(by delta: Int) {
        let limits = AoomooaPrefs.Limits.timerMinutes
        withAnimation(DS.Motion.micro) {
            timer.customMinutes = min(max(timer.customMinutes + delta, limits.lowerBound), limits.upperBound)
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.Fonts.caption(.semibold))
                .foregroundStyle(DS.Colors.textSecondary)
                .frame(width: DS.Size.stepButton, height: DS.Size.stepButton)
                .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous).fill(DS.Colors.fill))
        }
        .buttonStyle(.plain)
    }

    // 计时中 / 暂停
    private var running: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            HStack(spacing: DS.Space.l) {
                ZStack {
                    Circle()
                        .stroke(DS.Colors.separator, lineWidth: DS.Size.bar)
                    Circle()
                        .trim(from: 0, to: 1 - timer.progress(at: context.date))
                        .stroke(timer.phase == .paused ? DS.Colors.textSecondary : DS.Colors.accent,
                                style: StrokeStyle(lineWidth: DS.Size.bar, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(DS.Motion.panel, value: context.date)
                    Text(NotchTimerModel.clock(timer.remaining(at: context.date)))
                        .font(DS.Fonts.title)
                        .monospacedDigit()
                        .foregroundStyle(DS.Colors.textPrimary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .padding(.horizontal, DS.Space.s)
                }
                .frame(width: DS.Size.timerRing, height: DS.Size.timerRing)

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(timer.phase == .paused ? "已暂停" : "计时中 · \(Int(timer.duration / 60)) 分钟")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                    HStack(spacing: DS.Space.s) {
                        AoomooaPillButton(title: timer.phase == .paused ? "继续" : "暂停",
                                          icon: timer.phase == .paused ? "play.fill" : "pause.fill",
                                          prominent: true) { timer.togglePause() }
                        AoomooaPillButton(title: "+1 分钟", icon: "plus") { timer.addMinute() }
                        AoomooaPillButton(title: "结束", icon: "xmark") { timer.cancel() }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // 时间到
    private var finished: some View {
        HStack(spacing: DS.Space.l) {
            Image(systemName: "bell.fill")
                .font(DS.Fonts.title)
                .foregroundStyle(DS.Colors.accent)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("时间到")
                    .font(DS.Fonts.title)
                    .foregroundStyle(DS.Colors.accent)
                Text("\(timer.lastMinutes) 分钟计时结束了")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            Spacer(minLength: DS.Space.s)
            AoomooaPillButton(title: "再来一次", icon: "arrow.clockwise", prominent: true) { timer.again() }
            AoomooaPillButton(title: "完成", icon: "checkmark") { timer.cancel() }
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionHeader(_ text: String, _ icon: String) -> some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: icon)
            Text(text)
        }
        .font(DS.Fonts.caption(.semibold))
        .foregroundStyle(DS.Colors.textSecondary)
    }
}

/// 一个预设时长的卡片
private struct TimerPresetTile: View {
    let minutes: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs) {
                Text("\(minutes)")
                    .font(DS.Fonts.title)
                    .monospacedDigit()
                    .foregroundStyle(DS.Colors.textPrimary)
                Text("分钟")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(hovering ? DS.Colors.fillHover : DS.Colors.fill))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.micro) { hovering = h } }
    }
}

/// 刘海里通用的小按钮（强调色 = 主操作）
struct AoomooaPillButton: View {
    let title: String
    let icon: String
    var prominent: Bool = false
    let action: () -> Void
    @State private var hovering = false
    /// 主按钮悬停时稍微变暗
    private static let hoverDim: Double = 0.85

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: icon)
                Text(title)
            }
            .font(DS.Fonts.body(.medium))
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs)
            .background(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                .fill(prominent ? DS.Colors.accent : (hovering ? DS.Colors.fillHover : DS.Colors.fill)))
            .opacity(prominent && hovering ? Self.hoverDim : 1)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(DS.Motion.micro) { hovering = h } }
    }
}

// MARK: - 收起时的刘海：左边 ⏱，右边 mm:ss

struct AoomooaTimerLiveActivity: View {
    @ObservedObject private var timer = NotchTimerModel.shared
    /// 收起时刘海的高度
    let height: CGFloat
    /// 中间（硬件刘海）那段的宽度
    let middleWidth: CGFloat
    private static let tick: TimeInterval = 1

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            HStack(spacing: 0) {
                Image(systemName: icon)
                    .font(DS.Fonts.body(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: DS.Size.timerSide, height: height)
                Rectangle()
                    .fill(DS.Colors.background)
                    .frame(width: max(0, middleWidth), height: height)
                Text(timer.phase == .finished ? "时间到" : NotchTimerModel.clock(timer.remaining(at: context.date)))
                    .font(DS.Fonts.body(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: DS.Size.timerSide, height: height)
            }
        }
        .frame(height: height)
    }

    private var icon: String {
        switch timer.phase {
        case .finished: return "bell.fill"
        case .paused: return "pause.fill"
        default: return "timer"
        }
    }

    private var tint: Color {
        switch timer.phase {
        case .finished: return DS.Colors.accent
        case .paused: return DS.Colors.textSecondary
        default: return DS.Colors.textPrimary
        }
    }
}
