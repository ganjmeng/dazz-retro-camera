# DAZZ 相机生命周期架构优化研究报告

**作者**：Manus AI
**日期**：2026年3月18日

## 1. 现状与问题根因分析

在当前的 DAZZ 相机应用中，用户在启动、权限请求、切换相机、切换分辨率以及应用退入后台等场景下，频繁遇到预览失效（黑屏、卡死或参数丢失）的问题。通过对核心代码（如 `camera_screen.dart`、`camera_notifier.dart`、`CameraPlugin.kt` 和 `MetalRenderer.swift`）的深入分析，我们发现问题的根因在于**缺乏统一的相机状态机和生命周期管理**。

### 1.1 职责分散与硬编码恢复路径

当前架构中，相机生命周期的控制逻辑散落在多个文件中，主要表现为：

*   **页面级协调器**：`camera_screen.dart` 充当了 Flutter 层的相机生命周期入口。其 `initState` 方法中硬编码了初始化顺序：加载 JSON -> 请求权限 -> `initCamera()` -> `setSharpen()` -> `setCamera()` -> `updateLensParams()`。
*   **多条恢复路径**：在进入二级页面（如 `_pushWithCameraPause`）或切换清晰度（`cycleSharpen`）时，代码通过手动调用 `stopPreview()` 和 `initCamera()`，并重新发送所有参数来恢复状态。这种“打补丁”式的恢复方式极易因异步时序问题导致状态不一致。
*   **后台恢复缺失**：在 `didChangeAppLifecycleState` 中，应用进入后台时仅保存了状态快照（`saveCurrentSnapshot`），而在切回前台时仅播放了视觉过渡动画，并未真正重新绑定或恢复原生相机会话。

### 1.2 原生层状态与 Flutter 层状态脱节

*   **Android 端**：`setSharpen` 或 `switchLens` 会触发 `bindCameraUseCases`，这会导致 `CameraGLRenderer` 重建。如果在重建完成前 Flutter 层发送了新的渲染参数，这些参数将被丢弃，导致预览画面参数丢失。
*   **iOS 端**：`AVCaptureSession` 的中断（如电话呼入、退入后台）没有通过系统的 `AVCaptureSessionWasInterruptedNotification` 进行统一监听和恢复，导致前台恢复时 Metal 渲染器可能卡在最后一帧。

## 2. 业界最佳实践研究

为了解决上述问题，我们研究了 Android 和 iOS 平台的相机生命周期最佳实践。

### 2.1 Android CameraX 最佳实践

Google 推荐使用 `ProcessCameraProvider.bindToLifecycle` 将相机的生命周期直接绑定到 `LifecycleOwner`（如 Activity 或 Fragment）[1]。
*   **生命周期感知**：CameraX 会自动处理应用进入后台和前台的相机释放与恢复，无需手动调用 `stop` 和 `start`。
*   **解绑与重绑**：在切换摄像头或修改用例（如分辨率）时，应先调用 `unbindAll()`，然后重新绑定新的用例组合。

### 2.2 iOS AVCaptureSession 最佳实践

Apple 官方文档和社区经验指出，`AVCaptureSession` 的操作（如 `startRunning` 和 `stopRunning`）是阻塞的，必须在后台队列中执行[2]。
*   **中断处理**：必须监听 `AVCaptureSessionWasInterruptedNotification` 和 `AVCaptureSessionInterruptionEndedNotification`，以处理电话呼入或多任务切换导致的相机中断。
*   **后台策略**：应用进入后台时，系统会自动停止相机会话。应用切回前台时，应在中断结束通知中或 `sceneDidBecomeActive` 中重新启动会话。

### 2.3 Flutter 插件架构最佳实践

在 Flutter 插件中管理相机时，推荐引入**状态机（State Machine）**模式[3]。
*   将相机状态抽象为：`uninitialized`、`starting`、`running`、`stopping`、`paused`、`error`。
*   所有的操作（如切换镜头、修改参数）都应作为事件提交给状态机，由状态机根据当前状态决定是否执行或排队等待。

## 3. 系统性优化方案

基于上述分析，我们提出以下系统性优化方案，旨在彻底解决预览失效问题。

### 3.1 引入统一的相机状态机 (Camera State Machine)

在 Flutter 层（`camera_notifier.dart` 或新建 `camera_state_machine.dart`）引入严格的状态机。

| 状态 | 描述 | 允许的操作 |
| :--- | :--- | :--- |
| `Idle` | 初始状态，未请求权限或未初始化 | `initialize`, `requestPermission` |
| `Starting` | 正在初始化原生相机硬件 | 无（操作排队） |
| `Running` | 预览正常运行中 | `takePhoto`, `switchLens`, `updateParams` |
| `Paused` | 应用在后台或处于二级页面 | `resume` |
| `Reconfiguring` | 正在切换分辨率或重建 Renderer | 无（操作排队） |
| `Error` | 发生不可恢复的错误 | `retry` |

**核心机制**：
*   **操作队列**：当状态为 `Starting` 或 `Reconfiguring` 时，所有来自 UI 的参数更新（如滤镜、曝光）都会被放入队列，等待状态变为 `Running` 后统一应用，彻底消除竞态条件。

### 3.2 重构生命周期绑定 (Lifecycle Binding)

将生命周期管理从 `camera_screen.dart` 的 UI 逻辑中剥离，下沉到服务层或原生层。

*   **Flutter 层**：使用 `WidgetsBindingObserver` 的全局单例来监听 `AppLifecycleState`。
    *   `paused`：触发状态机进入 `Paused` 状态，通知原生层暂停渲染。
    *   `resumed`：触发状态机进入 `Starting` 状态，通知原生层恢复会话，并在就绪后自动重放（Replay）当前的完整渲染参数。
*   **Android 层**：充分利用 CameraX 的 `bindToLifecycle`。确保 `CameraPlugin` 能够正确响应 Activity 的生命周期事件。
*   **iOS 层**：在 `CameraSessionManager` 中添加对 `AVCaptureSessionWasInterruptedNotification` 的监听。当中断结束时，自动调用 `startRunning` 并通知 Flutter 层重新推送参数。

### 3.3 规范化参数重放机制 (Parameter Replay)

当前代码中存在多处手动拼接的参数重放逻辑（如 `_initCameraHardware` 和 `_pushWithCameraPause`）。应将其统一为一个单一的方法：

```dart
Future<void> _replayCurrentStateToNative() async {
  final state = ref.read(cameraAppProvider);
  if (state.camera == null) return;
  
  // 1. 同步相机基础配置
  await svc.setCamera(state.camera!);
  
  // 2. 同步镜头参数
  final lens = state.camera!.lensById(state.activeLensId);
  await svc.updateLensParams(...);
  
  // 3. 同步渲染参数 (滤镜、曝光、色温等)
  await svc.updateRenderParams(state.renderParams!.toJson());
  
  // 4. 同步其他状态 (缩放、镜像等)
  await svc.setZoom(state.zoomLevel);
  await svc.setMirrorFrontCamera(state.mirrorFrontCamera);
}
```
此方法仅在状态机进入 `Running` 状态时被调用一次。

### 3.4 优化原生层重建逻辑

*   **Android**：在 `setSharpen` 导致 `CameraGLRenderer` 重建时，使用 `CountDownLatch` 或 Kotlin Coroutines 的 `CompletableDeferred` 阻塞 Flutter 层的返回，直到新的 Surface 准备就绪。这可以防止 Flutter 层过早发送参数。
*   **iOS**：确保 `CADisplayLink` 的启停与 `AVCaptureSession` 的状态严格同步，避免在后台时继续触发渲染回调导致崩溃或卡死。

## 4. 实施步骤建议

1.  **第一阶段**：在 Flutter 层实现 `CameraStateMachine`，接管 `camera_screen.dart` 中的初始化和权限逻辑。
2.  **第二阶段**：实现统一的 `_replayCurrentStateToNative` 方法，替换掉所有散落的参数同步代码。
3.  **第三阶段**：在原生层（Android/iOS）完善生命周期事件的监听和阻塞等待机制。
4.  **第四阶段**：全面测试启动、后台切换、锁屏、电话呼入、频繁切换镜头等极端场景。

## References

[1] Android Developers. CameraX architecture. https://developer.android.com/media/camera/camerax/architecture
[2] Stack Overflow. Optimal handling of AVCaptureSession through app's lifecycle. https://stackoverflow.com/questions/73417733/optimal-handling-of-avcapturesession-through-apps-lifecycle
[3] Medium. State-Management in Flutter with MVP + Clean Architecture. https://martinnowosad.medium.com/flutter-model-view-presenter-clean-architecture-454bb601d755
