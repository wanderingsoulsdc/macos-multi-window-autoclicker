import SwiftUI
import ClickerCore

struct StepListDrag {
    let stepID: UUID
    let location: CGPoint
}

struct StepList: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var engine: RunEngine
    @State private var drag: StepListDrag?
    @State private var frames: [UUID: CGRect] = [:]
    @State private var collapsed: Set<UUID> = []
    @State private var groupEditor: GroupEditorRequest?
    static let coordinateSpace = "execution-list"

    var body: some View {
        GeometryReader { viewport in
            let blocks = model.plan.executionBlocks
            let drop = drag.flatMap { destination(from: $0.stepID, at: $0.location, in: viewport.size) }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(blocks) { block in
                            if let group = block.group {
                                VStack(spacing: 2) {
                                    groupHeader(group, block: block, canMove: blocks.count > 1, size: viewport.size)
                                    if !collapsed.contains(group.id) {
                                        ForEach(Array(model.plan.points[block.indices].enumerated()), id: \.element.id) { offset, point in
                                            let index = block.indices.lowerBound + offset
                                            let id = point.id
                                            tracked(id, drop: drop) { stepRow(at: index, canMove: block.indices.count > 1, size: viewport.size) }
                                                .padding(.leading, 12).id(id)
                                        }
                                    }
                                }
                                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                                .modifier(StepFrame(id: group.id, marked: drop?.id == group.id && drag?.stepID != group.id, placement: drop?.placement))
                            } else {
                                tracked(block.id, drop: drop) {
                                    stepRow(at: block.indices.lowerBound, canMove: blocks.count > 1, size: viewport.size)
                                }
                            }
                        }
                    }.padding(5)
                }
                .coordinateSpace(name: Self.coordinateSpace)
                .onPreferenceChange(StepFrames.self) { frames = $0 }
                .task(id: scrollDirection(in: viewport.size)) {
                    await scrollWhileDragging(in: viewport.size, with: scroll)
                }
            }
        }
        .sheet(item: $groupEditor) { GroupEditor(model: model, request: $0) }
    }

    private func stepRow(at index: Int, canMove: Bool, size: CGSize) -> some View {
        let point = model.plan.points[index]
        let create: (() -> Void)? = model.plan.groupEndChoices(startingAt: point.id).isEmpty ? nil : {
            groupEditor = .create(point.id)
        }
        return PointRow(model: model, engine: engine, point: point, index: index, drag: $drag,
                        canReorder: model.canEdit && canMove, createGroup: create) { location in
            finishDrag(from: point.id, at: location, in: size)
        }
    }

    private func groupHeader(_ group: LoopGroup, block: ExecutionBlock, canMove: Bool, size: CGSize) -> some View {
        let expanded = !collapsed.contains(group.id)
        let active = model.plan.points[block.indices].contains { $0.id == engine.currentPoint }
        return HStack(spacing: 6) {
            StepSortHandle(model: model, id: group.id, label: "拖拽排序\(group.title)",
                           enabled: model.canEdit && canMove, drag: $drag,
                           endDrag: { finishDrag(from: group.id, at: $0, in: size) }) {
                EmptyView()
            }
            Button {
                if expanded { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    Text(group.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("×\(group.rounds)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "折叠" : "展开")\(group.title)，循环 \(group.rounds) 次")
            Menu {
                Button("编辑循环组…") { groupEditor = .edit(group) }
                Button("解散循环组") { model.ungroup(group.id) }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(group.title)操作").disabled(!model.canEdit)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(active ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }

    private func tracked<V: View>(_ id: UUID, drop: (id: UUID, placement: ClickPlan.MovePlacement)?, @ViewBuilder content: () -> V) -> some View {
        content().modifier(StepFrame(id: id, marked: drop?.id == id && drag?.stepID != id, placement: drop?.placement))
    }

    private func finishDrag(from id: UUID, at location: CGPoint, in size: CGSize) {
        drag = nil
        guard let target = destination(from: id, at: location, in: size) else { return }
        model.movePoint(id, relativeTo: target.id, placement: target.placement)
    }

    private func siblings(of id: UUID) -> [UUID] {
        if let parent = model.plan.points.first(where: { $0.id == id })?.groupID {
            return model.plan.points.filter { $0.groupID == parent }.map(\.id)
        }
        return model.plan.executionBlocks.map(\.id)
    }

    private func destination(from id: UUID, at location: CGPoint, in size: CGSize) -> (id: UUID, placement: ClickPlan.MovePlacement)? {
        let viewport = CGRect(origin: .zero, size: size)
        guard model.canEdit, viewport.contains(location) else { return nil }
        let candidates = siblings(of: id).compactMap { key -> (UUID, CGRect)? in
            guard let frame = frames[key], frame.intersects(viewport) else { return nil }
            return (key, frame)
        }
        if let parent = model.plan.points.first(where: { $0.id == id })?.groupID,
           frames[parent]?.contains(location) != true { return nil }
        let nearest = candidates.first(where: { $0.1.contains(location) }) ?? candidates.min {
            abs($0.1.midY - location.y) < abs($1.1.midY - location.y)
        }
        return nearest.map { ($0.0, location.y < $0.1.midY ? .before : .after) }
    }

    private func scrollDirection(in size: CGSize) -> Int {
        guard model.canEdit, let location = drag?.location,
              CGRect(origin: .zero, size: size).contains(location) else { return 0 }
        if location.y < 22 { return -1 }
        if location.y > size.height - 22 { return 1 }
        return 0
    }

    private func scrollWhileDragging(in size: CGSize, with scroll: ScrollViewProxy) async {
        let direction = scrollDirection(in: size)
        guard direction != 0 else { return }
        let viewport = CGRect(origin: .zero, size: size)
        while !Task.isCancelled && scrollDirection(in: size) == direction {
            guard let drag else { return }
            let ids = siblings(of: drag.stepID)
            let visible = ids.indices.filter { frames[ids[$0]]?.intersects(viewport) == true }
            guard let edge = direction < 0 ? visible.first : visible.last,
                  ids.indices.contains(edge + direction) else { return }
            scroll.scrollTo(ids[edge + direction], anchor: direction < 0 ? .top : .bottom)
            do { try await Task.sleep(for: .milliseconds(125)) }
            catch { return }
        }
    }
}

struct StepSortHandle<Content: View>: View {
    @ObservedObject var model: WorkspaceModel
    let id: UUID
    let label: String
    let enabled: Bool
    @Binding var drag: StepListDrag?
    let endDrag: (CGPoint) -> Void
    @ViewBuilder var content: () -> Content
    @GestureState private var dragging = false

    var body: some View {
        let handle = HStack(spacing: 3) {
            Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary).frame(minWidth: 14, minHeight: 23)
            content()
        }.fixedSize().contentShape(Rectangle())
        if enabled {
            handle.gesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(StepList.coordinateSpace))
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { drag = StepListDrag(stepID: id, location: $0.location) }
                .onEnded { endDrag($0.location) })
                .onChange(of: dragging) { _, active in
                    if !active, drag?.stepID == id { drag = nil }
                }
                .help("拖动手柄调整执行顺序")
                .accessibilityElement(children: .ignore).accessibilityLabel(label)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: model.movePoint(id, by: 1)
                    case .decrement: model.movePoint(id, by: -1)
                    @unknown default: break
                    }
                }
        } else { handle }
    }
}

private struct StepFrame: ViewModifier {
    let id: UUID
    let marked: Bool
    let placement: ClickPlan.MovePlacement?

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { row in
                Color.clear.preference(key: StepFrames.self, value: [id: row.frame(in: .named(StepList.coordinateSpace))])
            }
        }.overlay(alignment: placement == .after ? .bottom : .top) {
            if marked { Capsule().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false).accessibilityHidden(true) }
        }
    }
}

private struct StepFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
