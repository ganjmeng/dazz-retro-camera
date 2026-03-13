#!/usr/bin/env python3
"""
Generate placeholder camera thumbnails (200x200 PNG) for DAZZ.
Each thumbnail visually represents the camera's color grade.
"""

import os
import math
import random
from PIL import Image, ImageDraw, ImageFont, ImageFilter

OUTPUT_DIR = "/home/ubuntu/retro_cam_project/flutter_app/assets/thumbnails"
os.makedirs(OUTPUT_DIR, exist_ok=True)

W, H = 200, 200

def get_font(size=18):
    try:
        return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", size)
    except:
        return ImageFont.load_default()

def draw_scene(draw, w, h, sky_color, ground_color):
    """Draw a simple landscape scene."""
    # Sky
    draw.rectangle([0, 0, w, h * 2 // 3], fill=sky_color)
    # Ground
    draw.rectangle([0, h * 2 // 3, w, h], fill=ground_color)
    # Sun/moon circle
    draw.ellipse([w - 60, 20, w - 20, 60], fill=(255, 255, 200, 200))

def apply_vignette(img, strength=0.4):
    """Apply a vignette overlay."""
    vignette = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(vignette)
    cx, cy = img.width // 2, img.height // 2
    max_r = math.sqrt(cx**2 + cy**2)
    for r in range(int(max_r), 0, -1):
        alpha = int(255 * strength * (r / max_r) ** 2)
        draw.ellipse([cx - r, cy - r, cx + r, cy + r],
                     outline=(0, 0, 0, alpha))
    return Image.alpha_composite(img.convert("RGBA"), vignette)

def make_thumbnail(filename, name, bg_colors, text_color, badge=None, extra_fn=None):
    img = Image.new("RGB", (W, H), bg_colors[0])
    draw = ImageDraw.Draw(img)

    # Gradient background
    for y in range(H):
        t = y / H
        r = int(bg_colors[0][0] * (1 - t) + bg_colors[1][0] * t)
        g = int(bg_colors[0][1] * (1 - t) + bg_colors[1][1] * t)
        b = int(bg_colors[0][2] * (1 - t) + bg_colors[1][2] * t)
        draw.line([(0, y), (W, y)], fill=(r, g, b))

    # Simple scene elements
    if extra_fn:
        extra_fn(draw, W, H)

    # Add grain overlay
    rng = random.Random(hash(filename))
    grain = Image.new("L", (W, H))
    gp = grain.load()
    for yy in range(H):
        for xx in range(W):
            gp[xx, yy] = max(0, min(255, 128 + int(rng.gauss(0, 18))))
    grain_rgba = grain.convert("RGBA")
    grain_rgba.putalpha(30)
    img_rgba = img.convert("RGBA")
    img_rgba = Image.alpha_composite(img_rgba, grain_rgba)

    # Apply vignette
    img_rgba = apply_vignette(img_rgba, 0.35)
    img = img_rgba.convert("RGB")
    draw = ImageDraw.Draw(img)

    # Camera name label
    font_large = get_font(16)
    font_small = get_font(11)
    tr, tg, tb = text_color
    draw.text((10, H - 44), name, fill=(tr, tg, tb, 220), font=font_large)

    # Premium badge
    if badge == "PRO":
        draw.rounded_rectangle([W - 46, 8, W - 8, 28], radius=4, fill=(255, 200, 50))
        draw.text((W - 42, 10), "PRO", fill=(80, 50, 0), font=get_font(12))

    # Category label
    img.save(os.path.join(OUTPUT_DIR, filename))
    size_kb = os.path.getsize(os.path.join(OUTPUT_DIR, filename)) / 1024
    print(f"  ✓ {filename} ({size_kb:.1f}KB)")


def scene_ccd(draw, w, h):
    draw.rectangle([0, 0, w, h * 3 // 5], fill=(100, 130, 180))
    draw.rectangle([0, h * 3 // 5, w, h], fill=(60, 80, 60))
    draw.ellipse([w - 55, 15, w - 15, 55], fill=(220, 230, 255, 180))

def scene_film(draw, w, h):
    draw.rectangle([0, 0, w, h * 2 // 3], fill=(180, 150, 110))
    draw.rectangle([0, h * 2 // 3, w, h], fill=(90, 110, 70))
    draw.ellipse([w - 60, 10, w - 10, 60], fill=(255, 220, 120))

def scene_night(draw, w, h):
    draw.rectangle([0, 0, w, h], fill=(15, 15, 35))
    for i in range(20):
        rng = random.Random(i * 7)
        sx, sy = rng.randint(0, w), rng.randint(0, h // 2)
        draw.ellipse([sx, sy, sx + 2, sy + 2], fill=(255, 255, 255))
    draw.ellipse([w - 50, 10, w - 20, 40], fill=(200, 200, 180))

def scene_flash(draw, w, h):
    draw.rectangle([0, 0, w, h], fill=(240, 235, 225))
    draw.rectangle([0, h * 3 // 4, w, h], fill=(100, 90, 80))
    draw.ellipse([w // 2 - 30, h // 2 - 30, w // 2 + 30, h // 2 + 30],
                 fill=(255, 255, 240))

def scene_polaroid(draw, w, h):
    draw.rectangle([0, 0, w, h * 2 // 3], fill=(160, 190, 220))
    draw.rectangle([0, h * 2 // 3, w, h], fill=(120, 150, 100))
    draw.rectangle([20, 20, w - 20, h - 40], fill=(255, 255, 255, 200))

def scene_vhs(draw, w, h):
    draw.rectangle([0, 0, w, h], fill=(20, 30, 20))
    for y in range(0, h, 4):
        alpha = 40 if y % 8 == 0 else 15
        draw.line([(0, y), (w, y)], fill=(0, 200, 0, alpha))
    draw.text((10, 10), "REC ●", fill=(220, 30, 30), font=get_font(14))

def scene_dv(draw, w, h):
    draw.rectangle([0, 0, w, h], fill=(30, 35, 45))
    draw.rectangle([0, h * 2 // 3, w, h], fill=(50, 60, 40))
    draw.text((8, 8), "SP ●", fill=(200, 200, 50), font=get_font(12))

def scene_portrait(draw, w, h):
    draw.rectangle([0, 0, w, h * 2 // 3], fill=(200, 180, 160))
    draw.rectangle([0, h * 2 // 3, w, h], fill=(150, 130, 110))
    draw.ellipse([w // 2 - 35, h // 4 - 35, w // 2 + 35, h // 4 + 35],
                 fill=(220, 190, 170))

def scene_scan(draw, w, h):
    draw.rectangle([0, 0, w, h], fill=(230, 220, 200))
    for i in range(3):
        x = 20 + i * 55
        draw.rectangle([x, 30, x + 40, h - 30], fill=(180, 160, 130))
    draw.rectangle([0, 0, w, 8], fill=(200, 180, 150))
    draw.rectangle([0, h - 8, w, h], fill=(200, 180, 150))


print("\nGenerating camera thumbnails...")

thumbnails = [
    ("ccd_2005.png",         "CCD-2005",        [(80, 100, 140), (40, 55, 80)],   (220, 230, 255), None,   scene_ccd),
    ("film_gold200.png",     "Gold 200",         [(160, 130, 80), (100, 80, 50)],  (255, 240, 180), None,   scene_film),
    ("fuji_superia.png",     "Superia",          [(80, 130, 100), (50, 90, 70)],   (180, 255, 200), None,   scene_film),
    ("disposable_flash.png", "Disposable",       [(220, 210, 190), (160, 150, 130)], (60, 50, 40),  None,   scene_flash),
    ("polaroid_classic.png", "Polaroid",         [(140, 170, 200), (100, 130, 160)], (255, 255, 255), "PRO", scene_polaroid),
    ("ccd_night.png",        "Night CCD",        [(15, 15, 40), (5, 5, 20)],       (180, 200, 255), "PRO",  scene_night),
    ("vhs_camcorder.png",    "VHS Cam",          [(20, 30, 20), (10, 15, 10)],     (0, 200, 0),     "PRO",  scene_vhs),
    ("dv2003.png",           "DV-2003",          [(30, 35, 50), (15, 20, 30)],     (200, 210, 230), None,   scene_dv),
    ("portrait_soft.png",    "Soft Portrait",    [(190, 170, 150), (140, 120, 100)], (255, 240, 220), None, scene_portrait),
    ("film_scan.png",        "Film Scan",        [(210, 200, 180), (170, 160, 140)], (80, 70, 60),  None,   scene_scan),
]

for fname, name, colors, tc, badge, scene_fn in thumbnails:
    make_thumbnail(fname, name, colors, tc, badge, scene_fn)

print(f"\n✅ All {len(thumbnails)} thumbnails generated.")
