import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Regression: Android motion photo packaging', () {
    final pluginFile = File(
      'android/app/src/main/kotlin/com/retrocam/app/camera/CameraPlugin.kt',
    );
    final packagingFile = File(
      'android/app/src/main/kotlin/com/retrocam/app/camera/MotionPhotoPackaging.kt',
    );

    test('should embed XMP into JPEG before appending video bytes', () {
      if (!pluginFile.existsSync() || !packagingFile.existsSync()) return;
      final pluginContent = pluginFile.readAsStringSync();
      final packagingContent = packagingFile.readAsStringSync();

      expect(
        pluginContent.contains('MotionPhotoPackaging.packageMotionPhoto('),
        isTrue,
        reason: 'Motion photo JPEG 应通过专用 packaging helper 写入嵌入式 XMP',
      );
      expect(
        pluginContent.contains('MotionPhotoPackaging.buildMotionPhotoXmp('),
        isTrue,
        reason: 'Motion photo 应生成专用 XMP 内容',
      );
      expect(
        pluginContent.contains('MotionPhotoPackaging.buildDisplayName('),
        isTrue,
        reason: 'Motion photo 文件名应统一通过 packaging helper 生成',
      );
      expect(
        pluginContent.contains('ExifInterface.TAG_XMP'),
        isFalse,
        reason: 'Motion photo 不应继续依赖 ExifInterface.TAG_XMP 序列化自定义 XMP',
      );
      expect(
        packagingContent.contains('output.write(videoFile.readBytes())') &&
            packagingContent.contains('writeApp1Segment('),
        isTrue,
        reason: 'Motion photo 文件应通过 helper 统一生成 XMP 和尾部视频拼接',
      );
    });

    test('should include Google motion photo XMP markers', () {
      if (!packagingFile.existsSync()) return;
      final content = packagingFile.readAsStringSync();

      final requiredTags = [
        'x:xmptk="Adobe XMP Core 5.1.0-jc003"',
        '<Camera:MotionPhoto>1</Camera:MotionPhoto>',
        '<Camera:MotionPhotoVersion>1</Camera:MotionPhotoVersion>',
        '<Camera:MotionPhotoPresentationTimestampUs>',
        '<Camera:MicroVideo>1</Camera:MicroVideo>',
        '<Camera:MicroVideoOffset>',
        '<GCamera:MotionPhoto>1</GCamera:MotionPhoto>',
        '<GCamera:MotionPhotoVersion>1</GCamera:MotionPhotoVersion>',
        '<GCamera:MotionPhotoPresentationTimestampUs>',
        '<GCamera:MicroVideo>1</GCamera:MicroVideo>',
        '<GCamera:MicroVideoOffset>',
        'Item:Mime="image/jpeg"',
        'Item:Semantic="Primary"',
        'Item:Mime="video/mp4"',
        'Item:Semantic="MotionPhoto"',
        'Item:Length="',
        'Item:Padding="0"',
        '<OpCamera:MotionPhotoOwner>oplus</OpCamera:MotionPhotoOwner>',
        '<OpCamera:MotionPhotoPrimaryPresentationTimestampUs>',
        '<OpCamera:OLivePhotoVersion>2</OpCamera:OLivePhotoVersion>',
        '<OpCamera:VideoLength>',
        'xmlns:xmpNote="http://ns.adobe.com/xmp/note/"',
        '<xmpNote:HasExtendedXMP>',
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
      if (!pluginFile.existsSync()) return;
      final content = pluginFile.readAsStringSync();

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

    test('should name motion photo files with MP suffix before extension', () {
      if (!packagingFile.existsSync()) return;
      final content = packagingFile.readAsStringSync();

      expect(
        content.contains('MP.jpg'),
        isTrue,
        reason: 'Motion photo 文件名应在扩展名前以 MP 结尾，贴近 Android 官方命名模式',
      );
      expect(
        content.contains('.MP.jpg'),
        isFalse,
        reason: 'Motion photo 文件名不应额外插入 .MP.jpg 这种非官方样式',
      );
    });
  });
}
