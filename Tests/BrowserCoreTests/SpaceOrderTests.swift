import Foundation
import Testing
@testable import BrowserCore

/// Manage Spaces reorders Spaces; their order is what ⌃1…9 and swiping follow. Each test names the bug it catches.
private func threeSpaces() -> (BrowserState, [UUID]) {
    var state = BrowserState()
    _ = state.addSpace(name: "Third")
    return (state, state.spaces.map(\.id))
}

@Test func movingASpaceReordersOnlyThatSpace() {
    var (state, ids) = threeSpaces()
    state.moveSpace(ids[2], to: 0)
    #expect(state.spaces.map(\.id) == [ids[2], ids[0], ids[1]])
}

@Test func movingPastTheEndClampsToLast() {
    var (state, ids) = threeSpaces()
    state.moveSpace(ids[0], to: 99)
    #expect(state.spaces.map(\.id) == [ids[1], ids[2], ids[0]])
}

@Test func reorderingKeepsTheSelectedSpaceAndItsTabs() {
    var (state, ids) = threeSpaces()
    state.selectSpace(ids[1])
    let tab = state.openTab(url: URL(string: "https://order.invalid/")!)
    state.moveSpace(ids[1], to: 2)
    #expect(state.selectedSpaceID == ids[1])
    #expect(state.tabs.first { $0.id == tab }?.spaceID == ids[1])
}

@Test func unknownSpaceIsANoOp() {
    var (state, _) = threeSpaces()
    let before = state
    state.moveSpace(UUID(), to: 0)
    #expect(state == before)
}

@Test func spaceOrderSurvivesSaving() throws {
    var (state, ids) = threeSpaces()
    state.moveSpace(ids[2], to: 0)
    let reloaded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
    #expect(reloaded.spaces.map(\.id) == [ids[2], ids[0], ids[1]])
}
