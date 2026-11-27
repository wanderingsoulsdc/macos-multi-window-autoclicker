import SwiftUI
import ClickerCore

struct PointCanvas: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var engine: RunEngine
    @State private var zoom: Double = 0
    @State private var fitScale: Double = 1
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(model.preview == nil ? "坐标画布" : "窗口预览").font(.system(size: 11, weight: .medium))
                Text("\(Int(model.canvasFrame.width)) × \(Int(model.canvasFrame.height)) 点")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.target != nil {
                    Button { model.capturePreview() } label: { Image(systemName: model.capturing ? "hourglass" : "camera") }
                        .disabled(model.capturing || !model.canEdit).accessibilityLabel("截取窗口预览").help("刷新完整窗口截图")
                }
            }.buttonStyle(.borderless)
            HStack(spacing: 8) {
                Button { zoom = max(0.05, (zoom == 0 ? fitScale : zoom) / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("缩小预览")
                Text(zoom == 0 ? "完整显示" : "\(Int(zoom * 100))%")
                    .font(.system(size: 11, design: .monospaced)).frame(minWidth: 55)
                Button { zoom = min(8, (zoom == 0 ? fitScale : zoom) * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("放大预览")
                Spacer(minLength: 0)
                Button("100%") { zoom = 1 }.help("按逻辑点原尺寸显示")
                Button("完整显示") { zoom = 0 }.help("显示完整窗口，不裁切画面")
            }.buttonStyle(.borderless)
            GeometryReader { geometry in
                let frame = model.canvasFrame
                let transform = CanvasTransform(bounds: frame, viewport: geometry.size, zoom: zoom)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        canvasBackground(size: transform.size)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { event in
                                model.tapCanvas(at: transform.logicalPoint(event.location))
                            })
                        ForEach(Array(model.plan.points.enumerated()), id: \.element.id) { index, point in
                            CanvasStep(point: point, number: index + 1, transform: transform,
                                       selected: model.selectedPoint == point.id,
                                       running: engine.currentPoint == point.id && engine.state.busy,
                                       editable: model.canEdit,
                                       select: { model.selectedPoint = point.id },
                                       move: { model.repositionPoint(point.id, handle: $0, to: $1) })
                                .allowsHitTesting(model.dragPlacement == nil)
                                .zIndex(model.selectedPoint == point.id ? 1 : 0)
                        }
                        if case .end(let start) = model.dragPlacement, frame.contains(start) {
                            Circle().fill(Color.accentColor).overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                .frame(width: 14, height: 14).position(transform.displayedPoint(start))
                                .allowsHitTesting(false).accessibilityHidden(true).zIndex(2)
                        }
                    }
                    .frame(width: transform.size.width, height: transform.size.height)
                    .coordinateSpace(name: "pointCanvas")
                    .padding(12)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .center)
                }
                .onAppear { updateFit(geometry.size) }
                .onChange(of: geometry.size) { _, size in updateFit(size) }
                .onChange(of: model.canvasFrame) { _, _ in updateFit(geometry.size) }
            }.clipped()
            HStack {
                Text(canvasHint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                if model.dragPlacement != nil {
                    Button("取消", action: model.cancelDragPlacement).buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
    private var canvasHint: String {
        switch model.dragPlacement {
        case .start: return "点击画布，选择拖动起点。"
        case .end: return "再点击画布，选择拖动终点。"
        case nil:
            return model.preview == nil ? "位置示意图。长按标记可调整位置。" : "静态截图。点击标记选中，长按可调整位置。"
        }
    }
    private func updateFit(_ viewport: CGSize) {
        fitScale = Double(CanvasTransform(bounds: model.canvasFrame, viewport: viewport).scale)
    }
    private func canvasBackground(size: CGSize) -> some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .textBackgroundColor))
            if let preview = model.preview {
                Image(decorative: preview.image, scale: 1)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: size.width, height: size.height).allowsHitTesting(false)
            } else {
                Canvas { context, canvas in
                    var path = Path()
                    for index in 1..<12 {
                        let x = canvas.width * Double(index) / 12
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: canvas.height))
                    }
                    for index in 1..<7 {
                        let y = canvas.height * Double(index) / 7
                        path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: canvas.width, y: y))
                    }
                    context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
                }.allowsHitTesting(false)
                Image(systemName: model.plan.windowCoordinates ? "macwindow" : "display.2")
                    .font(.title3).foregroundStyle(.secondary.opacity(0.65)).allowsHitTesting(false)
            }
        }.frame(width: size.width, height: size.height)
            .overlay(Rectangle().stroke(.primary.opacity(0.1), lineWidth: 1).allowsHitTesting(false))
    }
}


private struct CanvasStep: View {
    let point: ClickPoint
    let number: Int
    let transform: CanvasTransform
    let selected: Bool
    let running: Bool
    let editable: Bool
    let select: () -> Void
    let move: (PointHandle, CGPoint) -> Void
    @GestureState private var interaction = MarkerInteraction()
    private var tint: Color { running ? .orange : .accentColor }

    private func position(for handle: PointHandle, at origin: CGPoint) -> CGPoint {
        guard interaction.handle == handle else { return origin }
        return transform.draggedPoint(from: origin, by: interaction.translation) ?? origin
    }
    private func drag(_ handle: PointHandle, from origin: CGPoint) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("pointCanvas")))
            .updating($interaction) { value, state, _ in
                switch value {
                case .first(let held): state.handle = held ? handle : nil
                case .second(let held, let drag):
                    state.handle = held ? handle : nil
                    state.translation = drag?.translation ?? .zero
                }
            }
            .onChanged { value in
                switch value {
                case .first(true), .second(true, _): select()
                default: break
                }
            }
            .onEnded { value in
                guard editable, case .second(true, let drag?) = value,
                      let position = transform.draggedPoint(from: origin, by: drag.translation) else { return }
                move(handle, position)
            }
    }

    private func marker(_ handle: PointHandle, origin: CGPoint, label: String) -> some View {
        let logical = position(for: handle, at: origin)
        let location = transform.displayedPoint(logical)
        let coordinates = "X \(Int(logical.x))，Y \(Int(logical.y))"
        let hint = editable ? "长按并拖动调整位置" : "运行期间不能调整位置"
        let held = interaction.handle == handle
        let size: CGFloat = handle == .end ? 20 : 25
        return Group {
            if handle == .end { Image(systemName: "flag.fill") }
            else { Text(String(number)) }
        }
            .font(.system(size: handle == .end ? 9 : 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white).frame(width: size, height: size)
            .background(tint, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: selected || held ? 3 : 1.5))
            .shadow(color: .black.opacity(held ? 0.3 : 0.18), radius: held ? 6 : 3, y: 1)
            .scaleEffect(held ? 1.2 : 1)
            .contentShape(Circle())
            .onTapGesture(perform: select)
            .highPriorityGesture(drag(handle, from: origin), including: editable ? .all : .none)
            .position(location)
            .zIndex(held ? 2 : 1)
            .help(label + " · " + coordinates + " · " + hint)
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityValue(Text(coordinates))
            .accessibilityHint(Text(hint))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { select() }
    }

    var body: some View {
        let start = point.position
        let end = point.drag?.end
        ZStack(alignment: .topLeading) {
            if let end, transform.bounds.contains(start), transform.bounds.contains(end) {
                route(from: transform.displayedPoint(position(for: .start, at: start)),
                      to: transform.displayedPoint(position(for: .end, at: end)))
                    .stroke(tint, style: StrokeStyle(lineWidth: selected ? 2 : 1.5, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            if transform.bounds.contains(start) {
                marker(.start, origin: start, label: end == nil ? "点击点 \(number)" : "拖动 \(number) 起点")
            }
            if let end, transform.bounds.contains(end) {
                marker(.end, origin: end, label: "拖动 \(number) 终点")
            }
        }.opacity(point.enabled ? 1 : 0.35)
    }

    private func route(from start: CGPoint, to end: CGPoint) -> Path {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 34 else { return }
            let dx = (end.x - start.x) / length, dy = (end.y - start.y) / length
            let tip = CGPoint(x: end.x - dx * 12, y: end.y - dy * 12)
            let base = CGPoint(x: tip.x - dx * 6, y: tip.y - dy * 6)
            path.move(to: CGPoint(x: base.x - dy * 4, y: base.y + dx * 4))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: base.x + dy * 4, y: base.y - dx * 4))
        }
    }
}

private struct MarkerInteraction {
    var handle: PointHandle?
    var translation = CGSize.zero
}
