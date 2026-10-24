import BrowserCore
import SwiftUI

struct BrowsingDataView: View {
    @ObservedObject var controller: BrowsingDataController
    let profileID: UUID
    let profileName: String
    @Environment(\.dismiss) private var dismiss
    @State private var categories: Set<BrowsingDataCategory> = [.cookies, .cache, .siteStorage]
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Clear Browsing Data").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(controller.isClearing)
            }
            Text("Profile: \(profileName)").font(.headline)
            Text("Choose which saved data to remove from this profile. This clears data from all time.")
                .foregroundStyle(.secondary)
            ForEach(BrowsingDataCategory.allCases, id: \.self) { category in
                Toggle(isOn: Binding(get: { categories.contains(category) }, set: { selected in
                    if selected { categories.insert(category) } else { categories.remove(category) }
                })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category.title)
                        Text(detail(category)).font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(controller.isClearing)
            }
            if controller.lastProfileID == profileID {
                if let error = controller.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let complete = controller.completionMessage { Label(complete, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
            }
            HStack {
                if controller.isClearing { ProgressView().controlSize(.small); Text("Clearing…").foregroundStyle(.secondary) }
                Spacer()
                Button("Clear Selected Data…", role: .destructive) { confirming = true }
                    .disabled(categories.isEmpty || controller.isClearing)
            }
        }
        .padding(24).frame(width: 540)
        .interactiveDismissDisabled(controller.isClearing)
        .confirmationDialog("Clear data for “\(profileName)”?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Clear Data", role: .destructive) {
                let request = BrowsingDataRequest(profileID: profileID, categories: categories)
                Task { @MainActor in _ = await controller.clear(request) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes \(selectedNames)." +
                 (categories.contains(.cookies) ? " You may be signed out of websites in this profile." : "") +
                 (BrowsingDataRequest(profileID: profileID, categories: categories).requiresRendererReset ? " Open pages in this profile will reload." : ""))
        }
    }

    private var selectedNames: String {
        BrowsingDataCategory.allCases.filter { categories.contains($0) }.map { $0.title.lowercased() }.joined(separator: ", ")
    }

    private func detail(_ category: BrowsingDataCategory) -> String {
        switch category {
        case .cookies: "Removes saved website sign-ins and session cookies."
        case .cache: "Removes cached page resources and fetch caches."
        case .siteStorage: "Removes local storage, databases, offline files, and service workers."
        case .history: "Removes visits recorded in this profile's History."
        }
    }
}
