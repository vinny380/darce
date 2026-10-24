import Foundation
import Testing
@testable import BrowserCore

@Test func pinnedComparisonLowercasesTheWholeAbsoluteString() throws {
    let input = try #require(URL(string: "HTTP://User:Pass@WWW.Example.COM:80/Case/Path?Key=VaLue#Section"))
    let output = PinnedURLComparison.normalized(input)
    #expect(output.absoluteString == "https://user:pass@example.com:80/case/path?key=value")
    #expect(input.absoluteString.contains("Case/Path"))
}

@Test(arguments: [
    ("example.com/Path", "https://example.com/path"),
    ("//WWW.Example.COM/Path/", "https://example.com/path"),
    ("http://example.com:80/path", "https://example.com:80/path"),
    ("https://example.com:443/path", "https://example.com:443/path"),
    ("ftp://www.example.com:21/Path/", "ftp://example.com:21/path"),
    ("mailto:User@Example.COM", "mailto:user@example.com"),
])
func pinnedComparisonAuthoritySchemeAndPorts(input: String, expected: String) throws {
    let url = try #require(URL(string: input))
    #expect(PinnedURLComparison.normalized(url).absoluteString == expected)
}

@Test(arguments: [
    ("https://www.www.example.com/path", "https://www.example.com/path"),
    ("https://www..example...com./path", "https://example.com/path"),
    ("https://example..com/path", "https://example..com/path"),
    ("https://wwwexample.com/path", "https://wwwexample.com/path"),
])
func pinnedComparisonRemovesOneWWWComponentUsingOmittingEmptySplit(input: String, expected: String) throws {
    let url = try #require(URL(string: input))
    #expect(PinnedURLComparison.normalized(url).absoluteString == expected)
}

@Test(arguments: [
    ("https://example.com/", "https://example.com"),
    ("https://example.com/path///", "https://example.com/path//"),
    ("https://example.com/path/#section", "https://example.com/path"),
    ("https://example.com/path/#", "https://example.com/path"),
    ("https://example.com/path/#!", "https://example.com/path/#!"),
    ("https://example.com/path/#!/", "https://example.com/path/#!"),
    ("https://example.com/path/#!/Route/", "https://example.com/path/#!/route"),
    ("https://example.com/path/#!/route//", "https://example.com/path/#!/route/"),
])
func pinnedComparisonFragmentControlsSingleSlashTrimming(input: String, expected: String) throws {
    let url = try #require(URL(string: input))
    #expect(PinnedURLComparison.normalized(url).absoluteString == expected)
}

@Test func pinnedComparisonUsesOriginalPathAndFallsBackToOriginalURL() throws {
    let input = try #require(URL(string: "EXAMPLE.COM/Path/"))
    let original = try #require(URLComponents(string: input.absoluteString.lowercased()))
    #expect(original.scheme == nil)
    #expect(original.host == nil)
    #expect(original.path == "example.com/path/")
    var incompatible = try #require(URLComponents(string: "https://example.com/path/"))
    incompatible.path = "example.com/path"
    #expect(incompatible.url == nil)
    let output = PinnedURLComparison.normalized(input)
    #expect(output == input)
    #expect(output.absoluteString == "EXAMPLE.COM/Path/")
}

@Test(arguments: [
    "https://example.com/path",
    "https://example.com/path?",
    "https://example.com/path?flag&empty=&utm_source=x",
])
func pinnedComparisonRemovesEmptyQueriesAndAllRejectedItems(input: String) throws {
    let url = try #require(URL(string: input))
    #expect(PinnedURLComparison.normalized(url).absoluteString == "https://example.com/path")
}

@Test func pinnedComparisonQueryPreservesOrderDuplicatesEmptyNamesAndUnrelatedTracking() throws {
    let input = try #require(URL(string: "https://example.com/path?z=2&flag&a=1&empty=&a=3&utm_source=x&=keep&gclid=G&fbclid=F&xutm_source=y&utm=x"))
    let output = PinnedURLComparison.normalized(input)
    let components = try #require(URLComponents(url: output, resolvingAgainstBaseURL: false))
    #expect(components.queryItems == [
        URLQueryItem(name: "z", value: "2"),
        URLQueryItem(name: "a", value: "1"),
        URLQueryItem(name: "a", value: "3"),
        URLQueryItem(name: "", value: "keep"),
        URLQueryItem(name: "gclid", value: "g"),
        URLQueryItem(name: "fbclid", value: "f"),
        URLQueryItem(name: "xutm_source", value: "y"),
        URLQueryItem(name: "utm", value: "x"),
    ])
}

@Test func pinnedComparisonQueryFilterUsesDecodedNamesWithoutSecondLowercase() throws {
    let input = try #require(URL(string: "https://example.com/path?%75tm_source=x&%55tm_source=y&value=%41&keep=1"))
    let output = PinnedURLComparison.normalized(input)
    let components = try #require(URLComponents(url: output, resolvingAgainstBaseURL: false))
    #expect(components.queryItems == [
        URLQueryItem(name: "Utm_source", value: "y"),
        URLQueryItem(name: "value", value: "A"),
        URLQueryItem(name: "keep", value: "1"),
    ])
}

@Test func pinnedComparisonElidesQuerySetterWhenNothingIsRemoved() throws {
    let input = try #require(URL(string: "HTTP://example.com/path?name=%41&tag=%2F&tag=Second"))
    var expected = try #require(URLComponents(string: input.absoluteString.lowercased()))
    expected.scheme = "https"
    let expectedURL = try #require(expected.url)
    #expect(expected.percentEncodedQuery?.contains("%41") == true)
    let output = PinnedURLComparison.normalized(input)
    #expect(output.absoluteString == expectedURL.absoluteString)
    let actual = try #require(URLComponents(url: output, resolvingAgainstBaseURL: false))
    #expect(actual.percentEncodedQuery == expected.percentEncodedQuery)
}
