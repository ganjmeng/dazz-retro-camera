#!/usr/bin/env python3
"""
Generate placeholder PNG assets for DAZZ development:
- Grain textures (grain_fine.png, grain_coarse.png)
- Frame overlays (polaroid_white_frame.png, polaroid_cream_frame.png)
- Watermark assets (date_stamp_orange.png, camera_name_mark.png, rec_overlay.png)
"""

import os
import random
import math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

BASE = "/home/ubuntu/retro_cam_project/flutter_app/assets"

# ─── Grain Textures ──────────────────────────────────────────────────────────

def generate_grain(path, size=512, intensity=0.15, coarse=False):
    """Generate a tileable grain texture as a grayscale PNG."""
    img = Image.new("L", (size, size), 128)
    pixels = img.load()
    rng = random.Random(42 if not coarse else 99)

    for y in range(size):
        for x in range(size):
            if coarse:
                # Larger grain clusters
                noise = rng.gauss(0, intensity * 255 * 1.8)
                # Add occasional bright specks
                if rng.random() < 0.003:
                    noise += rng.uniform(30, 80)
            else:
                noise = rng.gauss(0, intensity * 255)
            pixels[x, y] = max(0, min(255, int(128 + noise)))

    if coarse:
        img = img.filter(ImageFilter.GaussianBlur(radius=0.8))
    else:
        img = img.filter(ImageFilter.GaussianBlur(radius=0.3))

    img.save(path)
    size_kb = os.path.getsize(path) / 1024
    print(f"  ✓ {os.path.basename(path)} ({size}x{size}px, {size_kb:.1f}KB)")


# ─── Polaroid Frame Overlays ─────────────────────────────────────────────────

def generate_polaroid_frame(path, bg_color, label_color, label_text="POLAROID"):
    """
    Generate a Polaroid-style frame overlay (RGBA PNG).
    The frame has thick bottom border and thin top/side borders.
    The inner area is transparent so the photo shows through.
    """
    W, H = 1080, 1080
    # Polaroid proportions: thin border top/sides, thick border bottom
    border_side = 60
    border_top = 60
    border_bottom = 220

    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Draw frame background (white/cream)
    r, g, b = bg_color
    # Top border
    draw.rectangle([0, 0, W, border_top], fill=(r, g, b, 255))
    # Bottom border
    draw.rectangle([0, H - border_bottom, W, H], fill=(r, g, b, 255))
    # Left border
    draw.rectangle([0, border_top, border_side, H - border_bottom], fill=(r, g, b, 255))
    # Right border
    draw.rectangle([W - border_side, border_top, W, H - border_bottom], fill=(r, g, b, 255))

    # Add subtle label text at bottom
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 36)
    except:
        font = ImageFont.load_default()

    lr, lg, lb = label_color
    text_bbox = draw.textbbox((0, 0), label_text, font=font)
    text_w = text_bbox[2] - text_bbox[0]
    text_x = (W - text_w) // 2
    text_y = H - border_bottom + (border_bottom - 50) // 2
    draw.text((text_x, text_y), label_text, fill=(lr, lg, lb, 180), font=font)

    img.save(path)
    size_kb = os.path.getsize(path) / 1024
    print(f"  ✓ {os.path.basename(path)} ({W}x{H}px RGBA, {size_kb:.1f}KB)")


# ─── Watermark Assets ─────────────────────────────────────────────────────────

def generate_date_stamp(path):
    """Generate an orange date stamp watermark (RGBA PNG)."""
    W, H = 320, 60
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 32)
    except:
        font = ImageFont.load_default()

    # Orange date text
    date_text = "2005 03 13"
    draw.text((8, 8), date_text, fill=(255, 140, 0, 220), font=font)

    img.save(path)
    size_kb = os.path.getsize(path) / 1024
    print(f"  ✓ {os.path.basename(path)} ({W}x{H}px RGBA, {size_kb:.1f}KB)")


def generate_camera_name_mark(path):
    """Generate a camera name watermark (RGBA PNG)."""
    W, H = 280, 50
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 26)
    except:
        font = ImageFont.load_default()

    draw.text((6, 8), "GOLD200", fill=(255, 255, 255, 200), font=font)

    img.save(path)
    size_kb = os.path.getsize(path) / 1024
    print(f"  ✓ {os.path.basename(path)} ({W}x{H}px RGBA, {size_kb:.1f}KB)")


def generate_rec_overlay(path):
    """Generate a VHS-style REC overlay (RGBA PNG)."""
    W, H = 200, 60
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 28)
    except:
        font = ImageFont.load_default()

    # Red circle indicator
    draw.ellipse([8, 14, 36, 42], fill=(220, 30, 30, 240))
    # REC text
    draw.text((46, 10), "REC", fill=(220, 30, 30, 240), font=font)

    img.save(path)
    size_kb = os.path.getsize(path) / 1024
    print(f"  ✓ {os.path.basename(path)} ({W}x{H}px RGBA, {size_kb:.1f}KB)")


# ─── Run All ──────────────────────────────────────────────────────────────────

print("\nGenerating grain textures...")
generate_grain(f"{BASE}/grain/grain_fine.png",   size=512, intensity=0.12, coarse=False)
generate_grain(f"{BASE}/grain/grain_coarse.png", size=512, intensity=0.22, coarse=True)

print("\nGenerating frame overlays...")
generate_polaroid_frame(
    f"{BASE}/frames/polaroid_white_frame.png",
    bg_color=(252, 252, 252),
    label_color=(100, 100, 100),
    label_text="POLAROID"
)
generate_polaroid_frame(
    f"{BASE}/frames/polaroid_cream_frame.png",
    bg_color=(245, 238, 220),
    label_color=(120, 105, 80),
    label_text="POLAROID"
)

print("\nGenerating watermark assets...")
generate_date_stamp(f"{BASE}/watermarks/date_stamp_orange.png")
generate_camera_name_mark(f"{BASE}/watermarks/camera_name_mark.png")
generate_rec_overlay(f"{BASE}/watermarks/rec_overlay.png")

print("\n✅ All PNG assets generated successfully.")
