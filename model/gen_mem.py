"""Generate the ROM initialisation files used by the RTL ($readmemh).

Usage:  python model/gen_mem.py            (writes into hw/mem/)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'sw', 'pynq'))
import pv_params as P  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'hw', 'mem')


def write(name, values, width_bits):
    digits = (width_bits + 3) // 4
    mask = (1 << width_bits) - 1
    with open(os.path.join(OUT, name), 'w') as f:
        for v in values:
            f.write(f'{int(v) & mask:0{digits}X}\n')


def main():
    os.makedirs(OUT, exist_ok=True)
    write('win_analysis.mem', P.analysis_window(), 16)
    write('win_synthesis.mem', P.synthesis_window(), 16)
    c, s = P.twiddles()
    write('twiddle.mem', [((int(ci) & 0x3FFFF) << 18) | (int(si) & 0x3FFFF) for ci, si in zip(c, s)], 36)
    notes, uppers, _ = P.note_table()
    pad = P.NOTE_SLOTS - len(notes)
    write('note_freq.mem', notes + [0] * pad, 32)
    write('note_upper.mem', uppers + [0x7FFFFFFF] * pad, 32)
    write('eq_unity.mem', [P.EQ_ONE] * P.N, 16)
    print(f'wrote ROMs to {os.path.abspath(OUT)} (default note table: {len(notes)} chromatic notes)')


if __name__ == '__main__':
    main()
