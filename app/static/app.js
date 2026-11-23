const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));

let overviewTimer = null;
let liveTimer = null;
let liveCurrency = "USD";
let liveTicks = 0;
let agentTimer = null;

function esc(v) {
  return String(v ?? "").replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]));
}
function money(v, cur = "USD") {
  const n = Number(v || 0);
  try { return n.toLocaleString(undefined, { style: "currency", currency: cur, maximumFractionDigits: 2 }); }
  catch { return n.toFixed(2); }
}
function pct(v) { return v == null ? "-" : (Number(v) * 100).toFixed(1) + "%"; }
function tstr(ts) {
  if (!ts) return "never";
  const d = new Date(Number(ts) * 1000);
  return d.toLocaleString();
}
function ago(ts) {
  if (!ts) return "never";
  const s = Math.max(0, Date.now() / 1000 - Number(ts));
  if (s < 60) return Math.round(s) + "s ago";
  if (s < 3600) return Math.round(s / 60) + "m ago";
  if (s < 86400) return Math.round(s / 3600) + "h ago";
  return Math.round(s / 86400) + "d ago";
}
function toast(msg, err = false) {
  const el = $("#toast");
  el.textContent = msg;
  el.className = "toast" + (err ? " err" : "");
  clearTimeout(el._t);
  el._t = setTimeout(() => el.classList.add("hidden"), 4200);
}

async function api(path, method = "GET", body = null) {
  const opt = { method, credentials: "same-origin", headers: {} };
  if (body !== null) {
    opt.headers["Content-Type"] = "application/json";
    opt.body = JSON.stringify(body);
  }
  const res = await fetch(path, opt);
  let data = {};
  try { data = await res.json(); } catch (e) { /* empty */ }
  if (res.status === 401) {
    showLogin();
    throw new Error(data.detail || "login required");
  }
  if (!res.ok) throw new Error(data.detail || ("HTTP " + res.status));
  return data;
}

function showLogin() {
  $("#app").classList.add("hidden");
  $("#login").classList.remove("hidden");
  if (overviewTimer) clearInterval(overviewTimer);
  if (liveTimer) clearInterval(liveTimer);
  if (agentTimer) clearInterval(agentTimer);
  overviewTimer = null;
  liveTimer = null;
  agentTimer = null;
}
function showApp() {
  $("#login").classList.add("hidden");
  $("#app").classList.remove("hidden");
  if (!overviewTimer) {
    overviewTimer = setInterval(() => {
      loadOverview().catch(() => {});
      if ($("#tab-tokens").classList.contains("active")) loadTokens().catch(() => {});
    }, 10000);
  }
  if (!agentTimer) {
    agentTimer = setInterval(() => {
      if (document.hidden) return;
      if ($("#tab-agent").classList.contains("active")) loadAgent().catch(() => {});
    }, 5000);
  }
  if (!liveTimer) {
    liveTimer = setInterval(() => {
      if (document.hidden) return;
      if ($("#tab-live").classList.contains("active")) {
        loadLive(false).catch(() => {});
        if (++liveTicks % 10 === 0) {
          loadAnalytics().catch(() => {});
          loadEquity().catch(() => {});
        }
      }
    }, 3000);
  }
}

// ---------------------------------------------------------------------------
// login
// ---------------------------------------------------------------------------
$("#login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  try {
    await api("/api/admin/login", "POST", { password: $("#password").value });
    $("#password").value = "";
    showApp();
    await Promise.all([loadOverview(), loadTokens(), loadBacktests()]);
  } catch (err) {
    $("#login-msg").textContent = err.message;
  }
});
$("#logout").addEventListener("click", async () => {
  try { await api("/api/admin/logout", "POST"); } catch (e) { /* ignore */ }
  showLogin();
});

// ---------------------------------------------------------------------------
// tabs
// ---------------------------------------------------------------------------
$$(".tab").forEach(btn => btn.addEventListener("click", () => {
  $$(".tab").forEach(b => b.classList.toggle("active", b === btn));
  $$(".tabpane").forEach(p => p.classList.toggle("active", p.id === "tab-" + btn.dataset.tab));
  if (btn.dataset.tab === "live") refreshLive().catch(e => toast(e.message, true));
  if (btn.dataset.tab === "agent") loadAgent().catch(e => toast(e.message, true));
  if (btn.dataset.tab === "tokens") loadTokens().catch(e => toast(e.message, true));
  if (btn.dataset.tab === "research") loadBacktests().catch(e => toast(e.message, true));
}));

// ---------------------------------------------------------------------------
// overview
// ---------------------------------------------------------------------------
async function loadOverview() {
  const d = await api("/api/admin/overview");
  const live = d.live || {};
  $("#s-online").textContent = d.stats.online;
  $("#s-pos").textContent = live.available ? live.position_count : d.stats.positions;
  $("#s-pos-note").textContent = live.available ? "direct from MT5" : "across all bots";
  const cur = (d.tokens.find(t => t.heartbeat && t.heartbeat.currency) || {}).heartbeat?.currency || "USD";
  $("#s-profit").textContent = money(d.stats.profit, cur);
  $("#s-wr").textContent = d.stats.win_rate == null ? "-" : pct(d.stats.win_rate);
  $("#s-trades").textContent = d.stats.trades + " closed trades";
  $("#conn-dot").className = "dot" + ((d.stats.online > 0 || live.available) ? " on" : "");
  $("#last-update").textContent = "updated " + new Date().toLocaleTimeString();
  $("#server-mode").textContent = live.available
    ? "Direct MT5 " + live.account.trade_mode
    : (d.demo_only_default ? "Demo-only server" : "Live-capable server");

  const bots = $("#bots");
  if (!d.tokens.length) {
    bots.innerHTML = `<p class="muted">No tokens yet. Create one in <b>Bots &amp; tokens</b>.</p>`;
  } else {
    bots.innerHTML = d.tokens.map(t => {
      const h = t.heartbeat || {};
      const status = !t.enabled ? `<span class="pill off">DISABLED</span>`
        : t.online ? `<span class="pill ok">ONLINE</span>`
        : `<span class="pill idle">WAITING</span>`;
      return `<div class="bot">
        <div class="who">
          <b>${esc(t.label)}</b>
          <span>${esc(t.login || "-")} &middot; ${esc(t.server || "any server")} &middot; ${t.demo_only ? "demo only" : "live allowed"}</span>
          <span>last seen ${ago(t.last_seen)}${h.balance != null ? " &middot; balance " + money(h.balance, h.currency) : ""}</span>
        </div>
        <div class="num">
          ${status}
          <strong>${h.equity != null ? money(h.equity, h.currency) : "-"}</strong>
          <span>${h.positions ?? 0} open &middot; risk ${t.risk_pct}%</span>
        </div>
      </div>`;
    }).join("");
  }

  const ev = $("#events");
  ev.innerHTML = d.events.length ? d.events.map(e => `
    <div class="event ${e.level === "warn" ? "warn" : ""}">
      <b>${esc(e.msg)}</b><span>${tstr(e.ts)}</span>
    </div>`).join("") : `<p class="muted">No activity yet.</p>`;
}

// ---------------------------------------------------------------------------
// direct MT5 account
// ---------------------------------------------------------------------------
function num(v, d = 2) {
  const n = Number(v);
  return Number.isFinite(n) ? n.toFixed(d) : "-";
}
function livePl(v, cur) {
  const n = Number(v || 0);
  return `<span class="${n > 0 ? "positive" : n < 0 ? "negative" : ""}">${money(n, cur)}</span>`;
}

async function refreshLive() {
  await Promise.all([loadLive(true), loadAnalytics(), loadEquity()]);
}

async function loadLive(withHistory = true) {
  const d = await api("/api/admin/live");
  const banner = $("#live-banner");
  if (!d.available) {
    banner.className = "banner warn";
    banner.classList.remove("hidden");
    banner.textContent = "Direct MT5 unavailable: " + (d.reason || "unknown") +
      ". Direct access needs the app and MT5 on the same Windows machine; on a hosted server use the EA heartbeat.";
    $("#l-balance").textContent = $("#l-equity").textContent = $("#l-free").textContent = "-";
    $("#l-pos").textContent = "-";
    $("#l-account").textContent = $("#l-profit").textContent = $("#l-margin").textContent = $("#l-orders").textContent = "";
    $("#l-details").innerHTML = "";
    $("#l-mode").textContent = "OFFLINE";
    $("#l-mode").className = "pill idle";
    $("#live-pos-rows").innerHTML = `<tr><td colspan="10" class="muted">No direct MT5 data.</td></tr>`;
    $("#live-order-rows").innerHTML = `<tr><td colspan="8" class="muted">No direct MT5 data.</td></tr>`;
    $("#live-deal-rows").innerHTML = `<tr><td colspan="8" class="muted">No direct MT5 data.</td></tr>`;
    return;
  }

  const a = d.account;
  const cur = a.currency || "USD";
  liveCurrency = cur;
  const locked = !a.demo && !d.allow_live_trading;
  if (locked || !a.trade_allowed) {
    banner.className = "banner warn";
    banner.classList.remove("hidden");
    banner.textContent = locked
      ? "LIVE account connected. Manual orders are locked on this server; set SMC_ALLOW_LIVE_TRADING=1 to unlock."
      : "Trading is disabled in the MT5 terminal (AutoTrading / account permission).";
  } else {
    banner.classList.add("hidden");
  }

  $("#l-balance").textContent = money(a.balance, cur);
  $("#l-account").textContent = `${a.login} · ${a.server}`;
  $("#l-equity").textContent = money(a.equity, cur);
  $("#l-profit").innerHTML = "floating " + livePl(a.profit, cur);
  $("#l-free").textContent = money(a.margin_free, cur);
  $("#l-margin").textContent = "used " + money(a.margin, cur) +
    (a.margin_level ? " · " + num(a.margin_level, 1) + "%" : "");
  $("#l-pos").textContent = d.position_count;
  $("#l-orders").textContent = d.order_count + " pending orders";
  $("#l-mode").textContent = a.trade_mode.toUpperCase();
  $("#l-mode").className = "pill " + (a.demo ? "ok" : "off");

  const details = [
    ["Login", a.login], ["Server", a.server], ["Currency", a.currency],
    ["Leverage", "1:" + a.leverage], ["Company", a.company || "-"],
    ["Trading", a.trade_allowed ? "enabled" : "disabled"],
    ["EA trading", a.trade_expert ? "enabled" : "disabled"],
    ["Mode", a.trade_mode],
  ];
  $("#l-details").innerHTML = details.map(([k, v]) =>
    `<div class="kv"><span>${esc(k)}</span><b>${esc(v)}</b></div>`).join("");

  const posRows = $("#live-pos-rows");
  if (!d.positions.length) {
    posRows.innerHTML = `<tr><td colspan="12" class="muted">No open positions.</td></tr>`;
  } else {
    posRows.innerHTML = d.positions.map(p => `<tr>
      <td>${p.ticket}</td>
      <td><b>${esc(p.symbol)}</b><div class="sub">${tstr(p.time)}</div></td>
      <td><span class="pill ${p.side === "BUY" ? "ok" : "off"}">${esc(p.side)}</span></td>
      <td>${num(p.volume)}</td>
      <td>${num(p.open, 5)}</td>
      <td>${num(p.current, 5)}</td>
      <td class="sub">${p.sl ? num(p.sl, 5) : "-"}</td>
      <td class="sub">${p.tp ? num(p.tp, 5) : "-"}</td>
      <td>${livePl(p.profit, cur)}</td>
      <td>${p.risk == null ? "-" : livePl(p.risk, cur)}</td>
      <td class="sub">${p.rr == null ? "-" : num(p.rr, 2) + "R"}</td>
      <td><div class="actions">
        <button class="btn sm" data-be="${p.ticket}">BE</button>
        <button class="btn sm" data-partial="${p.ticket}">Part</button>
        <button class="btn sm" data-mod="${p.ticket}">SL/TP</button>
        <button class="btn sm danger" data-close="${p.ticket}">Close</button>
      </div></td>
    </tr>`).join("");
  }

  const orderRows = $("#live-order-rows");
  if (!d.orders.length) {
    orderRows.innerHTML = `<tr><td colspan="8" class="muted">No pending orders.</td></tr>`;
  } else {
    orderRows.innerHTML = d.orders.map(o => `<tr>
      <td>${o.ticket}</td><td><b>${esc(o.symbol)}</b></td><td>${esc(o.type)}</td>
      <td>${num(o.volume)}</td><td>${num(o.open, 5)}</td>
      <td class="sub">${o.sl ? num(o.sl, 5) : "-"}</td>
      <td class="sub">${o.tp ? num(o.tp, 5) : "-"}</td>
      <td class="sub">${esc(o.comment || "-")}</td>
    </tr>`).join("");
  }

  $$("[data-close]").forEach(b => b.addEventListener("click", async () => {
    const p = d.positions.find(x => String(x.ticket) === b.dataset.close);
    if (!p || !confirm(`Close #${p.ticket} ${p.side} ${p.volume} ${p.symbol}?`)) return;
    try {
      await api(`/api/admin/live/positions/${p.ticket}/close`, "POST", { confirm: true });
      toast(`Closed #${p.ticket}`);
      await Promise.all([refreshLive(), loadOverview()]);
    } catch (e) { toast(e.message, true); }
  }));

  $$("[data-be]").forEach(b => b.addEventListener("click", async () => {
    const p = d.positions.find(x => String(x.ticket) === b.dataset.be);
    if (!p || !confirm(`Move #${p.ticket} SL to break-even (+2 points)?`)) return;
    try {
      const r = await api(`/api/admin/live/positions/${p.ticket}/break-even`,
                          "POST", { buffer_points: 2, confirm: true });
      toast(`Break-even SL ${num(r.result.sl, 5)}`);
      await refreshLive();
    } catch (e) { toast(e.message, true); }
  }));

  $$("[data-partial]").forEach(b => b.addEventListener("click", () => {
    const p = d.positions.find(x => String(x.ticket) === b.dataset.partial);
    if (!p) return;
    const half = Math.max(0.01, +(p.volume * 0.5).toFixed(2));
    openModal(`
      <h2>Partial close #${p.ticket}</h2>
      <p class="muted">${esc(p.symbol)} ${esc(p.side)} · position ${num(p.volume)} lots. Close less than the full volume.</p>
      <form id="partial-form" class="form-grid">
        <div class="full"><label>Volume to close (max ${num(p.volume)})</label>
          <input name="volume" type="number" step="0.01" min="0.01" max="${p.volume}" value="${half}" required></div>
        <div class="full"><button class="btn danger" type="submit">Close volume</button></div>
      </form>`);
    $("#partial-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const vol = Number(new FormData(e.target).get("volume"));
      if (!vol || vol > p.volume) { toast("Volume must be between 0 and the position size", true); return; }
      if (!confirm(`Close ${vol} lots of #${p.ticket}?`)) return;
      try {
        await api(`/api/admin/live/positions/${p.ticket}/close`, "POST",
                  { volume: vol, confirm: true });
        closeModal();
        toast(`Closed ${vol} lots of #${p.ticket}`);
        await Promise.all([refreshLive(), loadOverview()]);
      } catch (err) { toast(err.message, true); }
    });
  }));

  $$("[data-mod]").forEach(b => b.addEventListener("click", () => {
    const p = d.positions.find(x => String(x.ticket) === b.dataset.mod);
    if (!p) return;
    openModal(`
      <h2>Modify #${p.ticket} ${esc(p.symbol)}</h2>
      <p class="muted">Leave a field empty to keep its current value. Enter 0 to remove a level.</p>
      <form id="mod-form" class="form-grid">
        <div><label>Stop loss</label><input name="sl" type="number" step="any" value="${p.sl || ""}"></div>
        <div><label>Take profit</label><input name="tp" type="number" step="any" value="${p.tp || ""}"></div>
        <div class="full"><button class="btn primary" type="submit">Update</button></div>
      </form>`);
    $("#mod-form").addEventListener("submit", async (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      const sl = f.get("sl") === "" ? null : Number(f.get("sl"));
      const tp = f.get("tp") === "" ? null : Number(f.get("tp"));
      try {
        await api(`/api/admin/live/positions/${p.ticket}/modify`, "POST",
                  { sl, tp, confirm: true });
        closeModal();
        toast("SL/TP updated");
        await refreshLive();
      } catch (err) { toast(err.message, true); }
    });
  }));

  if (withHistory) await loadLiveHistory(cur);
}

async function loadLiveHistory(cur = "USD") {
  const d = await api("/api/admin/live/history?days=7&limit=50");
  const rows = $("#live-deal-rows");
  if (!d.available) {
    rows.innerHTML = `<tr><td colspan="8" class="muted">${esc(d.reason || "history unavailable")}</td></tr>`;
    return;
  }
  if (!d.deals.length) {
    rows.innerHTML = `<tr><td colspan="8" class="muted">No deals in the last 7 days.</td></tr>`;
    return;
  }
  rows.innerHTML = d.deals.map(x => `<tr>
    <td class="sub">${tstr(x.time)}</td>
    <td>${esc(x.symbol || "-")}</td>
    <td>${esc(x.type)}</td>
    <td class="sub">${esc(x.entry)}</td>
    <td>${num(x.volume)}</td>
    <td>${num(x.price, 5)}</td>
    <td>${livePl(x.profit + (x.commission || 0) + (x.swap || 0) + (x.fee || 0), cur)}</td>
    <td class="sub">${esc(x.comment || "-")}</td>
  </tr>`).join("");
}

async function loadAnalytics() {
  const d = await api("/api/admin/live/analytics?days=30");
  const set = (id, value, cls = "") => {
    const el = $("#" + id);
    el.textContent = value;
    el.className = cls;
  };
  if (!d.available) {
    ["an-net", "an-trades", "an-wr", "an-pf", "an-aw", "an-al", "an-risk", "an-riskpct"]
      .forEach(id => set(id, "-"));
    $("#exposure").innerHTML = `<div class="hint">${esc(d.reason || "analytics unavailable")}</div>`;
    return;
  }
  const c = d.closed;
  const o = d.open;
  const cur = d.currency || liveCurrency || "USD";
  set("an-net", money(c.net, cur), c.net > 0 ? "positive" : c.net < 0 ? "negative" : "");
  set("an-trades", `${c.trades} closed · ${c.wins}W / ${c.losses}L`);
  set("an-wr", pct(c.win_rate));
  set("an-pf", c.profit_factor == null ? "PF -" : "PF " + num(c.profit_factor, 2));
  set("an-aw", c.avg_win == null ? "-" : money(c.avg_win, cur), "positive");
  set("an-al", c.avg_loss == null ? "-" : money(c.avg_loss, cur), "negative");
  set("an-risk", money(o.risk, cur));
  set("an-riskpct", o.risk_pct == null ? "-" : num(o.risk_pct, 2) + "%");

  $("#exposure").innerHTML = d.exposure.length ? d.exposure.map(e =>
    `<div class="chip">${esc(e.symbol)} · L ${num(e.long)} / S ${num(e.short)} · ${livePl(e.floating, cur)}${e.risk ? " · risk " + money(e.risk, cur) : ""}</div>`
  ).join("") : `<div class="hint">No open exposure.</div>`;
}

function shortMoney(v, cur) {
  try {
    return new Intl.NumberFormat(undefined, {
      style: "currency", currency: cur, notation: "compact", maximumFractionDigits: 1,
    }).format(Number(v));
  } catch (e) { return Number(v).toFixed(0); }
}

function drawEquity(d) {
  const el = $("#equity-chart");
  if (!d.available || !d.points || d.points.length < 2) {
    el.innerHTML = `<div class="chart-empty">${esc(d.reason || "No equity data")}</div>`;
    return;
  }
  $("#eq-note").textContent = d.days + " days" + (d.note ? " · " + d.note : "");
  const pts = d.points;
  const cur = d.currency || liveCurrency || "USD";
  const vals = pts.map(p => Number(p.equity));
  let lo = Math.min(...vals), hi = Math.max(...vals);
  if (hi - lo < 0.01) { lo -= 1; hi += 1; }
  const pad = (hi - lo) * 0.08;
  lo -= pad; hi += pad;
  const t0 = pts[0].t, t1 = pts[pts.length - 1].t;
  const span = Math.max(1, t1 - t0);
  const W = 600, H = 220, L = 56, R = 16, T = 14, B = 28;
  const x = t => L + (t - t0) / span * (W - L - R);
  const y = v => T + (hi - Number(v)) / (hi - lo) * (H - T - B);
  const line = pts.map((p, i) =>
    `${i ? "L" : "M"}${x(p.t).toFixed(1)},${y(p.equity).toFixed(1)}`).join(" ");
  const area = `${line} L${x(t1).toFixed(1)},${H - B} L${x(t0).toFixed(1)},${H - B} Z`;

  let grid = "";
  for (let i = 0; i <= 4; i++) {
    const v = lo + (hi - lo) * i / 4;
    const yy = y(v);
    grid += `<line x1="${L}" y1="${yy.toFixed(1)}" x2="${W - R}" y2="${yy.toFixed(1)}" stroke="#1e314e" stroke-width="1" />` +
      `<text x="${L - 7}" y="${(yy + 3).toFixed(1)}" text-anchor="end" fill="#8ba0bd" font-size="9">${esc(shortMoney(v, cur))}</text>`;
  }
  const last = pts[pts.length - 1];
  const cx = x(last.t), cy = y(last.equity);
  const d0 = new Date(t0 * 1000).toLocaleDateString();
  const d1 = new Date(t1 * 1000).toLocaleDateString();
  el.innerHTML = `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="Equity curve">
    <defs><linearGradient id="eqfill" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#22d3ee" stop-opacity=".35" />
      <stop offset="100%" stop-color="#22d3ee" stop-opacity="0" />
    </linearGradient></defs>
    ${grid}
    <path d="${area}" fill="url(#eqfill)" />
    <path d="${line}" fill="none" stroke="#22d3ee" stroke-width="2" stroke-linejoin="round" />
    <circle cx="${cx.toFixed(1)}" cy="${cy.toFixed(1)}" r="4" fill="#22d3ee" stroke="#04101f" stroke-width="2" />
    <text x="${W - R}" y="${Math.max(10, cy - 9).toFixed(1)}" text-anchor="end" fill="#e8eff9" font-size="10">${esc(money(last.equity, cur))}</text>
    <text x="${L}" y="${H - 6}" fill="#8ba0bd" font-size="9">${esc(d0)}</text>
    <text x="${W - R}" y="${H - 6}" text-anchor="end" fill="#8ba0bd" font-size="9">${esc(d1)}</text>
  </svg>`;
}

async function loadEquity() {
  const d = await api("/api/admin/live/equity?days=30");
  drawEquity(d);
}

$("#live-refresh").addEventListener("click", () => {
  refreshLive().catch(e => toast(e.message, true));
  loadOverview().catch(() => {});
});

$("#close-all").addEventListener("click", async () => {
  let snap = null;
  try { snap = await api("/api/admin/live"); } catch (e) { /* handled below */ }
  const n = snap && snap.available ? snap.position_count : 0;
  if (!n) { toast("No open positions to close", true); return; }
  if (!confirm(`Close ALL ${n} open positions on the connected account? This cannot be undone.`)) return;
  try {
    const r = await api("/api/admin/live/close-all", "POST", { confirm: true });
    toast(`Closed ${r.result.closed.length}, failed ${r.result.failed.length}`);
    await Promise.all([refreshLive(), loadOverview()]);
  } catch (e) { toast(e.message, true); }
});

$("#calc-lot").addEventListener("click", async () => {
  const form = $("#order-form");
  const f = new FormData(form);
  const symbol = String(f.get("symbol") || "").trim().toUpperCase();
  const side = String(f.get("side") || "buy");
  const risk_pct = Number(f.get("risk_pct") || 0.5);
  const sl = Number(f.get("sl") || 0);
  const tp = Number(f.get("tp") || 0);
  if (!symbol) { toast("Enter a symbol first", true); return; }
  if (!sl) { toast("Enter an SL price first", true); return; }
  try {
    const r = await api("/api/admin/live/calc", "POST",
                        { symbol, side, risk_pct, sl, tp });
    const c = r.calc;
    const out = $("#calc-out");
    if (c.lots > 0) {
      form.elements.volume.value = c.lots;
      out.innerHTML = `<span class="positive">${num(c.lots)} lots</span> · risk ${money(c.actual_risk, liveCurrency)} · reward ${c.reward == null ? "-" : money(c.reward, liveCurrency)} · R:R ${c.rr == null ? "-" : num(c.rr, 2)}`;
    } else {
      out.textContent = c.note || `No valid lot size (minimum ${c.volume_min})`;
    }
  } catch (e) { toast(e.message, true); }
});

$("#order-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const btn = e.target.querySelector("button");
  const f = new FormData(e.target);
  const symbol = String(f.get("symbol") || "").trim().toUpperCase();
  const side = String(f.get("side") || "buy");
  const volume = Number(f.get("volume"));
  const sl = Number(f.get("sl") || 0);
  const tp = Number(f.get("tp") || 0);
  if (!symbol || !volume) { toast("Symbol and volume are required", true); return; }
  if (!confirm(`Place ${side.toUpperCase()} ${volume} ${symbol} at market on the connected account?`)) return;
  btn.disabled = true;
  try {
    const r = await api("/api/admin/live/orders", "POST",
                        { symbol, side, volume, sl, tp, confirm: true });
    toast(`Order placed: #${r.result.order}`);
    await Promise.all([refreshLive(), loadOverview()]);
  } catch (err) {
    toast(err.message, true);
  } finally {
    btn.disabled = false;
  }
});

// ---------------------------------------------------------------------------
// adaptive AI agent
// ---------------------------------------------------------------------------
async function loadAgent() {
  const [d, sig, act] = await Promise.all([
    api("/api/admin/agent"),
    api("/api/admin/agent/signals?limit=60"),
    api("/api/admin/agent/actions?limit=60"),
  ]);
  const st = d.state;
  const cfg = st.config;
  const status = $("#agent-status");
  status.textContent = st.running ? "RUNNING" : "STOPPED";
  status.className = "pill " + (st.running ? "ok" : "idle");
  const paperBanner = $("#agent-paper-banner");
  if (st.paper) {
    paperBanner.classList.remove("hidden");
    paperBanner.textContent = "Paper mode is ON — no orders will be placed. Uncheck it and restart the agent for demo execution.";
  } else {
    paperBanner.classList.add("hidden");
  }
  const form0 = $("#agent-form");
  if (!form0.dataset.paperSet) {
    $("#ag-paper").checked = st.paper;
    form0.dataset.paperSet = "1";
  }
  const modeText = st.paper ? "Paper (signals only)" : "Demo trade (orders enabled)";
  $("#ag-mode").textContent = cfg.scanner_mode ? modeText + " · scanner" : modeText;
  $("#ag-tick").textContent = st.stats.last_tick ? ago(st.stats.last_tick) : "never";
  $("#ag-error").textContent = st.stats.last_error || "none";
  $("#ag-account").textContent = d.account
    ? `${d.account.login} · ${d.account.trade_mode}`
    : (d.reason || "unavailable");

  const gate = $("#agent-gate");
  gate.classList.remove("hidden", "ok", "warn");
  if (d.research_gate) {
    gate.classList.add("ok");
    gate.textContent = "Research gate passed. Real-account execution still requires SMC_ALLOW_LIVE_TRADING=1.";
  } else {
    gate.classList.add("warn");
    gate.textContent = "Research gate NOT passed (100+ trades, PF > 1.2). Agent may scan and trade demo only.";
  }

  $("#ag-signals").textContent = st.stats.signals ?? 0;
  $("#ag-taken").textContent = st.stats.taken ?? 0;
  $("#ag-wl").textContent = `${st.stats.wins ?? 0} / ${st.stats.losses ?? 0}`;
  $("#ag-updates").textContent = `${st.brain.updates ?? 0} brain updates`;
  $("#ag-net").textContent = money(st.stats.net || 0, d.account?.currency || "USD");

  const tr = st.stats.training || {};
  const trainStatus = $("#ag-train-status");
  trainStatus.textContent = tr.status === "running" ? "TRAINING"
    : tr.status === "done" ? String(tr.result || "DONE").toUpperCase() : "IDLE";
  trainStatus.className = "pill " + (tr.status === "running" ? "ok"
    : tr.status === "done" && tr.result === "profitable" ? "ok" : "idle");
  $("#ag-train-closed").textContent = tr.closed ?? 0;
  $("#ag-train-net").textContent = money(tr.net || 0, d.account?.currency || "USD");
  $("#ag-train-target").textContent = `${tr.target_trades || 10} trades · cap ${tr.max_trades || 60}`;
  $("#ag-train-result").textContent = tr.result || "-";
  const runs = st.stats.training_runs || [];
  $("#ag-train-runs").textContent = runs.length
    ? runs.length + " · " + runs.filter(r => r.result === "profitable").length + " profitable"
    : "-";
  $("#ag-train").disabled = tr.status === "running";

  const bt = st.stats.backtest || {};
  $("#ag-bt-net").textContent = bt.test ? `${bt.test.net_r >= 0 ? "+" : ""}${num(bt.test.net_r, 2)}R` : "-";
  $("#ag-bt-net").className = bt.test && bt.test.net_r > 0 ? "positive"
    : bt.test && bt.test.net_r < 0 ? "negative" : "";
  $("#ag-bt-pf").textContent = bt.test
    ? `PF ${bt.test.profit_factor == null ? "-" : num(bt.test.profit_factor, 2)} · ${bt.test.trades} trades`
    : "-";
  $("#ag-bt-applied").textContent = bt.applied == null ? "-" : (bt.applied ? "yes" : "no");

  const form = $("#agent-form");
  if (!form.dataset.filled) {
    form.elements.symbols.value = (cfg.symbols || []).join(",");
    form.elements.timeframe.value = cfg.timeframe;
    form.elements.htf.value = cfg.htf;
    form.elements.risk_pct.value = cfg.risk_pct;
    form.elements.sl_buffer_atr.value = cfg.sl_buffer_atr ?? 0.2;
    form.elements.sl_max_atr.value = cfg.sl_max_atr ?? 2;
    form.elements.min_rr.value = cfg.min_rr;
    form.elements.min_score.value = cfg.min_score;
    form.elements.max_trades_day.value = cfg.max_trades_day;
    form.elements.max_open.value = cfg.max_open;
    form.elements.interval_sec.value = cfg.interval_sec;
    form.elements.max_spread_points.value = cfg.max_spread_points;
    form.elements.max_daily_loss_pct.value = cfg.max_daily_loss_pct;
    form.elements.session.value = cfg.session;
    form.elements.scanner_mode.checked = !!cfg.scanner_mode;
    form.elements.scan_universe.value = (cfg.scan_universe || []).join(",");
    form.elements.scan_bars.value = cfg.scan_bars ?? 200;
    form.elements.max_scan_take.value = cfg.max_scan_take ?? 2;
    form.dataset.filled = "1";
  }

  $("#ag-brain").innerHTML = Object.entries(st.brain.weights || {}).map(([k, v]) =>
    `<div class="chip">${esc(k)} <b>${Number(v).toFixed(3)}</b></div>`).join("") ||
    `<div class="hint">No weights yet.</div>`;

  const srows = $("#ag-signal-rows");
  if (!sig.signals.length) {
    srows.innerHTML = `<tr><td colspan="11" class="muted">No signals yet. Start the agent or run a scan.</td></tr>`;
  } else {
    srows.innerHTML = sig.signals.map((s, i) => `<tr>
      <td class="sub">${tstr(s.ts)}</td>
      <td><b>${esc(s.symbol)}</b></td>
      <td>${esc(s.side || "-")}</td>
      <td>${s.score == null ? "-" : num(s.score, 3)}</td>
      <td>${s.rr == null ? "-" : num(s.rr, 2)}</td>
      <td class="sub">${s.entry ? num(s.entry, 5) : "-"}</td>
      <td class="sub">${s.sl ? num(s.sl, 5) : "-"}</td>
      <td class="sub">${s.tp ? num(s.tp, 5) : "-"}</td>
      <td><span class="pill ${s.decision === "TAKE" ? "ok" : "idle"}">${esc(s.decision)}</span></td>
      <td class="sub">${esc(s.reason || "-")}</td>
      <td>${s.sl ? `<button class="btn sm" data-preview="${i}">Preview</button>` : ""}</td>
    </tr>`).join("");

    $$("[data-preview]").forEach(b => b.addEventListener("click", async () => {
      const s = sig.signals[Number(b.dataset.preview)];
      if (!s || !s.sl) return;
      try {
        const r = await api("/api/admin/live/calc", "POST", {
          symbol: s.symbol, side: s.side, risk_pct: cfg.risk_pct,
          sl: s.sl, tp: s.tp, entry: s.entry,
        });
        const c = r.calc;
        toast(c.lots > 0
          ? `${num(c.lots)} lots · risk ${money(c.actual_risk, liveCurrency)} · RR ${c.rr == null ? "-" : num(c.rr, 2)}`
          : (c.note || "No valid lot size"), c.lots <= 0);
      } catch (e) { toast(e.message, true); }
    }));
  }

  const arows = $("#ag-action-rows");
  if (!act.actions.length) {
    arows.innerHTML = `<tr><td colspan="6" class="muted">No actions yet.</td></tr>`;
  } else {
    arows.innerHTML = act.actions.map(a => `<tr>
      <td class="sub">${tstr(a.ts)}</td>
      <td>${esc(a.kind)}</td>
      <td>${a.ticket || "-"}</td>
      <td>${esc(a.symbol || "-")}</td>
      <td class="sub">${esc(a.detail)}</td>
      <td class="sub">${esc(a.result)}</td>
    </tr>`).join("");
  }
}

$("#ag-start").addEventListener("click", async () => {
  const paper = $("#ag-paper").checked;
  const msg = paper
    ? "Start the agent in PAPER mode? It will scan and log signals but place no orders."
    : "Start the agent with ORDER EXECUTION on the connected account? It is demo-only unless the server explicitly allows live.";
  if (!confirm(msg)) return;
  try {
    await api("/api/admin/agent/start", "POST", { confirm: true, paper });
    toast(paper ? "Agent started (paper)" : "Agent started (orders enabled)");
    await loadAgent();
  } catch (e) { toast(e.message, true); }
});

$("#ag-stop").addEventListener("click", async () => {
  if (!confirm("Stop the AI agent?")) return;
  try { await api("/api/admin/agent/stop", "POST"); toast("Agent stopped"); await loadAgent(); }
  catch (e) { toast(e.message, true); }
});

$("#ag-scan").addEventListener("click", async () => {
  try { await api("/api/admin/agent/tick", "POST"); toast("Scan complete"); await loadAgent(); }
  catch (e) { toast(e.message, true); }
});

$("#ag-refresh").addEventListener("click", () => loadAgent().catch(e => toast(e.message, true)));

$("#ag-save").addEventListener("click", async () => {
  const f = $("#agent-form");
  const body = {
    symbols: String(f.elements.symbols.value).split(",").map(s => s.trim()).filter(Boolean),
    timeframe: f.elements.timeframe.value,
    htf: f.elements.htf.value,
    risk_pct: Number(f.elements.risk_pct.value),
    sl_buffer_atr: Number(f.elements.sl_buffer_atr.value),
    sl_max_atr: Number(f.elements.sl_max_atr.value),
    min_rr: Number(f.elements.min_rr.value),
    min_score: Number(f.elements.min_score.value),
    max_trades_day: Number(f.elements.max_trades_day.value),
    max_open: Number(f.elements.max_open.value),
    interval_sec: Number(f.elements.interval_sec.value),
    max_spread_points: Number(f.elements.max_spread_points.value),
    max_daily_loss_pct: Number(f.elements.max_daily_loss_pct.value),
    session: f.elements.session.value,
    scanner_mode: f.elements.scanner_mode.checked,
    scan_universe: String(f.elements.scan_universe.value).split(",").map(s => s.trim()).filter(Boolean),
    scan_bars: Number(f.elements.scan_bars.value),
    max_scan_take: Number(f.elements.max_scan_take.value),
  };
  try {
    await api("/api/admin/agent/config", "PATCH", body);
    f.dataset.filled = "";
    toast("Agent config saved");
    await loadAgent();
  } catch (e) { toast(e.message, true); }
});

$("#ag-train").addEventListener("click", async () => {
  if (!confirm("Start demo training? The agent will temporarily use relaxed gates, 0.5% risk and a wider scan, then restore your config.")) return;
  try {
    const r = await api("/api/admin/agent/train", "POST",
                        { confirm: true, target_trades: 10, max_trades: 60, timeout_min: 30 });
    if (!r.ok) { toast(r.reason || "Could not start", true); return; }
    toast("Training started");
    await loadAgent();
  } catch (e) { toast(e.message, true); }
});

$("#ag-backtest").addEventListener("click", async () => {
  if (!confirm("Run an H1 backtest, train the brain on 70% and validate on 30%? Profitable weights will be applied.")) return;
  try {
    const r = await api("/api/admin/agent/backtest", "POST", {
      confirm: true, epochs: 15, limit: 1800, threshold: 0.5, apply: true,
      min_test_trades: 10, min_test_net: 0, min_test_pf: 1.0,
    });
    toast(r.profitable ? `Backtest profitable: ${num(r.test.net_r, 2)}R` : "Backtest not profitable", !r.profitable);
    await loadAgent();
  } catch (e) { toast(e.message, true); }
});

$("#ag-load-symbols").addEventListener("click", async () => {
  try {
    const d = await api("/api/admin/live/symbols?limit=25");
    if (!d.available || !d.symbols.length) { toast(d.reason || "No symbols found", true); return; }
    const names = d.symbols.slice(0, 12).map(s => s.name);
    const f = $("#agent-form");
    f.elements.scan_universe.value = names.join(",");
    toast("Loaded " + names.length + " symbols");
  } catch (e) { toast(e.message, true); }
});

// ---------------------------------------------------------------------------
// tokens
// ---------------------------------------------------------------------------
async function loadTokens() {
  const d = await api("/api/admin/tokens");
  const rows = $("#token-rows");
  if (!d.tokens.length) {
    rows.innerHTML = `<tr><td colspan="7" class="muted">No tokens yet.</td></tr>`;
    return;
  }
  rows.innerHTML = d.tokens.map(t => `<tr>
    <td><b>${esc(t.label)}</b><div class="sub">magic ${t.magic}</div></td>
    <td>${esc(t.login || "-")}<div class="sub">${esc(t.server || "any")}</div></td>
    <td>${t.risk_pct}%<div class="sub">max ${t.max_trades_day}/day</div></td>
    <td class="sub">${esc(t.symbols)}</td>
    <td>${t.enabled ? `<span class="pill ok">ACTIVE</span>` : `<span class="pill off">OFF</span>`}
        ${t.online ? `<div class="sub">seen ${ago(t.last_seen)}</div>` : ""}</td>
    <td class="sub">${ago(t.last_seen)}<div>exp ${t.expires ? new Date(t.expires * 1000).toLocaleDateString() : "never"}</div></td>
    <td><div class="actions">
      <button class="btn sm" data-toggle="${t.id}" data-enabled="${t.enabled ? 1 : 0}">${t.enabled ? "Disable" : "Enable"}</button>
      <button class="btn sm danger" data-del="${t.id}">Revoke</button>
    </div></td>
  </tr>`).join("");

  $$("[data-toggle]").forEach(b => b.addEventListener("click", async () => {
    try {
      await api("/api/admin/tokens/" + b.dataset.toggle, "PATCH",
                { enabled: b.dataset.enabled !== "1" });
      await loadTokens(); await loadOverview();
      toast("Token updated");
    } catch (e) { toast(e.message, true); }
  }));
  $$("[data-del]").forEach(b => b.addEventListener("click", async () => {
    if (!confirm("Revoke this token? The EA will stop trading immediately.")) return;
    try {
      await api("/api/admin/tokens/" + b.dataset.del, "DELETE");
      await loadTokens(); await loadOverview();
      toast("Token revoked");
    } catch (e) { toast(e.message, true); }
  }));
}

$("#new-token").addEventListener("click", () => {
  openModal(`
    <h2>New activation token</h2>
    <p class="muted">The token is shown once. Bind it to the demo account.</p>
    <form id="token-form" class="form-grid">
      <div class="full"><label>Label</label><input name="label" value="Demo bot" required maxlength="80"></div>
      <div><label>Account login</label><input name="login" type="number" placeholder="optional"></div>
      <div><label>Server</label><input name="server" placeholder="optional"></div>
      <div><label>Risk % per trade</label><input name="risk_pct" type="number" step="0.1" min="0.1" max="5" value="0.5"></div>
      <div><label>Max trades / day</label><input name="max_trades_day" type="number" min="0" max="50" value="3"></div>
      <div><label>Symbols</label><input name="symbols" value="GBPUSD,XAUUSD"></div>
      <div><label>Valid days</label><input name="days" type="number" min="1" value="30"></div>
      <div class="full check"><input type="checkbox" name="demo_only" checked><span>Demo accounts only (recommended)</span></div>
      <div class="full"><button class="btn primary" type="submit">Create token</button></div>
    </form>`);
  $("#token-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const f = new FormData(e.target);
    const body = {
      label: f.get("label"),
      login: f.get("login") ? Number(f.get("login")) : null,
      server: f.get("server") || "",
      risk_pct: Number(f.get("risk_pct")),
      max_trades_day: Number(f.get("max_trades_day")),
      symbols: f.get("symbols") || "GBPUSD",
      days: Number(f.get("days")),
      demo_only: f.get("demo_only") === "on",
    };
    try {
      const r = await api("/api/admin/tokens", "POST", body);
      openModal(`
        <h2>Token created</h2>
        <p class="muted">Copy it now. Only its hash is stored.</p>
        <div class="token-box"><code style="background:none;padding:0">${esc(r.token)}</code></div>
        <button class="btn" id="copy-token">Copy token</button>
        <p class="hint">In MT5: attach <code>SMC_Link</code>, set <code>InpAppUrl</code> to this site and <code>InpToken</code> to the value above. Then allow the URL under Tools &gt; Options &gt; Expert Advisors.</p>
        <button class="btn primary" id="done-token">Done</button>`);
      $("#copy-token").addEventListener("click", async () => {
        try { await navigator.clipboard.writeText(r.token); toast("Token copied"); }
        catch { toast("Copy failed - select it manually", true); }
      });
      $("#done-token").addEventListener("click", () => closeModal());
      loadTokens(); loadOverview();
    } catch (err) { toast(err.message, true); }
  });
});

// ---------------------------------------------------------------------------
// research
// ---------------------------------------------------------------------------
async function loadBacktests() {
  const d = await api("/api/admin/backtests");
  const rows = $("#bt-rows");
  if (!d.backtests.length) {
    rows.innerHTML = `<tr><td colspan="9" class="muted">No backtest files. Copy <code>data/stats_*.json</code> into <code>app/data/backtests/</code>.</td></tr>`;
  } else {
    rows.innerHTML = d.backtests.map(b => `<tr>
      <td><b>${esc(b.symbol || "-")}</b></td>
      <td>${esc(b.range_tf || "-")}</td>
      <td>${esc(b.stops || "-")}</td>
      <td>${b.trades ?? "-"}</td>
      <td>${pct(b.win_rate)}</td>
      <td>${b.avg_R == null ? "-" : Number(b.avg_R).toFixed(2)}</td>
      <td>${b.profit_factor == null ? "-" : Number(b.profit_factor).toFixed(2)}</td>
      <td>${b.max_dd_pct == null ? "-" : Number(b.max_dd_pct).toFixed(1) + "%"}</td>
      <td>${b.return_pct == null ? "-" : Number(b.return_pct).toFixed(1) + "%"}</td>
    </tr>`).join("");
  }
  $("#bt-note").textContent = d.note || "";
  const good = d.backtests.some(b => (b.trades || 0) >= 100 && (b.profit_factor || 0) > 1.2);
  const gate = $("#gate");
  gate.classList.remove("hidden", "ok", "warn");
  if (good) {
    gate.classList.add("ok");
    gate.textContent = "Research gate passed by at least one setup. You may enable live execution for that setup after a forward test.";
  } else {
    gate.classList.add("warn");
    gate.textContent = "Research gate NOT passed: no setup with 100+ trades and PF > 1.2. Keep live execution disabled.";
  }
}

// ---------------------------------------------------------------------------
// modal
// ---------------------------------------------------------------------------
function openModal(html) {
  $("#modal-body").innerHTML = html;
  $("#modal").classList.remove("hidden");
}
function closeModal() {
  $("#modal").classList.add("hidden");
  $("#modal-body").innerHTML = "";
}
$("#modal-x").addEventListener("click", closeModal);
$("#modal").addEventListener("click", (e) => { if (e.target.id === "modal") closeModal(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeModal(); });

// ---------------------------------------------------------------------------
// boot
// ---------------------------------------------------------------------------
(async function boot() {
  try {
    await api("/api/admin/me");
    showApp();
    await Promise.all([loadOverview(), loadTokens(), loadBacktests()]);
  } catch (e) {
    showLogin();
  }
})();
