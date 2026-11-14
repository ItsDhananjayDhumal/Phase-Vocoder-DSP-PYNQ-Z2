'use strict';
// Front end for pv_server.py: polls /api/state, posts settings to /api/set.

const $ = (id) => document.getElementById(id);
let S = null;                    // last state from the server
let busy = new Set();            // controls the user is dragging (don't overwrite)
const hist = [];                 // pitch trace: {t, f0, out}
const HIST_S = 10;
const NOTE = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const SCALES = {
  'chromatic': [0,1,2,3,4,5,6,7,8,9,10,11], 'major': [0,2,4,5,7,9,11], 'natural minor': [0,2,3,5,7,8,10],
  'harmonic minor': [0,2,3,5,7,8,11], 'major pentatonic': [0,2,4,7,9], 'minor pentatonic': [0,3,5,7,10],
  'blues': [0,3,5,6,7,10], 'dorian': [0,2,3,5,7,9,10],
};

async function api(path, body) {
  const opt = body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

let pending = {}, timer = null;
function set(obj, now) {
  Object.assign(pending, obj);
  clearTimeout(timer);
  timer = setTimeout(flush, now ? 0 : 120);
}
async function flush() {
  const body = pending; pending = {};
  try { S = await api('/api/set', body); render(); } catch (e) { toast(e.message); }
}
function toast(msg) { $('file-msg').textContent = msg; }

// ------------------------------------------------------------------ controls
function bindRange(id, fmt, key) {
  const el = $(id), out = el.parentElement.querySelector('output');
  el.addEventListener('pointerdown', () => busy.add(id));
  el.addEventListener('pointerup', () => setTimeout(() => busy.delete(id), 400));
  el.addEventListener('input', () => { out.textContent = fmt(+el.value); set({ [key || id]: +el.value }); });
}
bindRange('retune_ms', (v) => v === 0 ? 'hard (0 ms)' : `${v} ms`);
bindRange('shift', (v) => `${v > 0 ? '+' : ''}${v} st`);
bindRange('a4', (v) => `${v} Hz`);
bindRange('input_gain_db', (v) => `${v} dB`);
bindRange('gain_db', (v) => `${v > 0 ? '+' : ''}${v} dB`);
bindRange('hp_db', (v) => `${v} dB`);
bindRange('gate_thr', (v) => v);

$('key').addEventListener('change', (e) => set({ key: e.target.value }, true));
$('scale').addEventListener('change', (e) => set({ scale: e.target.value }, true));
$('in_ch').addEventListener('change', (e) => set({ in_ch: e.target.value }, true));
$('mute').addEventListener('change', (e) => set({ mute: e.target.checked }, true));
$('eq-on').addEventListener('change', (e) => set({ eq: e.target.checked }, true));
document.querySelectorAll('.mode').forEach((b) => b.addEventListener('click', () => set({ mode: b.dataset.mode }, true)));
document.querySelectorAll('.blk.tog').forEach((b) => b.addEventListener('click', () => {
  const k = b.dataset.toggle;
  set({ [k]: !S.settings[k] }, true);
}));
$('bypass').addEventListener('click', () => set({ dsp: !S.settings.dsp }, true));

// ----------------------------------------------------------------------- EQ
const EQ_FIELDS = {
  flat: [], telephone: [],
  lowpass: [['f1', 'Cutoff', 100, 12000, 3000]],
  highpass: [['f1', 'Cutoff', 30, 5000, 200]],
  bandpass: [['f1', 'Low edge', 50, 5000, 300], ['f2', 'High edge', 300, 16000, 3400]],
  bandstop: [['f1', 'Low edge', 50, 5000, 900], ['f2', 'High edge', 100, 16000, 1200]],
  presence: [['f1', 'From', 500, 5000, 2000], ['f2', 'To', 1000, 12000, 5000], ['gain_db', 'Boost', 0, 12, 6]],
};
const GRAPHIC = [63, 250, 1000, 2500, 6000, 12000];
let eqDesign = { type: 'flat' };

function buildEqParams() {
  const box = $('eq-params');
  box.innerHTML = '';
  box.className = eqDesign.type === 'graphic' ? 'graphic' : '';
  const add = (key, label, lo, hi, step, val, fmt) => {
    const l = document.createElement('label');
    l.className = 'slider';
    l.innerHTML = `${label} <output>${fmt(val)}</output><input type="range" min="${lo}" max="${hi}" step="${step}" value="${val}">`;
    const inp = l.querySelector('input');
    inp.addEventListener('input', () => {
      l.querySelector('output').textContent = fmt(+inp.value);
      if (key.startsWith('band')) eqDesign.bands[+key.slice(4)][1] = +inp.value; else eqDesign[key] = +inp.value;
      sendEq();
    });
    box.appendChild(l);
  };
  if (eqDesign.type === 'graphic') {
    eqDesign.bands = eqDesign.bands || GRAPHIC.map((f) => [f, 0]);
    eqDesign.bands.forEach(([f, g], i) => add('band' + i, f >= 1000 ? `${f / 1000}k` : `${f}`, -12, 12, 1, g, (v) => `${v} dB`));
  } else {
    for (const [k, label, lo, hi, def] of EQ_FIELDS[eqDesign.type]) {
      if (eqDesign[k] === undefined) eqDesign[k] = def;
      add(k, label, lo, hi, k === 'gain_db' ? 1 : 10, eqDesign[k], (v) => (k === 'gain_db' ? `+${v} dB` : v >= 1000 ? `${(v / 1000).toFixed(1)} kHz` : `${v} Hz`));
    }
  }
}
let eqTimer = null;
function sendEq() {
  clearTimeout(eqTimer);
  eqTimer = setTimeout(async () => {
    try { S = await api('/api/set', { eq_design: eqDesign }); drawEq(); } catch (e) { toast(e.message); }
  }, 150);
}
$('eq-type').addEventListener('change', (e) => {
  eqDesign = { type: e.target.value };
  buildEqParams();
  sendEq();
  if (!S.settings.eq && e.target.value !== 'flat') set({ eq: true }, true);
});

async function drawEq() {
  const d = await api('/api/eq');
  const c = $('eq-plot'), g = c.getContext('2d');
  fit(c);
  const W = c.width, H = c.height, css = getComputedStyle(document.documentElement);
  const x = (f) => (Math.log10(f) - 1.3) / (Math.log10(24000) - 1.3) * W;
  const y = (db) => H / 2 - db / 30 * H;
  g.clearRect(0, 0, W, H);
  g.strokeStyle = css.getPropertyValue('--grid'); g.fillStyle = css.getPropertyValue('--muted');
  g.font = `${10 * devicePixelRatio}px system-ui`;
  for (const f of [50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]) {
    g.beginPath(); g.moveTo(x(f), 0); g.lineTo(x(f), H); g.stroke();
    g.fillText(f >= 1000 ? `${f / 1000}k` : f, x(f) + 3, H - 4);
  }
  for (const db of [-12, 0, 12]) { g.beginPath(); g.moveTo(0, y(db)); g.lineTo(W, y(db)); g.stroke(); g.fillText(`${db} dB`, 3, y(db) - 3); }
  g.strokeStyle = css.getPropertyValue('--accent'); g.lineWidth = 2 * devicePixelRatio; g.beginPath();
  d.f.forEach((f, i) => { const yy = y(Math.max(d.db[i], -15)); i ? g.lineTo(x(f), yy) : g.moveTo(x(f), yy); });
  g.stroke(); g.lineWidth = 1;

  const c2 = $('eq-ir'), g2 = c2.getContext('2d');
  fit(c2);
  g2.clearRect(0, 0, c2.width, c2.height);
  g2.strokeStyle = css.getPropertyValue('--grid'); g2.beginPath(); g2.moveTo(0, c2.height / 2); g2.lineTo(c2.width, c2.height / 2); g2.stroke();
  g2.strokeStyle = css.getPropertyValue('--trace-in'); g2.beginPath();
  d.h.forEach((v, i) => { const xx = i / (d.h.length - 1) * c2.width, yy = c2.height / 2 - v * c2.height * 0.45; i ? g2.lineTo(xx, yy) : g2.moveTo(xx, yy); });
  g2.stroke();
  g2.fillStyle = css.getPropertyValue('--muted'); g2.font = `${10 * devicePixelRatio}px system-ui`;
  g2.fillText('equivalent FIR h[n], 256 taps', 4, 12 * devicePixelRatio);
}

// --------------------------------------------------------------------- file
let uploaded = false;
async function upload(file) {
  $('drop-text').textContent = `Uploading ${file.name} ...`;
  try {
    const r = await fetch('/api/upload', { method: 'POST', headers: { 'X-Filename': file.name }, body: file });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error);
    uploaded = true;
    $('drop-text').textContent = `${j.name} - ${j.seconds} s (${j.source_rate} Hz${j.source_rate !== 48000 ? ', resampled to 48 kHz' : ''})`;
    toast('Ready. Press "Process & play" to stream it through the FPGA.');
  } catch (e) { $('drop-text').textContent = 'Drop a .wav here or choose a file'; toast(e.message); }
}
$('file-in').addEventListener('change', (e) => e.target.files[0] && upload(e.target.files[0]));
const drop = $('drop');
['dragenter', 'dragover'].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add('over'); }));
['dragleave', 'drop'].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
drop.addEventListener('drop', (e) => e.dataTransfer.files[0] && upload(e.dataTransfer.files[0]));
$('play').addEventListener('click', async () => { try { S = await api('/api/play', {}); lastResult = false; render(); } catch (e) { toast(e.message); } });
$('stop').addEventListener('click', async () => { try { S = await api('/api/stop', {}); render(); } catch (e) { toast(e.message); } });

// ------------------------------------------------------------------- render
function fit(c) {
  if (!c.dataset.h) c.dataset.h = c.getAttribute('height');      // CSS height, set once
  const w = Math.round(c.clientWidth * devicePixelRatio), h = Math.round(+c.dataset.h * devicePixelRatio);
  if (c.width !== w || c.height !== h) { c.width = w; c.height = h; c.style.height = c.dataset.h + 'px'; }
}
const midi = (f, a4) => 69 + 12 * Math.log2(f / a4);
const name = (m) => `${NOTE[((Math.round(m) % 12) + 12) % 12]}${Math.floor(Math.round(m) / 12) - 1}`;

function setVal(id, v, fmt) {
  if (busy.has(id)) return;
  const el = $(id);
  if (+el.value !== v) el.value = v;
  const out = el.parentElement.querySelector('output');
  if (out && fmt) out.textContent = fmt(v);
}

let lastResult = false;
function render() {
  if (!S) return;
  const s = S.settings, t = S.telemetry;
  document.querySelectorAll('.mode').forEach((b) => b.classList.toggle('active', b.dataset.mode === t.mode));
  $('chain-in').textContent = { mic: 'HP+MIC mic', line: 'LINE IN', file: 'DMA file' }[t.mode] || '-';
  document.querySelectorAll('.blk.tog').forEach((b) => {
    const on = b.dataset.invert ? !s[b.dataset.toggle] : s[b.dataset.toggle];
    b.classList.toggle('off', !on);
  });
  $('bypass').textContent = s.dsp ? 'DSP on' : 'Dry bypass';
  $('bypass').classList.toggle('off', !s.dsp);
  document.querySelector('.chain').classList.toggle('dry', !s.dsp);

  if (!$('key').options.length) {
    S.keys.forEach((k) => $('key').add(new Option(k, k)));
    S.scales.forEach((k) => $('scale').add(new Option(k, k)));
  }
  $('key').value = s.key; $('scale').value = s.scale;
  setVal('retune_ms', s.retune_ms, (v) => v === 0 ? 'hard (0 ms)' : `${v} ms`);
  setVal('shift', s.shift, (v) => `${v > 0 ? '+' : ''}${v} st`);
  setVal('a4', s.a4, (v) => `${v} Hz`);
  setVal('input_gain_db', t.mode === 'mic' ? s.mic_gain_db : s.line_gain_db, (v) => `${v} dB`);
  setVal('gain_db', s.gain_db, (v) => `${v > 0 ? '+' : ''}${v} dB`);
  setVal('hp_db', s.hp_db, (v) => `${v} dB`);
  setVal('gate_thr', s.gate_thr, (v) => v);
  $('in_ch').value = s.in_ch; $('mute').checked = s.mute; $('eq-on').checked = s.eq;

  // status pills
  $('pill-conn').textContent = 'board connected'; $('pill-conn').className = 'pill ok';
  $('pill-codec').textContent = t.codec_alive ? 'codec clock OK' : 'codec clock missing';
  $('pill-codec').className = 'pill ' + (t.codec_alive ? 'ok' : 'bad');

  // pitch display
  if (t.voiced && t.f0_hz > 0) {
    $('note').textContent = t.note;
    $('needle').style.left = `${50 + Math.max(-50, Math.min(50, t.cents))}%`;
    $('f0').textContent = `${t.f0_hz.toFixed(1)} Hz (${t.cents > 0 ? '+' : ''}${t.cents} c)`;
    $('target').textContent = t.target_note ? `${t.target_note} ${t.target_hz.toFixed(1)} Hz` : '-';
  } else {
    $('note').textContent = '-'; $('f0').textContent = 'no pitch'; $('target').textContent = '-';
    $('needle').style.left = '50%';
  }
  $('corr').textContent = `${t.shift_cents > 0 ? '+' : ''}${t.shift_cents} cents`;

  // meters
  const pct = (db) => `${Math.max(0, Math.min(100, (db + 60) / 60 * 100))}%`;
  $('m-in').style.width = pct(t.in_dbfs); $('m-out').style.width = pct(t.out_dbfs);
  $('db-in').textContent = `${t.in_dbfs} dB`; $('db-out').textContent = `${t.out_dbfs} dB`;

  // file
  const f = t.file;
  $('play').disabled = !(f.loaded || uploaded) || f.playing;
  $('stop').disabled = !f.playing;
  $('prog').style.width = `${(f.progress || 0) * 100}%`;
  if (f.playing) toast(`Playing ${f.name}: ${Math.round(f.progress * 100)} %`);
  if (f.has_result && !lastResult) {
    lastResult = true;
    $('player').src = '/api/processed.wav?t=' + Date.now(); $('player').hidden = false;
    $('download').hidden = false;
    toast('Done. Listen to or download the processed result below.');
  }
  $('foot').textContent = `fs ${S.params.fs} Hz | FFT N = ${S.params.n}, hop ${S.params.hop} (75 % overlap) | ` +
    `latency ~${S.params.latency_ms} ms | frames ${t.frames} | underflows ${t.underflows} | overruns ${t.overruns}`;
}

// pitch trace
function drawTrace() {
  const c = $('trace'), g = c.getContext('2d');
  fit(c);
  const W = c.width, H = c.height, css = getComputedStyle(document.documentElement);
  g.clearRect(0, 0, W, H);
  if (!S) return;
  const a4 = S.settings.a4, now = performance.now() / 1000;
  const pts = hist.filter((p) => p.f0 > 0);
  const ms = pts.map((p) => midi(p.f0, a4));
  let mid = ms.length ? ms.reduce((a, b) => a + b, 0) / ms.length : 57;
  const lo = Math.round(mid) - 7, hi = lo + 14;
  const y = (m) => H - (m - lo) / (hi - lo) * H;
  const root = NOTE.indexOf(S.settings.key), steps = SCALES[S.settings.scale] || SCALES.chromatic;
  g.font = `${10 * devicePixelRatio}px system-ui`;
  for (let m = lo; m <= hi; m++) {
    const inScale = steps.includes(((m - root) % 12 + 12) % 12);
    g.fillStyle = css.getPropertyValue(inScale ? '--grid' : '--bg');
    g.fillRect(0, y(m + 0.5), W, y(m - 0.5) - y(m + 0.5) - 1);
    if (inScale) { g.fillStyle = css.getPropertyValue('--muted'); g.fillText(name(m), 4, y(m) + 4); }
  }
  const x = (t) => W - (now - t) / HIST_S * W;
  for (const [key, color] of [['f0', '--trace-in'], ['out', '--trace-out']]) {
    g.strokeStyle = css.getPropertyValue(color); g.lineWidth = (key === 'out' ? 2.5 : 1.5) * devicePixelRatio;
    g.beginPath(); let pen = false;
    for (const p of hist) {
      if (p[key] > 0) { const xx = x(p.t), yy = y(midi(p[key], a4)); pen ? g.lineTo(xx, yy) : g.moveTo(xx, yy); pen = true; } else pen = false;
    }
    g.stroke();
  }
  g.lineWidth = 1;
}

let frames0 = null, ft0 = 0;
async function poll() {
  try {
    S = await api('/api/state');
    const t = S.telemetry, now = performance.now() / 1000;
    hist.push({ t: now, f0: t.voiced ? t.f0_hz : 0, out: t.voiced ? t.f0_hz * t.ratio : 0 });
    while (hist.length && now - hist[0].t > HIST_S) hist.shift();
    if (frames0 === null || now - ft0 > 2) {
      if (frames0 !== null) $('pill-rate').textContent = `${Math.round((t.frames - frames0) / (now - ft0))} frames/s`;
      frames0 = t.frames; ft0 = now;
    }
    render();
  } catch (e) {
    $('pill-conn').textContent = 'board offline'; $('pill-conn').className = 'pill bad';
  }
  setTimeout(poll, 150);
}
(function loop() { drawTrace(); requestAnimationFrame(loop); })();

(async () => {
  await poll();
  eqDesign = Object.assign({ type: 'flat' }, S.settings.eq_design);
  $('eq-type').value = eqDesign.type;
  buildEqParams();
  drawEq();
  window.addEventListener('resize', drawEq);
})();
