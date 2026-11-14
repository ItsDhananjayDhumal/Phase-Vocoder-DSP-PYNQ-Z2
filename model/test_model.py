"""Sanity tests of the golden model: python model/test_model.py"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sw', 'pynq'))
import pv_params as P  # noqa: E402
from pv_model import PVModel  # noqa: E402

L = P.N - P.H


def tone(f0, secs=1.0, amp=8000, harmonics=1):
    t = np.arange(int(secs * P.FS)) / P.FS
    x = sum(amp / h * np.sin(2 * np.pi * f0 * h * t) for h in range(1, harmonics + 1))
    return np.round(x).astype(np.int64)


def est_freq(y, lo=60, hi=1500):
    """Fundamental via a long FFT with parabolic interpolation (lowest strong peak)."""
    y = y.astype(float) * np.hanning(len(y))
    n = 1 << 18
    Y = np.abs(np.fft.rfft(y, n))
    f = np.arange(len(Y)) * P.FS / n
    band = (f > lo) & (f < hi)
    idx = np.where(band)[0]
    thr = Y[idx].max() * 0.3
    for i in idx[1:-1]:
        if Y[i] >= thr and Y[i] >= Y[i - 1] and Y[i] >= Y[i + 1]:
            a, b, c = np.log(Y[i - 1:i + 2])
            return (i + 0.5 * (a - c) / (a - 2 * b + c)) * P.FS / n
    return float('nan')


def cents(f, ref):
    return 1200 * np.log2(f / ref)


def main():
    ok = True

    x = tone(300, harmonics=4)
    y = PVModel(autotune_en=0).run(x)
    n = len(y) - L
    err = y[L:] - x[:n]
    snr = 10 * np.log10(np.mean(x[:n] ** 2) / max(np.mean(err ** 2), 1e-9))
    print(f'identity  : SNR {snr:6.1f} dB (expect > 60)')
    ok &= snr > 60

    y = PVModel(autotune_en=0, manual_ratio=int(round(2 ** (3 / 12) * 65536))).run(tone(220, harmonics=3))
    f = est_freq(y[P.N:])
    print(f'shift +3st: 220 Hz -> {f:7.2f} Hz (expect {220 * 2 ** 0.25:.2f})')
    ok &= abs(cents(f, 220 * 2 ** 0.25)) < 5

    for f_in, f_exp in [(452.0, 440.0), (209.0, 207.65), (127.0, 123.47), (330.0, 329.63)]:
        m = PVModel(alpha=65536)
        y = m.run(tone(f_in, secs=1.0, harmonics=5))
        f = est_freq(y[P.N * 2:])
        f0s = [P.q14_to_hz(t[0]) for t in m.telemetry[8:]]
        print(f'autotune  : {f_in:6.1f} Hz -> {f:7.2f} Hz (expect {f_exp:.2f}); '
              f'detected {np.median(f0s):7.2f} Hz, voiced {np.mean([t[3] for t in m.telemetry[8:]]):.2f}')
        ok &= abs(cents(f, f_exp)) < 8

    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
