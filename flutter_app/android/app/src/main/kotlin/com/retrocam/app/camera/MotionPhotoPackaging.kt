package com.retrocam.app.camera

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Locale
import kotlin.text.Charsets.UTF_8

internal object MotionPhotoPackaging {
    private val standardXmpHeader = "http://ns.adobe.com/xap/1.0/\u0000".toByteArray(UTF_8)
    private val extendedXmpHeader = "http://ns.adobe.com/xmp/extension/\u0000".toByteArray(UTF_8)
    private val mp4HeaderSignatures = listOf(
        "ftypmp42".toByteArray(UTF_8),
        "ftypmp4".toByteArray(UTF_8),
        "ftypisom".toByteArray(UTF_8),
        "ftyp".toByteArray(UTF_8),
    )
    private const val jpegSoi = 0xFFD8
    private const val jpegApp1 = 0xFFE1
    private const val jpegSos = 0xFFDA
    private const val jpegEoi = 0xFFD9
    private const val maxApp1PayloadSize = 0xFFFF - 2
    private val fileNameRegex = Regex("^([^\\s/\\\\][^/\\\\]*MP)\\.(JPG|jpg|JPEG|jpeg|HEIC|heic|AVIF|avif)$")

    data class Inspection(
        val xmpXml: String?,
        val appendedVideoOffset: Long,
        val appendedVideoLength: Long,
        val itemLength: Long?,
        val microVideoOffset: Long?,
        val hasStandardApp1Xmp: Boolean,
        val hasExtendedXmp: Boolean,
        val fileNameMatchesOfficialPattern: Boolean,
    )

    data class PackagingMetadata(
        val imageWidth: Int? = null,
        val imageHeight: Int? = null,
        val gainMapBytes: ByteArray? = null,
    )

    fun buildDisplayName(cameraId: String, timestamp: String): String {
        return if (cameraId.isNotEmpty()) {
            "DAZZ_${cameraId}_${timestamp}MP.jpg"
        } else {
            "DAZZ_MOTION_${timestamp}MP.jpg"
        }
    }

    fun buildMotionPhotoXmp(
        videoLength: Long,
        presentationTimestampUs: Long,
        extendedGuid: String?,
        gainMapLength: Long = 0L,
    ): String {
        val hasExtended = extendedGuid?.isNotEmpty() == true
        val hasGainMap = gainMapLength > 0L
        val extendedNode = if (hasExtended) {
            "<xmpNote:HasExtendedXMP>$extendedGuid</xmpNote:HasExtendedXMP>"
        } else {
            "<xmpNote:HasExtendedXMP></xmpNote:HasExtendedXMP>"
        }
        val gainMapNode = if (hasGainMap) {
            """
                      <rdf:li rdf:parseType="Resource"
                          Item:Mime="image/jpeg"
                          Item:Semantic="GainMap"
                          Item:Length="$gainMapLength"
                          Item:Padding="0"/>
            """.trimIndent()
        } else {
            ""
        }
        val hdrgmNode = if (hasGainMap) {
            """
                <rdf:Description rdf:about=""
                    xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"
                    hdrgm:Version="1.0"/>
            """.trimIndent()
        } else {
            ""
        }
        return """
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0-jc003">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                    xmlns:Camera="http://ns.google.com/photos/1.0/camera/"
                    xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
                    xmlns:xmpNote="http://ns.adobe.com/xmp/note/">
                  <Camera:MotionPhoto>1</Camera:MotionPhoto>
                  <Camera:MotionPhotoVersion>1</Camera:MotionPhotoVersion>
                  <Camera:MotionPhotoPresentationTimestampUs>$presentationTimestampUs</Camera:MotionPhotoPresentationTimestampUs>
                  <Camera:MicroVideo>1</Camera:MicroVideo>
                  <Camera:MicroVideoVersion>1</Camera:MicroVideoVersion>
                  <Camera:MicroVideoOffset>$videoLength</Camera:MicroVideoOffset>
                  <Camera:MicroVideoPresentationTimestampUs>$presentationTimestampUs</Camera:MicroVideoPresentationTimestampUs>
                  <GCamera:MotionPhoto>1</GCamera:MotionPhoto>
                  <GCamera:MotionPhotoVersion>1</GCamera:MotionPhotoVersion>
                  <GCamera:MotionPhotoPresentationTimestampUs>$presentationTimestampUs</GCamera:MotionPhotoPresentationTimestampUs>
                  <GCamera:MicroVideo>1</GCamera:MicroVideo>
                  <GCamera:MicroVideoVersion>1</GCamera:MicroVideoVersion>
                  <GCamera:MicroVideoOffset>$videoLength</GCamera:MicroVideoOffset>
                  <GCamera:MicroVideoPresentationTimestampUs>$presentationTimestampUs</GCamera:MicroVideoPresentationTimestampUs>
                  $extendedNode
                </rdf:Description>
                <rdf:Description rdf:about=""
                    xmlns:Container="http://ns.google.com/photos/1.0/container/"
                    xmlns:Item="http://ns.google.com/photos/1.0/container/item/">
                  <Container:Directory>
                    <rdf:Seq>
                      <rdf:li rdf:parseType="Resource"
                          Item:Mime="image/jpeg"
                          Item:Semantic="Primary"
                          Item:Length="0"
                          Item:Padding="0"/>
                      $gainMapNode
                      <rdf:li rdf:parseType="Resource"
                          Item:Mime="video/mp4"
                          Item:Semantic="MotionPhoto"
                          Item:Length="$videoLength"
                          Item:Padding="0"/>
                    </rdf:Seq>
                  </Container:Directory>
                </rdf:Description>
                <rdf:Description rdf:about=""
                    xmlns:OpCamera="http://ns.oplus.com/photos/1.0/camera/">
                  <OpCamera:MotionPhotoOwner>oplus</OpCamera:MotionPhotoOwner>
                  <OpCamera:MotionPhotoPrimaryPresentationTimestampUs>$presentationTimestampUs</OpCamera:MotionPhotoPrimaryPresentationTimestampUs>
                  <OpCamera:OLivePhotoVersion>2</OpCamera:OLivePhotoVersion>
                  <OpCamera:VideoLength>$videoLength</OpCamera:VideoLength>
                </rdf:Description>
                $hdrgmNode
              </rdf:RDF>
            </x:xmpmeta>
        """.trimIndent()
    }

    fun packageMotionPhoto(
        imageFile: File,
        videoFile: File,
        outputFile: File,
        presentationTimestampUs: Long,
        metadata: PackagingMetadata = buildPackagingMetadata(imageFile),
    ) {
        val extendedBytes = buildExtendedXmpPayload(metadata)
        val extendedGuid = extendedBytes?.let { md5Hex(it) }
        val gainMapBytes = metadata.gainMapBytes
        val xmpXml = buildMotionPhotoXmp(
            videoLength = videoFile.length(),
            presentationTimestampUs = presentationTimestampUs,
            extendedGuid = extendedGuid,
            gainMapLength = gainMapBytes?.size?.toLong() ?: 0L,
        )
        val jpegBytes = imageFile.readBytes()
        val output = ByteArrayOutputStream(
            jpegBytes.size + videoFile.length().toInt() + (gainMapBytes?.size ?: 0) + 4096,
        )
        output.write(stripAndInjectXmp(jpegBytes, xmpXml, extendedGuid, extendedBytes))
        if (gainMapBytes != null) {
            output.write(gainMapBytes)
        }
        output.write(videoFile.readBytes())
        FileOutputStream(outputFile).use { it.write(output.toByteArray()) }
    }

    fun inspectMotionPhoto(file: File): Inspection {
        val bytes = file.readBytes()
        val xmpPackets = extractApp1XmpPackets(bytes)
        val standardXml = xmpPackets.firstOrNull { !it.extended }?.xml
        val hasExtended = xmpPackets.any { it.extended }
        val jpegEndOffset = findJpegEndOffset(bytes)
        val appendedOffset = findMp4HeaderOffset(bytes, jpegEndOffset) ?: -1L
        val appendedLength = if (appendedOffset >= 0) bytes.size - appendedOffset else -1L
        val itemLength = standardXml?.let { Regex("""Item:Length="(\d+)"""").findAll(it).toList().lastOrNull()?.groupValues?.get(1)?.toLongOrNull() }
        val microVideoOffset = standardXml?.let { Regex("""MicroVideoOffset>(\d+)<|MicroVideoOffset="(\d+)"""").find(it)?.groupValues?.drop(1)?.firstOrNull { g -> g.isNotEmpty() }?.toLongOrNull() }
        return Inspection(
            xmpXml = standardXml,
            appendedVideoOffset = appendedOffset,
            appendedVideoLength = appendedLength,
            itemLength = itemLength,
            microVideoOffset = microVideoOffset,
            hasStandardApp1Xmp = standardXml != null,
            hasExtendedXmp = hasExtended,
            fileNameMatchesOfficialPattern = fileNameRegex.matches(file.name),
        )
    }

    private data class XmpPacket(val xml: String, val extended: Boolean)

    private fun stripAndInjectXmp(
        jpegBytes: ByteArray,
        xmpXml: String,
        extendedGuid: String?,
        extendedBytes: ByteArray?,
    ): ByteArray {
        require(readMarker(jpegBytes, 0) == jpegSoi) { "Input is not a JPEG" }
        val out = ByteArrayOutputStream(jpegBytes.size + 4096)
        out.write(jpegBytes, 0, 2)
        writeApp1Segment(out, standardXmpHeader + xmpXml.toByteArray(UTF_8))
        if (extendedGuid != null && extendedBytes != null) {
            writeExtendedXmpSegments(out, extendedGuid, extendedBytes)
        }

        var offset = 2
        while (offset + 1 < jpegBytes.size) {
            val marker = readMarker(jpegBytes, offset)
            if (marker == jpegSos || marker == jpegEoi) {
                out.write(jpegBytes, offset, jpegBytes.size - offset)
                break
            }
            if (offset + 3 >= jpegBytes.size) {
                out.write(jpegBytes, offset, jpegBytes.size - offset)
                break
            }
            val segmentLength = readUnsignedShort(jpegBytes, offset + 2)
            if (segmentLength < 2 || offset + 2 + segmentLength > jpegBytes.size) {
                out.write(jpegBytes, offset, jpegBytes.size - offset)
                break
            }
            val totalSegmentLength = segmentLength + 2
            val isXmpApp1 = marker == jpegApp1 && isXmpApp1Segment(
                jpegBytes,
                offset + 4,
                segmentLength - 2,
            )
            if (!isXmpApp1) {
                out.write(jpegBytes, offset, totalSegmentLength)
            }
            offset += totalSegmentLength
        }
        return out.toByteArray()
    }

    fun buildPackagingMetadata(imageFile: File): PackagingMetadata {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        try {
            BitmapFactory.decodeFile(imageFile.absolutePath, options)
        } catch (_: RuntimeException) {
            return PackagingMetadata()
        }
        return PackagingMetadata(
            imageWidth = options.outWidth.takeIf { it > 0 },
            imageHeight = options.outHeight.takeIf { it > 0 },
            gainMapBytes = buildGainMapBytes(imageFile),
        )
    }

    private fun buildExtendedXmpPayload(metadata: PackagingMetadata): ByteArray? {
        val width = metadata.imageWidth ?: return null
        val height = metadata.imageHeight ?: return null
        return """
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description rdf:about=""
                    xmlns:exif="http://ns.adobe.com/exif/1.0/">
                  <exif:ImageWidth>$width</exif:ImageWidth>
                  <exif:ImageLength>$height</exif:ImageLength>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
        """.trimIndent().toByteArray(UTF_8)
    }

    private fun buildGainMapBytes(imageFile: File): ByteArray? {
        val bitmap = try {
            BitmapFactory.decodeFile(imageFile.absolutePath) ?: return null
        } catch (_: RuntimeException) {
            return null
        }
        return try {
            val targetWidth = bitmap.width.coerceAtMost(512).coerceAtLeast(1)
            val targetHeight = bitmap.height.coerceAtMost(512).coerceAtLeast(1)
            val scaled = Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true)
            val gainMap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
            for (y in 0 until targetHeight) {
                for (x in 0 until targetWidth) {
                    val color = scaled.getPixel(x, y)
                    val r = (color shr 16) and 0xFF
                    val g = (color shr 8) and 0xFF
                    val b = color and 0xFF
                    val luma = ((r * 77) + (g * 150) + (b * 29)) shr 8
                    val gray = (0xFF shl 24) or (luma shl 16) or (luma shl 8) or luma
                    gainMap.setPixel(x, y, gray)
                }
            }
            ByteArrayOutputStream().use { output ->
                gainMap.compress(Bitmap.CompressFormat.JPEG, 82, output)
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun writeApp1Segment(output: ByteArrayOutputStream, payload: ByteArray) {
        require(payload.size <= maxApp1PayloadSize) { "APP1 payload too large" }
        output.write(0xFF)
        output.write(0xE1)
        writeUnsignedShort(output, payload.size + 2)
        output.write(payload)
    }

    private fun writeExtendedXmpSegments(
        output: ByteArrayOutputStream,
        guid: String,
        extensionBytes: ByteArray,
    ) {
        val fixedHeaderSize = extendedXmpHeader.size + 32 + 4 + 4
        val maxChunkSize = maxApp1PayloadSize - fixedHeaderSize
        var offset = 0
        while (offset < extensionBytes.size) {
            val chunkSize = minOf(maxChunkSize, extensionBytes.size - offset)
            val payload = ByteArrayOutputStream(fixedHeaderSize + chunkSize)
            payload.write(extendedXmpHeader)
            payload.write(guid.toByteArray(UTF_8))
            payload.write(intToBytes(extensionBytes.size))
            payload.write(intToBytes(offset))
            payload.write(extensionBytes, offset, chunkSize)
            writeApp1Segment(output, payload.toByteArray())
            offset += chunkSize
        }
    }

    private fun extractApp1XmpPackets(bytes: ByteArray): List<XmpPacket> {
        val packets = mutableListOf<XmpPacket>()
        if (bytes.size < 4 || readMarker(bytes, 0) != jpegSoi) return packets
        var offset = 2
        while (offset + 1 < bytes.size) {
            val marker = readMarker(bytes, offset)
            if (marker == jpegSos || marker == jpegEoi) break
            if (offset + 3 >= bytes.size) break
            val segmentLength = readUnsignedShort(bytes, offset + 2)
            if (segmentLength < 2 || offset + 2 + segmentLength > bytes.size) break
            val payloadOffset = offset + 4
            val payloadLength = segmentLength - 2
            if (marker == jpegApp1 && payloadLength > 0) {
                when {
                    matchesHeader(bytes, payloadOffset, payloadLength, standardXmpHeader) -> {
                        val xmlStart = payloadOffset + standardXmpHeader.size
                        val xml = bytes.copyOfRange(xmlStart, payloadOffset + payloadLength).toString(UTF_8)
                        packets += XmpPacket(xml, extended = false)
                    }
                    matchesHeader(bytes, payloadOffset, payloadLength, extendedXmpHeader) -> {
                        packets += XmpPacket("", extended = true)
                    }
                }
            }
            offset += segmentLength + 2
        }
        return packets
    }

    private fun isXmpApp1Segment(bytes: ByteArray, offset: Int, length: Int): Boolean {
        return matchesHeader(bytes, offset, length, standardXmpHeader) ||
            matchesHeader(bytes, offset, length, extendedXmpHeader)
    }

    private fun matchesHeader(bytes: ByteArray, offset: Int, length: Int, header: ByteArray): Boolean {
        if (length < header.size || offset + header.size > bytes.size) return false
        for (i in header.indices) {
            if (bytes[offset + i] != header[i]) return false
        }
        return true
    }

    private fun findJpegEndOffset(bytes: ByteArray): Int {
        if (bytes.size < 4 || readMarker(bytes, 0) != jpegSoi) return 0
        for (index in 0 until bytes.size - 1) {
            if (readMarker(bytes, index) == jpegEoi) {
                return index + 2
            }
        }
        return 0
    }

    private fun findMp4HeaderOffset(bytes: ByteArray, start: Int): Long? {
        val safeStart = (start + 4).coerceIn(0, bytes.size)
        for (index in safeStart until bytes.size) {
            for (signature in mp4HeaderSignatures) {
                if (index + signature.size <= bytes.size && matchesAt(bytes, index, signature)) {
                    return (index - 4).toLong().coerceAtLeast(0L)
                }
            }
        }
        return null
    }

    private fun matchesAt(bytes: ByteArray, offset: Int, expected: ByteArray): Boolean {
        for (i in expected.indices) {
            if (bytes[offset + i] != expected[i]) return false
        }
        return true
    }

    private fun readMarker(bytes: ByteArray, offset: Int): Int {
        return readUnsignedShort(bytes, offset)
    }

    private fun readUnsignedShort(bytes: ByteArray, offset: Int): Int {
        return ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)
    }

    private fun writeUnsignedShort(output: ByteArrayOutputStream, value: Int) {
        output.write((value shr 8) and 0xFF)
        output.write(value and 0xFF)
    }

    private fun intToBytes(value: Int): ByteArray {
        return ByteBuffer.allocate(4)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(value)
            .array()
    }

    private fun md5Hex(bytes: ByteArray): String {
        return MessageDigest.getInstance("MD5")
            .digest(bytes)
            .joinToString("") { b -> "%02X".format(Locale.US, b) }
    }
}
