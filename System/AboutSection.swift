//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// Follow the macOS 26/27 look here: Liquid Glass (`glassEffect`, `.glass` buttons), system materials, system
// colours and `Color.accentColor` only, control sizes as in the stock apps. No hand-drawn chrome.

/// The last permanent section of the chats window: what the app is, who made it, where it lives, and a way to ask
/// for a newer version right now instead of waiting for the daily check.
struct AboutSectionView: View {
    @Environment(AppContainer.self) private var container

    private static let repositoryURL = URL(string: "https://github.com/andrey-lysikov/Mac-Olama")!
    private static let issuesURL = URL(string: "https://github.com/andrey-lysikov/Mac-Olama/issues")!

    private var appName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Mac-Olama"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                VStack(alignment: .leading, spacing: 12) {
                    row(String(localized: "Authors")) { Text(verbatim: "Andrey Lysikov") }
                    Divider()
                    row(String(localized: "License")) { Text(verbatim: "Apache 2.0") }
                    Divider()
                    row(String(localized: "Source code")) {
                        Link(String(localized: "GitHub"), destination: Self.repositoryURL)
                    }
                    Divider()
                    row(String(localized: "Releases")) {
                        Link(String(localized: "All versions"), destination: UpdateChecker.latestReleaseURL)
                    }
                    Divider()
                    row(String(localized: "Feedback")) {
                        Link(String(localized: "Report an issue"), destination: Self.issuesURL)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .glassCard(radius: 18)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 16).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            Text(verbatim: appName).font(.largeTitle.weight(.semibold))
            Text(versionLine).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            // The answer arrives as a notification, the same way the menu's "Check for Updates" reports it.
            Button {
                container.updates.checkApp(force: true)
            } label: {
                HStack(spacing: 6) {
                    if container.updates.isCheckingApp { ProgressView().controlSize(.small) }
                    Text(String(localized: "Check for Updates"))
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(container.updates.isCheckingApp)
            .padding(.top, 6)
        }
    }

    private var versionLine: String {
        let version = container.updates.installedVersion
        return build.isEmpty || build == version
            ? String(localized: "Version \(version)")
            : String(localized: "Version \(version) (\(build))")
    }

    /// One line of the card: its name on the left, the value on the right, as in the settings section.
    private func row(_ title: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            value().foregroundStyle(.secondary)
        }
    }
}
