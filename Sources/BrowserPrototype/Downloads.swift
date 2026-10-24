import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
import WebKit

enum DownloadStatus: String, Codable {
    case downloading, pausing, paused, resuming, completed, cancelled, failed
}

struct DownloadRecord: Identifiable, Codable {
    let id: UUID
    let profileID: UUID
    let sourceURL: URL?
    let createdAt: Date
    var filename: String
    var status: DownloadStatus
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64 = 0
    var destinationURL: URL?
    var error: String?
    var canResume = false
    var readyToSave = false
    fileprivate var stagingFilename: String?
}

@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var errorMessage: String?
    private(set) var recoveryRequired = false
    private let directory: URL
    private let downloadsDirectory: URL
    private var downloads: [UUID: WKDownload] = [:]
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var resumeWebViews: [UUID: WKWebView] = [:]
    private let files = FileManager.default
    private var metadataURL: URL { directory.appendingPathComponent("records.json") }

    init(directory: URL, downloadsDirectory: URL? = nil) {
        self.directory = directory.appendingPathComponent("downloads", isDirectory: true)
        self.downloadsDirectory = downloadsDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        super.init()
        do {
            if files.fileExists(atPath: metadataURL.path) {
                records = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: metadataURL))
                guard Set(records.map(\.id)).count == records.count,
                      records.allSatisfy({ $0.filename == Self.safeFilename($0.filename) &&
                          ($0.stagingFilename == nil || $0.stagingFilename == Self.safeFilename($0.stagingFilename!)) &&
                          ($0.destinationURL == nil || $0.destinationURL?.isFileURL == true) }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            try privateDirectory(self.directory)
            try privateDirectory(self.directory.appendingPathComponent("resume", isDirectory: true))
            try privateDirectory(self.directory.appendingPathComponent("staging", isDirectory: true))
            for index in records.indices where [.downloading, .pausing, .resuming].contains(records[index].status) {
                let resumable = files.fileExists(atPath: resumeURL(records[index].id).path)
                records[index].status = resumable ? .paused : .failed
                records[index].canResume = resumable
                records[index].error = resumable ? nil : "Download interrupted when the browser closed."
            }
        } catch {
            recoveryRequired = true
            errorMessage = "Downloads could not be loaded. Saving is disabled to preserve the original files. \(error.localizedDescription)"
        }
    }

    func records(for profileID: UUID) -> [DownloadRecord] {
        records.filter { $0.profileID == profileID }.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func accept(download: WKDownload, profileID: UUID) -> UUID? {
        guard !recoveryRequired else { download.cancel(nil); return nil }
        let id = UUID()
        records.append(DownloadRecord(id: id, profileID: profileID, sourceURL: download.originalRequest?.url,
                                      createdAt: Date(), filename: "Download", status: .downloading))
        guard persist() else {
            records.removeAll { $0.id == id }
            download.cancel(nil)
            return nil
        }
        attach(download, id: id)
        return id
    }

    private func attach(_ download: WKDownload, id: UUID) {
        downloads[id] = download
        download.delegate = self
        observations[id] = download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount, expected = progress.totalUnitCount
            Task { @MainActor [weak self] in
                guard let self, let index = self.index(id), self.downloads[id] != nil else { return }
                self.records[index].receivedBytes = max(0, received)
                self.records[index].expectedBytes = max(0, expected)
            }
        }
    }

    func pause(_ id: UUID) {
        guard let index = index(id), records[index].status == .downloading,
              let download = downloads[id] else { return }
        records[index].status = .pausing
        _ = persist()
        download.cancel { [weak self] data in
            guard let self, let index = self.index(id), self.records[index].status == .pausing else { return }
            self.detach(id)
            self.keepResume(data, id: id)
            self.records[index].status = self.records[index].canResume ? .paused : .failed
            if !self.records[index].canResume { self.records[index].error = "This server could not pause the download. Start it again from the page." }
            _ = self.persist()
        }
    }

    func cancel(_ id: UUID) {
        guard !recoveryRequired, let index = index(id), records[index].status != .completed,
              records[index].status != .cancelled else { return }
        records[index].status = .cancelled
        records[index].canResume = false
        records[index].readyToSave = false
        records[index].error = nil
        _ = persist()
        if let download = downloads[id] {
            download.cancel { [weak self] _ in self?.detach(id); self?.removePrivateFiles(id) }
        } else { removePrivateFiles(id) }
    }

    func resume(_ id: UUID, using webView: WKWebView, profileID: UUID) {
        guard !recoveryRequired, let index = index(id), records[index].canResume,
              records[index].profileID == profileID,
              webView.configuration.websiteDataStore.identifier == profileID,
              downloads[id] == nil else { return }
        do {
            let data = try Data(contentsOf: resumeURL(id))
            records[index].status = .resuming
            records[index].error = nil
            guard persist() else { records[index].status = .paused; return }
            resumeWebViews[id] = webView
            webView.resumeDownload(fromResumeData: data) { [weak self] download in
                guard let self, let index = self.index(id), self.records[index].status == .resuming else {
                    download.cancel(nil)
                    return
                }
                self.records[index].status = .downloading
                self.records[index].canResume = false
                self.attach(download, id: id)
                _ = self.persist()
            }
        } catch { fail(id, error: error) }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let id = id(for: download), let index = index(id), !recoveryRequired,
              records[index].status == .downloading else { completionHandler(nil); return }
        do {
            try privateDirectory(stagingDirectory(id))
            records[index].filename = Self.safeFilename(suggestedFilename)
            let name = UUID().uuidString + ".partial"
            records[index].stagingFilename = name
            records[index].expectedBytes = max(0, response.expectedContentLength)
            guard persist() else { completionHandler(nil); return }
            completionHandler(stagingDirectory(id).appendingPathComponent(name))
        } catch { fail(id, error: error); completionHandler(nil) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let id = id(for: download), let index = index(id), records[index].status != .cancelled else { return }
        records[index].receivedBytes = max(records[index].receivedBytes, download.progress.completedUnitCount)
        records[index].readyToSave = true
        records[index].canResume = false
        detach(id)
        _ = persist()
        retrySave(id)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let id = id(for: download), let index = index(id),
              ![.pausing, .cancelled].contains(records[index].status) else { return }
        detach(id)
        keepResume(resumeData, id: id)
        fail(id, error: error)
    }

    func retrySave(_ id: UUID) {
        guard !recoveryRequired, let index = index(id), records[index].readyToSave,
              let name = records[index].stagingFilename else { return }
        let source = stagingDirectory(id).appendingPathComponent(name)
        let temporary = downloadsDirectory.appendingPathComponent(".browser-download-" + UUID().uuidString)
        do {
            try files.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: temporary)
            let filename = records[index].filename
            let extensionPart = (filename as NSString).pathExtension
            let stem = (filename as NSString).deletingPathExtension
            var suffix = 0
            var destination: URL
            while true {
                let candidate = suffix == 0 ? filename : stem + " (\(suffix))" + (extensionPart.isEmpty ? "" : "." + extensionPart)
                destination = downloadsDirectory.appendingPathComponent(candidate)
                let result = temporary.withUnsafeFileSystemRepresentation { from in
                    destination.withUnsafeFileSystemRepresentation { to in
                        renamex_np(from!, to!, UInt32(RENAME_EXCL))
                    }
                }
                if result == 0 { break }
                let failure = errno
                guard failure == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
                suffix += 1
            }
            records[index].destinationURL = destination
            records[index].status = .completed
            records[index].readyToSave = false
            records[index].error = nil
            records[index].receivedBytes = (try? files.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? records[index].receivedBytes
            if persist() { removePrivateFiles(id) }
        } catch {
            try? files.removeItem(at: temporary)
            fail(id, error: error)
        }
    }

    func reveal(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }), let url = record.destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func index(_ id: UUID) -> Int? { records.firstIndex { $0.id == id } }
    private func id(for download: WKDownload) -> UUID? { downloads.first { $0.value === download }?.key }
    private func resumeURL(_ id: UUID) -> URL { directory.appendingPathComponent("resume/\(id.uuidString).data") }
    private func stagingDirectory(_ id: UUID) -> URL { directory.appendingPathComponent("staging/\(id.uuidString)", isDirectory: true) }

    private func detach(_ id: UUID) {
        observations.removeValue(forKey: id)
        downloads.removeValue(forKey: id)?.delegate = nil
        resumeWebViews.removeValue(forKey: id)
    }

    private func keepResume(_ data: Data?, id: UUID) {
        guard let index = index(id) else { return }
        records[index].canResume = false
        guard let data, !data.isEmpty else { try? files.removeItem(at: resumeURL(id)); return }
        do {
            try data.write(to: resumeURL(id), options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resumeURL(id).path)
            records[index].canResume = true
        } catch { errorMessage = "Resume data could not be saved: \(error.localizedDescription)" }
    }

    private func fail(_ id: UUID, error: any Error) {
        guard let index = index(id), records[index].status != .cancelled else { return }
        records[index].status = .failed
        records[index].error = error.localizedDescription
        _ = persist()
    }

    private func removePrivateFiles(_ id: UUID) {
        try? files.removeItem(at: stagingDirectory(id))
        try? files.removeItem(at: resumeURL(id))
    }

    private func privateDirectory(_ url: URL) throws {
        try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    @discardableResult
    private func persist() -> Bool {
        guard !recoveryRequired else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: metadataURL, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
            return true
        } catch {
            errorMessage = "Download history could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    private static func safeFilename(_ suggested: String) -> String {
        let component = suggested.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Download"
        let filtered = String(component.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filtered.isEmpty, filtered != ".", filtered != ".." else { return "Download" }
        // Keep room for collision suffixes within the filesystem's UTF-8 component limit.
        var result = filtered.hasPrefix(".") ? "Download" + filtered : filtered
        while result.utf8.count > 220 { result.removeLast() }
        return result
    }
}

struct DownloadsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: DownloadManager
    let profileID: UUID
    let resume: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Downloads").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error = manager.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if manager.records(for: profileID).isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Files you download in this profile appear here."))
            } else {
                List(manager.records(for: profileID)) { record in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: record.status == .completed ? "doc" : "arrow.down.circle").font(.title2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.destinationURL?.lastPathComponent ?? record.filename).fontWeight(.medium).lineLimit(1)
                            Text(record.sourceURL?.host ?? "Download").font(.caption).foregroundStyle(.secondary)
                            if [.downloading, .pausing, .resuming].contains(record.status) {
                                if record.expectedBytes > 0 {
                                    ProgressView(value: Double(min(record.receivedBytes, record.expectedBytes)), total: Double(record.expectedBytes))
                                } else { ProgressView().controlSize(.small) }
                            }
                            Text(status(record)).font(.caption).foregroundStyle(.secondary)
                            if let error = record.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        }
                        Spacer()
                        if record.status == .downloading { Button("Pause") { manager.pause(record.id) } }
                        if record.canResume && [.paused, .failed].contains(record.status) { Button("Resume") { resume(record.id) } }
                        if record.readyToSave { Button("Retry Save") { manager.retrySave(record.id) } }
                        if record.status == .completed { Button("Show in Finder") { manager.reveal(record.id) } }
                        else if record.status != .cancelled { Button("Cancel") { manager.cancel(record.id) } }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 360)
    }

    private func status(_ record: DownloadRecord) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file)
        if record.status == .downloading && record.expectedBytes > 0 {
            return bytes + " of " + ByteCountFormatter.string(fromByteCount: record.expectedBytes, countStyle: .file)
        }
        return record.status.rawValue.capitalized + " · " + bytes
    }
}
