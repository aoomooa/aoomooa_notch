#!/usr/bin/env swift
//
// 生成整套 macOS App 图标（16–1024 共 10 张）并写进 Assets.xcassets/AppIcon.appiconset
//
// 用法：
//   swift scripts/make-appicon.swift <源图标>            # PNG / JPG / SVG / PDF 都行，越大越清晰（最好 ≥ 1024）
//   swift scripts/make-appicon.swift <源图标> "#1C1C1E"  # 源图标是透明底时，用这个颜色垫底（默认白色）
//
// 按 Apple 的 macOS 图标模板：1024 画布里放 824 的圆角方块（squircle），四周留透明边和一点阴影，
// 这样在 macOS 26 以后的程序坞 / 启动台里不会被系统再套一层灰框。
//

import AppKit

// MARK: 参数

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("用法：swift scripts/make-appicon.swift <源图标.png|.svg|.pdf> [垫底颜色 #RRGGBB]")
    exit(1)
}
let sourcePath = (args[1] as NSString).expandingTildeInPath
guard let source = NSImage(contentsOfFile: sourcePath), source.size.width > 0 else {
    print("✗ 读不了这个文件：\(sourcePath)")
    print("  如果是 SVG 读不了，先在浏览器或预览里导出一张 1024×1024 的 PNG 再试。")
    exit(1)
}

func color(hex: String) -> NSColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let plate = args.count >= 3 ? (color(hex: args[2]) ?? .white) : .white

let scriptDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let iconSet = scriptDir.appendingPathComponent("../boringNotch/Assets.xcassets/AppIcon.appiconset").standardizedFileURL
guard FileManager.default.fileExists(atPath: iconSet.path) else {
    print("✗ 找不到 \(iconSet.path)")
    exit(1)
}

// MARK: 源图是不是“铺满的方形图标”（四个角不透明）

func bitmap(of image: NSImage, side: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let probeSide = 64
let fullBleed: Bool = {
    guard let rep = bitmap(of: source, side: probeSide) else { return true }
    let corners = [(1, 1), (probeSide - 2, 1), (1, probeSide - 2), (probeSide - 2, probeSide - 2)]
    return corners.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.alphaComponent ?? 0) > 0.9 }
}()
print(fullBleed ? "▶ 源图是铺满的方形图标：直接裁成圆角方块" : "▶ 源图有透明底：垫一层底色再放进去")

// MARK: Apple 模板（以 1024 为基准）

let canvas: CGFloat = 1024
let bodyInset: CGFloat = 100          // 824 的图标主体
let shadowBlur: CGFloat = 28
let shadowOffset: CGFloat = 12
let shadowAlpha: CGFloat = 0.3
let logoInset: CGFloat = 0.14         // 透明底的图案在主体里留的边
let squircleExponent: CGFloat = 5     // 超椭圆，接近系统图标的连续圆角

func squircle(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c >= 0 ? 1 : -1) * pow(abs(c), 2 / squircleExponent)
        let y = cy + b * (s >= 0 ? 1 : -1) * pow(abs(s), 2 / squircleExponent)
        i == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
    }
    path.close()
    return path
}

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    let k = CGFloat(pixels) / canvas
    let body = NSRect(x: bodyInset * k, y: bodyInset * k,
                      width: (canvas - bodyInset * 2) * k, height: (canvas - bodyInset * 2) * k)
    let shape = squircle(in: body)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = ctx
    ctx?.imageInterpolation = .high

    // 阴影
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = shadowBlur * k
    shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset * k)
    shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
    shadow.set()
    (fullBleed ? NSColor.black : plate).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // 主体
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    if fullBleed {
        // 铺满：按比例填满主体
        let scale = max(body.width / source.size.width, body.height / source.size.height)
        let w = source.size.width * scale, h = source.size.height * scale
        source.draw(in: NSRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1)
    } else {
        plate.setFill()
        body.fill()
        let inner = body.insetBy(dx: body.width * logoInset, dy: body.height * logoInset)
        let scale = min(inner.width / source.size.width, inner.height / source.size.height)
        let w = source.size.width * scale, h = source.size.height * scale
        source.draw(in: NSRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: 输出

struct Slot { let size: Int; let scale: Int }
let slots = [16, 32, 128, 256, 512].flatMap { [Slot(size: $0, scale: 1), Slot(size: $0, scale: 2)] }

// 删掉旧图标
let fm = FileManager.default
for name in (try? fm.contentsOfDirectory(atPath: iconSet.path)) ?? [] where name.hasSuffix(".png") {
    try? fm.removeItem(at: iconSet.appendingPathComponent(name))
}

var entries: [[String: String]] = []
for slot in slots {
    let pixels = slot.size * slot.scale
    let name = "icon_\(slot.size)x\(slot.size)\(slot.scale == 2 ? "@2x" : "").png"
    guard let png = render(pixels: pixels) else {
        print("✗ 生成 \(name) 失败")
        exit(1)
    }
    try png.write(to: iconSet.appendingPathComponent(name))
    entries.append(["filename": name, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.size)x\(slot.size)"])
    print("  ✓ \(name)（\(pixels)×\(pixels)）")
}

let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appendingPathComponent("Contents.json"))

let px = source.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
if px > 0 && px < 1024 {
    print("ℹ︎ 源图只有 \(px)px，1024 的图标会有点糊；有 SVG 或更大的 PNG 的话换它再跑一次。")
}
print("✓ 完成：\(iconSet.path)")
print("  接着运行 ./scripts/build-install.sh，Finder 和启动台里就是新图标。")
