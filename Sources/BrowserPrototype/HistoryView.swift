import AppKit
import BrowserCore
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var confirmingClear = false

    private var groups: [HistoryGroup] {
        model.history?.groups(matching: query, profileID: model.state.selectedProfileID) ?? []
    }
    private var profileName: String {
        model.state.profiles.first { $0.id == model.state.selectedProfileID }?.name ?? "Current Profile"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History").font(.title2.weight(.semibold))
                    Text(profileName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear History…") { confirmingClear = true }
                    .disabled(model.history?.search(profileID: model.state.selectedProfileID, limit: 1).isEmpty != false)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            TextField("Search page titles and addresses", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if model.history == nil {
                ContentUnavailableView("History Unavailable", systemImage: "clock.badge.exclamationmark", description: Text("The history file could not be opened. Its existing contents have been preserved."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No History Yet" : "No Matching Pages", systemImage: "clock", description: Text(query.isEmpty ? "Pages visited in this profile appear here." : "Try a different page title or address."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.day) { group in
                        Section(group.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.records) { record in
                                Button {
                                    model.open(record.url)
                                    dismiss()
                                } label: {
                                    HStack(alignment: .center, spacing: 12) {
                                        Image(systemName: "globe").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.title).lineLimit(1).foregroundStyle(.primary)
                                            Text(record.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        Text(record.visitedAt.formatted(date: .omitted, time: .shortened))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 4)
                                }.buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Open in New Tab") { model.open(record.url); dismiss() }
                                        Button("Copy Address") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(record.url.absoluteString, forType: .string)
                                        }
                                        Divider()
                                        Button("Remove from History", role: .destructive) { model.removeHistory(id: record.id) }
                                    }
                            }
                        }
                    }
                }.listStyle(.inset)
            }
            Divider()
            Text("Showing up to 500 recent matching pages in this profile.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
        .frame(width: 680, height: 560)
        .alert("Clear history for \(profileName)?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("This removes all saved page visits in this profile. Other profiles, open tabs, bookmarks, and website data stay unchanged.")
        }
    }
}
