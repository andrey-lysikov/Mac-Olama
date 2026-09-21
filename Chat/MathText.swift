//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// Markdown would mangle LaTeX, so formulas outside code become placeholders before parsing and SwiftMath typesets them.
// `unicode(_:)` is the plain-text fallback for formulas SwiftMath cannot parse (√40, x², ≤).

/// A formula found in a reply; `display` for `$$…$$` and `\[…\]`.
struct Formula: Hashable, Sendable {
    var latex: String
    var display: Bool
}

enum MathText {
    /// Tokens are private-use characters around the formula's index: Markdown leaves them alone.
    static let tokenStart: Character = "\u{E000}"
    static let tokenEnd: Character = "\u{E001}"

    /// Replaces `$…$`, `$$…$$`, `\(…\)` and `\[…\]` in Markdown source with tokens; fenced code and code spans stay untouched.
    static func extract(_ markdown: String) -> (source: String, formulas: [Formula]) {
        guard markdown.contains("$") || markdown.contains("\\(") || markdown.contains("\\[") else { return (markdown, []) }
        var formulas: [Formula] = []
        var out = ""
        var prose = ""
        var fence = CodeFence()
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if fence.isOpen {
                out += line + "\n"
                _ = fence.consume(line)
            } else if fence.consume(line) {  // the line opens a fence
                out += scanProse(prose, into: &formulas)
                prose = ""
                out += line + "\n"
            } else {
                prose += line + "\n"
            }
        }
        out += scanProse(prose, into: &formulas)
        return (String(out.dropLast()), formulas)  // the loop added a newline after the last line too
    }

    /// Prose between code fences: finds the formulas, skipping code spans and backslash escapes.
    private static func scanProse(_ text: String, into formulas: inout [Formula]) -> String {
        let c = Array(text)
        var out = ""
        var i = 0
        func formula(_ latex: String, display: Bool) -> String {
            formulas.append(Formula(latex: latex.trimmingCharacters(in: .whitespacesAndNewlines), display: display))
            return "\(tokenStart)\(formulas.count - 1)\(tokenEnd)"
        }
        func find(_ closing: String, from start: Int) -> Int? {
            let k = Array(closing)
            var j = start
            while j + k.count <= c.count {
                if c[j..<j + k.count].elementsEqual(k) { return j }  // no per-position Array copy
                j += c[j] == "\\" && closing != "\\)" && closing != "\\]" ? 2 : 1
            }
            return nil
        }
        while i < c.count {
            let ch = c[i]
            let next: Character? = i + 1 < c.count ? c[i + 1] : nil
            if ch == "`" {
                var run = 0
                while i + run < c.count, c[i + run] == "`" { run += 1 }
                let ticks = String(repeating: "`", count: run)
                if let end = find(ticks, from: i + run) {
                    out += String(c[i..<end + run])
                    i = end + run
                } else {
                    out += ticks
                    i += run
                }
            } else if ch == "\\", next == "(" || next == "[" {
                let closing = next == "(" ? "\\)" : "\\]"
                if let end = find(closing, from: i + 2) {
                    out += formula(String(c[i + 2..<end]), display: next == "[")
                    i = end + 2
                } else {
                    out.append(ch)
                    i += 1
                }
            } else if ch == "\\", let next {
                out += String([ch, next])  // an escape, e.g. \$ stays a dollar sign
                i += 2
            } else if ch == "$", next == "$" {
                if let end = find("$$", from: i + 2) {
                    out += formula(String(c[i + 2..<end]), display: true)
                    i = end + 2
                } else {
                    out += "$$"
                    i += 2
                }
            } else if ch == "$", let end = inlineEnd(c, from: i) {
                out += formula(String(c[i + 1..<end]), display: false)
                i = end + 1
            } else {
                out.append(ch)
                i += 1
            }
        }
        return out
    }

    /// Pandoc's rule, so prices stay text: `$` followed by a non-space, closed by `$` after a non-space and not before a digit,
    /// on the same line and before any code span.
    private static func inlineEnd(_ c: [Character], from start: Int) -> Int? {
        guard start + 1 < c.count, !c[start + 1].isWhitespace else { return nil }
        var j = start + 1
        while j < c.count, c[j] != "\n", c[j] != "`" {  // a code span wins over a formula, as in Pandoc
            if c[j] == "\\" {
                j += 2
                continue
            }
            if c[j] == "$" {
                let closes = !c[j - 1].isWhitespace && !(j + 1 < c.count && c[j + 1].isNumber)
                return closes && j > start + 1 ? j : nil
            }
            j += 1
        }
        return nil
    }

    /// LaTeX math → Unicode text.
    static func unicode(_ latex: String) -> String {
        var parser = Parser(c: Array(latex))
        let text = parser.sequence(closing: nil)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Parser {
        let c: [Character]
        var i = 0

        mutating func sequence(closing: Character?) -> String {
            var out = ""
            while i < c.count {
                let ch = c[i]
                if let closing, ch == closing {
                    i += 1
                    return out
                }
                switch ch {
                case "{":
                    i += 1
                    out += sequence(closing: "}")
                case "}":
                    i += 1
                case "^", "_":
                    i += 1
                    out += MathText.script(argument(), superscript: ch == "^")
                case "\\":
                    out += command()
                case "&", "~":
                    i += 1
                    out += " "
                case "'":
                    i += 1
                    out += "′"
                case "-":
                    i += 1
                    out += "−"
                case "*":
                    i += 1
                    out += "∗"
                default:
                    i += 1
                    if ch.isWhitespace {
                        if !out.isEmpty, !out.hasSuffix(" "), !out.hasSuffix("\n") { out += " " }
                    } else {
                        out.append(ch)
                    }
                }
            }
            return out
        }

        mutating func skipSpaces() {
            while i < c.count, c[i].isWhitespace { i += 1 }
        }

        /// A command argument: a group, a command, or one character.
        mutating func argument() -> String {
            skipSpaces()
            guard i < c.count else { return "" }
            switch c[i] {
            case "{":
                i += 1
                return sequence(closing: "}")
            case "\\":
                return command()
            case "-":
                i += 1
                return "−"
            default:
                i += 1
                return String(c[i - 1])
            }
        }

        mutating func command() -> String {
            i += 1
            guard i < c.count else { return "" }
            let first = c[i]
            guard first.isLetter else {
                i += 1
                switch first {
                case "\\": return "\n"
                case ",", ":", ";", ">", " ": return " "
                case "!": return ""
                case "|": return "‖"
                default: return String(first)
                }
            }
            var name = ""
            while i < c.count, c[i].isLetter {
                name.append(c[i])
                i += 1
            }
            switch name {
            case "sqrt":
                skipSpaces()
                var index: String?
                if i < c.count, c[i] == "[" {
                    i += 1
                    index = sequence(closing: "]").trimmingCharacters(in: .whitespaces)
                }
                let body = MathText.wrapped(argument())
                switch index {
                case nil, "", "2": return "√" + body
                case "3": return "∛" + body
                case "4": return "∜" + body
                case let n?: return MathText.script(n, superscript: true) + "√" + body
                }
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = argument()
                let denominator = argument()
                return MathText.wrapped(numerator) + "/" + MathText.wrapped(denominator)
            case "binom", "dbinom", "tbinom":
                let n = argument()
                let k = argument()
                return "C(\(n), \(k))"
            case "text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal", "mbox", "mathrm", "mathbf", "mathit",
                "mathsf", "mathtt", "mathcal", "mathscr", "mathfrak", "operatorname", "boldsymbol", "bm":
                return argument()
            case "mathbb":
                return String(argument().map { MathText.blackboard[$0] ?? $0 })
            case "left", "right", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "big", "Big", "bigg", "Bigg", "middle":
                skipSpaces()
                if i < c.count, c[i] == "." { i += 1 }  // `\left.` is an invisible delimiter
                return ""
            case "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "nonumber", "notag":
                return ""
            case "begin", "end":
                let environment = argument()
                skipSpaces()
                if name == "begin", ["array", "tabular"].contains(environment), i < c.count, c[i] == "{" { _ = argument() }
                return ""
            case "overline", "bar": return MathText.combining(argument(), "\u{0304}")
            case "hat", "widehat": return MathText.combining(argument(), "\u{0302}")
            case "tilde", "widetilde": return MathText.combining(argument(), "\u{0303}")
            case "vec", "overrightarrow": return MathText.combining(argument(), "\u{20D7}")
            case "dot": return MathText.combining(argument(), "\u{0307}")
            case "ddot": return MathText.combining(argument(), "\u{0308}")
            case "underline": return MathText.combining(argument(), "\u{0332}")
            case "not": return argument() + "\u{0338}"
            case "pmod": return "(mod \(argument()))"
            case "mod", "bmod": return " mod "
            case "quad": return "  "
            case "qquad": return "    "
            default: return MathText.symbols[name] ?? name  // functions (\sin, \log, \lim) read as their names
            }
        }
    }

    /// Parentheses only where the argument is more than one number or name, so √40 stays √40 and √(a + b) is unambiguous.
    static func wrapped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let simple = trimmed.count <= 1 || trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "," }
        return simple ? trimmed : "(\(trimmed))"
    }

    static func script(_ text: String, superscript: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if superscript, trimmed == "∘" { return "°" }
        if trimmed == "′" || trimmed == "′′" { return trimmed }
        let map = superscript ? superscripts : subscripts
        let mapped = trimmed.filter { !$0.isWhitespace }.compactMap { map[$0] }
        if !trimmed.isEmpty, mapped.count == trimmed.filter({ !$0.isWhitespace }).count { return String(mapped) }
        let mark = superscript ? "^" : "_"
        return trimmed.count == 1 ? mark + trimmed : "\(mark)(\(trimmed))"
    }

    static func combining(_ text: String, _ mark: Character) -> String {
        text.count == 1 ? text + String(mark) : text.map { String($0) + String(mark) }.joined()
    }

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "−": "⁻",
        "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ",
        "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
        "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ", "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ",
        "J": "ᴶ", "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ",
        "⊤": "ᵀ", "∗": "*",
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "−": "₋",
        "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ",
        "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ", "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ",
        "φ": "ᵩ", "χ": "ᵪ",
    ]

    static let blackboard: [Character: Character] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "P": "ℙ", "H": "ℍ", "E": "𝔼", "1": "𝟙",
    ]

    static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators and relations
        "times": "×", "cdot": "·", "cdotp": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆", "circ": "∘",
        "bullet": "•", "oplus": "⊕", "otimes": "⊗", "setminus": "∖", "le": "≤", "leq": "≤", "leqslant": "⩽", "ge": "≥",
        "geq": "≥", "geqslant": "⩾", "lt": "<", "gt": ">", "ne": "≠", "neq": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫", "mid": "∣", "nmid": "∤", "parallel": "∥", "perp": "⊥",
        "top": "⊤", "bot": "⊥",
        // Sets and logic
        "in": "∈", "ni": "∋", "notin": "∉", "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇", "cup": "∪",
        "cap": "∩", "bigcup": "⋃", "bigcap": "⋂", "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃",
        "nexists": "∄", "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨", "therefore": "∴",
        "because": "∵",
        // Arrows
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "implies": "⟹", "iff": "⟺", "longrightarrow": "⟶", "longleftarrow": "⟵", "Longrightarrow": "⟹",
        "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        // Calculus and misc
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
        "iiint": "∭", "oint": "∮", "ell": "ℓ", "hbar": "ℏ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "prime": "′", "degree": "°",
        "angle": "∠", "measuredangle": "∡", "triangle": "△", "square": "□", "checkmark": "✓", "dagger": "†", "euro": "€",
        "ldots": "…", "dots": "…", "dotsc": "…", "dotsb": "⋯", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        // Delimiters
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "vert": "|", "lvert": "|",
        "rvert": "|", "Vert": "‖", "lVert": "‖", "rVert": "‖", "lbrace": "{", "rbrace": "}", "backslash": "\\",
    ]
}
