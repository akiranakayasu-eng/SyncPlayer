import AppKit
import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// The practice show: four short numbered movies and a round mask, made on this Mac the first
/// time they are asked for (nothing to download). Every Mac makes the same files with the same
/// names, so the practice show can also be used to try syncing several Macs.
enum Practice {
    static var dir: URL { ShowStore.base.appendingPathComponent("practice", isDirectory: true) }
    static var showURL: URL { dir.appendingPathComponent("練習.syncshow") }
    static let seconds = 10
    static let fps = 30
    static let size = CGSize(width: 640, height: 360)
    static let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.80, 0.25, 0.25), (0.20, 0.55, 0.30),
                                                        (0.22, 0.35, 0.75), (0.75, 0.60, 0.15)]

    static func moviePath(_ n: Int) -> String { dir.appendingPathComponent("練習\(n).mov").path }
    static var maskPath: String { dir.appendingPathComponent("練習マスク（丸）.png").path }

    /// Makes the files that are missing (a few seconds the first time) and returns the show:
    /// one output, the four movies in a 2×2 grid, the round mask on the fourth (front) layer.
    static func makeShow() -> Show? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in 1...4 where !FileManager.default.fileExists(atPath: moviePath(n)) {
            guard writeMovie(n, to: URL(fileURLWithPath: moviePath(n))) else { return nil }
        }
        if !FileManager.default.fileExists(atPath: maskPath) { _ = writeMask(to: URL(fileURLWithPath: maskPath)) }
        var s = Show.make(paths: (1...4).map(moviePath))
        if let last = s.outputs[0].layers.indices.last, FileManager.default.fileExists(atPath: maskPath) {
            s.outputs[0].layers[last].mask = maskPath
        }
        s.outputs[0].name = "練習の出力"
        return s
    }

    /// A movie: its colour, its big number, a bar that runs across once per second and the
    /// time and frame number (to compare Macs frame by frame).
    private static func writeMovie(_ n: Int, to url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        guard w.canAdd(input) else { return false }
        w.add(input)
        guard w.startWriting() else { return false }
        w.startSession(atSourceTime: .zero)
        let c = colors[(n - 1) % colors.count]
        for f in 0..<(seconds * fps) {
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 5000 { usleep(1000); waited += 1 }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buf = pb else { return false }
            draw(into: buf, number: n, frame: f, color: c)
            guard adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))) else { return false }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        w.finishWriting { done.signal() }
        done.wait()
        return w.status == .completed
    }

    private static func draw(into buf: CVPixelBuffer, number n: Int, frame f: Int, color c: (CGFloat, CGFloat, CGFloat)) {
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        // A white bar across the bottom, once per second.
        let x = CGFloat(f % fps) / CGFloat(fps) * size.width
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: x, y: 20, width: 24, height: 24))
        text(ctx, "\(n)", size: 200, at: CGPoint(x: size.width / 2, y: 130))
        let t = Double(f) / Double(fps)
        text(ctx, String(format: "%d:%05.2f   frame %d", Int(t) / 60, t.truncatingRemainder(dividingBy: 60), f),
             size: 28, at: CGPoint(x: size.width / 2, y: 62))
    }

    private static func text(_ ctx: CGContext, _ s: String, size: CGFloat, at p: CGPoint) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attr)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: p.x - CGFloat(w) / 2, y: p.y)
        CTLineDraw(line, ctx)
    }

    /// Black with a white ellipse: the movie shows only inside the circle.
    private static func writeMask(to url: URL) -> Bool {
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fillEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 20))
        guard let img = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst)
    }
}
