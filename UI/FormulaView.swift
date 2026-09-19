//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftMath
import SwiftUI

// SwiftMath typesets LaTeX into vector images; inline ones sit on the text baseline inside SwiftUI `Text`, so formulas
// flow with paragraphs, list items and table cells. A formula SwiftMath cannot parse falls back to `MathText.unicode`.

@MainActor
enum FormulaRenderer {
    struct Rendered {
        let image: NSImage
        /// Distance from the image's bottom edge to the formula's baseline.
        let baseline: CGFloat
    }

    /// A streamed reply is re-rendered on every token: typeset each formula once per size and appearance.
    private static var cache: [String: Rendered?] = [:]

    static func render(_ formula: Formula, fontSize: CGFloat, dark: Bool) -> Rendered? {
        let key = "\(formula.display)|\(fontSize)|\(dark)|\(formula.latex)"
        if let hit = cache[key] { return hit }
        var math = MathImage(
            latex: formula.latex, fontSize: fontSize, textColor: labelColor(dark: dark), labelMode: formula.display ? .display : .text,
            textAlignment: .left)
        let (error, image, layout) = math.asImage()
        var rendered: Rendered?
        if error == nil, let image, let layout {
            // MathImage centres the formula vertically, with at least half the font size of height.
            let height = max(layout.ascent + layout.descent, fontSize / 2)
            rendered = Rendered(image: image, baseline: (image.size.height - height) / 2 + layout.descent)
        }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }

    /// The image is drawn once with a fixed colour, so the system label colour is resolved for the current appearance.
    private static func labelColor(dark: Bool) -> NSColor {
        var color = NSColor.labelColor
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return color
    }

    /// `Text` for an attributed string whose formula runs are typeset.
    static func text(_ attributed: AttributedString, fontSize: CGFloat, dark: Bool) -> Text {
        guard attributed.runs.contains(where: { $0[FormulaAttribute.self] != nil }) else { return Text(attributed) }
        // `Text + Text` is deprecated; an interpolation built in code joins the pieces; its empty catalog key is marked non-translatable.
        var joined = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: attributed.runs.count)
        for run in attributed.runs {
            let piece: Text
            if let formula = run[FormulaAttribute.self] {
                if let rendered = render(formula, fontSize: fontSize * (formula.display ? 1.2 : 1.05), dark: dark) {
                    piece = Text(Image(nsImage: rendered.image)).baselineOffset(-rendered.baseline)
                } else {
                    piece = Text(verbatim: MathText.unicode(formula.latex))
                }
            } else {
                piece = Text(AttributedString(attributed[run.range]))
            }
            joined.appendInterpolation(piece)
        }
        return Text(LocalizedStringKey(stringInterpolation: joined))
    }
}

/// A display formula on its own: larger, centred, scaled down when wider than the reply (no nested scroll view, see
/// `CodeBlockView`).
struct FormulaBlockView: View {
    let formula: Formula
    let fontSize: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let rendered = FormulaRenderer.render(formula, fontSize: fontSize * 1.25, dark: colorScheme == .dark) {
            Image(nsImage: rendered.image).resizable().scaledToFit()
                .frame(maxWidth: rendered.image.size.width)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        } else {
            Text(verbatim: MathText.unicode(formula.latex)).frame(maxWidth: .infinity).textSelection(.enabled)
        }
    }
}
