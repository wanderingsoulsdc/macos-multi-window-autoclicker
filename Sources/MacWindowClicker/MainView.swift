import SwiftUI
import Combine
import ClickerCore

struct MainView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var engine: RunEngine
    @AppStorage("workspace.arrangement") private var arrangementRaw = WorkspaceArrangement.stacked.rawValue
    @AppStorage("workspace.stackedProportion") private var stackedProportion = 0.62
    @AppStorage("workspace.sideProportion") private var sideProportion = 0.56
    @State private var pendingStepDeletion: Set<UUID>?
    private var arrangement: WorkspaceArrangement { WorkspaceArrangement(rawValue: arrangementRaw) ?? .stacked }
    private var splitProportion: Binding<Double> {
        Binding(get: { arrangement == .stacked ? stackedProportion : sideProportion },
                set: { if arrangement == .stacked { stackedProportion = $0 } else { sideProportion = $0 } })
    }
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sessionTabs
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Divider()
                workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector.frame(width: 260)
            }
            Divider()
            RunBar(model: model, engine: engine)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { model.cancelDragPlacement() }
        .onReceive(permissionTimer) { _ in model.refreshPermissions() }
        .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("知道了", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
        .confirmationDialog("此标签仍在运行，停止任务并关闭标签？", isPresented: Binding(get: { model.pendingCloseID != nil }, set: { if !$0 { model.pendingCloseID = nil } }), titleVisibility: .visible) {
            Button("停止并关闭标签", role: .destructive) { model.confirmClose() }
            Button("取消", role: .cancel) { model.pendingCloseID = nil }
        } message: { Text("其他标签会继续运行。关闭后此标签的方案也会移除，可先取消并导出保存。") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.click").font(.title2).foregroundStyle(.tint)
                .frame(width: 38, height: 38).background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Mac多窗口连点器").font(.system(size: 17, weight: .semibold))
                Text("MultiClick for macOS").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(model.saveLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("新建标签", systemImage: "plus") { model.newPlan() }
            Button("导入", systemImage: "square.and.arrow.down") { model.importPlan() }
            Button("导出", systemImage: "square.and.arrow.up") { model.exportPlan() }
        }
        .buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var sessionTabs: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sessions) { session in
                        HStack(spacing: 8) {
                            Button { model.selectSession(session.id) } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(session.engine.state == .failed ? Color.red : (session.engine.state.busy ? Color.orange : Color.accentColor.opacity(0.4))).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(session.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: 150, alignment: .leading)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("切换标签：" + session.label)
                            Button { model.requestClose(session.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 24) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭标签").accessibilityLabel("关闭标签：" + session.label)
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                            .background(model.selectedSessionID == session.id ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Button { model.newPlan() } label: { Image(systemName: "plus").frame(width: 28, height: 36) }
                        .buttonStyle(.borderless).help("新增窗口标签").accessibilityLabel("新增窗口标签")
                }.padding(.vertical, 2)
            }
            Divider().frame(height: 28)
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(model.busyCount) 个任务待执行或运行中").font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(model.allPaused ? "全部继续" : "全部暂停") { model.togglePauseAll() }
                    Button("全部停止", role: .destructive) { model.stopAll() }
                }.font(.caption).buttonStyle(.borderless).disabled(model.busyCount == 0)
            }
        }.padding(.horizontal, 18).padding(.vertical, 7)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("操作目标").font(.headline)
                Spacer()
                Button { model.refreshWindows() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新窗口列表").accessibilityLabel("刷新窗口列表").disabled(model.refreshing)
            }.padding(.top, 18)
            targetButton(owner: "整个屏幕", title: "使用屏幕坐标", icon: nil, symbol: "display", selected: !model.plan.windowCoordinates) { model.choose(nil) }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用或窗口", text: $model.query).textFieldStyle(.plain)
            }.padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            HStack {
                Text("当前窗口").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.windows.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(model.filteredWindows) { window in
                        targetButton(owner: window.owner, title: window.label,
                                     icon: NSRunningApplication(processIdentifier: window.pid)?.icon,
                                     symbol: "macwindow", selected: model.target?.id == window.id && model.plan.windowCoordinates) { model.choose(window) }
                    }
                    if model.filteredWindows.isEmpty {
                        Text("没有匹配的窗口\n请先打开目标窗口，再刷新。").font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.vertical, 28)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("选择窗口会打开独立标签。\n切换标签不会中断运行。\n隐藏或最小化的窗口暂不列出。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).padding(.bottom, 15)
        }.padding(.horizontal, 14)
    }

    private func targetButton(owner: String, title: String, icon: NSImage?, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Group { if let icon = icon { Image(nsImage: icon).resizable() } else { Image(systemName: symbol).resizable().scaledToFit().padding(3) } }
                    .frame(width: 27, height: 27)
                VStack(alignment: .leading, spacing: 3) {
                    Text(owner).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
            }.padding(.horizontal, 9).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(owner + " · " + title)
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.title).font(.headline).lineLimit(1).help(model.title)
                    Text(model.coordinateNote).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Picker("操作模式", selection: $model.plan.mode) {
                    ForEach(ClickMode.allCases) { mode in
                        Text(mode.title(includesDrag: model.plan.includesDrag)).tag(mode)
                            .disabled(!model.plan.windowCoordinates && mode != .foreground)
                    }
                }.labelsHidden().frame(width: 190).disabled(!model.canEdit)
            }
            modeNote
            HStack {
                Text("预览与执行顺序").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("预览布局", selection: $arrangementRaw) {
                    ForEach(WorkspaceArrangement.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 186)
            }
            AdjustableWorkspace(arrangement: arrangement, proportion: splitProportion) {
                PointCanvas(model: model, engine: engine)
            } sequence: {
                sequencePanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            DisclosureGroup("运行记录 · \(engine.logs.count)") {
                RunHistoryPanel(records: engine.logs)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }

    @ViewBuilder private var modeNote: some View {
        switch model.plan.mode {
        case .background:
            VStack(alignment: .leading, spacing: 4) {
                Label("尽量不移动鼠标、不切换前台；发送结束不代表目标已响应。", systemImage: "cursorarrow.motionlines")
                if model.target?.bundleID?.localizedCaseInsensitiveContains("wechat") == true {
                    Text("微信小游戏可能需要后台 Command 模式，切换后可先单次试运行。")
                        .foregroundStyle(.orange)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        case .commandBackground:
            Label("部分软件会为带 Command 的操作赋予不同含义，请先单次试运行。", systemImage: "command")
                .font(.system(size: 11)).foregroundStyle(.orange)
        case .foreground:
            Label("前台任务依次执行。操作时目标窗口须在前台且无遮挡。", systemImage: "cursorarrow")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    private var sequencePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("执行顺序").font(.headline)
                Text("\(model.plan.points.count) 步").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                batchStepMenu
            }
            HStack(spacing: 10) {
                Button { model.testSelectedPoint() } label: { Label("单次试运行", systemImage: "target") }
                    .disabled(!model.canEdit || model.dragPlacement != nil || model.selectedPoint == nil || (model.plan.windowCoordinates && model.target == nil))
                    .help("执行选中的步骤一次")
                Button { model.pickPoint() } label: { Label("屏幕取点", systemImage: "scope") }
                    .disabled(!model.canEdit || (model.plan.windowCoordinates && model.target == nil))
                Spacer(minLength: 0)
                Menu {
                    Button("添加点击点", systemImage: "cursorarrow.click") { model.cancelDragPlacement(); model.addPoint() }
                    Button("添加拖动", systemImage: "arrow.right") { model.beginDragPlacement() }
                } label: { Image(systemName: "plus") }
                    .fixedSize().help("添加点击点或拖动").accessibilityLabel("添加步骤")
                    .disabled(!model.canEdit || model.plan.points.count >= ClickPlan.maximumSteps)
            }.font(.system(size: 11)).controlSize(.small)
            pointList.frame(maxHeight: .infinity)
        }
        .padding(arrangement == .stacked ? .top : .leading, 5)
        .alert("删除已勾选的 \(pendingStepDeletion?.count ?? 0) 步？", isPresented: Binding(
            get: { pendingStepDeletion != nil }, set: { if !$0 { pendingStepDeletion = nil } }
        ), presenting: pendingStepDeletion) { ids in
            Button("删除", role: .destructive) { model.removePoints(ids) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这些步骤将从当前方案移除，并自动保存。")
        }
    }

    private var batchStepMenu: some View {
        let checked = Set(model.plan.activePoints.map(\.id))
        let count = model.plan.points.count
        let canCopy = !checked.isEmpty && count + checked.count <= ClickPlan.maximumSteps
        return Menu("批量 · \(checked.count)") {
            Button("全部勾选") { model.setAllPointsEnabled(true) }.disabled(checked.count == count)
            Button("全部取消勾选") { model.setAllPointsEnabled(false) }.disabled(checked.isEmpty)
            Divider()
            Button("复制到各条下方") { model.duplicate(checked, placement: .belowEach) }.disabled(!canCopy)
            Button("复制到列表底部") { model.duplicate(checked, placement: .bottom) }.disabled(!canCopy)
            Button("删除已勾选步骤", role: .destructive) { pendingStepDeletion = checked }.disabled(checked.isEmpty)
        }
        .controlSize(.small).fixedSize()
        .accessibilityLabel("批量操作，已勾选 \(checked.count) 步")
        .help("对已勾选步骤批量操作。勾选也决定哪些步骤会执行。")
        .disabled(!model.canEdit || count == 0)
    }

    private var pointList: some View {
        Group {
            if model.plan.points.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle.dashed").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("还没有步骤").font(.system(size: 13, weight: .medium))
                    Text("点击画布添加点击点，或从 + 菜单添加拖动。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StepList(model: model, engine: engine)
            }
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.06)))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                if let point = model.plan.points.first(where: { $0.id == model.selectedPoint }) {
                    Text("\(point.kind)设置").font(.headline)
                    PointInspector(model: model, id: point.id).id(point.id).disabled(!model.canEdit)
                } else {
                    Text("步骤设置").font(.headline)
                    Text("选中一个步骤以调整坐标、次数和间隔。")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4).frame(minHeight: 190, alignment: .topLeading)
                }
                Divider()
                VStack(alignment: .leading, spacing: 13) {
                    Text("运行设置").font(.headline)
                    Toggle("持续循环，直到手动停止", isOn: $model.plan.repeatForever).font(.caption)
                    HStack {
                        Text("执行轮数").font(.caption)
                        Spacer()
                        TextField("轮数", value: $model.plan.rounds, format: .number).frame(width: 76)
                            .disabled(model.plan.repeatForever)
                    }
                    launchSettings
                    Text("每轮依次执行所有已启用的步骤。").font(.system(size: 10)).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).disabled(!model.canEdit)
                RunNotificationSettings(canRequest: model.busyCount == 0)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: model.accessibility && model.eventAccess ? "checkmark.circle.fill" : "lock.circle")
                            .foregroundStyle(model.accessibility && model.eventAccess ? Color.teal : Color.orange)
                        Text(model.accessibility && model.eventAccess ? "操作权限已就绪" : "需要辅助功能权限").font(.caption.weight(.medium))
                    }
                    if !model.accessibility || !model.eventAccess {
                        Button("开启辅助功能权限") { model.requestAccess() }.disabled(!model.canEdit)
                        Text("授权后若仍未就绪，退出并重新打开应用。").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("后台模式是否有效，取决于目标软件是否接受这些操作。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                }
            }.padding(18)
        }.background(Color(nsColor: .underPageBackgroundColor).opacity(0.3))
    }

    private var launchSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("启动方式", selection: Binding(get: { model.plan.startMode }, set: { mode in
                if mode == .scheduled && (model.plan.scheduledStart ?? .distantPast) <= .now {
                    model.plan.scheduledStart = suggestedStart
                }
                model.plan.startMode = mode
            })) {
                ForEach(StartMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.font(.caption)

            switch model.plan.startMode {
            case .immediate:
                EmptyView()
            case .countdown:
                HStack {
                    Text("倒计时").font(.caption)
                    Spacer()
                    TextField("倒计时秒数", value: $model.plan.startDelay, format: .number)
                        .frame(width: 72)
                    Text("秒").font(.caption).foregroundStyle(.secondary)
                }
                Text("可设为 0～86,400 秒。").font(.caption2).foregroundStyle(.secondary)
            case .scheduled:
                ScheduledDatePicker(selection: Binding(
                    get: { model.plan.scheduledStart ?? suggestedStart },
                    set: { date in model.plan.scheduledStart = Calendar.current.dateInterval(of: .second, for: date)?.start ?? date }
                ))
                    .fixedSize()
                Text("按本机时间启动一次。预约期间请保持应用运行、Mac 唤醒。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var suggestedStart: Date {
        let next = Date.now.addingTimeInterval(300)
        return Calendar.current.dateInterval(of: .minute, for: next)?.start ?? next
    }
}

private struct RunNotificationSettings: View {
    @ObservedObject private var notifications = RunNotifications.shared
    let canRequest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch notifications.access {
            case .checking:
                EmptyView()
            case .notRequested:
                Button("开启任务结束通知", systemImage: "bell") {
                    Task { await notifications.requestAccess() }
                }.disabled(!canRequest || notifications.requesting)
            case .banner:
                Label("任务结束通知已开启", systemImage: "bell.badge")
            case .quiet:
                Label("结束通知将显示在通知中心", systemImage: "bell")
            case .disabled:
                Label("请在「系统设置 → 通知」中允许本应用通知", systemImage: "bell.slash")
            }
            if notifications.canPreviewSound {
                Button("试听提示音", systemImage: "speaker.wave.2") {
                    notifications.playSoundPreview()
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .task { await notifications.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await notifications.refresh() }
        }
    }
}

struct PointRow: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var engine: RunEngine
    let point: ClickPoint
    let index: Int
    @Binding var drag: StepListDrag?
    let canReorder: Bool
    let createGroup: (() -> Void)?
    let endDrag: (CGPoint) -> Void

    var body: some View {
        HStack(spacing: 6) {
            reorderHandle
            Toggle("启用 \(point.name)", isOn: Binding(get: { model.plan.points.first { $0.id == point.id }?.enabled ?? false }, set: { value in
                if let i = model.plan.points.firstIndex(where: { $0.id == point.id }) { model.plan.points[i].enabled = value }
            })).labelsHidden().toggleStyle(.checkbox).disabled(!model.canEdit)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    if point.drag != nil { Image(systemName: "arrow.right").foregroundStyle(.tint) }
                    Text(point.displayName(at: index)).lineLimit(1)
                }.font(.system(size: 12, weight: .medium))
                Text(point.drag.map { coordinateText(point.position) + " → " + coordinateText($0.end) } ?? coordinateText(point.position))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 3)
            Text("\(point.count) 次").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(point.interval.formatted(.number.precision(.fractionLength(0...2))))s").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
            if engine.currentPoint == point.id && engine.state.busy { Image(systemName: "play.fill").foregroundStyle(.tint).font(.caption) }
            Menu {
                stepActions
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("步骤操作")
            .accessibilityLabel("第 \(index + 1) 步操作")
            .disabled(!model.canEdit)
        }.padding(.horizontal, 8).padding(.vertical, 9).contentShape(Rectangle())
            .background(model.selectedPoint == point.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(point.enabled ? 1 : 0.5)
            .onTapGesture { model.selectedPoint = point.id }
            .contextMenu { stepActions }
    }

    @ViewBuilder private var reorderHandle: some View {
        StepSortHandle(model: model, id: point.id, label: "拖拽排序第 \(index + 1) 步",
                       enabled: canReorder, drag: $drag, endDrag: endDrag) {
            Text(String(index + 1)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 4).frame(minWidth: 21, minHeight: 23)
                .background(.primary.opacity(0.05), in: Capsule())
        }
    }

    @ViewBuilder private var stepActions: some View {
        if let createGroup {
            Button("创建循环组…", systemImage: "repeat", action: createGroup).disabled(!model.canEdit)
            Divider()
        }
        StepCopyActions(model: model, id: point.id)
    }

    private func coordinateText(_ position: CGPoint) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
        return "(\(Double(position.x).formatted(format)), \(Double(position.y).formatted(format)))"
    }
}

private struct StepCopyActions: View {
    @ObservedObject var model: WorkspaceModel
    let id: UUID
    var body: some View {
        Group {
            Button("复制到本条下方") { model.duplicate([id], placement: .belowEach) }
            Button("复制到列表底部") { model.duplicate([id], placement: .bottom) }
        }.disabled(!model.canEdit || model.plan.points.count >= ClickPlan.maximumSteps)
    }
}

private struct PointInspector: View {
    @ObservedObject var model: WorkspaceModel
    let id: UUID
    private var point: Binding<ClickPoint> {
        Binding(get: { model.plan.points.first { $0.id == id } ?? ClickPoint(id: id) }, set: { value in
            if model.canEdit, let index = model.plan.points.firstIndex(where: { $0.id == id }) { model.plan.points[index] = value }
        })
    }
    private var drag: Binding<DragMotion> {
        Binding(get: { point.wrappedValue.drag ?? DragMotion(end: .zero) }, set: { point.wrappedValue.drag = $0 })
    }

    var body: some View {
        let step = point.wrappedValue
        VStack(alignment: .leading, spacing: 13) {
            TextField("\(step.kind)名称", text: point.name)
            coordinateFields(step.drag == nil ? "" : "起点 ", x: point.x, y: point.y)
            if let motion = step.drag {
                coordinateFields("终点 ", x: drag.endX, y: drag.endY)
                Text(displacement(from: step.position, to: motion.end)).font(.caption).foregroundStyle(.secondary)
                secondsField("单次拖动耗时", value: drag.duration).help("0.1～10 秒")
            }
            HStack { Text(step.drag == nil ? "点击次数" : "拖动次数").font(.caption); Spacer(); TextField("次数", value: point.count, format: .number).frame(width: 82) }
            secondsField("每次执行后等待", value: point.interval)
            HStack(spacing: 8) {
                Menu {
                    StepCopyActions(model: model, id: id)
                } label: { Image(systemName: "doc.on.doc") }
                    .fixedSize().help("复制步骤").accessibilityLabel("复制步骤")
                Spacer()
                Button(role: .destructive) { model.removePoint(id) } label: { Image(systemName: "trash") }.help("删除").accessibilityLabel("删除步骤")
            }
        }.textFieldStyle(.roundedBorder)
    }

    private func coordinateFields(_ prefix: String, x: Binding<Double>, y: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            coordinateField(prefix + "X", value: x)
            coordinateField(prefix + "Y", value: y)
        }
    }

    private func coordinateField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number)
        }
    }

    private func secondsField(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            TextField(label, value: value, format: .number.precision(.fractionLength(0...2))).frame(width: 66)
            Text("秒").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func displacement(from start: CGPoint, to end: CGPoint) -> String {
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        let horizontal = dx == 0 ? nil : "向\(dx > 0 ? "右" : "左") \(abs(dx).formatted(format)) 点"
        let vertical = dy == 0 ? nil : "向\(dy > 0 ? "下" : "上") \(abs(dy).formatted(format)) 点"
        let parts = [horizontal, vertical].compactMap { $0 }
        return parts.isEmpty ? "起点和终点须分开" : parts.joined(separator: " · ")
    }
}

private struct RunBar: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var engine: RunEngine
    private var countdownText: String {
        let seconds = Int(ceil(engine.countdown))
        if seconds < 60 { return "\(seconds) 秒" }
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    private var startTitle: String {
        switch model.plan.startMode {
        case .immediate: return "开始运行"
        case .countdown: return "开始倒计时"
        case .scheduled: return "预约启动"
        }
    }
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(engine.state == .failed ? Color.red.opacity(0.1) : Color.accentColor.opacity(0.1))
                Image(systemName: engine.state == .failed ? "exclamationmark" : (engine.state == .running ? "play.fill" : "cursorarrow.click"))
                    .foregroundStyle(engine.state == .failed ? Color.red : Color.accentColor)
            }.frame(width: 35, height: 35)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(engine.statusTitle).font(.system(size: 13, weight: .semibold))
                    if engine.state == .countdown || (engine.state == .paused && engine.countdown > 0) { Text(countdownText).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Text("已发送 \(engine.sent)\(engine.total.map { " / \($0)" } ?? "") 次").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(engine.detail).font(.system(size: 11)).foregroundStyle(engine.state == .failed ? Color.red : .secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 9) {
                    if engine.state.busy {
                        Button(engine.state == .paused ? "继续" : "暂停", systemImage: engine.state == .paused ? "play.fill" : "pause.fill") { engine.togglePause() }.disabled(engine.state == .stopping)
                        Button(engine.scheduledDate == nil ? "停止" : "取消预约", systemImage: "stop.fill", role: .destructive) { engine.stop() }
                    } else {
                        Button(startTitle, systemImage: model.plan.startMode == .scheduled ? "clock" : "play.fill") { model.start() }.buttonStyle(.borderedProminent)
                            .disabled(model.dragPlacement != nil || model.plan.activePoints.isEmpty || (model.plan.windowCoordinates && model.target == nil))
                    }
                }.controlSize(.large)
                Text(model.hotkeys.stopAvailable ? "⌃⌘Esc 全部停止 · ⌃⌘P 全部暂停 / 继续" : "停止快捷键被占用，请重新打开应用")
                    .font(.system(size: 10)).foregroundStyle(model.hotkeys.stopAvailable ? Color.secondary : .red)
            }
        }.padding(.horizontal, 22).padding(.vertical, 15)
    }
}
