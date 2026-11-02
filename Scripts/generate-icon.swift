import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let configuration = root.appendingPathComponent("Configuration")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func render(size: Int) throws -> Data {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let shell = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                       cornerWidth: 184, cornerHeight: 184, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20,
                      color: color(0.12, 0.20, 0.23, 0.16))
    context.setFillColor(color(0.06, 0.38, 0.34))
    context.addPath(shell)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shell)
    context.clip()
    let dawn = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0.06, 0.27, 0.31), color(0.13, 0.43, 0.46),
             color(0.35, 0.57, 0.57), color(0.95, 0.66, 0.54),
             color(1, 0.85, 0.65)] as CFArray,
        locations: [0, 0.56, 0.73, 0.87, 1]
    )!
    context.drawLinearGradient(dawn, start: CGPoint(x: 512, y: 924),
                               end: CGPoint(x: 512, y: 100), options: [])
    context.setStrokeColor(color(1, 1, 1))
    context.setLineWidth(64)
    context.setLineJoin(.miter)
    context.setLineCap(.butt)
    context.move(to: CGPoint(x: 278, y: 376))
    context.addLine(to: CGPoint(x: 278, y: 640))
    context.addLine(to: CGPoint(x: 386, y: 508))
    context.addLine(to: CGPoint(x: 494, y: 640))
    context.addLine(to: CGPoint(x: 494, y: 376))
    context.strokePath()

    context.move(to: CGPoint(x: 688, y: 656))
    context.addLine(to: CGPoint(x: 688, y: 388))
    context.move(to: CGPoint(x: 606, y: 464))
    context.addLine(to: CGPoint(x: 688, y: 382))
    context.addLine(to: CGPoint(x: 770, y: 464))
    context.strokePath()
    context.restoreGState()
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    guard let data = image.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(points)x\(points)\(suffix).png"
        try render(size: points * scale).write(to: iconset.appendingPathComponent(filename))
    }
}
try render(size: 1024).write(to: configuration.appendingPathComponent("AppIcon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", configuration.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
print("Generated Configuration/AppIcon.png and AppIcon.icns (16-1024 px).")