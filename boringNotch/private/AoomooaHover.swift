//
//  AoomooaHover.swift — aoomooa: two-stage hover tuning
//

import SwiftUI

enum AoomooaHover {
    /// STAGE1_DELAY_MS — how long stage 1 stays before full expand (1.5–2.0 s)
    static let stage1Delay: TimeInterval = 1.8
    /// Expand: smooth, no bounce, Dock-like (seconds)
    static let expandTransition: Double = 0.26
    /// Collapse: quick smooth slide back (seconds). Set to 0 for an instant collapse.
    static let collapseTransition: Double = 0.16
    /// EXIT_GRACE_MS — confirm the mouse really left before collapsing (filters layout jitter)
    static let exitGraceMs: Int = 80
    /// Two-finger swipe distance to hide / bring back the live activity (up / down)
    static let swipeDistance: CGFloat = 60
    /// Two-finger swipe distance to change page (left / right) — bigger = less sensitive
    static let tabSwipeDistance: CGFloat = 120
    /// After a page change, ignore further swipes for this long (seconds)
    static let tabSwipeCooldown: Double = 0.6
    /// How far the page follows your fingers before it switches (points)
    static let tabSwipeFollow: CGFloat = 18

    static var expandAnimation: Animation { .smooth(duration: expandTransition) }
    static var collapseAnimation: Animation? {
        collapseTransition > 0 ? .smooth(duration: collapseTransition) : nil
    }

    /// A transaction that applies changes instantly, with no animation
    static var instant: Transaction {
        var t = Transaction()
        t.disablesAnimations = true
        return t
    }
}
