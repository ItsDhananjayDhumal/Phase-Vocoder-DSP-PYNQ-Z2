# Autotune in RTL: phase-vocoder pitch correction on the PYNQ-Z2

EE-317 DSP course project (IIT Indore): real-time autotune with a phase vocoder
([PS.pdf](PS.pdf)), using the platform architecture of Gaydecki (2007).
Team: Rohan Jain, Dhananjay Dhumal, Gadgil Rucha Vinay, Karan Hitesh Bagthariya.

```
AutotuneRTLProject.ipynb   phase-1 Python prototype (Mid-Eval)
Mid-Eval/                  mid-evaluation report
model/      golden model (numpy) + ROM generator + model tests
hw/rtl/     Verilog: FFT engine, CORDICs, phase-vocoder core, I2S, AXI top
hw/top/     FPGA top level (block design + core)
hw/sim/     xsim testbenches + run_sim.py (checks RTL against the model)
hw/scripts/ build.tcl (scripted Vivado project, block design, bitstream)
sw/pynq/    board software: codec driver, overlay driver, web GUI, diagnostics
sw/overlay/ pv_autotune.bit + pv_autotune.hwh (build output)
```

## Architecture

The design follows Gaydecki's real-time DSP platform: a hardware DSP core
streams codec audio through a chain of processing blocks, and host software with a
graphical interface switches those blocks on and off and downloads filter designs
to them (FIR via the frequency-sampling method, eq. 4–5 of the paper).

```
ADAU1761 ADC ─I2S─► source mux ─► window+FFT ─► CORDIC ─► pitch detect ─► autotune ─► noise gate ─► EQ ─► CORDIC ─► IFFT ─► OLA ─► gain ─I2S─► ADAU1761 DAC
   (mic / LINE IN)    ▲ DMA (file)                                                                                                     └─► DMA capture
PS (Python) ── AXI-Lite: modes, key/scale table, retune speed, shift, EQ bins, telemetry ── AXI IIC: codec setup
```

PS.pdf steps 3–10 (FFT → CORDIC → pitch detection → tuning ROM → magnitude
interpolation → phase unwrapping → polar→rect → IFFT) run in RTL, and so do
steps 2 and 11 (Hann windowing, 75 % overlap-add), so live audio works too.

| | |
|---|---|
| sample rate | 48 kHz (codec PLL, codec is I2S master) |
| FFT | N = 2048 (23.4 Hz bins), hop 512 (75 % overlap), in-place radix-2, 22.6k cycles |
| per-frame processing | ~52k cycles = 0.52 ms of the 10.7 ms hop budget at 100 MHz |
| pitch detection | lowest strong spectral peak, refined with the phase-vocoder instantaneous frequency (≈0.1 cent accuracy on steady tones) |
| latency, input to output | ~2100 samples ≈ 44 ms |
| resources (core) | ~6.1k LUT, 17 BRAM, 18 DSP |

## Verification (no board needed)

```bash
python model/test_model.py        # algorithm: identity 84 dB, exact shifts, autotune within 0.1 cent
python hw/sim/run_sim.py all       # xsim: FFT vs numpy, core vs model (4 scenarios), top level
```

The top-level testbench includes an ADAU1761 bus model (I2S master), an AXI-Lite
master and DMA stream models. It checks bit-exact I2S loopback, the DSP path at
67 dB against the model, and the file path with hardware-aligned capture.

## Building the bitstream

Vivado 2023.2 fails randomly when the project path is long (>80 characters) or
contains spaces, which is the case for this repo's location. Map it to a short
drive letter first:

```bat
subst P: "C:\Users\Dhananjay Dhumal\Phase Vocoder DSP\Phase-Vocoder-DSP-PYNQ-Z2"
cd /d P:\hw
vivado -mode batch -source scripts/build.tcl
```

The output goes to `sw/overlay/pv_autotune.bit` and `.hwh`. If you change
`sw/pynq/pv_params.py`, re-run `python model/gen_mem.py` first.

The build runs in stages (`-tclargs core|bd|synth|impl` runs one at a time). On
the development PC, Vivado 2023.2 crashed (EXCEPTION_ACCESS_VIOLATION) whenever
the core RTL was synthesised with a clock constraint applied, and it sometimes
fails to read its own files ("couldn't read file …: No error"). So the core is
pre-synthesised unconstrained into a checkpoint, and placement and routing
apply the real constraints. If a stage fails with one of those random read
errors, just rerun that stage. Adding a Windows Defender exclusion for
`C:\Xilinx` and the project folder probably helps.

## Running on the board

Only `sw/` goes to the board. `sw/overlay/` holds the bitstream and `sw/pynq/`
the software; keep them side by side.

From the repo folder on the laptop:
```bash
scp -r sw xilinx@192.168.2.99:/home/xilinx/autotune
```
On the board (`ssh xilinx@192.168.2.99`, default password `xilinx`). PYNQ's
Python lives in a virtual environment and loading bitstreams needs root:
```bash
sudo -i
source /etc/profile.d/pynq_venv.sh
cd /home/xilinx/autotune/pynq
python3 diag.py            # step-by-step hardware check
python3 pv_server.py       # GUI, Ctrl+C to stop
```
Open `http://192.168.2.99:8080` in the laptop browser. Jacks: speaker/headphones
(and headset mic for mode 1) on **HP+MIC**, laptop audio out on **LINE IN** for mode 2.

GUI: three mode buttons (Mic → Speaker, Laptop → Speaker, Audio file → Speaker),
a clickable signal chain (autotune / noise gate / EQ / output, plus dry bypass for
A/B), live note + pitch trace, key/scale/retune speed/±12 st shift, the EQ designer
with its equivalent FIR, level meters, and upload/play/download for files (WAV, any
rate; it's resampled to 48 kHz).

Develop the GUI without the board: `python sw/pynq/pv_server.py --mock`
(file processing then runs through the golden model on the PC).

### If something is silent

`diag.py` stops at the first failing layer:

1. registers: the bitstream/.hwh didn't load
2. I2C: no answer on PL pins U9/T9 (the old design had no I2C in the PL; that was the original "no audio at all" bug)
3. PLL lock: no 10 MHz MCLK on U5
4. I2S clocks: no BCLK/LRCLK from the codec on R18/T17
5. ADC data: wrong jack, cable, or input gain
6. DSP frames: core problem

`python3 diag.py --analog` routes the codec input straight to the
headphones inside the codec, bypassing the FPGA.
