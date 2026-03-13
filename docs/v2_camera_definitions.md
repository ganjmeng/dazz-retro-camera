## 10 个生产级相机定义示例

### 1. CCD Digital Camera
```json
{
  "id": "ccd_digital_01",
  "name": "D Classic",
  "category": "ccd",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "ccd-sim", "iso": 200, "dynamicRange": 8.5 },
    "color": { "lut": "ccd_base.cube", "temperature": 5200, "tint": 0 },
    "optical": { "focalLength": 28, "aperture": 2.8 }
  },
  "optionGroups": {
    "ratios": [
      { "id": "ratio_4_3", "name": "4:3", "isDefault": true, "value": "4:3" },
      { "id": "ratio_16_9", "name": "16:9", "isDefault": false, "value": "16:9" }
    ],
    "watermarks": [
      {
        "id": "ccd_date_mark",
        "name": "Date Stamp",
        "isDefault": true,
        "type": "ccd_date",
        "rendering": {
          "textFormat": "yyyy MM dd",
          "font": "digital-7",
          "color": "#FFFFA500",
          "position": "bottom_right",
          "opacity": 0.9,
          "frameIntegration": true
        }
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": false,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": true,
    "showWatermarkSelector": true
  }
}
```

### 2. Kodak Film Camera
```json
{
  "id": "film_kodak_01",
  "name": "K-Film 400",
  "category": "film",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "film-sim", "iso": 400, "dynamicRange": 11.0 },
    "color": { "lut": "kodak_base.cube", "temperature": 5500, "tint": 10 },
    "optical": { "focalLength": 35, "aperture": 2.0 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "kodak_gold_400",
        "name": "Gold 400",
        "isDefault": true,
        "rendering": { "lut": "kodak_gold.cube", "grainIntensity": 0.4, "colorScience": "warm", "highlightBehavior": 0.8, "toneCurve": "s-curve" }
      },
      {
        "id": "kodak_portra_400",
        "name": "Portra 400",
        "isDefault": false,
        "rendering": { "lut": "kodak_portra.cube", "grainIntensity": 0.2, "colorScience": "neutral", "highlightBehavior": 0.9, "toneCurve": "linear" }
      }
    ],
    "lenses": [
      {
        "id": "lens_35mm_f2",
        "name": "35mm f/2",
        "isDefault": true,
        "rendering": { "vignette": 0.3, "distortion": 0.05, "chromaticAberration": 0.01, "bloom": 0.2, "flare": "mild" }
      }
    ],
    "ratios": [
      { "id": "ratio_3_2", "name": "3:2", "isDefault": true, "value": "3:2" }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": true,
    "showPaperSelector": false,
    "showRatioSelector": false,
    "showWatermarkSelector": false
  }
}
```

### 3. Fuji Film Camera
```json
{
  "id": "film_fuji_01",
  "name": "F-Film 400H",
  "category": "film",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "film-sim", "iso": 400, "dynamicRange": 10.5 },
    "color": { "lut": "fuji_base.cube", "temperature": 4800, "tint": -15 },
    "optical": { "focalLength": 50, "aperture": 1.8 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "fuji_pro_400h",
        "name": "Pro 400H",
        "isDefault": true,
        "rendering": { "lut": "fuji_pro.cube", "grainIntensity": 0.3, "colorScience": "cool_green", "highlightBehavior": 0.85, "toneCurve": "s-curve" }
      },
      {
        "id": "fuji_superia_400",
        "name": "Superia 400",
        "isDefault": false,
        "rendering": { "lut": "fuji_superia.cube", "grainIntensity": 0.45, "colorScience": "vivid", "highlightBehavior": 0.7, "toneCurve": "contrasty" }
      }
    ],
    "lenses": [
      {
        "id": "lens_50mm_f18",
        "name": "50mm f/1.8",
        "isDefault": true,
        "rendering": { "vignette": 0.2, "distortion": 0.02, "chromaticAberration": 0.015, "bloom": 0.25, "flare": "moderate" }
      }
    ],
    "ratios": [
      { "id": "ratio_3_2", "name": "3:2", "isDefault": true, "value": "3:2" }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": true,
    "showPaperSelector": false,
    "showRatioSelector": false,
    "showWatermarkSelector": false
  }
}
```

### 4. Disposable Camera
```json
{
  "id": "disposable_01",
  "name": "FunSaver",
  "category": "disposable",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "film-sim", "iso": 800, "dynamicRange": 8.0 },
    "color": { "lut": "disposable_base.cube", "temperature": 5000, "tint": 5 },
    "optical": { "focalLength": 30, "aperture": 10.0 }
  },
  "optionGroups": {
    "lenses": [
      {
        "id": "plastic_lens",
        "name": "Plastic Lens",
        "isDefault": true,
        "rendering": { "vignette": 0.6, "distortion": 0.15, "chromaticAberration": 0.05, "bloom": 0.4, "flare": "strong" }
      }
    ],
    "ratios": [
      { "id": "ratio_3_2", "name": "3:2", "isDefault": true, "value": "3:2" }
    ],
    "watermarks": [
      {
        "id": "disposable_date",
        "name": "Date Stamp",
        "isDefault": true,
        "type": "ccd_date",
        "rendering": {
          "textFormat": "'98 MM dd",
          "font": "digital-7",
          "color": "#FFFF0000",
          "position": "bottom_right",
          "opacity": 0.8,
          "frameIntegration": true
        }
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": false,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": false,
    "showWatermarkSelector": true
  }
}
```

### 5. Polaroid Instant Camera
```json
{
  "id": "instant_polaroid_01",
  "name": "Polaroid SX-70",
  "category": "instant",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "instant-sim", "iso": 160, "dynamicRange": 7.5 },
    "color": { "lut": "polaroid_base.cube", "temperature": 4500, "tint": 20 },
    "optical": { "focalLength": 116, "aperture": 8.0 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "sx70_color",
        "name": "Color Film",
        "isDefault": true,
        "rendering": { "lut": "sx70_color.cube", "grainIntensity": 0.15, "colorScience": "warm_fade", "highlightBehavior": 0.5, "toneCurve": "flat" }
      },
      {
        "id": "sx70_bw",
        "name": "B&W Film",
        "isDefault": false,
        "rendering": { "lut": "sx70_bw.cube", "grainIntensity": 0.25, "colorScience": "monochrome", "highlightBehavior": 0.6, "toneCurve": "contrasty" }
      }
    ],
    "papers": [
      {
        "id": "polaroid_white",
        "name": "Classic White",
        "isDefault": true,
        "rendering": { "frameBorder": "polaroid_white_border", "paperTexture": "polaroid_texture", "paperColor": "#FFFFFA" }
      },
      {
        "id": "polaroid_black",
        "name": "Matte Black",
        "isDefault": false,
        "rendering": { "frameBorder": "polaroid_black_border", "paperTexture": "polaroid_texture", "paperColor": "#111111" }
      }
    ],
    "ratios": [
      { "id": "ratio_1_1", "name": "1:1", "isDefault": true, "value": "1:1" }
    ],
    "watermarks": [
      {
        "id": "polaroid_text",
        "name": "Bottom Text",
        "isDefault": true,
        "type": "polaroid_text",
        "rendering": {
          "textFormat": "PRINT-24",
          "font": "handwriting",
          "color": "#333333",
          "position": "frame_bottom",
          "opacity": 0.85,
          "frameIntegration": false
        }
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": false,
    "showPaperSelector": true,
    "showRatioSelector": false,
    "showWatermarkSelector": true
  }
}
```

### 6. Night CCD Camera
```json
{
  "id": "ccd_night_01",
  "name": "Night Vision",
  "category": "ccd",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "ccd-sim", "iso": 3200, "dynamicRange": 6.0 },
    "color": { "lut": "ccd_night.cube", "temperature": 3200, "tint": 30 },
    "optical": { "focalLength": 24, "aperture": 1.4 }
  },
  "optionGroups": {
    "ratios": [
      { "id": "ratio_4_3", "name": "4:3", "isDefault": true, "value": "4:3" },
      { "id": "ratio_16_9", "name": "16:9", "isDefault": false, "value": "16:9" }
    ],
    "watermarks": [
      {
        "id": "ccd_date_mark",
        "name": "Date Stamp",
        "isDefault": true,
        "type": "ccd_date",
        "rendering": {
          "textFormat": "yyyy MM dd",
          "font": "digital-7",
          "color": "#FF00FF00",
          "position": "bottom_right",
          "opacity": 0.9,
          "frameIntegration": true
        }
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": false,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": true,
    "showWatermarkSelector": true
  }
}
```

### 7. VHS Camcorder
```json
{
  "id": "camcorder_vhs_01",
  "name": "VHS Classic",
  "category": "camcorder",
  "outputType": "video",
  "baseModel": {
    "sensor": { "type": "vhs-sim", "iso": 400, "dynamicRange": 6.5 },
    "color": { "lut": "vhs_base.cube", "temperature": 4000, "tint": -5 },
    "optical": { "focalLength": 35, "aperture": 4.0 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "vhs_sp",
        "name": "SP Mode",
        "isDefault": true,
        "rendering": { "lut": "vhs_sp.cube", "grainIntensity": 0.5, "colorScience": "vhs_color", "highlightBehavior": 0.4, "toneCurve": "flat" }
      },
      {
        "id": "vhs_ep",
        "name": "EP Mode",
        "isDefault": false,
        "rendering": { "lut": "vhs_ep.cube", "grainIntensity": 0.8, "colorScience": "vhs_color_degraded", "highlightBehavior": 0.3, "toneCurve": "flat" }
      }
    ],
    "ratios": [
      { "id": "ratio_4_3", "name": "4:3", "isDefault": true, "value": "4:3" }
    ],
    "watermarks": [
      {
        "id": "vhs_rec_info",
        "name": "REC Info",
        "isDefault": true,
        "type": "rec_info",
        "rendering": {
          "textFormat": "REC • 00:00:00",
          "font": "vcr_osd",
          "color": "#FFFFFF",
          "position": "top_left",
          "opacity": 0.9,
          "frameIntegration": true
        }
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": false,
    "showWatermarkSelector": true
  }
}
```

### 8. MiniDV Camcorder
```json
{
  "id": "camcorder_minidv_01",
  "name": "MiniDV Pro",
  "category": "camcorder",
  "outputType": "video",
  "baseModel": {
    "sensor": { "type": "minidv-sim", "iso": 800, "dynamicRange": 8.0 },
    "color": { "lut": "minidv_base.cube", "temperature": 5500, "tint": 0 },
    "optical": { "focalLength": 28, "aperture": 2.8 }
  },
  "optionGroups": {
    "ratios": [
      { "id": "ratio_16_9", "name": "16:9", "isDefault": true, "value": "16:9" },
      { "id": "ratio_4_3", "name": "4:3", "isDefault": false, "value": "4:3" }
    ],
    "watermarks": [
      {
        "id": "minidv_rec_info",
        "name": "DV Info",
        "isDefault": true,
        "type": "rec_info",
        "rendering": {
          "textFormat": "REC 00:00:00 SP",
          "font": "camcorder_font",
          "color": "#FFFFFF",
          "position": "top_right",
          "opacity": 0.8,
          "frameIntegration": true
        }
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": false,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": true,
    "showWatermarkSelector": true
  }
}
```

### 9. Soft Portrait Film Camera
```json
{
  "id": "film_portrait_01",
  "name": "Soft Portrait",
  "category": "film",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "film-sim", "iso": 100, "dynamicRange": 12.0 },
    "color": { "lut": "portrait_base.cube", "temperature": 5000, "tint": 5 },
    "optical": { "focalLength": 85, "aperture": 1.4 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "portrait_pro_160",
        "name": "Pro 160",
        "isDefault": true,
        "rendering": { "lut": "portrait_160.cube", "grainIntensity": 0.1, "colorScience": "skin_tones", "highlightBehavior": 0.95, "toneCurve": "soft" }
      }
    ],
    "lenses": [
      {
        "id": "lens_85mm_soft",
        "name": "85mm Soft Focus",
        "isDefault": true,
        "rendering": { "vignette": 0.1, "distortion": 0.01, "chromaticAberration": 0.005, "bloom": 0.3, "flare": "none" }
      }
    ],
    "ratios": [
      { "id": "ratio_3_2", "name": "3:2", "isDefault": true, "value": "3:2" }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": true,
    "showPaperSelector": false,
    "showRatioSelector": false,
    "showWatermarkSelector": false
  }
}
```

### 10. Film Scanner Camera
```json
{
  "id": "scanner_film_01",
  "name": "Negative Scanner",
  "category": "scanner",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "scanner-sim", "iso": 100, "dynamicRange": 14.0 },
    "color": { "lut": "scanner_base.cube", "temperature": 5500, "tint": 0 },
    "optical": { "focalLength": 50, "aperture": 8.0 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "scan_kodak_colorplus",
        "name": "ColorPlus 200",
        "isDefault": true,
        "rendering": { "lut": "scan_colorplus.cube", "grainIntensity": 0.3, "colorScience": "warm", "highlightBehavior": 0.8, "toneCurve": "linear" }
      },
      {
        "id": "scan_ilford_hp5",
        "name": "HP5 Plus",
        "isDefault": false,
        "rendering": { "lut": "scan_hp5.cube", "grainIntensity": 0.5, "colorScience": "monochrome", "highlightBehavior": 0.9, "toneCurve": "s-curve" }
      }
    ],
    "ratios": [
      { "id": "ratio_3_2", "name": "3:2", "isDefault": true, "value": "3:2" }
    ],
    "watermarks": [
      {
        "id": "scanner_film_border",
        "name": "Film Border",
        "isDefault": true,
        "type": "brand_logo",
        "rendering": {
          "textFormat": "KODAK SAFETY FILM",
          "font": "helvetica",
          "color": "#FF8800",
          "position": "frame_border",
          "opacity": 0.9,
          "frameIntegration": false
        }
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": false,
    "showWatermarkSelector": true
  }
}
```
