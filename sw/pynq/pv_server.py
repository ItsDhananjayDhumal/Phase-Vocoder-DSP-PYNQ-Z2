"""Web GUI for the PYNQ-Z2 phase-vocoder autotune (stdlib only).

On the board (as root, since PYNQ needs it to load bitstreams):
    python3 pv_server.py                 # then open http://<board-ip>:8080
On a laptop without the board (GUI development, uses the golden model):
    python pv_server.py --mock
"""
import argparse
import io
import json
import math
import os
import struct
import sys
import threading
import time
import traceback
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pv_params as P  # noqa: E402

WEB = os.path.join(HERE, 'web')
MAX_SECONDS = 300


# ------------------------------------------------------------------ WAV I/O
def decode_wav(data):
    """Any PCM (8/16/24/32-bit) or float32/64 WAV -> mono float samples at 48 kHz (int16 scale)."""
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise ValueError('not a WAV file (convert MP3/M4A to .wav first)')
    pos, fmt, raw = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack('<I', data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b'fmt ':
            tag, ch, fs, _, _, bits = struct.unpack('<HHIIHH', body[:16])
            if tag == 0xFFFE and len(body) >= 26:
                tag = struct.unpack('<H', body[24:26])[0]
            fmt = (tag, ch, fs, bits)
        elif cid == b'data':
            raw = body
        pos += 8 + size + (size & 1)
    if fmt is None or raw is None:
        raise ValueError('WAV file has no fmt/data chunk')
    tag, ch, fs, bits = fmt
    if tag == 3:
        x = np.frombuffer(raw[:len(raw) // (bits // 8) * (bits // 8)], dtype='<f4' if bits == 32 else '<f8') * 32767.0
    elif tag == 1 and bits == 8:
        x = (np.frombuffer(raw, dtype=np.uint8).astype(np.float64) - 128) * 256
    elif tag == 1 and bits == 16:
        x = np.frombuffer(raw[:len(raw) // 2 * 2], dtype='<i2').astype(np.float64)
    elif tag == 1 and bits == 24:
        b = np.frombuffer(raw[:len(raw) // 3 * 3], dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        x = (np.where(v >= 1 << 23, v - (1 << 24), v) / 256.0)
    elif tag == 1 and bits == 32:
        x = np.frombuffer(raw[:len(raw) // 4 * 4], dtype='<i4') / 65536.0
    else:
        raise ValueError(f'unsupported WAV encoding (format {tag}, {bits} bit)')
    x = x[:len(x) // ch * ch].reshape(-1, ch).mean(axis=1)
    if len(x) > MAX_SECONDS * fs:
        x = x[:MAX_SECONDS * fs]
    if fs != P.FS:
        try:
            from scipy.signal import resample_poly
            g = math.gcd(int(fs), P.FS)
            x = resample_poly(x, P.FS // g, int(fs) // g)
        except ImportError:
            t = np.arange(int(len(x) * P.FS / fs)) * fs / P.FS
            x = np.interp(t, np.arange(len(x)), x)
    return np.clip(x, -32768, 32767), fs


def encode_wav(x):
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(P.FS)
        w.writeframes(np.asarray(x, dtype='<i2').tobytes())
    return buf.getvalue()


# --------------------------------------------------------------- mock board
class MockBackend:
    """Stands in for PVAutotune on a PC: telemetry is synthesised, files go through the golden model."""

    def __init__(self):
        sys.path.insert(0, os.path.join(HERE, '..', '..', 'model'))
        from pv_overlay import PVAutotune
        self.design_eq = PVAutotune.design_eq
        self.eq_impulse_response = PVAutotune.eq_impulse_response
        self.mode = 'line'
        self.settings = dict(key='C', scale='chromatic', a4=440.0, retune_ms=20.0, shift=0.0,
                             autotune=True, dsp=True, eq=False, gate=False, mute=False,
                             gain_db=0.0, hp_db=0.0, mic_gain_db=21.0, line_gain_db=0.0,
                             in_ch='L+R', gate_thr=48, eq_design=dict(type='flat'))
        self._eq_curve = self.design_eq('flat')
        self._file = None
        self._play = None
        self.t0 = time.time()

    def __getattr__(self, name):            # set_xxx(value) -> settings
        if name.startswith('set_'):
            key = name[4:]

            def setter(*a, **kw):
                if key == 'mode':
                    self.mode = a[0]
                elif key == 'key':
                    self.settings.update(key=a[0], scale=a[1], a4=float(a[2]) if len(a) > 2 else 440.0)
                elif key == 'eq_design':
                    self._eq_curve = self.design_eq(**kw)
                    self.settings['eq_design'] = kw
                elif key == 'gate':
                    if kw.get('on') is not None:
                        self.settings['gate'] = kw['on']
                    if kw.get('threshold') is not None:
                        self.settings['gate_thr'] = kw['threshold']
                else:
                    alias = dict(dsp='dsp', autotune='autotune', retune_speed='retune_ms', shift='shift',
                                 eq='eq', gain='gain_db', mute='mute', hp_volume='hp_db',
                                 input_channel='in_ch', input_gain='line_gain_db')
                    self.settings[alias.get(key, key)] = a[0]
            return setter
        raise AttributeError(name)

    def telemetry(self):
        t = time.time() - self.t0
        sung = 220 * 2 ** ((round(4 * math.sin(t / 3)) + 0.35 * math.sin(7 * t)) / 12)
        tgt = 440 * 2 ** (round(12 * math.log2(sung / 440)) / 12)
        voiced = (t % 6) < 4.5 and self.mode != 'file' or (self._play is not None and not self._play['done'])
        ratio = (tgt / sung if self.settings['autotune'] else 1.0) * 2 ** (self.settings['shift'] / 12)
        midi = 69 + 12 * math.log2(sung / self.settings['a4'])
        lv_in = int(8000 + 6000 * math.sin(3 * t) ** 2) if voiced else 120
        out = dict(mode=self.mode, codec_alive=True, voiced=voiced, primed=True,
                   f0_hz=round(sung, 2) if voiced else 0.0, target_hz=round(tgt, 2) if voiced else 0.0,
                   ratio=round(ratio, 5), shift_cents=round(1200 * math.log2(ratio), 1),
                   in_peak=lv_in, out_peak=0 if self.settings['mute'] else lv_in,
                   in_dbfs=round(20 * math.log10(lv_in / 32768), 1),
                   out_dbfs=round(20 * math.log10(max(lv_in, 1) / 32768), 1),
                   samples=int(t * P.FS), frames=int(t * P.FS / P.H), underflows=0, overruns=0)
        if voiced:
            out['note'] = f"{P.NOTE_NAMES[round(midi) % 12]}{round(midi) // 12 - 1}"
            out['cents'] = round(100 * (midi - round(midi)), 1)
            tm = round(69 + 12 * math.log2(tgt / self.settings['a4']))
            out['target_note'] = f"{P.NOTE_NAMES[tm % 12]}{tm // 12 - 1}"
        out['file'] = self.file_status()
        return out

    def diagnostics(self):
        return dict(version='mock', codec_i2c_addr='0x3B')

    def load_file(self, samples, name='upload'):
        self._file = (np.asarray(samples, dtype=np.int64), name)
        return dict(name=name, samples=len(samples), seconds=round(len(samples) / P.FS, 2))

    def play_file(self, capture=True):
        from pv_model import PVModel
        x, name = self._file
        self.mode = 'file'
        p = dict(name=name, n=len(x), t0=time.time(), done=False, result=None)
        self._play = p

        def work():
            s = self.settings
            m = PVModel(autotune_en=int(s['autotune']), manual_ratio=int(round(2 ** (s['shift'] / 12) * 65536)),
                        eq_en=int(s['eq']), eq=np.round(np.concatenate([self._eq_curve, np.ones(P.N)])[:P.N] * 16384).astype(np.int64),
                        gate_en=int(s['gate']), gate_thr=int(s['gate_thr']),
                        notes=P.note_table(s['key'], s['scale'], s['a4'])[0],
                        uppers=P.note_table(s['key'], s['scale'], s['a4'])[1])
            y = m.run(np.concatenate([x, np.zeros(2 * P.N, dtype=np.int64)]))
            y = y[P.N - P.H:P.N - P.H + len(x)]
            while time.time() - p['t0'] < len(x) / P.FS and not p['done']:
                time.sleep(0.1)
            p['result'] = y.astype(np.int16)
            p['done'] = True
        threading.Thread(target=work, daemon=True).start()

    def stop_file(self):
        if self._play:
            self._play['done'] = True

    def file_status(self):
        p = self._play
        loaded = None if self._file is None else dict(name=self._file[1], seconds=round(len(self._file[0]) / P.FS, 2))
        if p is None:
            return dict(loaded=loaded, playing=False, progress=0.0, has_result=False)
        prog = min(1.0, (time.time() - p['t0']) * P.FS / max(p['n'], 1))
        return dict(loaded=loaded, playing=not p['done'], progress=round(prog if not p['done'] else 1.0, 3),
                    has_result=p['result'] is not None, name=p['name'])

    def processed(self):
        return None if self._play is None else self._play['result']


# ------------------------------------------------------------------- server
class App:
    def __init__(self, backend):
        self.pv = backend
        self.lock = threading.Lock()

    def state(self):
        return dict(settings=self.pv.settings, telemetry=self.pv.telemetry(),
                    modes=['mic', 'line', 'file'], keys=P.NOTE_NAMES, scales=list(P.SCALES),
                    params=dict(fs=P.FS, n=P.N, hop=P.H, latency_ms=round(1000 * (P.N + 600) / P.FS, 1)))

    def apply(self, req):
        pv, s = self.pv, self.pv.settings
        for k, v in req.items():
            if k == 'mode':
                pv.set_mode(v)
            elif k == 'dsp':
                pv.set_dsp(bool(v))
            elif k == 'autotune':
                pv.set_autotune(bool(v))
            elif k in ('key', 'scale', 'a4'):
                pv.set_key(req.get('key', s['key']), req.get('scale', s['scale']), float(req.get('a4', s['a4'])))
            elif k == 'retune_ms':
                pv.set_retune_speed(float(v))
            elif k == 'shift':
                pv.set_shift(float(v))
            elif k == 'gate':
                pv.set_gate(on=bool(v))
            elif k == 'gate_thr':
                pv.set_gate(threshold=int(v))
            elif k == 'eq':
                pv.set_eq(bool(v))
            elif k == 'eq_design':
                pv.set_eq_design(**v)
            elif k == 'gain_db':
                pv.set_gain(float(v))
            elif k == 'mute':
                pv.set_mute(bool(v))
            elif k == 'hp_db':
                pv.set_hp_volume(float(v))
            elif k == 'input_gain_db':
                pv.set_input_gain(float(v))
            elif k == 'in_ch':
                pv.set_input_channel(v)
            else:
                raise ValueError(f'unknown setting {k}')

    def eq_plot(self):
        H = np.asarray(self.pv._eq_curve)
        f = np.arange(len(H)) * P.FS / P.N
        idx = np.unique(np.round(np.geomspace(1, len(H) - 1, 160)).astype(int))
        h = self.pv.eq_impulse_response(H, 256)
        return dict(f=f[idx].round(1).tolist(), db=(20 * np.log10(np.maximum(H[idx], 1e-3))).round(2).tolist(),
                    h=(h / max(np.max(np.abs(h)), 1e-9)).round(4).tolist())


def make_handler(app):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *a):
            pass

        def _send(self, code, body, ctype='application/json', extra=None):
            if isinstance(body, (dict, list)):
                body = json.dumps(body).encode()
            elif isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _body(self):
            n = int(self.headers.get('Content-Length', 0))
            return self.rfile.read(n) if n else b''

        def do_GET(self):
            path = urlparse(self.path).path
            try:
                if path == '/api/state':
                    with app.lock:
                        return self._send(200, app.state())
                if path == '/api/eq':
                    with app.lock:
                        return self._send(200, app.eq_plot())
                if path == '/api/diag':
                    with app.lock:
                        return self._send(200, app.pv.diagnostics())
                if path == '/api/processed.wav':
                    y = app.pv.processed()
                    if y is None:
                        return self._send(404, {'error': 'nothing processed yet'})
                    return self._send(200, encode_wav(y), 'audio/wav',
                                      {'Content-Disposition': 'attachment; filename="processed.wav"'})
                files = {'/': 'index.html', '/index.html': 'index.html', '/app.js': 'app.js', '/style.css': 'style.css'}
                if path in files:
                    ctype = {'html': 'text/html', 'js': 'application/javascript', 'css': 'text/css'}[files[path].split('.')[-1]]
                    with open(os.path.join(WEB, files[path]), 'rb') as f:
                        return self._send(200, f.read(), ctype + '; charset=utf-8')
                self._send(404, {'error': 'not found'})
            except Exception as e:
                traceback.print_exc()
                self._send(500, {'error': str(e)})

        def do_POST(self):
            path = urlparse(self.path).path
            try:
                if path == '/api/set':
                    with app.lock:
                        app.apply(json.loads(self._body() or b'{}'))
                        return self._send(200, app.state())
                if path == '/api/upload':
                    data = self._body()
                    x, fs_in = decode_wav(data)
                    name = os.path.basename(self.headers.get('X-Filename', 'upload.wav'))[:80]
                    with app.lock:
                        info = app.pv.load_file(x, name)
                    info['source_rate'] = fs_in
                    return self._send(200, info)
                if path == '/api/play':
                    with app.lock:
                        app.pv.play_file(capture=True)
                        return self._send(200, app.state())
                if path == '/api/stop':
                    with app.lock:
                        app.pv.stop_file()
                        return self._send(200, app.state())
                self._send(404, {'error': 'not found'})
            except Exception as e:
                traceback.print_exc()
                self._send(400, {'error': str(e)})

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--port', type=int, default=8080)
    ap.add_argument('--mock', action='store_true', help='run without the board (golden model)')
    ap.add_argument('--bit', default=None, help='path to pv_autotune.bit')
    a = ap.parse_args()
    if a.mock:
        backend = MockBackend()
    else:
        from pv_overlay import DEFAULT_BIT, PVAutotune
        print('Loading overlay and configuring the ADAU1761 ...')
        backend = PVAutotune(a.bit or DEFAULT_BIT)
        d = backend.diagnostics()
        t = backend.telemetry()
        print(f"  core {d['version']}, codec at I2C {d['codec_i2c_addr']}, codec clock "
              f"{'OK' if t['codec_alive'] else 'NOT DETECTED'}")
    srv = ThreadingHTTPServer(('0.0.0.0', a.port), make_handler(App(backend)))
    print(f'Autotune GUI on http://0.0.0.0:{a.port}  (open http://<board-ip>:{a.port} on your laptop)')
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
