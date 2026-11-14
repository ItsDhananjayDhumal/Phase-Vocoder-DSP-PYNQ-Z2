"""Golden model of the phase-vocoder autotune datapath (hw/rtl/pv_core.v).

It reproduces the hardware's integer formats and decisions step by step:
  window -> FFT (scaled by 1/N) -> magnitude/phase -> phase unwrapping and
  instantaneous frequency -> pitch detection -> tuning-table lookup -> ratio
  smoothing -> magnitude interpolation + phase accumulation -> noise gate /
  frequency-sampling EQ -> polar->rect -> IFFT -> synthesis window -> OLA.

The FFT and CORDIC are done in floating point and rounded, so RTL results
match to within a few LSBs rather than bit-exactly.

It doubles as the PS.pdf "bonus" software flow: run_file() takes a .wav,
does windowing/OLA in Python and writes the processed .wav.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sw', 'pynq'))
import pv_params as P  # noqa: E402

M16 = 0xFFFF


def _s16(v):
    v = np.asarray(v, dtype=np.int64) & M16
    return np.where(v >= 0x8000, v - 0x10000, v)


def _sat(v, bits):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return np.clip(v, lo, hi)


class PVModel:
    def __init__(self, **regs):
        self.wa = P.analysis_window()
        self.ws = P.synthesis_window()
        notes, uppers, _ = P.note_table()
        self.regs = dict(
            dsp_en=1, autotune_en=1, eq_en=0, gate_en=0, mute=0,
            manual_ratio=P.RATIO_ONE, alpha=P.DEFAULT_ALPHA,
            peak_thr=P.DEFAULT_PEAK_THR, voice_thr=P.DEFAULT_VOICE_THR,
            gate_thr=P.DEFAULT_GATE_THR, out_gain=P.EQ_ONE,
            kmin=P.DEFAULT_KMIN, kmax=P.DEFAULT_KMAX,
            notes=notes, uppers=uppers,
            eq=np.full(P.NBINS, P.EQ_ONE, dtype=np.int64),
        )
        self.regs.update(regs)
        self.reset()

    def reset(self):
        self.hist = np.zeros(P.N, dtype=np.int64)
        self.ola = np.zeros(P.N, dtype=np.int64)
        self.prev_phase = np.zeros(P.NBINS, dtype=np.int64)
        self.synth_phase = np.zeros(P.NBINS, dtype=np.int64)
        self.ratio_s = P.RATIO_ONE
        self.telemetry = []

    # ------------------------------------------------------------------ frame
    def frame(self, buf):
        r = self.regs
        k = np.arange(P.NBINS)

        # 1-3. window + FFT (hardware FFT is scaled by 1/2 per stage = 1/N)
        xw = (buf * self.wa) >> P.WIN_IN_SHIFT
        X = np.fft.fft(xw)[:P.NBINS] / P.N
        Xr, Xi = np.round(X.real), np.round(X.imag)

        # 4. rect -> polar (CORDIC vectoring); phase as 16-bit binary angle
        mag = np.minimum(np.round(np.hypot(Xr, Xi)), (1 << 24) - 1).astype(np.int64)
        ph = np.round(np.arctan2(Xi, Xr) / (2 * np.pi) * 65536).astype(np.int64) & M16

        # 8a. phase unwrapping -> instantaneous frequency (Q.14 bins)
        dev = _s16(ph - self.prev_phase - k * (1 << P.OMEGA_FRAC))
        omega = (k << P.OMEGA_FRAC) + dev
        self.prev_phase = ph

        # 5. pitch detection: lowest local peak >= peak_thr * global max
        kmin, kmax = r['kmin'], r['kmax']
        gmax = int(mag[kmin:kmax + 1].max())
        thr = (gmax * r['peak_thr']) >> 16
        fund = None
        for kk in range(kmin, kmax + 1):
            if mag[kk] > mag[kk - 1] and mag[kk] >= mag[kk + 1] and mag[kk] >= thr:
                fund = kk
                break
        f0 = int(omega[fund]) if fund is not None else 0
        voiced = fund is not None and gmax >= r['voice_thr'] and f0 > 0

        # 6. tuning-table lookup and ratio
        target = 0
        s_auto = P.RATIO_ONE
        if voiced:
            n = len(r['notes'])
            target = r['notes'][n - 1]
            for nf, up in zip(r['notes'], r['uppers']):
                if f0 < up:
                    target = nf
                    break
            if r['autotune_en']:
                s_auto = min(max((target << 16) // f0, P.RATIO_MIN), 1 << 17)
        step = ((s_auto - self.ratio_s) * r['alpha']) >> 16
        self.ratio_s = s_auto if step in (0, -1) else self.ratio_s + step   # snap when settled
        s_tot = min(max((self.ratio_s * r['manual_ratio']) >> 16, P.RATIO_MIN), P.RATIO_MAX)
        inv = (1 << 32) // s_tot
        self.telemetry.append((f0, target, s_tot, voiced, fund))

        # 7. magnitude resampling: source = target_bin / S, linear interpolation
        p = k * inv
        i = p >> 16
        F = p & 0xFFFF
        inside = i < P.NBINS - 1
        ic = np.minimum(i, P.NBINS - 2)
        m0, m1 = mag[ic], mag[ic + 1]
        mag_t = np.where(inside, m0 + (((m1 - m0) * F) >> 16), 0)
        ir = np.minimum(ic + (F >> 15), P.NBINS - 1)

        # 8b. phase accumulation at the shifted frequency
        if s_tot == P.RATIO_ONE:
            self.synth_phase = ph.copy()
        else:
            w_t = (omega[ir] * s_tot) >> 16
            self.synth_phase = (self.synth_phase + w_t) & M16
        phase_t = self.synth_phase

        # Gaydecki blocks: spectral noise gate and frequency-sampling EQ
        if r['gate_en']:
            mag_t = np.where(mag_t < r['gate_thr'], 0, mag_t)
        if r['eq_en']:
            mag_t = np.minimum((mag_t * r["eq"][:P.NBINS]) >> 14, (1 << 24) - 1)

        # 9. polar -> rect, Hermitian spectrum
        ang = phase_t / 65536 * 2 * np.pi
        yr = _sat(np.round(mag_t * np.cos(ang)), P.DW)
        yi = _sat(np.round(mag_t * np.sin(ang)), P.DW)
        Y = np.zeros(P.N, dtype=complex)
        Y[:P.NBINS] = yr + 1j * yi
        Y[0] = yr[0]
        Y[P.N // 2] = yr[-1]
        Y[P.NBINS:] = np.conj(Y[1:P.N // 2][::-1])

        # 10. inverse FFT (unscaled: forward already divided by N)
        y = _sat(np.round(np.fft.ifft(Y).real * P.N), P.DW).astype(np.int64)

        # 11. synthesis window + overlap-add
        self.ola += (y * self.ws) >> 16
        out = _sat((self.ola[:P.H] + (1 << (P.OUT_SHIFT - 1))) >> P.OUT_SHIFT, 16)
        self.ola = np.concatenate([self.ola[P.H:], np.zeros(P.H, dtype=np.int64)])
        return out

    # --------------------------------------------------------------- streams
    def run(self, x):
        """Process int16 samples; returns the OLA output stream (hop-aligned)."""
        x = np.asarray(x, dtype=np.int64)
        outs = []
        for start in range(0, len(x) - P.H + 1, P.H):
            self.hist = np.concatenate([self.hist[P.H:], x[start:start + P.H]])
            outs.append(self.frame(self.hist))
        y = np.concatenate(outs) if outs else np.zeros(0, dtype=np.int64)
        r = self.regs
        if not r['dsp_en']:
            y = x[:len(y)]
        if r['mute']:
            y = np.zeros_like(y)
        return _sat((y * r['out_gain']) >> 14, 16)

    LATENCY = N_MINUS_H = P.N - P.H  # input sample n appears at OLA output index n + N - H


def read_wav(path):
    from scipy.io import wavfile
    fs, x = wavfile.read(path)
    if x.ndim > 1:
        x = x.mean(axis=1)
    if x.dtype.kind == 'f':
        x = x * 32767
    elif x.dtype == np.int32:
        x = x / 65536
    elif x.dtype == np.uint8:
        x = (x.astype(np.int32) - 128) * 256
    x = np.asarray(x, dtype=np.float64)
    if fs != P.FS:
        from scipy.signal import resample_poly
        from math import gcd
        g = gcd(fs, P.FS)
        x = resample_poly(x, P.FS // g, fs // g)
    return np.clip(np.round(x), -32768, 32767).astype(np.int64)


def run_file(src, dst, **regs):
    from scipy.io import wavfile
    x = read_wav(src)
    pad = np.zeros(P.N, dtype=np.int64)
    y = PVModel(**regs).run(np.concatenate([x, pad]))
    y = y[P.N - P.H:P.N - P.H + len(x)]
    wavfile.write(dst, P.FS, y.astype(np.int16))
    return y


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser(description='Software phase-vocoder autotune (golden model)')
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--shift', type=float, default=0.0, help='manual shift in semitones')
    ap.add_argument('--no-autotune', action='store_true')
    a = ap.parse_args()
    run_file(a.src, a.dst, manual_ratio=int(round(2 ** (a.shift / 12) * 65536)),
             autotune_en=0 if a.no_autotune else 1)
    print('wrote', a.dst)
