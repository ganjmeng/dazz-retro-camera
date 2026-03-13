## 10 个生产级 DAZZ 风格相机预设 (V3 真实结构)

以下 10 个相机配置完全基于您提供的“真实产品逻辑”，并结合 V3 宽松的 JSON Schema 规范进行整理。

### 1. CCD-2005（经典CCD数码相机）
```json
{
  "id": "ccd_2005",
  "name": "CCD-2005",
  "category": "digital_ccd",
  "outputType": "photo",
  "baseModel": {
    "sensor": {
      "type": "ccd",
      "dynamic_range": 7.0,
      "noise": 0.32
    },
    "color": {
      "contrast": 1.1,
      "saturation": 1.1
    }
  },
  "optionGroups": {
    "films": [
      {
        "id": "ccd_default",
        "name": "Standard CCD",
        "isDefault": true,
        "rendering": {
          "lut": "ccd_standard.cube",
          "grain": 0.25
        }
      },
      {
        "id": "ccd_cool",
        "name": "Cool CCD",
        "rendering": {
          "lut": "ccd_cool.cube",
          "grain": 0.28
        }
      }
    ],
    "ratios": [
      { "id": "ratio_4_3", "value": "4:3", "isDefault": true },
      { "id": "ratio_1_1", "value": "1:1" }
    ],
    "watermarks": [
      {
        "id": "ccd_date",
        "name": "Date Stamp",
        "type": "digital_date",
        "position": "bottom_right",
        "isDefault": true
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": true,
    "showWatermarkSelector": true
  }
}
```

### 2. Kodak Gold 200（胶片相机）
```json
{
  "id": "film_gold200",
  "name": "Gold 200",
  "category": "film",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "film_scan" },
    "color": { "contrast": 1.05 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "gold200",
        "name": "Gold 200",
        "isDefault": true,
        "rendering": { "lut": "kodak_gold.cube", "grain": 0.25 }
      },
      {
        "id": "gold_warm",
        "name": "Warm Gold",
        "rendering": { "lut": "gold_warm.cube", "grain": 0.22 }
      }
    ],
    "ratios": [
      { "id": "ratio_3_2", "value": "3:2", "isDefault": true },
      { "id": "ratio_1_1", "value": "1:1" }
    ],
    "watermarks": [
      {
        "id": "film_corner_mark",
        "name": "Film Mark",
        "type": "camera_name",
        "text": "GOLD200",
        "position": "bottom_left"
      }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": true,
    "showWatermarkSelector": true
  }
}
```

### 3. Fuji Superia
```json
{
  "id": "fuji_superia",
  "name": "Superia",
  "category": "film",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "film_scan" },
    "color": { "saturation": 1.08 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "superia_green",
        "name": "Superia",
        "isDefault": true,
        "rendering": { "lut": "superia.cube", "grain": 0.22 }
      },
      {
        "id": "superia_soft",
        "name": "Soft Superia",
        "rendering": { "lut": "superia_soft.cube", "grain": 0.20 }
      }
    ],
    "ratios": [
      { "id": "ratio_3_2", "value": "3:2", "isDefault": true }
    ],
    "watermarks": [
      { "id": "none", "name": "None", "type": "none", "isDefault": true }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": true,
    "showWatermarkSelector": false
  }
}
```

### 4. Disposable Flash（一次性相机）
```json
{
  "id": "disposable_flash",
  "name": "Disposable Flash",
  "category": "disposable",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "film_scan" },
    "lens": { "vignette": 0.35 }
  },
  "optionGroups": {
    "films": [
      {
        "id": "disposable_color",
        "name": "Color Flash",
        "isDefault": true,
        "rendering": { "lut": "disposable.cube", "grain": 0.30 }
      }
    ],
    "ratios": [
      { "id": "ratio_3_2", "value": "3:2", "isDefault": true }
    ],
    "watermarks": [
      { "id": "date_red", "name": "Red Date", "type": "digital_date", "color": "red", "isDefault": true }
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

### 5. Polaroid Classic（拍立得）
```json
{
  "id": "polaroid_classic",
  "name": "Polaroid Classic",
  "category": "instant",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "instant" },
    "color": { "contrast": 0.9 }
  },
  "optionGroups": {
    "films": [
      { "id": "polaroid_default", "name": "Classic", "isDefault": true }
    ],
    "lenses": [
      { "id": "soft_lens", "name": "Soft Lens", "bloom": 0.15, "isDefault": true },
      { "id": "wide_lens", "name": "Wide Lens", "vignette": 0.18 }
    ],
    "papers": [
      { "id": "white_border", "name": "White Paper", "isDefault": true },
      { "id": "cream_border", "name": "Cream Paper" }
    ],
    "ratios": [
      { "id": "ratio_1_1", "value": "1:1", "isDefault": true }
    ],
    "watermarks": [
      { "id": "instant_footer", "name": "Footer Mark", "type": "frame_text", "text": "POLAROID", "isDefault": true }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": true,
    "showPaperSelector": true,
    "showRatioSelector": false,
    "showWatermarkSelector": true
  }
}
```

### 6. Night CCD
```json
{
  "id": "ccd_night",
  "name": "Night CCD",
  "category": "digital_ccd",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "ccd", "noise": 0.40 }
  },
  "optionGroups": {
    "films": [
      { "id": "night_blue", "name": "Night Blue", "isDefault": true }
    ],
    "ratios": [
      { "id": "ratio_4_3", "value": "4:3", "isDefault": true }
    ],
    "watermarks": [
      { "id": "night_date", "name": "Date Stamp", "type": "digital_date", "isDefault": true }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
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
  "id": "vhs_cam",
  "name": "VHS Camcorder",
  "category": "video",
  "outputType": "video",
  "baseModel": {
    "scan": { "scanlines": 0.18 }
  },
  "optionGroups": {
    "ratios": [
      { "id": "ratio_4_3", "value": "4:3", "isDefault": true }
    ],
    "watermarks": [
      {
        "id": "rec_overlay",
        "name": "REC Marker",
        "type": "video_rec",
        "text": "REC",
        "isDefault": true
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

### 8. MiniDV 2003
```json
{
  "id": "dv2003",
  "name": "DV-2003",
  "category": "video",
  "outputType": "video",
  "baseModel": {
    "noise": { "luminance": 0.25 }
  },
  "optionGroups": {
    "ratios": [
      { "id": "ratio_4_3", "value": "4:3", "isDefault": true }
    ],
    "watermarks": [
      { "id": "dv_date", "name": "Date Stamp", "type": "digital_date", "isDefault": true }
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

### 9. Portrait Soft Film
```json
{
  "id": "portrait_soft",
  "name": "Soft Portrait",
  "category": "film",
  "outputType": "photo",
  "baseModel": {
    "color": { "contrast": 0.95 }
  },
  "optionGroups": {
    "films": [
      { "id": "portra", "name": "Portra", "isDefault": true }
    ],
    "lenses": [
      { "id": "soft_focus", "name": "Soft Focus", "bloom": 0.12, "isDefault": true }
    ],
    "ratios": [
      { "id": "ratio_3_2", "value": "3:2", "isDefault": true }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": true,
    "showPaperSelector": false,
    "showRatioSelector": true,
    "showWatermarkSelector": false
  }
}
```

### 10. Film Scanner
```json
{
  "id": "film_scan",
  "name": "Film Scan",
  "category": "scanner",
  "outputType": "photo",
  "baseModel": {
    "sensor": { "type": "scanner" }
  },
  "optionGroups": {
    "films": [
      { "id": "scan_clean", "name": "Clean Scan", "isDefault": true },
      { "id": "scan_dust", "name": "Dusty Scan" }
    ],
    "ratios": [
      { "id": "ratio_3_2", "value": "3:2", "isDefault": true }
    ]
  },
  "uiCapabilities": {
    "showFilmSelector": true,
    "showLensSelector": false,
    "showPaperSelector": false,
    "showRatioSelector": true,
    "showWatermarkSelector": false
  }
}
```
