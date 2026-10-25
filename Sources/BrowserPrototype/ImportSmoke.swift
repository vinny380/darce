import BrowserCore
import Foundation

/// The import's app half: the sidebar, Space looks and history all land, and importing again adds nothing.
@MainActor
func runBrowserImportSmoke() -> [String: Bool] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darce-import-smoke-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = BrowserModel(directory: directory, ephemeralWebsiteData: true)
    var profile = ImportedProfile(key: "arc:Default", name: "Default", directory: nil)
    profile.spaces = [ImportedSpace(key: "arc-space:smoke", name: "Imported", icon: "🚀",
                                    tint: AppearanceColor(red: 0.2, green: 0.4, blue: 0.6),
                                    pinned: [.folder(key: "arc:folder", title: "Reading",
                                                     children: [.tab(key: "arc:pin", title: "Pin", url: URL(string: "https://pin.invalid/")!)])])]
    profile.favorites = [.tab(key: "arc:fav", title: "Favorite", url: URL(string: "https://favorite.invalid/")!)]
    profile.history = [ImportedVisit(url: URL(string: "https://visited.invalid/")!, title: "Visited", visitedAt: Date())]
    let first = model.applyBrowserImport([profile], from: .arc, into: .newProfiles, options: ImportOptions())
    let space = model.state.spaces.first { $0.name == "Imported" }
    let folder = model.state.folders.first { $0.name == "Reading" }
    let looks = space.map { model.appearance.state.space($0.id) }
    let second = model.applyBrowserImport([profile], from: .arc, into: .newProfiles, options: ImportOptions())
    return [
        "import_replaces_fresh_sidebar": model.state.spaces.map(\.name) == ["Imported"],
        "import_space_looks": looks?.icon == "🚀" && looks?.tint == AppearanceColor(red: 0.2, green: 0.4, blue: 0.6),
        "import_folder_collapsed": folder.map { looks?.collapsedFolderIDs.contains($0.id) == true } ?? false,
        "import_history_merged": first.counts["history"] == 1
            && model.history?.search("", profileID: model.state.profiles[0].id).count == 1,
        "import_selects_first_space": model.state.selectedSpaceID == space?.id,
        "import_twice_adds_nothing": second.counts.values.allSatisfy { $0 == 0 },
    ]
}

/// When the session can't be saved (an unreadable session.json puts D'arce in recovery mode), the import must
/// report that nothing came over instead of "Success".
@MainActor
func runUnsavedImportSmoke() -> [String: Bool] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darce-import-unsaved-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? Data("not a session".utf8).write(to: directory.appendingPathComponent("session.json"))
    let model = BrowserModel(directory: directory, ephemeralWebsiteData: true)
    var profile = ImportedProfile(key: "arc:Default", name: "Default", directory: nil)
    profile.spaces = [ImportedSpace(key: "arc-space:unsaved", name: "Unsaved",
                                    pinned: [.tab(key: "arc:unsaved", title: "Pin", url: URL(string: "https://pin.invalid/")!)])]
    let outcome = model.applyBrowserImport([profile], from: .arc, into: .newProfiles, options: ImportOptions())
    return ["unsaved_import_reports_nothing": model.recoveryRequired && outcome.counts.values.allSatisfy { $0 == 0 } && !outcome.skipped.isEmpty]
}

/// Cookies land in the right profile's WebKit store, don't duplicate, and "replace" clears what was there.
@MainActor
func runImportCookiesSmoke() async -> [String: Bool] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darce-import-cookies-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = BrowserModel(directory: directory, ephemeralWebsiteData: true)
    var profile = ImportedProfile(key: "chrome:Default", name: "Me", directory: nil)
    profile.cookieCount = 1
    var outcome = model.applyBrowserImport([profile], from: .chrome, into: .newProfiles, options: ImportOptions())
    guard let profileID = outcome.profileIDs["chrome:Default"] else { return ["import_cookies_profile_mapped": false] }
    let store = model.dataStore(for: profileID).httpCookieStore
    let mine = HTTPCookie(properties: [.domain: "mine.invalid", .path: "/", .name: "mine", .value: "1",
                                       .expires: Date().addingTimeInterval(3_600)])!
    await store.setCookie(mine)
    let imported = ImportedCookie(domain: ".shop.invalid", name: "session", value: "abc", path: "/",
                                  expires: Date().addingTimeInterval(3_600), secure: true, httpOnly: true, sameSite: "lax")
    var keep = ImportOptions()
    keep.replaceCookies = false
    let first = await model.applyImportedCookies(["chrome:Default": [imported]], outcome: &outcome, options: keep)
    _ = await model.applyImportedCookies(["chrome:Default": [imported]], outcome: &outcome, options: keep)
    let afterTwice = await store.allCookies()
    var replace = ImportOptions()
    replace.replaceCookies = true
    _ = await model.applyImportedCookies(["chrome:Default": [imported]], outcome: &outcome, options: replace)
    let afterReplace = await store.allCookies()
    let landed = afterTwice.first { $0.name == "session" }

    // Keeping (not replacing): a cookie D'arce already has wins over the imported one.
    let existing = HTTPCookie(properties: [.domain: ".keep.invalid", .path: "/", .name: "account", .value: "A",
                                           .expires: Date().addingTimeInterval(3_600)])!
    await store.setCookie(existing)
    let other = ImportedCookie(domain: ".keep.invalid", name: "account", value: "B", path: "/",
                               expires: Date().addingTimeInterval(3_600), secure: false, httpOnly: false, sameSite: nil)
    _ = await model.applyImportedCookies(["chrome:Default": [other]], outcome: &outcome, options: keep)
    let kept = await store.allCookies().first { $0.name == "account" }?.value

    // Replacing: two source profiles into one D'arce profile clear it once, and an empty list clears nothing.
    var shared = outcome
    shared.profileIDs["chrome:Profile 1"] = profileID
    let second = ImportedCookie(domain: ".second.invalid", name: "second", value: "2", path: "/",
                                expires: Date().addingTimeInterval(3_600), secure: false, httpOnly: false, sameSite: nil)
    _ = await model.applyImportedCookies(["chrome:Default": [imported], "chrome:Profile 1": [second]], outcome: &shared, options: replace)
    let both = await store.allCookies()
    _ = await model.applyImportedCookies(["chrome:Default": []], outcome: &shared, options: replace)
    let afterEmpty = await store.allCookies()
    return [
        "import_keep_mode_existing_cookie_wins": kept == "A",
        "import_replace_clears_each_store_once": both.contains { $0.name == "session" } && both.contains { $0.name == "second" },
        "import_replace_with_nothing_clears_nothing": afterEmpty.contains { $0.name == "second" },
        "import_cookies_land_in_profile_store": first == 1 && landed?.value == "abc" && landed?.isHTTPOnly == true
            && landed?.isSecure == true && landed?.sameSitePolicy == .sameSiteLax,
        "import_cookies_twice_no_duplicates": afterTwice.filter { $0.name == "session" }.count == 1 && afterTwice.contains { $0.name == "mine" },
        "import_replace_clears_existing_cookies": !afterReplace.contains { $0.name == "mine" } && afterReplace.contains { $0.name == "session" },
    ]
}

/// A denied keychain prompt costs only the cookies: the sidebar is already in, and the reason is listed.
@MainActor
func runDeniedKeychainSmoke() async -> [String: Bool] {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("darce-import-denied-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = BrowserModel(directory: directory, ephemeralWebsiteData: true)
    var profile = ImportedProfile(key: "chrome:Default", name: "Me", directory: directory)
    profile.cookieCount = 3
    profile.bookmarks = [.tab(key: "chrome:Default:bm:1", title: "Kept", url: URL(string: "https://kept.invalid/")!)]
    let outcome = model.applyBrowserImport([profile], from: .chrome, into: .newProfiles, options: ImportOptions())
    let finished = await model.completeBrowserImport([profile], from: .chrome, options: ImportOptions(), outcome: outcome) {
        throw SafeStorage.KeychainError.denied
    }
    return ["import_denied_keychain_still_imports_rest": model.state.tabs.contains { $0.title == "Kept" }
        && finished.skipped.contains { $0.hasPrefix("Cookies: you didn't allow") } && finished.counts["cookies", default: 0] == 0]
}

/// Ticking extensions in the import sheet is the consent: they install with no alert, from the source browser's files
/// when the Web Store has no package.
@MainActor
func runImportExtensionSmoke() async -> [String: Bool] {
    guard #available(macOS 15.4, *), let manager = ExtensionManager.shared else { return ["import_extension_from_files_without_prompt": true] }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("darce-import-ext-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["manifest_version": 3, "name": "Import Fixture", "version": "1.0"]
    try? JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
    let id = "pppppppppppppppppppppppppppppppp"
    var options = ImportOptions()
    options.excludedExtensionIDs = ["oooooooooooooooooooooooooooooooo"]
    let unticked = ImportedExtension(id: "oooooooooooooooooooooooooooooooo", name: "Unticked", files: folder)
    let result = await manager.installImported(ImportOptions.ticked([ImportedExtension(id: id, name: "Import Fixture", files: folder), unticked],
                                                                    options: options))
    let skippedUnticked = !manager.installed.contains { $0.id == unticked.id }
    let installed = manager.installed.first { $0.id == id }
    if let installed { manager.uninstall(installed) }
    return ["import_extension_from_files_without_prompt": result.installed == 1 && installed != nil && result.skipped.isEmpty,
            "import_extension_unticked_not_installed": skippedUnticked]
}
