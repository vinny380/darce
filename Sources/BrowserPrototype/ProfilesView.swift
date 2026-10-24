import BrowserCore
import SwiftUI

struct ProfilesView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var editingProfile: UUID?
    @State private var editedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Profiles").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }
            Text("Each profile has separate website sign-ins, cookies, history, and Favorites.")
                .foregroundStyle(.secondary)
            List {
                ForEach(model.state.profiles) { profile in
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text(profile.name)
                        Spacer()
                        Button("Rename") { editedName = profile.name; editingProfile = profile.id }
                    }
                }
            }.frame(height: 140)
            HStack {
                TextField("New profile name", text: $name).onSubmit(create)
                Button("Create Profile", action: create).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Space profiles").font(.headline)
            Text("Changing a Space's profile reloads its tabs in the selected profile. Existing website data stays with its original profile.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.state.spaces) { space in
                        HStack {
                            Text(space.name).frame(maxWidth: .infinity, alignment: .leading)
                            Picker("Profile for \(space.name)", selection: Binding(get: { space.profileID }, set: { model.assignProfile($0, to: space.id) })) {
                                ForEach(model.state.profiles) { profile in Text(profile.name).tag(profile.id) }
                            }.labelsHidden().frame(width: 220)
                        }
                    }
                }
            }
        }.padding(24).frame(width: 580, height: 490)
            .alert("Rename Profile", isPresented: Binding(get: { editingProfile != nil }, set: { if !$0 { editingProfile = nil } })) {
                TextField("Name", text: $editedName)
                Button("Save") {
                    if let id = editingProfile { model.stateUpdate { $0.renameProfile(id, name: editedName) } }
                    editingProfile = nil
                }
                Button("Cancel", role: .cancel) { editingProfile = nil }
            }
    }
    private func create() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.addProfile(name)
        name = ""
    }
}
