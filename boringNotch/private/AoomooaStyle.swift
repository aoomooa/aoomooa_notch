//
//  AoomooaStyle.swift — aoomooa: look and feel
//

import SwiftUI

enum AoomooaStyle {
    /// Pages reachable with a two-finger left/right swipe, in order
    static let swipeOrder: [NotchViews] = [.home, .reminders, .shelf]

    /// How strongly the open notch takes the album-art colour (0 = pure black, 1 = full colour)
    static let tintStrength: Double = 0.55
    /// How long the colour takes to change when the song changes
    static let tintFade: Double = 0.5

    /// Tab change: new page drops in from above, old page fades out
    static var tabTransition: AnyTransition {
        .asymmetric(insertion: .offset(y: -14).combined(with: .opacity),
                    removal: .opacity)
    }

    /// Hover streamline: colours from tail (left) to bright head (right)
    static let streakColors: [Color] = [
        Color(red: 0.45, green: 0.80, blue: 1.0).opacity(0.7),
        Color(red: 0.75, green: 0.60, blue: 1.0).opacity(0.9),
        Color.white
    ]
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
                    .blur(radius: 3)
                    .opacity(0.7)
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
}
