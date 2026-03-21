package com.retrocam.app.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class MotionPhotoPackagingTest {
    @Test
    fun `display name follows MP suffix convention`() {
        val name = MotionPhotoPackaging.buildDisplayName("FQN", "20260321_120000")
        assertTrue(name.endsWith("MP.jpg"))
        assertTrue(!name.contains(".MP.jpg"))
    }

    @Test
    fun `packageMotionPhoto writes app1 xmp and appended mp4 with matching offsets`() {
        val tempDir = createTempDir(prefix = "motion-photo-test")
        try {
            val image = File(tempDir, "source.jpg")
            val video = File(tempDir, "video.mp4")
            val output = File(tempDir, "packedMP.jpg")

            image.writeBytes(
                byteArrayOf(
                    0xFF.toByte(), 0xD8.toByte(),
                    0xFF.toByte(), 0xE0.toByte(), 0x00, 0x10,
                    0x4A, 0x46, 0x49, 0x46, 0x00,
                    0x01, 0x02, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
                    0xFF.toByte(), 0xD9.toByte(),
                ),
            )
            video.writeBytes(
                byteArrayOf(
                    0x00, 0x00, 0x00, 0x18,
                    0x66, 0x74, 0x79, 0x70,
                    0x6D, 0x70, 0x34, 0x32,
                    0x00, 0x00, 0x00, 0x00,
                    0x69, 0x73, 0x6F, 0x6D,
                    0x6D, 0x70, 0x34, 0x32,
                ),
            )

            MotionPhotoPackaging.packageMotionPhoto(
                imageFile = image,
                videoFile = video,
                outputFile = output,
                presentationTimestampUs = 411003L,
                metadata = MotionPhotoPackaging.PackagingMetadata(
                    imageWidth = 3072,
                    imageHeight = 4096,
                ),
            )

            val inspection = MotionPhotoPackaging.inspectMotionPhoto(output)
            assertTrue(inspection.hasStandardApp1Xmp)
            assertTrue(inspection.fileNameMatchesOfficialPattern)
            assertTrue(inspection.hasExtendedXmp)
            assertNotNull(inspection.xmpXml)
            assertTrue(inspection.xmpXml!!.contains("<Camera:MotionPhoto>1</Camera:MotionPhoto>"))
            assertTrue(inspection.xmpXml.contains("<Camera:MicroVideo>1</Camera:MicroVideo>"))
            assertTrue(inspection.xmpXml.contains("<GCamera:MicroVideo>1</GCamera:MicroVideo>"))
            assertTrue(inspection.xmpXml.contains("<OpCamera:MotionPhotoOwner>oplus</OpCamera:MotionPhotoOwner>"))
            assertTrue(inspection.xmpXml.contains("Item:Semantic=\"MotionPhoto\""))
            assertEquals(video.length(), inspection.itemLength)
            assertEquals(video.length(), inspection.microVideoOffset)
            assertEquals(video.length(), inspection.appendedVideoLength)
        } finally {
            tempDir.deleteRecursively()
        }
    }
}
