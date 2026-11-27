# 测试与验证

运行 `swift test` 可执行核心测试，覆盖坐标边界与多显示器、窗口移动、执行计数、方案保存与旧格式迁移、拖动终点和耗时验证、预览缩放与标记移动、标签独立保存、启动时间和前台队列。

0.2.0 的原生 GUI 已使用两个自建 AppKit 靶窗口验证：后台并发时分别触发标准按钮；切换标签后继续运行；暂停一个不影响另一个；全部暂停后不再收到事件；全部继续与全部停止有效。运行中关闭标签的提示与取消，以及跨重启保存也已检查。这些结果仅代表测试窗口，不保证第三方软件接受事件。

0.2.8 的自建窗口集成测试覆盖两种后台模式中的点击和拖动混排、拖动轨迹、暂停与停止，以及外层轮数与组内循环共同执行时的顺序和次数。执行列表的复制、批量删除、拖拽排序和循环组编辑也已通过界面检查。前台排队已验证互斥与取消，前台拖动及第三方应用仍需单独验证。

## 自建窗口验证工具

```sh
zsh Validation/build.sh
open Validation/build/BackgroundClickProbe.app
```

工具需要独立授予辅助功能权限，使用自建控件记录事件。集成检查通过正式版的 ClickEmitter、WindowCatalog 和 RunEngine 执行：

```sh
zsh Validation/build-integration.sh
open Validation/build/BackgroundClickProbe.app
```

本地报告在 `Validation/results/`。该目录、构建目录、用户窗口截图和本地验证历史均被忽略，不上传到仓库。
