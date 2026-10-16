import SwiftUI

/// Asignaturas y tareas configuradas en el iPhone.
struct TaskListView: View {
    @State private var store = TaskStore.shared
    @State private var timer = TimerStore.shared

    var body: some View {
        NavigationStack {
            List {
                if let active = timer.active, let task = store.task(id: active.taskID) {
                    Section("En marcha") {
                        NavigationLink(value: task) {
                            VStack(alignment: .leading) {
                                Text(task.subject.name).lineLimit(1)
                                Text(active.start, style: .timer)
                                    .font(.title3.monospacedDigit())
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                Section {
                    ForEach(store.tasks) { task in
                        NavigationLink(value: task) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(task.subject.name).lineLimit(2)
                                    Text(task.subtitle)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: task.kind.symbol)
                            }
                        }
                    }
                }
            }
            .overlay {
                if store.tasks.isEmpty {
                    ContentUnavailableView(
                        "Sin asignaturas",
                        systemImage: "iphone",
                        description: Text("Añádelas desde la app del iPhone.")
                    )
                }
            }
            .navigationTitle("Atracker")
            .navigationDestination(for: StudyTask.self) { task in
                TimerView(task: task)
            }
        }
    }
}

struct TimerView: View {
    let task: StudyTask
    @State private var timer = TimerStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text(task.subject.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(task.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let active = timer.active, timer.isRunning(task) {
                    Text(active.start, style: .timer)
                        .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.green)

                    Button(role: .destructive) {
                        Task { await timer.stop() }
                    } label: {
                        Label("Parar y guardar", systemImage: "stop.fill")
                    }
                    .tint(.red)

                    Button("Descartar", role: .cancel) { timer.cancel() }
                        .font(.footnote)
                } else if timer.active != nil {
                    Text("Hay otro temporizador en marcha. Páralo primero.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.orange)
                } else if timer.isSaving {
                    ProgressView("Guardando…")
                } else {
                    Button {
                        timer.start(task)
                    } label: {
                        Label("Iniciar", systemImage: "play.fill")
                    }
                    .tint(.green)
                }

                if let result = timer.lastResult, timer.active == nil {
                    Text(result)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
