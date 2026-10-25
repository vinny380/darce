import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

/* Failure plan (before implementation):
 - Profile leakage: key every image by profile plus exact page URL; fetch only in that page's WKWebView.
 - Stale navigation: compare request identity and current URL before publishing; superseded requests fail closed.
 - Unbounded data: stream at most 256 KiB, decode at most 4096px input, rasterize to 64px PNG; cache 128 entries.
 - Untrusted image content: decode in WebKit, hand native AppKit only bounded PNG bytes; CSP/CORS/decode errors fall back.
   The page only fetches the icon's bytes; decoding happens in a separate offline WebKit view, because many sites'
   CSP blocks the blob: images an in-page decode needs (Hacker News, for one).
 - Hanging/blocked requests: abort after five seconds; no URLSession, third-party favicon service, or cookie copying.
 Synthetic smoke below checks native image creation, profile isolation, and stale-navigation rejection.
 */
@MainActor
final class FaviconController: ObservableObject {
    private struct Key: Hashable { let profileID: UUID; let pageURL: URL }
    private struct Entry { let image: NSImage; let png: Data; var accessed: UInt64 }
    private var entries: [Key: Entry] = [:]
    private struct Pending { let token: UUID; let profileID: UUID }
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var clock: UInt64 = 0
    @Published private var revision = 0

    func image(for url: URL, profileID: UUID) -> NSImage? {
        let key = Key(profileID: profileID, pageURL: url)
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.accessed = clock
        entries[key] = entry
        return entry.image
    }

    /// The bounded PNG behind a loaded icon, for saving with its tab.
    func png(for url: URL, profileID: UUID) -> Data? { entries[Key(profileID: profileID, pageURL: url)]?.png }

    func clear(profileID: UUID) {
        entries = entries.filter { $0.key.profileID != profileID }
        pending = pending.filter { $0.value.profileID != profileID }
        revision &+= 1
    }

    func refresh(from page: BrowserPage, profileID: UUID, completion: ((Bool) -> Void)? = nil) {
        let webView = page.webView
        guard let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            completion?(false); return
        }
        let request = UUID(), identity = ObjectIdentifier(webView)
        pending[identity] = Pending(token: request, profileID: profileID)
        webView.callAsyncJavaScript(Self.loader, arguments: ["expectedURL": url.absoluteString], in: nil, in: .defaultClient) { [weak self, weak webView] result in
            guard let self else { completion?(false); return }
            guard self.pending[identity]?.token == request,
                  webView?.url == url, case .success(let value) = result,
                  let payload = value as? [String: Any], payload["pageURL"] as? String == url.absoluteString,
                  let icons = payload["icons"] as? [[String: Any]], !icons.isEmpty else {
                if self.pending[identity]?.token == request { self.pending.removeValue(forKey: identity) }
                completion?(false); return
            }
            Task { @MainActor in
                let png = await self.decodeFirst(icons)
                guard self.pending[identity]?.token == request else { completion?(false); return }
                self.pending.removeValue(forKey: identity)
                self.store(png, for: url, profileID: profileID, live: webView, completion: completion)
            }
        }
    }

    /// Decodes the fetched icons in order, in the offline decoder, until one works.
    private func decodeFirst(_ icons: [[String: Any]]) async -> String? {
        for icon in icons.prefix(5) {
            guard let data = icon["data"] as? String, data.utf8.count <= 350_000 else { continue }
            let type = (icon["type"] as? String).map { String($0.prefix(100)) } ?? "image/x-icon"
            if let png = try? await decoder.callAsyncJavaScript(Self.decode, arguments: ["data": data, "type": type],
                                                                 in: nil, contentWorld: .defaultClient) as? String {
                return png
            }
        }
        return nil
    }

    /// A blank WebKit view with its own throwaway data store, used only to turn icon bytes into a PNG.
    /// ponytail: its empty initial page is the sandbox; images loaded by <img> can't fetch subresources.
    private lazy var decoder: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
    }()

    private func store(_ encoded: String?, for url: URL, profileID: UUID, live webView: WKWebView?, completion: ((Bool) -> Void)?) {
        guard webView?.url == url, webView?.isLoading == false,
              let encoded, encoded.utf8.count <= 90_000,
              let data = Data(base64Encoded: encoded), data.count <= 65_536,
              data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let bitmap = NSBitmapImageRep(data: data),
              bitmap.pixelsWide > 0, bitmap.pixelsWide <= 64,
              bitmap.pixelsHigh > 0, bitmap.pixelsHigh <= 64 else { completion?(false); return }
        let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        image.addRepresentation(bitmap)
        self.clock &+= 1
        self.entries[Key(profileID: profileID, pageURL: url)] = Entry(image: image, png: data, accessed: self.clock)
        while self.entries.count > 128, let oldest = self.entries.min(by: { $0.value.accessed < $1.value.accessed })?.key {
            self.entries.removeValue(forKey: oldest)
        }
        self.revision &+= 1
        completion?(true)
    }

    private static let loader = #"""
    if (location.href !== expectedURL) return null;
    window.__browserPrototypeFaviconAbort?.abort();
    const controller = new AbortController();
    window.__browserPrototypeFaviconAbort = controller;
    const timeout = setTimeout(() => controller.abort(), 5000);
    const maximum = 262144;
    try {
      const links = [...document.querySelectorAll('link[rel][href]')]
        .filter(link => /(?:^|\s)(?:icon|apple-touch-icon)(?:\s|$)/i.test(link.rel))
        .sort((a, b) => Number(/apple-touch-icon/i.test(a.rel)) - Number(/apple-touch-icon/i.test(b.rel)));
      const candidates = [...new Set(links.map(link => link.href).filter(Boolean))].slice(0, 4);
      candidates.push(new URL('/favicon.ico', location.href).href);
      const icons = [];
      for (const address of candidates) {
        if (controller.signal.aborted || location.href !== expectedURL) return null;
        try {
          const iconURL = new URL(address, location.href);
          if (!['http:', 'https:', 'data:', 'blob:'].includes(iconURL.protocol)) continue;
          if (iconURL.href.length > maximum * 2) continue;
          const response = await fetch(iconURL.href, {credentials:'same-origin', mode:'cors', signal:controller.signal});
          if (!response.ok || !response.body) continue;
          const declared = Number(response.headers.get('content-length'));
          if (Number.isFinite(declared) && declared > maximum) { await response.body.cancel(); continue; }
          const reader = response.body.getReader();
          const chunks = []; let total = 0;
          while (true) {
            const item = await reader.read();
            if (item.done) break;
            total += item.value.byteLength;
            if (total > maximum) { await reader.cancel(); throw new Error('Icon too large'); }
            chunks.push(item.value);
          }
          const bytes = new Uint8Array(total); let at = 0;
          for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.byteLength; }
          let binary = '';
          for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768));
          icons.push({data: btoa(binary), type: (response.headers.get('content-type') || 'image/x-icon').slice(0, 100)});
        } catch (_) {
          // Blocked, tainted, invalid, oversized, or unsupported icons use the next candidate.
        }
      }
      if (location.href !== expectedURL || controller.signal.aborted || icons.length === 0) return null;
      return {icons, pageURL: location.href};
    } finally {
      clearTimeout(timeout);
      if (window.__browserPrototypeFaviconAbort === controller) delete window.__browserPrototypeFaviconAbort;
    }
    """#

    /// Runs in the offline decoder: icon bytes in, a PNG of at most 64px a side out (SVGs without a size get 64px).
    private static let decode = #"""
    const binary = atob(data);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    const url = URL.createObjectURL(new Blob([bytes], {type}));
    try {
      const image = new Image();
      await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = () => reject(new Error('Invalid icon')); image.src = url; });
      const svg = /svg/i.test(type);
      const width = image.naturalWidth || (svg ? 64 : 0), height = image.naturalHeight || (svg ? 64 : 0);
      if (!width || !height || width > 4096 || height > 4096) return null;
      const scale = Math.min(1, 64 / Math.max(width, height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(width * scale));
      canvas.height = Math.max(1, Math.round(height * scale));
      canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
      return canvas.toDataURL('image/png').split(',')[1];
    } finally { URL.revokeObjectURL(url); }
    """#
}

struct SiteIcon: View {
    @ObservedObject var controller: FaviconController
    let url: URL
    let profileID: UUID
    var size: CGFloat = 18
    var usesInheritedForeground = false
    /// The tab's saved icon, shown when its page isn't loaded (as Arc does for Favorites and pins).
    var saved: Data? = nil

    var body: some View {
        Group {
            if url.easelID != nil {
                Image(systemName: "scribble.variable").resizable().scaledToFit().foregroundStyle(Color.accentColor)
            } else if let image = controller.image(for: url, profileID: profileID) ?? saved.flatMap(NSImage.init(data:)) {
                Image(nsImage: image).renderingMode(.original).resizable().interpolation(.high).scaledToFit()
            } else if let first = url.host?.first {
                Text(String(first).uppercased()).font(.system(size: size * 0.62, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            } else if usesInheritedForeground {
                Image(systemName: "globe").resizable().scaledToFit()
            } else {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}


extension SiteIcon {
    /// A sidebar tab's icon: the live page's icon, falling back to the one saved with the tab.
    init(controller: FaviconController, url: URL, saved: Data?, profileID: UUID, size: CGFloat = 18, usesInheritedForeground: Bool = false) {
        self.init(controller: controller, url: url, profileID: profileID, size: size, usesInheritedForeground: usesInheritedForeground, saved: saved)
    }
}
