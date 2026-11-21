//
//  ContentView.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var webcamManager = WebcamManager.shared

    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var brightnessManager = BrightnessManager.shared
    @ObservedObject var volumeManager = VolumeManager.shared
    @State private var hoverTask: Task<Void, Never>?
    @State private var isHovering: Bool = false
    @State private var stage1Task: Task<Void, Never>?   // aoomooa
    @State private var collapseTask: Task<Void, Never>? // aoomooa
    @State private var swipeLatched = false                 // aoomooa: one action per swipe
    @State private var swipeOffset: CGFloat = 0             // aoomooa: page follows the fingers
    @State private var pageDirection: CGFloat = 0           // aoomooa: 0 = drop from top, ±1 = slide sideways
    @State private var swipeCooldownUntil = Date.distantPast
    @State private var hoverProgress: CGFloat = 0           // aoomooa: streamline sweep 0…1
    @AppStorage(AoomooaPrefs.Key.tintStrength) private var tintStrength = AoomooaPrefs.Default.tintStrength  // aoomooa
    @AppStorage(AoomooaPrefs.Key.timerShowWhenClosed) private var timerShowWhenClosed = AoomooaPrefs.Default.timerShowWhenClosed  // aoomooa
    @ObservedObject private var notchTimer = NotchTimerModel.shared   // aoomooa
    @ObservedObject private var sentinel = AoomooaSentinelModel.shared   // aoomooa: AI 哨兵

    @State private var gestureProgress: CGFloat = .zero

    @State private var haptics: Bool = false

    @Namespace var albumArtNamespace

    @Default(.useMusicVisualizer) var useMusicVisualizer

    @Default(.showNotHumanFace) var showNotHumanFace

    // Shared interactive spring for movement/resizing to avoid conflicting animations
    private var animationSpring: Animation { DS.Motion.panel }   // aoomooa: 统一走面板档

    private let extendedHoverPadding: CGFloat = 30
    private let zeroHeightHoverPadding: CGFloat = 10

    private var topCornerRadius: CGFloat {
       ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.top
                : cornerRadiusInsets.closed.top
    }

    private var currentNotchShape: NotchShape {
        NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: ((vm.notchState == .open) && Defaults[.cornerRadiusScaling])
                ? cornerRadiusInsets.opened.bottom
                : cornerRadiusInsets.closed.bottom
        )
    }

    private var isMusicLiveActive: Bool {
        (musicManager.isPlaying || !musicManager.isPlayerIdle) && coordinator.musicLiveActivityEnabled
    }

    /// AI 活跃时仅在媒体真正播放中展示外侧媒体翼（暂停即自动收翼，把空间还给 AI）
    private var showsMediaWithSentinel: Bool {
        coordinator.musicLiveActivityEnabled && musicManager.isPlaying
    }

    private var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if coordinator.expandingView.type == .battery && coordinator.expandingView.show
            && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
        {
            chinWidth = 640
        } else if !coordinator.expandingView.show && vm.notchState == .closed && !vm.hideOnClosed
            && notchTimer.showsOnClosedNotch(showWhileRunning: timerShowWhenClosed)
        {
            chinWidth += (2 * DS.Size.timerSide)
        } else if !coordinator.expandingView.show && vm.notchState == .closed && !vm.hideOnClosed
            && sentinel.showsOnClosedNotch
        {
            chinWidth += (2 * AoomooaSentinelLiveActivity.sideWidth(
                for: sentinel.orderedActiveRecords.count,
                withMedia: showsMediaWithSentinel
            ))
        } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music)
            && vm.notchState == .closed && isMusicLiveActive && !vm.hideOnClosed
        {
            let mediaWing = max(DS.Size.sentinelMediaWing, vm.effectiveClosedNotchHeight - 8)
            chinWidth += (2 * mediaWing)
        } else if !coordinator.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed
        {
            chinWidth += (2 * max(0, vm.effectiveClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var body: some View {
        // Calculate scale based on gesture progress only
        let gestureScale: CGFloat = {
            guard gestureProgress != 0 else { return 1.0 }
            let scaleFactor = 1.0 + gestureProgress * 0.01
            return max(0.6, scaleFactor)
        }()
        
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                        ? Defaults[.cornerRadiusScaling]
                        ? (cornerRadiusInsets.opened.top) : (cornerRadiusInsets.opened.bottom)
                        : cornerRadiusInsets.closed.bottom
                    )
                    .padding([.horizontal, .bottom], vm.notchState == .open ? DS.Space.m : 0)
                    .background {
                        // aoomooa: direction B — the open notch takes the album-art colour
                        ZStack {
                            Color.black
                            if vm.notchState == .open
                                && coordinator.currentView == .home
                                && !musicManager.isPlayerIdle {
                                LinearGradient(
                                    colors: [.clear, Color(nsColor: musicManager.avgColor).opacity(min(max(tintStrength, 0), 1))],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                        }
                        .animation(DS.Motion.page, value: musicManager.avgColor)
                    }
                    .clipShape(currentNotchShape)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, topCornerRadius)
                    }
                    .overlay {
                        // aoomooa: a streamline traces the island — down the left side, along the bottom,
                        // up the right side — and the notch opens when it reaches the top-right corner
                        if vm.notchState == .closed && isHovering && Defaults[.openNotchOnHover] {
                            AoomooaOutlineStreak(progress: hoverProgress,
                                                 topRadius: cornerRadiusInsets.closed.top,
                                                 bottomRadius: cornerRadiusInsets.closed.bottom,
                                                 hardwareWidth: vm.closedNotchSize.width)
                                .allowsHitTesting(false)
                        }
                    }
                    .shadow(
                        color: ((vm.notchState == .open || isHovering) && Defaults[.enableShadow])
                            ? .black.opacity(0.7) : .clear, radius: Defaults[.cornerRadiusScaling] ? 6 : 4
                    )
                    .padding(
                        .bottom,
                        vm.effectiveClosedNotchHeight == 0 ? 10 : 0
                    )
                
                mainLayout
                    .frame(height: vm.notchState == .open ? vm.notchSize.height : nil)
                    .conditionalModifier(true) { view in
                        let openAnimation: Animation? = AoomooaHover.expandAnimation
                        let closeAnimation: Animation? = AoomooaHover.collapseAnimation
                        
                        return view
                            .animation(vm.notchState == .open ? openAnimation : closeAnimation, value: vm.notchState)
                            .animation(DS.Motion.panel, value: gestureProgress)
                            .animation(DS.Motion.panel, value: showsMediaWithSentinel)
                            .animation(DS.Motion.panel, value: sentinel.orderedActiveRecords.count)
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        handleHover(hovering)
                    }
                    .onTapGesture {
                        doOpen()
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .down) { translation, phase in
                                handleDownGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.closeGestureEnabled] && Defaults[.enableGestures]) { view in
                        view
                            .panGesture(direction: .up) { translation, phase in
                                handleUpGesture(translation: translation, phase: phase)
                            }
                    }
                    .conditionalModifier(Defaults[.enableGestures]) { view in
                        view   // aoomooa: two-finger swipe left/right switches tabs
                            .panGesture(direction: .left) { translation, phase in
                                handleTabSwipe(step: 1, translation: translation, phase: phase)
                            }
                            .panGesture(direction: .right) { translation, phase in
                                handleTabSwipe(step: -1, translation: translation, phase: phase)
                            }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        if vm.notchState == .open && !isHovering && !vm.isBatteryPopoverActive {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if self.vm.notchState == .open && !self.isHovering && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: vm.notchState) { _, newState in
                        if newState == .closed && isHovering {
                            isHovering = false
                        }
                    }
                    .onChange(of: vm.isBatteryPopoverActive) {
                        if !vm.isBatteryPopoverActive && !sentinel.isPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            hoverTask?.cancel()
                            hoverTask = Task {
                                try? await Task.sleep(for: .milliseconds(100))
                                guard !Task.isCancelled else { return }
                                await MainActor.run {
                                    if !self.vm.isBatteryPopoverActive && !self.sentinel.isPopoverActive && !self.isHovering && self.vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                                        self.vm.close()
                                    }
                                }
                            }
                        }
                    }
                    .onChange(of: sentinel.isPopoverActive) {
                        if !sentinel.isPopoverActive && !vm.isBatteryPopoverActive && !isHovering && vm.notchState == .open && !SharingStateManager.shared.preventNotchClose {
                            handleHover(false)
                        }
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        Button("设置…") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        Divider()
                        Button("退出") {
                            NSApplication.shared.terminate(nil)
                        }
                        .keyboardShortcut(KeyEquivalent("q"), modifiers: .command)
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: windowSize.height, alignment: .top)
        .compositingGroup()
        .scaleEffect(
            x: gestureScale,
            y: gestureScale,
            anchor: .top
        )
        .animation(DS.Motion.panel, value: gestureProgress)
        .preferredColorScheme(.dark)
        .environmentObject(vm)
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                if coordinator.helloAnimationRunning {
                    Spacer()
                    HelloAnimation(onFinish: {
                        vm.closeHello()
                    }).frame(
                        width: getClosedNotchSize().width,
                        height: 80
                    )
                    .padding(.top, 40)
                    Spacer()
                } else {
                    if coordinator.expandingView.type == .battery && coordinator.expandingView.show
                        && vm.notchState == .closed && Defaults[.showPowerStatusNotifications]
                    {
                        HStack(spacing: 0) {
                            HStack {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.closedNotchSize.width + 10)

                            HStack {
                                BoringBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    isForNotification: true
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
                      } else if coordinator.sneakPeek.show && Defaults[.inlineHUD] && (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && vm.notchState == .closed {
                          InlineHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon, hoverAnimation: $isHovering, gestureProgress: $gestureProgress)
                              .transition(.opacity)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && !vm.hideOnClosed
                                    && notchTimer.showsOnClosedNotch(showWhileRunning: timerShowWhenClosed) {
                          // aoomooa: 计时器 — 左边 ⏱，右边 mm:ss（若同时有 AI 活跃则右侧边缘轻叠小灯）
                          HStack(spacing: DS.Space.xs) {
                              AoomooaTimerLiveActivity(height: vm.effectiveClosedNotchHeight,
                                                       middleWidth: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)
                              if sentinel.showsOnClosedNotch {
                                  AoomooaSentinelEdgeDot()
                              }
                          }
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && !vm.hideOnClosed
                                    && sentinel.showsOnClosedNotch {
                          // aoomooa: AI 哨兵（内侧左1↔右1，媒体播放时外侧镜像伸出封面与波形，暂停自动收翼）
                          AoomooaSentinelLiveActivity(
                              height: vm.effectiveClosedNotchHeight,
                              middleWidth: vm.closedNotchSize.width - cornerRadiusInsets.closed.top,
                              showsMedia: showsMediaWithSentinel
                          )
                      } else if (!coordinator.expandingView.show || coordinator.expandingView.type == .music) && vm.notchState == .closed && isMusicLiveActive && !vm.hideOnClosed {
                          MusicLiveActivity()
                              .frame(alignment: .center)
                      } else if !coordinator.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed  {
                          BoringFaceAnimation()
                       } else if vm.notchState == .open {
                           BoringHeader()
                               .frame(height: max(24, vm.effectiveClosedNotchHeight))
                               .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
                       } else {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
                       }

                      if coordinator.sneakPeek.show {
                          if (coordinator.sneakPeek.type != .music) && (coordinator.sneakPeek.type != .battery) && !Defaults[.inlineHUD] && vm.notchState == .closed {
                              SystemEventIndicatorModifier(
                                  eventType: $coordinator.sneakPeek.type,
                                  value: $coordinator.sneakPeek.value,
                                  icon: $coordinator.sneakPeek.icon,
                                  sendEventBack: { newVal in
                                      switch coordinator.sneakPeek.type {
                                      case .volume:
                                          VolumeManager.shared.setAbsolute(Float32(newVal))
                                      case .brightness:
                                          BrightnessManager.shared.setAbsolute(value: Float32(newVal))
                                      default:
                                          break
                                      }
                                  }
                              )
                              .padding(.bottom, 10)
                              .padding(.leading, 4)
                              .padding(.trailing, 8)
                          }
                          // Old sneak peek music
                          else if coordinator.sneakPeek.type == .music {
                              if vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard {
                                  HStack(alignment: .center) {
                                      Image(systemName: "music.note")
                                      GeometryReader { geo in
                                          MarqueeText(.constant(musicManager.songTitle + " - " + musicManager.artistName),  textColor: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, minDuration: 1, frameWidth: geo.size.width)
                                      }
                                  }
                                  .foregroundStyle(.gray)
                                  .padding(.bottom, 10)
                              }
                          }
                      }
                  }
              }
              .conditionalModifier((coordinator.sneakPeek.show && (coordinator.sneakPeek.type == .music) && vm.notchState == .closed && !vm.hideOnClosed && Defaults[.sneakPeekStyles] == .standard) || (coordinator.sneakPeek.show && (coordinator.sneakPeek.type != .music) && (vm.notchState == .closed))) { view in
                  view
                      .fixedSize()
              }
              .zIndex(2)
            if vm.notchState == .open {
                ZStack(alignment: .top) {   // aoomooa: pages overlap while switching
                    switch coordinator.currentView {
                    case .home, .shelf:
                        AoomooaIdleHomeView()   // aoomooa 页面 1：播放 · 常用网站 · AI
                            .transition(pageTransition)
                    case .apps, .reminders:
                        NotchWorkspaceView()    // aoomooa 页面 2：系统状态 · 工具启动器
                            .transition(pageTransition)
                    case .timer:
                        NotchTimerView()        // aoomooa 页面 3：日历与天气 · 紧凑计时器
                            .transition(pageTransition)
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.96, anchor: .top)
                            .combined(with: .opacity)
                            .animation(AoomooaHover.expandAnimation),
                        removal: .opacity.animation(AoomooaHover.collapseAnimation)
                    )
                )
                .offset(x: swipeOffset)
                .zIndex(1)
                .allowsHitTesting(vm.notchState == .open)
                .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
            }
        }
    }

    @ViewBuilder
    func BoringFaceAnimation() -> some View {
        HStack {
            HStack {
                Rectangle()
                    .fill(.clear)
                    .frame(
                        width: max(0, vm.effectiveClosedNotchHeight - 12),
                        height: max(0, vm.effectiveClosedNotchHeight - 12)
                    )
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20)
                MinimalFaceFeatures()
            }
        }.frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    func MusicLiveActivity() -> some View {
        let wingWidth = max(DS.Size.sentinelMediaWing, vm.effectiveClosedNotchHeight - 8)
        let artworkSize = max(16, min(20, vm.effectiveClosedNotchHeight - 13))
        let auraColor = AoomooaMediaAuraArtwork.resolvedAuraColor(from: musicManager.avgColor)

        HStack(spacing: 0) {
            AoomooaMediaAuraArtwork(
                image: musicManager.albumArt,
                auraColor: auraColor,
                size: artworkSize,
                isPlaying: musicManager.isPlaying
            )
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight)

            Rectangle()
                .fill(.black)
                .overlay(
                    HStack(alignment: .top) {
                        if coordinator.expandingView.show
                            && coordinator.expandingView.type == .music
                        {
                            MarqueeText(
                                .constant(musicManager.songTitle),
                                textColor: Defaults[.coloredSpectrogram]
                                    ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                minDuration: 0.4,
                                frameWidth: 100
                            )
                            .opacity(
                                (coordinator.expandingView.show
                                    && Defaults[.sneakPeekStyles] == .inline)
                                    ? 1 : 0
                            )
                            Spacer(minLength: vm.closedNotchSize.width)
                            // Song Artist
                            Text(musicManager.artistName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .foregroundStyle(
                                    Defaults[.coloredSpectrogram]
                                        ? Color(nsColor: musicManager.avgColor)
                                        : Color.gray
                                )
                                .opacity(
                                    (coordinator.expandingView.show
                                        && coordinator.expandingView.type == .music
                                        && Defaults[.sneakPeekStyles] == .inline)
                                        ? 1 : 0
                                )
                        }
                    }
                )
                .frame(
                    width: (coordinator.expandingView.show
                        && coordinator.expandingView.type == .music
                        && Defaults[.sneakPeekStyles] == .inline)
                        ? 380
                        : vm.closedNotchSize.width
                            - cornerRadiusInsets.closed.top
                )

            AoomooaMediaSpectrumWing(
                isPlaying: $musicManager.isPlaying,
                auraColor: auraColor,
                coexisting: false
            )
            .matchedGeometryEffect(id: "spectrum", in: albumArtNamespace)
            .frame(width: wingWidth, height: vm.effectiveClosedNotchHeight)
        }
        .frame(
            height: vm.effectiveClosedNotchHeight,
            alignment: .center
        )
    }

    private func doOpen() {
        withAnimation(AoomooaHover.expandAnimation) {
            vm.open()
        }
    }

    // MARK: - Hover Management

    private func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch { return }

        // aoomooa: stage 1 instantly -> wait stage1Delay -> ease-out expand.
        // Leaving collapses with no animation (after a tiny exitGrace that ignores
        // the hover flicker SwiftUI emits while the notch changes size).
        if hovering {
            hoverTask?.cancel()
            collapseTask?.cancel()
            collapseTask = nil
            withTransaction(AoomooaHover.instant) { isHovering = true }

            guard vm.notchState == .closed else { return }
            if stage1Task != nil { return }   // stage 1 already counting — don't restart

            withTransaction(AoomooaHover.instant) {
                if musicManager.isPlaying || !musicManager.isPlayerIdle {
                    coordinator.setMusicPeekInstant(true)
                }
            }
            if Defaults[.enableHaptics] { haptics.toggle() }
            guard Defaults[.openNotchOnHover] else { return }

            withTransaction(AoomooaHover.instant) { hoverProgress = 0 }
            withAnimation(.linear(duration: AoomooaHover.stage1Delay)) { hoverProgress = 1 }

            stage1Task = Task {
                try? await Task.sleep(for: .seconds(AoomooaHover.stage1Delay))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.stage1Task = nil
                    guard self.vm.notchState == .closed, self.isHovering else { return }
                    withTransaction(AoomooaHover.instant) {
                        self.coordinator.setMusicPeekInstant(false)
                        self.hoverProgress = 0
                    }
                    self.doOpen()
                }
            }
        } else {
            collapseTask?.cancel()
            // aoomooa: 展开态移开鼠标后停留 collapseDelay（默认 3 秒）再收起；
            // 收起态仅等 80ms 取消流光，避免擦过刘海后延迟误展开。
            let delay: Duration = vm.notchState == .open
                ? .seconds(max(Double(AoomooaHover.exitGraceMs) / 1000.0, AoomooaHover.collapseDelay))
                : .milliseconds(AoomooaHover.exitGraceMs)
            collapseTask = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.collapseTask = nil
                    self.stage1Task?.cancel()
                    self.stage1Task = nil
                    withTransaction(AoomooaHover.instant) {
                        self.isHovering = false
                        self.hoverProgress = 0
                        if self.coordinator.sneakPeek.show && self.coordinator.sneakPeek.type == .music {
                            self.coordinator.setMusicPeekInstant(false)
                        }
                    }
                    if self.vm.notchState == .open
                        && !self.vm.isBatteryPopoverActive
                        && !self.sentinel.isPopoverActive
                        && !SharingStateManager.shared.preventNotchClose {
                        withAnimation(AoomooaHover.collapseAnimation) { self.vm.close() }
                    }
                }
            }
        }
    }

    // MARK: - Gesture Handling

    private func handleDownGesture(translation: CGFloat, phase: NSEvent.Phase) {
        guard vm.notchState == .closed else { return }

        // aoomooa: if the playing live activity was swiped away, a swipe down brings it back
        if !coordinator.musicLiveActivityEnabled && (musicManager.isPlaying || !musicManager.isPlayerIdle) {
            if phase == .ended { swipeLatched = false; return }
            guard !swipeLatched, translation > AoomooaHover.swipeDistance else { return }
            swipeLatched = true
            if Defaults[.enableHaptics] { haptics.toggle() }
            withAnimation(AoomooaHover.expandAnimation) {
                coordinator.objectWillChange.send()
                coordinator.musicLiveActivityEnabled = true
            }
            return
        }

        if phase == .ended {
            withAnimation(animationSpring) { gestureProgress = .zero }
            return
        }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * 20
        }

        if translation > Defaults[.gestureSensitivity] {
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
            doOpen()
        }
    }

    /// Clicked tabs drop in from the top; swiped pages slide in from the side you swipe towards
    private var pageTransition: AnyTransition {
        guard pageDirection != 0 else { return AoomooaStyle.tabTransition }
        return .asymmetric(
            insertion: .offset(x: AoomooaStyle.swipeTransitionOffset * pageDirection).combined(with: .opacity),
            removal: .offset(x: -AoomooaStyle.swipeTransitionOffset * pageDirection).combined(with: .opacity)
        )
    }

    // aoomooa: two-finger swipe left/right moves between the pages while the notch is open
    private func handleTabSwipe(step: Int, translation: CGFloat, phase: NSEvent.Phase) {
        if phase == .ended {
            swipeLatched = false
            withAnimation(DS.Motion.panel) { swipeOffset = 0 }
            return
        }
        guard vm.notchState == .open, !swipeLatched, Date() >= swipeCooldownUntil,
              !NotchRemindersModel.shared.isHoveringDayStrip,
              !AoomooaGestureGate.horizontalScrollerHovered else { return }

        let order = AoomooaStyle.swipeOrder   // Music · Workspace · Tray
        guard let index = order.firstIndex(of: coordinator.currentView) else { return }
        let next = index + step
        let canMove = order.indices.contains(next)

        // follow the fingers a little; at the first/last page it only stretches (rubber band)
        let progress = min(translation / AoomooaHover.tabSwipeDistance, 1)
        let follow = AoomooaHover.tabSwipeFollow * progress * (canMove ? 1 : AoomooaHover.rubberBand)
        withAnimation(DS.Motion.micro) {
            swipeOffset = -CGFloat(step) * follow
        }

        guard canMove, translation > AoomooaHover.tabSwipeDistance else { return }
        swipeLatched = true
        swipeCooldownUntil = Date().addingTimeInterval(AoomooaHover.tabSwipeCooldown)
        if Defaults[.enableHaptics] { haptics.toggle() }

        // set the direction first, then switch on the next run-loop so both pages use it
        pageDirection = CGFloat(step)
        Task { @MainActor in
            await Task.yield()
            withAnimation(DS.Motion.page) {
                swipeOffset = 0
                coordinator.currentView = order[next]
            }
            try? await Task.sleep(for: .seconds(DS.Motion.pageDuration + DS.Motion.microDuration))
            pageDirection = 0
        }
    }

    private func handleUpGesture(translation: CGFloat, phase: NSEvent.Phase) {
        // aoomooa: on the closed notch, two-finger swipe up hides the playing live activity
        if vm.notchState == .closed {
            if phase == .ended { swipeLatched = false; return }
            guard !swipeLatched, translation > AoomooaHover.swipeDistance,
                  coordinator.musicLiveActivityEnabled,
                  musicManager.isPlaying || !musicManager.isPlayerIdle else { return }
            swipeLatched = true
            stage1Task?.cancel()
            stage1Task = nil
            withTransaction(AoomooaHover.instant) {
                hoverProgress = 0
                coordinator.setMusicPeekInstant(false)
            }
            if Defaults[.enableHaptics] { haptics.toggle() }
            withAnimation(AoomooaHover.collapseAnimation) {
                coordinator.objectWillChange.send()
                coordinator.musicLiveActivityEnabled = false
            }
            return
        }
        // aoomooa: 时间页（日历列表 + 计时器滚轮）本身需要上下滑动，屏蔽上滑收起手势避免误触
        guard vm.notchState == .open && !vm.isHoveringCalendar,
              coordinator.currentView != .timer,
              !AoomooaGestureGate.verticalScrollerHovered else { return }

        withAnimation(animationSpring) {
            gestureProgress = (translation / Defaults[.gestureSensitivity]) * -20
        }

        if phase == .ended {
            withAnimation(animationSpring) {
                gestureProgress = .zero
            }
        }

        if translation > Defaults[.gestureSensitivity] {
            withAnimation(animationSpring) {
                isHovering = false
            }
            if !SharingStateManager.shared.preventNotchClose { 
                gestureProgress = .zero
                vm.close()
            }

            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }
}

struct FullScreenDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let onDrop: () -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        onDrop()
        return true
    }

}

struct GeneralDropTargetDelegate: DropDelegate {
    @Binding var isTargeted: Bool

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .cancel)
    }

    func performDrop(info: DropInfo) -> Bool {
        return false
    }
}

#Preview {
    let vm = BoringViewModel()
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
