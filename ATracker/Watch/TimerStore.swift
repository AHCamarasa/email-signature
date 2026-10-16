import Foundation
import Observation
import WatchKit

/// Temporizador del reloj. Al pararlo convierte el tiempo a minutos y los envía al servidor,
/// que los escribe en Notion; si no hay conexión, se lo pasa al iPhone para que lo envíe él.
@MainActor
@Observable
final class TimerStore {
    static let shared = TimerStore()

    private(set) var active: ActiveTimer? {
        didSet { save() }
    }
    private(set) var lastResult: String?
    private(set) var isSaving = false

    private let key = "activeTimer"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(ActiveTimer.self, from: data) {
            active = saved
        }
    }

    func isRunning(_ task: StudyTask) -> Bool {
        active?.taskID == task.id
    }

    func start(_ task: StudyTask) {
        guard active == nil else { return }
        active = ActiveTimer(taskID: task.id, start: .now)
        lastResult = nil
        WKInterfaceDevice.current().play(.start)
    }

    func cancel() {
        active = nil
        lastResult = "Descartado"
    }

    func stop() async {
        guard let timer = active else { return }
        active = nil
        WKInterfaceDevice.current().play(.stop)

        guard let task = TaskStore.shared.task(id: timer.taskID) else {
            lastResult = "La tarea ya no existe en el iPhone"
            return
        }

        let seconds = Date.now.timeIntervalSince(timer.start)
        guard seconds >= 30 else {
            lastResult = "Menos de 30 s: no se guarda"
            return
        }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let entry = LogEntry(task: task, minutes: minutes, day: DayFormatter.string(from: timer.start))

        isSaving = true
        defer { isSaving = false }
        do {
            let total = try await AppSettings.shared.client.log(entry, accumulate: AppSettings.shared.accumulateDaily)
            lastResult = total == minutes
                ? "✅ \(minutes) min guardados"
                : "✅ +\(minutes) min (hoy \(total) min)"
            WKInterfaceDevice.current().play(.success)
        } catch {
            // Sin red o sin configuración en el reloj: lo envía el iPhone en cuanto lo reciba.
            Connectivity.shared.sendToPhone(entry)
            lastResult = "📲 \(minutes) min enviados al iPhone"
        }
    }

    private func save() {
        if let active, let data = try? JSONEncoder().encode(active) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
