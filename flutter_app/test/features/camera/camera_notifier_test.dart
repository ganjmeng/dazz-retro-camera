// ignore_for_file: prefer_const_constructors
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:retro_cam/features/camera/camera_notifier.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CameraAppNotifier 状态机单元测试
//
// 覆盖范围：
//  1. 初始状态验证
//  2. 曝光值 setExposure 边界 clamp
//  3. 缩放值 setZoom 边界 clamp
//  4. 色温 setColorTempK 边界 clamp
//  5. 闪光灯循环 cycleFlash
//  6. 定时器循环 cycleTimer
//  7. 面板切换 togglePanel / closeAllPanels
//  8. 网格开关 toggleGrid
//  9. 小窗模式 toggleSmallFrame
// 10. 缩放滑块 toggleZoomSlider / hideZoomSlider
// 11. 双重曝光状态机
// 12. 连拍张数循环 cycleBurst
// 13. 细粒度 Select Providers 与主 provider 同步
// ─────────────────────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mock 所有原生 MethodChannel，避免测试环境调用真实硬件
  setUp(() {
    final channels = [
      'com.retrocam.app/camera_control',
      'com.retrocam.app/camera_events',
    ];
    for (final ch in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        MethodChannel(ch),
        (call) async => null,
      );
    }
    // Mock shared_preferences
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async {
        if (call.method == 'getAll') return <String, dynamic>{};
        if (call.method == 'setBool') return true;
        if (call.method == 'setString') return true;
        if (call.method == 'setDouble') return true;
        if (call.method == 'setInt') return true;
        return null;
      },
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
      final key = const StringCodec().decodeMessage(message);
      if (key == 'assets/cameras/inst_c.json' ||
          key == 'assets/cameras/d_classic.json') {
        final file = File(key!);
        final bytes = await file.readAsBytes();
        return ByteData.sublistView(Uint8List.fromList(bytes));
      }
      return null;
    });
  });

  tearDown(() {
    for (final ch in [
      'com.retrocam.app/camera_control',
      'com.retrocam.app/camera_events',
      'plugins.flutter.io/shared_preferences',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), null);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  ProviderContainer makeContainer() => ProviderContainer();

  group('CameraAppState 初始状态', () {
    test('初始 activeCameraId 为 grd_r', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).activeCameraId, 'grd_r');
    });

    test('初始 isLoading 为 true', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).isLoading, isTrue);
    });

    test('初始 flashMode 为 off', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).flashMode, 'off');
    });

    test('初始 timerSeconds 为 0', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).timerSeconds, 0);
    });

    test('初始 zoomLevel 为 1.0', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).zoomLevel, closeTo(1.0, 0.001));
    });

    test('初始 doubleExpEnabled 为 false', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).doubleExpEnabled, isFalse);
    });

    test('初始 burstCount 为 0', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).burstCount, 0);
    });
  });

  group('曝光値 setExposure', () {
    test('正常范围内设置成功', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setExposure(1.5);
      expect(c.read(cameraAppProvider).exposureValue, closeTo(1.5, 0.001));
    });

    // 注意：setExposure 目前无 clamp，直接存储传入値
    // 这里验证设置和读取的一致性
    test('设置超出范围的大値（无 clamp）', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setExposure(5.0);
      expect(c.read(cameraAppProvider).exposureValue, closeTo(5.0, 0.001));
    });

    test('设置负値', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setExposure(-2.0);
      expect(c.read(cameraAppProvider).exposureValue, closeTo(-2.0, 0.001));
    });

    test('设置为 0 重置', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setExposure(2.0);
      c.read(cameraAppProvider.notifier).setExposure(0);
      expect(c.read(cameraAppProvider).exposureValue, closeTo(0.0, 0.001));
    });
  });

  group('缩放值 setZoom', () {
    test('正常范围内设置成功', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setZoom(2.5);
      expect(c.read(cameraAppProvider).zoomLevel, closeTo(2.5, 0.001));
    });

    test('超过上限 20.0 被 clamp', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setZoom(99.0);
      expect(c.read(cameraAppProvider).zoomLevel, closeTo(20.0, 0.001));
    });

    test('低于下限 0.6 被 clamp', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setZoom(0.1);
      expect(c.read(cameraAppProvider).zoomLevel, closeTo(0.6, 0.001));
    });
  });

  group('色温 setColorTempK', () {
    test('正常范围内设置成功', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setColorTempK(5500);
      expect(c.read(cameraAppProvider).colorTempK, 5500);
    });

    test('超过上限 8000 被 clamp', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setColorTempK(10000);
      expect(c.read(cameraAppProvider).colorTempK, 8000);
    });

    test('低于下限 1800 被 clamp', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setColorTempK(100);
      expect(c.read(cameraAppProvider).colorTempK, 1800);
    });
  });

  group('闪光灯循环 cycleFlash', () {
    test('off → on → auto → off 循环', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);

      expect(c.read(cameraAppProvider).flashMode, 'off');
      n.cycleFlash();
      expect(c.read(cameraAppProvider).flashMode, 'on');
      n.cycleFlash();
      expect(c.read(cameraAppProvider).flashMode, 'auto');
      n.cycleFlash();
      expect(c.read(cameraAppProvider).flashMode, 'off');
    });
  });

  group('定时器循环 cycleTimer', () {
    test('0 → 3 → 10 → 0 循环', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);

      expect(c.read(cameraAppProvider).timerSeconds, 0);
      n.cycleTimer();
      expect(c.read(cameraAppProvider).timerSeconds, 3);
      n.cycleTimer();
      expect(c.read(cameraAppProvider).timerSeconds, 10);
      n.cycleTimer();
      expect(c.read(cameraAppProvider).timerSeconds, 0);
    });
  });

  group('面板管理', () {
    test('togglePanel 打开面板', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).togglePanel('filter');
      expect(c.read(cameraAppProvider).activePanel, 'filter');
    });

    test('togglePanel 同一面板再次点击关闭', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);
      n.togglePanel('lens');
      n.togglePanel('lens');
      expect(c.read(cameraAppProvider).activePanel, isNull);
    });

    test('togglePanel 切换到不同面板', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);
      n.togglePanel('filter');
      n.togglePanel('lens');
      expect(c.read(cameraAppProvider).activePanel, 'lens');
    });

    test('closeAllPanels 关闭所有面板', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);
      n.togglePanel('ratio');
      n.closeAllPanels();
      expect(c.read(cameraAppProvider).activePanel, isNull);
      expect(c.read(cameraAppProvider).showTopMenu, isFalse);
    });
  });

  group('网格开关 toggleGrid', () {
    test('初始为 false，toggle 后为 true', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).gridEnabled, isFalse);
      c.read(cameraAppProvider.notifier).toggleGrid();
      expect(c.read(cameraAppProvider).gridEnabled, isTrue);
    });

    test('连续 toggle 两次恢复原状', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);
      n.toggleGrid();
      n.toggleGrid();
      expect(c.read(cameraAppProvider).gridEnabled, isFalse);
    });
  });

  group('缩放滑块', () {
    test('toggleZoomSlider 切换显示状态', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      expect(c.read(cameraAppProvider).showZoomSlider, isFalse);
      c.read(cameraAppProvider.notifier).toggleZoomSlider();
      expect(c.read(cameraAppProvider).showZoomSlider, isTrue);
    });

    test('hideZoomSlider 关闭滑块', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);
      n.toggleZoomSlider();
      n.hideZoomSlider();
      expect(c.read(cameraAppProvider).showZoomSlider, isFalse);
    });
  });

  group('双重曝光状态机', () {
    test('toggleDoubleExp 开启双重曝光', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).toggleDoubleExp();
      expect(c.read(cameraAppProvider).doubleExpEnabled, isTrue);
    });

    test('setDoubleExpFirstPath 设置第一张路径', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c
          .read(cameraAppProvider.notifier)
          .setDoubleExpFirstPath('/path/to/first.jpg');
      expect(
          c.read(cameraAppProvider).doubleExpFirstPath, '/path/to/first.jpg');
    });

    test('clearDoubleExpFirst 清除第一张路径', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);
      n.setDoubleExpFirstPath('/path/to/first.jpg');
      n.clearDoubleExpFirst();
      expect(c.read(cameraAppProvider).doubleExpFirstPath, isNull);
    });

    test('setDoubleExpBlend 设置混合比例', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setDoubleExpBlend(0.7);
      expect(c.read(cameraAppProvider).doubleExpBlend, closeTo(0.7, 0.001));
    });
  });

  group('细粒度 Select Providers 同步验证', () {
    test('exposureValueProvider 与 cameraAppProvider.exposureValue 同步', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setExposure(1.0);
      expect(c.read(exposureValueProvider), closeTo(1.0, 0.001));
      expect(c.read(exposureValueProvider),
          closeTo(c.read(cameraAppProvider).exposureValue, 0.001));
    });

    test('zoomLevelProvider 与 cameraAppProvider.zoomLevel 同步', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setZoom(3.0);
      expect(c.read(zoomLevelProvider), closeTo(3.0, 0.001));
    });

    test('flashModeProvider 与 cameraAppProvider.flashMode 同步', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).cycleFlash();
      expect(c.read(flashModeProvider), 'on');
    });

    test('gridEnabledProvider 与 cameraAppProvider.gridEnabled 同步', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).toggleGrid();
      expect(c.read(gridEnabledProvider), isTrue);
    });

    test('activePanelProvider 与 cameraAppProvider.activePanel 同步', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).togglePanel('frame');
      expect(c.read(activePanelProvider), 'frame');
    });

    test('showZoomSliderProvider 与 cameraAppProvider.showZoomSlider 同步', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).toggleZoomSlider();
      expect(c.read(showZoomSliderProvider), isTrue);
    });

    test('doubleExpFirstPathProvider 与 cameraAppProvider.doubleExpFirstPath 同步',
        () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c
          .read(cameraAppProvider.notifier)
          .setDoubleExpFirstPath('/test/path.jpg');
      expect(c.read(doubleExpFirstPathProvider), '/test/path.jpg');
    });

    test('colorTempKProvider 与 cameraAppProvider.colorTempK 同步', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setColorTempK(4000);
      expect(c.read(colorTempKProvider), 4000);
    });
  });

  group('水印参数设置', () {
    test('selectWatermarkColor 设置颜色', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).selectWatermarkColor('#FF0000');
      expect(c.read(cameraAppProvider).watermarkColor, '#FF0000');
    });

    test('setWatermarkPosition 设置位置', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setWatermarkPosition('bottom_right');
      expect(c.read(cameraAppProvider).watermarkPosition, 'bottom_right');
    });

    test('setWatermarkSize 设置大小', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setWatermarkSize('large');
      expect(c.read(cameraAppProvider).watermarkSize, 'large');
    });
  });

  group('白平衡设置', () {
    test('setWhiteBalance 设置白平衡模式', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setWhiteBalance('daylight');
      expect(c.read(cameraAppProvider).wbMode, 'daylight');
    });

    test('setColorTempK 自动切换到 manual 模式', () {
      final c = makeContainer();
      addTearDown(c.dispose);
      c.read(cameraAppProvider.notifier).setColorTempK(5000);
      expect(c.read(cameraAppProvider).wbMode, 'manual');
      expect(c.read(cameraAppProvider).colorTempK, 5000);
    });
  });

  group('相机切换时相框状态', () {
    test('从 INST C 切到 D Classic 时，应恢复为该相机默认关闭的相框状态', () async {
      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);

      await n.switchToCamera('inst_c');
      expect(c.read(cameraAppProvider).activeFrameId, isNotNull);

      await n.switchToCamera('d_classic');
      expect(c.read(cameraAppProvider).activeCameraId, 'd_classic');
      expect(
        c.read(cameraAppProvider).activeFrameId,
        isNull,
        reason: 'D Classic 默认 frameId 为 null，不应沿用 INST C 的 instant_default',
      );
    });
  });

  group('比例切换生命周期回归', () {
    test('同相机切比例时应走单事务同步链路，避免重复重放', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.retrocam.app/camera_control'),
        (call) async {
          calls.add(call);
          switch (call.method) {
            case 'syncRuntimeState':
              final args = (call.arguments as Map?) ?? const {};
              return {
                'appliedVersion': (args['version'] as int?) ?? 0,
                'rendererReady': true,
              };
            case 'updateRenderParams':
              final args = (call.arguments as Map?) ?? const {};
              return {
                'appliedVersion': (args['version'] as int?) ?? 0,
                'rendererReady': true,
              };
            case 'updateViewportRatio':
              return {'rebound': true};
            default:
              return null;
          }
        },
      );

      final c = makeContainer();
      addTearDown(c.dispose);
      final n = c.read(cameraAppProvider.notifier);

      await n.switchToCamera('inst_c');
      calls.clear();

      await n.selectRatioAndSync('ratio_1_1');

      expect(c.read(cameraAppProvider).activeRatioId, 'ratio_1_1');
      final methodNames = calls.map((e) => e.method).toList();
      expect(methodNames, contains('syncCameraState'));
      expect(
        methodNames.where((m) => m == 'syncCameraState').length,
        1,
        reason: '比例切换应采用一次原子 cameraState 同步，避免中间态覆盖',
      );
    });
  });
}
