"""Top-level checks (called from run_sim.py top): I2S framing, AXI-Lite, DMA streams."""
import os

import numpy as np

import pv_params as P
from pv_model import PVModel


def _hex(path, vals):
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{int(v) & 0xFFFF:04X}\n')


def _align(ref, got, max_lag=3 * P.N):
    """Lag that best aligns got to ref (got[n + lag] ~ ref[n]). Needs an aperiodic signal."""
    best, lag = -1, 0
    r = ref[P.N:P.N + 1024].astype(float)
    for L in range(0, max_lag):
        g = got[P.N + L:P.N + L + 1024].astype(float)
        if len(g) < len(r):
            break
        c = np.dot(r, g) / (np.linalg.norm(r) * np.linalg.norm(g) + 1e-9)
        if c > best:
            best, lag = c, L
    return lag


def _snr(ref, x):
    e = x.astype(float) - ref.astype(float)
    return 10 * np.log10(np.mean(ref.astype(float) ** 2) / max(np.mean(e ** 2), 1e-12))


def test_top(build, run, work):
    build('tb_top', ['tb_top.v'])
    ns = 14 * P.H
    t = np.arange(ns) / P.FS
    noise = np.random.default_rng(7).standard_normal(ns) * 400        # makes alignment unique
    x = np.round(6000 * np.sin(2 * np.pi * 330 * t) + 2000 * np.sin(2 * np.pi * 660 * t) + noise).astype(np.int64)
    _hex(os.path.join(work, 'top_in.hex'), x)
    _hex(os.path.join(work, 'dma_in.hex'), x)
    ok_all = True

    # 1. dry loopback through the real I2S framing must be bit exact
    out = run('tb_top', f'+TEST=bypass +NS={ns}')
    dac = np.loadtxt(os.path.join(work, 'dac.txt')).astype(np.int64)
    lag = next((L for L in range(0, 64) if np.array_equal(dac[L + 50:L + 1050, 0], x[50:1050])), None)
    ok = lag is not None and np.array_equal(dac[:, 0], dac[:, 1]) and 'PASS' in out
    print(f'top/bypass: I2S loopback bit-exact={lag is not None} (lag {lag} frames), L==R -> {"PASS" if ok else "FAIL"}')
    ok_all &= ok

    # 2. phase vocoder through the codec path
    ref = PVModel(autotune_en=0).run(x)
    out = run('tb_top', f'+TEST=dsp +NS={ns}')
    dac = np.loadtxt(os.path.join(work, 'dac.txt')).astype(np.int64)[:, 0]
    lag = _align(ref, dac)
    n = min(len(ref), len(dac) - lag)
    s = _snr(ref[P.N:n], dac[P.N + lag:n + lag])
    ok = s > 60 and 'PASS' in out
    print(f'top/dsp   : codec in -> DSP -> codec out vs model SNR {s:.1f} dB (lag {lag}) -> {"PASS" if ok else "FAIL"}')
    ok_all &= ok

    # 3. file playback via DMA MM2S with S2MM capture
    # the capture is hardware-aligned: cap[n] is the output for file sample n
    out = run('tb_top', f'+TEST=dma +NS={ns}')
    cap = np.loadtxt(os.path.join(work, 'cap.txt')).astype(np.int64)
    L0 = P.N - P.H
    n = min(len(ref) - L0, len(cap))
    s = _snr(ref[P.N + L0:n + L0], cap[P.N:n])
    s_in = _snr(x[P.N:n], cap[P.N:n])
    ok = s > 60 and s_in > 50 and len(cap) == ns and 'PASS' in out
    print(f'top/dma   : MM2S file -> DSP -> S2MM capture: {len(cap)} samples, aligned SNR vs model {s:.1f} dB, '
          f'vs input {s_in:.1f} dB -> {"PASS" if ok else "FAIL"}')
    ok_all &= ok
    return ok_all
