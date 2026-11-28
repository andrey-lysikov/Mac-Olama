//  Copyright © AndreyLysikov
//  SPDX-License-Identifier: Apache-2.0

import Foundation

// API server on the chosen port; a busy port blocks the switch.
extension AppContainer {
    private func updateAPISetting<V: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppSettings, V>, to value: V) {
        guard settings[keyPath: keyPath] != value else { return }
        settings[keyPath: keyPath] = value
        restartAPI()
    }

    func setAPIEnabled(_ enabled: Bool) { updateAPISetting(\.apiServerEnabled, to: enabled) }

    func setAPIBindHost(_ host: String) { updateAPISetting(\.apiBindHost, to: host) }

    func setAPIPort(_ port: Int) { updateAPISetting(\.apiServerPort, to: min(max(port, 1024), 65535)) }

    func restartAPI() {
        let previous = apiRestartTask
        apiGeneration += 1
        let generation = apiGeneration
        apiRestartTask = Task {
            await previous?.value
            guard generation == self.apiGeneration else { return }
            await self.startAPI()
        }
    }

    var corsPolicy: CORSPolicy { CORSPolicy.parse(mode: settings.apiCORSMode, origins: settings.apiCORSOrigins) }

    func setCORSMode(_ mode: String) {
        settings.apiCORSMode = mode
        apiServer?.setCORSPolicy(corsPolicy)
    }

    func setCORSOrigins(_ origins: String) {
        settings.apiCORSOrigins = origins
        apiServer?.setCORSPolicy(corsPolicy)
    }

    var apiURL: URL {
        let host = settings.apiBindHost == "0.0.0.0" ? (NetworkInterfaces.addresses().first?.address ?? "127.0.0.1") : settings.apiBindHost
        return URL(string: "http://\(host):\(settings.apiServerPort)")!
    }

    func startAPI() async {
        stopAPI()
        let port = settings.apiServerPort
        apiPortBusy = !HTTPServer.portIsFree(host: settings.apiBindHost, port: port)
        // Switched off in the settings: nothing listens, and no port is taken from anyone else.
        guard settings.apiServerEnabled else { return }
        guard !apiPortBusy else {
            apiStatus = .portBusy(port: port)
            NotificationService.shared.send(title: String(localized: "API port in use"), body: Self.portBusyText(port))
            return
        }
        apiStatus = .starting
        let server = APIServer(
            configuration: .init(
                host: settings.apiBindHost, port: port,
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"),
            catalog: catalog, engine: engineManager
        ) { [weak self] model in await self?.apiDefaults(for: model) ?? APIModelDefaults(contextTokens: model.contextLength) }
        server.setCORSPolicy(corsPolicy)
        do {
            try server.start()
        } catch {
            // Taken between the check and the bind.
            print("API bind on \(port) failed: \(error)")
            apiPortBusy = true
            apiStatus = .portBusy(port: port)
            return
        }
        apiServer = server
        apiStatus = .running(port: port)
    }

    func checkAPIPort() {
        guard apiServer == nil else { return }
        let busy = !HTTPServer.portIsFree(host: settings.apiBindHost, port: settings.apiServerPort)
        guard busy != apiPortBusy else { return }
        apiPortBusy = busy
        if !busy, settings.apiServerEnabled { restartAPI() }
    }

    static func portBusyText(_ port: Int) -> String {
        String(localized: "Port \(port) is taken by another program: choose a free one to turn the API on.")
    }

    func stopAPI() {
        apiServer?.stop()
        apiServer = nil
        apiStatus = .disabled
    }
}
