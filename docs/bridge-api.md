# 桥接 API 设计 (Bridge API)

本文件定义了 Flutter 与原生插件（iOS/Android）之间的通信协议。主要通过 `MethodChannel` 发送指令，通过 `EventChannel` 接收状态回调。

## 1. MethodChannel 接口定义

通道名称：`com.retrocam.app/camera_control`

| 方法名 | 参数 (JSON/Map) | 返回值 | 说明 |
|---|---|---|---|
| `initCamera` | `{ "presetId": "ccd_cool", "resolution": "1080p", "lens": "back" }` | `{"textureId": 123}` | 初始化相机并返回用于 Flutter 渲染的 Texture ID。 |
| `startPreview` | 无 | `{"success": true}` | 开始输出视频流到 Texture。 |
| `stopPreview` | 无 | `{"success": true}` | 暂停视频流输出。 |
| `switchLens` | `{"lens": "front" \| "back"}` | `{"success": true}` | 切换前后置摄像头。 |
| `setPreset` | `{ "preset": <PresetJSON> }` | `{"success": true}` | 切换当前相机的 Preset，原生层解析并加载对应 Shader/LUT。 |
| `updatePresetParams`| `{ "exposureBias": 0.5, "contrast": 1.2 }` | `{"success": true}` | 实时微调当前 Preset 的参数。 |
| `takePhoto` | `{"flashMode": "auto" \| "on" \| "off"}` | `{"filePath": "/path/to/photo.jpg"}` | 触发拍照，原生层执行全分辨率渲染并保存到本地。 |
| `startRecording` | `{"audioEnabled": true}` | `{"success": true}` | 开始录制视频。 |
| `stopRecording` | 无 | `{"filePath": "/path/to/video.mp4"}` | 停止录制并返回视频文件路径。 |
| `setFlashMode` | `{"mode": "auto" \| "on" \| "off"}` | `{"success": true}` | 设置闪光灯模式。 |
| `setAspectRatio` | `{"ratio": "4:3" \| "16:9" \| "1:1"}` | `{"success": true}` | 设置裁剪画幅比例。 |
| `enableTimestamp` | `{"enabled": true, "format": "yyyy MM dd", "color": "#FF8C00"}`| `{"success": true}` | 开启或关闭复古日期时间戳。 |
| `dispose` | 无 | `{"success": true}` | 释放相机和所有 GPU 资源。 |

## 2. EventChannel 回调定义

通道名称：`com.retrocam.app/camera_events`

原生层通过此通道向 Flutter 发送实时事件流。事件数据结构统一为 JSON。

| 事件类型 (type) | 负载数据 (payload) | 说明 |
|---|---|---|
| `onCameraReady` | `{"status": "ready"}` | 相机硬件初始化完成，准备好接收指令。 |
| `onPermissionDenied`| `{"reason": "camera" \| "microphone"}` | 用户拒绝了必要的权限。 |
| `onPhotoCaptured` | `{"filePath": "...", "thumbnail": "<base64>"}` | 照片拍摄并渲染完成，返回路径和缩略图。 |
| `onVideoRecorded` | `{"filePath": "...", "duration": 15.2}` | 视频录制完成。 |
| `onRecordingStateChanged` | `{"isRecording": true, "duration": 5.0}` | 录制状态变更或录制进度更新（如每秒回调一次）。 |
| `onError` | `{"code": 1001, "message": "Failed to start camera"}` | 发生严重错误，需要 UI 层提示用户。 |

## 3. 错误码建议

- `1001`: 相机初始化失败（硬件被占用或不支持）。
- `1002`: 权限未授予。
- `1003`: Preset 配置解析失败或资源缺失（如找不到 LUT 文件）。
- `1004`: 渲染管线错误（如 Shader 编译失败、OOM）。
- `1005`: 文件写入失败（磁盘空间不足）。
