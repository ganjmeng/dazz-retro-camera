#!/usr/bin/env python3
"""
Generate 5 distinct shutter sound WAV files for DAZZ camera app.
Each sound is synthesized to match a camera type's character.

Sound types:
  1. mechanical  - GRD/film SLR style: sharp click + body resonance
  2. instax      - Instax/Polaroid style: soft thunk + motor whir
  3. ccd         - CCD compact style: electronic beep-click
  4. fisheye     - Lomo/toy camera: plastic snap
  5. silent      - Near-silent: very soft click (for quiet environments)
"""

import numpy as np
import struct
import wave
import os

OUT_DIR = '/home/ubuntu/retro_cam_project/flutter_app/assets/sounds'
os.makedirs(OUT_DIR, exist_ok=True)

SAMPLE_RATE = 44100

def write_wav(filename, samples, rate=SAMPLE_RATE):
    """Write float32 array [-1,1] to 16-bit mono WAV."""
    # Normalize and clip
    peak = np.max(np.abs(samples))
    if peak > 0:
        samples = samples / peak * 0.90
    samples = np.clip(samples, -1.0, 1.0)
    int_samples = (samples * 32767).astype(np.int16)
    path = os.path.join(OUT_DIR, filename)
    with wave.open(path, 'w') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(int_samples.tobytes())
    print(f"  Written: {filename} ({len(int_samples)/rate*1000:.0f}ms, {os.path.getsize(path)//1024}KB)")

def envelope(t, attack=0.001, decay=0.05, sustain=0.3, release=0.1, sustain_level=0.4):
    """ADSR envelope."""
    env = np.zeros_like(t)
    total = attack + decay + sustain + release
    a_end = attack
    d_end = attack + decay
    s_end = attack + decay + sustain
    env[t < a_end] = t[t < a_end] / attack
    mask_d = (t >= a_end) & (t < d_end)
    env[mask_d] = 1.0 - (1.0 - sustain_level) * (t[mask_d] - a_end) / decay
    mask_s = (t >= d_end) & (t < s_end)
    env[mask_s] = sustain_level
    mask_r = t >= s_end
    env[mask_r] = sustain_level * (1.0 - (t[mask_r] - s_end) / release)
    return np.clip(env, 0, 1)

def noise_burst(duration, rate=SAMPLE_RATE):
    n = int(duration * rate)
    return np.random.randn(n)

def tone(freq, duration, rate=SAMPLE_RATE, phase=0):
    t = np.linspace(0, duration, int(duration * rate), endpoint=False)
    return np.sin(2 * np.pi * freq * t + phase)

def exp_decay(n, tau):
    """Exponential decay envelope of length n with time constant tau (samples)."""
    return np.exp(-np.arange(n) / tau)

# ─── 1. mechanical ────────────────────────────────────────────────────────────
# GRD / film SLR: sharp transient click + low-freq body thump + trailing resonance
def make_mechanical():
    dur = 0.18
    n = int(dur * SAMPLE_RATE)
    t = np.arange(n) / SAMPLE_RATE

    # Sharp click: broadband noise burst with fast decay
    click_n = int(0.003 * SAMPLE_RATE)
    click = noise_burst(0.003) * exp_decay(click_n, click_n * 0.3)
    click_sig = np.zeros(n)
    click_sig[:click_n] = click * 0.9

    # Body resonance: low-freq damped sine ~180Hz
    body_freq = 180
    body_n = int(0.12 * SAMPLE_RATE)
    body_t = np.arange(body_n) / SAMPLE_RATE
    body = np.sin(2 * np.pi * body_freq * body_t) * exp_decay(body_n, body_n * 0.25)
    body_sig = np.zeros(n)
    body_sig[:body_n] = body * 0.5

    # Mirror slap: mid-freq ~800Hz short burst
    slap_n = int(0.008 * SAMPLE_RATE)
    slap_t = np.arange(slap_n) / SAMPLE_RATE
    slap = np.sin(2 * np.pi * 800 * slap_t) * exp_decay(slap_n, slap_n * 0.2)
    slap_sig = np.zeros(n)
    slap_sig[:slap_n] = slap * 0.4

    sig = click_sig + body_sig + slap_sig
    write_wav('shutter_mechanical.wav', sig)

# ─── 2. instax ────────────────────────────────────────────────────────────────
# Instax / Polaroid: soft thunk + brief motor whir
def make_instax():
    dur = 0.30
    n = int(dur * SAMPLE_RATE)

    # Soft thunk: low-freq noise with slow attack
    thunk_n = int(0.06 * SAMPLE_RATE)
    thunk_noise = noise_burst(0.06)
    # Low-pass via simple moving average
    kernel = np.ones(80) / 80
    thunk_noise = np.convolve(thunk_noise, kernel, mode='same')
    thunk_env = np.concatenate([
        np.linspace(0, 1, int(thunk_n * 0.1)),
        np.linspace(1, 0, thunk_n - int(thunk_n * 0.1))
    ])
    thunk = thunk_noise * thunk_env * 0.7

    # Motor whir: rising then falling frequency sweep
    motor_n = int(0.18 * SAMPLE_RATE)
    motor_t = np.arange(motor_n) / SAMPLE_RATE
    freq_sweep = 300 + 400 * np.sin(np.pi * motor_t / motor_t[-1])
    phase = np.cumsum(2 * np.pi * freq_sweep / SAMPLE_RATE)
    motor_env = np.sin(np.pi * motor_t / motor_t[-1]) * 0.25
    motor = np.sin(phase) * motor_env

    sig = np.zeros(n)
    sig[:thunk_n] += thunk
    offset = int(0.02 * SAMPLE_RATE)
    sig[offset:offset + motor_n] += motor

    write_wav('shutter_instax.wav', sig)

# ─── 3. ccd ───────────────────────────────────────────────────────────────────
# CCD compact (Sony/Canon): electronic beep-click, crisp and digital
def make_ccd():
    dur = 0.12
    n = int(dur * SAMPLE_RATE)

    # Electronic click: short 1200Hz tone with very fast decay
    click_n = int(0.015 * SAMPLE_RATE)
    click_t = np.arange(click_n) / SAMPLE_RATE
    click = np.sin(2 * np.pi * 1200 * click_t) * exp_decay(click_n, click_n * 0.15)

    # Confirmation beep: 2400Hz short tone, slightly delayed
    beep_n = int(0.025 * SAMPLE_RATE)
    beep_t = np.arange(beep_n) / SAMPLE_RATE
    beep = np.sin(2 * np.pi * 2400 * beep_t) * exp_decay(beep_n, beep_n * 0.3) * 0.35

    # Noise transient
    trans_n = int(0.004 * SAMPLE_RATE)
    trans = noise_burst(0.004) * exp_decay(trans_n, trans_n * 0.2) * 0.5

    sig = np.zeros(n)
    sig[:click_n] += click
    sig[:trans_n] += trans
    delay = int(0.018 * SAMPLE_RATE)
    sig[delay:delay + beep_n] += beep

    write_wav('shutter_ccd.wav', sig)

# ─── 4. fisheye ───────────────────────────────────────────────────────────────
# Lomo / toy camera: plastic snap, hollow and bright
def make_fisheye():
    dur = 0.14
    n = int(dur * SAMPLE_RATE)

    # Plastic snap: mid-high noise burst with hollow resonance
    snap_n = int(0.005 * SAMPLE_RATE)
    snap = noise_burst(0.005) * exp_decay(snap_n, snap_n * 0.25)

    # Hollow body resonance: ~600Hz
    res_n = int(0.08 * SAMPLE_RATE)
    res_t = np.arange(res_n) / SAMPLE_RATE
    res = np.sin(2 * np.pi * 600 * res_t) * exp_decay(res_n, res_n * 0.2) * 0.45

    # Bright overtone: ~1800Hz
    ov_n = int(0.04 * SAMPLE_RATE)
    ov_t = np.arange(ov_n) / SAMPLE_RATE
    ov = np.sin(2 * np.pi * 1800 * ov_t) * exp_decay(ov_n, ov_n * 0.15) * 0.25

    sig = np.zeros(n)
    sig[:snap_n] += snap * 0.8
    sig[:res_n] += res
    sig[:ov_n] += ov

    write_wav('shutter_fisheye.wav', sig)

# ─── 5. silent ────────────────────────────────────────────────────────────────
# Near-silent: very soft, barely audible click for quiet environments
def make_silent():
    dur = 0.06
    n = int(dur * SAMPLE_RATE)

    click_n = int(0.008 * SAMPLE_RATE)
    click = noise_burst(0.008) * exp_decay(click_n, click_n * 0.3) * 0.15

    # Low-pass filter
    kernel = np.ones(30) / 30
    click = np.convolve(click, kernel, mode='same')

    sig = np.zeros(n)
    sig[:click_n] = click

    write_wav('shutter_silent.wav', sig)

print("Generating shutter sounds...")
make_mechanical()
make_instax()
make_ccd()
make_fisheye()
make_silent()
print("Done! All 5 shutter sounds generated.")
