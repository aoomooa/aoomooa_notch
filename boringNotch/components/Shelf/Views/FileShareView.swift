//
//  FileShareView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct FileShareView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @StateObject private var quickShare = QuickShareService.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @State private var hostView: NSView?
    @State private var interactionNonce: UUID = .init()
    @State private var isProcessing = false
    
    private var selectedProvider: QuickShareProvider {
        quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) ?? QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }

    var body: some View {
        dropArea
            .background(NSViewHost(view: $hostView))
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dropZoneTargeting) { providers in
                interactionNonce = .init()
                vm.dropEvent = true
                Task { await handleDrop(providers) }
                return true
            }
            .onTapGesture {
                Task {
                    await handleClick()
                }
            }
    }

    private var dropArea: some View {
        ZStack {
            // aoomooa: 和其它模块一样的极淡底色，没有虚线和阴影；拖文件进来时才出现红色虚线
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(vm.dropZoneTargeting ? DS.Colors.accentSoft : DS.Colors.module)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                        .strokeBorder(vm.dropZoneTargeting ? DS.Colors.accent : Color.clear,
                                      style: StrokeStyle(lineWidth: DS.Size.dropBorder, lineCap: .round, dash: [DS.Space.s]))
                )

            // Content
            VStack(spacing: DS.Space.xs) {
                ZStack {
                    Circle()
                        .fill(vm.dropZoneTargeting ? DS.Colors.fillHover : DS.Colors.fill)
                        .frame(width: 55, height: 55)
                    Image(systemName: "square.and.arrow.up")
                    Group {
                        if let imgData = selectedProvider.imageData, let nsImg = NSImage(data: imgData) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .frame(width: 34, height: 34)
                        .foregroundStyle(
                            vm.dropZoneTargeting ? DS.Colors.accent : DS.Colors.textSecondary
                        )
                        .scaleEffect(
                            vm.dropZoneTargeting ? 1.06 : 1.0
                        )
                        .animation(DS.Motion.micro, value: vm.dropZoneTargeting)
                }

                Text(selectedProvider.id)
                    .font(DS.Fonts.body(.semibold))
                    .foregroundColor(DS.Colors.textPrimary)

            }
            .padding(DS.Space.l)
            
            // Loading overlay
            if isProcessing || quickShare.isPickerOpen {
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(DS.Colors.overlay)
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }
    
    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?
    
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}
