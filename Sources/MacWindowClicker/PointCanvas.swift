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
                                guard model.canEdit else { return }
                                let point = transform.logicalPoint(event.location)
                                if frame.contains(point) { model.addPoint(at: point) }
                            })
                        ForEach(Array(model.plan.points.enumerated()), id: \.element.id) { index, point in
                            if frame.contains(point.position) {
                                CanvasPointMarker(point: point, number: index + 1, transform: transform,
                                                  selected: model.selectedPoint == point.id,
                                                  running: engine.currentPoint == point.id && engine.state.busy,
                                                  editable: model.canEdit,
                                                  select: { model.selectedPoint = point.id },
                                                  move: { model.repositionPoint(point.id, to: $0) })
                            }
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
            Text(model.preview == nil ? "位置示意图；长按标记可拖动，对准按钮请用屏幕取点。" : "静态截图；点击标记选中，长按拖动调整位置。")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
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


private struct CanvasPointMarker: View {
    let point: ClickPoint
    let number: Int
    let transform: CanvasTransform
    let selected: Bool
    let running: Bool
    let editable: Bool
    let select: () -> Void
    let move: (CGPoint) -> Void
    @GestureState private var interaction = MarkerInteraction()
    private var position: CGPoint {
        interaction.held ? (transform.draggedPoint(from: point.position, by: interaction.translation) ?? point.position) : point.position
    }
    private var drag: some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("pointCanvas")))
            .updating($interaction) { value, state, _ in
                switch value {
                case .first(let held): state.held = held
                case .second(let held, let drag):
                    state.held = held
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
                      let position = transform.draggedPoint(from: point.position, by: drag.translation) else { return }
                move(position)
            }
    }
    private var marker: some View {
        Text(String(number)).font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(.white).frame(width: 25, height: 25)
            .background(running ? Color.orange : Color.accentColor, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: selected || interaction.held ? 3 : 1.5))
            .shadow(color: .black.opacity(interaction.held ? 0.3 : 0.18), radius: interaction.held ? 6 : 3, y: 1)
            .scaleEffect(interaction.held ? 1.2 : 1)
            .contentShape(Circle())
            .opacity(point.enabled ? 1 : 0.35)
    }
    var body: some View {
        let logical = position
        let location = transform.displayedPoint(logical)
        let coordinates = "X \(Int(logical.x))，Y \(Int(logical.y))"
        let hint = editable ? "长按并拖动调整位置" : "运行期间不能调整位置"
        return marker
            .onTapGesture(perform: select)
            .highPriorityGesture(drag, including: editable ? .all : .none)
            .position(location)
            .zIndex(interaction.held ? 1 : 0)
            .help(point.name + " · " + coordinates + " · " + hint)
            .accessibilityElement()
            .accessibilityLabel(Text("点击点 \(number)"))
            .accessibilityValue(Text(coordinates))
            .accessibilityHint(Text(hint))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { select() }
    }
}

private struct MarkerInteraction {
    var held = false
    var translation = CGSize.zero
}
