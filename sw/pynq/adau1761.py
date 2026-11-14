"""ADAU1761 codec driver for the PYNQ-Z2, talking I2C through the AXI IIC block in the PL.

On the PYNQ-Z2 the codec's I2C pins (SCL=U9, SDA=T9) are wired to the FPGA
fabric, not to the ARM, so /dev/i2c-* cannot reach it. (That is why the
previous design got [Errno 110] and stayed silent.) The overlay contains an
AXI IIC controller on those pins. This module drives it directly through
MMIO in "dynamic controller" mode, so no Linux driver or device tree is needed.

Clocking matches the PYNQ base overlay: the PL sends a 10 MHz MCLK, the codec
PLL makes 49.152 MHz, and the codec is I2S master at 48 kHz.
"""
import time


class I2CError(RuntimeError):
    pass


class AxiIicMaster:
    """Minimal polled driver for Xilinx AXI IIC (PG090) in dynamic mode."""
    ISR, SOFTR, CR, SR, TX_FIFO, RX_FIFO, RX_OCY, RX_PIRQ = 0x20, 0x40, 0x100, 0x104, 0x108, 0x10C, 0x118, 0x120
    SR_BB, SR_RX_EMPTY, SR_TX_EMPTY = 0x04, 0x40, 0x80
    ISR_ARB_LOST, ISR_TX_ERR = 0x01, 0x02

    def __init__(self, mmio, timeout=0.05):
        self.mmio = mmio
        self.timeout = timeout
        self.reset()

    def reset(self):
        self.mmio.write(self.SOFTR, 0xA)
        time.sleep(0.001)
        self.mmio.write(self.RX_PIRQ, 0x0F)
        self.mmio.write(self.CR, 0x02)          # reset TX FIFO
        self.mmio.write(self.CR, 0x01)          # enable, dynamic mode

    def _clear_isr(self):
        self.mmio.write(self.ISR, self.mmio.read(self.ISR))      # toggle-on-write

    def _wait_idle(self):
        t0 = time.time()
        while self.mmio.read(self.SR) & self.SR_BB:
            if time.time() - t0 > self.timeout:
                raise I2CError(f'bus stays busy (SR=0x{self.mmio.read(self.SR):02X}): '
                               'SCL/SDA held low - wrong pins or no pull-ups?')
            time.sleep(0.0002)

    def status(self):
        return dict(SR=self.mmio.read(self.SR), ISR=self.mmio.read(self.ISR))

    def probe(self, addr7):
        """True if a device ACKs its address (a 1-byte write, harmless for the ADAU1761)."""
        try:
            self.write(addr7, [0x40])
            return True
        except I2CError:
            return False

    def scan(self):
        return [a for a in range(0x08, 0x78) if self.probe(a)]

    def _wait_done(self, what):
        t0 = time.time()
        while True:
            sr = self.mmio.read(self.SR)
            isr = self.mmio.read(self.ISR)
            if isr & (self.ISR_TX_ERR | self.ISR_ARB_LOST):
                self.reset()
                raise I2CError(f'{what}: no ACK from device (ISR=0x{isr:02X})')
            if not (sr & self.SR_BB) and (sr & self.SR_TX_EMPTY):
                return
            if time.time() - t0 > self.timeout:
                self.reset()
                raise I2CError(f'{what}: timeout (SR=0x{sr:02X}) - is the overlay loaded?')
            time.sleep(0.0002)

    def write(self, addr7, data):
        data = bytes(data)
        self._wait_idle()
        self._clear_isr()
        self.mmio.write(self.CR, 0x03)
        self.mmio.write(self.CR, 0x01)
        self.mmio.write(self.TX_FIFO, 0x100 | (addr7 << 1))
        for b in data[:-1]:
            self.mmio.write(self.TX_FIFO, b)
        self.mmio.write(self.TX_FIFO, 0x200 | data[-1])
        self._wait_done(f'write to 0x{addr7:02X}')

    def write_read(self, addr7, wdata, n):
        """Write wdata, repeated START, read n bytes."""
        self._wait_idle()
        self._clear_isr()
        self.mmio.write(self.CR, 0x03)
        self.mmio.write(self.CR, 0x01)
        self.mmio.write(self.TX_FIFO, 0x100 | (addr7 << 1))
        for b in bytes(wdata):
            self.mmio.write(self.TX_FIFO, b)
        self.mmio.write(self.TX_FIFO, 0x100 | (addr7 << 1) | 1)
        self.mmio.write(self.TX_FIFO, 0x200 | n)
        out = []
        t0 = time.time()
        while len(out) < n:
            if not (self.mmio.read(self.SR) & self.SR_RX_EMPTY):
                out.append(self.mmio.read(self.RX_FIFO) & 0xFF)
                continue
            # The controller may flag a "transmit error" when the master NACKs the
            # last read byte, so only treat it as a failure once the bus is idle
            # and no data is left to collect.
            sr = self.mmio.read(self.SR)
            if (self.mmio.read(self.ISR) & (self.ISR_TX_ERR | self.ISR_ARB_LOST)) and not (sr & self.SR_BB)                     and (sr & self.SR_RX_EMPTY):
                self.reset()
                raise I2CError(f'read from 0x{addr7:02X}: no ACK (got {len(out)}/{n} bytes)')
            if time.time() - t0 > self.timeout:
                self.reset()
                raise I2CError(f'read from 0x{addr7:02X}: timeout')
        return bytes(out)


# ADAU1761 register addresses
R0_CLOCK, R1_PLL = 0x4000, 0x4002
R4_REC_MIX_L0, R5_REC_MIX_L1, R6_REC_MIX_R0, R7_REC_MIX_R1 = 0x400A, 0x400B, 0x400C, 0x400D
R8_DIFF_VOL_L, R9_DIFF_VOL_R, R10_MIC_BIAS = 0x400E, 0x400F, 0x4010
R15_SERIAL_0, R16_SERIAL_1, R17_CONVERTER_0 = 0x4015, 0x4016, 0x4017
R19_ADC_CTRL, R20_ADC_VOL_L, R21_ADC_VOL_R = 0x4019, 0x401A, 0x401B
R22_PLAY_MIX_L0, R23_PLAY_MIX_L1, R24_PLAY_MIX_R0, R25_PLAY_MIX_R1 = 0x401C, 0x401D, 0x401E, 0x401F
R26_PLAY_LR_L, R27_PLAY_LR_R = 0x4020, 0x4021
R29_HP_L, R30_HP_R, R31_LINE_L, R32_LINE_R = 0x4023, 0x4024, 0x4025, 0x4026
R35_PLAY_POWER, R36_DAC_CTRL = 0x4029, 0x402A
R58_SER_IN_ROUTE, R59_SER_OUT_ROUTE, R64_SER_SAMPLING = 0x40F2, 0x40F3, 0x40F8
R65_CLK_EN0, R66_CLK_EN1 = 0x40F9, 0x40FA


class ADAU1761:
    def __init__(self, iic, address=None):
        self.iic = iic
        self.address = address if address is not None else self.probe()
        self.hp_volume_db = 0.0

    def probe(self):
        """The PL drives ADDR1:0 = 11 (0x3B); also try the other three codec addresses."""
        for a in (0x3B, 0x38, 0x39, 0x3A):
            if self.iic.probe(a):
                return a
        raise I2CError('ADAU1761 not found on the PL I2C bus (no ACK at 0x38-0x3B)')

    # ------------------------------------------------------------- raw access
    def write(self, reg, *values):
        self.iic.write(self.address, [reg >> 8, reg & 0xFF] + list(values))

    def read(self, reg, n=1):
        return self.iic.write_read(self.address, [reg >> 8, reg & 0xFF], n)

    # ------------------------------------------------------------------ setup
    def init(self):
        # PLL: 10 MHz MCLK * (4 + 572/625) = 49.152 MHz = 1024 * 48 kHz.
        # The PLL must be disabled while it is reprogrammed, which matters when the
        # codec is still running from a previous session and MCLK has just been
        # interrupted by reloading the bitstream.
        pll = [0x02, 0x71, 0x02, 0x3C, 0x21]
        last = None
        for attempt in range(4):
            self.write(R0_CLOCK, 0x00)                          # core clock off
            self.write(R1_PLL, *pll, 0x00)                      # PLL disabled
            time.sleep(0.005)
            self.write(R0_CLOCK, 0x0E)                          # PLL as source, core still off
            self.write(R1_PLL, *pll, 0x01)                      # enable
            t0 = time.time()
            while time.time() - t0 < 0.5:
                last = self.read(R1_PLL, 6)
                if last[5] & 0x02:
                    break
                time.sleep(0.005)
            if last is not None and last[5] & 0x02:
                break
        else:
            raise I2CError('ADAU1761 PLL did not lock after 4 attempts (R1 = '
                           + ' '.join(f'{b:02X}' for b in last) + ') - is MCLK (pin U5) running?')
        self.write(R0_CLOCK, 0x0F)                              # core clock on

        self.write(R15_SERIAL_0, 0x01)      # serial port master (drives BCLK/LRCLK)
        self.write(R16_SERIAL_1, 0x00)      # 64 BCLK per frame, I2S
        self.write(R17_CONVERTER_0, 0x00)   # 48 kHz
        self.write(R64_SER_SAMPLING, 0x00)  # 48 kHz
        self.write(R19_ADC_CTRL, 0x23)      # both ADCs on, high-pass filter (removes DC)
        self.write(R20_ADC_VOL_L, 0x00)
        self.write(R21_ADC_VOL_R, 0x00)
        self.write(R22_PLAY_MIX_L0, 0x21)   # left DAC -> left playback mixer
        self.write(R23_PLAY_MIX_L1, 0x00)
        self.write(R24_PLAY_MIX_R0, 0x41)   # right DAC -> right playback mixer
        self.write(R25_PLAY_MIX_R1, 0x00)
        self.write(R26_PLAY_LR_L, 0x05)
        self.write(R27_PLAY_LR_R, 0x11)
        self.write(R31_LINE_L, 0xE6)
        self.write(R32_LINE_R, 0xE6)
        self.write(R35_PLAY_POWER, 0x03)
        self.write(R36_DAC_CTRL, 0x03)
        self.write(R58_SER_IN_ROUTE, 0x01)  # serial input -> DACs
        self.write(R59_SER_OUT_ROUTE, 0x01) # ADCs -> serial output
        self.write(R65_CLK_EN0, 0x7F)
        self.write(R66_CLK_EN1, 0x03)
        self.set_hp_volume(self.hp_volume_db)
        self.select_line_in()

    # ----------------------------------------------------------------- inputs
    def select_line_in(self, gain_db=0):
        """LINE IN jack -> LAUX/RAUX -> record mixers. gain -12..+6 dB in 3 dB steps."""
        code = max(1, min(7, int(round(gain_db / 3)) + 5))
        self.write(R10_MIC_BIAS, 0x00)
        self.write(R8_DIFF_VOL_L, 0x00)
        self.write(R9_DIFF_VOL_R, 0x00)
        self.write(R4_REC_MIX_L0, 0x01)
        self.write(R5_REC_MIX_L1, code)
        self.write(R6_REC_MIX_R0, 0x01)
        self.write(R7_REC_MIX_R1, code)

    def select_mic(self, gain_db=21):
        """HP+MIC jack microphone -> differential PGA (+20 dB boost) with mic bias."""
        vol = max(0, min(63, int(round((gain_db + 12) / 0.75))))
        self.write(R10_MIC_BIAS, 0x01)                 # mic bias on
        self.write(R4_REC_MIX_L0, 0x01)
        self.write(R5_REC_MIX_L1, 0x10)                # LDBOOST = +20 dB
        self.write(R8_DIFF_VOL_L, (vol << 2) | 0x03)   # unmute + enable
        self.write(R6_REC_MIX_R0, 0x01)
        self.write(R7_REC_MIX_R1, 0x10)
        self.write(R9_DIFF_VOL_R, (vol << 2) | 0x03)

    # ---------------------------------------------------------------- outputs
    def set_hp_volume(self, db):
        """Headphone amplifier gain on the HP+MIC jack, -57..+6 dB in 1 dB steps."""
        self.hp_volume_db = max(-57.0, min(6.0, float(db)))
        code = int(round(self.hp_volume_db)) + 57
        self.write(R29_HP_L, (code << 2) | 0x03)       # unmute, HP enable
        self.write(R30_HP_R, (code << 2) | 0x03)       # unmute, headphone mode

    def set_analog_bypass(self, on):
        """Diagnostic: route the record mixers straight to the headphones (no FPGA)."""
        self.write(R23_PLAY_MIX_L1, 0x06 if on else 0x00)
        self.write(R25_PLAY_MIX_R1, 0x60 if on else 0x00)
