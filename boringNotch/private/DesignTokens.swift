//
//  DesignTokens.swift — aoomooa 设计规范（唯一来源）
//
//  所有 aoomooa 界面只从这里取：颜色 / 字号 / 圆角 / 间距 / 动画 / 控件尺寸。
//  新增控件只能从这些档位里选，不要在视图里写数字。
//
//  · 强调色唯一：暗色 #FF453A，亮色 #FF3B30；绿色/橙色只表示成功/警告
//  · 字号三档：11 辅助 · 13 正文 · 20 大标题（圆体只用于 20）
//  · 圆角三档：6 小按钮/标签 · 10 卡片/列表项 · 16 面板/容器（刘海外形不算）
//  · 间距四档：4 · 8 · 12 · 16
//  · 动画三档：微交互 0.18s easeOut · 面板 0.28s spring(0.85) · 页面 0.35s spring
//

import AppKit
import SwiftUI

enum DS {

    // MARK: - 颜色

    enum Colors {
        /// 唯一强调色（随系统明暗自动切换）
        static var accentNS: NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(srgbRed: 1.0, green: 69 / 255.0, blue: 58 / 255.0, alpha: 1)   // #FF453A
                    : NSColor(srgbRed: 1.0, green: 59 / 255.0, blue: 48 / 255.0, alpha: 1)   // #FF3B30
            }
        }
        static var accent: Color { Color(nsColor: accentNS) }
        /// 强调色的浅底（拖拽高亮、选中底色）
        static var accentSoft: Color { accent.opacity(0.2) }

        /// 只用于“成功”语义
        static let success = Color(nsColor: .systemGreen)
        /// 只用于“警告”语义
        static let warning = Color(nsColor: .systemOrange)

        // 刘海永远是黑底，文字和填充用白色的固定几档
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.55)
        static let textTertiary = Color.white.opacity(0.3)
        /// 卡片 / 输入框 / 按钮底
        static let fill = Color.white.opacity(0.08)
        /// 悬停 / 选中的底
        static let fillHover = Color.white.opacity(0.16)
        /// 分隔线、进度条轨道、描边
        static let separator = Color.white.opacity(0.12)
        /// 进度条、运行指示点
        static let indicator = Color.white.opacity(0.75)
        /// 悬浮标签的底
        static let overlay = Color.black.opacity(0.75)
        static let background = Color.black
    }

    // MARK: - 字号（三档）

    enum Fonts {
        static let captionSize: CGFloat = 11
        static let bodySize: CGFloat = 13
        static let titleSize: CGFloat = 20

        /// 11pt：辅助说明 / 小标签
        static let caption = Font.system(size: captionSize)
        static func caption(_ weight: Font.Weight) -> Font { .system(size: captionSize, weight: weight) }
        /// 13pt：正文 / 设置项 / 按钮
        static let body = Font.system(size: bodySize)
        static func body(_ weight: Font.Weight) -> Font { .system(size: bodySize, weight: weight) }
        /// 20pt 圆体：日历月份 / 大标题 / 主按钮图标
        static let title = Font.system(size: titleSize, weight: .bold, design: .rounded)
    }

    // MARK: - 圆角（三档）

    enum Radius {
        /// 小按钮 / 小标签
        static let small: CGFloat = 6
        /// 卡片 / 列表项
        static let card: CGFloat = 10
        /// 面板 / 容器
        static let panel: CGFloat = 16
    }

    // MARK: - 间距（四档）

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    // MARK: - 动画（三档，速度跟随 设置 → aoomooa → 动画速度）

    enum Motion {
        static let microBase: Double = 0.18
        static let panelBase: Double = 0.28
        static let pageBase: Double = 0.35
        static let damping: Double = 0.85

        private static var speed: Double { AoomooaPrefs.animationSpeed }

        static var microDuration: Double { microBase / speed }
        static var panelDuration: Double { panelBase / speed }
        static var pageDuration: Double { pageBase / speed }

        /// 微交互：悬停、按下、勾选、小元素出现
        static var micro: Animation { .easeOut(duration: microDuration) }
        /// 面板展开 / 收起
        static var panel: Animation { .spring(response: panelDuration, dampingFraction: damping) }
        /// 页面转场（切换标签、左右滑页）
        static var page: Animation { .spring(response: pageDuration, dampingFraction: damping) }

        /// 不要动画，立即生效
        static var instant: Transaction {
            var t = Transaction()
            t.disablesAnimations = true
            return t
        }
    }

    // MARK: - 控件尺寸（不是规范档位，只是集中起来，别在视图里写）

    enum Size {
        /// 顶栏圆形按钮
        static let control: CGFloat = 30
        /// 顶栏标签高度
        static let tab: CGFloat = 26
        /// 媒体控制按钮的点击区
        static let mediaButton: CGFloat = 30
        /// 封面
        static let artwork: CGFloat = 54
        /// 启动台图标（最大静止尺寸 / 最小尺寸）
        static let appIcon: CGFloat = 38
        static let appIconMin: CGFloat = 20
        /// 网站图标
        static let favicon: CGFloat = 24
        /// 日历条：每天的宽度、整条高度
        static let dayWidth: CGFloat = 30
        static let dayStripHeight: CGFloat = 46
        /// 小圆点（日程、运行中）
        static let dot: CGFloat = 4
        /// 状态灯
        static let statusDot: CGFloat = 6
        /// 进度条粗细（普通 / 拖动中）
        static let bar: CGFloat = 4
        static let barActive: CGFloat = 6
        /// 进度条的点击区高度
        static let barHitArea: CGFloat = 12
        /// 分隔线 / 日程色条宽度
        static let hairline: CGFloat = 1
        static let eventBar: CGFloat = 3
        /// 列表行里图标的高度
        static let rowIcon: CGFloat = 14
    }
}
