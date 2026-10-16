import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var uploader = LogUploader.shared
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://tu-servidor/atracker", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Código de acceso", text: $settings.accessCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await testConnection() }
                    } label: {
                        if testing { ProgressView() } else { Text("Probar conexión") }
                    }
                    .disabled(!settings.isConfigured || testing)
                    if let status {
                        Text(status).font(.footnote)
                    }
                } header: {
                    Text("Servidor")
                } footer: {
                    Text("Tu servidor Atracker en Oracle. El código de acceso es el ATRACKER_ACCESS_CODE del archivo .env del servidor; se guarda en el Llavero.")
                }

                Section {
                    TextField("2026/27", text: $settings.course)
                    Toggle("Sumar al registro del día", isOn: $settings.accumulateDaily)
                } header: {
                    Text("Registros")
                } footer: {
                    Text("Si está activado y ya existe un registro de hoy con la misma asignatura, tarea y PEC, se suman los minutos en vez de crear otro.")
                }

                Section("Apple Watch") {
                    Button("Enviar tareas al reloj") { Connectivity.shared.pushContext() }
                }

                Section("Pendientes de subir") {
                    LabeledContent("Registros", value: "\(uploader.pending.count)")
                    ForEach(uploader.pending) { entry in
                        LabeledContent("\(entry.task.subject.name) · \(entry.task.tag)", value: "\(entry.minutes) min · \(entry.day)")
                            .font(.footnote)
                    }
                    if let error = uploader.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Reintentar") { Task { await uploader.flush() } }
                        .disabled(uploader.pending.isEmpty)
                }
            }
            .navigationTitle("Ajustes")
            .onChange(of: settings.serverURL) { _, _ in Connectivity.shared.pushContext() }
            .onChange(of: settings.accessCode) { _, _ in Connectivity.shared.pushContext() }
            .onChange(of: settings.accumulateDaily) { _, _ in Connectivity.shared.pushContext() }
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let subjects = try await settings.client.fetchSubjects(course: settings.course)
            status = "✅ Conectado: \(subjects.count) asignaturas en \(settings.course.isEmpty ? "todos los cursos" : settings.course)."
            await uploader.flush()
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }
}
