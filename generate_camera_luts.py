"""
DAZZ 相机级 LUT 生成器
为每台相机生成 33x33x33 的 .cube 文件，精准还原各机型的色彩特征。

每台相机的色彩设计依据：
- ccd_m  : Sony CCD 蓝调冷色，高饱和，轻微青偏
- ccd_r  : Sony CCD 暖红调版本，暖橙肤色，胶片感
- d_classic: 数码复古，轻微暖色，适度对比
- fisheye : 鱼眼镜头，高饱和高对比，色彩夸张
- fxn_r  : Fujifilm X 系列，绿色偏移，高对比胶片
- grd_r  : Ricoh GRD，高对比黑白感（彩色版），强暗角
- inst_c  : Instax Wide，明亮高饱和，偏暖
- inst_s  : Instax Mini，柔和暖色，低对比
- inst_sq : Instax Square，暖黄偏移，胶片质感最强
- u300   : 水下相机，蓝绿偏移，清透感
"""

import numpy as np
import os

OUTPUT_DIR = '/home/ubuntu/retro_cam_project/flutter_app/assets/lut/cameras'
os.makedirs(OUTPUT_DIR, exist_ok=True)

SIZE = 33  # 33x33x33 LUT

def apply_color_transform(r, g, b, params):
    """
    对单个 RGB 值（0-1 范围）应用色彩变换，返回变换后的 RGB。
    params 字典支持：
      temp        : 色温偏移 (-1~+1, 正=暖)
      tint        : 色调偏移 (-1~+1, 正=品红)
      contrast    : 对比度 (0.5~1.5, 1=无变化)
      saturation  : 饱和度 (0~2, 1=无变化)
      highlights  : 高光调整 (-1~+1)
      shadows     : 阴影调整 (-1~+1)
      lift_r/g/b  : 各通道提升 (0~0.1)
      gain_r/g/b  : 各通道增益 (0.8~1.2)
      gamma_r/g/b : 各通道伽马 (0.8~1.2)
      cross_r_from_b: 交叉处理 - 红通道从蓝通道获取偏移
      cross_b_from_r: 交叉处理 - 蓝通道从红通道获取偏移
      fade        : 褪色（黑场提亮）(0~0.15)
    """
    # 1. 各通道独立增益 + 提升（模拟胶片曲线的通道偏移）
    r = r * params.get('gain_r', 1.0) + params.get('lift_r', 0.0)
    g = g * params.get('gain_g', 1.0) + params.get('lift_g', 0.0)
    b = b * params.get('gain_b', 1.0) + params.get('lift_b', 0.0)

    # 2. 伽马调整（通道独立）
    r = np.power(np.clip(r, 1e-6, 1.0), 1.0 / params.get('gamma_r', 1.0))
    g = np.power(np.clip(g, 1e-6, 1.0), 1.0 / params.get('gamma_g', 1.0))
    b = np.power(np.clip(b, 1e-6, 1.0), 1.0 / params.get('gamma_b', 1.0))

    # 3. 交叉处理（cross-processing）
    cross_r = params.get('cross_r_from_b', 0.0)
    cross_b = params.get('cross_b_from_r', 0.0)
    r = r + b * cross_r
    b = b + r * cross_b

    # 4. 色温偏移（暖色 = R+, B-）
    temp = params.get('temp', 0.0)
    r = r + temp * 0.12
    b = b - temp * 0.12

    # 5. 色调偏移（品红 = R+, B+, G-）
    tint = params.get('tint', 0.0)
    r = r + tint * 0.04
    g = g - tint * 0.04
    b = b + tint * 0.02

    # 6. 对比度（以 0.5 为中心）
    contrast = params.get('contrast', 1.0)
    mid = 0.5
    r = (r - mid) * contrast + mid
    g = (g - mid) * contrast + mid
    b = (b - mid) * contrast + mid

    # 7. 高光/阴影调整（S 曲线模拟）
    hl = params.get('highlights', 0.0)
    sh = params.get('shadows', 0.0)
    def apply_hl_sh(c, h, s):
        # 高光：亮部区域 (>0.7) 调整
        hl_mask = np.clip((c - 0.7) / 0.3, 0, 1)
        c = c + h * 0.15 * hl_mask
        # 阴影：暗部区域 (<0.3) 调整
        sh_mask = np.clip((0.3 - c) / 0.3, 0, 1)
        c = c + s * 0.15 * sh_mask
        return c
    r = apply_hl_sh(r, hl, sh)
    g = apply_hl_sh(g, hl, sh)
    b = apply_hl_sh(b, hl, sh)

    # 8. 饱和度
    sat = params.get('saturation', 1.0)
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
    r = luma + (r - luma) * sat
    g = luma + (g - luma) * sat
    b = luma + (b - luma) * sat

    # 9. 褪色（黑场提亮，模拟胶片 fade）
    fade = params.get('fade', 0.0)
    r = r * (1 - fade) + fade
    g = g * (1 - fade) + fade
    b = b * (1 - fade) + fade

    # 10. 最终 clamp
    r = np.clip(r, 0.0, 1.0)
    g = np.clip(g, 0.0, 1.0)
    b = np.clip(b, 0.0, 1.0)

    return r, g, b


def generate_lut(title, filename, params):
    """生成 33x33x33 .cube 文件"""
    indices = np.linspace(0.0, 1.0, SIZE)
    
    lines = [
        f'TITLE "{title}"',
        f'# DAZZ Camera LUT - {title}',
        f'# Generated for DAZZ retro camera app',
        f'LUT_3D_SIZE {SIZE}',
        f'DOMAIN_MIN 0.0 0.0 0.0',
        f'DOMAIN_MAX 1.0 1.0 1.0',
        '',
    ]
    
    # .cube 格式：R 变化最快，B 变化最慢
    for bi in range(SIZE):
        for gi in range(SIZE):
            for ri in range(SIZE):
                r_in = indices[ri]
                g_in = indices[gi]
                b_in = indices[bi]
                
                r_out, g_out, b_out = apply_color_transform(r_in, g_in, b_in, params)
                lines.append(f'{r_out:.6f} {g_out:.6f} {b_out:.6f}')
    
    out_path = os.path.join(OUTPUT_DIR, filename)
    with open(out_path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    
    size_kb = os.path.getsize(out_path) // 1024
    print(f'  ✅ {filename:<25} {SIZE}^3={SIZE**3} 点  {size_kb}KB')


# ─────────────────────────────────────────────────────────────────────────────
# 各相机 LUT 参数定义
# ─────────────────────────────────────────────────────────────────────────────

cameras = [
    # ── CCD M（Sony CCD 蓝调冷色版）──────────────────────────────────────────
    # 特征：CCD 传感器的标志性蓝青偏移，高饱和，轻微欠曝感
    # 参考：Sony Cybershot DSC-T 系列，蓝天更蓝，肤色偏冷
    (
        'CCD M',
        'ccd_m.cube',
        {
            'temp': -0.25,          # 偏冷
            'tint': -0.15,          # 轻微偏绿（CCD 特征）
            'contrast': 1.08,       # 稍高对比
            'saturation': 1.18,     # CCD 高饱和
            'highlights': -0.1,
            'shadows': 0.05,
            'gain_r': 0.92,         # 压低红通道
            'gain_g': 1.02,
            'gain_b': 1.12,         # 提升蓝通道
            'lift_r': 0.0,
            'lift_g': 0.0,
            'lift_b': 0.02,         # 蓝色提升
            'gamma_r': 1.05,        # 红通道稍暗
            'gamma_g': 1.0,
            'gamma_b': 0.95,        # 蓝通道稍亮
            'fade': 0.0,
        }
    ),

    # ── CCD R（Sony CCD 暖红调版）────────────────────────────────────────────
    # 特征：CCD 传感器暖色版，偏橙红，肤色好看，类似 DSC-W 系列
    # 与 ccd_m 形成冷暖对比
    (
        'CCD R',
        'ccd_r.cube',
        {
            'temp': 0.20,           # 偏暖
            'tint': 0.10,           # 轻微品红
            'contrast': 1.06,
            'saturation': 1.12,
            'highlights': -0.08,
            'shadows': 0.08,
            'gain_r': 1.10,         # 提升红通道
            'gain_g': 1.02,
            'gain_b': 0.90,         # 压低蓝通道
            'lift_r': 0.01,
            'lift_g': 0.0,
            'lift_b': 0.0,
            'gamma_r': 0.95,        # 红通道稍亮
            'gamma_g': 1.0,
            'gamma_b': 1.08,        # 蓝通道稍暗
            'cross_r_from_b': 0.0,
            'fade': 0.02,           # 轻微褪色
        }
    ),

    # ── D Classic（数码复古）─────────────────────────────────────────────────
    # 特征：早期数码相机的色彩还原，轻微暖色，略高对比，清晰锐利
    # 参考：Canon PowerShot G 系列早期机型
    (
        'D Classic',
        'd_classic.cube',
        {
            'temp': 0.12,
            'tint': 0.05,
            'contrast': 1.10,
            'saturation': 1.06,
            'highlights': -0.06,
            'shadows': -0.04,
            'gain_r': 1.04,
            'gain_g': 1.0,
            'gain_b': 0.96,
            'lift_r': 0.005,
            'lift_g': 0.0,
            'lift_b': 0.0,
            'gamma_r': 0.98,
            'gamma_g': 1.0,
            'gamma_b': 1.02,
            'fade': 0.01,
        }
    ),

    # ── Fisheye（鱼眼相机）──────────────────────────────────────────────────
    # 特征：色彩夸张，高饱和，高对比，偏向艺术感
    # 参考：Lomography Fisheye 系列，色彩浓烈
    (
        'Fisheye',
        'fisheye.cube',
        {
            'temp': 0.08,
            'tint': 0.0,
            'contrast': 1.20,       # 高对比
            'saturation': 1.30,     # 高饱和
            'highlights': -0.12,
            'shadows': -0.08,
            'gain_r': 1.06,
            'gain_g': 1.04,
            'gain_b': 0.96,
            'lift_r': 0.0,
            'lift_g': 0.0,
            'lift_b': 0.0,
            'gamma_r': 0.96,
            'gamma_g': 0.98,
            'gamma_b': 1.04,
            'cross_r_from_b': 0.04, # 轻微交叉处理
            'fade': 0.0,
        }
    ),

    # ── FXN R（Fujifilm X 系列胶片模拟）─────────────────────────────────────
    # 特征：Fujifilm 标志性的绿色偏移，高对比，胶片感强
    # 参考：Fujifilm X100 系列 Classic Chrome 模拟
    (
        'FXN R',
        'fxn_r.cube',
        {
            'temp': 0.05,
            'tint': -0.20,          # 偏绿（Fuji 特征）
            'contrast': 1.12,
            'saturation': 1.08,
            'highlights': -0.15,    # 压高光
            'shadows': 0.10,        # 提阴影
            'gain_r': 0.96,
            'gain_g': 1.06,         # 绿通道提升
            'gain_b': 0.94,
            'lift_r': 0.01,
            'lift_g': 0.01,
            'lift_b': 0.01,
            'gamma_r': 1.02,
            'gamma_g': 0.96,        # 绿通道稍亮
            'gamma_b': 1.04,
            'fade': 0.03,           # 轻微褪色（Classic Chrome 特征）
        }
    ),

    # ── GRD R（Ricoh GRD 高对比黑白感）──────────────────────────────────────
    # 特征：极高对比度，近乎黑白的色彩倾向，强暗角，锐利
    # 参考：Ricoh GR Digital III，黑白模式的彩色版
    (
        'GRD R',
        'grd_r.cube',
        {
            'temp': -0.10,          # 轻微偏冷
            'tint': 0.0,
            'contrast': 1.28,       # 极高对比
            'saturation': 0.82,     # 低饱和（近黑白）
            'highlights': -0.18,
            'shadows': -0.12,
            'gain_r': 0.98,
            'gain_g': 1.0,
            'gain_b': 1.02,
            'lift_r': 0.0,
            'lift_g': 0.0,
            'lift_b': 0.0,
            'gamma_r': 1.0,
            'gamma_g': 1.0,
            'gamma_b': 1.0,
            'fade': 0.0,
        }
    ),

    # ── Inst C（Instax Wide）────────────────────────────────────────────────
    # 特征：明亮高饱和，偏暖，色彩鲜艳，宽幅格式
    # 参考：Fujifilm Instax Wide 300
    (
        'Instax Wide',
        'inst_c.cube',
        {
            'temp': 0.18,
            'tint': 0.08,
            'contrast': 1.08,
            'saturation': 1.20,
            'highlights': 0.05,     # 高光略亮
            'shadows': -0.06,
            'gain_r': 1.08,
            'gain_g': 1.02,
            'gain_b': 0.92,
            'lift_r': 0.01,
            'lift_g': 0.005,
            'lift_b': 0.0,
            'gamma_r': 0.96,
            'gamma_g': 0.98,
            'gamma_b': 1.04,
            'fade': 0.02,
        }
    ),

    # ── Inst S（Instax Mini）────────────────────────────────────────────────
    # 特征：柔和暖色，低对比，高光不过曝，阴影不死黑，胶片质感
    # 参考：Fujifilm Instax Mini 11/12
    (
        'Instax Mini',
        'inst_s.cube',
        {
            'temp': 0.30,           # 较强暖色
            'tint': 0.06,
            'contrast': 0.90,       # 低对比
            'saturation': 1.06,
            'highlights': -0.20,    # 强压高光
            'shadows': 0.15,        # 强提阴影
            'gain_r': 1.12,
            'gain_g': 1.04,
            'gain_b': 0.88,
            'lift_r': 0.02,
            'lift_g': 0.01,
            'lift_b': 0.005,
            'gamma_r': 0.94,
            'gamma_g': 0.98,
            'gamma_b': 1.06,
            'fade': 0.05,           # 明显褪色感
        }
    ),

    # ── Inst SQ（Instax Square）─────────────────────────────────────────────
    # 特征：暖黄偏移，胶片质感最强，方形格式，R-B差值最大
    # 参考：Fujifilm Instax Square SQ6/SQ40，实测 R-B=+31
    (
        'Instax Square',
        'inst_sq.cube',
        {
            'temp': 0.38,           # 最强暖色（对应 temperature=48）
            'tint': 0.06,
            'contrast': 0.88,       # 最低对比
            'saturation': 1.04,
            'highlights': -0.22,    # 最强高光压制
            'shadows': 0.18,        # 最强阴影提亮
            'gain_r': 1.14,         # 红通道最强
            'gain_g': 1.03,
            'gain_b': 0.84,         # 蓝通道最弱
            'lift_r': 0.025,
            'lift_g': 0.01,
            'lift_b': 0.005,
            'gamma_r': 0.92,        # 红通道最亮
            'gamma_g': 0.98,
            'gamma_b': 1.08,        # 蓝通道最暗
            'fade': 0.06,           # 最强褪色（胶片质感）
        }
    ),

    # ── U300（水下相机）─────────────────────────────────────────────────────
    # 特征：蓝绿偏移，清透感，水下色彩还原
    # 参考：Olympus Tough TG 系列水下模式
    (
        'U300',
        'u300.cube',
        {
            'temp': -0.20,          # 偏冷（水下感）
            'tint': -0.10,          # 轻微偏青
            'contrast': 0.96,
            'saturation': 1.10,
            'highlights': -0.05,
            'shadows': 0.08,
            'gain_r': 0.88,         # 压低红（水下红色衰减）
            'gain_g': 1.08,         # 提升绿
            'gain_b': 1.16,         # 提升蓝（水下蓝色增强）
            'lift_r': 0.0,
            'lift_g': 0.01,
            'lift_b': 0.02,
            'gamma_r': 1.06,
            'gamma_g': 0.98,
            'gamma_b': 0.94,
            'fade': 0.01,
        }
    ),
]


print(f'生成 {len(cameras)} 个相机级 LUT 文件（{SIZE}x{SIZE}x{SIZE}）...\n')
for title, filename, params in cameras:
    generate_lut(title, filename, params)

print(f'\n✅ 全部完成！输出目录: {OUTPUT_DIR}')
print(f'文件列表:')
for f in sorted(os.listdir(OUTPUT_DIR)):
    size = os.path.getsize(os.path.join(OUTPUT_DIR, f)) // 1024
    print(f'  {f:<25} {size}KB')
