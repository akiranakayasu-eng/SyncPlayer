//! Drawing with wgpu (Direct3D 12 / Vulkan on Windows), ported from the Mac's Metal renderer
//! (Sources/SyncPlayer/Renderer.swift): every layer is a 49×49 grid warped by its look, drawn back
//! to front with premultiplied alpha; the fragment shader does crop, feather, the Screen's edge
//! blend, the mask image and opacity exactly as the Mac's `fmain`. Presents with vsync (Fifo).
use crate::show::{Blend, Look};
use crate::warp;
use std::sync::Arc;
use wgpu::util::DeviceExt;
use winit::window::Window;

const SHADER: &str = r#"
struct U { crop: vec4f, blend: vec4f, p: vec4f, q: vec4f };
// p = (gamma, hasTex, opacity, mask: 0 none / 1 / 2 inverted), q = (feather, 0, 0, 0)
@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var tex: texture_2d<f32>;
@group(0) @binding(2) var mtex: texture_2d<f32>;
@group(0) @binding(3) var s: sampler;

struct VOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f, @location(1) op: vec2f };

@vertex fn vmain(@location(0) v: vec4f) -> VOut {
    var o: VOut;
    o.pos = vec4f(v.xy * 2.0 - 1.0, 0.0, 1.0);
    o.uv = v.zw;
    o.op = v.xy;
    return o;
}

@fragment fn fmain(i: VOut) -> @location(0) vec4f {
    let uv = i.uv;
    let st = vec2f(uv.x, 1.0 - uv.y);
    let c0 = textureSample(tex, s, st);
    let mk = textureSample(mtex, s, st);
    // crop: x=L y=R z=T w=B (uv y points up). Cropped parts show what is behind.
    if (uv.x < u.crop.x || uv.x > 1.0 - u.crop.y || uv.y > 1.0 - u.crop.z || uv.y < u.crop.w) { discard; }
    var c = vec4f(0.1, 0.1, 0.1, 1.0);
    if (u.p.y > 0.5) { c = vec4f(c0.rgb, 1.0); }
    var f = 1.0;
    let feather = u.q.x;
    if (feather > 0.0) {
        let dx = min(uv.x - u.crop.x, 1.0 - u.crop.y - uv.x);
        let dy = min(uv.y - u.crop.w, 1.0 - u.crop.z - uv.y);
        f *= smoothstep(0.0, feather, dx) * smoothstep(0.0, feather, dy);
    }
    let p = i.op;
    let ig = 1.0 / max(u.p.x, 0.1);
    if (u.blend.x > 0.0) { f *= pow(smoothstep(0.0, 1.0, clamp(p.x / u.blend.x, 0.0, 1.0)), ig); }
    if (u.blend.y > 0.0) { f *= pow(smoothstep(0.0, 1.0, clamp((1.0 - p.x) / u.blend.y, 0.0, 1.0)), ig); }
    if (u.blend.z > 0.0) { f *= pow(smoothstep(0.0, 1.0, clamp((1.0 - p.y) / u.blend.z, 0.0, 1.0)), ig); }
    if (u.blend.w > 0.0) { f *= pow(smoothstep(0.0, 1.0, clamp(p.y / u.blend.w, 0.0, 1.0)), ig); }
    if (u.p.w > 0.5) {
        let m = dot(mk.rgb, vec3f(0.2126, 0.7152, 0.0722));   // premultiplied: clear = black
        f *= select(m, 1.0 - m, u.p.w > 1.5);
    }
    let a = clamp(u.p.z, 0.0, 1.0) * f;
    return vec4f(c.rgb * a, a);
}
"#;

/// One picture on the GPU (a clip's frame, a mask, the status text).
struct Tex { tex: wgpu::Texture, view: wgpu::TextureView, w: u32, h: u32 }

/// What to draw for one layer.
pub struct LayerSpec { pub clip: usize, pub look: Look, pub opacity: f64, pub mask: Option<(u32, u32, Vec<u8>)>, pub mask_invert: bool }

struct LayerGpu {
    spec: LayerSpec,
    ubuf: wgpu::Buffer,
    vbuf: Option<(wgpu::Buffer, (u32, u32, u32, u32))>, // key: view size, video size
    bind: Option<(wgpu::BindGroup, u64)>,               // key: clip texture generation
    mask: Option<Tex>,
}

pub struct Gpu {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    config: wgpu::SurfaceConfiguration,
    pipeline: wgpu::RenderPipeline,
    bgl: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    ibuf: wgpu::Buffer,
    icount: u32,
    blank: Tex,
    clips: Vec<Option<(Tex, u64)>>, // texture and its generation
    tex_gen: u64,
    layers: Vec<LayerGpu>,
    overlay: Option<(Tex, wgpu::Buffer, wgpu::Buffer, wgpu::BindGroup)>,
    pub adapter_name: String,
}

fn make_tex(device: &wgpu::Device, w: u32, h: u32, label: &str) -> Tex {
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
        mip_level_count: 1, sample_count: 1, dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    let view = tex.create_view(&wgpu::TextureViewDescriptor::default());
    Tex { tex, view, w, h }
}

fn upload(queue: &wgpu::Queue, t: &Tex, rgba: &[u8]) {
    queue.write_texture(
        wgpu::TexelCopyTextureInfo { texture: &t.tex, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        rgba,
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(t.w * 4), rows_per_image: Some(t.h) },
        wgpu::Extent3d { width: t.w, height: t.h, depth_or_array_layers: 1 },
    );
}

fn uniforms(look: &Look, blend: &Blend, has_tex: bool, opacity: f64, mask: f32) -> [f32; 16] {
    [look.crop_l as f32, look.crop_r as f32, look.crop_t as f32, look.crop_b as f32,
     blend.l as f32, blend.r as f32, blend.t as f32, blend.b as f32,
     blend.gamma as f32, if has_tex { 1.0 } else { 0.0 }, opacity as f32, mask,
     look.feather as f32, 0.0, 0.0, 0.0]
}

impl Gpu {
    pub fn new(window: Arc<Window>, clips: usize, layers: Vec<LayerSpec>) -> Result<Gpu, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        let surface = instance.create_surface(window.clone()).map_err(|e| format!("surface: {e}"))?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
            apply_limit_buckets: false,
        })).map_err(|e| format!("no GPU adapter: {e}"))?;
        let adapter_name = adapter.get_info().name;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("win-player"),
            required_limits: wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits()),
            ..Default::default()
        })).map_err(|e| format!("GPU device: {e}"))?;
        let caps = surface.get_capabilities(&adapter);
        // Plain (not sRGB) 8-bit, as the Mac's bgra8Unorm: values go to the screen as they are.
        let format = caps.formats.iter().copied().find(|f| *f == wgpu::TextureFormat::Bgra8Unorm)
            .or_else(|| caps.formats.iter().copied().find(|f| !f.is_srgb()))
            .unwrap_or(caps.formats[0]);
        let size = window.inner_size();
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            width: size.width.max(1), height: size.height.max(1),
            present_mode: wgpu::PresentMode::Fifo,
            color_space: wgpu::SurfaceColorSpace::Auto,
            desired_maximum_frame_latency: 1,
            alpha_mode: caps.alpha_modes[0],
            view_formats: vec![],
        };
        surface.configure(&device, &config);

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("layers"), source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });
        let tex_entry = |b| wgpu::BindGroupLayoutEntry {
            binding: b, visibility: wgpu::ShaderStages::FRAGMENT, count: None,
            ty: wgpu::BindingType::Texture { sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2, multisampled: false },
        };
        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("layer"),
            entries: &[
                wgpu::BindGroupLayoutEntry { binding: 0, visibility: wgpu::ShaderStages::FRAGMENT, count: None,
                    ty: wgpu::BindingType::Buffer { ty: wgpu::BufferBindingType::Uniform, has_dynamic_offset: false, min_binding_size: None } },
                tex_entry(1), tex_entry(2),
                wgpu::BindGroupLayoutEntry { binding: 3, visibility: wgpu::ShaderStages::FRAGMENT, count: None,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering) },
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("layer"), bind_group_layouts: &[Some(&bgl)], immediate_size: 0,
        });
        let blend = wgpu::BlendComponent { src_factor: wgpu::BlendFactor::One, dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha, operation: wgpu::BlendOperation::Add };
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("layers"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader, entry_point: Some("vmain"), compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout { array_stride: 16, step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &wgpu::vertex_attr_array![0 => Float32x4] })],
            },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader, entry_point: Some("fmain"), compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState { format, blend: Some(wgpu::BlendState { color: blend, alpha: blend }),
                    write_mask: wgpu::ColorWrites::ALL })],
            }),
            multiview_mask: None,
            cache: None,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear, min_filter: wgpu::FilterMode::Linear, ..Default::default()
        });
        let idx = warp::indices();
        let ibuf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("grid"), contents: bytemuck::cast_slice(&idx), usage: wgpu::BufferUsages::INDEX });
        let blank = make_tex(&device, 1, 1, "blank");
        upload(&queue, &blank, &[0, 0, 0, 255]);
        let layers = layers.into_iter().map(|spec| {
            let mask = spec.mask.as_ref().map(|(w, h, px)| { let t = make_tex(&device, *w, *h, "mask"); upload(&queue, &t, px); t });
            LayerGpu {
                ubuf: device.create_buffer(&wgpu::BufferDescriptor { label: Some("u"), size: 64,
                    usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false }),
                spec, vbuf: None, bind: None, mask,
            }
        }).collect();
        Ok(Gpu { surface, device, queue, config, pipeline, bgl, sampler, ibuf, icount: idx.len() as u32, blank,
            clips: (0..clips).map(|_| None).collect(), tex_gen: 0, layers, overlay: None, adapter_name })
    }

    pub fn resize(&mut self, w: u32, h: u32) {
        if w == 0 || h == 0 { return; }
        self.config.width = w; self.config.height = h;
        self.surface.configure(&self.device, &self.config);
    }

    /// New frame of a clip (w×h RGBA).
    pub fn set_frame(&mut self, clip: usize, w: u32, h: u32, rgba: &[u8]) {
        let fits = matches!(&self.clips[clip], Some((t, _)) if t.w == w && t.h == h);
        if !fits { self.tex_gen += 1; self.clips[clip] = Some((make_tex(&self.device, w, h, "frame"), self.tex_gen)); }
        upload(&self.queue, &self.clips[clip].as_ref().unwrap().0, rgba);
    }

    fn bind_group(&self, tex: &wgpu::TextureView, mask: &wgpu::TextureView, ubuf: &wgpu::Buffer) -> wgpu::BindGroup {
        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("layer"), layout: &self.bgl,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: ubuf.as_entire_binding() },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::TextureView(tex) },
                wgpu::BindGroupEntry { binding: 2, resource: wgpu::BindingResource::TextureView(mask) },
                wgpu::BindGroupEntry { binding: 3, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        })
    }

    /// Status text (w×h RGBA, opaque) at the top left, `None` to hide it.
    pub fn set_overlay(&mut self, img: Option<(u32, u32, Vec<u8>)>) {
        let Some((w, h, px)) = img else { self.overlay = None; return };
        let t = make_tex(&self.device, w, h, "overlay");
        upload(&self.queue, &t, &px);
        let ubuf = self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor { label: Some("u"),
            contents: bytemuck::cast_slice(&uniforms(&Look::default(), &Blend::default(), true, 1.0, 0.0)),
            usage: wgpu::BufferUsages::UNIFORM });
        let bind = self.bind_group(&t.view, &self.blank.view, &ubuf);
        let vbuf = self.device.create_buffer(&wgpu::BufferDescriptor { label: Some("overlay"),
            size: ((warp::N + 1) * (warp::N + 1) * 16) as u64, usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST, mapped_at_creation: false });
        self.overlay = Some((t, ubuf, vbuf, bind));
    }

    pub fn render(&mut self, blend: &Blend) {
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(f) | wgpu::CurrentSurfaceTexture::Suboptimal(f) => f,
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                self.surface.configure(&self.device, &self.config); return;
            }
            _ => return,
        };
        let (vw, vh) = (self.config.width, self.config.height);
        let view_aspect = vw as f64 / vh as f64;
        // Per layer: vertices for this Screen and movie size, uniforms, bind group.
        for k in 0..self.layers.len() {
            let ci = self.layers[k].spec.clip;
            let (tw, th, tgen) = match &self.clips[ci] { Some((t, g)) => (t.w, t.h, *g), None => (0, 0, 0) };
            let key = (vw, vh, tw, th);
            if self.layers[k].vbuf.as_ref().map(|v| v.1) != Some(key) {
                let video = if th > 0 { tw as f64 / th as f64 } else { 0.0 };
                let verts = warp::vertices(&self.layers[k].spec.look, view_aspect, video);
                let b = self.device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("grid"), contents: bytemuck::cast_slice(&verts), usage: wgpu::BufferUsages::VERTEX });
                self.layers[k].vbuf = Some((b, key));
            }
            let l = &self.layers[k];
            let mask_mode = if l.mask.is_some() { if l.spec.mask_invert { 2.0 } else { 1.0 } } else { 0.0 };
            let u = uniforms(&l.spec.look, blend, tw > 0, l.spec.opacity, mask_mode);
            self.queue.write_buffer(&l.ubuf, 0, bytemuck::cast_slice(&u));
            if l.bind.as_ref().map(|b| b.1) != Some(tgen) {
                let tv = self.clips[ci].as_ref().map(|c| &c.0.view).unwrap_or(&self.blank.view);
                let mv = l.mask.as_ref().map(|m| &m.view).unwrap_or(&self.blank.view);
                let bg = self.bind_group(tv, mv, &l.ubuf);
                self.layers[k].bind = Some((bg, tgen));
            }
        }
        if let Some((t, _, vbuf, _)) = &self.overlay {
            // Pixel-exact rectangle 8 px from the top left (Screen coordinates, y up).
            let (x0, x1) = (8.0 / vw as f64, (8 + t.w) as f64 / vw as f64);
            let (y1, y0) = (1.0 - 8.0 / vh as f64, 1.0 - (8 + t.h) as f64 / vh as f64);
            let look = Look { corners: Some([x0, y0, x1, y0, x1, y1, x0, y1]), ..Look::default() };
            let verts = warp::vertices(&look, view_aspect, 0.0);
            self.queue.write_buffer(vbuf, 0, bytemuck::cast_slice(&verts));
        }
        let target = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
        let mut enc = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("frame") });
        {
            let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("layers"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &target, depth_slice: None, resolve_target: None,
                    ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::BLACK), store: wgpu::StoreOp::Store },
                })],
                depth_stencil_attachment: None, timestamp_writes: None, occlusion_query_set: None,
                ..Default::default()
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_index_buffer(self.ibuf.slice(..), wgpu::IndexFormat::Uint32);
            for l in &self.layers {
                if l.spec.opacity <= 0.0 { continue; }
                let (Some((vb, _)), Some((bg, _))) = (&l.vbuf, &l.bind) else { continue };
                pass.set_vertex_buffer(0, vb.slice(..));
                pass.set_bind_group(0, bg, &[]);
                pass.draw_indexed(0..self.icount, 0, 0..1);
            }
            if let Some((_, _, vb, bg)) = &self.overlay {
                pass.set_vertex_buffer(0, vb.slice(..));
                pass.set_bind_group(0, bg, &[]);
                pass.draw_indexed(0..self.icount, 0, 0..1);
            }
        }
        self.queue.submit([enc.finish()]);
        self.queue.present(frame);
    }
}

/// A mask image as premultiplied RGBA (as the Mac draws it into a premultipliedLast context).
pub fn load_mask(path: &std::path::Path) -> Result<(u32, u32, Vec<u8>), String> {
    let img = image::open(path).map_err(|e| format!("mask {}: {e}", path.display()))?.to_rgba8();
    let (w, h) = img.dimensions();
    let mut px = img.into_raw();
    for p in px.chunks_exact_mut(4) {
        let a = p[3] as u32;
        for c in &mut p[..3] { *c = ((*c as u32 * a + 127) / 255) as u8; }
    }
    Ok((w, h, px))
}
