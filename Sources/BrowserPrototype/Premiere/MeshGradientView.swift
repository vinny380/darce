import BrowserCore
import MetalKit
import SwiftUI

/// The welcome's moving backdrop: Paper's Mesh Gradient (paper-design/shaders, Apache-2.0), ported to Metal.
/// The shader below is a line-for-line port of `meshGradientFragmentShader` from @paper-design/shaders 0.0.82,
/// with Paper's default "contain" object sizing at scale 1.
struct MeshGradientView: NSViewRepresentable {
    var tint: AppearanceColor

    // Picked in the shader playground (Oct 2026).
    static let speed: Float = 0.29
    static let distortion: Float = 0.33
    static let swirl: Float = 0.46
    static let grainOverlay: Float = 0.15

    struct Stop: Equatable {
        var red: Double, green: Double, blue: Double
        var hex: String { "#" + [red, green, blue].map { String(format: "%02x", Int((min(max($0, 0), 1) * 255).rounded())) }.joined() }
    }

    /// The Space color as four stops, deep to glow: saturated away from grey, then scaled, with a light tint on top.
    static func palette(for tint: AppearanceColor) -> [Stop] {
        let gray = 0.3 * tint.red + 0.59 * tint.green + 0.11 * tint.blue
        let at = { (k: Double) in
            Stop(red: (gray + (tint.red - gray) * 1.45) * k, green: (gray + (tint.green - gray) * 1.45) * k, blue: (gray + (tint.blue - gray) * 1.45) * k)
        }
        let glow = Stop(red: tint.red + (1 - tint.red) * 0.45, green: tint.green + (1 - tint.green) * 0.45, blue: tint.blue + (1 - tint.blue) * 0.45)
        return [at(0.22), at(0.55), at(0.85), glow]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let renderer = MeshGradientRenderer.shared else { return NSView() } // the flat color underneath shows instead
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = MeshGradientRenderer.pixelFormat
        view.preferredFramesPerSecond = 60
        view.layer?.isOpaque = true
        context.coordinator.renderer = renderer
        context.coordinator.target = Self.palette(for: tint)
        context.coordinator.current = context.coordinator.target
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.target = Self.palette(for: tint)
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: MeshGradientRenderer?
        var target: [Stop] = []
        var current: [Stop] = []
        private var elapsed: Double = 0
        private var last = CACurrentMediaTime()

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            let now = CACurrentMediaTime()
            let delta = min(now - last, 0.1)
            last = now
            // ponytail: reduced motion freezes the drift; a Space color change still eases over.
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { elapsed += delta }
            let ease = 1 - exp(-delta / 0.12)
            current = zip(current, target).map { from, to in
                Stop(red: from.red + (to.red - from.red) * ease, green: from.green + (to.green - from.green) * ease, blue: from.blue + (to.blue - from.blue) * ease)
            }
            guard let renderer, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = renderer.queue.makeCommandBuffer() else { return }
            renderer.encode(into: buffer, pass: pass, palette: current, size: view.drawableSize, time: Float(elapsed) * MeshGradientView.speed)
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

@MainActor
final class MeshGradientRenderer {
    static let pixelFormat = MTLPixelFormat.bgra8Unorm // no sRGB conversion, so colors match the browser's canvas
    static let shared = MeshGradientRenderer()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private struct Uniforms {
        var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        var resolution: SIMD2<Float>
        var time: Float
        var distortion: Float
        var swirl: Float
        var grainOverlay: Float
    }

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mesh_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "mesh_fragment")
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    func encode(into buffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, palette: [MeshGradientView.Stop], size: CGSize, time: Float) {
        let stops = palette.map { SIMD4<Float>(Float($0.red), Float($0.green), Float($0.blue), 1) }
        guard stops.count == 4, let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(colors: (stops[0], stops[1], stops[2], stops[3]), resolution: SIMD2(Float(size.width), Float(size.height)),
                                time: time, distortion: MeshGradientView.distortion, swirl: MeshGradientView.swirl, grainOverlay: MeshGradientView.grainOverlay)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// One frame into an offscreen texture, as BGRA pixels; for the smoke check.
    static func renderOffline(palette: [MeshGradientView.Stop], width: Int, height: Int, time: Float) -> [UInt32]? {
        guard let renderer = shared else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor), let buffer = renderer.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        renderer.encode(into: buffer, pass: pass, palette: palette, size: CGSize(width: width, height: height), time: time)
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixels = [UInt32](repeating: 0, count: width * height)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float4 colors[4]; float2 resolution; float time; float distortion; float swirl; float grainOverlay; };
    struct Varyings { float4 position [[position]]; float2 uv; };

    vertex Varyings mesh_vertex(uint id [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
      float2 p = float2((id << 1) & 2, id & 2) * 2.0 - 1.0; // one triangle covering the screen
      Varyings out;
      out.position = float4(p, 0.0, 1.0);
      out.uv = p * 0.5 * (u.resolution / min(u.resolution.x, u.resolution.y)); // Paper's "contain" sizing
      return out;
    }

    float hash21(float2 p) {
      p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
      p += dot(p, p + 19.19);
      return fract(p.x * p.y);
    }

    float2 rotate(float2 uv, float th) { return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv; }

    float valueNoise(float2 st) {
      float2 i = floor(st);
      float2 f = fract(st);
      float a = hash21(i);
      float b = hash21(i + float2(1.0, 0.0));
      float c = hash21(i + float2(0.0, 1.0));
      float d = hash21(i + float2(1.0, 1.0));
      float2 u = f * f * (3.0 - 2.0 * f);
      return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    }

    float2 getPosition(int i, float t) {
      float a = float(i) * .37;
      float b = .6 + fract(float(i) / 3.) * .9;
      float c = .8 + fract(float(i + 1) / 4.);
      return .5 + .5 * float2(sin(t * b + a), cos(t * c + a * 1.5));
    }

    fragment float4 mesh_fragment(Varyings in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
      float2 uv = in.uv + .5;
      float2 grainUV = uv * 1000.;
      float t = .5 * (u.time + 41.5);

      float radius = smoothstep(0., 1., length(uv - .5));
      float center = 1. - radius;
      for (float i = 1.; i <= 2.; i++) {
        uv.x += u.distortion * center / i * sin(t + i * .4 * smoothstep(.0, 1., uv.y)) * cos(.2 * t + i * 2.4 * smoothstep(.0, 1., uv.y));
        uv.y += u.distortion * center / i * cos(t + i * 2. * smoothstep(.0, 1., uv.x));
      }

      float2 uvRotated = rotate(uv - .5, -3. * u.swirl * radius) + .5;

      float3 color = float3(0.);
      float totalWeight = 0.;
      for (int i = 0; i < 4; i++) {
        float dist = pow(length(uvRotated - getPosition(i, t)), 3.5);
        float weight = 1. / (dist + 1e-3);
        color += u.colors[i].rgb * weight;
        totalWeight += weight;
      }
      color /= max(1e-4, totalWeight);

      if (u.grainOverlay > 0.) {
        float grain = valueNoise(rotate(grainUV, 1.) + float2(3.));
        grain = mix(grain, valueNoise(rotate(grainUV, 2.) + float2(-1.)), .5);
        grain = pow(grain, 1.3);
        float grainV = grain * 2. - 1.;
        float strength = pow(u.grainOverlay * abs(grainV), .8);
        color = mix(color, float3(step(0., grainV)), .35 * strength);
      }
      return float4(color, 1.);
    }
    """
}
