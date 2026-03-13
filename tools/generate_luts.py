#!/usr/bin/env python3
"""
Generate placeholder LUT .cube files for development.
Each LUT is a 33x33x33 3D LUT with a specific color grade applied.
Format: Adobe/Resolve .cube standard
"""

import os
import math

OUTPUT_DIR = "/home/ubuntu/retro_cam_project/flutter_app/assets/lut"
os.makedirs(OUTPUT_DIR, exist_ok=True)

LUT_SIZE = 33  # 33x33x33 is standard for real-time use

def clamp(v, lo=0.0, hi=1.0):
    return max(lo, min(hi, v))

def write_cube(filename, title, transform_fn):
    """Write a .cube LUT file with the given color transform."""
    path = os.path.join(OUTPUT_DIR, filename)
    lines = []
    lines.append(f"TITLE \"{title}\"")
    lines.append(f"# Generated placeholder LUT for DAZZ development")
    lines.append(f"# Replace with production-grade LUT before release")
    lines.append(f"LUT_3D_SIZE {LUT_SIZE}")
    lines.append(f"DOMAIN_MIN 0.0 0.0 0.0")
    lines.append(f"DOMAIN_MAX 1.0 1.0 1.0")
    lines.append("")

    for b in range(LUT_SIZE):
        for g in range(LUT_SIZE):
            for r in range(LUT_SIZE):
                ri = r / (LUT_SIZE - 1)
                gi = g / (LUT_SIZE - 1)
                bi = b / (LUT_SIZE - 1)
                ro, go, bo = transform_fn(ri, gi, bi)
                lines.append(f"{clamp(ro):.6f} {clamp(go):.6f} {clamp(bo):.6f}")

    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f"  ✓ {filename} ({LUT_SIZE}^3 = {LUT_SIZE**3} entries)")


# ─── LUT Definitions ──────────────────────────────────────────────────────────

def lut_ccd_standard(r, g, b):
    """CCD Standard: slight warm shift, boosted contrast, reduced saturation"""
    # Contrast S-curve (mild)
    r = 0.5 + (r - 0.5) * 1.10
    g = 0.5 + (g - 0.5) * 1.10
    b = 0.5 + (b - 0.5) * 1.10
    # Warm shift: boost red/green slightly, reduce blue
    r = r * 1.04
    g = g * 1.01
    b = b * 0.94
    # Desaturate slightly (mix toward luma)
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    r = luma + (r - luma) * 0.88
    g = luma + (g - luma) * 0.88
    b = luma + (b - luma) * 0.88
    return r, g, b


def lut_kodak_gold(r, g, b):
    """Kodak Gold 200: warm golden tones, lifted shadows, rich midtones"""
    # Lift shadows
    r = r * 0.92 + 0.06
    g = g * 0.92 + 0.05
    b = b * 0.90 + 0.04
    # Warm golden push
    r = r * 1.08
    g = g * 1.04
    b = b * 0.88
    # Slight contrast
    r = 0.5 + (r - 0.5) * 1.05
    g = 0.5 + (g - 0.5) * 1.05
    b = 0.5 + (b - 0.5) * 1.05
    return r, g, b


def lut_superia(r, g, b):
    """Fuji Superia: cool-green tones, punchy saturation"""
    # Cool-green push
    r = r * 0.94
    g = g * 1.06
    b = b * 1.02
    # Boost saturation
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    r = luma + (r - luma) * 1.12
    g = luma + (g - luma) * 1.12
    b = luma + (b - luma) * 1.12
    # Slight contrast
    r = 0.5 + (r - 0.5) * 1.08
    g = 0.5 + (g - 0.5) * 1.08
    b = 0.5 + (b - 0.5) * 1.08
    return r, g, b


def lut_disposable_flash(r, g, b):
    """Disposable Flash: overexposed highlights, warm flash, heavy grain feel"""
    # Overexpose highlights
    r = r * 1.12 + 0.02
    g = g * 1.10 + 0.02
    b = b * 1.05 + 0.01
    # Warm flash
    r = r * 1.06
    g = g * 1.02
    b = b * 0.92
    # Slight green cast in shadows
    if g < 0.3:
        g = g * 1.04
    return r, g, b


def lut_instant_polaroid(r, g, b):
    """Polaroid Instant: faded, low contrast, slight blue-green cast"""
    # Fade (compress range)
    r = r * 0.80 + 0.08
    g = g * 0.80 + 0.09
    b = b * 0.82 + 0.10
    # Blue-green cast
    r = r * 0.96
    g = g * 1.02
    b = b * 1.05
    # Reduce saturation
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    r = luma + (r - luma) * 0.82
    g = luma + (g - luma) * 0.82
    b = luma + (b - luma) * 0.82
    return r, g, b


def lut_soft_portrait(r, g, b):
    """Soft Portrait: warm skin tones, lifted shadows, low contrast"""
    # Lift shadows gently
    r = r * 0.88 + 0.07
    g = g * 0.88 + 0.06
    b = b * 0.88 + 0.05
    # Warm skin push
    r = r * 1.06
    g = g * 1.02
    b = b * 0.96
    # Low contrast
    r = 0.5 + (r - 0.5) * 0.95
    g = 0.5 + (g - 0.5) * 0.95
    b = 0.5 + (b - 0.5) * 0.95
    return r, g, b


def lut_film_scan(r, g, b):
    """Film Scan: neutral with slight orange-teal split tone"""
    # Slight orange in shadows, teal in highlights
    shadow_strength = max(0.0, 1.0 - r * 3.0)
    highlight_strength = max(0.0, r * 3.0 - 2.0)
    r = r + shadow_strength * 0.04 + highlight_strength * (-0.02)
    g = g + shadow_strength * 0.01 + highlight_strength * 0.02
    b = b + shadow_strength * (-0.03) + highlight_strength * 0.04
    # Slight desaturation
    luma = 0.299 * r + 0.587 * g + 0.114 * b
    r = luma + (r - luma) * 0.92
    g = luma + (g - luma) * 0.92
    b = luma + (b - luma) * 0.92
    return r, g, b


# ─── Generate All LUTs ────────────────────────────────────────────────────────

print(f"\nGenerating {LUT_SIZE}x{LUT_SIZE}x{LUT_SIZE} placeholder LUT files...")
print(f"Output: {OUTPUT_DIR}\n")

luts = [
    ("ccd_standard.cube",     "CCD Standard",      lut_ccd_standard),
    ("kodak_gold.cube",       "Kodak Gold 200",     lut_kodak_gold),
    ("superia.cube",          "Fuji Superia",       lut_superia),
    ("disposable_flash.cube", "Disposable Flash",   lut_disposable_flash),
    ("instant_polaroid.cube", "Instant Polaroid",   lut_instant_polaroid),
    ("soft_portrait.cube",    "Soft Portrait",      lut_soft_portrait),
    ("film_scan.cube",        "Film Scan",          lut_film_scan),
]

for filename, title, fn in luts:
    write_cube(filename, title, fn)

print(f"\n✅ All {len(luts)} LUT files generated successfully.")
print(f"   Total entries per LUT: {LUT_SIZE**3:,}")
