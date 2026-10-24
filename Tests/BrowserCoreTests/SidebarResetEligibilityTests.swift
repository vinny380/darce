import Foundation
import Testing
@testable import BrowserCore

@Test(arguments: [TabKind.favorite, .today, .archived])
func sidebarResetRejectsNonPinnedKinds(kind: TabKind) throws {
    let saved = try #require(URL(string: "https://example.com/home"))
    let live = try #require(URL(string: "https://example.com/away"))
    #expect(!SidebarResetEligibility.isEligible(kind: kind, isEditing: false,
                                               savedURL: saved, liveURL: live, canGoBack: true))
}

@Test func sidebarResetRejectsEditingWithOtherwiseEligiblePage() throws {
    let saved = try #require(URL(string: "https://example.com/home"))
    let live = try #require(URL(string: "https://example.com/away"))
    #expect(!SidebarResetEligibility.isEligible(kind: .pinned, isEditing: true,
                                               savedURL: saved, liveURL: live, canGoBack: true))
}

@Test func sidebarResetRequiresBackHistoryDespiteChangedURL() throws {
    let saved = try #require(URL(string: "https://example.com/home"))
    let live = try #require(URL(string: "https://example.com/away"))
    #expect(!SidebarResetEligibility.isEligible(kind: .pinned, isEditing: false,
                                               savedURL: saved, liveURL: live, canGoBack: false))
}

@Test(arguments: [(true, false), (false, true), (true, true)])
func sidebarResetRequiresBothSavedAndLiveURLs(missingSaved: Bool, missingLive: Bool) throws {
    let saved = try #require(URL(string: "https://example.com/home"))
    let live = try #require(URL(string: "https://example.com/away"))
    #expect(!SidebarResetEligibility.isEligible(kind: .pinned, isEditing: false,
                                               savedURL: missingSaved ? nil : saved,
                                               liveURL: missingLive ? nil : live, canGoBack: true))
}

@Test func sidebarResetRejectsRawURLEqualityWithBackHistory() throws {
    let url = try #require(URL(string: "https://example.com/home?q=1#!route"))
    #expect(!SidebarResetEligibility.isEligible(kind: .pinned, isEditing: false,
                                               savedURL: url, liveURL: url, canGoBack: true))
}

@Test(arguments: [
    ("http://www.example.com/Home/", "https://example.com/home"),
    ("https://example.com/home?utm_source=x", "https://example.com/home#section"),
    ("https://example.com/home?flag&empty=", "https://example.com/home"),
    ("https://example.com/home?key=VALUE", "https://example.com/home?key=value"),
])
func sidebarResetRejectsNormalizedEquality(savedString: String, liveString: String) throws {
    let saved = try #require(URL(string: savedString))
    let live = try #require(URL(string: liveString))
    #expect(saved != live)
    #expect(!SidebarResetEligibility.isEligible(kind: .pinned, isEditing: false,
                                               savedURL: saved, liveURL: live, canGoBack: true))
}

@Test(arguments: [
    ("https://example.com/home", "https://example.com/away"),
    ("https://example.com/home?q=one", "https://example.com/home?q=two"),
    ("https://example.com/home#!one", "https://example.com/home#!two"),
    ("https://example.com:443/home", "https://example.com:8443/home"),
])
func sidebarResetAdmitsOrdinaryChangesWithBackHistory(savedString: String, liveString: String) throws {
    let saved = try #require(URL(string: savedString))
    let live = try #require(URL(string: liveString))
    #expect(SidebarResetEligibility.isEligible(kind: .pinned, isEditing: false,
                                              savedURL: saved, liveURL: live, canGoBack: true))
}

@Test(arguments: [
    ("http://www.instagram.com/direct/inbox", "https://instagram.com/direct/t/one"),
    ("HTTPS://WWW.INSTAGRAM.COM/DIRECT/ONE", "https://instagram.com/DiReCt/TWO"),
    ("https://instagram.com/directly/one", "https://instagram.com/direct-two"),
    ("https://instagram.example/direct/one", "https://instagram.example/direct/two"),
    ("instagram.com/direct/one", "instagram.com/direct/two"),
])
func sidebarResetSuppressesDualInstagramDirectPrefixMatches(savedString: String, liveString: String) throws {
    let saved = try #require(URL(string: savedString))
    let live = try #require(URL(string: liveString))
    #expect(saved != live)
    #expect(PinnedURLComparison.normalized(saved) != PinnedURLComparison.normalized(live))
    #expect(!SidebarResetEligibility.isEligible(kind: .pinned, isEditing: false,
                                               savedURL: saved, liveURL: live, canGoBack: true))
}

@Test(arguments: [
    ("https://instagram.com/direct/one", "https://instagram.com/explore"),
    ("https://instagram.com/explore", "https://instagram.com/direct/one"),
    ("https://example.com/home", "https://instagram.com/direct/one"),
    ("https://instagram.com/direct/one", "https://example.com/away"),
    ("https://instagram.com:443/direct/one", "https://instagram.com:443/direct/two"),
    ("ftp://instagram.com/direct/one", "ftp://instagram.com/direct/two"),
    ("https://example.com/instagram.com/direct/one", "https://example.com/instagram.com/direct/two"),
])
func sidebarResetAdmitsWhenTheDualInstagramExceptionDoesNotApply(savedString: String, liveString: String) throws {
    let saved = try #require(URL(string: savedString))
    let live = try #require(URL(string: liveString))
    #expect(SidebarResetEligibility.isEligible(kind: .pinned, isEditing: false,
                                              savedURL: saved, liveURL: live, canGoBack: true))
}

@Test(arguments: [false, true])
func sidebarResetMatchesOriginalAbsoluteStringsInsteadOfNormalizedDecodedPaths(encodedSaved: Bool) throws {
    let encoded = try #require(URL(string: "https://instagram.com/%64irect/one/"))
    let plain = try #require(URL(string: "https://instagram.com/direct/two/"))
    let pattern = #"^(?:https?:\/\/)?(?:www\.)?instagram\.([^:\/\n\?]+)\/direct"#
    #expect(encoded.absoluteString.contains("/%64irect/"))
    #expect(encoded.absoluteString.range(of: pattern, options: [.regularExpression, .caseInsensitive],
                                        range: nil, locale: nil) == nil)
    let normalized = PinnedURLComparison.normalized(encoded)
    #expect(normalized.absoluteString.contains("/direct/"))
    #expect(normalized.absoluteString.range(of: pattern, options: [.regularExpression, .caseInsensitive],
                                           range: nil, locale: nil) != nil)
    #expect(plain.absoluteString.range(of: pattern, options: [.regularExpression, .caseInsensitive],
                                      range: nil, locale: nil) != nil)
    #expect(SidebarResetEligibility.isEligible(kind: .pinned, isEditing: false,
                                              savedURL: encodedSaved ? encoded : plain,
                                              liveURL: encodedSaved ? plain : encoded,
                                              canGoBack: true))
}
