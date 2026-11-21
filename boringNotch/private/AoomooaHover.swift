//
//  AoomooaHover.swift — aoomooa: 悬停与手势参数
//
//  时长类数值来自 设置 → aoomooa（AoomooaPrefs），动画曲线来自 DesignTokens（DS.Motion）。
//  这里只留手势判定用的常量。
//

import SwiftUI

enum AoomooaHover {
    /// 悬停多久后从第一阶段展开（设置里 0.2–1.0 秒）
    static var stage1Delay: TimeInterval { AoomooaPrefs.hoverDelay }
    /// 展开后鼠标移开多久再自动收起（设置里 0.0–5.0 秒，默认 3 秒）
    static var collapseDelay: TimeInterval { AoomooaPrefs.collapseDelay }
    /// 收起态悬停离开时过滤布局抖动（毫秒）
    static let exitGraceMs: Int = 80
    /// 双指上/下滑隐藏/恢复音乐实时活动需要的距离
    static let swipeDistance: CGFloat = 60
    /// 双指左/右滑切页需要的距离（设置里的“左右滑灵敏度”）
    static var tabSwipeDistance: CGFloat { AoomooaPrefs.tabSwipeDistance }
    /// 切页后这段时间内不再响应（秒）
    static let tabSwipeCooldown: Double = 0.6
    /// 切页前页面跟手移动的最大距离
    static let tabSwipeFollow: CGFloat = 18
    /// 第一页/最后一页继续滑时只拉伸这么多（橡皮筋）
    static let rubberBand: CGFloat = 0.4

    /// 面板展开 / 收起都用面板档动画
    static var expandAnimation: Animation { DS.Motion.panel }
    static var collapseAnimation: Animation? { DS.Motion.panel }

    /// 立即生效、不带动画
    static var instant: Transaction { DS.Motion.instant }
}
