// The long explanation, out of the way.
//
// 🛑 EVERY PARAGRAPH ON THIS WINDOW WAS WRITTEN BECAUSE SOMETHING WAS ONCE
// READ WRONGLY. None of them can be deleted, and all of them together made the
// window look like a page of warnings — which is worse than saying nothing,
// because a reader who scrolls past everything scrolls past the one line that
// is really about them.
//
// So a fact that is TRUE ALL THE TIME goes behind this button, and a fact that
// is true RIGHT NOW stays on the page. The test is: would this line ever go
// away? If not, it is background, and it belongs here.
//
// ⚠️ A POPOVER, NOT A `.help()` TOOLTIP. macOS draws a tooltip as one
// unselectable strip; several of these paragraphs name a command the user is
// meant to copy.

import SwiftUI

struct Explain: View {
    let title: String
    let detail: String
    @State private var open = false

    init(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    /// A note with no heading of its own.
    ///
    /// ⚠️ ONE ARGUMENT MEANS THE BODY, NOT THE TITLE. A review read
    /// `Explain("…")` as naming the popover. Call the two-argument form
    /// whenever the popover deserves a heading.
    init(detail: String) {
        self.title = ""
        self.detail = detail
    }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(detail)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if !title.isEmpty {
                    Text(title).font(.callout.weight(.semibold))
                }
                Text(detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(width: 380)
        }
    }
}

/// The same thing, worn as a label rather than as a bare glyph. Used where the
/// button would otherwise float with nothing to attach to.
struct ExplainLabel: View {
    let label: String
    let title: String
    let detail: String

    init(_ label: String, _ title: String, _ detail: String) {
        self.label = label; self.title = title; self.detail = detail
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Explain(title, detail)
        }
    }
}
