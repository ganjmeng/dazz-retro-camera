#!/usr/bin/env python3
"""
统一所有相机 JSON 的比例顺序为：3:4 → 2:3 → 1:1 → 9:16
（参考效果图从左往右的顺序）
"""
import json
import os

CAMERAS_DIR = "/home/ubuntu/retro_cam_project/flutter_app/assets/cameras"

# 标准比例定义（按照效果图顺序：3:4 2:3 1:1 9:16）
STANDARD_RATIOS = [
    {"id": "ratio_3_4",  "label": "3:4",  "width": 3,  "height": 4,  "supportsFrame": True},
    {"id": "ratio_2_3",  "label": "2:3",  "width": 2,  "height": 3,  "supportsFrame": False},
    {"id": "ratio_1_1",  "label": "1:1",  "width": 1,  "height": 1,  "supportsFrame": True},
    {"id": "ratio_9_16", "label": "9:16", "width": 9,  "height": 16, "supportsFrame": False},
]

for filename in os.listdir(CAMERAS_DIR):
    if not filename.endswith(".json"):
        continue
    filepath = os.path.join(CAMERAS_DIR, filename)
    with open(filepath, "r", encoding="utf-8") as f:
        data = json.load(f)
    
    modules = data.get("modules", {})
    existing_ratios = {r["id"]: r for r in modules.get("ratios", [])}
    
    # 只保留该相机原本支持的比例，但按标准顺序排列
    # 如果相机原来没有某比例，则不添加（保持相机特色）
    # 但所有相机都需要有 3:4（默认比例）
    new_ratios = []
    for std in STANDARD_RATIOS:
        if std["id"] in existing_ratios:
            # 保留原有设置（supportsFrame 可能不同），但按标准顺序
            new_ratios.append(existing_ratios[std["id"]])
        elif std["id"] == "ratio_3_4":
            # 3:4 是默认比例，所有相机都需要有
            new_ratios.append(std)
    
    # 特殊处理 inst_sq（方形相机，只保留 1:1 和 3:4）
    if "inst_sq" in filename:
        new_ratios = [r for r in new_ratios if r["id"] in ("ratio_3_4", "ratio_1_1")]
    
    modules["ratios"] = new_ratios
    data["modules"] = modules
    
    with open(filepath, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    
    labels = [r["label"] for r in new_ratios]
    print(f"{filename}: {labels}")

print("\n✅ 所有相机比例顺序已更新")
