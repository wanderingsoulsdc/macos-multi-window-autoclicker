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
                                let location = transform.displayedPoint(point.position)
                                Button { model.selectedPoint = point.id } label: {
                                    Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white).frame(width: 25, height: 25)
                                        .background(engine.currentPoint == point.id && engine.state.busy ? Color.orange : Color.accentColor, in: Circle())
                                        .overlay(Circle().stroke(.white, lineWidth: model.selectedPoint == point.id ? 3 : 1.5))
                                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                                }.buttonStyle(.plain).opacity(point.enabled ? 1 : 0.35)
                                    .position(location)
                                    .help("\(point.name) · (\(Int(point.x)), \(Int(point.y)))")
                            }
                        }
                    }
                    .frame(width: transform.size.width, height: transform.size.height)
                    .padding(12)
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .center)
                }
                .onAppear { updateFit(geometry.size) }
                .onChange(of: geometry.size) { _, size in updateFit(size) }
                .onChange(of: model.canvasFrame) { _, _ in updateFit(geometry.size) }
            }.clipped()
            Text(model.preview == nil ? "位置示意图；对准实际按钮请用屏幕取点。" : "静态截图；可放大滚动查看，点击标记可选中。")
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
