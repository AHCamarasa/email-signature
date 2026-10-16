import Foundation

/// Tipo de trabajo que se está haciendo en una asignatura.
enum TaskKind: String, Codable, CaseIterable, Identifiable {
    case pec
    case apuntes
    case estudiar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pec: "PEC"
        case .apuntes: "Apuntes"
        case .estudiar: "Estudiar"
        }
    }

    var symbol: String {
        switch self {
        case .pec: "doc.text"
        case .apuntes: "pencil"
        case .estudiar: "book"
        }
    }

    /// Opciones de la propiedad multi-select "Tareas" de Atracker que encajan con cada tipo.
    var tagOptions: [String] {
        switch self {
        case .pec: (1...5).map { "PEC \($0)" }
        case .apuntes: (1...5).map { "Módulo \($0)" }
        case .estudiar: ["Examen"] + (1...5).map { "Módulo \($0)" }
        }
    }
}

/// Página de la base de datos "Asignaturas".
struct Subject: Codable, Hashable, Identifiable {
    let id: String
    var name: String
}

/// Página de la base de datos "PECS" (PEC, apuntes o examen de una asignatura).
struct PECItem: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var tipo: String?
    var estado: String?

    var isDone: Bool {
        guard let estado else { return false }
        return ["Finalizado", "Subir", "Subido"].contains(estado)
    }
}

/// Una asignatura + la tarea concreta que se cronometra desde el reloj.
struct StudyTask: Codable, Hashable, Identifiable {
    var id = UUID()
    var subject: Subject
    var kind: TaskKind
    /// Valor de "Tareas" en Atracker (p. ej. "PEC 1", "Módulo 2", "Examen").
    var tag: String
    /// Página de PECS relacionada (propiedad "PEC" en Atracker).
    var pec: PECItem?

    var subtitle: String { "\(kind.title) · \(tag)" }
}

/// Minutos pendientes de escribir en Notion.
struct LogEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var task: StudyTask
    var minutes: Int
    /// Día del registro en formato yyyy-MM-dd (propiedad "Fecha").
    var day: String
}

/// Temporizador en marcha. Se guarda la hora de inicio, así sobrevive a que el sistema suspenda la app.
struct ActiveTimer: Codable, Equatable {
    var taskID: UUID
    var start: Date
}

enum DayFormatter {
    static func string(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

extension StudyTask {
    /// Elige la página de PECS que mejor encaja con el tipo y la etiqueta elegidos.
    static func suggestedPEC(kind: TaskKind, tag: String, in items: [PECItem]) -> PECItem? {
        let open = items.filter { !$0.isDone }
        let candidates = open.isEmpty ? items : open
        switch kind {
        case .pec:
            return candidates.first { $0.tipo == "PEC" && $0.title.localizedCaseInsensitiveContains(tag) }
                ?? candidates.first { $0.tipo == "PEC" }
        case .apuntes:
            return candidates.first { $0.tipo == "Apuntes" }
        case .estudiar:
            return candidates.first { $0.title.localizedCaseInsensitiveContains("Examen") }
                ?? candidates.first { $0.tipo == "Apuntes" }
        }
    }
}
