import BrowserCore
import SwiftUI

/// Arc's Spaces menu: create and edit the current Space, move between Spaces (⌥⌘←/→, ⌃1…9), manage them all.
struct SpacesMenu: Commands {
    @ObservedObject var model: BrowserModel
    @ObservedObject var privateWindows: PrivateBrowserWindows

    private var current: BrowserSpace? { model.state.spaces.first { $0.id == model.state.selectedSpaceID } }

    var body: some Commands {
        CommandMenu("Spaces") {
            Group {
                Button("New Space…") { model.spacePrompt = .new }
                Button("Edit Theme…") { model.panel = .appearance }
                Button("Rename Space") { if let current { model.spacePrompt = .rename(current.id) } }
                Picker("Change Profile", selection: Binding(
                    get: { current?.profileID ?? model.state.selectedProfileID },
                    set: { profile in if let current { model.assignProfile(profile, to: current.id) } })) {
                    ForEach(model.state.profiles) { Text($0.name).tag($0.id) }
                }
                Divider()
                Button("Next Space") { model.cycleSpace(backwards: false) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(model.state.spaces.count < 2)
                Button("Previous Space") { model.cycleSpace(backwards: true) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(model.state.spaces.count < 2)
                Divider()
                ForEach(Array(model.state.spaces.enumerated()), id: \.element.id) { index, space in
                    Toggle(isOn: Binding(get: { space.id == model.state.selectedSpaceID }, set: { _ in model.selectSpace(space.id) })) {
                        Label(space.name, systemImage: model.appearance.state.space(space.id).icon)
                    }
                    .modifier(SpaceNumberKey(index: index))
                }
                Divider()
                Button("Manage Spaces…") { model.panel = .spaces }
            }.disabled(privateWindows.isPrivateWindowActive)
        }
    }
}

/// ⌃1…⌃9 for the first nine Spaces, as in Arc; later Spaces have no key.
private struct SpaceNumberKey: ViewModifier {
    let index: Int
    func body(content: Content) -> some View {
        if index < 9 { content.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .control) } else { content }
    }
}

/// Arc's Space manager: reorder by dragging, rename, pick each Space's profile, remove.
struct ManageSpacesView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Spaces").font(.title2.bold())
                Spacer()
                Button("New Space…") { dismiss(); model.spacePrompt = .new }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Drag to reorder. The order sets ⌃1…9 and swiping between Spaces.").foregroundStyle(.secondary)
            List {
                ForEach(model.state.spaces) { space in row(space) }
                    .onMove { from, to in
                        guard let index = from.first else { return }
                        let id = model.state.spaces[index].id
                        model.stateUpdate { $0.moveSpace(id, to: to > index ? to - 1 : to) }
                    }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .frame(minHeight: 260)
        }
        .padding(22).frame(width: 560, height: 440)
    }

    private func row(_ space: BrowserSpace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: model.appearance.state.space(space.id).icon).frame(width: 20)
            TextField("Name", text: Binding(get: { space.name }, set: { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.stateUpdate { $0.renameSpace(space.id, name: trimmed) } }
            })).textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
            Picker("Profile", selection: Binding(get: { space.profileID }, set: { model.assignProfile($0, to: space.id) })) {
                ForEach(model.state.profiles) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(width: 150)
            Button { remove(space) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove Space")
                .disabled(!model.state.spaces.contains { $0.id != space.id && $0.profileID == space.profileID })
        }.padding(.vertical, 4)
    }

    /// Nothing is deleted: tabs, folders and Favorites move to another Space with the same profile.
    private func remove(_ space: BrowserSpace) {
        guard let destination = model.state.spaces.first(where: { $0.id != space.id && $0.profileID == space.profileID }) else { return }
        let model = model
        dismiss()  // the dialog shows over the browser window, which this sheet would cover
        DialogCenter.shared.present(DialogRequest(
            title: "Remove “\(space.name)”?",
            message: "Its tabs, folders and Favorites will move to \(destination.name). No tabs will be deleted.",
            symbol: "rectangle.stack", actions: [
                .init(title: "Cancel", role: .cancel) {},
                .init(title: "Remove", role: .destructive) { model.stateUpdate { _ = $0.removeSpace(space.id, movingContentsTo: destination.id) } },
            ]), in: model)
    }
}
