import Foundation
import WatchConnectivity

/// Sincroniza iPhone ⇄ Apple Watch.
/// - iPhone → reloj: lista de tareas, URL del servidor y código de acceso (applicationContext, siempre llega la última versión).
/// - Reloj → iPhone: registros que el reloj no pudo enviar al servidor (transferUserInfo, entrega garantizada).
final class Connectivity: NSObject, WCSessionDelegate {
    static let shared = Connectivity()

    private enum Key {
        static let tasks = "tasks"
        static let serverURL = "serverURL"
        static let accessCode = "accessCode"
        static let accumulate = "accumulate"
        static let entry = "entry"
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    #if os(iOS)
    /// Envía la configuración actual al reloj.
    @MainActor
    func pushContext() {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        let tasks = (try? JSONEncoder().encode(TaskStore.shared.tasks)) ?? Data()
        let settings = AppSettings.shared
        try? session.updateApplicationContext([
            Key.tasks: tasks,
            Key.serverURL: settings.serverURL,
            Key.accessCode: settings.accessCode,
            Key.accumulate: settings.accumulateDaily,
            "sentAt": Date().timeIntervalSince1970,
        ])
    }
    #endif

    #if os(watchOS)
    /// Pasa al iPhone un registro para que lo suba él.
    func sendToPhone(_ entry: LogEntry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        WCSession.default.transferUserInfo([Key.entry: data])
    }

    @MainActor
    private func apply(context: [String: Any]) {
        if let data = context[Key.tasks] as? Data,
           let tasks = try? JSONDecoder().decode([StudyTask].self, from: data) {
            TaskStore.shared.tasks = tasks
        }
        if let serverURL = context[Key.serverURL] as? String {
            AppSettings.shared.serverURL = serverURL
        }
        if let accessCode = context[Key.accessCode] as? String {
            AppSettings.shared.accessCode = accessCode
        }
        if let accumulate = context[Key.accumulate] as? Bool {
            AppSettings.shared.accumulateDaily = accumulate
        }
    }
    #endif

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        #if os(iOS)
        Task { @MainActor in self.pushContext() }
        #else
        let context = session.receivedApplicationContext
        if !context.isEmpty {
            Task { @MainActor in self.apply(context: context) }
        }
        #endif
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.pushContext() }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[Key.entry] as? Data,
              let entry = try? JSONDecoder().decode(LogEntry.self, from: data) else { return }
        Task { @MainActor in
            LogUploader.shared.enqueue(entry)
            await LogUploader.shared.flush()
        }
    }
    #endif

    #if os(watchOS)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(context: applicationContext) }
    }
    #endif
}
