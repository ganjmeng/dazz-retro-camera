// ignore_for_file: prefer_const_constructors
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_cam/models/camera_definition.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CameraDefinition 单元测试
//
// 覆盖范围：
//  1. 完整 JSON 解析（grd_r 风格）
//  2. 拍立得 JSON 解析（inst_c 风格，含 width/height 修复验证）
//  3. 缺失可选字段的容错处理
//  4. RatioDefinition.aspectRatio 计算
//  5. filterById / lensById / ratioById / frameById 查找方法
//  6. isFrameEnabled 逻辑
//  7. DefaultLook 色彩参数范围验证
//  8. LensDefinition 参数解析
//  9. FrameDefinition.assetForRatio / insetForRatio 优先级
// 10. 强制 as num 字段 null 时的异常行为（回归测试：拍立得 Bug 复现）
// ─────────────────────────────────────────────────────────────────────────────

// ── 测试用 JSON 工厂 ──────────────────────────────────────────────────────────

Map<String, dynamic> _makeMinimalCameraJson({
  String id = 'test_cam',
  String name = 'Test Cam',
  String category = 'digital',
  String mode = 'photo',
}) {
  return {
    'id': id,
    'name': name,
    'category': category,
    'mode': mode,
    'supportsPhoto': true,
    'supportsVideo': false,
    'focalLengthLabel': '28mm',
    'sensor': {
      'type': 'cmos',
      'dynamicRange': 11,
      'baseNoise': 0.15,
      'colorDepth': 12,
    },
    'defaultLook': {
      'baseLut': 'assets/lut/cameras/test.cube',
      'temperature': 2.0,
      'tint': 0.0,
      'contrast': 1.18,
      'highlights': -10.0,
      'shadows': -18.0,
      'whites': 12.0,
      'blacks': -22.0,
      'clarity': 25.0,
      'vibrance': 0.9,
      'saturation': 0.95,
      'vignette': 0.08,
      'distortion': 0.0,
      'chromaticAberration': 0.0,
      'bloom': 0.0,
      'flare': 0.0,
      'grain': 0.12,
      'colorBiasR': 0.0,
      'colorBiasG': 0.0,
      'colorBiasB': 0.0,
    },
    'modules': {
      'filters': [
        {
          'id': 'filter_none',
          'name': '无',
          'nameEn': 'None',
          'lut': null,
          'contrast': 1.0,
          'saturation': 1.0,
          'grain': 'none',
        }
      ],
      'lenses': [
        {
          'id': 'wide',
          'name': '广角',
          'nameEn': 'Wide',
          'zoomFactor': 0.6,
          'distortion': -0.05,
          'vignette': 0.04,
          'chromaticAberration': 0.01,
          'fisheyeMode': false,
        }
      ],
      'ratios': [
        {'id': 'ratio_1_1', 'label': '1:1', 'width': 1, 'height': 1, 'supportsFrame': true},
        {'id': 'ratio_3_4', 'label': '3:4', 'width': 3, 'height': 4, 'supportsFrame': true},
        {'id': 'ratio_9_16', 'label': '9:16', 'width': 9, 'height': 16, 'supportsFrame': false},
      ],
      'frames': [
        {
          'id': 'frame_default',
          'name': '默认',
          'nameEn': 'Default',
          'asset': 'assets/frames/frame_default.png',
          'ratioAssets': {
            'ratio_1_1': 'assets/frames/frame_default_1x1.png',
          },
          'backgroundColor': '#FFFFFF',
          'inset': {'top': 10.0, 'right': 10.0, 'bottom': 10.0, 'left': 10.0},
          'ratioInsets': {
            'ratio_1_1': {'top': 5.0, 'right': 5.0, 'bottom': 5.0, 'left': 5.0},
          },
          'supportedRatios': ['ratio_1_1', 'ratio_3_4'],
          'lightLeak': 0.0,
          'shake': 0.0,
          'outerPadding': 0.0,
          'outerBackgroundColor': '#FFFFFF',
          'cornerRadius': 0.0,
          'innerShadow': false,
          'supportsBackground': false,
        }
      ],
      'watermarks': {
        'presets': [
          {
            'id': 'none',
            'name': '无水印',
            'nameEn': 'None',
            'type': 'none',
          }
        ],
        'editor': {},
      },
      'extras': [],
    },
    'defaultSelection': {
      'filterId': null,
      'lensId': 'wide',
      'ratioId': 'ratio_3_4',
      'frameId': null,
      'watermarkPresetId': 'none',
      'extraId': null,
    },
    'uiCapabilities': {
      'enableFilter': true,
      'enableLens': true,
      'enableRatio': true,
      'enableFrame': true,
      'enableWatermark': true,
      'enableExtra': false,
    },
    'previewCapabilities': {
      'allowSmallViewport': true,
      'allowGridOverlay': true,
      'allowZoom': true,
      'allowImportImage': true,
      'allowTimer': true,
      'allowFlash': true,
    },
    'previewPolicy': {
      'enableLut': true,
      'enableTemperature': true,
      'enableContrast': true,
      'enableSaturation': true,
      'enableVignette': true,
      'enableLightLensEffect': false,
      'enableGrain': true,
      'enableBloom': false,
      'enableChromaticAberration': false,
      'enableFrameComposite': false,
      'enableWatermarkComposite': true,
    },
    'exportPolicy': {
      'jpegQuality': 0.92,
      'applyRatioCrop': true,
      'applyFrameOnExport': true,
      'applyWatermarkOnExport': true,
      'preserveMetadata': true,
    },
    'videoConfig': {
      'enabled': false,
      'fpsOptions': [30],
      'resolutionOptions': ['HD'],
      'defaultFps': 30,
      'defaultResolution': 'HD',
      'supportsAudio': true,
      'videoBitrate': 12000000,
    },
    'assets': {
      'thumbnail': 'assets/thumbnails/cameras/test_icon.png',
      'icon': 'assets/thumbnails/cameras/test_icon.png',
    },
    'meta': {
      'version': '1.0',
      'premium': false,
      'sortOrder': 10,
      'tags': ['digital', 'test'],
    },
  };
}

void main() {
  group('CameraDefinition.fromJson', () {
    test('解析完整 JSON 字段正确', () {
      final json = _makeMinimalCameraJson();
      final cam = CameraDefinition.fromJson(json);

      expect(cam.id, 'test_cam');
      expect(cam.name, 'Test Cam');
      expect(cam.category, 'digital');
      expect(cam.mode, 'photo');
      expect(cam.supportsPhoto, isTrue);
      expect(cam.supportsVideo, isFalse);
      expect(cam.focalLengthLabel, '28mm');
    });

    test('sensor 字段解析正确', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.sensor.type, 'cmos');
      expect(cam.sensor.dynamicRange, 11);
      expect(cam.sensor.baseNoise, closeTo(0.15, 0.001));
      expect(cam.sensor.colorDepth, 12);
    });

    test('defaultLook 色彩参数解析正确', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      final look = cam.defaultLook;
      expect(look.contrast, closeTo(1.18, 0.001));
      expect(look.saturation, closeTo(0.95, 0.001));
      expect(look.vignette, closeTo(0.08, 0.001));
      expect(look.grain, closeTo(0.12, 0.001));
      expect(look.temperature, closeTo(2.0, 0.001));
      expect(look.baseLut, 'assets/lut/cameras/test.cube');
    });

    test('modules.filters 解析正确', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.modules.filters, hasLength(1));
      final f = cam.modules.filters.first;
      expect(f.id, 'filter_none');
      expect(f.name, '无');
      expect(f.nameEn, 'None');
      expect(f.contrast, closeTo(1.0, 0.001));
      expect(f.grain, 'none');
    });

    test('modules.lenses 解析正确', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.modules.lenses, hasLength(1));
      final l = cam.modules.lenses.first;
      expect(l.id, 'wide');
      expect(l.zoomFactor, closeTo(0.6, 0.001));
      expect(l.distortion, closeTo(-0.05, 0.001));
      expect(l.fisheyeMode, isFalse);
    });

    test('modules.ratios 解析正确，aspectRatio 计算正确', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.modules.ratios, hasLength(3));

      final r1 = cam.modules.ratios[0];
      expect(r1.id, 'ratio_1_1');
      expect(r1.width, 1);
      expect(r1.height, 1);
      expect(r1.aspectRatio, closeTo(1.0, 0.001));
      expect(r1.supportsFrame, isTrue);

      final r2 = cam.modules.ratios[1];
      expect(r2.id, 'ratio_3_4');
      expect(r2.aspectRatio, closeTo(0.75, 0.001));

      final r3 = cam.modules.ratios[2];
      expect(r3.id, 'ratio_9_16');
      expect(r3.supportsFrame, isFalse);
    });

    test('defaultSelection 解析正确', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      final sel = cam.defaultSelection;
      expect(sel.filterId, isNull);
      expect(sel.lensId, 'wide');
      expect(sel.ratioId, 'ratio_3_4');
      expect(sel.frameId, isNull);
      expect(sel.watermarkPresetId, 'none');
    });

    test('uiCapabilities 解析正确', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      final ui = cam.uiCapabilities;
      expect(ui.enableFilter, isTrue);
      expect(ui.enableLens, isTrue);
      expect(ui.enableRatio, isTrue);
      expect(ui.enableFrame, isTrue);
      expect(ui.enableExtra, isFalse);
    });
  });

  // ── 拍立得相机专项测试（回归：inst_c Bug 修复验证）─────────────────────────
  group('拍立得相机 JSON 解析（inst_c 风格）', () {
    Map<String, dynamic> _makeInstantCameraJson() {
      final json = _makeMinimalCameraJson(
        id: 'inst_c',
        name: 'INST C',
        category: 'instant',
      );
      // 拍立得只有两个比例，且有 width/height（修复后）
      json['modules']['ratios'] = [
        {'id': 'ratio_1_1', 'label': '1:1', 'width': 1, 'height': 1, 'supportsFrame': true},
        {'id': 'ratio_3_4', 'label': '3:4', 'width': 3, 'height': 4, 'supportsFrame': true},
      ];
      json['defaultSelection']['frameId'] = 'instant_default';
      json['uiCapabilities']['enableFilter'] = false;
      return json;
    }

    test('拍立得相机 ratios 解析成功（不抛出异常）', () {
      expect(() => CameraDefinition.fromJson(_makeInstantCameraJson()), returnsNormally);
    });

    test('拍立得相机只有 2 个比例', () {
      final cam = CameraDefinition.fromJson(_makeInstantCameraJson());
      expect(cam.modules.ratios, hasLength(2));
    });

    test('拍立得相机默认比例 3:4 宽高正确', () {
      final cam = CameraDefinition.fromJson(_makeInstantCameraJson());
      final ratio = cam.modules.ratios.firstWhere((r) => r.id == 'ratio_3_4');
      expect(ratio.width, 3);
      expect(ratio.height, 4);
      expect(ratio.aspectRatio, closeTo(0.75, 0.001));
    });

    test('拍立得相机默认选中相框 instant_default', () {
      final cam = CameraDefinition.fromJson(_makeInstantCameraJson());
      expect(cam.defaultSelection.frameId, 'instant_default');
    });

    test('拍立得相机 enableFilter=false', () {
      final cam = CameraDefinition.fromJson(_makeInstantCameraJson());
      // 拍立得不显示滤镜选择器
      expect(cam.uiCapabilities.enableFilter, isFalse);
    });

    // 回归测试：确保修复前的 Bug 不会复发
    // 修复前：ratios 中缺少 width/height 字段，(json['width'] as num) 会抛出 TypeError
    test('回归：ratios 缺少 width 字段时抛出 TypeError（确认修复必要性）', () {
      final json = _makeInstantCameraJson();
      // 模拟修复前的错误数据：ratios 缺少 width/height
      json['modules']['ratios'] = [
        {'id': 'ratio_1_1', 'label': '1:1', 'supportsFrame': true},
        // 故意不加 width/height
      ];
      expect(
        () => CameraDefinition.fromJson(json),
        throwsA(isA<TypeError>()),
        reason: '缺少 width/height 字段时，(json["width"] as num) 应抛出 TypeError',
      );
    });
  });

  // ── 查找方法测试 ──────────────────────────────────────────────────────────
  group('CameraDefinition 查找方法', () {
    late CameraDefinition cam;

    setUp(() {
      cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
    });

    test('filterById 找到存在的 filter', () {
      final f = cam.filterById('filter_none');
      expect(f, isNotNull);
      expect(f!.id, 'filter_none');
    });

    test('filterById 返回 null 当 id 不存在', () {
      expect(cam.filterById('not_exist'), isNull);
    });

    test('filterById 返回 null 当 id 为 null', () {
      expect(cam.filterById(null), isNull);
    });

    test('lensById 找到存在的 lens', () {
      final l = cam.lensById('wide');
      expect(l, isNotNull);
      expect(l!.id, 'wide');
    });

    test('lensById 返回 null 当 id 不存在', () {
      expect(cam.lensById('telephoto'), isNull);
    });

    test('ratioById 找到 ratio_3_4', () {
      final r = cam.ratioById('ratio_3_4');
      expect(r, isNotNull);
      expect(r!.width, 3);
      expect(r.height, 4);
    });

    test('frameById 找到存在的 frame', () {
      final f = cam.frameById('frame_default');
      expect(f, isNotNull);
      expect(f!.id, 'frame_default');
    });

    test('frameById 返回 null 当 id 为 null', () {
      expect(cam.frameById(null), isNull);
    });
  });

  // ── isFrameEnabled 逻辑测试 ───────────────────────────────────────────────
  group('isFrameEnabled', () {
    test('ratio_1_1 supportsFrame=true 且 enableFrame=true 时返回 true', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.isFrameEnabled('ratio_1_1'), isTrue);
    });

    test('ratio_9_16 supportsFrame=false 时返回 false', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.isFrameEnabled('ratio_9_16'), isFalse);
    });

    test('enableFrame=false 时始终返回 false', () {
      final json = _makeMinimalCameraJson();
      json['uiCapabilities']['enableFrame'] = false;
      final cam = CameraDefinition.fromJson(json);
      expect(cam.isFrameEnabled('ratio_1_1'), isFalse);
      expect(cam.isFrameEnabled('ratio_3_4'), isFalse);
    });

    test('ratioId 为 null 时返回 false', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.isFrameEnabled(null), isFalse);
    });
  });

  // ── FrameDefinition 优先级测试 ────────────────────────────────────────────
  group('FrameDefinition.assetForRatio / insetForRatio', () {
    late FrameDefinition frame;

    setUp(() {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      frame = cam.modules.frames.first;
    });

    test('assetForRatio 优先返回 ratioAssets 中的路径', () {
      expect(frame.assetForRatio('ratio_1_1'), 'assets/frames/frame_default_1x1.png');
    });

    test('assetForRatio 回退到 asset 当 ratioAssets 无对应比例', () {
      expect(frame.assetForRatio('ratio_3_4'), 'assets/frames/frame_default.png');
    });

    test('assetForRatio 回退到 asset 当 ratioId 为 null', () {
      expect(frame.assetForRatio(null), 'assets/frames/frame_default.png');
    });

    test('insetForRatio 优先返回 ratioInsets 中的 inset', () {
      final inset = frame.insetForRatio('ratio_1_1');
      expect(inset.top, closeTo(5.0, 0.001));
      expect(inset.right, closeTo(5.0, 0.001));
    });

    test('insetForRatio 回退到默认 inset 当无对应比例', () {
      final inset = frame.insetForRatio('ratio_3_4');
      expect(inset.top, closeTo(10.0, 0.001));
    });
  });

  // ── DefaultLook 色彩参数范围验证 ──────────────────────────────────────────
  group('DefaultLook 色彩参数范围', () {
    test('contrast 在合理范围内 (0.5~1.8)', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.defaultLook.contrast, inInclusiveRange(0.5, 1.8));
    });

    test('saturation 在合理范围内 (0.0~2.0)', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.defaultLook.saturation, inInclusiveRange(0.0, 2.0));
    });

    test('vignette 在合理范围内 (0.0~1.0)', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.defaultLook.vignette, inInclusiveRange(0.0, 1.0));
    });

    test('grain 在合理范围内 (0.0~1.0)', () {
      final cam = CameraDefinition.fromJson(_makeMinimalCameraJson());
      expect(cam.defaultLook.grain, inInclusiveRange(0.0, 1.0));
    });

    test('DefaultLook.empty() 返回安全默认值', () {
      final look = DefaultLook.empty();
      expect(look.contrast, closeTo(1.0, 0.001));
      expect(look.saturation, closeTo(1.0, 0.001));
      expect(look.vignette, closeTo(0.0, 0.001));
      expect(look.grain, closeTo(0.0, 0.001));
    });
  });

  // ── LensDefinition 参数测试 ───────────────────────────────────────────────
  group('LensDefinition', () {
    test('fisheyeMode 默认为 false', () {
      final json = {
        'id': 'std',
        'name': '标准',
        'nameEn': 'Standard',
        'zoomFactor': 1.0,
        'distortion': 0.0,
        'vignette': 0.02,
        'chromaticAberration': 0.0,
      };
      final lens = LensDefinition.fromJson(json);
      expect(lens.fisheyeMode, isFalse);
    });

    test('fisheyeMode 可以设为 true', () {
      final json = {
        'id': 'fisheye',
        'name': '鱼眼',
        'nameEn': 'Fisheye',
        'zoomFactor': 1.0,
        'distortion': 0.8,
        'vignette': 0.5,
        'chromaticAberration': 0.1,
        'fisheyeMode': true,
      };
      final lens = LensDefinition.fromJson(json);
      expect(lens.fisheyeMode, isTrue);
    });

    test('缺失可选字段时使用默认值', () {
      final json = {
        'id': 'minimal',
        'name': '最小',
        'nameEn': 'Minimal',
        'distortion': 0.0,
        'vignette': 0.0,
        'chromaticAberration': 0.0,
      };
      final lens = LensDefinition.fromJson(json);
      expect(lens.zoomFactor, closeTo(1.0, 0.001));
      expect(lens.edgeBlur, closeTo(0.0, 0.001));
      expect(lens.exposure, closeTo(0.0, 0.001));
      expect(lens.bloom, closeTo(0.0, 0.001));
      expect(lens.iconPath, isNull);
    });
  });

  // ── FilterDefinition 测试 ─────────────────────────────────────────────────
  group('FilterDefinition', () {
    test('nameEn 回退到 name 当 nameEn 缺失', () {
      final json = {
        'id': 'f1',
        'name': '暖调',
        'contrast': 1.1,
        'saturation': 1.2,
        'grain': 'light',
      };
      final filter = FilterDefinition.fromJson(json);
      expect(filter.nameEn, '暖调'); // 回退到 name
    });

    test('grain 缺失时默认为 none', () {
      final json = {
        'id': 'f2',
        'name': 'Test',
        'nameEn': 'Test',
        'contrast': 1.0,
        'saturation': 1.0,
      };
      final filter = FilterDefinition.fromJson(json);
      expect(filter.grain, 'none');
    });
  });
}
