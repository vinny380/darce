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
 - Hanging/blocked requests: abort after five seconds; no URLSession, third-party favicon service, or cookie copying.
 Synthetic smoke below checks native image creation, profile isolation, and stale-navigation rejection.
 */
@MainActor
final class FaviconController: ObservableObject {
    private struct Key: Hashable { let profileID: UUID; let pageURL: URL }
    private struct Entry { let image: NSImage; var accessed: UInt64 }
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
            guard self.pending[identity]?.token == request else { completion?(false); return }
            self.pending.removeValue(forKey: identity)
            guard webView?.url == url, webView?.isLoading == false,
                  case .success(let value) = result,
                  let payload = value as? [String: Any],
                  payload["pageURL"] as? String == url.absoluteString,
                  let encoded = payload["png"] as? String, encoded.utf8.count <= 90_000,
                  let data = Data(base64Encoded: encoded), data.count <= 65_536,
                  data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  let bitmap = NSBitmapImageRep(data: data),
                  bitmap.pixelsWide > 0, bitmap.pixelsWide <= 64,
                  bitmap.pixelsHigh > 0, bitmap.pixelsHigh <= 64 else { completion?(false); return }
            let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            image.addRepresentation(bitmap)
            self.clock &+= 1
            self.entries[Key(profileID: profileID, pageURL: url)] = Entry(image: image, accessed: self.clock)
            while self.entries.count > 128, let oldest = self.entries.min(by: { $0.value.accessed < $1.value.accessed })?.key {
                self.entries.removeValue(forKey: oldest)
            }
            self.revision &+= 1
            completion?(true)
        }
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
      for (const address of candidates) {
        if (controller.signal.aborted || location.href !== expectedURL) return null;
        let objectURL;
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
          const blob = new Blob(chunks, {type:response.headers.get('content-type') || 'image/x-icon'});
          objectURL = URL.createObjectURL(blob);
          const image = new Image();
          await new Promise((resolve, reject) => {
            const aborted = () => { image.src = ''; reject(new Error('Aborted')); };
            const cleanup = () => controller.signal.removeEventListener('abort', aborted);
            image.onload = () => { cleanup(); resolve(); };
            image.onerror = () => { cleanup(); reject(new Error('Invalid icon')); };
            controller.signal.addEventListener('abort', aborted, {once:true});
            if (controller.signal.aborted) { aborted(); return; }
            image.src = objectURL;
          });
          if (!image.naturalWidth || !image.naturalHeight || image.naturalWidth > 4096 || image.naturalHeight > 4096) continue;
          const scale = Math.min(1, 64 / Math.max(image.naturalWidth, image.naturalHeight));
          const canvas = document.createElement('canvas');
          canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
          canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
          canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
          const png = canvas.toDataURL('image/png').split(',')[1];
          if (location.href !== expectedURL || controller.signal.aborted) return null;
          return {png, pageURL:location.href};
        } catch (_) {
          // Blocked, tainted, invalid, oversized, or unsupported icons use the next candidate.
        } finally { if (objectURL) URL.revokeObjectURL(objectURL); }
      }
      return null;
    } finally {
      clearTimeout(timeout);
      if (window.__browserPrototypeFaviconAbort === controller) delete window.__browserPrototypeFaviconAbort;
    }
    """#
}

struct SiteIcon: View {
    @ObservedObject var controller: FaviconController
    let url: URL
    let profileID: UUID
    var size: CGFloat = 18
    var usesInheritedForeground = false

    var body: some View {
        Group {
            if url.easelID != nil {
                Image(systemName: "scribble.variable").resizable().scaledToFit().foregroundStyle(Color.accentColor)
            } else if let image = controller.image(for: url, profileID: profileID) {
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

