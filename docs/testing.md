# 测试与验证

运行 `swift test` 可执行 12 项核心测试，覆盖坐标边界与多显示器、窗口移动 / 大小变化、点击计数、方案验证、文件保存与损坏处理、预览缩放坐标、旧格式迁移与标签独立保存、前台队列串行与取消。

0.2.0 的原生 GUI 已使用两个自建 AppKit 靶窗口验证：后台并发时分别触发标准按钮；切换标签后继续运行；暂停一个不影响另一个；全部暂停后不再收到事件；全部继续与全部停止有效。运行中关闭标签的提示与取消，以及跨重启保存也已检查。这些结果仅代表测试窗口，不保证第三方软件接受事件。

前台排队的互斥与取消进行了队列层测试，未将此描述为所有前台应用的完整端到端验证。GUI 自动化模拟的全局快捷键未确认触发；全部停止按钮已验证。独立集成工具在后续更新后受系统权限限制，因此不能将该次工具报告视为通过。

## 自建窗口验证工具

```sh
zsh Validation/build.sh
open Validation/build/BackgroundClickProbe.app
```

工具需要独立授予辅助功能权限，使用自有测试按钮记录事件。集成检查使用正式版的 ClickEmitter、WindowCatalog 和 RunEngine：

```sh
zsh Validation/build-integration.sh
open Validation/build/BackgroundClickProbe.app
```

本地报告在 `Validation/results/`。该目录、构建目录、用户窗口截图和本地验证历史均被忽略，不上传到仓库。
