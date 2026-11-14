"""Step-by-step hardware check for the PYNQ-Z2 autotune overlay.

    python3 diag.py               # run all checks
    python3 diag.py --analog      # also try the codec's analog bypass (no FPGA in the path)

Each step depends on the one before. The first FAIL tells you which layer is broken:
  1 overlay loads + core registers  -> bitstream / .hwh
  2 codec answers on PL I2C         -> AXI IIC, pins U9/T9, address pins M17/M18
  3 codec PLL locks                 -> 10 MHz MCLK on U5
  4 I2S clocks reach the FPGA       -> codec master mode, pins R18/T17
  5 ADC data arrives                -> input routing / cable / F17
  6 DSP frames run, no underflows   -> phase-vocoder core
"""
import argparse
import sys
import time

sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import pv_overlay as po  # noqa: E402


def step(n, name, ok, detail=''):
    print(f'[{n}] {name:38s} {"PASS" if ok else "FAIL"}  {detail}')
    if not ok:
        sys.exit(1)


# Candidate record-mixer routings (R4/R6 = mixer 0, R5/R7 = mixer 1, R8/R9 = diff PGA).
ROUTES = [
    ('AUX inputs LAUX/RAUX (default line-in)', dict(r4=0x01, r5=0x05, r8=0x00)),
    ('single-ended LINP/RINP',                 dict(r4=0x51, r5=0x00, r8=0x00)),
    ('single-ended LINN/RINN',                 dict(r4=0x0B, r5=0x00, r8=0x00)),
    ('differential PGA, 0 dB (mic path)',      dict(r4=0x01, r5=0x08, r8=0x43)),
]


def try_routes(codec, regs):
    import adau1761 as A
    print('    Routing test: keep the audio playing at a normal volume ...')
    best = None
    for name, r in ROUTES:
        codec.write(A.R10_MIC_BIAS, 0x00)
        codec.write(A.R8_DIFF_VOL_L, r['r8']); codec.write(A.R9_DIFF_VOL_R, r['r8'])
        codec.write(A.R4_REC_MIX_L0, r['r4']); codec.write(A.R6_REC_MIX_R0, r['r4'])
        codec.write(A.R5_REC_MIX_L1, r['r5']); codec.write(A.R7_REC_MIX_R1, r['r5'])
        time.sleep(0.3)
        peak = 0
        for _ in range(12):
            time.sleep(0.25)
            peak = max(peak, regs.read(po.LEVELS) & 0xFFFF)
        print(f'    {name:42s} input peak {peak:6d} / 32767')
        if best is None or peak > best[1]:
            best = (name, peak)
    print(f'    -> strongest: {best[0]}')
    codec.select_line_in()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', default='line', choices=['line', 'mic'])
    ap.add_argument('--analog', action='store_true')
    ap.add_argument('--routes', action='store_true',
                    help='try each codec input routing while you play audio and report its level')
    a = ap.parse_args()

    from pynq import MMIO, Overlay
    from adau1761 import ADAU1761, AxiIicMaster, I2CError
    ol = Overlay(po.DEFAULT_BIT)
    fclk = po.set_fclk0()
    print(f'    PL clock FCLK0 = {fclk:.3f} MHz (needs 100 for a 10 MHz codec MCLK)')
    regs = MMIO(po.core_base(ol.ip_dict), 0x4000)
    v = regs.read(po.VERSION)
    step(1, 'overlay + core registers', v >> 16 == 0x5056, f'version 0x{v:08X}')

    iic = AxiIicMaster(MMIO(ol.ip_dict['axi_iic_0']['phys_addr'], 0x1000))
    try:
        codec = ADAU1761(iic)
        step(2, 'ADAU1761 answers on PL I2C', True, f'address 0x{codec.address:02X}')
    except I2CError as e:
        st = iic.status()
        print(f'    AXI IIC status: SR=0x{st["SR"]:02X} ISR=0x{st["ISR"]:02X}'
              f'  (bus {"BUSY - lines held low" if st["SR"] & 0x04 else "idle"})')
        try:
            found = iic.scan()
            print('    I2C scan 0x08-0x77: ' + (', '.join(f'0x{a:02X}' for a in found) or 'no device answered'))
        except I2CError as e2:
            print(f'    I2C scan failed: {e2}')
        step(2, 'ADAU1761 answers on PL I2C', False, str(e))
    try:
        codec.init()
        step(3, 'codec PLL lock + configuration', True)
    except I2CError as e:
        step(3, 'codec PLL lock + configuration', False, str(e))

    codec.select_mic() if a.mode == 'mic' else codec.select_line_in()
    s0 = regs.read(po.SAMPLE_CNT)
    time.sleep(0.5)
    s1 = regs.read(po.SAMPLE_CNT)
    rate = (s1 - s0) * 2
    step(4, 'I2S clocks from codec', 40000 < rate < 56000, f'{rate} samples/s (expect 48000)')

    print(f'    play something into the {"HP+MIC microphone" if a.mode == "mic" else "LINE IN jack"} now ...')
    peak = 0
    for _ in range(20):
        time.sleep(0.25)
        peak = max(peak, regs.read(po.LEVELS) & 0xFFFF)
    step(5, 'audio arriving from ADC', peak > 30, f'input peak {peak} / 32767')

    f0 = regs.read(po.FRAME_CNT)
    time.sleep(1)
    fr = regs.read(po.FRAME_CNT) - f0
    uf = regs.read(po.UNDERFLOW_CNT)
    out_peak = regs.read(po.LEVELS) >> 16
    step(6, 'DSP frames running', 85 < fr < 100 and uf <= 2,
         f'{fr} frames/s (expect 93.75), underflows {uf}, output peak {out_peak}')

    if a.routes:
        try_routes(codec, regs)

    if a.analog:
        codec.set_analog_bypass(True)
        input('    analog bypass ON: you should hear the input directly. Press Enter to turn it off ...')
        codec.set_analog_bypass(False)
    print('All checks passed. Start the GUI with:  python3 pv_server.py')


if __name__ == '__main__':
    main()
