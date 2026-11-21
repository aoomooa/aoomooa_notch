//
//  AoomooaStyle.swift — aoomooa: 外观（数值全部来自 DesignTokens / AoomooaPrefs）
//

import SwiftUI

enum AoomooaStyle {
    /// 双指左右滑能到的页面，顺序和顶栏图标从左到右一致：首页 · 控制台 · 时间（日历+天气+计时器）
    static let swipeOrder: [NotchViews] = [.home, .apps, .timer]

    /// 展开后背景取封面颜色的强度（设置里 0–100%）
    static var tintStrength: Double { AoomooaPrefs.tintStrength }

    /// Tab change: new page drops in from above, old page fades out
    static var tabTransition: AnyTransition {
        .asymmetric(insertion: .offset(y: -DS.Space.m).combined(with: .opacity),
                    removal: .opacity)
    }

    /// 左右滑页时新页面从滑动方向进入的距离
    static let swipeTransitionOffset: CGFloat = 70

    /// 悬停流光：尾部强调色 → 亮白色头部（只用唯一强调色）
    static var streakColors: [Color] {
        [DS.Colors.accent.opacity(0.5), DS.Colors.accent, DS.Colors.textPrimary]
    }
    /// 流光外发光
    static let streakGlowBlur: CGFloat = 3
    static let streakGlowOpacity: Double = 0.7
    /// Line thickness
    static let streakHeight: CGFloat = 2
    /// Distance outside the notch edge
    static let streakGap: CGFloat = 1.5
}

/// Path that hugs the visible island: starts in the top-left ear, runs down the left side,
/// round the bottom corners and up the right side to the top-right ear.
/// It mirrors NotchShape's geometry exactly, pushed outward by `outset`.
struct AoomooaNotchOutline: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// How far the visible side edge sits inside the view's frame
    var sideInset: CGFloat
    /// Push the line this far outside the edge so it sits right on the rim
    var outset: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + sideInset - outset
        let right = rect.maxX - sideInset + outset
        let bottom = rect.maxY + outset
        let r = min(bottomRadius + outset, (right - left) / 2, rect.height)
        let ear = max(0, sideInset - outset)

        var p = Path()
        p.move(to: CGPoint(x: left - ear, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.minY + min(topRadius, rect.height / 2)),
                       control: CGPoint(x: left, y: rect.minY))
        p.addLine(to: CGPoint(x: left, y: bottom - r))
        p.addQuadCurve(to: CGPoint(x: left + r, y: bottom),
                       control: CGPoint(x: left, y: bottom))
        p.addLine(to: CGPoint(x: right - r, y: bottom))
        p.addQuadCurve(to: CGPoint(x: right, y: bottom - r),
                       control: CGPoint(x: right, y: bottom))
        p.addLine(to: CGPoint(x: right, y: rect.minY + min(topRadius, rect.height / 2)))
        p.addQuadCurve(to: CGPoint(x: right + ear, y: rect.minY),
                       control: CGPoint(x: right, y: rect.minY))
        return p
    }
}

/// The line that travels around the island while hovering (progress 0…1)
struct AoomooaOutlineStreak: View {
    var progress: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// Width of the closed notch when nothing extra is shown (hardware notch + 4 pt)
    var hardwareWidth: CGFloat

    var body: some View {
        GeometryReader { g in
            // When the island is just the hardware notch, the camera cut-out (2 pt in from our frame)
            // is the visible edge. When music widens it, our drawn body (topRadius in) is the edge.
            let widened = g.size.width > hardwareWidth + 1
            let shape = AoomooaNotchOutline(topRadius: topRadius,
                                            bottomRadius: bottomRadius,
                                            sideInset: widened ? topRadius : 2,
                                            outset: AoomooaStyle.streakGap)
            let gradient = LinearGradient(colors: AoomooaStyle.streakColors,
                                          startPoint: .leading, endPoint: .trailing)
            ZStack {
                shape.trim(from: 0, to: progress)
                    .stroke(gradient, style: StrokeStyle(lineWidth: AoomooaStyle.streakHeight * 2,
                                                         lineCap: .round, lineJoin: .round))
                    .blur(radius: AoomooaStyle.streakGlowBlur)
                    .opacity(AoomooaStyle.streakGlowOpacity)
                shape.trim(from: 0, to: progress)
                    .stroke(gradient, style: StrokeStyle(lineWidth: AoomooaStyle.streakHeight,
                                                         lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Set while the mouse is over something that scrolls sideways (so a swipe scrolls it instead of changing page)
@MainActor
enum AoomooaGestureGate {
    static var horizontalScrollerHovered = false
    /// 鼠标在上下滚动的控件上（比如分钟滚轮）：上滑不收起刘海
    static var verticalScrollerHovered = false
}

// MARK: - 功能模块：极淡的底 + 面板圆角，代替分割线

extension View {
    /// 把一块内容包成一个功能模块（模块之间用 DS.Space.l 隔开，不画线）
    func aoomooaModule(padding: CGFloat = DS.Space.m) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(DS.Colors.module))
    }

    /// 图标的轻阴影
    func aoomooaIconShadow() -> some View {
        shadow(color: DS.Shadow.iconColor, radius: DS.Shadow.iconRadius, x: 0, y: DS.Shadow.iconY)
    }
}

/// 系统图标的圆角形状
struct AoomooaSquircle: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: min(rect.width, rect.height) * DS.Radius.iconRatio, style: .continuous)
            .path(in: rect)
    }
}

/// 按下时轻微缩小（原生按钮那种反馈），没有弹跳
struct AoomooaPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? DS.Motion.pressScale : 1)
            .animation(DS.Motion.micro, value: configuration.isPressed)
    }
}

/// 启动器式图标格子：图标 + 名字；悬停时底色轻微变亮，按下轻微缩小
struct AoomooaIconTile<Icon: View>: View {
    let title: String
    let iconSize: CGFloat
    let action: () -> Void
    let icon: () -> Icon
    @State private var hovering = false

    init(title: String, iconSize: CGFloat, action: @escaping () -> Void,
         @ViewBuilder icon: @escaping () -> Icon) {
        self.title = title
        self.iconSize = iconSize
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: DS.Space.xs) {
                icon()
                    .frame(width: iconSize, height: iconSize)
                Text(title)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(hovering ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
            }
            .padding(.vertical, DS.Space.xs)
            .padding(.horizontal, DS.Space.xs)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(hovering ? DS.Colors.fill : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(AoomooaPressStyle())
        .onHover { h in withAnimation(DS.Motion.micro) { hovering = h } }
        .help(title)
    }
}

/// 图标网格的排版：在给定的宽高里选列数，让图标尽量大又不挤
struct AoomooaIconGrid {
    let columns: Int
    let iconSize: CGFloat

    /// 每个格子除图标外占的高度：上下内边距 + 图标和名字的间距 + 名字一行
    static var chromeHeight: CGFloat { DS.Space.xs * 3 + DS.Fonts.captionLineHeight }
    static var chromeWidth: CGFloat { DS.Space.xs * 2 }

    init(count: Int, size: CGSize, spacing: CGFloat = DS.Space.s,
         minColumns: Int = 2, maxColumns: Int = 8) {
        let n = max(count, 1)
        var best = (columns: minColumns, icon: CGFloat(0))
        for c in minColumns...max(minColumns, min(maxColumns, n)) {
            let rows = Int((Double(n) / Double(c)).rounded(.up))
            let cellW = (size.width - spacing * CGFloat(c - 1)) / CGFloat(c)
            let cellH = (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
            let icon = min(DS.Size.appIcon, cellW - Self.chromeWidth, cellH - Self.chromeHeight)
            // 一样大时选列数少的（更舒展）
            if icon > best.icon + 0.5 { best = (c, icon) }
        }
        columns = best.columns
        iconSize = max(DS.Size.appIconMin, floor(best.icon))
    }
}

