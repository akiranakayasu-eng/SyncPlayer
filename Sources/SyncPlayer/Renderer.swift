import Foundation
import MetalKit
import AVFoundation
import CoreVideo

/// Draws the playing picture with Metal: a fine grid of triangles carries the corner pin,
/// mesh warp and content transform; the fragment shader does crop, edge blend and the test grid.
/// Timing is untouched: the frame for "now" is taken from the active player's video output.
final class VideoRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var indexCount = 0
    private var dirty = true
    private var currentTexture: CVMetalTexture?
    private var blank: MTLTexture?
    private let N = 48   // grid subdivisions

    weak var node: SyncNode?
    var settings = DisplaySettings() { didSet { if settings != oldValue { dirty = true } } }
    private(set) var viewAspect = 16.0 / 9.0
    private(set) var videoAspect = 0.0 { didSet { if videoAspect != oldValue { dirty = true; onVideoAspect?() } } }
    var onVideoAspect: (() -> Void)?

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; float2 uv; float2 outPos; };
    struct U { float4 crop; float4 blend; float gamma; float grid; float hasTex; float pad; };

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
        // crop: x=L y=R z=T w=B (uv y points up)
        if (uv.x < u.crop.x || uv.x > 1.0 - u.crop.y || uv.y > 1.0 - u.crop.z || uv.y < u.crop.w) {
            return float4(0, 0, 0, 1);
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
        return float4(c.rgb * f, 1.0);
    }
    """

    init?(view: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev
        queue = q
        do {
            let lib = try dev.makeLibrary(source: VideoRenderer.shader, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("Metal setup failed: \(error)")
            return nil
        }
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        blank = dev.makeTexture(descriptor: td)
        super.init()
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = self
        view.preferredFramesPerSecond = 120
        let s = view.drawableSize
        if s.height > 0 { viewAspect = Double(s.width / s.height) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.height > 0 { viewAspect = Double(size.width / size.height); dirty = true }
    }

    private func rebuild() {
        let s = settings
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
        var idx: [UInt32] = []
        idx.reserveCapacity(N * N * 6)
        for j in 0..<N {
            for i in 0..<N {
                let a = UInt32(j * (N + 1) + i), b = a + 1, c = a + UInt32(N + 1), d = c + 1
                idx += [a, b, d, a, d, c]
            }
        }
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD4<Float>>.stride)
        indexBuffer = device.makeBuffer(bytes: idx, length: idx.count * 4)
        indexCount = idx.count
        dirty = false
    }

    private func fetchFrame() {
        guard let node, let cache else { return }
        let out = node.outputs[node.active]
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard out.hasNewPixelBuffer(forItemTime: t),
              let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if h > 0 { videoAspect = Double(w) / Double(h) }
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &tex)
        if tex != nil { currentTexture = tex }
    }

    func draw(in view: MTKView) {
        fetchFrame()
        if dirty { rebuild() }
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd),
              let vb = vertexBuffer, let ib = indexBuffer else { return }
        let s = settings
        var u: [Float] = [Float(s.cropL), Float(s.cropR), Float(s.cropT), Float(s.cropB),
                          Float(s.blendL), Float(s.blendR), Float(s.blendT), Float(s.blendB),
                          Float(s.blendGamma), s.showGrid ? 1 : 0, 0, 0]
        let texture = currentTexture.flatMap { CVMetalTextureGetTexture($0) }
        u[10] = texture == nil ? 0 : 1
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        enc.setFragmentBytes(&u, length: u.count * 4, index: 0)
        enc.setFragmentTexture(texture ?? blank, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                  indexBuffer: ib, indexBufferOffset: 0)
        enc.endEncoding()
        let keep = currentTexture
        cb.addCompletedHandler { _ in _ = keep }
        cb.present(drawable)
        cb.commit()
    }
}
