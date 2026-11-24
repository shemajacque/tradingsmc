# SMC Control Center

Self-hosted activation, monitoring and local account console for the SMC MT5
bot.

It issues activation tokens, returns the risk configuration to the `SMC_Link`
EA, and stores account heartbeats. When it runs on the **same Windows machine
as the MT5 terminal**, it also reads the live account directly and can close or
modify positions and place manual demo orders. The automated strategy stays
disabled until it passes the research gate shown in the Research tab.

## Local quick start (Windows)

```powershell
cd C:\Users\Student\smc_bot
python -m pip install -r app\requirements.txt
$env:SMC_ADMIN_PASSWORD = "use-a-long-random-password"
python -m uvicorn app.main:app --host 127.0.0.1 --port 8010
```

Open http://127.0.0.1:8010 and sign in with that password.

`run_app.ps1` does the same and generates a random password if none is set:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_app.ps1
```

## Direct MT5 account (Windows)

If the app runs on the machine where MT5 is installed and logged in, open the
**Live account** tab. It uses the MetaTrader5 Python package against that
terminal and shows:

- balance, equity, free margin and floating P/L
- open positions with live P/L
- pending orders and recent deals
- close and SL/TP actions
- a manual market-order form

No token or WebRequest allowlist entry is involved in direct mode. Manual
trades are explicit and are blocked on a **real** account unless the server is
started with `SMC_ALLOW_LIVE_TRADING=1`. On Docker/Linux the direct bridge is
disabled because the package cannot reach a Windows terminal; use the
`SMC_Link` EA heartbeat there instead.

## Advanced console

The **Live account** tab auto-refreshes every 3 seconds and also includes:

- an equity curve rebuilt from recent deals (deposits/withdrawals excluded)
- 30-day performance: net P/L, trade count, win rate, profit factor,
  average win/loss, payoff and expectancy
- open exposure by symbol, floating P/L, total open risk and risk % of equity
- per-position SL risk, TP reward and reward:risk (R:R)
- **Break-even**, **Partial close**, **SL/TP**, **Close** and **Close all**
  actions, all requiring confirmation
- a risk-based lot calculator: enter SL and risk %, and it fills the order
  form with the lot size that matches your risk budget

`Close all`, partial close and break-even are real MT5 actions. They are logged
in the app's activity feed. The automated bot remains gated by the Research
tab; these are manual controls for the connected account.

## AI agent (autonomous, local)

The **AI Agent** tab runs an autonomous loop when you press **Start agent**.
It is a transparent adaptive system, not an external LLM:

1. **Signal engine** - the Python SMC structure engine reads closed M15/H1/H4
   bars from MT5 and looks for a confirmed range, taken IRL, premium/discount
   location and HTF alignment.
2. **Brain** - a small online-learning scoring model weights the features
   (`bias_valid`, `irl_taken`, `htf_aligned`, `RR`, zone, session, spread).
   Closed trades from the agent's magic number update the weights, so it adapts
   from its own demo results.
3. **Stops** - SL is the nearest swing ±0.2 ATR, capped at 2 ATR from entry;
   TP stays at the range boundary. This keeps stops fundable at 0.01 lots.
4. **Risk gates** - spread, daily loss, max trades/day, max open positions,
   session, minimum score (0.66) and minimum R:R (1.5) must pass.
5. **Execution** - orders are sent with a dedicated magic (`730999`) and SL/TP.
   The agent can also move SL to break-even at 1R. All actions are logged.

**Paper mode** is off by default: starting the agent enables demo order
execution after an explicit confirmation. Tick **Paper mode** to scan and log
signals without orders. The agent never runs automatically after an app
restart. Real-account execution is blocked unless the research gate passes
**and** `SMC_ALLOW_LIVE_TRADING=1`. On a hosted Linux server the direct MT5
bridge is unavailable, so the agent cannot run there.

Default risk is **1%**; edit `SL buffer (ATR)` and `Max SL (ATR)` in the agent
config to tune stops. Use **Preview** on any signal to see the computed lot
size, risk and R:R before execution. If no setup passes the gates, the agent
logs SKIP reasons rather than forcing a trade.

### Scanner mode

Enable **Scanner mode** to scrape a wider symbol universe instead of only the
three configured symbols. Each cycle it:

- scans `Scan symbols` on the configured timeframe/HTF using `Scan bars` bars
- logs every setup and ranks TAKE signals by score, then R:R
- executes only the top `Max scanner takes` setups (default 2), subject to the
  same max-open / max-trades-per-day limits
- marks lower-ranked setups as SKIP with reason `scanner rank`

Use **Load top MT5 symbols** to fill the universe with the lowest-spread
tradable symbols from the terminal. Scanner mode uses more CPU and MT5 calls,
so increase `Interval sec` if the terminal feels slow.

### Train until profitable

**Start training** runs a bounded demo-only loop: it temporarily enables the
scanner on M15, lowers the score/RR gates, uses 0.3% risk and a wider symbol
set, and exits positions after 60 seconds so outcomes arrive quickly. Each
closed trade updates the brain weights. It stops when net P/L is positive after
at least 10 closed trades, or at 60 trades / 30 minutes, then restores your
previous config while keeping the learned weights. Profitability is not
guaranteed; the cap prevents endless demo trading.
Endpoints: `POST /api/admin/agent/train`, `GET /api/admin/agent/training`.

### Backtest & train

**Backtest & train** replays H1 CSV history through the SMC structure engine,
records synthetic signals and their forward outcomes, trains the brain on the
first 70% of trades and validates on the last 30%. If the validation set is
profitable (positive net R and PF ≥ 1.0), the learned weights are applied. This
is in-sample training with out-of-sample validation; it does not guarantee
future results. Only a profitable applied run overwrites the saved backtest
panel, and a training thread interrupted by a restart is marked as such on the
next launch. Endpoints: `POST /api/admin/agent/backtest`,
`GET /api/admin/agent/backtest`.

The agent's demo stats and brain weights are stored in the SQLite database.
`Scan once` runs one cycle even while stopped.

**Always scan market** is enabled by default: when the app starts and the local
MT5 bridge is available, it automatically starts the scanner in paper mode
(`auto_scan` / `auto_scan_paper`). It continuously scans the configured symbol
universe and logs signals without placing orders. The status shows `SCANNING`.
To trade, uncheck paper mode and press **Start agent**; real-account rules still
apply. Automatic scanning stops when the app shuts down and restarts with it.

## Docker

```powershell
Copy-Item .env.example .env
# edit .env and set SMC_ADMIN_PASSWORD
docker compose up -d --build
```

## Free hosting

### Render free web service

The repo includes `render.yaml`. On Render, create a new **Blueprint** from
`https://github.com/shemajacque/tradingsmc.git`, then set
`SMC_ADMIN_PASSWORD` when prompted. The free plan gives an HTTPS URL and
`/health` checks. It sleeps when idle and wakes on the first request.

This is a **Linux** host: it can run the dashboard, token API, EA heartbeats,
backtests and history, but it cannot see your Windows MT5 terminal. The direct
**Live account** and **AI Agent** tabs will show "direct MT5 unavailable". For
those, either keep the local Windows app running or use the tunnel below.

The SQLite file lives in `/tmp` on Render, so tokens/heartbeats reset on
restart. Use it as a monitoring/activation endpoint, not durable storage.

### Free full-access tunnel (Windows + MT5)

To keep full MT5/agent functionality without paying for a VPS:

```powershell
powershell -ExecutionPolicy Bypass -File .\run_app.ps1 -Port 8010
powershell -ExecutionPolicy Bypass -File .\cloudflare_tunnel.ps1 -Port 8010
```

The tunnel prints an `https://*.trycloudflare.com` URL. Open it, sign in with
the admin password, and you get the complete app including Live account and AI
Agent. Your Windows PC must stay on and MT5 must stay logged in. The quick
tunnel URL changes whenever the script restarts; a named Cloudflare tunnel with
your own domain gives a stable URL. Set `InpAppUrl` to the HTTPS URL and allow
that origin in MT5 if you want the EA to report to the tunnel.

Never expose the app without a strong `SMC_ADMIN_PASSWORD`: the admin session
can place trades when the direct bridge is enabled.

## Install on a phone

The dashboard is a PWA. Open the HTTPS URL (Render or the Cloudflare tunnel)
in your phone browser:

- **Android / Chrome:** menu &rarr; **Install app** or **Add to Home screen**.
  The **Install** button also appears in the top bar when supported.
- **iPhone / Safari:** Share &rarr; **Add to Home Screen**.

It installs like an app with its own icon and full-screen layout. The interface
shell is cached for offline opening, but login, API data, trading and AI Agent
actions still need a network connection and a reachable backend. Long-press the
home-screen icon for **Live account** and **AI Agent** shortcuts.

The SQLite database lives in `./data` (mounted at `/data`). Back up that folder.
Backtest JSON files are baked into the image from `app/data/backtests`; rebuild
after adding new results (or set `SMC_BACKTEST_DIR` to a mounted folder).

## HTTPS and hosting

MT5 `WebRequest` only contacts **port 80 for `http://` and 443 for `https://`**.
A URL such as `http://127.0.0.1:8010` will never work from an EA, even if it is
on the allowlist.

Host the app on a normal HTTPS origin, for example:

- Render / Railway / Fly.io web service, persistent disk mounted at `/data`
- A VPS with Caddy or nginx in front of uvicorn on `127.0.0.1:8010`

Set `SMC_COOKIE_SECURE=1` when the browser reaches the app over HTTPS.
Example Caddyfile:

```
bot.example.com {
    reverse_proxy 127.0.0.1:8010
}
```

Environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `SMC_ADMIN_PASSWORD` | `change-me-now` | Admin login. Always set this. |
| `SMC_DEMO_ONLY` | `1` | Reject tokens on real accounts. |
| `SMC_MT5_DIRECT` | `1` | Enable the local Windows MT5 bridge. Docker sets `0`. |
| `SMC_ALLOW_LIVE_TRADING` | `0` | Allow manual orders on a real account. Keep `0`. |
| `SMC_COOKIE_SECURE` | `0` | Set to `1` behind HTTPS. |
| `SMC_SESSION_HOURS` | `12` | Admin session lifetime. |
| `SMC_HEARTBEAT_SEC` | `30` | Heartbeat interval returned to the EA. |
| `SMC_DATA_DIR` | `app/data` | Database/backtest directory. |
| `SMC_DB` | `<data>/smc.db` | SQLite path. |
| `SMC_BACKTEST_DIR` | `app/data/backtests` | Folder feeding the Research tab. |

## Create a token

1. Sign in.
2. Open **Bots & tokens** -> **New token**.
3. Choose the demo login/server and copy the token immediately (shown once,
   stored hashed).

## MT5 setup

1. Copy `SMC_Link.ex5` to `MQL5\Experts` (or run `deploy.ps1 -Compile`).
2. Attach `SMC_Link` to a chart on the demo account.
3. Set inputs:
   - `InpAppUrl` = `https://your-app.example.com` (no trailing slash)
   - `InpToken` = the `smc_...` token
   - `InpHeartbeatSec` = 30
   - `InpAllowLive` = false
4. Allow the URL in MT5:
   - **Tools > Options > Expert Advisors**
   - Tick **Allow WebRequest for listed URL**
   - Double-click the empty line, enter the app origin exactly, e.g.
     `https://your-app.example.com`
   - Press Enter, then **OK**
5. The chart comment changes from `OFFLINE` to `ACTIVE`, and the bot card in
   the app turns online within ~30 seconds.

If the comment shows `[4014]` or `[4060]`, the URL is not on MT5's allowlist or
the port is not 80/443. A local URL like `http://127.0.0.1:8010` cannot be used
by WebRequest.

The link EA only validates and reports. The trading engine is a separate step
and must stay disabled until the backtest/forward-test gate passes.

## Research gate

`app/data/backtests/*.json` feeds the Research tab. Current Setup A results
(2024-2026, relaxed stops):

| Symbol | TF | Trades | Win rate | Avg R | PF |
|---|---|---:|---:|---:|---:|
| GBPUSD | H1 | 2 | 50.0% | -0.57 | 0.20 |
| GBPUSD | H4 | 9 | 22.2% | -1.01 | 0.06 |
| XAUUSD | H1 | 9 | 22.2% | -0.94 | 0.07 |
| XAUUSD | H4 | 21 | 61.9% | +0.14 | 1.29 |

XAUUSD H4 is the only positive cell, with 21 trades. That is not enough for the
gate (100+ trades, PF > 1.2). Do not enable live trading on this evidence.

## Security notes

- Never commit `.env`, the demo password, or activation tokens.
- Tokens are stored as SHA-256 hashes; the plaintext is shown once.
- Use HTTPS and a long admin password.
- **The admin password grants MT5 account access when the direct bridge is on.**
  Keep `SMC_MT5_DIRECT=0` on any shared or hosted server and use the EA bridge
  instead. Keep `SMC_ALLOW_LIVE_TRADING=0` unless you deliberately want manual
  orders on a real account.
- Back up the `data` volume; it contains the tokens' hashes and heartbeat history.
- The EA fails safe: if activation/heartbeat fails, it reports trading disabled.

## API

Admin (cookie session): `/api/admin/login`, `/api/admin/overview`,
`/api/admin/tokens`, `/api/admin/backtests`, `/api/admin/live`,
`/api/admin/live/history`.

AI agent (admin cookie): `GET /api/admin/agent`, `POST /api/admin/agent/start`,
`POST /api/admin/agent/stop`, `POST /api/admin/agent/tick`,
`PATCH /api/admin/agent/config`, `GET /api/admin/agent/signals`,
`GET /api/admin/agent/actions`.

Advanced analytics (admin cookie): `GET /api/admin/live/analytics`,
`GET /api/admin/live/equity`, `POST /api/admin/live/calc`.

Direct account actions (admin cookie, Windows bridge only):
`POST /api/admin/live/orders`,
`POST /api/admin/live/positions/{ticket}/close` (optionally with `volume`),
`POST /api/admin/live/positions/{ticket}/modify`,
`POST /api/admin/live/positions/{ticket}/break-even`,
`POST /api/admin/live/close-all`.

EA (bearer token): `POST /api/v1/activate`, `POST /api/v1/heartbeat`.
