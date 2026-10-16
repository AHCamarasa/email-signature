import Foundation
import Observation
import Security

/// Guarda el código de acceso al servidor en el llavero del dispositivo.
enum Keychain {
    private static let service = "ATracker"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// URL del servidor Atracker en Oracle, p. ej. https://tu-dominio/atracker
    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") }
    }

    /// Código de acceso personal (el mismo que ATRACKER_ACCESS_CODE en el .env del servidor).
    var accessCode: String {
        didSet { Keychain.set(accessCode, for: "accessCode") }
    }

    var isConfigured: Bool { !serverURL.isEmpty && !accessCode.isEmpty }

    /// Valor de "Curso académico" con el que se filtran las asignaturas. Vacío = todas.
    var course: String {
        didSet { UserDefaults.standard.set(course, forKey: "course") }
    }

    /// Suma los minutos al registro del mismo día en vez de crear uno nuevo.
    var accumulateDaily: Bool {
        didSet { UserDefaults.standard.set(accumulateDaily, forKey: "accumulateDaily") }
    }

    var client: APIClient { APIClient(serverURL: serverURL, accessCode: accessCode) }

    private init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        accessCode = Keychain.get("accessCode") ?? ""
        course = UserDefaults.standard.string(forKey: "course") ?? "2026/27"
        accumulateDaily = UserDefaults.standard.object(forKey: "accumulateDaily") as? Bool ?? true
    }
}

/// Asignaturas + tareas configuradas en el iPhone y sincronizadas al reloj.
@MainActor
@Observable
final class TaskStore {
    static let shared = TaskStore()

    var tasks: [StudyTask] = [] {
        didSet { save() }
    }

    private let key = "tasks"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([StudyTask].self, from: data) {
            tasks = saved
        }
    }

    func task(id: UUID) -> StudyTask? {
        tasks.first { $0.id == id }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Cola de registros que aún no se han podido enviar al servidor (sin conexión, error, etc.).
@MainActor
@Observable
final class LogUploader {
    static let shared = LogUploader()

    private(set) var pending: [LogEntry] = [] {
        didSet { save() }
    }
    private(set) var lastError: String?
    private var isFlushing = false
    private let key = "pendingEntries"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([LogEntry].self, from: data) {
            pending = saved
        }
    }

    /// Intenta escribir el registro ya mismo. Si falla, lo deja en cola y lanza el error.
    @discardableResult
    func upload(_ entry: LogEntry) async throws -> Int {
        let settings = AppSettings.shared
        do {
            let total = try await settings.client.log(entry, accumulate: settings.accumulateDaily)
            lastError = nil
            return total
        } catch {
            enqueue(entry)
            lastError = error.localizedDescription
            throw error
        }
    }

    func enqueue(_ entry: LogEntry) {
        guard !pending.contains(where: { $0.id == entry.id }) else { return }
        pending.append(entry)
    }

    func flush() async {
        guard !isFlushing, !pending.isEmpty, AppSettings.shared.isConfigured else { return }
        isFlushing = true
        defer { isFlushing = false }
        let settings = AppSettings.shared
        for entry in pending {
            do {
                try await settings.client.log(entry, accumulate: settings.accumulateDaily)
                pending.removeAll { $0.id == entry.id }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
