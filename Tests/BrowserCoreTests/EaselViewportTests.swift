import CoreGraphics
import Foundation
import Testing
@testable import BrowserCore

/// The infinite canvas: pan anywhere, zoom around the pointer, zoom to fit. Each test names the bug it catches.
private func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }

@Test func screenAndCanvasPositionsRoundTrip() {
    let viewport = EaselViewport(scale: 1.7, offset: CGPoint(x: -240, y: 95))
    let point = CGPoint(x: 312, y: -48)
    #expect(close(viewport.toCanvas(viewport.toView(point)), point))
}

@Test func zoomingKeepsThePointUnderThePointerStill() {
    var viewport = EaselViewport(scale: 1, offset: CGPoint(x: 40, y: 20))
    let pointer = CGPoint(x: 500, y: 300)
    let under = viewport.toCanvas(pointer)
    viewport.zoom(by: 2.5, around: pointer)
    #expect(viewport.scale == 2.5)
    #expect(close(viewport.toView(under), pointer))
}

@Test func zoomStopsAtSensibleLimits() {
    var viewport = EaselViewport()
    viewport.zoom(by: 1000, around: .zero)
    #expect(viewport.scale == EaselViewport.maxScale)
    viewport.zoom(by: 0.00001, around: .zero)
    #expect(viewport.scale == EaselViewport.minScale)
}

@Test func panningMovesTheCanvasWithTheFingers() {
    var viewport = EaselViewport(scale: 2, offset: .zero)
    let before = viewport.toCanvas(CGPoint(x: 100, y: 100))
    viewport.pan(by: CGSize(width: -60, height: 30))
    #expect(close(viewport.toCanvas(CGPoint(x: 40, y: 130)), before))
}

@Test func zoomToFitShowsEverythingCentredIncludingNegativePositions() {
    var viewport = EaselViewport()
    let content = CGRect(x: -500, y: -200, width: 2000, height: 800)
    let view = CGSize(width: 1000, height: 600)
    viewport.fit(content, in: view, padding: 50)
    let topLeft = viewport.toView(CGPoint(x: content.minX, y: content.minY))
    let bottomRight = viewport.toView(CGPoint(x: content.maxX, y: content.maxY))
    #expect(topLeft.x >= 49.9 && bottomRight.x <= 950.1 && topLeft.y >= 49.9 && bottomRight.y <= 550.1)
    #expect(abs((topLeft.x + bottomRight.x) / 2 - 500) < 0.01)  // centred
}

@Test func fittingAFewSmallItemsDoesNotBlowThemUp() {
    var viewport = EaselViewport()
    viewport.fit(CGRect(x: 0, y: 0, width: 40, height: 40), in: CGSize(width: 1000, height: 800), padding: 50)
    #expect(viewport.scale == 1)  // fit zooms out to show more, never in past 100%
}

@Test func itemsAboveAndLeftOfTheStartAreKept() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var store = try DocumentStore(directory: directory)
    let profile = UUID()
    let easel = try store.create(kind: .easel, title: "", profileID: profile)
    let card = try store.addCard(.shape(.ellipse, color: "#55B948"), documentID: easel, profileID: profile, x: -1200, y: -340, width: 80, height: 80)
    let reloaded = try DocumentStore(directory: directory).document(easel, profileID: profile)?.cards.first { $0.id == card }
    #expect(reloaded?.x == -1200 && reloaded?.y == -340)
}
