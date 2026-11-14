"""Shared fixed-point parameters of the phase-vocoder hardware.

Everything here must match hw/rtl/*.v. The RTL testbenches, the golden model,
the ROM generator and the PYNQ driver all import from this one file.
"""
import numpy as np

FS = 48000              # codec sample rate (ADAU1761 PLL from 10 MHz MCLK)
LOGN = 11
N = 1 << LOGN           # FFT size (2048 -> 23.44 Hz bins, good down to ~90 Hz voices)
H = N // 4              # hop size (75 % overlap, as in PS.pdf)
NBINS = N // 2 + 1      # bins 0..N/2 that the spectral stage processes

DW = 24                 # FFT/CORDIC data width (re and im)
TWW = 18                # twiddle width, 1.0 = 2**16
WIN_IN_SHIFT = 12       # FFT input = (x * w_a) >> 12  -> 16 LSBs per input LSB
OUT_SHIFT = 4           # output sample = OLA >> 4
OMEGA_FRAC = 14         # instantaneous frequency in bins, Q.14 (== BAM16 phase advance per hop)
RATIO_ONE = 1 << 16     # Q16.16 pitch ratios
RATIO_MIN = 1 << 15     # 0.5  (-12 semitones)
RATIO_MAX = (1 << 17) - 1  # just under 2.0 (+12 semitones)
EQ_ONE = 1 << 14        # EQ gains are Q2.14
NOTE_SLOTS = 128        # note-table depth

CORDIC_ITER = 18
CORDIC_K = 0.6072529350088812561694
CORDIC_KQ = int(round(CORDIC_K * (1 << 17)))

# Defaults that the RTL also resets to (keep in sync with pv_regs in pv_audio_top.v)
DEFAULT_ALPHA = 0x6000
DEFAULT_PEAK_THR = 0x3000
DEFAULT_VOICE_THR = 400
DEFAULT_GATE_THR = 48
DEFAULT_KMIN = 3
DEFAULT_KMAX = 48


def hann(n=N):
    k = np.arange(n)
    return 0.5 - 0.5 * np.cos(2 * np.pi * k / n)  # periodic Hann


def analysis_window():
    return np.minimum(np.round(hann() * 65536), 65535).astype(np.int64)


def synthesis_window():
    # Sum of hann^2 at 75 % overlap is 1.5, so the synthesis window carries 2/3.
    return np.round(hann() * (2.0 / 3.0) * 65536).astype(np.int64)


def twiddles():
    k = np.arange(N // 2)
    c = np.round(np.cos(2 * np.pi * k / N) * 65536).astype(np.int64)
    s = np.round(np.sin(2 * np.pi * k / N) * 65536).astype(np.int64)
    return c, s


def atan_table(iters=CORDIC_ITER):
    return [int(round(np.arctan(2.0 ** -i) / (2 * np.pi) * 2 ** 32)) for i in range(iters)]


def hz_to_q14(f_hz):
    """Frequency in Hz -> fractional FFT bin in Q.14 (the unit of DET_F0/TARGET)."""
    return int(round(f_hz * N / FS * (1 << OMEGA_FRAC)))


def q14_to_hz(q):
    return q / (1 << OMEGA_FRAC) * FS / N


NOTE_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
SCALES = {
    'chromatic': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
    'major': [0, 2, 4, 5, 7, 9, 11],
    'natural minor': [0, 2, 3, 5, 7, 8, 10],
    'harmonic minor': [0, 2, 3, 5, 7, 8, 11],
    'major pentatonic': [0, 2, 4, 7, 9],
    'minor pentatonic': [0, 3, 5, 7, 10],
    'blues': [0, 3, 5, 6, 7, 10],
    'dorian': [0, 2, 3, 5, 7, 9, 10],
}


def note_table(key='C', scale='chromatic', a4=440.0, midi_lo=24, midi_hi=96):
    """Allowed target notes and their geometric-midpoint upper bounds (both Q.14 bins).

    Hardware picks entry i for the first i with f0 < upper[i]."""
    root = NOTE_NAMES.index(key)
    steps = set((root + s) % 12 for s in SCALES[scale])
    midis = [m for m in range(midi_lo, midi_hi + 1) if m % 12 in steps]
    freqs = [a4 * 2 ** ((m - 69) / 12) for m in midis]
    notes, uppers = [], []
    for i, f in enumerate(freqs):
        notes.append(hz_to_q14(f))
        if i + 1 < len(freqs):
            uppers.append(hz_to_q14(np.sqrt(f * freqs[i + 1])))
        else:
            uppers.append(0x7FFFFFFF)
    assert len(notes) <= NOTE_SLOTS
    return notes, uppers, midis


def bitrev(x, bits=LOGN):
    r = 0
    for _ in range(bits):
        r = (r << 1) | (x & 1)
        x >>= 1
    return r
