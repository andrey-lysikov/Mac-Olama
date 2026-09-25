//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// Safari

/// `browser_*`: the user's own Safari, driven through Apple Events (JXA run by osascript, no shell). The model opens,
/// reads, clicks, types and goes back on its own; password fields are never touched. Off by default, with its own switch in the settings.
public struct SafariToolProvider: ToolProvider {
    public struct Configuration: Sendable {
        /// Characters of page text one read returns; the same setting as the page reader's.
        public var pageCharacters: Int
        public var timeout: TimeInterval = 30
        public init(pageCharacters: Int) { self.pageCharacters = pageCharacters }
    }

    public var configuration: Configuration
    public init(configuration: Configuration) { self.configuration = configuration }

    private static let tabParameter =
        #""tab":{"type":"integer","description":"Tab number from browser_tabs; leave it out for the tab in front""#

    public var specs: [ToolSpec] {
        [
            ToolSpec(
                name: "browser_tabs", description: "List the tabs open in the user's Safari: number, title and address.",
                parametersJSONSchema: #"{"type":"object","properties":{}}"#),
            ToolSpec(
                name: "browser_open",
                description:
                    "Open a web address in the user's Safari, in a new tab unless told otherwise, wait for it to load and return the page as browser_read does.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"url":{"type":"string","description":"http or https address"},"new_tab":{"type":"boolean","description":"Default true; false loads it in the tab in front"}},"required":["url"]}"#
            ),
            ToolSpec(
                name: "browser_read",
                description:
                    "Read a Safari tab: its title, address, visible text, and its links, buttons and fields, each with a number to use with browser_click and browser_type. Numbers change when the page does: read again after it has.",
                parametersJSONSchema: #"{"type":"object","properties":{"# + Self.tabParameter + "}}}"),
            ToolSpec(
                name: "browser_click",
                description:
                    "Click a link or button by its number from browser_read, then return the page as it is afterwards.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"element":{"type":"integer","description":"Number from browser_read"},"#
                    + Self.tabParameter + #"}},"required":["element"]}"#),
            ToolSpec(
                name: "browser_type",
                description:
                    "Type text into a field (or pick a list option by its text) by its number from browser_read, optionally sending the form after. Password fields are refused.",
                parametersJSONSchema:
                    #"{"type":"object","properties":{"element":{"type":"integer","description":"Number from browser_read"},"text":{"type":"string"},"submit":{"type":"boolean","description":"Send the form (or press Enter) after typing; default false"},"#
                    + Self.tabParameter + #"}},"required":["element","text"]}"#),
            ToolSpec(
                name: "browser_back", description: "Go back one page in a Safari tab and return the page as browser_read does.",
                parametersJSONSchema: #"{"type":"object","properties":{"# + Self.tabParameter + "}}}"),
        ]
    }

    public func execute(_ call: ToolCall) async throws -> String {
        let args = ToolArguments(call.argumentsJSON)
        let tab = args.int("tab") ?? args.string("tab").flatMap { Int($0) }
        let element = args.int("element") ?? args.string("element").flatMap { Int($0) }
        do {
            switch call.name {
            case "browser_tabs":
                return try await tabs()
            case "browser_open":
                guard let text = args.string("url"), let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased())
                else { return "error: an http or https address is needed" }
                let open =
                    args.bool("new_tab") == false
                    ? "const t = tabAt(null); t.url = \(Self.literal(url.absoluteString));"
                    : "const t = newTab(\(Self.literal(url.absoluteString)));"
                return try await page(open + " settle(t); return t.doJavaScript(READ);", source: url.absoluteString)
            case "browser_read":
                return try await page("return tabAt(\(Self.literal(tab))).doJavaScript(READ);", source: "Safari tab")
            case "browser_back":
                let body =
                    "const t = tabAt(\(Self.literal(tab))); t.doJavaScript('history.back()'); settle(t); return t.doJavaScript(READ);"
                return try await page(body, source: "Safari tab")
            case "browser_click":
                guard let element else { return toolFailure(missing: "element") }
                return try await click(element, tab: tab)
            case "browser_type":
                guard let element else { return toolFailure(missing: "element") }
                guard let text = args.string("text") else { return toolFailure(missing: "text") }
                return try await type(text, into: element, submit: args.bool("submit") ?? false, tab: tab)
            default:
                throw ConversationError.unknownTool(call.name)
            }
        } catch let failure as SafariFailure {
            return failure.toolText
        }
    }

    // Actions

    private func tabs() async throws -> String {
        let out = try await run(
            """
            const all = [];
            browserWindows().forEach(w => w.tabs().forEach(t => all.push({ title: t.name(), url: t.url() })));
            return JSON.stringify(all);
            """)
        guard let list = try? JSONDecoder().decode([Tab].self, from: Data(out.utf8)) else { throw SafariFailure.unreadable(out) }
        guard !list.isEmpty else { return "Safari has no open tabs." }
        let lines = list.enumerated().map { "\($0.offset + 1). \($0.element.title ?? "") — \($0.element.url ?? "")" }
        return ToolOutput.wrap((["Tabs open in Safari:"] + lines).joined(separator: "\n"), source: "browser_tabs")
    }

    private func click(_ element: Int, tab: Int?) async throws -> String {
        _ = try await describe(element, tab: tab)  // a stale number fails here with a clear error, before anything is pressed
        let body = """
            const t = tabAt(\(Self.literal(tab)));
            t.doJavaScript(\(Self.literal(Self.clickScript(element))));
            settle(t);
            return t.doJavaScript(READ);
            """
        return try await page(body, source: "Safari tab")
    }

    private func type(_ text: String, into element: Int, submit: Bool, tab: Int?) async throws -> String {
        let target = try await describe(element, tab: tab)
        guard target.password != true else { return "error: that is a password field; the user types passwords themselves" }
        guard target.typable == true else { return "error: element \(element) is not a field; read the page again" }
        let body = """
            const t = tabAt(\(Self.literal(tab)));
            const done = t.doJavaScript(\(Self.literal(Self.fillScript(element, text: text, submit: submit))));
            if (done === 'NO_OPTION') return 'NO_OPTION';
            \(submit ? "settle(t);" : "")
            return t.doJavaScript(READ);
            """
        let out = try await run(body)
        if out == "NO_OPTION" { return "error: the list has no option called \"\(text)\"" }
        return try format(out, source: "Safari tab")
    }

    // The element the model means, described before anything is done to it

    private struct Target: Decodable {
        var label: String
        var host: String
        var submits = false
        var download = false
        var password: Bool?
        var typable: Bool?
    }

    private func describe(_ element: Int, tab: Int?) async throws -> Target {
        let out = try await run("return tabAt(\(Self.literal(tab))).doJavaScript(\(Self.literal(Self.describeScript(element))));")
        guard out != "MISSING" else { throw SafariFailure.missing(element) }
        guard let target = try? JSONDecoder().decode(Target.self, from: Data(out.utf8)) else { throw SafariFailure.unreadable(out) }
        return target
    }

    // Running JXA

    // Scripts run in the page (internal, so they can be tried in a WebKit view)

    /// browser_read: the text, and every visible control numbered in the page itself, so a later click finds it by
    /// that number. A field's value is never read: it may be what the user typed.
    static func readScript(limit: Int) -> String {
        """
        (() => {
          const limit = \(limit);
          document.querySelectorAll('[data-mo-id]').forEach(e => e.removeAttribute('data-mo-id'));
          const shown = e => {
            const r = e.getBoundingClientRect();
            if (r.width === 0 && r.height === 0) return false;
            const s = getComputedStyle(e);
            return s.visibility !== 'hidden' && s.display !== 'none';
          };
          const nodes = [...document.querySelectorAll(
            'a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link], [role=tab], [role=menuitem], [contenteditable=true]'
          )].filter(shown).slice(0, 200);
          const label = e => {
            const field = ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.tagName) && !['submit', 'button'].includes(e.type);
            const text = field
              ? (e.getAttribute('aria-label') || e.placeholder || (e.labels && e.labels[0] && e.labels[0].innerText) || e.name || e.title || '')
              : (e.getAttribute('aria-label') || e.innerText || e.value || e.title || e.alt || '');
            return text.replace(/\\s+/g, ' ').trim().slice(0, 80);
          };
          const elements = nodes.map((e, i) => {
            e.setAttribute('data-mo-id', String(i + 1));
            const tag = e.tagName.toLowerCase();
            return { id: i + 1, tag, type: e.getAttribute('type') || e.getAttribute('role') || '', label: label(e), href: tag === 'a' ? e.href : null };
          });
          const text = (document.body ? document.body.innerText : '').replace(/\\n{3,}/g, '\\n\\n');
          return JSON.stringify({ title: document.title, url: location.href, text: text.slice(0, limit), cut: text.length > limit, elements });
        })()
        """
    }

    /// Helpers every Safari script gets: the tab lookup, a new tab, waiting for a page to load, and the read script.
    private func run(_ body: String) async throws -> String {
        let prelude = """
            const s = Application('Safari');
            const READ = \(Self.literal(Self.readScript(limit: configuration.pageCharacters)));
            function browserWindows() {
              return s.windows().filter(w => { try { w.currentTab(); return true } catch (e) { return false } });
            }
            function tabAt(n) {
              const windows = browserWindows();
              if (!windows.length) throw new Error('NO_WINDOW');
              if (n === null) return windows[0].currentTab();
              const all = [];
              windows.forEach(w => w.tabs().forEach(t => all.push(t)));
              if (n < 1 || n > all.length) throw new Error('NO_TAB');
              return all[n - 1];
            }
            function newTab(url) {
              const windows = browserWindows();
              if (!windows.length) { s.Document().make(); delay(0.5); const t = browserWindows()[0].currentTab(); t.url = url; return t; }
              const t = s.Tab({ url });
              windows[0].tabs.push(t);
              windows[0].currentTab = t;
              return t;
            }
            function settle(t) {
              delay(0.6);
              for (let i = 0; i < 25; i++) {
                try { if (t.doJavaScript('document.readyState') === 'complete') return; } catch (e) {}
                delay(0.4);
              }
            }
            """
        let out = try await JXA.run(prelude: prelude, body, timeout: configuration.timeout)
        if out.hasPrefix("ERROR:") { throw SafariFailure(error: out) }
        return out
    }

    private func page(_ body: String, source: String) async throws -> String {
        try format(try await run(body), source: source)
    }

    private struct Page: Decodable {
        struct Element: Decodable {
            var id: Int
            var tag: String
            var type: String
            var label: String
            var href: String?
        }
        var title: String
        var url: String
        var text: String
        var cut: Bool
        var elements: [Element]
    }

    private struct Tab: Decodable {
        var title: String?
        var url: String?
    }

    private func format(_ json: String, source: String) throws -> String {
        guard let page = try? JSONDecoder().decode(Page.self, from: Data(json.utf8)) else { throw SafariFailure.unreadable(json) }
        var lines = ["Safari tab: \(page.title) — \(page.url)", "", page.text]
        if page.cut { lines.append("…[the page goes on; the rest was cut]") }
        lines += ["", "Links, buttons and fields (use the numbers with browser_click and browser_type):"]
        lines += page.elements.map { element in
            let kind = element.tag == "a" ? "link" : element.type.isEmpty ? element.tag : "\(element.tag) \(element.type)"
            return "[\(element.id)] \(kind) “\(element.label)”" + (element.href.map { " → \($0)" } ?? "")
        }
        return ToolOutput.wrap(lines.joined(separator: "\n"), source: "browser: \(source)")
    }

    /// What element `id` is, before anything is done to it: its label and the page's host for the question to the
    /// user, whether pressing it sends a form or downloads, and whether it takes text.
    static func describeScript(_ id: Int) -> String {
        inPage(
            find(id) + """
                const tag = e.tagName.toLowerCase();
                const type = (e.getAttribute('type') || (tag === 'button' ? 'submit' : '')).toLowerCase();
                const button = tag === 'input' && ['submit', 'button', 'reset', 'image'].includes(type);
                // A field is named by its label, never by its content: a list's text is all its options at once.
                const field = !button && ['input', 'textarea', 'select'].includes(tag);
                const label = (e.getAttribute('aria-label')
                  || (field ? e.placeholder || (e.labels && e.labels[0] && e.labels[0].innerText) || e.name : e.innerText || (button ? e.value : ''))
                  || e.title || tag)
                  .replace(/\\s+/g, ' ').trim().slice(0, 80);
                return JSON.stringify({
                  label, host: location.host,
                  submits: (tag === 'button' && !!e.form && type === 'submit') || (tag === 'input' && (type === 'submit' || type === 'image')),
                  download: tag === 'a' && e.hasAttribute('download'),
                  password: type === 'password',
                  typable: e.isContentEditable || tag === 'textarea' || tag === 'select'
                    || (tag === 'input' && !['submit', 'button', 'image', 'reset', 'checkbox', 'radio', 'file', 'hidden'].includes(type))
                });
                """)
    }

    static func clickScript(_ id: Int) -> String {
        inPage(find(id) + "e.scrollIntoView({ block: 'center' }); e.click(); return 'ok';")
    }

    /// Sets the value the way typing does, through the element's own setter, so pages built on React and the like see it.
    static func fillScript(_ id: Int, text: String, submit: Bool) -> String {
        inPage(
            find(id) + """
                e.focus();
                const text = \(literal(text));
                if (e.tagName === 'SELECT') {
                  const o = [...e.options].find(o => o.text.trim() === text || o.value === text);
                  if (!o) return 'NO_OPTION';
                  e.value = o.value;
                } else if (e.isContentEditable) {
                  e.textContent = text;
                } else {
                  const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                  Object.getOwnPropertyDescriptor(proto, 'value').set.call(e, text);
                }
                e.dispatchEvent(new Event('input', { bubbles: true }));
                e.dispatchEvent(new Event('change', { bubbles: true }));
                if (\(submit ? "true" : "false")) {
                  if (e.form && e.form.requestSubmit) e.form.requestSubmit();
                  else e.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
                }
                return 'ok';
                """)
    }

    /// A script for the page, as a function: `do JavaScript` runs a plain script, where `return` is not allowed.
    private static func inPage(_ body: String) -> String { "(() => {\n" + body + "\n})()" }

    /// The prologue of a page script that acts on element `id`; a page that changed since the read has lost it.
    private static func find(_ id: Int) -> String {
        "const e = document.querySelector('[data-mo-id=\"\(id)\"]'); if (!e) return 'MISSING';\n"
    }

    private static func literal(_ value: String) -> String { JXA.literal(value) }

    private static func literal(_ value: Int?) -> String { value.map(String.init) ?? "null" }
}

/// Why Safari did not do what the model asked, in words that tell the model (and so the user) what to change.
enum SafariFailure: Error {
    case javaScriptOff, notAllowed, noWindow, noTab, missing(Int), unreadable(String), other(String)

    init(error: String) {
        switch true {
        case error.contains("-1743"):
            PrivacySettings.ask(.automation)
            self = .notAllowed
        case error.contains("Apple Events") || error.contains("Apple events"): self = .javaScriptOff
        case error.contains("NO_WINDOW"): self = .noWindow
        case error.contains("NO_TAB"): self = .noTab
        default: self = .other(String(error.dropFirst("ERROR:".count)))
        }
    }

    var toolText: String {
        switch self {
        case .javaScriptOff:
            "error: Safari does not let apps run scripts in its pages yet. Tell the user to turn on Safari → Settings → Advanced → Show features for web developers, then Develop → Allow JavaScript from Apple Events."
        case .notAllowed:
            "error: Mac-Olama may not control Safari. A notification now asks the user to allow Mac-Olama → Safari in System Settings → Privacy & Security → Automation; ask again once they have."
        case .noWindow: "error: Safari has no open window; open a page with browser_open"
        case .noTab: "error: there is no tab with that number; call browser_tabs"
        case .missing(let id): "error: element \(id) is not on the page any more; call browser_read and use the new numbers"
        case .unreadable(let text): "error: Safari answered with something unexpected: \(text.prefix(300))"
        case .other(let text): "error: Safari could not do it: \(text.prefix(300))"
        }
    }
}
