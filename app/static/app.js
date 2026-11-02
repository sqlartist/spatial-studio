/* Spatial Studio front end - plain JS, no build step. */
'use strict';

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const PALETTE = ['#4e79a7', '#f28e2b', '#e15759', '#76b7b2', '#59a14f', '#edc948', '#b07aa1', '#ff9da7', '#9c755f', '#bab0ac'];
const MAP_MODES = new Set(['geography', 'lonlat', 'merc']);

const state = {
  packs: [], demo: null, result: null, layers: [], selected: null, activeRs: 0,
  frames: [], frameIdx: 0, playing: null, status: null, demoStatus: {},
};

/* ------------------------------------------------------------------ helpers */
async function api(path, body) {
  const res = await fetch(path, body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  if (!res.ok) {
    let msg = res.statusText;
    try { msg = (await res.json()).detail || msg; } catch (e) { /* not json */ }
    throw new Error(msg);
  }
  return res.json();
}
async function streamNdjson(path, onItem) {
  const res = await fetch(path, { method: 'POST' });
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i); buf = buf.slice(i + 1);
      if (line.trim()) onItem(JSON.parse(line));
    }
  }
}
function toast(msg, ms = 2600) {
  const t = $('#toast'); t.textContent = msg; t.hidden = false;
  clearTimeout(toast._t); toast._t = setTimeout(() => (t.hidden = true), ms);
}
function store(k, v) { try { localStorage.setItem('ss.' + k, JSON.stringify(v)); } catch (e) { /* private mode */ } }
function recall(k, d) { try { const v = localStorage.getItem('ss.' + k); return v === null ? d : JSON.parse(v); } catch (e) { return d; } }
function fmtNum(v) {
  if (typeof v !== 'number') return v;
  if (Number.isInteger(v)) return v.toLocaleString('en-GB');
  return Math.abs(v) >= 1e6 || Math.abs(v) < 1e-4 ? v.toPrecision(8) : String(Math.round(v * 1e6) / 1e6);
}
function cssVar(n) { return getComputedStyle(document.documentElement).getPropertyValue(n).trim(); }

/* ------------------------------------------------------------------ theme */
function applyTheme(t) {
  if (t) document.documentElement.dataset.theme = t; else delete document.documentElement.dataset.theme;
  plane && plane.render();
  if (mapView.map) mapView.applyBasemap();
}
$('#btnTheme').onclick = () => {
  const dark = document.documentElement.dataset.theme === 'dark' ||
    (!document.documentElement.dataset.theme && matchMedia('(prefers-color-scheme: dark)').matches);
  const t = dark ? 'light' : 'dark'; store('theme', t); applyTheme(t);
};
function isDark() {
  const t = document.documentElement.dataset.theme;
  return t ? t === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
}

/* ------------------------------------------------------------------ editor */
const editor = CodeMirror.fromTextArea($('#sql'), {
  mode: 'text/x-mssql', lineNumbers: true, indentUnit: 4, smartIndent: true, lineWrapping: false,
  extraKeys: {
    'Ctrl-Enter': () => run(), 'Cmd-Enter': () => run(), 'F5': () => run(),
    'Ctrl-L': () => explain(), 'Ctrl-Space': 'autocomplete',
  },
  hintOptions: { completeSingle: false },
});
editor.setValue(recall('sql', '-- Pick a demo on the left, or write T-SQL here and press Ctrl+Enter.\nSELECT geography::Point(51.6565, -0.3903, 4326).STBuffer(5000) AS watford;\n'));
editor.on('change', () => store('sql', editor.getValue()));
document.addEventListener('keydown', e => {
  if (e.key === 'F5') { e.preventDefault(); run(); }
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter' && !editor.hasFocus()) { e.preventDefault(); run(); }
  if (e.key === 'Escape') { drawing.cancel(); closeModal(); }
});

/* splitter */
(() => {
  const sp = $('#splitter'), pane = $('#editorPane'), main = $('.main');
  const h = recall('split', null); if (h) pane.style.height = h;
  sp.addEventListener('pointerdown', e => {
    sp.setPointerCapture(e.pointerId);
    const move = ev => {
      const r = main.getBoundingClientRect();
      const pct = Math.min(80, Math.max(15, (ev.clientY - r.top) / r.height * 100));
      pane.style.height = pct + '%'; editor.refresh(); plane.resize(); mapView.map && mapView.map.resize();
    };
    const up = () => { sp.removeEventListener('pointermove', move); sp.removeEventListener('pointerup', up); store('split', pane.style.height); };
    sp.addEventListener('pointermove', move); sp.addEventListener('pointerup', up);
  });
})();

/* ------------------------------------------------------------------ tabs */
function showTab(name) {
  $$('#tabs button').forEach(b => b.classList.toggle('active', b.dataset.tab === name));
  $$('.tabBody > .tab').forEach(t => t.classList.toggle('active', t.dataset.tab === name));
  state.tab = name;
  const viewer = name === 'map' || name === 'plane';
  $('#layersBox').classList.toggle('show', viewer && state.layers.length > 0);
  $('#animBar').hidden = !(viewer && state.frames.length > 1);
  if (name === 'map') { mapView.ensure(); setTimeout(() => mapView.map && mapView.map.resize(), 0); }
  if (name === 'plane') setTimeout(() => plane.resize(), 0);
  renderLayersBox();
}
$$('#tabs button').forEach(b => (b.onclick = () => showTab(b.dataset.tab)));

/* ------------------------------------------------------------------ demos */
async function loadDemos() {
  state.packs = await api('/api/demos');
  state.demoStatus = recall('demoStatus', {});
  renderTree();
}
function renderTree() {
  const q = $('#demoSearch').value.trim().toLowerCase();
  const closed = recall('closedPacks', {});
  let shown = 0, total = 0;
  const html = state.packs.map(p => {
    const items = p.demos.filter(d => {
      total++;
      if (!q) return true;
      return (d.title + ' ' + d.desc + ' ' + d.tags.join(' ') + ' ' + d.sql).toLowerCase().includes(q);
    });
    shown += items.length;
    if (!items.length) return '';
    const isClosed = !q && closed[p.title];
    return `<div class="pack ${isClosed ? 'closed' : ''}" data-pack="${esc(p.title)}">
      <div class="packHead"><span class="caret">▾</span>${esc(p.title)}<span class="n">${items.length}</span></div>
      ${items.map(d => {
        const st = state.demoStatus[d.id];
        const mark = st === 'ok' ? '<span class="st st-ok">✓</span>' : st === 'bad' ? '<span class="st st-bad">✗</span>' : st === 'warn' ? '<span class="st st-warn">!</span>' : '';
        return `<div class="demoItem ${state.demo && state.demo.id === d.id ? 'active' : ''}" data-id="${esc(d.id)}" title="${esc(d.desc)}">${mark}${esc(d.title)}</div>`;
      }).join('')}
    </div>`;
  }).join('');
  $('#demoTree').innerHTML = html || '<p class="muted" style="padding:10px">No demos match.</p>';
  $('#demoCount').textContent = q ? `${shown} of ${total} demos` : `${total} demos in ${state.packs.length} packs`;
  $$('.packHead').forEach(h => (h.onclick = () => {
    const p = h.parentElement; p.classList.toggle('closed');
    const c = recall('closedPacks', {}); c[p.dataset.pack] = p.classList.contains('closed'); store('closedPacks', c);
  }));
  $$('.demoItem').forEach(el => {
    el.onclick = () => openDemo(el.dataset.id);
    el.ondblclick = () => { openDemo(el.dataset.id); run(); };
  });
}
$('#demoSearch').addEventListener('input', renderTree);
function findDemo(id) { for (const p of state.packs) for (const d of p.demos) if (d.id === id) return d; return null; }
function openDemo(id, autorun = false) {
  const d = findDemo(id); if (!d) return;
  state.demo = d; store('demo', id);
  editor.setValue(d.sql); editor.clearHistory();
  $('#demoTitle').textContent = d.title;
  $('#demoDesc').textContent = d.desc || '';
  $('#demoTags').innerHTML = d.tags.map(t => `<span class="tag">${esc(t)}</span>`).join('');
  $$('#demoTags .tag').forEach(t => (t.onclick = () => { $('#demoSearch').value = t.textContent; renderTree(); }));
  $$('.demoItem').forEach(el => el.classList.toggle('active', el.dataset.id === id));
  if (autorun) run();
}

/* ------------------------------------------------------------------ status / connection */
async function refreshStatus() {
  const pill = $('#connPill');
  try {
    const s = await api('/api/status');
    state.status = s;
    pill.classList.remove('ok', 'bad', 'warn');
    if (!s.pyodbc) { pill.classList.add('bad'); $('#connText').textContent = 'pyodbc not installed'; return s; }
    if (!s.connected) { pill.classList.add('bad'); $('#connText').textContent = `Not connected: ${s.config.server}`; pill.title = s.error || ''; return s; }
    const ver = s.productVersion ? `v${s.productVersion}` : '';
    const inst = s.installed ? 'sample DB ready' : (s.databaseExists ? 'sample DB incomplete' : 'sample DB not installed');
    pill.classList.add(s.installed ? (s.is2025 === false ? 'warn' : 'ok') : 'warn');
    $('#connText').textContent = `${s.config.server} · ${ver}${s.is2025 === false ? ' (not 2025!)' : ''} · ${inst}`;
    pill.title = s.version || '';
    $('#btnInstall').textContent = s.installed ? 'Reinstall sample DB' : 'Install sample DB';
    return s;
  } catch (e) {
    pill.classList.add('bad'); $('#connText').textContent = 'Server offline'; return null;
  }
}
$('#connPill').onclick = () => connectDialog();
function connectDialog() {
  const c = (state.status && state.status.config) || {};
  const drivers = (state.status && state.status.drivers) || [];
  openModal('Connection', `
    <div class="form">
      <label>Server</label><input type="text" id="cServer" value="${esc(c.server || 'localhost')}" placeholder="localhost, .\\SQL2025, host,1433">
      <label>Database</label><input type="text" id="cDb" value="${esc(c.database || 'SpatialStudio')}">
      <label>Authentication</label><select id="cAuth"><option value="windows">Windows (trusted)</option><option value="sql">SQL Server login</option></select>
      <label>User</label><input type="text" id="cUser" value="${esc(c.user || '')}">
      <label>Password</label><input type="password" id="cPwd" placeholder="kept in memory only">
      <label>ODBC driver</label><select id="cDrv"><option value="">(auto: ${esc((state.status && state.status.driver) || 'none found')})</option>${drivers.map(d => `<option ${d === c.driver ? 'selected' : ''}>${esc(d)}</option>`).join('')}</select>
      <label>Encrypt</label><select id="cEnc"><option>optional</option><option>mandatory</option><option>strict</option></select>
      <label></label><label class="small"><input type="checkbox" id="cTrust" ${c.trustServerCertificate !== false ? 'checked' : ''}> Trust server certificate (typical for a local dev instance)</label>
      <div class="full"><button class="btn primary" id="cSave">Save &amp; test</button> <span id="cMsg" class="muted"></span></div>
    </div>`);
  $('#cAuth').value = c.auth || 'windows'; $('#cEnc').value = c.encrypt || 'optional';
  $('#cSave').onclick = async () => {
    $('#cMsg').textContent = 'Testing…';
    try {
      const body = { server: $('#cServer').value.trim(), database: $('#cDb').value.trim(), auth: $('#cAuth').value, user: $('#cUser').value.trim(),
        driver: $('#cDrv').value, encrypt: $('#cEnc').value, trustServerCertificate: $('#cTrust').checked, remember: true };
      if ($('#cPwd').value) body.password = $('#cPwd').value;
      const s = await api('/api/connect', body);
      state.status = s;
      $('#cMsg').textContent = s.connected ? `Connected: ${s.version}` : `Failed: ${s.error}`;
      refreshStatus();
    } catch (e) { $('#cMsg').textContent = e.message; }
  };
}

/* ------------------------------------------------------------------ modal */
function openModal(title, html) { $('#modalTitle').textContent = title; $('#modalBody').innerHTML = html; $('#modal').hidden = false; }
function closeModal() { $('#modal').hidden = true; }
$('#modalClose').onclick = closeModal;
$('#modal').addEventListener('click', e => { if (e.target.id === 'modal') closeModal(); });

/* ------------------------------------------------------------------ install */
$('#btnInstall').onclick = () => {
  openModal('Install the SpatialStudio sample database', `
    <p>This creates (or rebuilds) the <code>SpatialStudio</code> database: the <code>sx</code> function library, 177 Natural Earth countries,
    24,000+ GeoNames cities, the generated town of Sqlford, shape vectors and the spatial + DiskANN vector indexes. It takes a few minutes.</p>
    <p class="muted">Needs permission to CREATE DATABASE. Everything is in <code>sql/install</code> if you'd rather run it in SSMS.</p>
    <button class="btn primary" id="goInstall">Install now</button>
    <div class="log" id="installLog" style="margin-top:10px"></div>`);
  $('#goInstall').onclick = async () => {
    $('#goInstall').disabled = true;
    const log = $('#installLog');
    const add = (t, cls = '') => { log.insertAdjacentHTML('beforeend', `<div class="${cls}">${esc(t)}</div>`); log.scrollTop = log.scrollHeight; };
    let errors = 0;
    try {
      await streamNdjson('/api/install', m => {
        if (m.kind === 'file') add(`▶ ${m.file}`);
        else if (m.kind === 'info') add('   ' + m.text, 'muted');
        else if (m.kind === 'error') { errors++; add('   ' + m.text, 'st-bad'); }
        else if (m.kind === 'done') add(`   ${m.errors ? '✗' : '✓'} ${m.file} in ${(m.ms / 1000).toFixed(1)} s`, m.errors ? 'st-bad' : 'st-ok');
        else if (m.kind === 'finished') add(errors ? `Finished with ${errors} error(s).` : 'All done. Pick a demo and press Run.', errors ? 'st-bad' : 'st-ok');
      });
    } catch (e) { add(e.message, 'st-bad'); }
    $('#goInstall').disabled = false;
    refreshStatus();
  };
};

/* ------------------------------------------------------------------ run */
let running = false;
async function run() {
  if (running) return;
  const sel = editor.getSelection();
  const sql = sel.trim() ? sel : editor.getValue();
  const offset = sel.trim() ? editor.getCursor('from').line : 0;
  running = true;
  $('#btnRun').disabled = true; $('#btnCancel').disabled = false;
  $('#runStatus').className = 'runStatus'; $('#runStatus').textContent = 'Running…';
  clearErrorMarks();
  const t0 = performance.now();
  try {
    const res = await api('/api/run', { sql, maxRows: +$('#maxRows').value || 5000 });
    state.result = res;
    const ms = Math.round(performance.now() - t0);
    const rows = res.resultSets.reduce((a, r) => a + r.rowCount, 0);
    $('#runStatus').textContent = `${res.errors.length ? res.errors.length + ' error(s) · ' : ''}${res.resultSets.length} result set(s), ${rows.toLocaleString()} rows · server ${res.elapsedMs} ms · total ${ms} ms`;
    if (res.errors.length) $('#runStatus').className = 'runStatus err';
    res.errors.forEach(e => markError(e.line - 1 + offset));
    if (state.demo) {
      state.demoStatus[state.demo.id] = res.errors.length ? 'bad' : 'ok'; store('demoStatus', state.demoStatus);
    }
    onResults();
  } catch (e) {
    $('#runStatus').className = 'runStatus err'; $('#runStatus').textContent = e.message;
  } finally {
    running = false; $('#btnRun').disabled = false; $('#btnCancel').disabled = true;
  }
}
$('#btnRun').onclick = run;
$('#btnCancel').onclick = async () => { await api('/api/cancel', {}); toast('Cancel requested'); };
let errorMarks = [];
function markError(line) { if (line >= 0 && line < editor.lineCount()) errorMarks.push(editor.addLineClass(line, 'background', 'cm-error-line')); }
function clearErrorMarks() { errorMarks.forEach(h => editor.removeLineClass(h, 'background', 'cm-error-line')); errorMarks = []; }

function onResults() {
  const res = state.result;
  buildLayers();
  renderMessages();
  renderResultTabs();
  $('#rsCount').textContent = res.resultSets.length ? `(${res.resultSets.length})` : '';
  $('#msgCount').textContent = res.errors.length ? `(${res.errors.length} ✗)` : '';
  const hasMap = state.layers.some(l => l.map), hasPlane = state.layers.some(l => !l.map);
  const hint = state.demo && state.demo.view;
  let tab = 'results';
  if (res.errors.length && !res.resultSets.length) tab = 'messages';
  else if (hint === 'map' && hasMap) tab = 'map';
  else if (hint === 'plane' && hasPlane) tab = 'plane';
  else if (hasMap) tab = 'map';
  else if (hasPlane) tab = 'plane';
  if (state.layers.length || res.resultSets.length || res.errors.length) showTab(tab);
  setupFrames();
  plane.setLayers(state.layers.filter(l => !l.map), true);
  if (mapView.map) mapView.setLayers(state.layers.filter(l => l.map), true);
  else mapView.pending = true;
  renderLayersBox();
}

/* ------------------------------------------------------------------ layers */
function colIndex(rs, ...names) {
  const lower = rs.columns.map(c => c.name.toLowerCase());
  for (const n of names) { const i = lower.indexOf(n); if (i >= 0) return i; }
  return -1;
}
function buildLayers() {
  const layers = [];
  state.result.resultSets.forEach((rs, ri) => {
    const ci = colIndex(rs, 'color', 'colour'), li = colIndex(rs, 'label'), fi = colIndex(rs, 'frame');
    const oi = colIndex(rs, 'opacity'), wi = colIndex(rs, 'linewidth'), si = colIndex(rs, 'fontsize');
    const num = (row, i) => (i >= 0 && typeof row[i] === 'number' ? row[i] : null);
    const byCol = {};
    rs.features.forEach(f => (byCol[f.col] = byCol[f.col] || []).push(f));
    Object.keys(byCol).forEach(col => {
      const c = rs.columns[col];
      const idx = layers.length;
      const def = PALETTE[idx % PALETTE.length];
      const feats = byCol[col].map(f => {
        const row = rs.rows[f.row];
        const fr = fi >= 0 ? row[fi] : null;
        return { ...f, rs: ri, color: (ci >= 0 && row[ci]) || def, label: li >= 0 && row[li] != null ? String(row[li]) : null,
          frame: typeof fr === 'number' ? fr : null, opacity: num(row, oi), linewidth: num(row, wi), fontsize: num(row, si) };
      });
      const map = MAP_MODES.has(c.mode);
      layers.push({ id: `L${idx}`, name: `RS${ri + 1} · ${c.name}`, rs: ri, col: +col, kind: c.kind, mode: c.mode, map, color: def, visible: true, features: feats });
    });
  });
  state.layers = layers;
  state.selected = null;
}
function renderLayersBox() {
  const box = $('#layersBox');
  const view = state.tab === 'map' ? true : state.tab === 'plane' ? false : null;
  const ls = state.layers.filter(l => l.map === view);
  if (view === null || !ls.length) { box.classList.remove('show'); return; }
  box.classList.add('show');
  box.innerHTML = `<div class="head"><span>Layers</span><span class="muted">${ls.reduce((a, l) => a + l.features.length, 0)} shapes</span></div>` +
    ls.map(l => `<label class="lrow"><input type="checkbox" data-l="${l.id}" ${l.visible ? 'checked' : ''}><span class="sw" style="background:${esc(l.color)}"></span>${esc(l.name)} <span class="muted">${l.features.length} · ${esc(l.kind)}${l.features[0] ? ' ' + l.features[0].mode : ''}</span></label>`).join('');
  $$('input', box).forEach(cb => (cb.onchange = () => {
    const l = state.layers.find(x => x.id === cb.dataset.l); l.visible = cb.checked;
    if (l.map) mapView.setLayers(state.layers.filter(x => x.map), false); else plane.render();
  }));
}

/* ------------------------------------------------------------------ animation */
function setupFrames() {
  stopAnim();
  const set = new Set();
  state.layers.forEach(l => l.features.forEach(f => f.frame !== null && set.add(f.frame)));
  state.frames = [...set].sort((a, b) => a - b);
  state.frameIdx = 0;
  const bar = $('#animBar');
  bar.hidden = !(state.frames.length > 1 && (state.tab === 'map' || state.tab === 'plane'));
  $('#frameSlider').max = Math.max(0, state.frames.length - 1); $('#frameSlider').value = 0;
  updateFrameLabel();
  if (state.frames.length > 60) $('#animSpeed').value = '83';
  if (state.frames.length > 1) setTimeout(() => !state.playing && startAnim(), 400);
}
function currentFrame() { return state.frames.length ? state.frames[state.frameIdx] : null; }
function frameVisible(f) { const cf = currentFrame(); return f.frame === null || cf === null || f.frame === cf; }
function updateFrameLabel() { $('#frameLabel').textContent = state.frames.length ? `frame ${currentFrame()} (${state.frameIdx + 1}/${state.frames.length})` : ''; }
function gotoFrame(i) {
  state.frameIdx = (i + state.frames.length) % state.frames.length;
  $('#frameSlider').value = state.frameIdx; updateFrameLabel();
  plane.render(); mapView.applyFrame();
}
function startAnim() {
  stopAnim(); $('#btnPlay').textContent = '❚❚';
  const tick = () => { gotoFrame(state.frameIdx + 1); state.playing = setTimeout(tick, +$('#animSpeed').value); };
  state.playing = setTimeout(tick, +$('#animSpeed').value);
}
function stopAnim() { clearTimeout(state.playing); state.playing = null; $('#btnPlay').textContent = '▶'; }
$('#btnPlay').onclick = () => (state.playing ? stopAnim() : startAnim());
$('#frameSlider').oninput = e => { stopAnim(); gotoFrame(+e.target.value); };

/* ------------------------------------------------------------------ geometry utils */
function ringCentroid(r) {
  let a = 0, x = 0, y = 0;
  for (let i = 0; i < r.length - 1; i++) {
    const f = r[i][0] * r[i + 1][1] - r[i + 1][0] * r[i][1];
    a += f; x += (r[i][0] + r[i + 1][0]) * f; y += (r[i][1] + r[i + 1][1]) * f;
  }
  if (Math.abs(a) < 1e-12) { const n = r.length || 1; return [r.reduce((s, p) => s + p[0], 0) / n, r.reduce((s, p) => s + p[1], 0) / n]; }
  return [x / (3 * a), y / (3 * a)];
}
function labelAnchor(parts) {
  if (parts.polys.length) {
    let best = null, bestA = -1;
    parts.polys.forEach(p => { const r = p[0]; let a = 0; for (let i = 0; i < r.length - 1; i++) a += r[i][0] * r[i + 1][1] - r[i + 1][0] * r[i][1]; a = Math.abs(a); if (a > bestA) { bestA = a; best = r; } });
    return ringCentroid(best);
  }
  if (parts.lines.length) { const l = parts.lines[0]; return l[Math.floor(l.length / 2)]; }
  if (parts.points.length) return parts.points[0];
  return null;
}
function unionBbox(feats) {
  let b = null;
  feats.forEach(f => { if (!f.bbox) return; b = b ? [Math.min(b[0], f.bbox[0]), Math.min(b[1], f.bbox[1]), Math.max(b[2], f.bbox[2]), Math.max(b[3], f.bbox[3])] : f.bbox.slice(); });
  return b;
}
function rowTooltip(rs, rowIdx) {
  const r = state.result.resultSets[rs];
  const row = r.rows[rowIdx];
  const cells = r.columns.map((c, i) => [c, row[i]]).filter(([c]) => !['color', 'colour'].includes(c.name.toLowerCase())).slice(0, 10);
  return '<table>' + cells.map(([c, v]) => `<tr><td>${esc(c.name)}</td><td>${v && v.$sp ? esc(v.type + ' · SRID ' + v.srid) : esc(fmtNum(v))}</td></tr>`).join('') + '</table>';
}

/* ------------------------------------------------------------------ plane view (canvas) */
const plane = (() => {
  const cv = $('#plane'), ctx = cv.getContext('2d');
  const v = { cx: 0, cy: 0, s: 1 };
  let layers = [], dpr = 1, hoverFeat = null;
  const self = {};
  self.resize = () => {
    const r = cv.getBoundingClientRect(); if (!r.width) return;
    dpr = window.devicePixelRatio || 1;
    cv.width = Math.round(r.width * dpr); cv.height = Math.round(r.height * dpr);
    self.render();
  };
  const W = () => cv.width / dpr, H = () => cv.height / dpr;
  const toScreen = (x, y) => [(x - v.cx) * v.s + W() / 2, H() / 2 - (y - v.cy) * v.s];
  const toWorld = (sx, sy) => [(sx - W() / 2) / v.s + v.cx, (H() / 2 - sy) / v.s + v.cy];
  self.toWorld = toWorld;
  self.fit = () => {
    const b = unionBbox(layers.filter(l => l.visible).flatMap(l => l.features)); if (!b) return;
    const w = Math.max(b[2] - b[0], 1e-9), h = Math.max(b[3] - b[1], 1e-9);
    v.cx = (b[0] + b[2]) / 2; v.cy = (b[1] + b[3]) / 2;
    v.s = Math.min((W() - 60) / w, (H() - 60) / h);
    if (!isFinite(v.s) || v.s <= 0) v.s = 1;
    if (b[2] - b[0] === 0 && b[3] - b[1] === 0) v.s = 1;
    self.render();
  };
  self.setLayers = (ls, fit) => {
    layers = ls;
    layers.forEach(l => l.features.forEach(f => { f._path = null; }));
    if (fit) { if (state.tab === 'plane') { self.resize(); self.fit(); } else self._needFit = true; }
    self.render();
  };
  function pathFor(f) {
    if (f._path) return f._path;
    const p = new Path2D();
    f.parts.polys.forEach(poly => poly.forEach(ring => { ring.forEach((pt, i) => (i ? p.lineTo(pt[0], pt[1]) : p.moveTo(pt[0], pt[1]))); p.closePath(); }));
    const lp = new Path2D();
    f.parts.lines.forEach(line => line.forEach((pt, i) => (i ? lp.lineTo(pt[0], pt[1]) : lp.moveTo(pt[0], pt[1]))));
    f._path = p; f._lpath = lp;
    return p;
  }
  function niceStep(span) { const raw = span / 8, p = Math.pow(10, Math.floor(Math.log10(raw))); const m = raw / p; return (m < 2 ? 1 : m < 5 ? 2 : 5) * p; }
  function drawGrid() {
    const [x0, y1] = toWorld(0, 0), [x1, y0] = toWorld(W(), H());
    const step = niceStep(x1 - x0);
    ctx.strokeStyle = cssVar('--plane-grid'); ctx.lineWidth = 1; ctx.fillStyle = cssVar('--muted'); ctx.font = '10px Consolas, monospace';
    ctx.beginPath();
    for (let x = Math.ceil(x0 / step) * step; x <= x1; x += step) { const [sx] = toScreen(x, 0); ctx.moveTo(sx, 0); ctx.lineTo(sx, H()); }
    for (let y = Math.ceil(y0 / step) * step; y <= y1; y += step) { const [, sy] = toScreen(0, y); ctx.moveTo(0, sy); ctx.lineTo(W(), sy); }
    ctx.stroke();
    for (let x = Math.ceil(x0 / step) * step; x <= x1; x += step) { const [sx] = toScreen(x, 0); ctx.fillText(+x.toPrecision(10), sx + 2, H() - 4); }
    for (let y = Math.ceil(y0 / step) * step; y <= y1; y += step) { const [, sy] = toScreen(0, y); ctx.fillText(+y.toPrecision(10), 3, sy - 2); }
  }
  self.render = () => {
    if (!cv.width) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = cssVar('--plane-bg'); ctx.fillRect(0, 0, W(), H());
    if ($('#chkGrid').checked) drawGrid();
    const labels = [];
    const sel = state.selected;
    layers.forEach(l => {
      if (!l.visible) return;
      l.features.forEach(f => {
        if (!frameVisible(f)) return;
        const p = pathFor(f);
        const isSel = sel && sel.rs === f.rs && sel.row === f.row;
        ctx.setTransform(dpr * v.s, 0, 0, -dpr * v.s, dpr * (W() / 2 - v.cx * v.s), dpr * (H() / 2 + v.cy * v.s));
        if (f.parts.polys.length) {
          ctx.globalAlpha = f.opacity !== null ? f.opacity : (f === hoverFeat || isSel ? 0.8 : 0.55); ctx.fillStyle = f.color; ctx.fill(p, 'evenodd');
          ctx.globalAlpha = 1;
          const lw = isSel ? 3 : (f.linewidth !== null ? f.linewidth : 1.1);
          if (lw > 0) { ctx.lineWidth = lw / v.s; ctx.lineJoin = 'round'; ctx.strokeStyle = isSel ? '#facc15' : (f.linewidth !== null ? 'rgba(20,14,10,.85)' : shade(f.color)); ctx.stroke(p); }
        }
        if (f.parts.lines.length) {
          ctx.lineWidth = (isSel || f === hoverFeat ? 4 : 2.2) / v.s; ctx.strokeStyle = isSel ? '#facc15' : f.color; ctx.lineJoin = 'round'; ctx.lineCap = 'round'; ctx.stroke(f._lpath);
        }
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        f.parts.points.forEach(pt => {
          const [sx, sy] = toScreen(pt[0], pt[1]);
          ctx.beginPath(); ctx.arc(sx, sy, isSel || f === hoverFeat ? 6 : 4.2, 0, Math.PI * 2);
          ctx.fillStyle = f.color; ctx.fill(); ctx.lineWidth = 1.4; ctx.strokeStyle = isSel ? '#facc15' : '#fff'; ctx.stroke();
        });
        if (f.label && $('#chkLabels').checked) { const a = labelAnchor(f.parts); if (a) labels.push([toScreen(a[0], a[1]), f.label, f.fontsize]); }
      });
    });
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = '600 11px "Segoe UI", system-ui, sans-serif'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    const boxes = [];
    const fg = isDark() ? '#f3f4f6' : '#1d2330', halo = isDark() ? 'rgba(0,0,0,.85)' : 'rgba(255,255,255,.9)';
    labels.forEach(([[x, y], t, fsz]) => {
      ctx.font = `600 ${fsz || 11}px "Segoe UI", system-ui, sans-serif`;
      const w = ctx.measureText(t).width + 6, h = (fsz || 11) + 3;
      const b = [x - w / 2, y - h / 2, x + w / 2, y + h / 2];
      if (b[2] < 0 || b[0] > W() || b[3] < 0 || b[1] > H()) return;
      if (boxes.some(o => !(b[2] < o[0] || b[0] > o[2] || b[3] < o[1] || b[1] > o[3]))) return;
      boxes.push(b);
      ctx.lineWidth = 3; ctx.strokeStyle = halo; ctx.strokeText(t, x, y); ctx.fillStyle = fg; ctx.fillText(t, x, y);
    });
    drawing.renderPlane(ctx, toScreen);
    if (!layers.length && !drawing.active) {
      ctx.fillStyle = cssVar('--muted'); ctx.font = '13px "Segoe UI", sans-serif'; ctx.textAlign = 'center';
      ctx.fillText('Flat (geometry) results appear here. Geography and lon/lat shapes go to the Map tab.', W() / 2, H() / 2);
    }
  };
  function shade(c) { return isDark() ? 'rgba(255,255,255,.55)' : 'rgba(0,0,0,.45)'; }
  function hit(sx, sy) {
    for (let li = layers.length - 1; li >= 0; li--) {
      const l = layers[li]; if (!l.visible) continue;
      for (let i = l.features.length - 1; i >= 0; i--) {
        const f = l.features[i]; if (!frameVisible(f)) continue;
        for (const pt of f.parts.points) { const [x, y] = toScreen(pt[0], pt[1]); if (Math.hypot(x - sx, y - sy) < 7) return f; }
        const p = pathFor(f);
        ctx.setTransform(dpr * v.s, 0, 0, -dpr * v.s, dpr * (W() / 2 - v.cx * v.s), dpr * (H() / 2 + v.cy * v.s));
        ctx.lineWidth = 8 / v.s;
        const inside = (f.parts.polys.length && ctx.isPointInPath(p, sx * dpr, sy * dpr, 'evenodd')) ||
          (f.parts.lines.length && ctx.isPointInStroke(f._lpath, sx * dpr, sy * dpr));
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        if (inside) return f;
      }
    }
    return null;
  }
  let drag = null;
  cv.addEventListener('pointerdown', e => {
    if (drawing.active && drawing.view === 'plane') return;
    drag = { x: e.clientX, y: e.clientY, cx: v.cx, cy: v.cy, moved: false }; cv.setPointerCapture(e.pointerId); cv.style.cursor = 'grabbing';
  });
  cv.addEventListener('pointermove', e => {
    const r = cv.getBoundingClientRect(), sx = e.clientX - r.left, sy = e.clientY - r.top;
    const [wx, wy] = toWorld(sx, sy);
    $('#planeCoords').textContent = `x ${+wx.toPrecision(9)}   y ${+wy.toPrecision(9)}`;
    if (drawing.active && drawing.view === 'plane') { drawing.hover([wx, wy]); return; }
    if (drag) {
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (Math.abs(dx) + Math.abs(dy) > 2) drag.moved = true;
      v.cx = drag.cx - dx / v.s; v.cy = drag.cy + dy / v.s; self.render(); return;
    }
    const f = hit(sx, sy);
    if (f !== hoverFeat) { hoverFeat = f; self.render(); }
    const hv = $('#planeHover');
    if (f) { hv.innerHTML = rowTooltip(f.rs, f.row); hv.style.display = 'block'; hv.style.left = Math.min(sx + 16, r.width - 300) + 'px'; hv.style.top = (sy + 50) + 'px'; }
    else hv.style.display = 'none';
  });
  cv.addEventListener('pointerup', e => {
    const r = cv.getBoundingClientRect(), sx = e.clientX - r.left, sy = e.clientY - r.top;
    if (drawing.active && drawing.view === 'plane') { drawing.click(toWorld(sx, sy)); return; }
    if (drag && !drag.moved) { const f = hit(sx, sy); if (f) selectRow(f.rs, f.row, 'plane'); }
    drag = null; cv.style.cursor = '';
  });
  cv.addEventListener('dblclick', e => { if (drawing.active && drawing.view === 'plane') { e.preventDefault(); drawing.finish(); } });
  cv.addEventListener('pointerleave', () => { $('#planeHover').style.display = 'none'; });
  cv.addEventListener('wheel', e => {
    e.preventDefault();
    const r = cv.getBoundingClientRect(), sx = e.clientX - r.left, sy = e.clientY - r.top;
    const [wx, wy] = toWorld(sx, sy);
    v.s *= Math.exp(-e.deltaY * 0.0015);
    v.cx = wx - (sx - W() / 2) / v.s; v.cy = wy + (sy - H() / 2) / v.s;
    self.render();
  }, { passive: false });
  self.zoomTo = f => { if (!f.bbox) return; const b = f.bbox; const w = Math.max(b[2] - b[0], 1e-6), h = Math.max(b[3] - b[1], 1e-6); v.cx = (b[0] + b[2]) / 2; v.cy = (b[1] + b[3]) / 2; v.s = Math.min(v.s, Math.min((W() - 80) / w, (H() - 80) / h)); self.render(); };
  new ResizeObserver(() => { if (state.tab === 'plane') { self.resize(); if (self._needFit) { self._needFit = false; self.fit(); } } }).observe(cv);
  $('#btnFitPlane').onclick = () => self.fit();
  $('#chkGrid').onchange = $('#chkLabels').onchange = () => self.render();
  return self;
})();

/* ------------------------------------------------------------------ map view (MapLibre) */
const mapView = {
  map: null, layers: [], markers: [], globe: false, pending: false, ready: false,
  ensure() {
    if (this.map) return;
    const bm = $('#basemap').value;
    const style = {
      version: 8,
      sources: {
        osm: { type: 'raster', tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'], tileSize: 256, maxzoom: 19, attribution: '© OpenStreetMap contributors' },
        offline: { type: 'geojson', data: '/static/data/countries110.geojson', attribution: 'Natural Earth' },
      },
      layers: [
        { id: 'bg', type: 'background', paint: { 'background-color': '#dfe9f3' } },
        { id: 'osm', type: 'raster', source: 'osm', layout: { visibility: bm === 'osm' ? 'visible' : 'none' } },
        { id: 'off-fill', type: 'fill', source: 'offline', layout: { visibility: bm === 'offline' ? 'visible' : 'none' }, paint: { 'fill-color': '#f4f1ea' } },
        { id: 'off-line', type: 'line', source: 'offline', layout: { visibility: bm === 'offline' ? 'visible' : 'none' }, paint: { 'line-color': '#a8a29e', 'line-width': 0.6 } },
      ],
    };
    this.map = new maplibregl.Map({ container: 'map', style, center: [0, 30], zoom: 1.3, attributionControl: { compact: true }, maxPitch: 70 });
    this.map.addControl(new maplibregl.NavigationControl({ visualizePitch: true }), 'top-left');
    this.map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }), 'bottom-left');
    this.map.on('load', () => {
      this.ready = true;
      this.applyBasemap();
      if (this.pending) { this.pending = false; this.setLayers(state.layers.filter(l => l.map), true); }
    });
    this.map.on('mousemove', e => this.onMove(e));
    this.map.on('click', e => this.onClick(e));
    this.map.on('dblclick', e => { if (drawing.active && drawing.view === 'map') { e.preventDefault(); drawing.finish(); } });
    this.map.on('mouseout', () => ($('#mapHover').style.display = 'none'));
    this.map.on('moveend', () => this.renderLabels());
  },
  applyBasemap() {
    if (!this.ready) return;
    const b = $('#basemap').value, dark = isDark();
    this.map.setLayoutProperty('osm', 'visibility', b === 'osm' ? 'visible' : 'none');
    this.map.setLayoutProperty('off-fill', 'visibility', b === 'offline' ? 'visible' : 'none');
    this.map.setLayoutProperty('off-line', 'visibility', b === 'offline' ? 'visible' : 'none');
    this.map.setPaintProperty('bg', 'background-color', dark ? '#0f1720' : '#dfe9f3');
    this.map.setPaintProperty('off-fill', 'fill-color', dark ? '#262c36' : '#f4f1ea');
    this.map.setPaintProperty('off-line', 'line-color', dark ? '#4b5563' : '#a8a29e');
    this.map.setPaintProperty('osm', 'raster-saturation', dark ? -0.6 : 0);
    this.map.setPaintProperty('osm', 'raster-brightness-max', dark ? 0.55 : 1);
  },
  toFeature(f, li) {
    const props = { color: f.color, frame: f.frame === null ? -1 : f.frame, rs: f.rs, row: f.row, layer: li,
      opacity: f.opacity !== null ? f.opacity : 0.5, lw: f.linewidth !== null ? f.linewidth : 1.2 };
    const out = [];
    if (f.parts.polys.length) out.push({ type: 'Feature', properties: { ...props, k: 'poly' }, geometry: { type: 'MultiPolygon', coordinates: f.parts.polys } });
    if (f.parts.lines.length) out.push({ type: 'Feature', properties: { ...props, k: 'line' }, geometry: { type: 'MultiLineString', coordinates: f.parts.lines } });
    if (f.parts.points.length) out.push({ type: 'Feature', properties: { ...props, k: 'point' }, geometry: { type: 'MultiPoint', coordinates: f.parts.points } });
    return out;
  },
  clear() {
    this.layers.forEach(id => { ['-fill', '-line', '-pline', '-pt'].forEach(s => this.map.getLayer(id + s) && this.map.removeLayer(id + s)); this.map.getSource(id) && this.map.removeSource(id); });
    this.layers = [];
    this.markers.forEach(m => m.remove()); this.markers = [];
  },
  setLayers(ls, fit) {
    if (!this.map || !this.ready) { this.pending = true; return; }
    this.clear();
    ls.forEach((l, li) => {
      if (!l.visible) return;
      const id = 'res-' + l.id;
      this.map.addSource(id, { type: 'geojson', data: { type: 'FeatureCollection', features: l.features.flatMap(f => this.toFeature(f, li)) } });
      const col = ['get', 'color'];
      this.map.addLayer({ id: id + '-fill', type: 'fill', source: id, filter: ['==', ['get', 'k'], 'poly'], paint: { 'fill-color': col, 'fill-opacity': ['get', 'opacity'] } });
      this.map.addLayer({ id: id + '-pline', type: 'line', source: id, filter: ['==', ['get', 'k'], 'poly'], paint: { 'line-color': col, 'line-width': ['get', 'lw'] } });
      this.map.addLayer({ id: id + '-line', type: 'line', source: id, filter: ['==', ['get', 'k'], 'line'], paint: { 'line-color': col, 'line-width': 2.6 }, layout: { 'line-cap': 'round', 'line-join': 'round' } });
      this.map.addLayer({ id: id + '-pt', type: 'circle', source: id, filter: ['==', ['get', 'k'], 'point'], paint: { 'circle-color': col, 'circle-radius': 5, 'circle-stroke-color': '#fff', 'circle-stroke-width': 1.3 } });
      this.layers.push(id);
    });
    this.applyFrame();
    if (fit) this.fit();
  },
  frameFilter(k) {
    const cf = currentFrame();
    const base = ['==', ['get', 'k'], k];
    if (cf === null) return base;
    return ['all', base, ['any', ['==', ['get', 'frame'], -1], ['==', ['get', 'frame'], cf]]];
  },
  applyFrame() {
    if (!this.map || !this.ready) return;
    this.layers.forEach(id => {
      this.map.setFilter(id + '-fill', this.frameFilter('poly'));
      this.map.setFilter(id + '-pline', this.frameFilter('poly'));
      this.map.setFilter(id + '-line', this.frameFilter('line'));
      this.map.setFilter(id + '-pt', this.frameFilter('point'));
    });
    this.renderLabels();
  },
  renderLabels() {
    this.markers.forEach(m => m.remove()); this.markers = [];
    if (!this.map) return;
    const W = this.map.getCanvas().clientWidth, H = this.map.getCanvas().clientHeight;
    const boxes = [];
    let n = 0;
    state.layers.filter(l => l.map && l.visible).forEach(l => l.features.forEach(f => {
      if (!f.label || n > 300 || !frameVisible(f)) return;
      const a = labelAnchor(f.parts); if (!a) return;
      const p = this.map.project(a);
      if (p.x < -50 || p.y < -20 || p.x > W + 50 || p.y > H + 20) return;
      const w = f.label.length * 6.5 + 8, isPt = f.parts.points.length > 0;
      const b = [p.x - w / 2, p.y - (isPt ? 22 : 8), p.x + w / 2, p.y + (isPt ? 0 : 8)];
      if (boxes.some(o => !(b[2] < o[0] || b[0] > o[2] || b[3] < o[1] || b[1] > o[3]))) return;
      boxes.push(b);
      const el = document.createElement('div'); el.className = 'maplabel'; el.textContent = f.label;
      this.markers.push(new maplibregl.Marker({ element: el, anchor: isPt ? 'bottom' : 'center', offset: isPt ? [0, -7] : [0, 0] }).setLngLat(a).addTo(this.map));
      n++;
    }));
  },
  fit() {
    const b = unionBbox(state.layers.filter(l => l.map && l.visible).flatMap(l => l.features));
    if (!b) return;
    const lat = v => Math.max(-84, Math.min(84, v));
    let [x0, y0, x1, y1] = [b[0], lat(b[1]), b[2], lat(b[3])];
    if (x1 - x0 > 360) { x0 = -180; x1 = 180; }
    if (x0 === x1 && y0 === y1) { this.map.flyTo({ center: [x0, y0], zoom: 9 }); return; }
    this.map.fitBounds([[x0, y0], [x1, y1]], { padding: 50, maxZoom: 15, duration: 600 });
  },
  queryLayers() { return this.layers.flatMap(id => [id + '-pt', id + '-line', id + '-fill']); },
  onMove(e) {
    if (drawing.active && drawing.view === 'map') { drawing.hover([e.lngLat.lng, e.lngLat.lat]); return; }
    const hv = $('#mapHover');
    const feats = this.layers.length ? this.map.queryRenderedFeatures(e.point, { layers: this.queryLayers() }) : [];
    this.map.getCanvas().style.cursor = feats.length ? 'pointer' : '';
    if (!feats.length) { hv.style.display = 'none'; return; }
    const p = feats[0].properties;
    hv.innerHTML = rowTooltip(p.rs, p.row);
    hv.style.display = 'block';
    hv.style.left = Math.min(e.point.x + 16, this.map.getCanvas().clientWidth - 300) + 'px';
    hv.style.top = (e.point.y + 50) + 'px';
  },
  onClick(e) {
    if (drawing.active && drawing.view === 'map') { drawing.click([e.lngLat.lng, e.lngLat.lat]); return; }
    const feats = this.layers.length ? this.map.queryRenderedFeatures(e.point, { layers: this.queryLayers() }) : [];
    if (feats.length) selectRow(feats[0].properties.rs, feats[0].properties.row, 'map');
  },
  highlight(f) {
    if (!this.map || !this.ready) return;
    const src = this.map.getSource('sel');
    const data = { type: 'FeatureCollection', features: f ? this.toFeature(f, 0) : [] };
    if (src) src.setData(data);
    else {
      this.map.addSource('sel', { type: 'geojson', data });
      this.map.addLayer({ id: 'sel-line', type: 'line', source: 'sel', paint: { 'line-color': '#facc15', 'line-width': 4 } });
      this.map.addLayer({ id: 'sel-pt', type: 'circle', source: 'sel', filter: ['==', ['get', 'k'], 'point'], paint: { 'circle-radius': 8, 'circle-color': 'rgba(0,0,0,0)', 'circle-stroke-color': '#facc15', 'circle-stroke-width': 3 } });
    }
    ['sel-line', 'sel-pt'].forEach(id => this.map.moveLayer(id));
  },
};
$('#basemap').value = recall('basemap', 'osm');
$('#basemap').onchange = () => { store('basemap', $('#basemap').value); mapView.applyBasemap(); };
$('#btnFitMap').onclick = () => mapView.map && mapView.fit();
$('#btnGlobe').onclick = () => {
  if (!mapView.map) return;
  mapView.globe = !mapView.globe;
  try { mapView.map.setProjection({ type: mapView.globe ? 'globe' : 'mercator' }); } catch (e) { toast('Globe needs MapLibre 5'); }
  $('#btnGlobe').classList.toggle('active', mapView.globe);
};

/* ------------------------------------------------------------------ selection */
function selectRow(rs, row, from) {
  state.selected = { rs, row };
  const f = state.layers.flatMap(l => l.features).find(x => x.rs === rs && x.row === row);
  plane.render();
  mapView.highlight(f && MAP_MODES.has(f.mode) ? f : null);
  if (from !== 'grid') { state.activeRs = rs; renderResultTabs(); }
  highlightGridRow();
  const r = state.result.resultSets[rs];
  const spatialCol = r.columns.findIndex(c => c.spatial);
  if (spatialCol >= 0 && r.rows[row][spatialCol]) inspectCell(r.rows[row][spatialCol], r.columns[spatialCol].kind);
}

/* ------------------------------------------------------------------ results grid */
function renderResultTabs() {
  const sets = state.result ? state.result.resultSets : [];
  if (state.activeRs >= sets.length) state.activeRs = 0;
  $('#rsTabs').innerHTML = sets.map((r, i) => `<button class="${i === state.activeRs ? 'active' : ''}" data-i="${i}">RS ${i + 1} · ${r.rowCount}${r.truncated ? '+' : ''} rows</button>`).join('') +
    (sets.length ? '<span class="spacer"></span><button id="btnCsv">CSV</button>' : '');
  $$('#rsTabs button[data-i]').forEach(b => (b.onclick = () => { state.activeRs = +b.dataset.i; renderResultTabs(); }));
  if ($('#btnCsv')) $('#btnCsv').onclick = exportCsv;
  renderGrid();
}
function renderGrid() {
  const grid = $('#grid');
  const r = state.result && state.result.resultSets[state.activeRs];
  if (!r) { grid.innerHTML = `<div class="gridNote">${state.result ? 'No result sets.' : 'Run something to see results.'}</div>`; return; }
  const LIMIT = 2000;
  const rows = r.rows.slice(0, LIMIT);
  const head = '<tr><th></th>' + r.columns.map(c => `<th>${esc(c.name)}${c.spatial ? ` <span class="muted">(${esc(c.kind)})</span>` : ''}</th>`).join('') + '</tr>';
  const body = rows.map((row, ri) => `<tr data-r="${ri}"><td class="rn">${ri + 1}</td>` + row.map((v, ci) => {
    if (v === null) return '<td class="null">NULL</td>';
    if (v && v.$sp) return `<td class="spcell" data-c="${ci}" title="${esc(v.wkt)}"><span class="ty">${esc(v.type)}</span>SRID ${v.srid} · ${esc(v.wkt.slice(0, 90))}</td>`;
    if (typeof v === 'number') return `<td class="num">${esc(fmtNum(v))}</td>`;
    const s = String(v);
    return `<td title="${esc(s.length > 60 ? s.slice(0, 2000) : '')}">${esc(s.slice(0, 300))}</td>`;
  }).join('') + '</tr>').join('');
  grid.innerHTML = `<table><thead>${head}</thead><tbody>${body}</tbody></table>` +
    (r.rows.length > LIMIT ? `<div class="gridNote">Showing the first ${LIMIT} of ${r.rows.length} rows.</div>` : '') +
    (r.truncated ? `<div class="gridNote">Stopped at Max rows (${r.rowCount}).</div>` : '');
  $$('tbody tr', grid).forEach(tr => (tr.onclick = e => {
    const ri = +tr.dataset.r;
    const cell = e.target.closest('.spcell');
    if (cell) inspectCell(r.rows[ri][+cell.dataset.c], r.columns[+cell.dataset.c].kind, true);
    selectRow(state.activeRs, ri, 'grid');
  }));
  highlightGridRow();
}
function highlightGridRow() {
  $$('#grid tbody tr').forEach(tr => tr.classList.toggle('sel', state.selected && state.selected.rs === state.activeRs && +tr.dataset.r === state.selected.row));
}
function exportCsv() {
  const r = state.result.resultSets[state.activeRs];
  const q = v => { const s = v === null ? '' : v && v.$sp ? v.wkt : String(v); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
  const csv = [r.columns.map(c => q(c.name)).join(',')].concat(r.rows.map(row => row.map(q).join(','))).join('\n');
  download(`resultset${state.activeRs + 1}.csv`, csv, 'text/csv');
}
function download(name, text, type) {
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([text], { type })); a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

/* ------------------------------------------------------------------ messages */
function renderMessages() {
  const res = state.result;
  const html = res.messages.map(m => `<div class="msg ${m.kind}">${esc(m.text)}</div>`).join('') +
    (res.errors.length ? '' : `<div class="msg time">Completed in ${res.elapsedMs} ms (${res.batches} batch${res.batches === 1 ? '' : 'es'}).</div>`);
  $('#messages').innerHTML = html || '<p class="muted">No messages.</p>';
}

/* ------------------------------------------------------------------ inspector */
async function inspectCell(cell, kind, switchTab = false) {
  if (!cell || !cell.$sp) return;
  if (!cell.hex) { renderInspectorInput(`Binary not kept for this cell (large result). WKT: ${cell.wkt}`); return; }
  try {
    const info = await api('/api/inspect', { hex: cell.hex, kind });
    renderInspector(info, cell.hex);
    if (switchTab) showTab('inspector');
  } catch (e) { renderInspectorInput(e.message); }
}
function renderInspectorInput(msg = '') {
  $('#inspector').innerHTML = `<h3>Spatial binary inspector</h3>
    <p class="muted">Click a shape cell in Results (or a shape on the Map/Plane) to decode SQL Server's native serialisation byte by byte.
    Or paste a value from <code>SELECT CAST(shape AS varbinary(max))</code>:</p>
    <textarea id="hexIn" rows="3" placeholder="0x00000000010C000000000000F03F0000000000000040"></textarea>
    <p><select id="hexKind"><option value="unknown">guess type</option><option value="geometry">geometry</option><option value="geography">geography</option></select>
    <button class="btn primary" id="hexGo">Decode</button> <span class="st-bad">${esc(msg)}</span></p>`;
  $('#hexGo').onclick = async () => {
    try { const h = $('#hexIn').value.trim(); renderInspector(await api('/api/inspect', { hex: h, kind: $('#hexKind').value }), h.replace(/^0x/i, '')); }
    catch (e) { renderInspectorInput(e.message); }
  };
}
function renderInspector(info, hex) {
  const bytes = hex.replace(/\s+/g, '').match(/../g) || [];
  const owner = new Array(bytes.length).fill(-1);
  info.fields.forEach((f, i) => { for (let k = 0; k < f.length; k++) owner[f.offset + k] = i; });
  const hexHtml = bytes.slice(0, 6000).map((b, i) => {
    const fi = owner[i]; const g = fi >= 0 ? info.fields[fi].group : '';
    return `<span class="g-${g}" data-f="${fi}">${b.toUpperCase()}</span>`;
  }).join(' ') + (bytes.length > 6000 ? ' …' : '');
  const maxRows = 600;
  $('#inspector').innerHTML = `<h3>${esc(info.type)} · ${esc(info.interpretedAs)} · SRID ${info.srid}</h3>
    <div class="kv">
      <div>Serialisation version</div><div>${info.version} ${info.version === 2 ? '(curves or larger-than-hemisphere: SQL Server 2012+ format)' : '(classic format)'}</div>
      <div>Properties</div><div>${esc(info.properties)}</div>
      <div>Size</div><div>${info.bytes} bytes: ${info.points} points, ${info.figures} figures, ${info.shapes} shapes${info.version === 2 ? `, ${info.segments} segments` : ''}</div>
    </div>
    <div class="wkt">${esc(info.wkt)}</div>
    <div class="hexdump" id="hexdump">${hexHtml}</div>
    <table class="ftable"><thead><tr><th>offset</th><th>bytes</th><th>field</th><th>value</th><th>raw (little-endian)</th></tr></thead><tbody>
    ${info.fields.slice(0, maxRows).map((f, i) => `<tr data-f="${i}"><td>${f.offset}</td><td>${f.length}</td><td><span class="g-${f.group}">&nbsp;&nbsp;</span> ${esc(f.field)}</td><td>${esc(f.value)}</td><td>${esc(f.hex)}</td></tr>`).join('')}
    </tbody></table>${info.fields.length > maxRows ? `<p class="muted">… ${info.fields.length - maxRows} more fields</p>` : ''}
    <p><button class="btn small" id="hexAgain">Decode another value</button></p>`;
  $$('#inspector .ftable tr[data-f]').forEach(tr => {
    tr.onmouseenter = () => $$(`#hexdump span[data-f="${tr.dataset.f}"]`).forEach(s => s.classList.add('hl'));
    tr.onmouseleave = () => $$('#hexdump span.hl').forEach(s => s.classList.remove('hl'));
  });
  $('#hexAgain').onclick = () => renderInspectorInput();
}
renderInspectorInput();

/* ------------------------------------------------------------------ explain */
async function explain() {
  const sel = editor.getSelection();
  const sql = sel.trim() ? sel : editor.getValue();
  showTab('explain');
  $('#explain').innerHTML = '<p class="muted">Compiling…</p>';
  try {
    const res = await api('/api/explain', { sql });
    const total = res.statements.reduce((a, s) => a + s.cost, 0) || 1;
    const node = n => `<li><span class="op ${n.spatial ? 'spatial' : ''} ${n.vector ? 'vector' : ''}">
        ${n.spatial ? '<span class="badge spatial">SPATIAL INDEX</span>' : ''}${n.vector ? '<span class="badge vector">VECTOR</span>' : ''}
        <b>${esc(n.op)}</b>${n.logical && n.logical !== n.op ? `<span class="muted">${esc(n.logical)}</span>` : ''}
        ${n.object ? `<span class="obj">${esc(n.object)}</span>` : ''}
        <span class="cost">rows ${fmtNum(Math.round(n.rows * 10) / 10)} · cost ${(n.cost / total * 100).toFixed(1)}%</span>${n.parallel ? ' <span class="muted">∥</span>' : ''}</span>
        ${n.children.length ? `<ul>${n.children.map(node).join('')}</ul>` : ''}</li>`;
    $('#explain').innerHTML = (res.errors.map(e => `<p class="st-bad">${esc(e)}</p>`).join('')) +
      res.statements.filter(s => s.plan).map(s => `<div class="stmt"><pre>${esc(s.text)}</pre><div class="plan"><ul>${node(s.plan)}</ul></div></div>`).join('') ||
      '<p class="muted">No plans returned (statements without a query plan, such as DECLARE or SET, are skipped).</p>';
  } catch (e) { $('#explain').innerHTML = `<p class="st-bad">${esc(e.message)}</p>`; }
}
$('#btnExplain').onclick = explain;

/* ------------------------------------------------------------------ self-test */
async function selfTest() {
  showTab('selftest');
  const box = $('#selftest');
  box.innerHTML = `<div class="summary"><span id="stProg">Starting…</span><span class="st-ok" id="stOk"></span><span class="st-warn" id="stWarn"></span><span class="st-bad" id="stBad"></span></div>
    <table><thead><tr><th></th><th>pack</th><th>demo</th><th>ms</th><th>result sets</th><th>notes</th></tr></thead><tbody id="stBody"></tbody></table>`;
  let ok = 0, bad = 0, warn = 0, total = 0, n = 0;
  await streamNdjson('/api/selftest', m => {
    if (m.kind === 'start') total = m.total;
    if (m.kind !== 'demo') return;
    n++;
    const cls = m.ok ? (m.warning ? 'st-warn' : 'st-ok') : 'st-bad';
    if (!m.ok) bad++; else if (m.warning) warn++; else ok++;
    state.demoStatus[m.id] = m.ok ? (m.warning ? 'warn' : 'ok') : 'bad';
    $('#stBody').insertAdjacentHTML('beforeend', `<tr data-id="${esc(m.id)}"><td class="${cls}">${m.ok ? (m.warning ? '!' : '✓') : '✗'}</td><td>${esc(m.pack)}</td><td>${esc(m.title)}</td><td>${m.ms}</td><td>${m.resultSets}</td><td class="${cls}">${esc(m.errors.join(' | '))}</td></tr>`);
    $('#stProg').textContent = `${n} / ${total}`; $('#stOk').textContent = `${ok} passed`; $('#stWarn').textContent = warn ? `${warn} handled` : ''; $('#stBad').textContent = bad ? `${bad} failed` : '';
    const last = $('#stBody tr:last-child'); last.onclick = () => openDemo(last.dataset.id);
  });
  store('demoStatus', state.demoStatus); renderTree();
  $('#stProg').textContent = `Finished ${n} demos`;
}
$('#btnSelfTest').onclick = selfTest;
$('#btnSelfTest2').onclick = selfTest;

/* ------------------------------------------------------------------ drawing */
const drawing = {
  active: null, view: null, pts: [], cursor: null,
  start(kind, view) {
    this.active = kind; this.view = view; this.pts = []; this.cursor = null;
    $$('.draw').forEach(b => b.classList.toggle('active', b.dataset.draw === kind && b.closest('.tab').dataset.tab === view));
    $('#drawBox').hidden = false;
    $('#drawHint').textContent = kind === 'point' ? 'click to place' : 'click to add vertices, double-click to finish';
    $('#drawWkt').value = '';
    $('#plane').classList.toggle('drawing', view === 'plane');
    if (view === 'map' && mapView.map) { mapView.map.doubleClickZoom.disable(); mapView.map.getCanvas().style.cursor = 'crosshair'; }
    this.renderAll();
  },
  cancel() {
    if (!this.active) return;
    this.active = null; $$('.draw').forEach(b => b.classList.remove('active')); $('#plane').classList.remove('drawing');
    if (mapView.map) { mapView.map.doubleClickZoom.enable(); mapView.map.getCanvas().style.cursor = ''; }
    this.renderAll();
  },
  click(p) {
    if (!this.active) return;
    if (this.view === 'plane') { const z = Math.pow(10, Math.max(0, 3 - Math.floor(Math.log10(Math.abs(p[0]) + Math.abs(p[1]) + 1)))); p = [Math.round(p[0] * z) / z, Math.round(p[1] * z) / z]; }
    else p = [Math.round(p[0] * 1e6) / 1e6, Math.round(p[1] * 1e6) / 1e6];
    const last = this.pts[this.pts.length - 1];
    if (last && last[0] === p[0] && last[1] === p[1]) return;   // dblclick sends two clicks
    this.pts.push(p);
    if (this.active === 'point') { this.finish(); return; }
    this.updateWkt(); this.renderAll();
  },
  hover(p) { this.cursor = p; if (this.pts.length) this.renderAll(); },
  finish() {
    if (this.active === 'line' && this.pts.length < 2) return;
    if (this.active === 'polygon' && this.pts.length < 3) return;
    this.updateWkt(true);
    const kind = this.active; this.cursor = null; this.active = null;
    $$('.draw').forEach(b => b.classList.remove('active')); $('#plane').classList.remove('drawing');
    if (mapView.map) { mapView.map.doubleClickZoom.enable(); mapView.map.getCanvas().style.cursor = ''; }
    this.done = kind; this.renderAll();
  },
  updateWkt() {
    const c = p => `${p[0]} ${p[1]}`;
    let pts = this.pts.slice(), wkt = '';
    const kind = this.active || this.done;
    if (kind === 'point') wkt = `POINT (${c(pts[0])})`;
    else if (kind === 'line') wkt = `LINESTRING (${pts.map(c).join(', ')})`;
    else if (kind === 'polygon') {
      if (this.view === 'map') {   // geography wants the inside on the left: make the ring anticlockwise
        let a = 0; for (let i = 0; i < pts.length; i++) { const j = (i + 1) % pts.length; a += pts[i][0] * pts[j][1] - pts[j][0] * pts[i][1]; }
        if (a < 0) pts.reverse();
      }
      wkt = `POLYGON ((${pts.concat([pts[0]]).map(c).join(', ')}))`;
    }
    const expr = this.view === 'map' ? `geography::STGeomFromText('${wkt}', 4326)` : `geometry::STGeomFromText('${wkt}', 0)`;
    $('#drawWkt').value = expr;
  },
  geo() {
    const pts = this.pts.concat(this.cursor && this.active ? [this.cursor] : []);
    const kind = this.active || this.done;
    if (!pts.length) return { type: 'FeatureCollection', features: [] };
    const feats = pts.map(p => ({ type: 'Feature', properties: {}, geometry: { type: 'Point', coordinates: p } }));
    if (pts.length > 1) feats.push({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: kind === 'polygon' && pts.length > 2 ? pts.concat([pts[0]]) : pts } });
    return { type: 'FeatureCollection', features: feats };
  },
  renderAll() {
    plane.render();
    if (mapView.map && mapView.ready) {
      const data = this.view === 'map' ? this.geo() : { type: 'FeatureCollection', features: [] };
      const src = mapView.map.getSource('draw');
      if (src) src.setData(data);
      else {
        mapView.map.addSource('draw', { type: 'geojson', data });
        mapView.map.addLayer({ id: 'draw-line', type: 'line', source: 'draw', paint: { 'line-color': '#ec4899', 'line-width': 2.5, 'line-dasharray': [2, 1] } });
        mapView.map.addLayer({ id: 'draw-pt', type: 'circle', source: 'draw', filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-radius': 4, 'circle-color': '#ec4899' } });
      }
    }
  },
  renderPlane(ctx, toScreen) {
    if (this.view !== 'plane') return;
    const pts = this.pts.concat(this.cursor && this.active ? [this.cursor] : []);
    if (!pts.length) return;
    const kind = this.active || this.done;
    ctx.strokeStyle = '#ec4899'; ctx.fillStyle = '#ec4899'; ctx.lineWidth = 2; ctx.setLineDash([6, 4]);
    ctx.beginPath(); pts.forEach((p, i) => { const [x, y] = toScreen(p[0], p[1]); i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); });
    if (kind === 'polygon' && pts.length > 2) ctx.closePath();
    ctx.stroke(); ctx.setLineDash([]);
    pts.forEach(p => { const [x, y] = toScreen(p[0], p[1]); ctx.beginPath(); ctx.arc(x, y, 3.5, 0, 7); ctx.fill(); });
  },
};
$$('.draw').forEach(b => (b.onclick = () => {
  const view = b.closest('.tab').dataset.tab;
  if (view === 'map') mapView.ensure();
  drawing.done = null; drawing.start(b.dataset.draw, view);
}));
$('#btnDrawDone').onclick = () => { drawing.cancel(); drawing.pts = []; drawing.done = null; drawing.renderAll(); $('#drawBox').hidden = true; };
$('#btnDrawCopy').onclick = () => { navigator.clipboard.writeText($('#drawWkt').value).then(() => toast('Copied')); };
$('#btnDrawInsert').onclick = () => {
  const txt = $('#drawWkt').value; if (!txt) return;
  const doc = editor.getDoc();
  // In the sketch demo, swap the sketch literal; otherwise insert at the cursor
  const v = editor.getValue();
  const m = v.match(/DECLARE @sketch geometry = '([^']*)'/);
  if (m && drawing.view === 'plane') {
    const wkt = txt.match(/'([^']*)'/)[1];
    editor.setValue(v.replace(m[0], `DECLARE @sketch geometry = '${wkt}'`));
    toast('Sketch replaced - press Run');
  } else { doc.replaceSelection(txt); toast('Inserted at the cursor'); }
  editor.focus();
};

/* ------------------------------------------------------------------ export GeoJSON */
function exportGeoJSON(mapLayers) {
  const feats = [];
  state.layers.filter(l => l.visible && l.map === mapLayers).forEach(l => l.features.forEach(f => {
    const rs = state.result.resultSets[f.rs];
    const props = {};
    rs.columns.forEach((c, i) => { if (!c.spatial) props[c.name] = rs.rows[f.row][i]; });
    const geoms = [];
    if (f.parts.polys.length) geoms.push({ type: 'MultiPolygon', coordinates: f.parts.polys });
    if (f.parts.lines.length) geoms.push({ type: 'MultiLineString', coordinates: f.parts.lines });
    if (f.parts.points.length) geoms.push({ type: 'MultiPoint', coordinates: f.parts.points });
    const geometry = geoms.length === 1 ? geoms[0] : { type: 'GeometryCollection', geometries: geoms };
    feats.push({ type: 'Feature', properties: { layer: l.name, ...props }, geometry });
  }));
  if (!feats.length) { toast('Nothing to export'); return; }
  download(mapLayers ? 'spatial-studio-map.geojson' : 'spatial-studio-plane.geojson', JSON.stringify({ type: 'FeatureCollection', features: feats }), 'application/geo+json');
}
$('#btnExportMap').onclick = () => exportGeoJSON(true);
$('#btnExportPlane').onclick = () => exportGeoJSON(false);

/* ------------------------------------------------------------------ import GeoJSON */
$('#btnImport').onclick = () => {
  openModal('Import GeoJSON into SQL Server', `
    <p class="muted">The file is parsed inside SQL Server by <code>sx.GeoJsonFeatures</code> (recursive OPENJSON) into a new table in the <code>lab</code> schema.</p>
    <div class="form">
      <label>GeoJSON file</label><input type="file" id="iFile" accept=".json,.geojson,application/geo+json,application/json">
      <label>Table name</label><input type="text" id="iName" value="Imported">
      <label>SRID</label><input type="number" id="iSrid" value="4326">
      <label></label><label class="small"><input type="checkbox" id="iGeog" checked> Also make a geography column (lon/lat data)</label>
      <div class="full"><button class="btn primary" id="iGo">Import</button> <span id="iMsg" class="muted"></span></div>
    </div>`);
  $('#iFile').onchange = () => { const f = $('#iFile').files[0]; if (f) $('#iName').value = f.name.replace(/\.[^.]+$/, '').replace(/[^A-Za-z0-9_]/g, '_'); };
  $('#iGo').onclick = async () => {
    const f = $('#iFile').files[0]; if (!f) { $('#iMsg').textContent = 'Choose a file first.'; return; }
    $('#iMsg').textContent = 'Importing…';
    try {
      const text = await f.text();
      const res = await api('/api/import-geojson', { table: $('#iName').value, srid: +$('#iSrid').value, geography: $('#iGeog').checked, geojson: text });
      closeModal();
      state.demo = null; $('#demoTitle').textContent = `Imported ${res.table}`; $('#demoDesc').textContent = `${res.rows} features loaded.`; $('#demoTags').innerHTML = '';
      editor.setValue(res.query); run();
    } catch (e) { $('#iMsg').textContent = e.message; }
  };
};

/* ------------------------------------------------------------------ help */
$('#btnHelp').onclick = () => openModal('Spatial Studio help', `<div class="help">
  <h4>Running</h4>
  <table><tr><td><code>Ctrl+Enter</code> / <code>F5</code></td><td>Run the script, or just the selection</td></tr>
  <tr><td><code>Ctrl+L</code></td><td>Explain (estimated plan) - spatial and vector index operators are highlighted</td></tr>
  <tr><td><code>Ctrl+Space</code></td><td>Autocomplete</td></tr><tr><td>Double-click a demo</td><td>Open and run it</td></tr></table>
  <p><code>GO</code> separates batches, as in SSMS. Every spatial column of every result set becomes a layer.</p>
  <h4>Styling columns</h4>
  <table><tr><td><code>color</code></td><td>Any CSS colour per row: <code>'#e15759'</code>, <code>'hsl(200,70%,50%)'</code></td></tr>
  <tr><td><code>label</code></td><td>Text drawn on the shape</td></tr>
  <tr><td><code>frame</code></td><td>Animation frame number. Rows with no frame column stay visible throughout.</td></tr>
  <tr><td><code>opacity</code></td><td>Fill opacity 0-1 (default 0.55; use 1 for solid cartoon colour)</td></tr>
  <tr><td><code>linewidth</code></td><td>Outline width in screen pixels (0 = no outline)</td></tr>
  <tr><td><code>fontsize</code></td><td>Label size in pixels</td></tr></table>
  <h4>Where shapes are drawn</h4>
  <p><b>Map</b>: geography, and geometry whose SRID is geodetic (e.g. 4326, treated as lon/lat) or 3857 (Web Mercator, reprojected for you).
  <b>Plane</b>: every other geometry, in its own units. Geography edges are drawn as true geodesics; arcs are drawn as arcs.</p>
  <p>The tool decodes SQL Server's native binary itself. For the first result set of each batch it asks <code>sp_describe_first_result_set</code>
  whether a column is geometry or geography; for later result sets it uses the column name (<code>geom…</code> / <code>geog…</code>) and SRID.</p>
  <h4>Drawing</h4><p>Pick Point, Line or Polygon above the Map or Plane, click to add vertices, double-click to finish, then insert the WKT into the editor.
  In the "Query by sketch" demo, Insert replaces the sketch.</p>
  <h4>Data</h4><p>Countries: Natural Earth 1:110m (public domain). Cities: GeoNames cities15000 (CC BY 4.0). Basemap: © OpenStreetMap contributors.
  Sqlford is generated by <code>sql/install/05_town.sql</code>.</p></div>`);

/* ------------------------------------------------------------------ boot */
(async function boot() {
  const t = recall('theme', null); if (t) applyTheme(t);
  $('.brand').onclick = () => $('.sidebar').classList.toggle('open');
  showTab('plane');
  await loadDemos();
  const last = recall('demo', null);
  if (last && findDemo(last)) {
    const d = findDemo(last); state.demo = d;
    $('#demoTitle').textContent = d.title; $('#demoDesc').textContent = d.desc;
    $('#demoTags').innerHTML = d.tags.map(x => `<span class="tag">${esc(x)}</span>`).join('');
    renderTree();
  }
  const s = await refreshStatus();
  if (s && s.connected && !s.installed) toast('Connected. Press "Install sample DB" to create the demo data.', 6000);
  if (s && !s.connected) setTimeout(connectDialog, 400);
  plane.resize();
})();
