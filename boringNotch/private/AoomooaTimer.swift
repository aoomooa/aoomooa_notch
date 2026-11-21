//
//  AoomooaTimer.swift — 计时器第一版
//
//  · 顶栏 ⏱ 或双指左右滑到「天气 + 计时器」页：5 / 10 / 15 / 25 分钟，或用滚轮自定义 1–60 分钟
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

// MARK: - 展开后的页面（页面 3：时间 — 左边日历与天气 · 右边紧凑计时器）

struct NotchTimerView: View {
    @ObservedObject private var timer = NotchTimerModel.shared

    /// 左边日历+天气占的宽度比例
    private static let calendarShare: CGFloat = 0.50
    /// 时间的刷新间隔（秒）
    private static let tick: TimeInterval = 1

    var body: some View {
        GeometryReader { g in
            // 两个模块：极淡的底 + 面板圆角，中间只留间距，不画线（去掉多余的模块说明文字）
            HStack(alignment: .top, spacing: DS.Space.l) {
                NotchRemindersView()
                    .aoomooaModule()
                    .frame(width: (g.size.width - DS.Space.l) * Self.calendarShare)

                Group {
                    switch timer.phase {
                    case .idle: picker
                    case .running, .paused: running
                    case .finished: finished
                    }
                }
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .aoomooaModule()
                .frame(maxWidth: .infinity)
            }
        }
        .animation(DS.Motion.micro, value: timer.phase)
    }

    // 选时长：左边 2×2 预设方格 + 右边自定义分钟滚轮（在 50% 宽度里舒展好点）
    private var picker: some View {
        HStack(spacing: DS.Space.s) {
            VStack(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    TimerPresetTile(minutes: NotchTimerModel.presetMinutes[0]) { timer.start(minutes: NotchTimerModel.presetMinutes[0]) }
                    TimerPresetTile(minutes: NotchTimerModel.presetMinutes[1]) { timer.start(minutes: NotchTimerModel.presetMinutes[1]) }
                }
                HStack(spacing: DS.Space.s) {
                    TimerPresetTile(minutes: NotchTimerModel.presetMinutes[2]) { timer.start(minutes: NotchTimerModel.presetMinutes[2]) }
                    TimerPresetTile(minutes: NotchTimerModel.presetMinutes[3]) { timer.start(minutes: NotchTimerModel.presetMinutes[3]) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            customTile
        }
        .onAppear { timer.customMinutes = AoomooaPrefs.timerMinutes }
    }

    private var customTile: some View {
        VStack(spacing: DS.Space.xs) {
            AoomooaMinuteWheel(value: $timer.customMinutes,
                               range: AoomooaPrefs.Limits.timerMinutes,
                               suffix: "分钟")
                .frame(maxHeight: .infinity)
            AoomooaPillButton(title: "开始", icon: "play.fill", prominent: true) {
                timer.start(minutes: timer.customMinutes)
            }
        }
        .padding(DS.Space.s)
        .frame(width: DS.Size.wheelTile)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(DS.Colors.fill))
    }

    // 计时中 / 暂停（左圆环，右上下两排按钮，50% 宽度不挤）
    private var running: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            HStack(spacing: DS.Space.m) {
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
                        .lineLimit(1)
                    AoomooaPillButton(title: timer.phase == .paused ? "继续" : "暂停",
                                      icon: timer.phase == .paused ? "play.fill" : "pause.fill",
                                      prominent: true) { timer.togglePause() }
                    HStack(spacing: DS.Space.s) {
                        AoomooaPillButton(title: "+1 分", icon: "plus") { timer.addMinute() }
                        AoomooaPillButton(title: "结束", icon: "xmark") { timer.cancel() }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // 时间到
    private var finished: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "bell.fill")
                .font(DS.Fonts.title)
                .foregroundStyle(DS.Colors.accent)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("时间到")
                    .font(DS.Fonts.title)
                    .foregroundStyle(DS.Colors.accent)
                    .lineLimit(1)
                Text("\(timer.lastMinutes) 分钟计时结束了")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: DS.Space.xs)
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                AoomooaPillButton(title: "再来一次", icon: "arrow.clockwise", prominent: true) { timer.again() }
                AoomooaPillButton(title: "完成", icon: "checkmark") { timer.cancel() }
            }
        }
    }
}

/// 一个预设时长的卡片
private struct TimerPresetTile: View {
    let minutes: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
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
        .buttonStyle(AoomooaPressStyle())
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
        .buttonStyle(AoomooaPressStyle())
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
