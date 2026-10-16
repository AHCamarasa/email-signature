import SwiftUI

/// Lista de asignaturas + tarea que aparecerán en el Apple Watch.
struct TasksView: View {
    @State private var store = TaskStore.shared
    @State private var showingAdd = false

    private struct SubjectGroup: Identifiable {
        let subject: Subject
        let tasks: [StudyTask]
        var id: String { subject.id }
    }

    private var groups: [SubjectGroup] {
        Dictionary(grouping: store.tasks, by: \.subject)
            .map { SubjectGroup(subject: $0.key, tasks: $0.value) }
            .sorted { $0.subject.name.localizedCompare($1.subject.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups) { group in
                    Section(group.subject.name) {
                        ForEach(group.tasks) { task in
                            TaskRow(task: task)
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { group.tasks[$0].id }
                            store.tasks.removeAll { ids.contains($0.id) }
                            Connectivity.shared.pushContext()
                        }
                    }
                }
            }
            .overlay {
                if store.tasks.isEmpty {
                    ContentUnavailableView(
                        "Sin tareas",
                        systemImage: "stopwatch",
                        description: Text("Añade una asignatura y lo que estás haciendo (PEC, apuntes o estudiar). Aparecerá en el reloj.")
                    )
                }
            }
            .navigationTitle("Atracker")
            .toolbar {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
            .sheet(isPresented: $showingAdd) {
                AddTaskView { task in
                    store.tasks.append(task)
                    Connectivity.shared.pushContext()
                }
            }
        }
    }
}

private struct TaskRow: View {
    let task: StudyTask

    var body: some View {
        HStack {
            Image(systemName: task.kind.symbol)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(task.subtitle)
                if let pec = task.pec {
                    Text(pec.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Formulario: asignatura (de Notion) → tipo de tarea → etiqueta "Tareas" → página de PECS.
struct AddTaskView: View {
    var onSave: (StudyTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var settings = AppSettings.shared

    @State private var subjects: [Subject] = []
    @State private var pecs: [PECItem] = []
    @State private var subject: Subject?
    @State private var kind: TaskKind = .pec
    @State private var tag = "PEC 1"
    @State private var pec: PECItem?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Asignatura") {
                    if loading && subjects.isEmpty {
                        ProgressView()
                    } else {
                        Picker("Asignatura", selection: $subject) {
                            Text("Elige…").tag(Subject?.none)
                            ForEach(subjects) { Text($0.name).tag(Optional($0)) }
                        }
                    }
                }

                Section("¿Qué estás haciendo?") {
                    Picker("Tipo", selection: $kind) {
                        ForEach(TaskKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("Tareas", selection: $tag) {
                        ForEach(kind.tagOptions, id: \.self) { Text($0).tag($0) }
                    }
                }

                if subject != nil {
                    Section {
                        Picker("PEC / apuntes", selection: $pec) {
                            Text("Ninguno").tag(PECItem?.none)
                            ForEach(pecs) { item in
                                Text(item.title).tag(Optional(item))
                            }
                        }
                    } footer: {
                        Text("Página de la base de datos PECS que se enlaza en la propiedad «PEC» del registro.")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Nueva tarea")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        guard let subject else { return }
                        onSave(StudyTask(subject: subject, kind: kind, tag: tag, pec: pec))
                        dismiss()
                    }
                    .disabled(subject == nil)
                }
            }
            .task { await loadSubjects() }
            .onChange(of: subject) { _, _ in Task { await loadPECs() } }
            .onChange(of: kind) { _, newKind in
                tag = newKind.tagOptions[0]
                suggestPEC()
            }
            .onChange(of: tag) { _, _ in suggestPEC() }
        }
    }

    private func loadSubjects() async {
        loading = true
        defer { loading = false }
        do {
            subjects = try await settings.client.fetchSubjects(course: settings.course)
            error = subjects.isEmpty ? "No hay asignaturas para el curso «\(settings.course)»." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadPECs() async {
        pecs = []
        pec = nil
        guard let subject else { return }
        do {
            pecs = try await settings.client.fetchPECs(for: subject)
            suggestPEC()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggestPEC() {
        pec = StudyTask.suggestedPEC(kind: kind, tag: tag, in: pecs)
    }
}
