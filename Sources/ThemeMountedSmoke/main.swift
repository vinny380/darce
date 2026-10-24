import AppKit
import BrowserTheme
import Foundation
import QuartzCore

final class DrawableProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var mainThread = false
    var attempts: Int { lock.withLock { count } }
    var usedMainThread: Bool { lock.withLock { mainThread } }
    func acquire(_ layer: CAMetalLayer) -> CAMetalDrawable? {
        let first = lock.withLock { count += 1; mainThread = mainThread || Thread.isMainThread; return count == 1 }
        if first { Thread.sleep(forTimeInterval:0.15); return nil }
        return layer.nextDrawable()
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var checks: [[String: Any]] = []
    let output = URL(fileURLWithPath: CommandLine.arguments[1],isDirectory:true)
    func check(_ name: String,_ pass: Bool) { checks.append(["name":name,"pass":pass]) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await exercise() }
    }
    func wait(_ name: String, until predicate: () -> Bool) async {
        let end = Date().addingTimeInterval(8)
        while !predicate() && Date() < end { try? await Task.sleep(for:.milliseconds(20)) }
        check(name,predicate())
    }
    func exercise() async {
        do {
            try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            let view = ThemeMetalView(captureFrames:true)
            view.frame = NSRect(x:0,y:0,width:252,height:480)
            let host = NSView(frame:view.frame)
            host.addSubview(view)
            let owned = NSWindow(contentRect:NSRect(x:100,y:100,width:252,height:480),
                                 styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            owned.isReleasedWhenClosed = false
            owned.title = "Theme Renderer Verification"
            owned.contentView = host
            window = owned
            view.update(theme:ThemeLayer(base:[SIMD4(1,0,0,1)]))
            owned.orderFront(nil)
            await wait("first_drawable_completed",until:{view.completedFrames > 0 || view.lastError != nil})
            check("first_no_error",view.lastError == nil)
            if let image = view.lastImage {
                try image.writePNG(to:output.appendingPathComponent("mounted-red.png"))
                let pixel = image.pixel(x:image.width/2,y:image.height/2)
                check("same_drawable_red",abs(pixel.x-1)<0.003 && abs(pixel.y)<0.003 && abs(pixel.z)<0.003 && abs(pixel.w-1)<0.003)
                check("backing_dimensions",image.width == Int(252*owned.backingScaleFactor) && image.height == Int(480*owned.backingScaleFactor))
            } else { check("same_drawable_red",false) }
            let before = view.submittedFrames
            for _ in 0..<10 { view.update(theme:ThemeLayer(base:[SIMD4(1,0,0,1)])); view.needsLayout = true }
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for:.milliseconds(150))
            check("unchanged_updates_coalesced",view.submittedFrames == before)
            let completed = view.completedFrames
            view.update(theme:ThemeLayer(base:[SIMD4(0,1,0,1)]))
            view.update(theme:ThemeLayer(base:[SIMD4(0,0,1,1)]))
            await wait("latest_update_completed",until:{view.completedFrames > completed || view.lastError != nil})
            if let image = view.lastImage {
                try image.writePNG(to:output.appendingPathComponent("mounted-blue.png"))
                let pixel = image.pixel(x:image.width/2,y:image.height/2)
                check("latest_update_blue",abs(pixel.x)<0.003 && abs(pixel.y)<0.003 && abs(pixel.z-1)<0.003)
            } else { check("latest_update_blue",false) }
            let resized = view.completedFrames
            view.frame = NSRect(x:0,y:0,width:317,height:240)
            owned.setContentSize(NSSize(width:317,height:240))
            await wait("resize_completed",until:{view.completedFrames > resized || view.lastError != nil})
            check("resize_dimensions",view.lastImage?.width == Int(317*owned.backingScaleFactor) && view.lastImage?.height == Int(240*owned.backingScaleFactor))
            view.removeFromSuperview()
            let detached = view.submittedFrames
            view.update(theme:ThemeLayer(base:[SIMD4(0,1,0,1)]))
            try? await Task.sleep(for:.milliseconds(150))
            check("detached_does_not_submit",view.submittedFrames == detached)
            host.addSubview(view)
            await wait("remount_submits",until:{view.submittedFrames > detached && view.lastImage?.pixel(x:0,y:0).y ?? 0 > 0.99})
            if let image = view.lastImage { try image.writePNG(to:output.appendingPathComponent("mounted-remount.png")) }
            let hiddenCount = view.submittedFrames
            view.isHidden = true
            view.update(theme:ThemeLayer(base:[SIMD4(1,0,0,1)]))
            try? await Task.sleep(for:.milliseconds(80))
            check("hidden_does_not_submit",view.submittedFrames == hiddenCount)
            view.isHidden = false
            await wait("unhide_new_theme",until:{view.submittedFrames > hiddenCount && (view.lastImage?.pixel(x:0,y:0).x ?? 0) > 0.99})
            let wideCount = view.completedFrames
            view.frame = NSRect(x:0,y:0,width:2560,height:24)
            await wait("wide_retina_completed",until:{view.completedFrames > wideCount || view.lastError != nil})
            check("wide_retina_dimensions",view.lastImage?.width == Int(2560*owned.backingScaleFactor))
            view.frame = NSRect(x:0,y:0,width:317,height:240)
            let probe = DrawableProbe()
            let retryView = ThemeMetalView(captureFrames:true,drawableSource:{probe.acquire($0)})
            retryView.frame = NSRect(x:0,y:0,width:64,height:64)
            host.addSubview(retryView)
            retryView.update(theme:ThemeLayer(base:[SIMD4(0,0,1,1)]))
            await wait("same_theme_recovers_after_injected_nil",until:{retryView.completedFrames > 0})
            check("drawable_acquired_off_main",!probe.usedMainThread && probe.attempts >= 2)
            check("retry_error_cleared",retryView.lastError == nil)
            if let image = retryView.lastImage { check("retry_real_drawable_blue",image.pixel(x:0,y:0).z > 0.99) }
            else { check("retry_real_drawable_blue",false) }
            retryView.removeFromSuperview()
            let theme = try ThemePalette.layer(primary:NSColor(displayP3Red:0.68,green:0.38,blue:0.64,alpha:1),
                                              colorCount:3,wheel:.analogous,intensity:0.8,dark:false)
            let paletteCompleted = view.completedFrames
            view.update(theme:theme)
            await wait("palette_drawable_completed",until:{view.completedFrames > paletteCompleted || view.lastError != nil})
            if let image = view.lastImage {
                try image.writePNG(to:output.appendingPathComponent("mounted-palette.png"))
                try image.writeHalfFloats(to:output.appendingPathComponent("mounted-palette.rgba16f"))
                check("palette_has_alpha",image.pixel(x:0,y:0).w > 0 && image.pixel(x:0,y:0).w < 1)
            } else { check("palette_has_alpha",false) }
            check("final_no_error",view.lastError == nil)
        } catch {
            checks.append(["name":"exception","pass":false,"error":String(describing:error)])
        }
        let pass = checks.allSatisfy { $0["pass"] as? Bool == true }
        let record:[String:Any] = ["pass":pass,"checks":checks,
            "scope":"Owned native window and same-command drawable capture; not an OS screenshot"]
        do { try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json")) }
        catch { print(error); exit(1) }
        window?.orderOut(nil); window?.close(); window = nil
        print("Mounted theme checks: \(checks.filter { $0["pass"] as? Bool == true }.count)/\(checks.count)")
        exit(pass ? 0 : 1)
    }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = Delegate()
application.delegate = delegate
application.run()
