import Foundation
import MetalKit
import AVFoundation
import CoreVideo

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
    struct U { float4 crop; float4 blend; float gamma; float grid; float hasTex; float opacity; };

    vertex Out vmain(uint vid [[vertex_id]], const device float4* v [[buffer(0)]]) {
        Out o;
        float2 p = v[vid].xy;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = v[vid].zw;
        o.outPos = p;
        return o;
    }

    fragment float4 fmain(Out in [[stage_in]], texture2d<float> tex [[texture(0)]], constant U& u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 uv = in.uv;
        // crop: x=L y=R z=T w=B (uv y points up). Cropped parts show what is behind.
        if (uv.x < u.crop.x || uv.x > 1.0 - u.crop.y || uv.y > 1.0 - u.crop.z || uv.y < u.crop.w) {
            discard_fragment();
        }
        float4 c = u.hasTex > 0.5 ? tex.sample(s, float2(uv.x, 1.0 - uv.y)) : float4(0.1, 0.1, 0.1, 1);
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
    private(set) var texture: CVMetalTexture?
    private(set) var aspect = 0.0

    init(node: SyncNode) { self.node = node }

    func fetch(now: Double) {
        guard let gpu = GPU.shared else { return }
        let out = node.outputs[node.displayIndex(atLocal: now)]
        let t = out.itemTime(forHostTime: now)
        guard out.hasNewPixelBuffer(forItemTime: t),
              let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if h > 0 { aspect = Double(w) / Double(h) }
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, gpu.cache, pb, nil, .bgra8Unorm, w, h, 0, &tex)
        if tex != nil { texture = tex }
    }

    var mtlTexture: MTLTexture? { texture.flatMap { CVMetalTextureGetTexture($0) } }
}

/// Draws an output's layers into one MTKView (an output window or the preview).
final class OutputRenderer: NSObject, MTKViewDelegate {
    /// Supplied by the controller: the layers to draw (back to front) and each clip's frames.
    var layers: () -> [Layer] = { [] }
    var frames: (String) -> FrameSource? = { _ in nil }
    private(set) var viewAspect = 16.0 / 9.0

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
        let ls = layers().filter { $0.visible && $0.opacity > 0 }
        var keep: [CVMetalTexture] = []
        enc.setRenderPipelineState(gpu.pipeline)
        for l in ls {
            let fs = frames(l.clipID)
            fs?.fetch(now: now)
            guard let vb = buffer(for: l, video: fs?.aspect ?? 0) else { continue }
            let tex = fs?.mtlTexture
            if let t = fs?.texture { keep.append(t) }
            let s = l.look
            var u: [Float] = [Float(s.cropL), Float(s.cropR), Float(s.cropT), Float(s.cropB),
                              Float(s.blendL), Float(s.blendR), Float(s.blendT), Float(s.blendB),
                              Float(s.blendGamma), s.showGrid ? 1 : 0, tex == nil ? 0 : 1, Float(l.opacity)]
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setFragmentBytes(&u, length: u.count * 4, index: 0)
            enc.setFragmentTexture(tex ?? gpu.blank, index: 0)
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
