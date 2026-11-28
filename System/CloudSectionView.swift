//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct CloudSectionView: View {
    let provider: CloudProvider
    @Environment(AppContainer.self) private var container
    @State private var baseDraft = ""
    @State private var keyDraft = ""
    @State private var showAdvanced = false

    private var store: CloudStore { container.cloudStore(for: provider) }
    private var centered: Bool { !store.isSignedIn && !store.isSigningIn }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group(String(localized: "Account")) { account }
                if store.isSignedIn {
                    group(String(localized: "Models")) { models }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden(true, for: .top)
        .onAppear {
            baseDraft = provider == store.provider ? store.baseAPI.absoluteString : provider.defaultBaseAPI
            keyDraft = store.isSignedIn && !provider.usesOAuth ? keyDraft : ""
            Task { await store.refresh() }
        }
    }

    private var account: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .center, spacing: 12) {
                    identity
                    if provider.usesOAuth, !store.isSignedIn, !store.isSigningIn {
                        Button(String(localized: "Sign in with Browser…")) { store.signIn() }
                            .buttonStyle(.glass)
                    }
                }
                if store.isSignedIn { accountStatus }
            }
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            if let error = store.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !provider.usesOAuth, !store.isSignedIn { apiKeyEntry }
            if store.isSigningIn { signInProgress }
            if showAdvanced, provider.supportsCustomBaseAPI { advanced }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private var identity: some View {
        VStack(alignment: .center, spacing: 10) {
            Group {
                if let avatarURL = store.profile?.avatarURL {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        identitySymbol
                    }
                } else {
                    identitySymbol
                }
            }
            .frame(width: 64, height: 64).clipShape(Circle())
            VStack(alignment: .center, spacing: 3) {
                Text(store.accountName ?? provider.title).font(.title3.weight(.semibold))
                if let plan = store.profile?.planName ?? store.usage?.planName {
                    Text(plan).font(.callout).foregroundStyle(.secondary)
                } else if !store.isSignedIn {
                    Text(provider.accountPrompt).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 280)
                } else {
                    Text(provider.showsBalance ? String(localized: "Pay per token") : String(localized: "Subscription"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var identitySymbol: some View {
        Image(systemName: store.isSignedIn ? "checkmark.circle.fill" : provider.usesOAuth ? "person.crop.circle.fill" : "key.fill")
            .font(.system(size: 52)).foregroundStyle(store.isSignedIn ? Color.accentColor : .secondary)
    }

    private var apiKeyEntry: some View {
        VStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                SecureField(String(localized: "API key"), text: $keyDraft)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 240, maxWidth: 360)
                    .onSubmit(connect)
                Button(String(localized: "Connect"), action: connect)
                    .buttonStyle(.glass)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            if let url = provider.apiKeyURL {
                Button(String(localized: "Get an API key")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link).font(.callout)
            }
        }
    }

    private func connect() {
        store.setAPIKey(keyDraft)
        keyDraft = ""
    }

    @ViewBuilder
    private var signInProgress: some View {
        if let code = store.signInCode {
            row(String(localized: "Enter this code"), help: String(localized: "The browser page asks for it to confirm the sign-in")) {
                Text(code).font(.title3.monospaced()).textSelection(.enabled)
            }
        }
        row(String(localized: "Waiting for confirmation…")) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                if let url = store.signInURL {
                    Button(String(localized: "Open Browser")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.glass)
                }
                Button(String(localized: "Cancel")) { store.cancelSignIn() }
                    .buttonStyle(.glass)
            }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            row(String(localized: "Base API"), help: String(localized: "Empty means \(provider.defaultBaseAPI); press Return to apply")) {
                TextField(provider.defaultBaseAPI, text: $baseDraft)
                    .frame(width: 320)
                    .onSubmit { store.setBaseAPI(baseDraft) }
            }
            if provider.showsAPIKeyInAdvanced {
                row(String(localized: "API key"), help: String(localized: "Only for a custom endpoint; browser sign-in is used otherwise")) {
                    SecureField(String(localized: "Optional"), text: $keyDraft)
                        .frame(width: 320)
                        .onSubmit { store.setAPIKey(keyDraft) }
                }
            }
        }
    }

    private var accountStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch provider {
            case .deepSeek: deepSeekBalance
            case .alibaba: alibabaLimits
            case .kimi, .openAI: quota
            }
            HStack(spacing: 12) {
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
                Button(provider == .deepSeek ? String(localized: "Top Up") : String(localized: "Manage Subscription")) {
                    NSWorkspace.shared.open(provider.accountURL)
                }
                .buttonStyle(.glass)
                if provider.supportsCustomBaseAPI {
                    Button {
                        showAdvanced.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(String(localized: "Advanced"))
                            Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.glass)
                    .foregroundStyle(.secondary)
                }
                Button(String(localized: "Sign Out")) { store.signOut() }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var deepSeekBalance: some View {
        if store.balances.isEmpty {
            loadingMetric(String(localized: "Balance"))
        } else {
            ForEach(store.balances) { balance in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(String(localized: "Available balance"))
                        Spacer()
                        Text(Self.money(balance.total, currency: balance.currency)).font(.title3.weight(.semibold))
                    }
                    HStack {
                        Text(String(localized: "Granted")).foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.money(balance.granted, currency: balance.currency)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(String(localized: "Topped up")).foregroundStyle(.secondary)
                        Spacer()
                        Text(Self.money(balance.toppedUp, currency: balance.currency)).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var alibabaLimits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Coding Plan Pro limits")).font(.callout.weight(.semibold))
            limitRow(String(localized: "Every 5 hours"), requests: 6_000)
            limitRow(String(localized: "Every week"), requests: 45_000)
            limitRow(String(localized: "Every month"), requests: 90_000)
            Text(String(localized: "Alibaba does not expose current Coding Plan consumption through its API. Open the console for the live remaining quota."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func limitRow(_ title: String, requests: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(String(localized: "\(requests.formatted()) requests"))
        }
        .font(.callout)
    }

    @ViewBuilder
    private var quota: some View {
        if let usage = store.usage, !usage.entries.isEmpty {
            ForEach(usage.entries) { entry in quotaRow(entry) }
        } else {
            loadingMetric(String(localized: "Quota"))
        }
    }

    private func loadingMetric(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            if store.isRefreshing { ProgressView().controlSize(.small) }
        }
    }

    private func quotaRow(_ entry: CloudQuota.Entry) -> some View {
        let used = max(0, min(1, entry.usedRatio))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.title)
                Text(String(localized: "\(used.formatted(.percent.precision(.fractionLength(0)))) used")).foregroundStyle(.secondary)
                Spacer()
                if let reset = entry.resetAt {
                    Text(String(localized: "Resets \(reset.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: used)
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.catalog.isEmpty, !store.isRefreshing {
                Text(String(localized: "No models available for this account."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(store.catalog) { model in
                Divider()
                modelRow(model)
            }
        }
    }

    private func modelRow(_ model: CloudModel) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                Text(model.id).font(.caption).foregroundStyle(.secondary)
                if let detail = model.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.contextOptions.count > 1 {
                ChoiceMenu(
                    items: model.contextOptions,
                    choose: { store.setContext($0, for: model) },
                    row: { Text(verbatim: Self.contextLabel($0)) }
                ) {
                    Text(verbatim: Self.contextLabel(store.context(for: model))).font(.callout)
                }
                .fixedSize()
            }
            ChoiceMenu(
                items: AppContainer.outputTokenLimits,
                choose: { container.setOutputTokenLimit($0, forModelID: store.modelID(for: model)) },
                row: { Text(verbatim: "↓" + Self.contextLabel($0)) }
            ) {
                Text(verbatim: "↓" + Self.contextLabel(container.outputTokenLimit(forModelID: store.modelID(for: model)))).font(.callout)
            }
            .fixedSize()
            if !model.efforts.isEmpty {
                ChoiceMenu(
                    items: model.efforts,
                    choose: { store.setEffort($0, for: model) },
                    row: { Text(verbatim: $0) }
                ) {
                    Text(verbatim: store.effort(for: model)).font(.callout)
                }
                .fixedSize()
            }
            reasoningButton(model)
            Toggle("", isOn: Binding(get: { store.isEnabled(model) }, set: { store.setEnabled($0, for: model) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func reasoningButton(_ model: CloudModel) -> some View {
        let id = store.modelID(for: model)
        let shown = container.showsReasoning(modelID: id)
        return SymbolButton(
            symbol: shown ? "eye" : "eye.slash",
            help: shown ? String(localized: "The chat shows how this model thinks") : String(localized: "Show how this model thinks"),
            style: shown ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
        ) {
            container.setShowsReasoning(!shown, forModelID: id)
        }
    }

    private static func contextLabel(_ tokens: Int) -> String {
        tokens >= 1_000_000 ? "\(tokens / 1_000_000)M" : "\(tokens / 1024)K"
    }

    private static func money(_ value: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: value)) ?? "\(value) \(currency)"
    }

    private func row(_ title: String, help: String? = nil, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let help {
                    Text(help).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(radius: 18)
    }
}
