"""Run the RTL testbenches in Vivado xsim and check them against numpy / the golden model.

    python hw/sim/run_sim.py fft            FFT engine vs numpy
    python hw/sim/run_sim.py core           all pv_core scenarios vs model/pv_model.py
    python hw/sim/run_sim.py core shift     one scenario (identity|shift|autotune|eqgate)
    python hw/sim/run_sim.py top            full top level: I2S codec model, AXI-Lite, DMA streams
"""
import os
import shutil
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'model'))
sys.path.insert(0, os.path.join(ROOT, 'sw', 'pynq'))
import pv_params as P  # noqa: E402
from pv_model import PVModel  # noqa: E402

RTL = os.path.join(ROOT, 'hw', 'rtl')
MEM = os.path.join(ROOT, 'hw', 'mem')
WORK = os.path.join(HERE, 'work')
VIVADO_BIN = os.environ.get('VIVADO_BIN', r'C:\Xilinx\Vivado\2023.2\bin')


def tool(name):
    ext = '.bat' if os.name == 'nt' else ''
    return os.path.join(VIVADO_BIN, name + ext)


def sh(cmd):
    r = subprocess.run(cmd, cwd=WORK, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-4000:], r.stderr[-4000:])
        raise SystemExit(f'command failed: {cmd}')
    return r.stdout


def build(top, extra_srcs=()):
    os.makedirs(WORK, exist_ok=True)
    for f in os.listdir(MEM):
        shutil.copy(os.path.join(MEM, f), WORK)
    srcs = [os.path.join(RTL, f) for f in sorted(os.listdir(RTL)) if f.endswith('.v')]
    srcs += [os.path.join(HERE, s) for s in extra_srcs]
    quoted = ' '.join(f'"{s}"' for s in srcs)
    sh(f'"{tool("xvlog")}" -i "{RTL}" {quoted}')
    sh(f'"{tool("xelab")}" {top} -s {top}_sim -timescale 1ns/1ps')


def run(top, plusargs=''):
    out = sh(f'"{tool("xsim")}" {top}_sim -R ' + ' '.join(f'-testplusarg "{a.lstrip("+")}"' for a in plusargs.split()))
    for line in out.splitlines():
        if line.startswith(('FFT', 'frames', 'TOP', 'ERROR', 'PASS', 'FAIL')):
            print('   xsim:', line)
    return out


def write_hex(path, vals, bits):
    m = (1 << bits) - 1
    d = (bits + 3) // 4
    with open(path, 'w') as f:
        for v in vals:
            f.write(f'{int(v) & m:0{d}X}\n')


def snr_db(ref, x):
    e = np.asarray(x, float) - np.asarray(ref, float)
    return 10 * np.log10(np.mean(np.asarray(ref, float) ** 2) / max(np.mean(e ** 2), 1e-12))


# ----------------------------------------------------------------------- FFT
def test_fft():
    rng = np.random.default_rng(1)
    build('tb_fft', ['tb_fft.v'])
    x = rng.integers(-(1 << 19), 1 << 19, P.N) + 1j * rng.integers(-(1 << 19), 1 << 19, P.N)
    write_hex(os.path.join(WORK, 'fft_in.hex'),
              [((int(v.real) & 0xFFFFFF) << 24) | (int(v.imag) & 0xFFFFFF) for v in x], 48)
    X = np.fft.fft(rng.integers(-(1 << 19), 1 << 19, P.N)) / P.N        # a realistic spectrum
    Xi = np.round(X.real) + 1j * np.round(X.imag)
    write_hex(os.path.join(WORK, 'fft_in_inv.hex'),
              [((int(v.real) & 0xFFFFFF) << 24) | (int(v.imag) & 0xFFFFFF) for v in Xi], 48)
    run('tb_fft')

    def load(name):
        a = np.loadtxt(os.path.join(WORK, name))
        return a[:, 0] + 1j * a[:, 1]

    fwd, inv = load('fft_out_fwd.txt'), load('fft_out_inv.txt')
    s1 = snr_db(np.abs(np.fft.fft(x) / P.N), np.abs(fwd)) if False else snr_db_c(np.fft.fft(x) / P.N, fwd)
    s2 = snr_db_c(np.fft.ifft(Xi) * P.N, inv)
    print(f'FFT forward (scaled) : SNR {s1:6.1f} dB, max err {np.max(np.abs(fwd - np.fft.fft(x) / P.N)):.2f} LSB')
    print(f'FFT inverse (unscaled): SNR {s2:6.1f} dB, max err {np.max(np.abs(inv - np.fft.ifft(Xi) * P.N)):.2f} LSB')
    ok = s1 > 70 and s2 > 70
    print('PASS' if ok else 'FAIL')
    return ok


def snr_db_c(ref, x):
    e = x - ref
    return 10 * np.log10(np.mean(np.abs(ref) ** 2) / max(np.mean(np.abs(e) ** 2), 1e-12))


# ---------------------------------------------------------------------- core
def tone(f0, n, amp=8000, harmonics=4):
    t = np.arange(n) / P.FS
    return np.round(sum(amp / h * np.sin(2 * np.pi * f0 * h * t) for h in range(1, harmonics + 1))).astype(np.int64)


SCENARIOS = {
    #            input            model regs                                  plusargs
    'identity': (lambda n: tone(300, n), dict(autotune_en=0), '+AUTOTUNE=0'),
    'shift':    (lambda n: tone(220, n), dict(autotune_en=0, manual_ratio=77935), '+AUTOTUNE=0 +RATIO=77935'),
    'autotune': (lambda n: tone(452, n), dict(autotune_en=1, alpha=0x6000), '+AUTOTUNE=1 +ALPHA=24576'),
    'eqgate':   (lambda n: tone(180, n, harmonics=8) + np.round(300 * np.random.default_rng(3).standard_normal(n)).astype(np.int64),
                 dict(autotune_en=1, eq_en=1, gate_en=1, gate_thr=200), '+AUTOTUNE=1 +EQ=1 +GATE=1 +GATETHR=200'),
}


def eq_lowpass():
    k = np.arange(P.N)
    f = np.minimum(k, P.N - k) * P.FS / P.N
    return np.where(f < 1500, P.EQ_ONE, P.EQ_ONE // 8).astype(np.int64)


def test_core(names=None, built=[False]):
    if not built[0]:
        build('tb_pv_core', ['tb_pv_core.v'])
        built[0] = True
    ok_all = True
    for name in names or SCENARIOS:
        gen, regs, plus = SCENARIOS[name]
        ns = 12 * P.H
        x = np.clip(gen(ns), -32768, 32767)
        write_hex(os.path.join(WORK, 'core_in.hex'), x, 16)
        eq = eq_lowpass()
        write_hex(os.path.join(WORK, 'eq.hex'), eq, 16)
        regs = dict(regs)
        if regs.get('eq_en'):
            regs['eq'] = eq
        model = PVModel(**regs)
        ref = model.run(x)

        run('tb_pv_core', f'+NS={ns} ' + plus)
        push = np.loadtxt(os.path.join(WORK, 'core_push.txt')).astype(np.int64)
        tel = np.loadtxt(os.path.join(WORK, 'core_tel.txt'), ndmin=2).astype(np.int64)
        out = np.loadtxt(os.path.join(WORK, 'core_out.txt')).astype(np.int64)

        n = min(len(push), len(ref))
        s = snr_db(ref[P.N:n], push[P.N:n])
        mt = np.array([(t[0], t[1], t[2], int(t[3])) for t in model.telemetry])
        k = min(len(tel), len(mt))
        f0_err = np.max(np.abs(tel[4:k, 0] - mt[4:k, 0])) if k > 4 else -1
        ratio_err = np.max(np.abs(tel[4:k, 2] - mt[4:k, 2])) if k > 4 else -1
        voiced_match = np.mean(tel[:k, 3] == mt[:k, 3]) if k else 0
        # played-out stream must be the push stream delayed (no gaps, no glitches)
        nz = np.flatnonzero(out)
        lag = None
        if len(nz):
            for L in range(0, 3 * P.H):
                seg = out[L:L + n]
                if len(seg) > 2 * P.H and np.array_equal(seg[:len(seg)], push[:len(seg)]):
                    lag = L
                    break
        ok = s > 45 and voiced_match == 1.0 and lag is not None and 0 <= ratio_err <= 64
        ok_all &= ok
        print(f'core/{name:9s}: {len(push)} samples, RTL vs model SNR {s:5.1f} dB, f0 err {f0_err} (Q.14), '
              f'ratio err {ratio_err}, voiced match {voiced_match:.2f}, playout lag {lag} -> {"PASS" if ok else "FAIL"}')
    return ok_all


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'all'
    ok = True
    if what in ('fft', 'all'):
        ok &= test_fft()
    if what in ('core', 'all'):
        ok &= test_core(sys.argv[2:] or None)
    if what in ('top', 'all'):
        sys.path.insert(0, HERE)
        import run_top  # noqa: E402
        ok &= run_top.test_top(build, run, WORK)
    sys.exit(0 if ok else 1)
