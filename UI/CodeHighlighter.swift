//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

// A small lexer instead of a highlighting package: comments, strings, numbers, keywords, types and attributes cover
// what makes code readable in a chat. Colours are system colours, so dark mode and accessibility settings apply.

enum CodeHighlighter {
    private struct Syntax {
        var lineComments: [String]
        var blockComment: (open: String, close: String)?
        var keywords: Set<String>
        var caseInsensitive = false
    }

    /// Colours code of the given fence language; unknown languages get a generic C-like reading.
    static func highlight(_ code: String, language: String?) -> AttributedString {
        let syntax = syntax(for: language?.lowercased() ?? "")
        var out = AttributedString()
        let c = Array(code)
        var i = 0
        var plain = ""
        func flush() {
            if !plain.isEmpty { out.append(AttributedString(plain)) }
            plain = ""
        }
        func emit(_ text: String, _ color: NSColor) {
            flush()
            var piece = AttributedString(text)
            piece.foregroundColor = Color(nsColor: color)
            out.append(piece)
        }
        func starts(_ token: String, at index: Int) -> Bool {
            let t = Array(token)
            return index + t.count <= c.count && Array(c[index..<index + t.count]) == t
        }
        while i < c.count {
            if syntax.lineComments.contains(where: { starts($0, at: i) }) {
                var j = i
                while j < c.count, c[j] != "\n" { j += 1 }
                emit(String(c[i..<j]), .secondaryLabelColor)
                i = j
                continue
            }
            if let block = syntax.blockComment, starts(block.open, at: i) {
                var j = i + block.open.count
                while j < c.count, !starts(block.close, at: j) { j += 1 }
                j = min(c.count, j + block.close.count)
                emit(String(c[i..<j]), .secondaryLabelColor)
                i = j
                continue
            }
            let ch = c[i]
            if ch == "\"" || ch == "'" || ch == "`" {
                // Triple quotes (Python, Swift multi-line) run to the matching triple.
                let triple = starts(String(repeating: ch, count: 3), at: i)
                let quote = triple ? String(repeating: ch, count: 3) : String(ch)
                var j = i + quote.count
                while j < c.count, !starts(quote, at: j) {
                    if c[j] == "\\" { j += 1 } else if c[j] == "\n", !triple, ch != "`" { break }
                    j += 1
                }
                j = min(c.count, j + (j < c.count && c[j] != "\n" ? quote.count : 0))
                emit(String(c[i..<j]), .systemRed)
                i = j
                continue
            }
            if ch.isNumber, i == 0 || !(c[i - 1].isLetter || c[i - 1] == "_") {
                var j = i + 1
                while j < c.count, c[j].isHexDigit || c[j] == "." || c[j] == "_" || c[j] == "x" || c[j] == "X" { j += 1 }
                emit(String(c[i..<j]), .systemBlue)
                i = j
                continue
            }
            if ch.isLetter || ch == "_" || ch == "@" || ch == "#" {
                var j = i + 1
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                let word = String(c[i..<j])
                if ch == "@" || (ch == "#" && j > i + 1) {
                    emit(word, .systemBrown)  // attributes, decorators, directives
                } else if syntax.keywords.contains(syntax.caseInsensitive ? word.lowercased() : word) {
                    emit(word, .systemPink)
                } else if ch.isUppercase, word.count > 1, word.contains(where: \.isLowercase) {
                    emit(word, .systemPurple)  // TypeName by convention
                } else {
                    plain += word
                }
                i = j
                continue
            }
            plain.append(ch)
            i += 1
        }
        flush()
        return out
    }

    private static func syntax(for language: String) -> Syntax {
        let slash = ["//"]
        let cBlock = (open: "/*", close: "*/")
        switch language {
        case "swift": return Syntax(lineComments: slash, blockComment: cBlock, keywords: swift)
        case "python", "py": return Syntax(lineComments: ["#"], blockComment: nil, keywords: python)
        case "javascript", "js", "jsx", "typescript", "ts", "tsx", "json", "jsonc":
            return Syntax(lineComments: slash, blockComment: cBlock, keywords: script)
        case "bash", "sh", "zsh", "shell", "console", "fish", "powershell", "ps1", "dockerfile", "makefile", "yaml", "yml", "toml",
            "ini", "ruby", "rb", "r", "perl":
            return Syntax(lineComments: ["#"], blockComment: nil, keywords: shell)
        case "sql", "mysql", "postgresql", "sqlite":
            return Syntax(lineComments: ["--"], blockComment: cBlock, keywords: sql, caseInsensitive: true)
        case "lua", "haskell", "hs": return Syntax(lineComments: ["--"], blockComment: nil, keywords: cFamily)
        case "html", "xml", "svg", "plist": return Syntax(lineComments: [], blockComment: ("<!--", "-->"), keywords: [])
        case "css", "scss", "less": return Syntax(lineComments: slash, blockComment: cBlock, keywords: [])
        default: return Syntax(lineComments: slash, blockComment: cBlock, keywords: cFamily.union(script))
        }
    }

    private static let swift: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer",
        "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "guard", "if",
        "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator",
        "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static", "struct",
        "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while", "consuming",
        "borrowing", "sending",
    ]
    private static let python: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except",
        "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "None", "nonlocal", "not", "or",
        "pass", "raise", "return", "self", "True", "try", "while", "with", "yield",
    ]
    private static let script: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "declare", "default",
        "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements",
        "import", "in", "instanceof", "interface", "let", "namespace", "new", "null", "of", "private", "protected", "public",
        "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var",
        "void", "while", "with", "yield",
    ]
    private static let cFamily: Set<String> = [
        "auto", "bool", "boolean", "break", "byte", "case", "catch", "chan", "char", "class", "const", "continue", "crate", "data",
        "default", "defer", "do", "double", "else", "enum", "extends", "extern", "false", "final", "float", "fn", "for", "fun",
        "func", "go", "goto", "if", "impl", "implements", "import", "include", "define", "int", "interface", "let", "long", "loop",
        "map", "match", "mod", "mut", "namespace", "new", "nil", "null", "nullptr", "object", "override", "package", "private",
        "protected", "pub", "public", "range", "ref", "return", "select", "self", "short", "signed", "sizeof", "static", "string",
        "struct", "super", "switch", "template", "this", "throw", "throws", "trait", "true", "try", "typedef", "typename", "union",
        "unsigned", "use", "using", "val", "var", "virtual", "void", "volatile", "when", "where", "while",
    ]
    private static let shell: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "in", "return", "exit",
        "export", "local", "readonly", "source", "alias", "true", "false", "def", "end", "class", "module", "require",
    ]
    private static let sql: Set<String> = [
        "select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "join",
        "inner", "left", "right", "outer", "full", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or",
        "not", "null", "is", "in", "like", "between", "primary", "key", "foreign", "references", "index", "distinct", "union",
        "all", "case", "when", "then", "else", "end", "exists", "with", "asc", "desc", "view", "default", "unique", "count", "sum",
        "avg", "min", "max",
    ]
}
