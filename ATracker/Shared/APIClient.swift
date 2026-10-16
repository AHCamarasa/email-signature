import Foundation

/// Cliente del servidor Atracker en Oracle. El servidor es quien habla con Notion;
/// las apps solo conocen la URL del servidor y tu código de acceso personal.
enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Falta la URL del servidor o el código de acceso. Añádelos en Ajustes del iPhone."
        case .invalidURL:
            "La URL del servidor no es válida."
        case let .http(401, _):
            "Código de acceso incorrecto."
        case let .http(status, message):
            "El servidor respondió \(status): \(message)"
        }
    }
}

struct APIClient {
    var serverURL: String
    var accessCode: String

    private struct EntryBody: Encodable {
        let id: String
        let subject_id: String
        let tag: String
        let pec_id: String?
        let minutes: Int
        let day: String
        let accumulate: Bool
    }

    private struct EntryResult: Decodable {
        let total: Int
        let duplicate: Bool
    }

    private struct ErrorBody: Decodable {
        let detail: String?
    }

    func fetchSubjects(course: String) async throws -> [Subject] {
        let course = course.trimmingCharacters(in: .whitespaces)
        let query = course.isEmpty ? [] : [URLQueryItem(name: "course", value: course)]
        return try await send("GET", "subjects", query: query)
    }

    func fetchPECs(for subject: Subject) async throws -> [PECItem] {
        try await send("GET", "subjects/\(subject.id)/pecs")
    }

    /// Envía los minutos al servidor. Si la app reintenta el mismo registro (mismo `entry.id`),
    /// el servidor no lo suma dos veces. Devuelve los minutos totales del registro en Notion.
    @discardableResult
    func log(_ entry: LogEntry, accumulate: Bool) async throws -> Int {
        let body = EntryBody(
            id: entry.id.uuidString,
            subject_id: entry.task.subject.id,
            tag: entry.task.tag,
            pec_id: entry.task.pec?.id,
            minutes: entry.minutes,
            day: entry.day,
            accumulate: accumulate
        )
        let result: EntryResult = try await send("POST", "entries", json: try JSONEncoder().encode(body))
        return result.total
    }

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        json: Data? = nil
    ) async throws -> Response {
        let base = serverURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !accessCode.isEmpty else { throw APIError.notConfigured }
        guard var components = URLComponents(string: base.hasSuffix("/") ? base + path : base + "/" + path) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("Bearer \(accessCode)", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = json
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw APIError.http(status, detail ?? "error desconocido")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
