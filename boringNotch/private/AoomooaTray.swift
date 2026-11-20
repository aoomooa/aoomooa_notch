//
//  AoomooaTray.swift
//  boringNotch (aoomooa fork)
//
//  The "Tray" page (button left of the settings gear): AirDrop + a temporary holding tray.
//  Right-click items for Finder-style actions (open, copy, rename, move to Trash …).
//

import AppKit
import SwiftUI

struct NotchTrayView: View {
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        HStack(spacing: DS.Space.s) {
            // Existing shelf: AirDrop square on the left + the holding tray
            ShelfView()
                .environmentObject(vm)
        }
        // when the tray has enough items to scroll sideways, let the swipe scroll it instead of changing page
        .onHover { inside in
            AoomooaGestureGate.horizontalScrollerHovered = inside && ShelfStateViewModel.shared.items.count > 5
        }
        .onDisappear { AoomooaGestureGate.horizontalScrollerHovered = false }
    }
}
