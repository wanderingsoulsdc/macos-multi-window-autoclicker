import SwiftUI
import Combine
import ClickerCore

struct MainView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var engine: RunEngine
    @AppStorage("workspace.arrangement") private var arrangementRaw = WorkspaceArrangement.stacked.rawValue
    @AppStorage("workspace.stackedProportion") private var stackedProportion = 0.62
    @AppStorage("workspace.sideProportion") private var sideProportion = 0.56
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
                Text("\(model.busyCount) 个任务运行中").font(.system(size: 10)).foregroundStyle(.secondary)
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
                Text("点击目标").font(.headline)
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
                Picker("点击方式", selection: $model.plan.mode) {
                    ForEach(ClickMode.allCases) { mode in
                        Text(mode.title).tag(mode).disabled(!model.plan.windowCoordinates && mode != .foreground)
                    }
                }.labelsHidden().frame(width: 190).disabled(!model.canEdit)
            }
            modeNote
            HStack {
                Text("预览与点击顺序").font(.caption).foregroundStyle(.secondary)
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if engine.logs.isEmpty { Text("运行后显示记录。") }
                        ForEach(engine.logs) { log in
                            HStack(alignment: .top, spacing: 8) {
                                Text(log.time, style: .time).foregroundStyle(.tertiary)
                                Text(log.message).textSelection(.enabled)
                            }
                        }
                    }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                }.frame(height: 90)
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }

    @ViewBuilder private var modeNote: some View {
        switch model.plan.mode {
        case .background:
            VStack(alignment: .leading, spacing: 4) {
                Label("尽量不移动鼠标、不切换前台；发送结束不代表目标已响应。", systemImage: "cursorarrow.motionlines")
                if model.target?.bundleID?.localizedCaseInsensitiveContains("wechat") == true {
                    Text("微信小游戏可能需要「后台 Command 点击」；切换后请先单次试点确认。")
                        .foregroundStyle(.orange)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        case .commandBackground:
            Label("带 Command 的点击可能触发多选或打开新标签，请确认目标软件的含义。", systemImage: "command")
                .font(.system(size: 11)).foregroundStyle(.orange)
        case .foreground:
            Label("前台任务依次执行；轮到后请在倒计时内将目标窗口置于前台。", systemImage: "cursorarrow")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    private var sequencePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("点击顺序").font(.headline)
                Text("\(model.plan.points.count) 个点").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Button { model.testSelectedPoint() } label: { Label("单次试点", systemImage: "target") }
                    .disabled(!model.canEdit || model.selectedPoint == nil || (model.plan.windowCoordinates && model.target == nil))
                    .help("只点击当前选中的点一次，不修改方案")
                Button { model.pickPoint() } label: { Label("屏幕取点", systemImage: "scope") }
                    .disabled(!model.canEdit || (model.plan.windowCoordinates && model.target == nil))
                Spacer(minLength: 0)
                Button { model.addPoint() } label: { Image(systemName: "plus") }
                    .help("手动添加点击点").accessibilityLabel("添加点击点").disabled(!model.canEdit)
            }.font(.system(size: 11)).controlSize(.small)
            pointList.frame(maxHeight: .infinity)
        }
        .padding(arrangement == .stacked ? .top : .leading, 5)
    }

    private var pointList: some View {
        Group {
            if model.plan.points.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle.dashed").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("还没有点击点").font(.system(size: 13, weight: .medium))
                    Text("使用屏幕取点、点击上方画布，或点 + 手动添加。").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.plan.points.enumerated()), id: \.element.id) { index, point in
                            PointRow(model: model, engine: engine, point: point, index: index)
                        }
                    }.padding(5)
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.06)))
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                Text("点击点设置").font(.headline)
                if let id = model.selectedPoint, model.plan.points.contains(where: { $0.id == id }) {
                    PointInspector(model: model, id: id).disabled(!model.canEdit)
                } else {
                    Text("选中一个点击点后，在这里调整坐标、次数与等待时间。")
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
                    HStack {
                        Text("开始前等待").font(.caption)
                        Spacer()
                        TextField("秒", value: $model.plan.startDelay, format: .number).frame(width: 56)
                        Text("秒").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("每一轮会按左侧顺序执行所有已启用的点。").font(.system(size: 10)).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).disabled(!model.canEdit)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: model.accessibility && model.eventAccess ? "checkmark.circle.fill" : "lock.circle")
                            .foregroundStyle(model.accessibility && model.eventAccess ? Color.teal : Color.orange)
                        Text(model.accessibility && model.eventAccess ? "点击权限已就绪" : "需要辅助功能权限").font(.caption.weight(.medium))
                    }
                    if !model.accessibility || !model.eventAccess {
                        Button("开启辅助功能权限") { model.requestAccess() }.disabled(!model.canEdit)
                        Text("授权后若仍未就绪，退出并重新打开应用。").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("后台点击是实验功能，实际效果取决于目标软件。不会自动改成前台点击。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                }
            }.padding(18)
        }.background(Color(nsColor: .underPageBackgroundColor).opacity(0.3))
    }
}

private struct PointRow: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var engine: RunEngine
    let point: ClickPoint
    let index: Int
    var body: some View {
        HStack(spacing: 10) {
            Text(String(index + 1)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 23, height: 23).background(.primary.opacity(0.05), in: Circle())
            Toggle("启用 \(point.name)", isOn: Binding(get: { model.plan.points.first { $0.id == point.id }?.enabled ?? false }, set: { value in
                if let i = model.plan.points.firstIndex(where: { $0.id == point.id }) { model.plan.points[i].enabled = value }
            })).labelsHidden().toggleStyle(.checkbox).disabled(!model.canEdit)
            VStack(alignment: .leading, spacing: 3) {
                Text(point.name.isEmpty ? "点击点 \(index + 1)" : point.name).font(.system(size: 12, weight: .medium))
                Text("(\(point.x.formatted(.number.precision(.fractionLength(0...1)))), \(point.y.formatted(.number.precision(.fractionLength(0...1)))))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 3)
            Text("\(point.count) 次").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(point.interval.formatted(.number.precision(.fractionLength(0...2))))s").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
            if engine.currentPoint == point.id && engine.state.busy { Image(systemName: "play.fill").foregroundStyle(.tint).font(.caption) }
        }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
            .background(model.selectedPoint == point.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(point.enabled ? 1 : 0.5)
            .onTapGesture { model.selectedPoint = point.id }
    }
}

private struct PointInspector: View {
    @ObservedObject var model: WorkspaceModel
    let id: UUID
    private var point: Binding<ClickPoint> {
        Binding(get: { model.plan.points.first { $0.id == id } ?? ClickPoint(id: id) }, set: { value in
            if let index = model.plan.points.firstIndex(where: { $0.id == id }) { model.plan.points[index] = value }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            TextField("点击点名称", text: point.name)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) { Text("X 坐标").font(.caption).foregroundStyle(.secondary); TextField("X", value: point.x, format: .number) }
                VStack(alignment: .leading, spacing: 5) { Text("Y 坐标").font(.caption).foregroundStyle(.secondary); TextField("Y", value: point.y, format: .number) }
            }
            HStack { Text("点击次数").font(.caption); Spacer(); TextField("次数", value: point.count, format: .number).frame(width: 82) }
            HStack { Text("每次点击后等待").font(.caption); Spacer(); TextField("秒", value: point.interval, format: .number.precision(.fractionLength(0...2))).frame(width: 55); Text("秒").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                Button { model.movePoint(id, by: -1) } label: { Image(systemName: "arrow.up") }.help("上移").accessibilityLabel("上移点击点")
                Button { model.movePoint(id, by: 1) } label: { Image(systemName: "arrow.down") }.help("下移").accessibilityLabel("下移点击点")
                Button { model.duplicate(id) } label: { Image(systemName: "doc.on.doc") }.help("复制").accessibilityLabel("复制点击点")
                Spacer()
                Button(role: .destructive) { model.removePoint(id) } label: { Image(systemName: "trash") }.help("删除").accessibilityLabel("删除点击点")
            }
        }.textFieldStyle(.roundedBorder)
    }
}

private struct RunBar: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var engine: RunEngine
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(engine.state == .failed ? Color.red.opacity(0.1) : Color.accentColor.opacity(0.1))
                Image(systemName: engine.state == .failed ? "exclamationmark" : (engine.state == .running ? "play.fill" : "cursorarrow.click"))
                    .foregroundStyle(engine.state == .failed ? Color.red : Color.accentColor)
            }.frame(width: 35, height: 35)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(engine.state.title).font(.system(size: 13, weight: .semibold))
                    if engine.state == .countdown || (engine.state == .paused && engine.countdown > 0) { Text("\(Int(ceil(engine.countdown))) 秒").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Text("已发送 \(engine.sent)\(engine.total.map { " / \($0)" } ?? "") 次").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(engine.detail).font(.system(size: 11)).foregroundStyle(engine.state == .failed ? Color.red : .secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 9) {
                    if engine.state.busy {
                        Button(engine.state == .paused ? "继续" : "暂停", systemImage: engine.state == .paused ? "play.fill" : "pause.fill") { engine.togglePause() }.disabled(engine.state == .stopping)
                        Button("停止", systemImage: "stop.fill", role: .destructive) { engine.stop() }
                    } else {
                        Button("开始点击", systemImage: "play.fill") { model.start() }.buttonStyle(.borderedProminent)
                            .disabled(model.plan.activePoints.isEmpty || (model.plan.windowCoordinates && model.target == nil))
                    }
                }.controlSize(.large)
                Text(model.hotkeys.stopAvailable ? "⌃⌘Esc 全部停止 · ⌃⌘P 全部暂停 / 继续" : "停止快捷键被占用，请重新打开应用")
                    .font(.system(size: 10)).foregroundStyle(model.hotkeys.stopAvailable ? Color.secondary : .red)
            }
        }.padding(.horizontal, 22).padding(.vertical, 15)
    }
}
