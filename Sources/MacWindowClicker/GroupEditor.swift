import SwiftUI
import ClickerCore

enum GroupEditorRequest: Identifiable {
    case create(UUID)
    case edit(LoopGroup)

    var id: UUID {
        switch self {
        case .create(let id): return id
        case .edit(let group): return group.id
        }
    }
}

struct GroupEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: WorkspaceModel
    let request: GroupEditorRequest
    @State private var name: String
    @State private var rounds: String
    @State private var end: UUID?
    @State private var error: String?

    init(model: WorkspaceModel, request: GroupEditorRequest) {
        self.model = model
        self.request = request
        switch request {
        case .create(let start):
            _name = State(initialValue: "循环组 \((model.plan.groupSettings?.count ?? 0) + 1)")
            _rounds = State(initialValue: "2")
            _end = State(initialValue: model.plan.groupEndChoices(startingAt: start).first.map { model.plan.points[$0].id })
        case .edit(let group):
            _name = State(initialValue: group.name)
            _rounds = State(initialValue: String(group.rounds))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(title).font(.headline)
            Form {
                if case .create(let start) = request, let first = model.plan.points.firstIndex(where: { $0.id == start }) {
                    LabeledContent("起始步骤", value: stepName(at: first))
                    Picker("结束步骤", selection: $end) {
                        ForEach(model.plan.groupEndChoices(startingAt: start), id: \.self) { index in
                            Text(stepName(at: index)).tag(Optional(model.plan.points[index].id))
                        }
                    }
                }
                TextField("组名称", text: $name)
                TextField("每轮循环次数", text: $rounds)
            }.textFieldStyle(.roundedBorder)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("每轮按组内顺序执行，循环结束后继续下一步。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saveTitle, action: save).keyboardShortcut(.defaultAction).disabled(!model.canEdit)
            }
        }.padding(22).frame(width: 365)
    }

    private var title: String {
        if case .create = request { return "创建循环组" }
        return "编辑循环组"
    }

    private var saveTitle: String {
        if case .create = request { return "创建" }
        return "保存"
    }

    private func stepName(at index: Int) -> String { "第 \(index + 1) 步 · \(model.plan.points[index].displayName(at: index))" }

    private func save() {
        do {
            guard let count = Int(rounds.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw PlanError.message("请输入整数循环次数。")
            }
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            switch request {
            case .create(let start):
                guard let end else { throw PlanError.message("请选择结束步骤。") }
                try model.createGroup(start: start, end: end, name: title, rounds: count)
            case .edit(let group):
                try model.editGroup(group.id, name: title, rounds: count)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
