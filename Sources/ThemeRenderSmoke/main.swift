import AppKit
import BrowserTheme
import Foundation

@MainActor func run() throws {
guard CommandLine.arguments.count == 2 else { throw ThemeError.invalidInput }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let renderer = try ThemeRenderer()
var checks: [[String: Any]] = []
@MainActor func check(_ name: String, _ actual: SIMD4<Float>, _ expected: SIMD4<Float>, tolerance: Float = 0.003) {
    let error = (0..<4).map { abs(actual[$0] - expected[$0]) }.max()!
    checks.append(["name": name, "pass": error.isFinite && error <= tolerance,
                   "actual": (0..<4).map { actual[$0] }, "expected": (0..<4).map { expected[$0] },
                   "tolerance": tolerance, "maximumError": error])
}
func transfer(_ linear: Float) -> Float {
    linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
}
@MainActor func render(_ name: String, _ frame: ThemeFrame) throws -> ThemeImage {
    let image = try renderer.render(frame)
    try image.writePNG(to: output.appendingPathComponent(name + ".png"))
    try image.writeHalfFloats(to: output.appendingPathComponent(name + ".rgba16f"))
    return image
}
for (name, color) in [("red", SIMD4<Float>(1,0,0,1)), ("green", SIMD4<Float>(0,1,0,1)),
                      ("blue", SIMD4<Float>(0,0,1,1)), ("gray", SIMD4<Float>(0.5,0.5,0.5,1))] {
    let image = try render(name, ThemeFrame(width: 32, height: 32, layers: [ThemeLayer(base: [color])]))
    check("single_" + name, image.pixel(x: 15, y: 15), color)
}
let alpha = try render("alpha", ThemeFrame(width: 32, height: 32, layers: [ThemeLayer(
    base: [SIMD4(1,0,0,1)], alpha: 0.5, underlay: SIMD4(0,0,0,0.25))]))
check("premultiplied_red_over_black", alpha.pixel(x: 15, y: 15), SIMD4(0.5,0,0,0.625))
for (name,color,underlay,value) in [
    ("white_over_black",SIMD4<Float>(1,1,1,1),SIMD4<Float>(0,0,0,0.25),Float(0.5)),
    ("black_over_white",SIMD4<Float>(0,0,0,1),SIMD4<Float>(1,1,1,0.25),Float(0.125))] {
    let image = try render(name,ThemeFrame(width:32,height:32,layers:[ThemeLayer(base:[color],alpha:0.5,underlay:underlay)]))
    check(name,image.pixel(x:15,y:15),SIMD4(value,value,value,0.625))
}
let transparent = try render("transparent", ThemeFrame(width: 32, height: 32,
    layers: [ThemeLayer(base: [.zero])]))
check("defined_transparent", transparent.pixel(x: 15, y: 15), .zero)
let colors = [SIMD4<Float>(0,0,0,1), SIMD4<Float>(1,1,1,1)]
var gradientFrame = ThemeFrame(width: 32, height: 32, layers: [ThemeLayer(base: colors)])
gradientFrame.baseAxis = SIMD4(0,0,1,0)
let gradient = try render("gradient", gradientFrame)
let t: Float = (11.5 / 32) * (4 / 3)
let gray = transfer(t * t * t)
check("triplet_interpolation", gradient.pixel(x: 11, y: 15), SIMD4(gray,gray,gray,1))
check("base_reaches_endpoint_at_three_quarters", gradient.pixel(x: 24, y: 15), SIMD4(1,1,1,1))
gradientFrame.baseAxis = SIMD4(0.25,0.25,0.75,0.75)
let vertexClamp = try render("vertex-clamp", gradientFrame)
let vertexGray = transfer(1 / 27)
check("clamp_at_vertices", vertexClamp.pixel(x: 0, y: 15), SIMD4(vertexGray,vertexGray,vertexGray,1))
let overlayGradient = try render("overlay-gradient", ThemeFrame(width: 32, height: 32, layers: [ThemeLayer(
    base: [SIMD4(1,0,0,1)], overlay: [.zero, SIMD4(0,0,1,1)])]))
let blend: Float = 15.5 / 32
check("overlay_no_four_thirds_linear_alpha", overlayGradient.pixel(x: 15, y: 15), SIMD4(transfer(1-blend),0,transfer(blend),1))
for progress: Float in [0, 0.25, 1] {
    var frame = ThemeFrame(width: 32, height: 32, layers: [ThemeLayer(base: [SIMD4(1,0,0,1)]), ThemeLayer(base: [SIMD4(0,0,1,1)])])
    frame.progress = progress
    let image = try render("transition-\(progress)", frame)
    check("layer_transition_\(progress)", image.pixel(x: 15, y: 15), SIMD4(1-progress,0,progress,1))
}
var alphaTransitionFrame = ThemeFrame(width:32,height:32,layers:[
    ThemeLayer(base:[SIMD4(1,0,0,1)],alpha:0.5),ThemeLayer(base:[SIMD4(0,0,1,1)])])
alphaTransitionFrame.progress = 0.25
let alphaTransition = try render("alpha-transition",alphaTransitionFrame)
check("transition_precedes_premultiplication",alphaTransition.pixel(x:15,y:15),SIMD4(0.46875,0,0.15625,0.625))
var textureFrame = ThemeFrame(width: 32, height: 32, layers: [ThemeLayer(base: [SIMD4(0.5,0.5,0.5,1)])])
textureFrame.overlayFrom = ThemeTexture(width: 1, height: 1, pixels: [SIMD4(0.2,0.1,0.05,0.25)])
textureFrame.overlayTo = textureFrame.overlayFrom
let texture = try render("texture-composition", textureFrame)
check("componentwise_final_composition", texture.pixel(x: 15, y: 15), SIMD4(0.475,0.425,0.4,1))
textureFrame.overlayTo = nil
textureFrame.progress = 1
let textureAbsent = try render("texture-transition-null", textureFrame)
check("null_overlay_transition", textureAbsent.pixel(x: 15, y: 15), SIMD4(0.5,0.5,0.5,1))
var cutoutFrame = ThemeFrame(width: 32, height: 32, layers: [ThemeLayer(base: [SIMD4(1,0,0,1)])])
cutoutFrame.cutout = SIMD4(8.5/32,8.5/32,23.5/32,23.5/32)
let cutout = try render("cutout", cutoutFrame)
for (name,x,y,expected) in [("inside",15,15,SIMD4<Float>.zero), ("lower_edge",8,8,.zero),
                           ("upper_edge",23,23,.zero), ("outside",7,8,SIMD4<Float>(1,0,0,1))] {
    check("cutout_" + name, cutout.pixel(x:x,y:y),expected)
}
// Region cropping uses the full gradient's UVs, rather than regenerating a local gradient.
gradientFrame.baseAxis = SIMD4(0,0,1,0)
gradientFrame.renderCoordinates = SIMD4(0.5,0,1,1)
let cropped = try render("cropped", gradientFrame)
// UV=.7421875 samples texel coordinate23.25: the final pass interpolates
// stored half-float texels23/24, rather than re-evaluating a continuous curve.
let croppedExpected = gradient.pixel(x:23,y:15)*0.75 + gradient.pixel(x:24,y:15)*0.25
check("render_region_crop_linear_sampling", cropped.pixel(x:15,y:15), croppedExpected, tolerance:0.001)
var repeatedFrame = ThemeFrame(width:200,height:32,layers:[ThemeLayer(base:[SIMD4(0.5,0.5,0.5,1)])])
let originalTile = ThemeTexture(width:2,height:1,pixels:[SIMD4(1,1,1,1),SIMD4(0,0,0,1)])
repeatedFrame.overlayFrom = originalTile; repeatedFrame.overlayTo = originalTile
for scale: Float in [1,2] {
    repeatedFrame.scale = scale
    let repeated = try render("repeated-\(scale)", repeatedFrame)
    checks.append(["name":"retina_dimensions_\(scale)","pass":repeated.width == Int(200*scale) && repeated.height == Int(32*scale)])
    for (x,value): (Int,Float) in [(24,0.5),(37,0.5),(62,0),(74,0),(124,0.5),(174,0)] {
        check("repeat_\(scale)_\(x)",repeated.pixel(x:Int(Float(x)*scale),y:16),SIMD4(value,value,value,1))
    }
}
let extended = try render("extended",ThemeFrame(width:32,height:32,layers:[ThemeLayer(base:[SIMD4(1.1,-0.2,0.5,1)])]))
check("extended_srgb_not_clamped",extended.pixel(x:15,y:15),SIMD4(1.1,-0.2,0.5,1))
var invalid: [(String, ThemeFrame)] = []
var bad = cutoutFrame; bad.width = 0; invalid.append(("zero_width",bad))
bad = cutoutFrame; bad.scale = .nan; invalid.append(("nan_scale",bad))
bad = cutoutFrame; bad.baseAxis = SIMD4(0,0,0,0); invalid.append(("degenerate_axis",bad))
bad = cutoutFrame; bad.renderCoordinates = SIMD4(1,0,0,1); invalid.append(("reversed_region",bad))
bad = cutoutFrame; bad.layers[0].base[0].x = .infinity; invalid.append(("nonfinite_color",bad))
for (name,frame) in invalid {
    var rejected = false
    do { _ = try renderer.render(frame) } catch ThemeError.invalidInput { rejected = true }
    checks.append(["name":"reject_"+name,"pass":rejected])
}
// Original illustrative inputs, not a UI screenshot.
for dark in [false,true] {
    let intensity: Float = 0.8
    let alpha = intensity*0.55+0.2
    let underlay = dark ? SIMD4<Float>(0,0,0,min(alpha,0.5)*0.35) : SIMD4<Float>(1,1,1,min(alpha,0.5))
    var showcase = ThemeFrame(width:252,height:640,layers:[ThemeLayer(
        base:[SIMD4(0.68,0.38,0.64,1),SIMD4(0.38,0.48,0.79,1)],
        overlay:[.zero,SIMD4(0.38,0.72,0.64,1)],alpha:alpha,underlay:underlay)])
    showcase.scale = 2
    _ = try render(dark ? "illustration-dark" : "illustration-light",showcase)
}
let pass = checks.allSatisfy { $0["pass"] as? Bool == true }
let report: [String: Any] = ["pass":pass,"device":renderer.deviceName,"checks":checks,
    "scope":"Independent offscreen GPU renderer",
    "pixelFormat":"RGBA16Float", "png":"Clamped sRGB inspection export; raw rgba16f is authoritative"]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("result.json"))
print("Theme GPU checks: \(checks.filter { $0["pass"] as? Bool == true }.count)/\(checks.count); \(output.path)")
exit(pass ? 0 : 1)

}
do { try run() } catch {
    print("Theme fixture failed: \(error)")
    exit(1)
}
