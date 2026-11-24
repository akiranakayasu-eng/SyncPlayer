import Foundation
import MetalKit
import AVFoundation
import CoreVideo
import CoreMedia

/// How video frames reach the GPU. YUV (two planes, the decoder's own layout) is converted to
/// RGB in the shader, so no separate conversion pass is needed per frame. BGRA is kept for tests.
enum FrameFormat {
    static var bgra = false
    /// Keep the movie's own chroma detail: ProRes 422 as 4:2:2, ProRes 4444 as 4:4:4, others 4:2:0.
    static func pixelFormat(forCodec c: FourCharCode?) -> OSType {
        if bgra { return kCVPixelFormatType_32BGRA }
        switch c {
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
             kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy:
            return kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
        default:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }
}

/// Metal objects shared by every view: device, pipeline (premultiplied alpha, so layers stack),
/// texture cache for video frames, and the grid's index buffer.
final class GPU {
    static let shared = GPU()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let cache: CVMetalTextureCache
    let blank: MTLTexture
    let indexBuffer: MTLBuffer
    let indexCount: Int
    static let N = 48   // grid subdivisions

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; float2 uv; float2 outPos; };
    struct U { float4 crop; float4 blend; float gamma; float grid; float hasTex; float opacity;
               float yuv; float pad0; float pad1; float pad2; };

    vertex Out vmain(uint vid [[vertex_id]], const device float4* v [[buffer(0)]]) {
        Out o;
        float2 p = v[vid].xy;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = v[vid].zw;
        o.outPos = p;
        return o;
    }

    // Video-range Y'CbCr (8 bit) to RGB. m: 1 = BT.709, 2 = BT.601, 3 = BT.2020 (matrix only;
    // the picture is not tone-mapped, so HDR movies look flat).
    float3 toRGB(float y, float2 c, float m) {
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        c = (c - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb;
        if (m > 2.5)      rgb = float3(y + 1.4746 * c.y, y - 0.164553 * c.x - 0.571353 * c.y, y + 1.8814 * c.x);
        else if (m > 1.5) rgb = float3(y + 1.402 * c.y, y - 0.344136 * c.x - 0.714136 * c.y, y + 1.772 * c.x);
        else              rgb = float3(y + 1.5748 * c.y, y - 0.187324 * c.x - 0.468124 * c.y, y + 1.8556 * c.x);
        return saturate(rgb);
    }

    fragment float4 fmain(Out in [[stage_in]], texture2d<float> tex [[texture(0)]],
                          texture2d<float> chroma [[texture(1)]], constant U& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        // crop: x=L y=R z=T w=B (uv y points up). Cropped parts show what is behind.
        if (uv.x < u.crop.x || uv.x > 1.0 - u.crop.y || uv.y > 1.0 - u.crop.z || uv.y < u.crop.w) {
            discard_fragment();
        }
        float2 st = float2(uv.x, 1.0 - uv.y);
        float4 c = float4(0.1, 0.1, 0.1, 1);
        if (u.hasTex > 0.5) {
            c = u.yuv > 0.5 ? float4(toRGB(tex.sample(s, st).r, chroma.sample(s, st).rg, u.yuv), 1.0) : tex.sample(s, st);
        }
        if (u.grid > 0.5) {
            float2 g = uv * 10.0;
            float2 d = abs(fract(g - 0.5) - 0.5) / max(fwidth(g), float2(1e-5));
            float line = 1.0 - min(min(d.x, d.y), 1.0);
            float2 dc = abs(uv - 0.5) / max(fwidth(uv), float2(1e-5));
            float center = 1.0 - min(min(dc.x, dc.y) / 2.0, 1.0);
            float diag = 1.0 - min(min(abs(uv.x - uv.y), abs(uv.x + uv.y - 1.0)) / max(fwidth(uv.x) * 1.5, 1e-5), 1.0);
            c.rgb = mix(c.rgb, float3(1.0), max(line, diag) * 0.85);
            c.rgb = mix(c.rgb, float3(1.0, 0.2, 0.2), center);
        }
        float f = 1.0;
        float2 p = in.outPos;
        float ig = 1.0 / max(u.gamma, 0.1);
        if (u.blend.x > 0.0) f *= pow(smoothstep(0.0, 1.0, clamp(p.x / u.blend.x, 0.0, 1.0)), ig);
        if (u.blend.y > 0.0) f *= pow(smoothstep(0.0, 1.0, clamp((1.0 - p.x) / u.blend.y, 0.0, 1.0)), ig);
        if (u.blend.z > 0.0) f *= pow(smoothstep(0.0, 1.0, clamp((1.0 - p.y) / u.blend.z, 0.0, 1.0)), ig);
        if (u.blend.w > 0.0) f *= pow(smoothstep(0.0, 1.0, clamp(p.y / u.blend.w, 0.0, 1.0)), ig);
        // Premultiplied: over black this is the same as darkening; over another layer it fades into it.
        float a = clamp(u.opacity, 0.0, 1.0) * f;
        return float4(c.rgb * a, a);
    }
    """

    private init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        do {
            let lib = try dev.makeLibrary(source: GPU.shader, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            let ca = desc.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("Metal setup failed: \(error)")
            return nil
        }
        var c: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &c)
        guard let c else { return nil }
        cache = c
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let b = dev.makeTexture(descriptor: td) else { return nil }
        blank = b
        let N = GPU.N
        var idx: [UInt32] = []
        idx.reserveCapacity(N * N * 6)
        for j in 0..<N {
            for i in 0..<N {
                let a = UInt32(j * (N + 1) + i), b = a + 1, c = a + UInt32(N + 1), d = c + 1
                idx += [a, b, d, a, d, c]
            }
        }
        guard let ib = dev.makeBuffer(bytes: idx, length: idx.count * 4) else { return nil }
        indexBuffer = ib
        indexCount = idx.count
    }

    /// Grid vertices (output x,y + source u,v) for one layer's look.
    func vertices(_ s: DisplaySettings, viewAspect: Double, videoAspect: Double) -> MTLBuffer? {
        let N = GPU.N
        let H = Warp.Homography(Warp.corners(s, viewAspect: viewAspect, videoAspect: videoAspect))
        let m = s.meshOffsets
        var verts: [SIMD4<Float>] = []
        verts.reserveCapacity((N + 1) * (N + 1))
        for j in 0...N {
            for i in 0...N {
                let u = Double(i) / Double(N), v = Double(j) / Double(N)
                let o = Warp.output(s, H, m, u, v)
                let src = Warp.source(s, videoAspect: videoAspect, u, v)
                verts.append(SIMD4(Float(o.x), Float(o.y), Float(src.x), Float(src.y)))
            }
        }
        return device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD4<Float>>.stride)
    }
}

/// The latest video frame of one clip, shared by every view that shows the clip.
/// Timing is untouched: the frame for "now" is taken from the node's active player.
final class FrameSource {
    let node: SyncNode
    /// BGRA: the picture. YUV: the Y plane; chromaTexture holds CbCr.
    private(set) var texture: CVMetalTexture?
    private(set) var chromaTexture: CVMetalTexture?
    /// 0 = BGRA, 1 = BT.709, 2 = BT.601, 3 = BT.2020 (for the shader).
    private(set) var yuvMatrix: Float = 0
    private(set) var aspect = 0.0

    init(node: SyncNode) { self.node = node }

    // Load check: frames shown and frames skipped (a gap larger than one frame in the movie's time).
    private(set) var framesShown = 0
    private(set) var framesDropped = 0
    private var lastShown = -1.0

    private func count(_ t: Double) {
        guard t.isFinite else { return }
        framesShown += 1
        let fd = node.frameDuration
        if lastShown >= 0, fd > 0 {
            let gap = t - lastShown
            // Ignore loop points, jumps and restarts.
            if gap > fd * 1.5 && gap < 0.5 { framesDropped += Int((gap / fd).rounded()) - 1 }
        }
        lastShown = t
    }

    func fetch(now: Double) {
        guard let gpu = GPU.shared else { return }
        guard node.outputs.count == 2 else { return }
        let out = node.outputs[node.displayIndex(atLocal: now)]
        let t = out.itemTime(forHostTime: now)
        guard out.hasNewPixelBuffer(forItemTime: t) else { return }
        var shown = CMTime.invalid
        guard let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) else { return }
        count(shown.seconds)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if h > 0 { aspect = Double(w) / Double(h) }
        if CVPixelBufferGetPlaneCount(pb) >= 2 {
            var y: CVMetalTexture?, c: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, gpu.cache, pb, nil, .r8Unorm,
                                                      CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &y)
            CVMetalTextureCacheCreateTextureFromImage(nil, gpu.cache, pb, nil, .rg8Unorm,
                                                      CVPixelBufferGetWidthOfPlane(pb, 1), CVPixelBufferGetHeightOfPlane(pb, 1), 1, &c)
            guard y != nil, c != nil else { return }
            texture = y; chromaTexture = c
            // The movie's matrix; without one, SD (below 720 lines) is BT.601 and the rest BT.709.
            let m = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
            if m == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
                yuvMatrix = 2
            } else if m == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
                yuvMatrix = 3
            } else if m == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
                        || m == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String) {   // 240M is close to 709
                yuvMatrix = 1
            } else {
                yuvMatrix = h < 720 ? 2 : 1
            }
        } else {
            var tex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, gpu.cache, pb, nil, .bgra8Unorm, w, h, 0, &tex)
            guard tex != nil else { return }
            texture = tex; chromaTexture = nil; yuvMatrix = 0
        }
    }

    var mtlTexture: MTLTexture? { texture.flatMap { CVMetalTextureGetTexture($0) } }
    var mtlChroma: MTLTexture? { chromaTexture.flatMap { CVMetalTextureGetTexture($0) } }
}

/// Draws an output's layers into one MTKView (an output window or the preview).
final class OutputRenderer: NSObject, MTKViewDelegate {
    /// Supplied by the controller: the layers to draw (back to front) and each clip's frames.
    var layers: () -> [Layer] = { [] }
    var frames: (String) -> FrameSource? = { _ in nil }
    private(set) var viewAspect = 16.0 / 9.0
    /// Frames drawn in the last full second (load check).
    private(set) var drawRate = 0.0
    private var drawCount = 0
    private var drawSince = CACurrentMediaTime()

    private struct Key: Equatable { var look: DisplaySettings; var view: Double; var video: Double }
    private var buffers: [String: (key: Key, buf: MTLBuffer)] = [:]

    init?(view: MTKView, fps: Int) {
        guard let gpu = GPU.shared else { return nil }
        super.init()
        view.device = gpu.device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
        view.preferredFramesPerSecond = fps
        let s = view.drawableSize
        if s.height > 0 { viewAspect = Double(s.width / s.height) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.height > 0 { viewAspect = Double(size.width / size.height) }
    }

    private func buffer(for l: Layer, video: Double) -> MTLBuffer? {
        let k = Key(look: l.look, view: viewAspect, video: video)
        if let c = buffers[l.id], c.key == k { return c.buf }
        guard let b = GPU.shared?.vertices(l.look, viewAspect: viewAspect, videoAspect: video) else { return nil }
        buffers[l.id] = (k, b)
        return b
    }

    func draw(in view: MTKView) {
        guard let gpu = GPU.shared, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = gpu.queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let now = CACurrentMediaTime()
        drawCount += 1
        if now - drawSince >= 1 { drawRate = Double(drawCount) / (now - drawSince); drawCount = 0; drawSince = now }
        let ls = layers().filter { $0.visible && $0.opacity > 0 }
        var keep: [CVMetalTexture] = []
        enc.setRenderPipelineState(gpu.pipeline)
        for l in ls {
            let fs = frames(l.clipID)
            fs?.fetch(now: now)
            guard let vb = buffer(for: l, video: fs?.aspect ?? 0) else { continue }
            let tex = fs?.mtlTexture
            let chroma = fs?.mtlChroma
            if let t = fs?.texture { keep.append(t) }
            if let t = fs?.chromaTexture { keep.append(t) }
            let s = l.look
            var u: [Float] = [Float(s.cropL), Float(s.cropR), Float(s.cropT), Float(s.cropB),
                              Float(s.blendL), Float(s.blendR), Float(s.blendT), Float(s.blendB),
                              Float(s.blendGamma), s.showGrid ? 1 : 0, tex == nil ? 0 : 1, Float(l.opacity),
                              chroma == nil ? 0 : (fs?.yuvMatrix ?? 0), 0, 0, 0]
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentBytes(&u, length: u.count * 4, index: 0)
            enc.setFragmentTexture(tex ?? gpu.blank, index: 0)
            enc.setFragmentTexture(chroma ?? gpu.blank, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: gpu.indexCount, indexType: .uint32,
                                      indexBuffer: gpu.indexBuffer, indexBufferOffset: 0)
        }
        enc.endEncoding()
        if buffers.count > ls.count + 4 {
            let ids = Set(ls.map(\.id))
            buffers = buffers.filter { ids.contains($0.key) }
        }
        cb.addCompletedHandler { _ in _ = keep }
        cb.present(drawable)
        cb.commit()
    }
}
