"""PYNQ driver for the phase-vocoder autotune overlay (pv_autotune.bit / .hwh).

    from pv_overlay import PVAutotune
    pv = PVAutotune()               # downloads the bitstream and configures the codec
    pv.set_mode('line')             # 'mic' | 'line' | 'file'
    pv.set_key('A', 'minor')        # autotune scale
    pv.set_shift(3)                 # +3 semitones on top
    print(pv.telemetry())

Mirrors Gaydecki's platform split: the PL is the real-time DSP core, and this
host software configures its processing blocks and downloads filter designs
(frequency-sampling method) to it.
"""
import os
import threading
import time

import numpy as np

import pv_params as P
from adau1761 import ADAU1761, AxiIicMaster

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BIT = os.path.join(HERE, '..', 'overlay', 'pv_autotune.bit')

# pv_audio_top register map (see hw/rtl/pv_audio_top.v)
CTRL, STATUS, SAMPLE_CNT, FRAME_CNT = 0x00, 0x04, 0x08, 0x0C
MANUAL_RATIO, ALPHA, PEAK_THR, VOICE_THR, GATE_THR, OUT_GAIN, KRANGE, NOTE_CNT = (
    0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C)
DET_F0, DET_TARGET, DET_RATIO, LEVELS, CAPTURE_LEN = 0x30, 0x34, 0x38, 0x3C, 0x40
UNDERFLOW_CNT, DMA_IN_CNT, DMA_STARVE_CNT, CAPTURE_CNT = 0x44, 0x48, 0x4C, 0x50
DET_LEVEL, DET_BIN, OVERRUN_CNT, RAW_L, RAW_R, CAPTURE_DROP, VERSION = 0x54, 0x58, 0x5C, 0x60, 0x64, 0x68, 0x7C
NOTE_TABLE, EQ_TABLE = 0x1000, 0x2000
PV_BASE = 0x43C00000   # pv_audio_top sits outside the block design, on the PV_AXI port

C_DSP, C_AUTOTUNE, C_SRC_DMA, C_EQ, C_GATE, C_MUTE = 1 << 0, 1 << 1, 1 << 2, 1 << 3, 1 << 4, 1 << 5
C_SOFT_RESET, C_CAP_ARM, C_CAP_WAIT_DMA = 1 << 8, 1 << 9, 1 << 10

MODES = {
    'mic':  'Microphone (HP+MIC jack) -> headphones/speaker (HP+MIC jack)',
    'line': 'Laptop audio (LINE IN jack) -> headphones/speaker (HP+MIC jack)',
    'file': 'Uploaded audio file (DMA) -> headphones/speaker (HP+MIC jack)',
}
HOP_MS = 1000.0 * P.H / P.FS


def set_fclk0(mhz=100.0):
    """Force the PL clock to 100 MHz (MCLK = FCLK0/10 must be 10.000 MHz for 48 kHz).

    The first bitstream's .hwh carries FCLK dividers computed for a 33.3 MHz PS
    crystal; the PYNQ-Z2 has 50 MHz, which gave 62.5 MHz. Setting the frequency
    here makes PYNQ compute the dividers from the real PLL."""
    from pynq.ps import Clocks
    Clocks.fclk0_mhz = mhz
    time.sleep(0.05)                       # let MCLK settle before the codec PLL locks to it
    return Clocks.fclk0_mhz


def core_base(ip_dict):
    return ip_dict['pv_audio_top_0']['phys_addr'] if 'pv_audio_top_0' in ip_dict else PV_BASE


def note_name(midi):
    return f'{P.NOTE_NAMES[int(midi) % 12]}{int(midi) // 12 - 1}'


class PVAutotune:
    def __init__(self, bitfile=DEFAULT_BIT, download=True):
        from pynq import MMIO, Overlay
        self.ol = Overlay(os.path.abspath(bitfile), download=download)
        self.fclk_mhz = set_fclk0()
        ip = self.ol.ip_dict
        self.regs = MMIO(core_base(ip), 0x4000)
        self.dma = self.ol.axi_dma_0
        version = self.regs.read(VERSION)
        if version >> 16 != 0x5056:
            raise RuntimeError(f'unexpected core version 0x{version:08X} - wrong bitstream?')
        self.iic = AxiIicMaster(MMIO(ip['axi_iic_0']['phys_addr'], 0x1000))
        time.sleep(0.01)                       # MCLK is running from the PL
        self.codec = ADAU1761(self.iic)
        self.codec.init()

        self.ctrl = C_DSP | C_AUTOTUNE
        self.mode = None
        self.settings = dict(key='C', scale='chromatic', a4=440.0, retune_ms=20.0, shift=0.0,
                             autotune=True, dsp=True, eq=False, gate=False, mute=False,
                             gain_db=0.0, hp_db=0.0, mic_gain_db=21.0, line_gain_db=0.0,
                             in_ch='L+R', gate_thr=48, eq_design=dict(type='flat'))
        self._file = None                      # (samples int16, name)
        self._play = None                      # playback state dict
        self._lock = threading.Lock()
        self._write_ctrl()
        self.set_key('C', 'chromatic')
        self.set_retune_speed(self.settings['retune_ms'])
        self.set_eq_design(type='flat')
        self.set_mode('line')

    # ------------------------------------------------------------ low level
    def _w(self, off, val):
        self.regs.write(off, int(val) & 0xFFFFFFFF)

    def _r(self, off):
        return self.regs.read(off)

    def _write_ctrl(self, pulse=0):
        ch = {'L+R': 0, 'L': 1, 'R': 2}[self.settings.get('in_ch', 'L+R')]
        self._w(CTRL, self.ctrl | (ch << 6) | pulse)

    def _set_bit(self, bit, on):
        self.ctrl = (self.ctrl | bit) if on else (self.ctrl & ~bit)
        self._write_ctrl()

    # ---------------------------------------------------------------- modes
    def set_mode(self, mode):
        """'mic': HP+MIC mic in, 'line': LINE IN, 'file': uploaded file via DMA. Output is always HP+MIC."""
        if mode not in MODES:
            raise ValueError(f'mode must be one of {list(MODES)}')
        if mode != 'file':
            self.stop_file()
        if mode == 'mic':
            self.codec.select_mic(self.settings['mic_gain_db'])
        elif mode == 'line':
            self.codec.select_line_in(self.settings['line_gain_db'])
        self._set_bit(C_SRC_DMA, mode == 'file')
        self.mode = mode

    # ------------------------------------------------------ processing blocks
    def set_dsp(self, on):
        """False = dry bypass (input straight to output) for A/B comparison."""
        self.settings['dsp'] = bool(on)
        self._set_bit(C_DSP, on)

    def set_autotune(self, on):
        self.settings['autotune'] = bool(on)
        self._set_bit(C_AUTOTUNE, on)

    def set_key(self, key='C', scale='chromatic', a4=440.0):
        notes, uppers, _ = P.note_table(key, scale, a4)
        for i, (nf, up) in enumerate(zip(notes, uppers)):
            self._w(NOTE_TABLE + 8 * i, nf)
            self._w(NOTE_TABLE + 8 * i + 4, up)
        self._w(NOTE_CNT, len(notes))
        self.settings.update(key=key, scale=scale, a4=float(a4))

    def set_retune_speed(self, ms):
        """Time constant of the pitch correction. 0 = instant ("hard"/robotic)."""
        ms = max(0.0, float(ms))
        alpha = 1.0 if ms < 1e-3 else 1.0 - np.exp(-HOP_MS / ms)
        self._w(ALPHA, min(65536, int(round(alpha * 65536))))
        self.settings['retune_ms'] = ms

    def set_shift(self, semitones):
        """Manual pitch shift on top of autotune, -12..+12 semitones."""
        semitones = max(-12.0, min(12.0, float(semitones)))
        self._w(MANUAL_RATIO, int(round(2 ** (semitones / 12) * P.RATIO_ONE)))
        self.settings['shift'] = semitones

    def set_gate(self, on=None, threshold=None):
        if threshold is not None:
            self.settings['gate_thr'] = int(threshold)
            self._w(GATE_THR, int(threshold))
        if on is not None:
            self.settings['gate'] = bool(on)
            self._set_bit(C_GATE, on)

    def set_eq(self, on):
        self.settings['eq'] = bool(on)
        self._set_bit(C_EQ, on)

    def set_gain(self, db):
        db = max(-40.0, min(12.0, float(db)))
        self._w(OUT_GAIN, min(65535, int(round(10 ** (db / 20) * P.EQ_ONE))))
        self.settings['gain_db'] = db

    def set_mute(self, on):
        self.settings['mute'] = bool(on)
        self._set_bit(C_MUTE, on)

    def set_hp_volume(self, db):
        self.codec.set_hp_volume(db)
        self.settings['hp_db'] = self.codec.hp_volume_db

    def set_input_gain(self, db):
        if self.mode == 'mic':
            self.settings['mic_gain_db'] = float(db)
            self.codec.select_mic(db)
        else:
            self.settings['line_gain_db'] = float(db)
            if self.mode == 'line':
                self.codec.select_line_in(db)

    def set_input_channel(self, ch):
        self.settings['in_ch'] = ch
        self._write_ctrl()

    # --------------------------------------------- frequency-sampling EQ (Gaydecki)
    @staticmethod
    def design_eq(type='flat', f1=300.0, f2=3000.0, gain_db=12.0, bands=None, smooth_bins=4):
        """Desired magnitude response H[k] for k = 0..N/2 (linear gain).

        Gaydecki's frequency-sampling method specifies the filter directly as
        H[k]; the hardware multiplies every STFT bin by it. The transition is
        raised-cosine over `smooth_bins` bins to limit time-domain ringing.
        `bands` = list of (freq_hz, gain_db) for a graphic EQ.
        """
        f = np.arange(P.NBINS) * P.FS / P.N
        g = 10 ** (gain_db / 20)

        def edge(fc, rising):
            w = smooth_bins * P.FS / P.N
            t = np.clip((f - fc) / w + 0.5, 0, 1)
            s = 0.5 - 0.5 * np.cos(np.pi * t)
            return s if rising else 1 - s

        if type == 'flat':
            H = np.ones_like(f)
        elif type == 'lowpass':
            H = edge(f1, False)
        elif type == 'highpass':
            H = edge(f1, True)
        elif type == 'bandpass':
            H = edge(f1, True) * edge(f2, False)
        elif type == 'bandstop':
            H = 1 - edge(f1, True) * edge(f2, False)
        elif type == 'presence':        # voice presence boost between f1 and f2
            H = 1 + (g - 1) * edge(f1, True) * edge(f2, False)
        elif type == 'telephone':
            H = edge(300, True) * edge(3400, False)
        elif type == 'graphic':
            pts = sorted(bands or [(100, 0), (1000, 0), (10000, 0)])
            fx = np.log10([max(p[0], 1) for p in pts])
            H = 10 ** (np.interp(np.log10(np.maximum(f, 1)), fx, [p[1] for p in pts]) / 20)
        else:
            raise ValueError(f'unknown EQ type {type}')
        return np.clip(H, 0, 3.999)

    @staticmethod
    def eq_impulse_response(H, taps=256):
        """Equivalent windowed FIR h[n] = w[n] * IDFT{H} (Gaydecki eq. 4/5), centred."""
        h = np.fft.irfft(H, P.N)
        h = np.roll(h, taps // 2)[:taps]
        return h * np.hanning(taps)

    def set_eq_design(self, **design):
        H = self.design_eq(**design)
        q = np.round(H * P.EQ_ONE).astype(np.int64)
        for k, v in enumerate(q):
            self._w(EQ_TABLE + 4 * k, v)
        self.settings['eq_design'] = design
        self._eq_curve = H
        return H

    # ------------------------------------------------------------ telemetry
    def telemetry(self):
        st = self._r(STATUS)
        f0 = self._r(DET_F0)
        tgt = self._r(DET_TARGET)
        ratio = self._r(DET_RATIO) / P.RATIO_ONE
        lv = self._r(LEVELS)
        voiced = bool(st & 2) and f0 > 0
        f0_hz = P.q14_to_hz(f0) if voiced else 0.0
        tgt_hz = P.q14_to_hz(tgt) if voiced else 0.0
        out = dict(
            mode=self.mode, codec_alive=bool(st & 1), voiced=voiced, primed=bool(st & 16),
            f0_hz=round(f0_hz, 2), target_hz=round(tgt_hz, 2), ratio=round(ratio, 5),
            shift_cents=round(1200 * np.log2(ratio), 1) if ratio > 0 else 0.0,
            in_peak=lv & 0xFFFF, out_peak=lv >> 16,
            in_dbfs=round(20 * np.log10(max(lv & 0xFFFF, 1) / 32768), 1),
            out_dbfs=round(20 * np.log10(max(lv >> 16, 1) / 32768), 1),
            samples=self._r(SAMPLE_CNT), frames=self._r(FRAME_CNT),
            underflows=self._r(UNDERFLOW_CNT), overruns=self._r(OVERRUN_CNT),
        )
        if voiced and f0_hz > 0:
            midi = 69 + 12 * np.log2(f0_hz / self.settings['a4'])
            out['note'] = note_name(round(midi))
            out['cents'] = round(100 * (midi - round(midi)), 1)
            if tgt_hz > 0:
                out['target_note'] = note_name(round(69 + 12 * np.log2(tgt_hz / self.settings['a4'])))
        out['file'] = self.file_status()
        return out

    def diagnostics(self):
        """Raw registers for debugging the codec link."""
        return dict(version=hex(self._r(VERSION)), ctrl=hex(self._r(CTRL)), status=hex(self._r(STATUS)),
                    samples=self._r(SAMPLE_CNT), raw_l=self._r(RAW_L), raw_r=self._r(RAW_R),
                    codec_i2c_addr=hex(self.codec.address))

    # ------------------------------------------------------ file playback (DMA)
    def load_file(self, samples, name='upload'):
        x = np.clip(np.round(np.asarray(samples, dtype=np.float64)), -32768, 32767).astype(np.int16)
        self._file = (x, name)
        return dict(name=name, samples=len(x), seconds=round(len(x) / P.FS, 2))

    def play_file(self, capture=True):
        """Stream the loaded file through the DSP to the HP+MIC jack; capture the result."""
        from pynq import allocate
        if self._file is None:
            raise RuntimeError('no file loaded')
        self.stop_file()
        if self.mode != 'file':
            self.set_mode('file')
        x, name = self._file
        n = len(x)
        total = n + 2 * P.N                     # zero tail flushes the vocoder pipeline
        src = allocate(shape=(total,), dtype=np.int32)
        src[:n] = x
        src[n:] = 0
        dst = allocate(shape=(n,), dtype=np.int32) if capture else None
        if hasattr(src, 'flush'):
            src.flush()
        with self._lock:
            self._play = dict(name=name, n=n, total=total, src=src, dst=dst, t0=time.time(),
                              start_cnt=self._r(DMA_IN_CNT), done=False, result=None)
        if capture:
            self._w(CAPTURE_LEN, n)
            self.dma.recvchannel.transfer(dst)
            self._write_ctrl(C_CAP_ARM | C_CAP_WAIT_DMA)
        self.dma.sendchannel.transfer(src)
        threading.Thread(target=self._watch_playback, daemon=True).start()

    def _watch_playback(self):
        p = self._play
        while p is self._play and not p['done']:
            send_done = self.dma.sendchannel.idle
            recv_done = p['dst'] is None or self.dma.recvchannel.idle
            if send_done and recv_done:
                if p['dst'] is not None:
                    if hasattr(p['dst'], 'invalidate'):
                        p['dst'].invalidate()
                    p['result'] = np.array(p['dst'], dtype=np.int32).astype(np.int16)
                p['done'] = True
                self._free(p)
                break
            time.sleep(0.05)

    @staticmethod
    def _free(p):
        for k in ('src', 'dst'):
            b = p.get(k)
            if b is not None and hasattr(b, 'freebuffer'):
                try:
                    b.freebuffer()
                except Exception:
                    pass
            p[k] = None

    def stop_file(self):
        p = self._play
        if p is None or p['done']:
            return
        # Halt and reset the DMA (both channels), then disarm the capture.
        p['done'] = True
        dma_regs = self.dma.mmio
        dma_regs.write(0x00, 0x4)               # MM2S_DMACR.Reset (resets the whole core)
        t0 = time.time()
        while dma_regs.read(0x00) & 0x4 and time.time() - t0 < 0.1:
            time.sleep(0.001)
        self.dma.sendchannel.start()
        self.dma.recvchannel.start()
        self._w(CAPTURE_LEN, 0)
        self._write_ctrl(C_CAP_ARM)
        self._free(p)

    def file_status(self):
        p = self._play
        loaded = None if self._file is None else dict(name=self._file[1], seconds=round(len(self._file[0]) / P.FS, 2))
        if p is None:
            return dict(loaded=loaded, playing=False, progress=0.0, has_result=False)
        played = (self._r(DMA_IN_CNT) - p['start_cnt']) & 0xFFFFFFFF
        return dict(loaded=loaded, playing=not p['done'], progress=round(min(1.0, played / p['n']), 3),
                    has_result=p['result'] is not None, name=p['name'])

    def processed(self):
        p = self._play
        return None if p is None else p['result']
