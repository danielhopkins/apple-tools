// The contact web, drawn by d3 inside a WKWebView.
//
// 🛑 WHY A WEB VIEW AT ALL. The layout before this was Fruchterman–Reingold
// written by hand. It worked, and it was missing the force that decides whether
// a graph is readable: a force-directed model places CENTRES and has no idea a
// node is a disc, so it settles two circles a comfortable distance apart and
// draws them overlapping. `d3.forceCollide` is the separate pass every real
// graph library ships for that, and dragging, panning and zooming come with it.
//
// 🛑 IT MAKES NO NETWORK REQUESTS, AND THAT IS ENFORCED THREE WAYS. This app
// holds Full Disk Access, so a web view that could reach the internet would be
// that app phoning home with the user's social graph in its memory.
//
//   1. d3 is vendored in the bundle. See `Resources/web/VENDORED.md`.
//   2. The page declares `default-src 'none'` with `connect-src 'none'`.
//   3. `decidePolicyFor` below cancels every navigation that is not the one
//      file URL this view loads.
//
// ⚠️ Any two of those can be got wrong quietly. The third is the one that
// still refuses.

import SwiftUI
import WebKit

struct ContactWebView: NSViewRepresentable {
    /// The whole picture, as JSON. ⚠️ It carries a `layoutKey`, and the PAGE
    /// decides from it whether to re-run the simulation. Remembering that on
    /// this side too means two places tracking what was last drawn, and they
    /// drift the first time a frame is skipped.
    let payload: String
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> WKWebView {
        let settings = WKWebViewConfiguration()
        settings.userContentController.add(context.coordinator, name: "graph")
        // ⚠️ No persistent storage. Nothing here needs a cookie or a cache, and
        // a data store is one more place the graph could come to rest on disk.
        settings.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: .zero, configuration: settings)
        view.navigationDelegate = context.coordinator
        // 🛑 TRANSPARENT, so the panel behind it shows through and the graph
        // follows the window's own background in both themes. A white web view
        // in dark mode is a lightbox in the middle of the window.
        view.setValue(false, forKey: "drawsBackground")
        // Right-click gives "Reload" and "Inspect Element" on a page the user
        // did not ask for. There is nothing here to reload.
        view.allowsMagnification = false
        context.coordinator.view = view

        guard let page = Paths.graphPage else {
            context.coordinator.failed = true
            return view
        }
        context.coordinator.allowed = page
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.send(payload)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let onSelect: (String) -> Void
        weak var view: WKWebView?
        var allowed: URL?
        var failed = false
        private var ready = false
        private var pending: String?

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        /// ⚠️ HELD UNTIL THE PAGE SAYS IT IS READY. `loadFileURL` returns long
        /// before the script has run, and a `render()` call before then is
        /// silently dropped — which showed as an empty panel that fixed itself
        /// the next time anything changed.
        func send(_ payload: String) {
            guard ready, let view else { pending = payload; return }
            // ⚠️ The payload is a JSON document being passed as a JS STRING, so
            // it is encoded a second time. Interpolating it raw breaks on the
            // first apostrophe in somebody's name.
            guard let quoted = try? JSONEncoder().encode(payload),
                  let literal = String(data: quoted, encoding: .utf8) else { return }
            view.evaluateJavaScript("window.render(\(literal))")
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if body["ready"] as? Bool == true {
                ready = true
                if let waiting = pending {
                    pending = nil
                    send(waiting)
                }
                return
            }
            if let id = body["selected"] as? String { onSelect(id) }
        }

        /// 🛑 THE THIRD GUARD. Nothing may navigate anywhere except the one
        /// local file this view was given. A link, a redirect or an injected
        /// `location =` is cancelled here even if the page's own policy were
        /// wrong.
        func webView(_ view: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url, let allowed else {
                decisionHandler(.cancel); return
            }
            decisionHandler(target == allowed ? .allow : .cancel)
        }
    }
}
