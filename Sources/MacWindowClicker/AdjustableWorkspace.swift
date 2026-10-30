import SwiftUI

enum WorkspaceArrangement: String, CaseIterable, Identifiable {
    case stacked, sideBySide
    var id: String { rawValue }
    var title: String { self == .stacked ? "上下布局" : "左右布局" }
    var symbol: String { self == .stacked ? "rectangle.split.1x2" : "rectangle.split.2x1" }
}

struct AdjustableWorkspace<Preview: View, Sequence: View>: View {
    let arrangement: WorkspaceArrangement
    @Binding var proportion: Double
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder var sequence: () -> Sequence
    @State private var dragStart: Double?
    private let divider: CGFloat = 12
    var body: some View {
        GeometryReader { geometry in
            let stacked = arrangement == .stacked
            let extent = max(1, (stacked ? geometry.size.height : geometry.size.width) - divider)
            let minimumFirst = min(stacked ? 170.0 : 200.0, extent * 0.45)
            let minimumSecond = min(stacked ? 125.0 : 190.0, extent * 0.4)
            let first = min(extent - minimumSecond, max(minimumFirst, extent * proportion))
            if stacked {
                VStack(spacing: 0) {
                    preview().frame(height: first)
                    handle(stacked: true, extent: extent, first: first, minimumFirst: minimumFirst, minimumSecond: minimumSecond)
                    sequence().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    preview().frame(width: first)
                    handle(stacked: false, extent: extent, first: first, minimumFirst: minimumFirst, minimumSecond: minimumSecond)
                    sequence().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    private func handle(stacked: Bool, extent: CGFloat, first: CGFloat, minimumFirst: CGFloat, minimumSecond: CGFloat) -> some View {
        ZStack {
            Color.primary.opacity(0.035)
            Capsule().fill(.secondary.opacity(0.5)).frame(width: stacked ? 36 : 3, height: stacked ? 3 : 36)
        }
        .frame(width: stacked ? nil : divider, height: stacked ? divider : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { (stacked ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set() }
            else { NSCursor.arrow.set() }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { value in
            if dragStart == nil { dragStart = first / extent }
            let delta = stacked ? value.translation.height : value.translation.width
            proportion = min(1 - minimumSecond / extent, max(minimumFirst / extent, (dragStart ?? proportion) + delta / extent))
        }.onEnded { _ in dragStart = nil })
        .onTapGesture(count: 2) { proportion = 0.6 }
        .help("拖动调整预览和点击顺序大小；双击恢复默认比例")
        .accessibilityLabel("预览与点击顺序分隔线")
        .accessibilityValue("预览占 \(Int(proportion * 100))%")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            proportion = min(1 - minimumSecond / extent, max(minimumFirst / extent, proportion + delta))
        }
    }
}
