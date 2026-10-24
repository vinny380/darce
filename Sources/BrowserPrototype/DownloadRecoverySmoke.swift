import Foundation
import WebKit

@MainActor
private func requireDownloadRecovery(_ condition: Bool, _ description: String) throws {
    guard condition else {
        throw NSError(domain: "DownloadRecoverySmoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: description])
    }
}

@MainActor
private func waitForDownloadRecovery(_ description: String, condition: @MainActor () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw NSError(domain: "DownloadRecoverySmoke", code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "Timed out after 20 seconds: " + description])
}

@MainActor
func seedDownloadRecovery(model: BrowserModel, base: URL) async throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let profileID = model.state.selectedProfileID
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = model.dataStore(for: profileID)
    let webView = WKWebView(frame: .zero, configuration: configuration)
    let download = await webView.startDownload(using: URLRequest(url: base.appendingPathComponent("slow")))
    guard let id = model.downloads.accept(download: download, profileID: profileID) else {
        throw NSError(domain: "DownloadRecoverySmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not accept cross-process resume fixture"])
    }
    try await waitForDownloadRecovery("recovery fixture receives partial bytes") {
        (model.downloads.records.first { $0.id == id }?.receivedBytes ?? 0) > 100_000
    }
    model.downloads.pause(id)
    try await waitForDownloadRecovery("recovery fixture pauses") {
        model.downloads.records.first { $0.id == id }?.status == .paused
    }
    let dataDirectory = model.sessionURL.deletingLastPathComponent()
    let resumeURL = dataDirectory.appendingPathComponent("downloads/resume/\(id.uuidString).data")
    let resumeData = try Data(contentsOf: resumeURL)
    try requireDownloadRecovery(!resumeData.isEmpty, "Paused download has no persisted resume bytes")
    let attributes = try FileManager.default.attributesOfItem(atPath: resumeURL.path)
    try requireDownloadRecovery((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Resume bytes are not private to the user")
    checks["paused resume bytes saved privately before restart"] = true
    try Data(id.uuidString.utf8).write(to: dataDirectory.appendingPathComponent("download-recovery-id.txt"), options: .atomic)

    let corruptDirectory = dataDirectory.appendingPathComponent("download-recovery-corrupt", isDirectory: true)
    let corruptMetadata = corruptDirectory.appendingPathComponent("downloads/records.json")
    try FileManager.default.createDirectory(at: corruptMetadata.deletingLastPathComponent(), withIntermediateDirectories: true)
    let originalBytes = Data("{preserve-invalid-download-history".utf8)
    try originalBytes.write(to: corruptMetadata)
    let corruptManager = DownloadManager(directory: corruptDirectory,
                                         downloadsDirectory: corruptDirectory.appendingPathComponent("published"))
    let rejected = await webView.startDownload(using: URLRequest(url: base.appendingPathComponent("download")))
    let rejectedID = corruptManager.accept(download: rejected, profileID: profileID)
    try await Task.sleep(for: .milliseconds(150))
    try requireDownloadRecovery(rejectedID == nil && corruptManager.recoveryRequired &&
                                (try Data(contentsOf: corruptMetadata)) == originalBytes,
                                "Corrupt download metadata was accepted or replaced")
    checks["corrupt metadata rejects real downloads without overwriting bytes"] = true

    let retryDirectory = dataDirectory.appendingPathComponent("download-recovery-retry", isDirectory: true)
    try FileManager.default.createDirectory(at: retryDirectory, withIntermediateDirectories: true)
    let blockedDestination = retryDirectory.appendingPathComponent("sentinel")
    let sentinel = Data("Do not replace this existing file.".utf8)
    try sentinel.write(to: blockedDestination)
    let failingManager = DownloadManager(directory: retryDirectory, downloadsDirectory: blockedDestination)
    let blockedDownload = await webView.startDownload(using: URLRequest(url: base.appendingPathComponent("download")))
    guard let blockedID = failingManager.accept(download: blockedDownload, profileID: profileID) else {
        throw NSError(domain: "DownloadRecoverySmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not accept blocked-destination fixture"])
    }
    try await waitForDownloadRecovery("completed bytes survive blocked publication") {
        failingManager.records.first { $0.id == blockedID }?.readyToSave == true &&
        failingManager.records.first { $0.id == blockedID }?.status == .failed
    }
    let recoveredManager = DownloadManager(directory: retryDirectory,
                                           downloadsDirectory: retryDirectory.appendingPathComponent("published"))
    recoveredManager.retrySave(blockedID)
    guard let finished = recoveredManager.records.first(where: { $0.id == blockedID }),
          let destination = finished.destinationURL else {
        throw NSError(domain: "DownloadRecoverySmoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "Retry Save did not publish retained bytes"])
    }
    let expected = Data(String(repeating: "Native browser download fixture.\n", count: 8192).utf8)
    try requireDownloadRecovery(finished.status == .completed && (try Data(contentsOf: destination)) == expected,
                                "Retry Save changed the completed payload")
    try requireDownloadRecovery(try Data(contentsOf: blockedDestination) == sentinel, "Failed publication overwrote the destination sentinel")
    checks["failed publication retains bytes for retry after manager restart"] = true
    checks["failed publication preserves existing destination file"] = true
    return checks
}

@MainActor
func verifyDownloadRecovery(model: BrowserModel, base: URL) async throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let marker = model.sessionURL.deletingLastPathComponent().appendingPathComponent("download-recovery-id.txt")
    let idText = try String(contentsOf: marker, encoding: .utf8)
    guard let id = UUID(uuidString: idText), let paused = model.downloads.records.first(where: { $0.id == id }),
          paused.status == .paused, paused.canResume else {
        throw NSError(domain: "DownloadRecoverySmoke", code: 6, userInfo: [NSLocalizedDescriptionKey: "Paused download did not survive application restart"])
    }
    checks["paused download identity survives application restart"] = true
    guard let otherProfile = model.state.profiles.first(where: { $0.id != paused.profileID })?.id else {
        throw NSError(domain: "DownloadRecoverySmoke", code: 7, userInfo: [NSLocalizedDescriptionKey: "No alternate profile exists for resume isolation fixture"])
    }
    let wrongConfiguration = WKWebViewConfiguration()
    wrongConfiguration.websiteDataStore = model.dataStore(for: otherProfile)
    let wrongWebView = WKWebView(frame: .zero, configuration: wrongConfiguration)
    // Supply the record's profile label with the wrong actual data store: both must match.
    model.downloads.resume(id, using: wrongWebView, profileID: paused.profileID)
    try await Task.sleep(for: .milliseconds(150))
    let unchanged = model.downloads.records.first { $0.id == id }
    try requireDownloadRecovery(unchanged?.status == .paused && unchanged?.canResume == true &&
                                unchanged?.receivedBytes == paused.receivedBytes,
                                "A download resumed through another profile's cookie store")
    checks["resume rejects a WebView owned by another profile"] = true
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = model.dataStore(for: paused.profileID)
    let webView = WKWebView(frame: .zero, configuration: configuration)
    model.downloads.resume(id, using: webView, profileID: paused.profileID)
    try await waitForDownloadRecovery("download resumes after application restart") {
        model.downloads.records.first { $0.id == id }?.status == .completed
    }
    guard let destination = model.downloads.records.first(where: { $0.id == id })?.destinationURL else {
        throw NSError(domain: "DownloadRecoverySmoke", code: 8, userInfo: [NSLocalizedDescriptionKey: "Resumed record has no published file"])
    }
    let expected = Data((0..<(256 * 32768)).map { UInt8($0 % 256) })
    try requireDownloadRecovery(try Data(contentsOf: destination) == expected, "Cross-process resume changed the payload")
    checks["resumed download after application restart preserves every byte"] = true
    return checks
}
