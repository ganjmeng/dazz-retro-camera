import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Regression: Android motion photo packaging', () {
    final file = File(
      'android/app/src/main/kotlin/com/retrocam/app/camera/CameraPlugin.kt',
    );

    test('should embed XMP into JPEG before appending video bytes', () {
      if (!file.existsSync()) return;
      final content = file.readAsStringSync();

      expect(
        content.contains('ExifInterface.TAG_XMP'),
        isTrue,
        reason: 'Motion photo JPEG 应通过 ExifInterface.TAG_XMP 写入嵌入式 XMP',
      );
      expect(
        content.contains('buildMotionPhotoXmp('),
        isTrue,
        reason: 'Motion photo 应生成专用 XMP 内容',
      );
      expect(
        content.contains('input.copyTo(output)') &&
            content.contains('videoInput.copyTo(output)'),
        isTrue,
        reason: 'Motion photo 文件应先写 JPEG，再把 MP4 直接追加到文件尾',
      );
    });

    test('should include Google motion photo XMP markers', () {
      if (!file.existsSync()) return;
      final content = file.readAsStringSync();

      final requiredTags = [
        'GCamera:MotionPhoto="1"',
        'GCamera:MotionPhotoVersion="1"',
        'GCamera:MotionPhotoPresentationTimestampUs=',
        'GCamera:MicroVideo="1"',
        'GCamera:MicroVideoOffset=',
        'Item:Mime="image/jpeg"',
        'Item:Semantic="Primary"',
        'Item:Mime="video/mp4"',
        'Item:Semantic="MotionPhoto"',
        'Item:Length="',
        'Item:Padding="0"',
      ];

      for (final tag in requiredTags) {
        expect(
          content.contains(tag),
          isTrue,
          reason: 'Motion photo XMP 应包含 $tag',
        );
      }
    });

    test('should save through MediaStore with pending flag', () {
      if (!file.existsSync()) return;
      final content = file.readAsStringSync();

      expect(
        content.contains('MediaStore.Images.Media.EXTERNAL_CONTENT_URI'),
        isTrue,
        reason: 'Motion photo 应通过 MediaStore 写入系统相册',
      );
      expect(
        content.contains('MediaStore.Images.Media.IS_PENDING, 1'),
        isTrue,
        reason: '写入 motion photo 时应先设置 IS_PENDING=1',
      );
      expect(
        content.contains('MediaStore.Images.Media.IS_PENDING, 0'),
        isTrue,
        reason: '写入完成后应恢复 IS_PENDING=0',
      );
      expect(
        content.contains('MediaStore.Images.Media.MIME_TYPE, "image/jpeg"'),
        isTrue,
        reason: 'Motion photo 主文件应以 image/jpeg 写入图库',
      );
    });
  });
}
