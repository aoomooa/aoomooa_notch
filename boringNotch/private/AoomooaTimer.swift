//
//  AoomooaTimer.swift — 计时器
//
//  · 顶栏 ⏱ 或双指左右滑到「日历 + 计时器」页：5 / 10 / 15 / 25 分钟，或用滚轮自定义 1–60 分钟
//  · 收起后刘海两侧显示 ⏱ 和 mm:ss（设置 → 模块 → 计时器 可关）
//  · 到点后收起态刘海闪烁“🔔 时间到”并播放苹果原生铃声；鼠标移到刘海屏等待展开即刻结束并复位，零点击
//

import AppKit
import AVFoundation
import Defaults
import SwiftUI

enum TimerAlarmTone: String, CaseIterable, Identifiable {
    case crystals
    case bulletin
    case beacon
    case bellTower
    case presto
    case daybreak

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crystals:  return "水晶（默认）"
        case .bulletin:  return "简报双音"
        case .beacon:    return "信标"
        case .bellTower: return "钟楼"
        case .presto:    return "急板"
        case .daybreak:  return "破晓（柔和）"
        }
    }

    var filePath: String {
        switch self {
        case .crystals:
            return "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Crystals.m4r"
        case .bulletin:
            return "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Bulletin.m4r"
        case .beacon:
            return "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Beacon.m4r"
        case .bellTower:
            return "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Bell Tower.m4r"
        case .presto:
            return "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Presto.m4r"
        case .daybreak:
            return "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones/Daybreak-EncoreInfinitum.m4r"
        }
    }

    static var current: TimerAlarmTone {
        TimerAlarmTone(rawValue: AoomooaPrefs.timerTone) ?? .crystals
    }
}

@MainActor
final class NotchTimerModel: ObservableObject {
    static let shared = NotchTimerModel()

    enum Phase: Equatable { case idle, running, paused, finished }

    /// 快捷时长（分钟）
    static let presetMinutes = [5, 10, 15, 25]
    /// 到点闹钟与闪烁持续时长（秒）；超时未展开刘海也自动结束复位
    static let finishedBannerDuration: TimeInterval = 12
    /// 设置页试听时长（秒）
    static let previewDuration: TimeInterval = 3.6

    @Published private(set) var phase: Phase = .idle
    /// 是否正在响铃/闪烁中（展开刘海即停）
    @Published private(set) var isRinging: Bool = false
    /// 本轮总时长（秒，含中途 +1 分钟）
    @Published private(set) var duration: TimeInterval = 0
    /// 上一次开始时选的分钟数
    @Published private(set) var lastMinutes: Int = 0
    /// 自定义时长（分钟），默认取设置里的“默认时长”
    @Published var customMinutes: Int = AoomooaPrefs.timerMinutes

    private var endDate: Date?
    private var pausedRemaining: TimeInterval = 0
    private var finishTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var alarmTask: Task<Void, Never>?
    private var alarmPlayer: AVAudioPlayer?

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

    /// 结束 / 复位到初始状态
    func cancel() {
        stopAlarm()
        finishTask?.cancel()
        bannerTask?.cancel()
        endDate = nil
        pausedRemaining = 0
        phase = .idle
    }

    /// 用户把鼠标放在刘海屏并等待刘海展开时调用：若处于到点提示态，立即结束闹钟并复位（零点击）
    func acknowledgeOnExpand() {
        stopAlarm()
        if phase == .finished {
            cancel()
        }
    }

    /// 停止闹钟响铃
    func stopAlarm() {
        alarmTask?.cancel()
        alarmTask = nil
        alarmPlayer?.stop()
        alarmPlayer = nil
        if isRinging { isRinging = false }
    }

    /// 设置页“试听闹钟”按钮（正在试听时再点即停）
    func previewAlarm(forcePlay: Bool = false) {
        if !forcePlay, alarmPlayer?.isPlaying == true {
            stopAlarm()
            return
        }
        stopAlarm()
        isRinging = true
        playToneLoop(duration: Self.previewDuration)
    }

    // MARK: 内部

    private func run(for seconds: TimeInterval) {
        stopAlarm()
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
        startAlarm()
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.finishedBannerDuration))
            guard !Task.isCancelled, self?.phase == .finished else { return }
            self?.cancel()
        }
    }

    private func startAlarm() {
        stopAlarm()
        isRinging = true
        playToneLoop(duration: Self.finishedBannerDuration)
    }

    private func playToneLoop(duration: TimeInterval) {
        if let player = makeAudioPlayer() {
            player.volume = 1.0
            player.numberOfLoops = -1
            player.prepareToPlay()
            player.play()
            alarmPlayer = player
        } else {
            NSSound.beep()
        }
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        alarmTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.stopAlarm()
        }
    }

    private func makeAudioPlayer() -> AVAudioPlayer? {
        let candidates = [
            TimerAlarmTone.current.filePath,
            TimerAlarmTone.crystals.filePath,
            TimerAlarmTone.bulletin.filePath,
            "/System/Library/Sounds/Glass.aiff"
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isReadableFile(atPath: path),
               let player = try? AVAudioPlayer(contentsOf: url) {
                return player
            }
        }
        return nil
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

    // 时间到（仅当倒计时归零瞬间刘海恰好处在展开态时短暂闪烁提示，无需任何点击即自动复位）
    private var finished: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "bell.fill")
                .font(DS.Fonts.title)
                .foregroundStyle(DS.Colors.accent)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("时间到")
                    .font(DS.Fonts.title)
                    .foregroundStyle(DS.Colors.accent)
                    .lineLimit(1)
                Text("\(timer.lastMinutes) 分钟计时已结束")
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled, timer.phase == .finished else { return }
            timer.cancel()
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

// MARK: - 收起态刘海计时器左右翼组件（支持与视频封面/小波浪及 AI 状态灯同心共存）

/// 左耳外侧：计时器图标（⏱ / ⏸ / 到点时闪烁摇摆的 🔔）
struct AoomooaTimerWingIcon: View {
    @ObservedObject private var timer = NotchTimerModel.shared
    @State private var bellPulse = false

    private var isAlerting: Bool { timer.phase == .finished }

    var body: some View {
        Image(systemName: icon)
            .font(DS.Fonts.body(.semibold))
            .foregroundStyle(tint)
            .scaleEffect(isAlerting ? (bellPulse ? 1.22 : 0.94) : 1.0)
            .rotationEffect(.degrees(isAlerting ? (bellPulse ? 16 : -16) : 0))
            .opacity(isAlerting && bellPulse ? 0.18 : 1.0)
            .onAppear { updateAnimation(isAlerting) }
            .onChange(of: isAlerting) { _, alerting in updateAnimation(alerting) }
    }

    private func updateAnimation(_ alerting: Bool) {
        withTransaction(DS.Motion.instant) { bellPulse = false }
        guard alerting else { return }
        DispatchQueue.main.async {
            guard isAlerting else { return }
            withAnimation(.easeInOut(duration: 0.36).repeatForever(autoreverses: true)) {
                bellPulse = true
            }
        }
    }

    private var icon: String {
        switch timer.phase {
        case .finished: return "bell.fill"
        case .paused:   return "pause.fill"
        default:        return "timer"
        }
    }

    private var tint: Color {
        switch timer.phase {
        case .finished: return DS.Colors.accent
        case .paused:   return DS.Colors.textSecondary
        default:        return DS.Colors.textPrimary
        }
    }
}

/// 右耳外侧：倒计时读秒（mm:ss / 到点时闪烁的“时间到”）
struct AoomooaTimerWingLabel: View {
    @ObservedObject private var timer = NotchTimerModel.shared
    private static let tick: TimeInterval = 1
    @State private var bellPulse = false

    private var isAlerting: Bool { timer.phase == .finished }

    var body: some View {
        Group {
            if isAlerting {
                Text("时间到")
                    .font(DS.Fonts.body(.semibold))
                    .foregroundStyle(DS.Colors.accent)
                    .opacity(bellPulse ? 0.18 : 1.0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            } else {
                TimelineView(.periodic(from: .now, by: Self.tick)) { context in
                    Text(NotchTimerModel.clock(timer.remaining(at: context.date)))
                        .font(DS.Fonts.body(.semibold).monospacedDigit())
                        .foregroundStyle(timer.phase == .paused ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }
            }
        }
        .onAppear { updateAnimation(isAlerting) }
        .onChange(of: isAlerting) { _, alerting in updateAnimation(alerting) }
    }

    private func updateAnimation(_ alerting: Bool) {
        withTransaction(DS.Motion.instant) { bellPulse = false }
        guard alerting else { return }
        DispatchQueue.main.async {
            guard isAlerting else { return }
            withAnimation(.easeInOut(duration: 0.36).repeatForever(autoreverses: true)) {
                bellPulse = true
            }
        }
    }
}
