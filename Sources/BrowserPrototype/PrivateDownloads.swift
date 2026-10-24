import AppKit
import WebKit

/// Only an explicit Save As can create a file. No download history or resume data is retained.
@MainActor
final class PrivateDownload: NSObject, WKDownloadDelegate {
    private let download: WKDownload
    private weak var window: NSWindow?
    private let finished: (String?) -> Void
    private var panel: NSSavePanel?
    private var destinationReply: ((URL?) -> Void)?
    private var destination: URL?
    private var stagingDirectory: URL?
    private var done = false

    init(download: WKDownload, window: NSWindow, finished: @escaping (String?) -> Void) {
        self.download = download
        self.window = window
        self.finished = finished
        super.init()
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard !done, let window, window.isVisible, window.attachedSheet == nil else {
            completionHandler(nil)
            complete("Download cancelled because its private window is unavailable or already showing a dialog.")
            return
        }
        destinationReply = completionHandler
        let chooser = NSSavePanel()
        chooser.title = "Save Private Download"
        chooser.message = "This file will remain on your Mac after the private window closes."
        chooser.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent
        chooser.canCreateDirectories = true
        panel = chooser
        chooser.beginSheetModal(for: window) { [weak self] result in
            guard let self, !self.done else { return }
            self.panel = nil
            guard result == .OK, let destination = chooser.url, self.window?.isVisible == true else {
                self.cancel()
                return
            }
            do {
                // Do not replace an existing file implicitly or race another writer at completion.
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw NSError(domain: "PrivateDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a new filename; private downloads do not replace existing files."])
                }
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("private-download-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                self.stagingDirectory = staging
                self.destination = destination
                self.reply(staging.appendingPathComponent("download"))
            } catch {
                self.reply(nil)
                self.download.cancel(nil)
                self.complete(error.localizedDescription)
            }
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !done, let stagingDirectory, let destination else { return }
        do {
            // copyItem refuses overwrites, including a file created after the chooser returned.
            try FileManager.default.copyItem(at: stagingDirectory.appendingPathComponent("download"), to: destination)
            complete(nil)
        } catch { complete("Download could not be saved: \(error.localizedDescription)") }
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        complete("Download failed: \(error.localizedDescription)")
    }

    func cancel() {
        guard !done else { return }
        reply(nil)
        download.cancel(nil)
        complete(nil)
    }

    private func reply(_ url: URL?) {
        let completion = destinationReply
        destinationReply = nil
        completion?(url)
    }

    private func complete(_ error: String?) {
        guard !done else { return }
        done = true
        reply(nil)
        if let panel { panel.cancel(nil) }
        panel = nil
        download.delegate = nil
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
        finished(error)
    }
}
