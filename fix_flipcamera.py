import re

path = '/home/ubuntu/dazz-retro-camera/flutter_app/lib/features/camera/camera_notifier.dart'

with open(path, 'r') as f:
    content = f.read()

old = """  Future<void> flipCamera() async {
    state = state.copyWith(isFrontCamera: !state.isFrontCamera);
    await _ref.read(cameraServiceProvider.notifier).switchLens();
  }"""

new = """  Future<void> flipCamera() async {
    state = state.copyWith(isFrontCamera: !state.isFrontCamera);
    await _ref.read(cameraServiceProvider.notifier).switchLens();
    // ── FIX: switchLens 会重建 native renderer，所有 uniform 参数丢失。
    // 必须重新发送当前相机参数和镜头参数到 native GPU shader。
    final camera = state.camera;
    if (camera != null) {
      await _ref.read(cameraServiceProvider.notifier).setCamera(camera);
      final lens = camera.lensById(state.activeLensId);
      _ref.read(cameraServiceProvider.notifier).updateLensParams(
        distortion: lens?.distortion ?? 0.0,
        vignette: lens?.vignette ?? 0.0,
        zoomFactor: lens?.zoomFactor ?? 1.0,
        fisheyeMode: lens?.fisheyeMode ?? false,
      );
    }
  }"""

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("OK: flipCamera patched")
else:
    print("ERROR: old pattern not found")
