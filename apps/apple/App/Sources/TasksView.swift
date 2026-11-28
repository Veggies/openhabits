import HabitsCore
import SwiftUI

/// How the Tasks tab shows your tasks: as a list by day, or sorted into
/// the Eisenhower matrix.
enum TasksLayout: String, CaseIterable {
    case list, matrix

    var label: String {
        switch self {
        case .list: "List"
        case .matrix: "Matrix"
        }
    }
}

/// The Tasks tab: one-off to-dos, listed as Today (with anything overdue),
/// Upcoming, Someday and Done, or sorted into the four boxes of the matrix.
struct TasksView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("tasksLayout") private var layout = TasksLayout.list
    @State private var editing: TaskDraft?

    var body: some View {
        Group {
            switch layout {
            case .list: TaskList(editing: $editing)
            case .matrix: TaskMatrix(editing: $editing)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 12) {
                #if os(macOS)
                HStack(alignment: .firstTextBaseline) {
                    Text("Tasks").font(.largeTitle.bold())
                    Spacer()
                    Button("New Task", systemImage: "plus") { editing = TaskDraft() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
                #endif
                Picker("Show as", selection: $layout) {
                    ForEach(TasksLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .navigationTitle("Tasks")
        .inlineTitle()
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Task", systemImage: "plus") { editing = TaskDraft() }
            }
        }
        #endif
        .sheet(item: $editing) { TaskEditor(draft: $0) }
    }
}

/// Today, Upcoming, Someday and Done, with a box at the top to add a task
/// quickly. Done tasks stay hidden until you ask to see them.
private struct TaskList: View {
    @Environment(AppModel.self) private var app
    @Binding var editing: TaskDraft?
    @State private var newTitle = ""
    @State private var showingDone = false
    @State private var confirmingClear = false

    var body: some View {
        let repo = app.repo
        let done = repo.tasks(in: .done)
        List {
            Section {
                TextField("Add a task", text: $newTitle, prompt: Text("Add a task"))
                    .onSubmit(add)
                    .submitLabel(.done)
            } footer: {
                if repo.tasks.isEmpty {
                    Text("Write down anything you need to do once, like renewing your passport. Tap a task to give it a due date, or to mark it as important or urgent.")
                }
            }
            ForEach([TaskGroup.today, .upcoming, .someday], id: \.self) { group in
                let tasks = repo.tasks(in: group)
                if !tasks.isEmpty {
                    Section(group.label) {
                        ForEach(tasks) { TaskRow(task: $0, editing: $editing) }
                    }
                }
            }
            if !done.isEmpty {
                Section {
                    if showingDone {
                        ForEach(done) { TaskRow(task: $0, editing: $editing) }
                        Button("Delete Finished Tasks", role: .destructive) { confirmingClear = true }
                    }
                } header: {
                    HStack {
                        Text("Done")
                        Spacer()
                        Button(showingDone ? "Hide" : "Show \(done.count)") {
                            withAnimation { showingDone.toggle() }
                        }
                        .font(.subheadline)
                        .textCase(nil)
                    }
                }
            }
        }
        .groupedList()
        .animation(.default, value: repo.tasks.map(\.id))
        .confirmationDialog("Delete all \(done.count) finished tasks?", isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete Finished Tasks", role: .destructive) {
                for t in done { repo.deleteTask(t.id) }
            }
        } message: {
            Text("This removes them from all your devices.")
        }
    }

    private func add() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        app.repo.addTask(title: title)
        newTitle = ""
    }
}

/// The four boxes of the Eisenhower matrix, side by side when there's
/// room. Each box's plus button adds a task already marked to go in it.
private struct TaskMatrix: View {
    @Environment(AppModel.self) private var app
    @Binding var editing: TaskDraft?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                ForEach(TaskQuadrant.allCases, id: \.self) { box in
                    QuadrantBox(box: box, editing: $editing)
                }
            }
            .padding(20)
        }
        .animation(.default, value: app.repo.tasks.map(\.id))
    }
}

private struct QuadrantBox: View {
    @Environment(AppModel.self) private var app
    let box: TaskQuadrant
    @Binding var editing: TaskDraft?

    var body: some View {
        let tasks = app.repo.tasks(in: box)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: box.symbol).foregroundStyle(box.color)
                Text(box.label).font(.headline)
                Spacer()
                Button("New Task in \(box.label)", systemImage: "plus") {
                    editing = TaskDraft(important: box == .doNow || box == .plan,
                        urgent: box == .doNow || box == .keepQuick)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            Text(box.hint).font(.subheadline).foregroundStyle(.secondary)
            if tasks.isEmpty {
                Text("Nothing here right now.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(tasks) { task in
                    Divider()
                    TaskRow(task: task, editing: $editing)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(box.color.opacity(0.08), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(box.color.opacity(0.25)))
    }
}

extension TaskQuadrant {
    var color: Color {
        switch self {
        case .doNow: .red
        case .plan: .blue
        case .keepQuick: .orange
        case .letGo: .gray
        }
    }

    var symbol: String {
        switch self {
        case .doNow: "flame"
        case .plan: "calendar"
        case .keepQuick: "bolt"
        case .letGo: "leaf"
        }
    }
}

/// A task with a circle to tick it off. Tapping the rest opens it to edit;
/// touch and hold (or right-click) to mark it important or urgent, or to
/// delete it.
struct TaskRow: View {
    @Environment(AppModel.self) private var app
    let task: TaskItem
    @Binding var editing: TaskDraft?

    var body: some View {
        let repo = app.repo
        let due = dueLabel(task, today: repo.today)
        let overdue = (task.daysUntilDue(today: repo.today) ?? 0) < 0
        HStack(spacing: 12) {
            Button {
                withAnimation { repo.setTaskDone(task.id, !task.done) }
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(task.done ? app.accent : .secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? "Mark \(task.title) as not done" : "Mark \(task.title) as done")
            .sensoryFeedback(.success, trigger: task.done) { _, done in done }

            Button {
                editing = TaskDraft(task)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .strikethrough(task.done)
                        .foregroundStyle(task.done ? .secondary : .primary)
                    if due != nil || task.important || task.urgent {
                        HStack(spacing: 6) {
                            if let due {
                                Text(due).foregroundStyle(overdue ? .red : .secondary)
                            }
                            if task.important { Tag(text: "Important", color: .blue) }
                            if task.urgent { Tag(text: "Urgent", color: .orange) }
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { repo.deleteTask(task.id) }
        }
        .contextMenu {
            Button(task.important ? "Not Important" : "Important", systemImage: "star") {
                repo.updateTask(task.id, title: task.title, due: task.due.flatMap(Days.parse),
                    important: !task.important, urgent: task.urgent)
            }
            Button(task.urgent ? "Not Urgent" : "Urgent", systemImage: "bolt") {
                repo.updateTask(task.id, title: task.title, due: task.due.flatMap(Days.parse),
                    important: task.important, urgent: !task.urgent)
            }
            Button("Edit", systemImage: "pencil") { editing = TaskDraft(task) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { repo.deleteTask(task.id) }
        }
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: .capsule)
    }
}

/// A task being added or edited.
struct TaskDraft: Identifiable {
    var taskId: String?
    var title = ""
    var hasDue = false
    var due = Date()
    var important = false
    var urgent = false

    var id: String { taskId ?? "new" }

    init(important: Bool = false, urgent: Bool = false) {
        self.important = important
        self.urgent = urgent
    }

    init(_ t: TaskItem) {
        taskId = t.id
        title = t.title
        if let d = t.due.flatMap(Days.parse) {
            hasDue = true
            due = d
        }
        important = t.important
        urgent = t.urgent
    }
}

struct TaskEditor: View {
    @State var draft: TaskDraft
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    private var title: String { draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Task", text: $draft.title, prompt: Text("Renew the passport"))
                }
                Section {
                    Toggle("Due date", isOn: $draft.hasDue.animation())
                    if draft.hasDue {
                        DatePicker("Due", selection: $draft.due, displayedComponents: .date)
                    }
                }
                Section {
                    Toggle("Important", isOn: $draft.important)
                    Toggle("Urgent", isOn: $draft.urgent)
                } footer: {
                    Text("Important means it matters to you. Urgent means it can't wait. Together they decide which box the task goes in on the matrix. This one goes in “\(taskQuadrant(preview).label).”")
                }
                if let id = draft.taskId {
                    Section {
                        Button("Delete Task", role: .destructive) { confirmingDelete = true }
                    }
                    .confirmationDialog("Delete \(title.isEmpty ? "this task" : title)?", isPresented: $confirmingDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Task", role: .destructive) {
                            app.repo.deleteTask(id)
                            dismiss()
                        }
                    } message: {
                        Text("This removes it from all your devices.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.taskId == nil ? "New Task" : "Edit Task")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(title.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 360)
        #endif
    }

    /// The task as it would be saved, to say which box it lands in.
    private var preview: TaskItem {
        TaskItem(id: "", fields: ["important": .bool(draft.important), "urgent": .bool(draft.urgent)])
    }

    private func save() {
        let due = draft.hasDue ? draft.due : nil
        if let id = draft.taskId {
            app.repo.updateTask(id, title: title, due: due, important: draft.important, urgent: draft.urgent)
        } else {
            app.repo.addTask(title: title, due: due, important: draft.important, urgent: draft.urgent)
        }
        dismiss()
    }
}
