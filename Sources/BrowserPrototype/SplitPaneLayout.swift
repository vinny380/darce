// Failure plan, recorded before implementation:
// - Invalid/nonfinite weights or zero geometry must never create invalid frames.
// - External membership, order, weights, axis or size changes cancel an active
//   resize; a later event from that gesture must not commit stale state.
// - A drag previews adjacent panes only and commits at most once on successful
//   end. Cancellation/disappearance clears preview without a model mutation.
// - One flat UUID-keyed content hierarchy survives resizing and axis changes;
//   renderer identity must not depend on index, geometry or layout orientation.
// Verification belongs to the real native/CEF consumers: retained page state,
// adjacent-only resize, preview geometry, external-change cancellation, AX
// adjustments and exactly one durable resize callback. No mirrored unit tests.

import BrowserCore
import SwiftUI

struct SplitPaneLayout<Content: View>: View {
    let group: BrowserSplitGroup
    let selectedTabID: UUID?
    let title: (UUID) -> String
    let onFocus: (UUID) -> Void
    let onSeparate: (UUID) -> Void
    let onClose: ((UUID) -> Void)?
    let onResize: ([Double]) -> Void
    let onAxis: (BrowserSplitAxis) -> Void
    let onReorder: ([UUID]) -> Void
    let onPreview: ([Double]?) -> Void
    private let content: (UUID) -> Content

    @State private var preview: [Double]?
    @State private var resize: Resize?
    @State private var invalidatedGesture = false
    @GestureState private var gestureInProgress = false

    private let gap: CGFloat = 10
    private let headerHeight: CGFloat = 32

    init(
        group: BrowserSplitGroup,
        selectedTabID: UUID?,
        title: @escaping (UUID) -> String,
        onFocus: @escaping (UUID) -> Void,
        onSeparate: @escaping (UUID) -> Void,
        onClose: ((UUID) -> Void)? = nil,
        onResize: @escaping ([Double]) -> Void,
        onAxis: @escaping (BrowserSplitAxis) -> Void,
        onReorder: @escaping ([UUID]) -> Void,
        onPreview: @escaping ([Double]?) -> Void = { _ in },
        @ViewBuilder content: @escaping (UUID) -> Content
    ) {
        self.group = group
        self.selectedTabID = selectedTabID
        self.title = title
        self.onFocus = onFocus
        self.onSeparate = onSeparate
        self.onClose = onClose
        self.onResize = onResize
        self.onAxis = onAxis
        self.onReorder = onReorder
        self.onPreview = onPreview
        self.content = content
    }

    private struct Signature: Equatable {
        let id: UUID
        let spaceID: UUID
        let tabs: [UUID]
        // Bit patterns compare stably even for malformed NaN input.
        let weights: [UInt64]
        let horizontal: Bool
    }

    private struct Resize {
        let signature: Signature
        let index: Int
        let available: CGFloat
        let weights: [Double]
    }

    private var horizontal: Bool { group.axis == .horizontal }
    private var signature: Signature {
        Signature(id: group.id, spaceID: group.spaceID, tabs: group.tabIDs,
                  weights: group.weights.map(\.bitPattern), horizontal: horizontal)
    }

    private var weights: [Double] {
        let count = group.tabIDs.count
        guard count > 0 else { return [] }
        guard group.weights.count == count,
              group.weights.allSatisfy({ $0.isFinite && $0 > 0 }),
              let largest = group.weights.max(), largest > 0 else {
            return Array(repeating: 1 / Double(count), count: count)
        }
        // Scale first so a finite but extreme input cannot overflow the sum.
        let scaled = group.weights.map { $0 / largest }
        let total = scaled.reduce(0, +)
        return scaled.map { $0 / total }
    }

    private func finiteSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width.isFinite ? max(0, size.width) : 0,
               height: size.height.isFinite ? max(0, size.height) : 0)
    }

    private func available(in size: CGSize) -> CGFloat {
        max(0, (horizontal ? size.width : size.height) - gap * CGFloat(max(0, group.tabIDs.count - 1)))
    }

    private func start(of index: Int, weights: [Double], available: CGFloat) -> CGFloat {
        CGFloat(weights.prefix(index).reduce(0, +)) * available + gap * CGFloat(index)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = finiteSize(geometry.size)
            let available = available(in: size)
            let displayed = preview ?? weights
            ZStack(alignment: .topLeading) {
                // Keep renderer-bearing views in one keyed hierarchy for both axes.
                ForEach(group.tabIDs, id: \.self) { id in
                    if let index = group.tabIDs.firstIndex(of: id), index < displayed.count {
                        let length = available * CGFloat(displayed[index])
                        let offset = start(of: index, weights: displayed, available: available)
                        pane(id)
                            .frame(width: horizontal ? length : size.width,
                                   height: horizontal ? size.height : length)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(selectedTabID == id ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.12),
                                                  lineWidth: selectedTabID == id ? 2 : 1)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                            .offset(x: horizontal ? offset : 0, y: horizontal ? 0 : offset)
                    }
                }
                ForEach(Array(group.tabIDs.dropLast()), id: \.self) { id in
                    if let index = group.tabIDs.firstIndex(of: id), index + 1 < displayed.count {
                        let offset = start(of: index + 1, weights: displayed, available: available) - gap
                        divider(index: index, available: available, displayed: displayed)
                            .frame(width: horizontal ? gap : size.width,
                                   height: horizontal ? size.height : gap)
                            .offset(x: horizontal ? offset : 0, y: horizontal ? 0 : offset)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .onChange(of: size) { _, _ in invalidateResize() }
        }
        .onChange(of: signature) { _, _ in invalidateResize() }
        .onChange(of: gestureInProgress) { _, active in
            if !active { clearResize() }
        }
        .onDisappear { clearResize() }
    }

    private func pane(_ id: UUID) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { onFocus(id) } label: {
                    Text(title(id)).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Focus \(title(id))")
                .accessibilityValue(selectedTabID == id ? "Selected pane" : "Pane")
                Menu {
                    Button("Arrange Horizontally") { invalidateResize(); onAxis(.horizontal) }
                    Button("Arrange Vertically") { invalidateResize(); onAxis(.vertical) }
                    Divider()
                    Button(horizontal ? "Move Left" : "Move Up") { move(id, by: -1) }
                        .disabled(group.tabIDs.first == id)
                    Button(horizontal ? "Move Right" : "Move Down") { move(id, by: 1) }
                        .disabled(group.tabIDs.last == id)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Split options for \(title(id))")
                Button { invalidateResize(); onSeparate(id) } label: {
                    Image(systemName: "arrow.up.right.square").frame(width: 20, height: 24)
                }
                .accessibilityLabel("Separate \(title(id)) from split")
                .help("Separate Tab")
                if let onClose {
                    Button { invalidateResize(); onClose(id) } label: {
                        Image(systemName: "xmark").frame(width: 20, height: 24)
                    }
                    .accessibilityLabel("Close pane \(title(id))")
                    .help("Close Pane")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: headerHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            content(id).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func divider(index: Int, available: CGFloat, displayed: [Double]) -> some View {
        Rectangle().fill(Color.clear)
            .overlay {
                Capsule().fill(Color.primary.opacity(0.22))
                    .frame(width: horizontal ? 3 : 24, height: horizontal ? 24 : 3)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($gestureInProgress) { _, active, _ in active = true }
                    .onChanged { value in
                        updateResize(index: index, available: available, translation: value.translation)
                    }
                    .onEnded { value in
                        finishResize(index: index, available: available, translation: value.translation)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Resize split between \(title(group.tabIDs[index])) and \(title(group.tabIDs[index + 1]))")
            .accessibilityValue("\(Int((displayed[index] * 100).rounded())) percent and \(Int((displayed[index + 1] * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat
                switch direction {
                case .increment: delta = 20
                case .decrement: delta = -20
                @unknown default: return
                }
                invalidateResize()
                guard let adjusted = adjusted(weights, index: index, available: available, delta: delta),
                      adjusted != weights else { return }
                onResize(adjusted)
            }
    }

    private func adjusted(_ original: [Double], index: Int, available: CGFloat, delta: CGFloat) -> [Double]? {
        guard available.isFinite, available > 0, delta.isFinite,
              index >= 0, index + 1 < original.count else { return nil }
        let pair = original[index] + original[index + 1]
        let minimum = min(Double(horizontal ? 220 : 100) / Double(available), pair / 2)
        let first = min(max(original[index] + Double(delta / available), minimum), pair - minimum)
        var result = original
        result[index] = first
        result[index + 1] = pair - first
        return result
    }

    private func updateResize(index: Int, available: CGFloat, translation: CGSize) {
        guard !invalidatedGesture, available > 0 else { return }
        if resize == nil {
            resize = Resize(signature: signature, index: index, available: available, weights: weights)
        }
        guard let resize, resize.signature == signature, resize.index == index,
              resize.available == available else { invalidateResize(); return }
        guard let next = adjusted(resize.weights, index: index, available: available,
                                  delta: horizontal ? translation.width : translation.height) else {
            invalidateResize(); return
        }
        preview = next
        onPreview(next)
    }

    private func finishResize(index: Int, available: CGFloat, translation: CGSize) {
        guard !invalidatedGesture, let resize, resize.signature == signature,
              resize.index == index, resize.available == available,
              let next = adjusted(resize.weights, index: index, available: available,
                                  delta: horizontal ? translation.width : translation.height) else {
            clearResize(); return
        }
        // Clear local ownership before a potentially reentrant model callback.
        self.resize = nil
        preview = nil
        invalidatedGesture = false
        if next != resize.weights { onResize(next) }
        onPreview(nil)
    }

    private func invalidateResize() {
        let hadPreview = preview != nil
        if resize != nil || gestureInProgress { invalidatedGesture = true }
        resize = nil
        preview = nil
        if hadPreview { onPreview(nil) }
    }

    private func clearResize() {
        let hadPreview = preview != nil
        resize = nil
        preview = nil
        invalidatedGesture = false
        if hadPreview { onPreview(nil) }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = group.tabIDs.firstIndex(of: id),
              group.tabIDs.indices.contains(index + offset) else { return }
        invalidateResize()
        var reordered = group.tabIDs
        reordered.swapAt(index, index + offset)
        onReorder(reordered)
    }
}
