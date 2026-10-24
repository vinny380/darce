import AppKit
import Foundation
import Metal
import QuartzCore
import ImageIO

public enum ThemeError: Error, Sendable { case unavailable, invalidInput, gpu(String) }

public struct ThemeLayer: Equatable, Sendable {
    public var base: [SIMD4<Float>]
    public var overlay: [SIMD4<Float>]
    public var alpha: Float
    public var underlay: SIMD4<Float>
    public init(base: [SIMD4<Float>], overlay: [SIMD4<Float>] = [], alpha: Float = 1,
                underlay: SIMD4<Float> = .zero) {
        self.base = base; self.overlay = overlay; self.alpha = alpha; self.underlay = underlay
    }
}

/// Caller-owned, premultiplied, non-sRGB texture samples. No proprietary texture assets.
public struct ThemeTexture: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [SIMD4<Float>]
    public init(width: Int, height: Int, pixels: [SIMD4<Float>]) {
        self.width = width; self.height = height; self.pixels = pixels
    }
}

/// Width/height are logical points; scale determines output pixels and overlay resolution.
public struct ThemeFrame: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var scale: Float = 1
    public var layers: [ThemeLayer]
    public var progress: Float = 0
    public var renderCoordinates = SIMD4<Float>(0,0,1,1)
    public var cutout: SIMD4<Float>? = nil
    public var baseAxis: SIMD4<Float>? = nil
    public var overlayFrom: ThemeTexture? = nil
    public var overlayTo: ThemeTexture? = nil
    public var overlayAlphas = SIMD2<Float>(1,1)
    public init(width: Int, height: Int, layers: [ThemeLayer]) {
        self.width = width; self.height = height; self.layers = layers
    }
}

public struct ThemeImage: Sendable {
    public let width: Int
    public let height: Int
    public let halfFloats: [Float16]
    public func pixel(x: Int, y: Int) -> SIMD4<Float> {
        let i = (y * width + x) * 4
        return SIMD4(Float(halfFloats[i]), Float(halfFloats[i+1]), Float(halfFloats[i+2]), Float(halfFloats[i+3]))
    }
    public func writeHalfFloats(to url: URL) throws {
        try halfFloats.withUnsafeBytes { try Data($0).write(to: url) }
    }
    public func writePNG(to url: URL) throws {
        // Inspectable straight-alpha 8-bit export; extended values remain in raw output.
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        for y in 0..<height { for x in 0..<width {
            let p = pixel(x: x,y: y); let i = (y*width+x)*4
            for c in 0..<4 {
                let value = c == 3 ? p.w : (p.w > 0 ? p[c]/p.w : 0)
                bytes[i+c] = UInt8((max(0,min(1,value))*255).rounded())
            }
        }}
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,
                bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
                provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else {
            throw ThemeError.unavailable
        }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw ThemeError.gpu("PNG export failed") }
    }
}

/// Main-actor encoder with a serial Metal command queue and reusable intermediate targets.
@MainActor public final class ThemeRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let gradient: MTLRenderPipelineState
    private let overlay: MTLRenderPipelineState
    private let final: MTLRenderPipelineState
    private var cachedGradient: MTLTexture?
    private var cachedOverlay: MTLTexture?
    private var transparentTexture: MTLTexture?
    public var metalDevice: MTLDevice { device }
    public var deviceName: String { device.name }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ThemeError.unavailable }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            descriptor.colorAttachments[0].isBlendingEnabled = false
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        gradient = try pipeline("gradientVertex", "gradientFragment")
        overlay = try pipeline("quadVertex", "overlayFragment")
        final = try pipeline("displayVertex", "displayFragment")
    }

    private func texture(width: Int, height: Int, shared: Bool = false) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = shared ? .shared : .private
        descriptor.usage = shared ? [.shaderRead] : [.shaderRead, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw ThemeError.unavailable }
        return texture
    }

    private func source(_ input: ThemeTexture?) throws -> MTLTexture {
        if input == nil, let transparentTexture { return transparentTexture }
        let isNull = input == nil
        let input = input ?? ThemeTexture(width: 1, height: 1, pixels: [.zero])
        guard (1...4096).contains(input.width), (1...4096).contains(input.height),
              input.pixels.count == input.width * input.height,
              input.pixels.allSatisfy({ Self.finite($0) && $0.w >= 0 && $0.w <= 1 }) else {
            throw ThemeError.invalidInput
        }
        // Half-float overflow must not silently introduce infinite samples.
        guard input.pixels.allSatisfy({ p in (0..<4).allSatisfy { abs(p[$0]) <= 65504 } }) else { throw ThemeError.invalidInput }
        let tex = try texture(width: input.width, height: input.height, shared: true)
        let values = input.pixels.flatMap { p in (0..<4).map { Float16(p[$0]) } }
        values.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0,0,input.width,input.height), mipmapLevel: 0,
                                            withBytes: $0.baseAddress!, bytesPerRow: input.width*8) }
        if isNull { transparentTexture = tex }
        return tex
    }

    private static func finite(_ v: SIMD4<Float>) -> Bool { (0..<4).allSatisfy { v[$0].isFinite } }
    private static func palette(_ color: SIMD4<Float>) -> SIMD4<Float> {
        func linear(_ c: Float) -> Float {
            abs(c) <= 0.040449999272823334 ? c / 12.920000076293945 :
                (c < 0 ? -1 : 1) * powf((abs(c)+0.054999999701976776)/1.0549999475479126,2.4000000953674316)
        }
        let r = linear(color.x), g = linear(color.y), b = linear(color.z)
        let l = cbrtf(0.4122214615345001*r + 0.5363325476646423*g + 0.05144599452614784*b)
        let m = cbrtf(0.21190349757671356*r + 0.6806995272636414*g + 0.10739696025848389*b)
        let s = cbrtf(0.08830246329307556*r + 0.2817188501358032*g + 0.6299787163734436*b)
        return SIMD4(0.21045425534248352*l + 0.7936177849769592*m - 0.004072046838700771*s,
                     1.9779984951019287*l - 2.4285922050476074*m + 0.4505937099456787*s,
                     0.025904037058353424*l + 0.7827717661857605*m - 0.8086757659912109*s, color.w)
    }

    private struct Submission: @unchecked Sendable {
        let command: MTLCommandBuffer
        let buffer: MTLBuffer?
        let width: Int
        let height: Int
        let rowBytes: Int
    }

    /// Offscreen verification/export only. The mounted path below never waits for completion.
    public func render(_ frame: ThemeFrame) throws -> ThemeImage {
        let submission = try prepare(frame, destination: nil, readback: true)
        submission.command.commit(); submission.command.waitUntilCompleted()
        guard let image = try Self.image(from: submission) else { throw ThemeError.unavailable }
        return image
    }

    public func present(_ frame: ThemeFrame, to drawable: CAMetalDrawable, capture: Bool = false,
                        completion: @escaping @Sendable (Result<ThemeImage?, ThemeError>) -> Void) throws {
        let submission = try prepare(frame, destination: drawable.texture, readback: capture)
        submission.command.addCompletedHandler { _ in
            do { completion(.success(try Self.image(from: submission))) }
            catch let error as ThemeError { completion(.failure(error)) }
            catch { completion(.failure(.gpu(error.localizedDescription))) }
        }
        submission.command.present(drawable)
        submission.command.commit()
    }

    private nonisolated static func image(from submission: Submission) throws -> ThemeImage? {
        guard submission.command.status == .completed else {
            throw ThemeError.gpu(submission.command.error?.localizedDescription ?? "command did not complete")
        }
        guard let buffer = submission.buffer else { return nil }
        var values: [Float16] = []; values.reserveCapacity(submission.width*submission.height*4)
        for row in 0..<submission.height {
            let ptr = buffer.contents().advanced(by: row*submission.rowBytes).assumingMemoryBound(to: Float16.self)
            values.append(contentsOf: UnsafeBufferPointer(start:ptr,count:submission.width*4))
        }
        guard values.allSatisfy({ $0.isFinite }) else { throw ThemeError.gpu("nonfinite output") }
        return ThemeImage(width:submission.width,height:submission.height,halfFloats:values)
    }

    private func prepare(_ frame: ThemeFrame, destination: MTLTexture?, readback: Bool) throws -> Submission {
        guard (1...16384).contains(frame.width), (1...16384).contains(frame.height),
              frame.scale.isFinite, frame.scale >= 0.25, frame.scale <= 4,
              frame.progress.isFinite, (0...1).contains(frame.progress),
              (1...2).contains(frame.layers.count), Self.finite(frame.renderCoordinates),
              frame.renderCoordinates.z > frame.renderCoordinates.x,
              frame.renderCoordinates.w > frame.renderCoordinates.y,
              frame.overlayAlphas.x.isFinite, frame.overlayAlphas.y.isFinite,
              (0...1).contains(frame.overlayAlphas.x), (0...1).contains(frame.overlayAlphas.y) else { throw ThemeError.invalidInput }
        for layer in frame.layers {
            guard (1...2).contains(layer.base.count), layer.overlay.count <= 2,
                  layer.alpha.isFinite, (0...1).contains(layer.alpha), Self.finite(layer.underlay),
                  (0...1).contains(layer.underlay.w), (0..<3).allSatisfy({ abs(layer.underlay[$0]) <= 16 }),
                  (layer.base + layer.overlay).allSatisfy({ p in Self.finite(p) && (0...1).contains(p.w) &&
                      (0..<3).allSatisfy { abs(p[$0]) <= 16 } }) else { throw ThemeError.invalidInput }
        }
        let pixelWidth = Int(Float(frame.width) * frame.scale)
        let pixelHeight = Int(Float(frame.height) * frame.scale)
        guard (1...16384).contains(pixelWidth), (1...16384).contains(pixelHeight),
              pixelWidth * pixelHeight <= 64 * 1024 * 1024 else { throw ThemeError.invalidInput }
        let region = frame.renderCoordinates
        let effective = SIMD2(Float(frame.width)/(region.z-region.x), Float(frame.height)/(region.w-region.y))
        let ratio = effective.x / effective.y
        let axis = frame.baseAxis ?? (ratio > 1 ? SIMD4(0,0.5-0.5/ratio,1,0.5+0.5/ratio) : SIMD4(0.5-0.5*ratio,0,0.5+0.5*ratio,1))
        let axisLength = (axis.z-axis.x)*(axis.z-axis.x) + (axis.w-axis.y)*(axis.w-axis.y)
        guard Self.finite(axis), axisLength.isFinite, axisLength > 0 else { throw ThemeError.invalidInput }
        if let cutout = frame.cutout {
            guard Self.finite(cutout), cutout.z >= cutout.x, cutout.w >= cutout.y else { throw ThemeError.invalidInput }
        }
        let overlaySize = Int(100 * frame.scale)
        let reps = effective * frame.scale / Float(overlaySize)
        guard reps.x.isFinite, reps.y.isFinite else { throw ThemeError.invalidInput }
        let hasOverlay = frame.overlayFrom != nil || frame.overlayTo != nil
        // Own packed float4 ABI; unrelated to the original binary's private structs.
        var uniforms: [SIMD4<Float>] = [axis, SIMD4(0.5,0,0.5,1), region,
            frame.cutout ?? SIMD4(1,1,-1,-1), SIMD4(frame.progress,Float(frame.layers.count),reps.x,reps.y),
            SIMD4(frame.overlayAlphas.x,frame.overlayAlphas.y,hasOverlay ? 1 : 0,0)]
        for layer in frame.layers + (frame.layers.count == 1 ? [frame.layers[0]] : []) {
            var adjustedOverlay = layer.overlay
            if adjustedOverlay.count == 2 && adjustedOverlay[0] == .zero {
                adjustedOverlay[0] = SIMD4(adjustedOverlay[1].x,adjustedOverlay[1].y,adjustedOverlay[1].z,0)
            }
            let base = layer.base.map(Self.palette), overlay = adjustedOverlay.map(Self.palette)
            uniforms += [base[0],base.count == 2 ? base[1] : .zero,
                         overlay.first ?? .zero,overlay.count == 2 ? overlay[1] : .zero,layer.underlay,
                         SIMD4(Float(base.count),Float(overlay.count),layer.alpha,0)]
        }
        let from = try source(frame.overlayFrom), to = try source(frame.overlayTo)
        if cachedGradient == nil { cachedGradient = try texture(width:32,height:32) }
        if cachedOverlay?.width != overlaySize { cachedOverlay = try texture(width:overlaySize,height:overlaySize) }
        guard let gradientTexture = cachedGradient, let overlayTexture = cachedOverlay else { throw ThemeError.unavailable }
        let output = try destination ?? texture(width:pixelWidth,height:pixelHeight)
        guard output.width == pixelWidth, output.height == pixelHeight, output.pixelFormat == .rgba16Float,
              output.device === device else { throw ThemeError.invalidInput }
        guard let command = queue.makeCommandBuffer() else { throw ThemeError.unavailable }
        func encode(_ target: MTLTexture, _ pipeline: MTLRenderPipelineState, _ textures: [MTLTexture]) throws {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw ThemeError.unavailable }
            encoder.setRenderPipelineState(pipeline)
            uniforms.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            for (i,texture) in textures.enumerated() { encoder.setFragmentTexture(texture,index:i) }
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,vertexCount: 4)
            encoder.endEncoding()
        }
        try encode(gradientTexture,gradient,[])
        if hasOverlay { try encode(overlayTexture,overlay,[from,to]) }
        try encode(output,final,[gradientTexture,overlayTexture])
        let rowBytes = ((pixelWidth*8+255)/256)*256
        var buffer: MTLBuffer?
        if readback {
            guard let allocation = device.makeBuffer(length:rowBytes*pixelHeight,options:.storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else { throw ThemeError.unavailable }
            buffer = allocation
            blit.copy(from:output,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                      sourceSize:MTLSize(width:pixelWidth,height:pixelHeight,depth:1),to:allocation,
                      destinationOffset:0,destinationBytesPerRow:rowBytes,destinationBytesPerImage:rowBytes*pixelHeight)
            blit.endEncoding()
        }
        return Submission(command:command,buffer:buffer,width:pixelWidth,height:pixelHeight,rowBytes:rowBytes)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; float2 factors; };
    float2 corner(uint id) { return float2(id / 2, id % 2); }
    Vertex makeQuadVertex(uint id) {
        Vertex v; v.uv = corner(id); v.position = float4(v.uv.x*2-1,1-v.uv.y*2,0,1); v.factors = 0; return v;
    }
    float projection(float2 uv, float4 axis) {
        float2 delta = axis.zw-axis.xy; return clamp(dot(uv-axis.xy,delta)/dot(delta,delta),0.0f,1.0f);
    }
    vertex Vertex gradientVertex(uint id [[vertex_id]], constant float4 *u [[buffer(0)]]) {
        Vertex v = makeQuadVertex(id); v.factors = float2(projection(v.uv,u[0]),projection(v.uv,u[1])); return v;
    }
    vertex Vertex quadVertex(uint id [[vertex_id]]) { return makeQuadVertex(id); }
    vertex Vertex displayVertex(uint id [[vertex_id]], constant float4 *u [[buffer(0)]]) {
        Vertex v = makeQuadVertex(id); v.uv = mix(u[2].xy,u[2].zw,v.uv); return v;
    }
    float3 linearRGB(float3 c) {
        float3 v = float3(c.x+0.3963377773761749f*c.y+0.21580375730991364f*c.z,
                         c.x-0.10556134581565857f*c.y-0.0638541728258133f*c.z,
                         c.x-0.08948417752981186f*c.y-1.2914855480194092f*c.z);
        v = v*v*v;
        return float3(4.076741695404053f*v.x-3.307711601257324f*v.y+0.23096993565559387f*v.z,
                      -1.2684379816055298f*v.x+2.609757423400879f*v.y-0.34131938219070435f*v.z,
                      -0.004196086432784796f*v.x-0.7034186124801636f*v.y+1.7076146602630615f*v.z);
    }
    float3 transfer(float3 c) {
        return select(sign(c)*(1.0549999475479126f*pow(abs(c),float3(0.4166666567325592f))-0.054999999701976776f),
                      c*12.920000076293945f, abs(c)<=0.0031308000907301903f);
    }
    float4 over(float4 foreground, float4 background) {
        float a = foreground.a + background.a*(1-foreground.a);
        return a > 0 ? float4((foreground.rgb*foreground.a + background.rgb*background.a*(1-foreground.a))/a,a) : float4(0);
    }
    float4 layer(constant float4 *u, uint offset, float2 factors) {
        float4 controls = u[offset+5];
        float4 c = controls.x == 1 ? u[offset] : mix(u[offset],u[offset+1],clamp(factors.x*1.3333333730697632f,0.0f,1.0f));
        c = float4(linearRGB(c.rgb),c.a*controls.z);
        if (controls.y > 0) {
            float4 o = controls.y == 1 ? u[offset+2] : mix(u[offset+2],u[offset+3],factors.y);
            c = over(float4(linearRGB(o.rgb),o.a*controls.z),c);
        }
        c.rgb = transfer(c.rgb); return over(c,u[offset+4]);
    }
    fragment float4 gradientFragment(Vertex v [[stage_in]], constant float4 *u [[buffer(0)]]) {
        float4 c = layer(u,6,v.factors);
        if (u[4].y == 2) c = mix(c,layer(u,12,v.factors),u[4].x);
        return float4(c.rgb*c.a,c.a);
    }
    float4 adjusted(float4 value,float alpha) {
        float3 rgb = value.a > 0 ? value.rgb/value.a : value.rgb;
        float a = value.a*alpha; return float4(rgb*a,a);
    }
    fragment float4 overlayFragment(Vertex v [[stage_in]], constant float4 *u [[buffer(0)]],
        texture2d<float> from [[texture(0)]], texture2d<float> to [[texture(1)]]) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::nearest,mip_filter::none);
        return mix(adjusted(from.sample(s,v.uv),u[5].x),adjusted(to.sample(s,v.uv),u[5].y),u[4].x);
    }
    fragment float4 displayFragment(Vertex v [[stage_in]], constant float4 *u [[buffer(0)]],
        texture2d<float> gradient [[texture(0)]], texture2d<float> overlay [[texture(1)]]) {
        if (all(v.uv >= u[3].xy) && all(v.uv <= u[3].zw)) discard_fragment();
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::none);
        float4 g = gradient.sample(s,v.uv);
        if (u[5].z == 0) return g;
        float4 o = overlay.sample(s,fract(v.uv*u[4].zw));
        return (1-o.a)*g + o*(g+(1-g.a));
    }
    """
}
