//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

private let homeTab = TabModel(label: "Home", icon: "house.fill", view: .home)
private let workspaceTab = TabModel(label: "Workspace", icon: "rectangle.split.2x1.fill", view: .apps)

// aoomooa: 首页（媒体·网站·AI）+ 控制台（系统状态·启动器）；右侧 ⏱ 进入时间页（日历+天气·计时器）
var tabs: [TabModel] {
    [homeTab, workspaceTab]
}

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(DS.Motion.page) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: DS.Size.tab)
                    .foregroundStyle(tab.view == coordinator.currentView ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? DS.Colors.fillHover : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? DS.Colors.fillHover : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
