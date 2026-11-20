//
//  AoomooaWheel.swift — 上下滚动选数字的滚轮（类似 iOS 的 Picker 滚轮）
//
//  · 触控板：数字跟着手指走，松手后带惯性，最后吸附到最近的一格
//  · 鼠标滚轮：一格一格跳；鼠标按住上下拖也行；点上下两行直接选中
//  · 每过一格轻触反馈（设置里开了触感反馈时）
//

import AppKit
import Defaults
import SwiftUI

struct AoomooaMinuteWheel: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// 选中行右边的小字，比如“分钟”
    var suffix: String = ""

    private static let rowHeight = DS.Size.wheelRow
    /// 离中间每远一行：变淡、变小、往后倒
    private static let fadePerRow: Double = 0.4
    private static let shrinkPerRow: CGFloat = 0.14
    private static let tiltPerRow: Double = 22
    /// 超出两端时的阻力（越小越难拉），最多拉出这么多行
    private static let rubberBand: CGFloat = 0.3
    private static let maxOvershoot: CGFloat = 0.8
    /// 上下两端渐隐的比例
    private static let edgeFade: CGFloat = 0.3
    /// 松手后多久没有惯性就吸附（秒）
    private static let settleDelay: Double = 0.06
    /// 按下后移动不到这么多算点按
    private static let clickSlop: CGFloat = 3

    /// 小数“行号”：0 = range 的第一个数
    @State private var position: CGFloat = 0
    /// 未加阻力的原始位置（手指 / 惯性累计）
    @State private var raw: CGFloat = 0
    @State private var dragStartRaw: CGFloat = 0
    @State private var settleTask: Task<Void, Never>?

    private var count: Int { range.count }
    private var maxIndex: CGFloat { CGFloat(count - 1) }

    var body: some View {
        GeometryReader { g in
            let mid = g.size.height / 2
            let reach = Int((mid / Self.rowHeight).rounded(.up)) + 1
            let first = max(0, Int(position.rounded()) - reach)
            let last = min(count - 1, Int(position.rounded()) + reach)

            ZStack {
                // 选中行的底
                RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous)
                    .fill(DS.Colors.fill)
                    .frame(height: Self.rowHeight)
                    .position(x: g.size.width / 2, y: mid)

                if first <= last {
                    ForEach(first...last, id: \.self) { i in
                        let d = CGFloat(i) - position
                        let distance = min(abs(d), 3)
                        Text(verbatim: "\(range.lowerBound + i)")
                            .font(DS.Fonts.title)
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.textPrimary)
                            .scaleEffect(1 - Self.shrinkPerRow * distance)
                            .opacity(max(0, 1 - Self.fadePerRow * Double(distance)))
                            .rotation3DEffect(.degrees(-Self.tiltPerRow * Double(d)), axis: (x: 1, y: 0, z: 0))
                            .position(x: g.size.width / 2, y: mid + d * Self.rowHeight)
                    }
                }

                if !suffix.isEmpty {
                    Text(suffix)
                        .font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, DS.Space.s)
                        .position(x: g.size.width / 2, y: mid)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: Self.edgeFade),
                                       .init(color: .black, location: 1 - Self.edgeFade),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                WheelInput(
                    onScroll: { event in handleScroll(event) },
                    onDrag: { phase, dy, y, height in handleDrag(phase, dy: dy, y: y, height: height) }
                )
            )
        }
        .onDisappear {
            AoomooaGestureGate.verticalScrollerHovered = false
            settleTask?.cancel()
        }
        .onAppear { jump(to: index(of: value)) }
        .onChange(of: value) { _, newValue in
            // 外部改了数值（比如设置里改了默认时长）
            let target = index(of: newValue)
            if Int(position.rounded()) != target { animate(to: target) }
        }
    }

    // MARK: 触控板 / 鼠标滚轮

    private func handleScroll(_ event: NSEvent) {
        let isWheelMouse = !event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty
        if isWheelMouse {
            // 鼠标滚轮：一格一格
            guard event.scrollingDeltaY != 0 else { return }
            let step: CGFloat = event.scrollingDeltaY > 0 ? -1 : 1
            animate(to: Int((position + step).rounded()))
            return
        }

        if event.phase == .began || event.phase == .mayBegin {
            settleTask?.cancel()
            raw = position
        }
        if event.momentumPhase == .began {
            settleTask?.cancel()
        }

        move(by: -event.scrollingDeltaY / Self.rowHeight)

        if event.momentumPhase == .ended {
            settle()
        } else if event.phase == .ended || event.phase == .cancelled {
            // 手指离开：稍等一下，如果没有惯性跟上就吸附
            settleTask?.cancel()
            settleTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.settleDelay))
                guard !Task.isCancelled else { return }
                settle()
            }
        }
    }

    // MARK: 鼠标拖动 / 点按

    private func handleDrag(_ phase: WheelInput.Phase, dy: CGFloat, y: CGFloat, height: CGFloat) {
        switch phase {
        case .began:
            settleTask?.cancel()
            dragStartRaw = position
            raw = position
        case .changed:
            raw = dragStartRaw - dy / Self.rowHeight
            apply()
        case .ended:
            if abs(dy) < Self.clickSlop {
                // 点按：点上面一行 / 下面一行就选它
                let tapped = Int((position + (y - height / 2) / Self.rowHeight).rounded())
                animate(to: tapped)
            } else {
                settle()
            }
        }
    }

    // MARK: 位置

    private func move(by rows: CGFloat) {
        raw += rows
        apply()
    }

    /// 用原始位置算出显示位置（两端加阻力），并更新选中的数
    private func apply() {
        var p = raw
        if p < 0 { p = -min(-p * Self.rubberBand, Self.maxOvershoot) }
        if p > maxIndex { p = maxIndex + min((p - maxIndex) * Self.rubberBand, Self.maxOvershoot) }
        position = p
        select(Int(p.rounded()))
    }

    /// 吸附到最近的一格
    private func settle() {
        settleTask?.cancel()
        animate(to: Int(position.rounded()))
    }

    private func animate(to index: Int) {
        let target = clamp(index)
        raw = CGFloat(target)
        withAnimation(DS.Motion.panel) { position = CGFloat(target) }
        select(target)
    }

    private func jump(to index: Int) {
        let target = clamp(index)
        raw = CGFloat(target)
        position = CGFloat(target)
    }

    private func select(_ index: Int) {
        let newValue = range.lowerBound + clamp(index)
        guard newValue != value else { return }
        value = newValue
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func clamp(_ i: Int) -> Int { min(max(i, 0), count - 1) }
    private func index(of v: Int) -> Int { clamp(v - range.lowerBound) }
}

/// 透明的 AppKit 视图：接住滚动、拖动和点按（SwiftUI 在 macOS 上拿不到原始滚动事件）
private struct WheelInput: NSViewRepresentable {
    enum Phase { case began, changed, ended }

    var onScroll: (NSEvent) -> Void
    var onDrag: (Phase, _ dy: CGFloat, _ y: CGFloat, _ height: CGFloat) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.onScroll = onScroll
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.onScroll = onScroll
        view.onDrag = onDrag
    }

    final class InputView: NSView {
        var onScroll: ((NSEvent) -> Void)?
        var onDrag: ((Phase, CGFloat, CGFloat, CGFloat) -> Void)?
        private var downY: CGFloat = 0

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // 鼠标在滚轮上时告诉外层：上下滑是在调数字，不是要收起刘海
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            AoomooaGestureGate.verticalScrollerHovered = true
        }

        override func mouseExited(with event: NSEvent) {
            AoomooaGestureGate.verticalScrollerHovered = false
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { AoomooaGestureGate.verticalScrollerHovered = false }
        }

        override func scrollWheel(with event: NSEvent) {
            onScroll?(event)   // 不往上传，免得外层把它当成“上滑收起”
        }

        override func mouseDown(with event: NSEvent) {
            let y = convert(event.locationInWindow, from: nil).y
            downY = y
            onDrag?(.began, 0, y, bounds.height)
        }

        override func mouseDragged(with event: NSEvent) {
            let y = convert(event.locationInWindow, from: nil).y
            onDrag?(.changed, y - downY, y, bounds.height)
        }

        override func mouseUp(with event: NSEvent) {
            let y = convert(event.locationInWindow, from: nil).y
            onDrag?(.ended, y - downY, y, bounds.height)
        }
    }
}
