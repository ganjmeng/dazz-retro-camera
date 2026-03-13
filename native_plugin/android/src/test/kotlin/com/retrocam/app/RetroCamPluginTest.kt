package com.retrocam.app

import com.retrocam.app.models.Preset
import org.junit.Assert.*
import org.junit.Test

class RetroCamPluginTest {

    @Test
    fun testPresetParsing() {
        val map = mapOf(
            "id" to "test_cam",
            "name" to "Test Cam",
            "category" to "ccd",
            "outputType" to "photo",
            "baseModel" to mapOf(
                "sensor" to mapOf("type" to "ccd-2005")
            )
        )

        val preset = Preset.fromMap(map)
        
        assertEquals("test_cam", preset.id)
        assertEquals("ccd", preset.category)
        
        val sensor = preset.baseModel["sensor"] as? Map<*, *>
        assertEquals("ccd-2005", sensor?.get("type"))
    }
}
