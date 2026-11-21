//
//  AoomooaPrefs.swift — 设置 → aoomooa 页里所有可调项（UserDefaults，全部有默认值）
//
//  视图里用 @AppStorage(AoomooaPrefs.Key.xxx) 绑定；非视图代码读下面的静态属性，
//  每次用到时现读，所以改完立即生效、重启后保留。
//

import Foundation
import SwiftUI

enum AoomooaPrefs {
    enum Key {
        static let hoverDelay = "aoomooa.hoverDelay"
        static let collapseDelay = "aoomooa.collapseDelay"
        static let swipeSensitivity = "aoomooa.swipeSensitivity"
        static let tintStrength = "aoomooa.tintStrength"
        static let animationSpeed = "aoomooa.animationSpeed"
        static let timerMinutes = "aoomooa.timerDefaultMinutes"
        static let timerShowWhenClosed = "aoomooa.timerShowWhenClosed"
        static let weatherCity = "aoomooa.weatherCity"
    }

    enum Default {
        /// 悬停多久后展开（秒）
        static let hoverDelay: Double = 0.8
        /// 展开后鼠标移开多久再收起（秒）
        static let collapseDelay: Double = 3.0
        /// 左右滑灵敏度 0…1（0.5 ≈ 原来的 120pt）
        static let swipeSensitivity: Double = 0.5
        /// 封面取色强度 0…1
        static let tintStrength: Double = 0.55
        /// 动画速度倍率（1 = 标准，2 = 快一倍）
        static let animationSpeed: Double = 1.0
        /// 计时器默认分钟
        static let timerMinutes: Int = 25
        /// 收起时在刘海上显示倒计时
        static let timerShowWhenClosed: Bool = true
        /// 天气城市，空 = 按网络位置自动判断
        static let weatherCity: String = ""
    }

    enum Limits {
        static let hoverDelay: ClosedRange<Double> = 0.2...1.0
        static let collapseDelay: ClosedRange<Double> = 0.0...5.0
        static let swipeSensitivity: ClosedRange<Double> = 0...1
        static let tintStrength: ClosedRange<Double> = 0...1
        static let animationSpeed: ClosedRange<Double> = 0.5...2.0
        static let timerMinutes: ClosedRange<Int> = 1...60
        /// 灵敏度 0 → 需要滑 180pt，灵敏度 1 → 60pt
        static let swipeDistance: ClosedRange<Double> = 60...180
    }

    // MARK: 读取（随时现读）

    static var hoverDelay: Double { clamp(double(Key.hoverDelay, Default.hoverDelay), Limits.hoverDelay) }
    static var collapseDelay: Double { clamp(double(Key.collapseDelay, Default.collapseDelay), Limits.collapseDelay) }
    static var swipeSensitivity: Double { clamp(double(Key.swipeSensitivity, Default.swipeSensitivity), Limits.swipeSensitivity) }
    static var tintStrength: Double { clamp(double(Key.tintStrength, Default.tintStrength), Limits.tintStrength) }
    static var animationSpeed: Double { clamp(double(Key.animationSpeed, Default.animationSpeed), Limits.animationSpeed) }
    static var timerMinutes: Int {
        let v = (UserDefaults.standard.object(forKey: Key.timerMinutes) as? Int) ?? Default.timerMinutes
        return min(max(v, Limits.timerMinutes.lowerBound), Limits.timerMinutes.upperBound)
    }
    static var timerShowWhenClosed: Bool {
        (UserDefaults.standard.object(forKey: Key.timerShowWhenClosed) as? Bool) ?? Default.timerShowWhenClosed
    }

    static var weatherCity: String {
        (UserDefaults.standard.string(forKey: Key.weatherCity) ?? Default.weatherCity)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 左右滑切页需要滑过的距离（pt）
    static var tabSwipeDistance: CGFloat {
        let r = Limits.swipeDistance
        return CGFloat(r.upperBound - swipeSensitivity * (r.upperBound - r.lowerBound))
    }

    /// 恢复默认：清掉 aoomooa 页的所有设置
    static func resetAll() {
        let d = UserDefaults.standard
        for key in [Key.hoverDelay, Key.collapseDelay, Key.swipeSensitivity, Key.tintStrength,
                    Key.animationSpeed, Key.timerMinutes, Key.timerShowWhenClosed, Key.weatherCity] {
            d.removeObject(forKey: key)
        }
    }

    // MARK: helpers

    private static func double(_ key: String, _ fallback: Double) -> Double {
        (UserDefaults.standard.object(forKey: key) as? Double) ?? fallback
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
}
