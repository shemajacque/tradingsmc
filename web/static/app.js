const $ = (id) => document.getElementById(id);
const esc = (v) => String(v ?? "").replace(/[&<>"]/g,
  c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));

function msg(text, ok = true) {
  const el = $('msg');
  el.textContent = text;
  el.className = 'msg ' + (ok ? 'ok' : 'err');
}

async function api(path, options = {}) {
  const r = await fetch(path, options);
  if (!r.ok) {
    let detail = r.statusText;
    try { detail = (await r.json()).detail || detail; } catch (e) {}
    throw new Error(detail);
  }
  return r.json();
}

function card(label, value, cls = '') {
  return `<div class="card"><div class="label">${esc(label)}</div>
    <div class="value ${cls}">${esc(value)}</div></div>`;
}

async function refreshStatus() {
  try {
    const d = await api('/api/status');
    const s = d.status || {};
    const c = d.config || {};
    const connected = !!s.connected;
    $('conn').textContent = connected ? 'EA online' : 'EA offline';
    $('conn').className = 'pill ' + (connected ? 'pill-on' : 'pill-off');

    const live = !!c.live;
    $('cards').innerHTML =
      card('EA / compile', d.ea_compiled ? (connected ? 'running' : 'compiled') : 'missing',
           d.ea_compiled ? 'pos' : 'neg') +
      card('Trading', c.enabled ? 'enabled' : 'disabled', c.enabled ? 'pos' : 'neg') +
      card('Mode', live ? 'LIVE' : 'PAPER', live ? 'neg' : 'pos') +
      card('Risk / trade', (Number(c.risk_percent)).toFixed(2) + '%') +
      card('Max spread', c.max_spread) +
      card('Score min', c.score_min) +
      card('Positions', s.positions ?? '-') +
      card('Equity', s.equity ?? '-') +
      card('Bias', s.bias ?? '-') +
      card('Day type', s.day_type ?? '-') +
      card('Last signal', s.last_signal_reason || 'NONE') +
      card('Kill switch', Number(c.kill_switch) ? 'ARMED' : 'off',
           Number(c.kill_switch) ? 'neg' : 'pos') +
      card('Heartbeat', connected ? 'ok' : 'stale');

    const kb = $('btnKill');
    kb.textContent = Number(c.kill_switch) ? 'DISARM KILL SWITCH' : 'ARM KILL SWITCH';
    kb.className = Number(c.kill_switch) ? 'danger armed' : 'danger';

    for (const k of ['enabled','live']) $(k).checked = !!c[k];
    for (const k of ['risk_percent','max_spread','max_trades','score_min']) $(k).value = c[k];
  } catch (e) {
    msg('Status error: ' + e.message, false);
  }
}

async function refreshLog() {
  try {
    const d = await api('/api/log?limit=80');
    const rows = d.rows || [];
    $('logTable').querySelector('tbody').innerHTML = rows.map(r =>
      `<tr><td>${esc(r.time_local)}</td><td>${esc(r.symbol)}</td>
       <td>${esc(r.event)}</td><td>${esc(r.reason)}</td>
       <td>${esc(r.setup)}</td><td>${esc(r.dir)}</td>
       <td>${esc(r.entry)}</td><td>${esc(r.sl)}</td><td>${esc(r.score)}</td></tr>`
    ).join('') || '<tr><td colspan="9" class="muted">No decisions logged yet.</td></tr>';
  } catch (e) { msg('Log error: ' + e.message, false); }
}

async function refreshEquity() {
  try {
    const d = await api('/api/equity');
    const pts = d.points || [];
    const cv = $('equityChart');
    const ctx = cv.getContext('2d');
    const W = cv.width = cv.clientWidth;
    const H = cv.height = 180;
    ctx.clearRect(0, 0, W, H);
    if (!pts.length) { $('equityMeta').textContent = 'No equity points yet.'; return; }
    const ys = pts.map(p => p[1]);
    const lo = Math.min(...ys), hi = Math.max(...ys);
    const span = (hi - lo) || 1;
    ctx.strokeStyle = '#2f81f7';
    ctx.lineWidth = 2;
    ctx.beginPath();
    pts.forEach((p, i) => {
      const x = (i / Math.max(1, pts.length - 1)) * (W - 12) + 6;
      const y = H - 10 - ((p[1] - lo) / span) * (H - 24);
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    });
    ctx.stroke();
    $('equityMeta').textContent =
      `${pts.length} points | first ${ys[0]} | last ${ys[ys.length-1]}`;
  } catch (e) { msg('Chart error: ' + e.message, false); }
}

async function refreshReports() {
  try {
    const d = await api('/api/reports');
    const mc = d.montecarlo || {};
    $('mc').textContent = mc.runs
      ? `Monte Carlo ${mc.runs} runs | total R P05/P50/P95 ` +
        `${mc.total_R_p05}/${mc.total_R_p50}/${mc.total_R_p95} | ` +
        `maxDD R P05/P50/P95 ${mc.max_dd_R_p05}/${mc.max_dd_R_p50}/` +
        `${mc.max_dd_R_p95} | profit prob ${mc.prob_profit}`
      : 'No Monte Carlo data yet.';
    $('reportTable').querySelector('tbody').innerHTML = (d.summary || []).map(r =>
      `<tr><td>${esc(r.variant)}</td><td>${esc(r.poi_model)}</td>
       <td>${esc(r.n)}</td><td>${esc(r.win_rate)}</td>
       <td>${esc(r.avg_R)}</td><td>${esc(r.profit_factor)}</td>
       <td>${esc(r.max_dd_pct)}</td></tr>`
    ).join('') || '<tr><td colspan="7" class="muted">Run python/python/report.py.</td></tr>';
  } catch (e) { msg('Report error: ' + e.message, false); }
}

$('cfgForm').addEventListener('submit', async (e) => {
  e.preventDefault();
  const pw = $('password').value;
  if (!pw) { msg('Enter the web password first.', false); return; }
  const payload = {
    enabled: $('enabled').checked ? 1 : 0,
    live: $('live').checked ? 1 : 0,
    risk_percent: Number($('risk_percent').value),
    max_spread: Number($('max_spread').value),
    max_trades: Number($('max_trades').value),
    score_min: Number($('score_min').value),
  };
  try {
    await api('/api/config', {method:'POST',
      headers:{'Content-Type':'application/json','X-SMC-Password':pw},
      body:JSON.stringify(payload)});
    msg('Saved. The EA applies it within 60 seconds.');
    refreshStatus();
  } catch (err) { msg('Save failed: ' + err.message, false); }
});

$('btnReset').addEventListener('click', async () => {
  const pw = $('password').value;
  if (!pw) { msg('Enter the web password first.', false); return; }
  try {
    await api('/api/config/reset', {method:'POST', headers:{'X-SMC-Password':pw}});
    msg('Defaults restored.'); refreshStatus();
  } catch (e) { msg('Reset failed: ' + e.message, false); }
});

$('btnKill').addEventListener('click', async () => {
  const pw = $('password').value;
  if (!pw) { msg('Enter the web password first.', false); return; }
  const armed = Number((await api('/api/config')).kill_switch) ? 0 : 1;
  if (armed && !window.confirm('ARM kill switch? This cancels pending orders and closes all positions.')) return;
  try {
    await api('/api/config', {method:'POST',
      headers:{'Content-Type':'application/json','X-SMC-Password':pw},
      body:JSON.stringify({kill_switch: armed})});
    msg(armed ? 'Kill switch ARMED - flattening and halting.' : 'Kill switch disarmed.');
    refreshStatus();
  } catch (e) { msg('Kill switch failed: ' + e.message, false); }
});

$('btnCompile').addEventListener('click', async () => {
  const pw = $('password').value;
  if (!pw) { msg('Enter the web password first.', false); return; }
  msg('Compiling...');
  try {
    const r = await api('/api/compile', {method:'POST', headers:{'X-SMC-Password':pw}});
    msg(r.returncode === 0 ? 'Compile OK' : 'Compile failed: ' + r.output.slice(-300),
        r.returncode === 0);
  } catch (e) { msg('Compile failed: ' + e.message, false); }
});

function tick() {
  $('clock').textContent = new Date().toLocaleTimeString();
}
setInterval(tick, 1000);
setInterval(() => { refreshStatus(); refreshLog(); refreshEquity(); }, 5000);
tick(); refreshStatus(); refreshLog(); refreshEquity(); refreshReports();
