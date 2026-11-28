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

    private var picker: some View {
        Picker("Show as", selection: $layout) {
            ForEach(TasksLayout.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Tasks").font(.largeTitle.bold())
                Spacer()
                picker
                Button("New Task", systemImage: "plus") { editing = TaskDraft() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 6)
            #endif
            switch layout {
            case .list: TaskList(editing: $editing)
            case .matrix: TaskMatrix(editing: $editing)
            }
        }
        .navigationTitle("Tasks")
        .inlineTitle()
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .principal) { picker }
            ToolbarItem(placement: .primaryAction) {
                Button("New Task", systemImage: "plus") { editing = TaskDraft() }
            }
        }
        #endif
        .sheet(item: $editing) { TaskEditor(draft: $0) }
    }
}

/// Today, Upcoming and Someday, like a list in Reminders: a row to add a
/// task straight away, and finished tasks out of sight until you ask.
private struct TaskList: View {
    @Environment(AppModel.self) private var app
    @Binding var editing: TaskDraft?
    @State private var newTitle = ""
    @State private var showingDone = false
    @State private var confirmingClear = false
    @FocusState private var adding: Bool

    var body: some View {
        let repo = app.repo
        let done = repo.tasks(in: .done)
        let open = [TaskGroup.today, .upcoming, .someday].map { ($0, repo.tasks(in: $0)) }.filter { !$0.1.isEmpty }
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    TextField("New Task", text: $newTitle)
                        .textFieldStyle(.plain)
                        .focused($adding)
                        .onSubmit(add)
                        .submitLabel(.done)
                }
                .padding(.vertical, 2)
            } footer: {
                if repo.tasks.isEmpty {
                    Text("Add anything you need to do once, like renewing your passport. Tap a task to give it a due date, or to mark it as important or urgent.")
                }
            }
            ForEach(open, id: \.0) { group, tasks in
                Section(group.label) {
                    ForEach(tasks) { TaskRow(task: $0, editing: $editing, inToday: group == .today) }
                }
            }
            if !done.isEmpty {
                Section {
                    if showingDone {
                        ForEach(done) { TaskRow(task: $0, editing: $editing) }
                    }
                    Button(showingDone ? "Hide Finished Tasks" : "Show Finished Tasks (\(done.count))") {
                        withAnimation { showingDone.toggle() }
                    }
                    if showingDone {
                        Button("Delete Finished Tasks", role: .destructive) { confirmingClear = true }
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
                // Only ones still finished: another device may have
                // reopened one while this was asking.
                for t in done where repo.tasks.first(where: { $0.id == t.id })?.done == true {
                    repo.deleteTask(t.id)
                }
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
        adding = true  // ready for the next one
    }
}

/// The Eisenhower matrix as a 2×2 grid that fills the screen: urgent on
/// the left, important on top, so "Do it now" is the top-left box.
private struct TaskMatrix: View {
    @Binding var editing: TaskDraft?

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]).frame(width: 14, height: 0)
                AxisLabel(text: "Urgent")
                AxisLabel(text: "Not urgent")
            }
            GridRow {
                AxisLabel(text: "Important", vertical: true)
                QuadrantBox(box: .doNow, editing: $editing)
                QuadrantBox(box: .plan, editing: $editing)
            }
            GridRow {
                AxisLabel(text: "Not important", vertical: true)
                QuadrantBox(box: .keepQuick, editing: $editing)
                QuadrantBox(box: .later, editing: $editing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 4)
    }
}

private struct AxisLabel: View {
    let text: String
    var vertical = false

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .fixedSize()
            .rotationEffect(vertical ? .degrees(-90) : .zero)
            .frame(width: vertical ? 14 : nil)
            .frame(maxWidth: vertical ? nil : .infinity)
    }
}

private struct QuadrantBox: View {
    @Environment(AppModel.self) private var app
    let box: TaskQuadrant
    @Binding var editing: TaskDraft?

    var body: some View {
        let tasks = app.repo.tasks(in: box)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: box.symbol)
                Text(box.label).lineLimit(1).minimumScaleFactor(0.8)
                if !tasks.isEmpty {
                    Text("\(tasks.count)").foregroundStyle(box.color.opacity(0.7))
                }
                Spacer(minLength: 0)
                Button("New Task in \(box.label)", systemImage: "plus") {
                    editing = TaskDraft(important: box == .doNow || box == .plan,
                        urgent: box == .doNow || box == .keepQuick)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(box.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if tasks.isEmpty {
                Text(box.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tasks) { task in
                            MatrixTaskRow(task: task, color: box.color, editing: $editing)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(box.color.opacity(0.07), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(box.color.opacity(0.18)))
    }
}

/// A task in a box of the matrix: smaller than in the list, so a few fit
/// even on a phone.
private struct MatrixTaskRow: View {
    @Environment(AppModel.self) private var app
    let task: TaskItem
    let color: Color
    @Binding var editing: TaskDraft?

    var body: some View {
        let repo = app.repo
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TickButton(task: task, color: color, font: .body)
            Button {
                editing = TaskDraft(task)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(.subheadline).lineLimit(2)
                    if let due = dueText(task, today: repo.today) {
                        Text(due.text).font(.caption2).foregroundStyle(due.overdue ? .red : .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .contextMenu { TaskMenu(task: task, editing: $editing) }
    }
}

extension TaskQuadrant {
    var color: Color {
        switch self {
        case .doNow: .red
        case .plan: .blue
        case .keepQuick: .orange
        case .later: .gray
        }
    }

    var symbol: String {
        switch self {
        case .doNow: "flame.fill"
        case .plan: "calendar"
        case .keepQuick: "bolt.fill"
        case .later: "clock.fill"
        }
    }
}

/// "Overdue", "Today", "Tomorrow", or the date ("Fri, Dec 4"). Nil if the
/// task has no date or is done, or (with `hidingToday`) if it's due today,
/// as in the Today section where that goes without saying.
func dueText(_ t: TaskItem, today: Date, hidingToday: Bool = false) -> (text: String, overdue: Bool)? {
    guard !t.done, let days = t.daysUntilDue(today: today) else { return nil }
    if days == 0 && hidingToday { return nil }
    if let label = dueLabel(t, today: today) { return (label, days < 0) }
    guard let d = t.due.flatMap(Days.parse) else { return nil }
    return (d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), false)
}

/// The circle that ticks a task off. Its color is the task's box in the
/// matrix, so you can tell what matters at a glance.
private struct TickButton: View {
    @Environment(AppModel.self) private var app
    let task: TaskItem
    let color: Color
    var font: Font = .title2

    var body: some View {
        Button {
            withAnimation { app.repo.setTaskDone(task.id, !task.done) }
        } label: {
            Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                .font(font)
                .foregroundStyle(task.done ? Color.secondary : color)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.done ? "Mark \(task.title) as not done" : "Mark \(task.title) as done")
        .sensoryFeedback(.success, trigger: task.done) { _, done in done }
    }
}

/// Important, Urgent, Edit and Delete, on a touch and hold or right-click.
private struct TaskMenu: View {
    @Environment(AppModel.self) private var app
    let task: TaskItem
    @Binding var editing: TaskDraft?

    var body: some View {
        let repo = app.repo
        let due = task.due.flatMap(Days.parse)
        Toggle("Important", systemImage: "star", isOn: Binding(get: { task.important }, set: {
            repo.updateTask(task.id, title: task.title, due: due, important: $0, urgent: task.urgent)
        }))
        Toggle("Urgent", systemImage: "bolt", isOn: Binding(get: { task.urgent }, set: {
            repo.updateTask(task.id, title: task.title, due: due, important: task.important, urgent: $0)
        }))
        Button("Edit", systemImage: "pencil") { editing = TaskDraft(task) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { repo.deleteTask(task.id) }
    }
}

/// A task in a list: the tick circle, its title, and when it's due if
/// that's worth saying. Tapping it opens it to edit.
struct TaskRow: View {
    @Environment(AppModel.self) private var app
    let task: TaskItem
    @Binding var editing: TaskDraft?
    /// In a list of today's tasks, so "Today" goes without saying.
    var inToday = false

    var body: some View {
        let repo = app.repo
        let due = dueText(task, today: repo.today, hidingToday: inToday)
        HStack(spacing: 12) {
            TickButton(task: task, color: taskQuadrant(task).color)
            Button {
                editing = TaskDraft(task)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .strikethrough(task.done)
                        .foregroundStyle(task.done ? .secondary : .primary)
                    if let due {
                        Text(due.text)
                            .font(.subheadline)
                            .foregroundStyle(due.overdue ? .red : .secondary)
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
        .contextMenu { TaskMenu(task: task, editing: $editing) }
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
