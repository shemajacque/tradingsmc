"""
SMC Control Center
==================
Hosted activation, monitoring and advanced local account console for the SMC
MT5 bot.

The EA is given two inputs: the app URL and a token generated here.  On
startup it calls /api/v1/activate, then heartbeats every N seconds.  The app
returns a flat JSON config (enabled, risk, symbols, demo_only, ...) and stores
the account snapshot / closed trades for the dashboard.  When running on the
same Windows machine as MT5, the Live account tab uses the direct bridge for
real-time positions, equity analytics, risk sizing and manual trade actions.

Run locally:
    set SMC_ADMIN_PASSWORD=...           (PowerShell: $env:SMC_ADMIN_PASSWORD="...")
    uvicorn app.main:app --host 0.0.0.0 --port 8010

Deploy with HTTPS (see APP_README.md).  Never expose this app over plain HTTP
to the internet: tokens are bearer credentials.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from collections import defaultdict
from contextlib import closing
from pathlib import Path
from typing import List, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import ai_agent as agent
from . import backtest_trainer as trainer
from . import mt5_direct as direct

APP_DIR = Path(__file__).resolve().parent
ROOT = APP_DIR.parent
DATA_DIR = Path(os.environ.get("SMC_DATA_DIR", APP_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = os.environ.get("SMC_DB", str(DATA_DIR / "smc.db"))
BACKTEST_DIR = Path(os.environ.get("SMC_BACKTEST_DIR", APP_DIR / "data" / "backtests"))
BACKTEST_DIR.mkdir(parents=True, exist_ok=True)

ADMIN_PASSWORD = os.environ.get("SMC_ADMIN_PASSWORD", "change-me-now")
COOKIE_SECURE = os.environ.get("SMC_COOKIE_SECURE", "0") == "1"
SESSION_HOURS = int(os.environ.get("SMC_SESSION_HOURS", "12"))
DEFAULT_DEMO_ONLY = os.environ.get("SMC_DEMO_ONLY", "1") == "1"
HEARTBEAT_SEC = int(os.environ.get("SMC_HEARTBEAT_SEC", "30"))
ONLINE_SEC = int(os.environ.get("SMC_ONLINE_SEC", "120"))
DIRECT_ENABLED = os.environ.get("SMC_MT5_DIRECT", "1") == "1"
ALLOW_LIVE_TRADING = os.environ.get("SMC_ALLOW_LIVE_TRADING", "0") == "1"

app = FastAPI(title="SMC Control Center", docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=APP_DIR / "static"), name="static")


@app.on_event("startup")
def start_background_scanner() -> None:
    state = agent.get_state()
    training = state["stats"].get("training") or {}
    if training.get("status") == "running":
        training["status"] = "done"
        training["result"] = "interrupted by restart"
        training["ended"] = now()
        stats = dict(state["stats"])
        stats["training"] = training
        agent._save(stats=stats)
    cfg = state["config"]
    changed = False
    if not cfg.get("scanner_mode"):
        cfg["scanner_mode"] = True
        changed = True
    if cfg.get("training_mode"):
        cfg["training_mode"] = False
        changed = True
    if changed:
        agent._save(config=cfg)
    if not DIRECT_ENABLED or not cfg.get("auto_scan", True):
        return
    agent.runtime.start(paper=bool(cfg.get("auto_scan_paper", True)))


@app.on_event("shutdown")
def stop_background_scanner() -> None:
    agent.runtime.stop()

_attempts: dict = defaultdict(list)


# ---------------------------------------------------------------------------
# storage
# ---------------------------------------------------------------------------
def db() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH, timeout=15)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    return con


def init_db() -> None:
    with closing(db()) as con, con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                sid TEXT PRIMARY KEY,
                created REAL NOT NULL,
                last_seen REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS tokens (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                label TEXT NOT NULL,
                thash TEXT NOT NULL UNIQUE,
                login INTEGER,
                server TEXT DEFAULT '',
                enabled INTEGER NOT NULL DEFAULT 1,
                demo_only INTEGER NOT NULL DEFAULT 1,
                risk_pct REAL NOT NULL DEFAULT 0.5,
                max_trades_day INTEGER NOT NULL DEFAULT 3,
                symbols TEXT NOT NULL DEFAULT 'GBPUSD,XAUUSD',
                magic INTEGER NOT NULL DEFAULT 730001,
                is_demo INTEGER,
                created REAL NOT NULL,
                expires REAL,
                last_seen REAL,
                last_ip TEXT DEFAULT ''
            );
            CREATE TABLE IF NOT EXISTS heartbeats (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                token_id INTEGER NOT NULL,
                ts REAL NOT NULL,
                login INTEGER,
                server TEXT,
                name TEXT,
                currency TEXT,
                leverage INTEGER,
                balance REAL,
                equity REAL,
                margin_free REAL,
                day_pnl REAL,
                positions INTEGER,
                demo INTEGER,
                raw TEXT
            );
            CREATE INDEX IF NOT EXISTS ix_hb_token_ts ON heartbeats(token_id, ts);
            CREATE TABLE IF NOT EXISTS trades (
                token_id INTEGER NOT NULL,
                ticket INTEGER NOT NULL,
                symbol TEXT,
                dir TEXT,
                lots REAL,
                open_time INTEGER,
                close_time INTEGER,
                open_price REAL,
                close_price REAL,
                profit REAL,
                raw TEXT,
                PRIMARY KEY (token_id, ticket)
            );
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                level TEXT NOT NULL,
                msg TEXT NOT NULL
            );
            """
        )


init_db()
if ADMIN_PASSWORD == "change-me-now":
    print("WARNING: SMC_ADMIN_PASSWORD is not set. Using the insecure default.")


def now() -> float:
    return time.time()


def log_event(con: sqlite3.Connection, level: str, msg: str) -> None:
    con.execute("INSERT INTO events(ts, level, msg) VALUES(?,?,?)",
                (now(), level, msg[:500]))


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def find_token(con: sqlite3.Connection, token: str) -> Optional[sqlite3.Row]:
    return con.execute("SELECT * FROM tokens WHERE thash=?",
                       (token_hash(token),)).fetchone()


# ---------------------------------------------------------------------------
# admin auth
# ---------------------------------------------------------------------------
def require_admin(request: Request) -> sqlite3.Row:
    sid = request.cookies.get("smc_sid")
    if not sid:
        raise HTTPException(401, "login required")
    with closing(db()) as con:
        row = con.execute("SELECT * FROM sessions WHERE sid=?", (sid,)).fetchone()
        if row is None or row["last_seen"] < now() - SESSION_HOURS * 3600:
            raise HTTPException(401, "session expired")
        con.execute("UPDATE sessions SET last_seen=? WHERE sid=?", (now(), sid))
        con.commit()
    return row


def rate_limit(ip: str, bucket: str, limit: int, window: int) -> None:
    key = (bucket, ip)
    t = now()
    _attempts[key] = [x for x in _attempts[key] if x > t - window]
    if len(_attempts[key]) >= limit:
        raise HTTPException(429, "too many attempts, wait a few minutes")
    _attempts[key].append(t)


def client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    return fwd.split(",")[0].strip() if fwd else (
        request.client.host if request.client else "unknown")


class LoginIn(BaseModel):
    password: str


@app.post("/api/admin/login")
def admin_login(body: LoginIn, request: Request, response: Response):
    rate_limit(client_ip(request), "login", 8, 600)
    if not hmac.compare_digest(body.password, ADMIN_PASSWORD):
        raise HTTPException(401, "wrong password")
    sid = secrets.token_urlsafe(32)
    with closing(db()) as con, con:
        con.execute("DELETE FROM sessions WHERE last_seen < ?",
                    (now() - SESSION_HOURS * 3600,))
        con.execute("INSERT INTO sessions(sid, created, last_seen) VALUES(?,?,?)",
                    (sid, now(), now()))
        log_event(con, "info", f"admin login from {client_ip(request)}")
    response.set_cookie("smc_sid", sid, httponly=True, samesite="lax",
                        secure=COOKIE_SECURE, max_age=SESSION_HOURS * 3600)
    return {"ok": True}


@app.post("/api/admin/logout")
def admin_logout(request: Request, response: Response):
    sid = request.cookies.get("smc_sid")
    if sid:
        with closing(db()) as con, con:
            con.execute("DELETE FROM sessions WHERE sid=?", (sid,))
    response.delete_cookie("smc_sid")
    return {"ok": True}


@app.get("/api/admin/me")
def admin_me(_: sqlite3.Row = Depends(require_admin)):
    return {"ok": True, "demo_only_default": DEFAULT_DEMO_ONLY}


# ---------------------------------------------------------------------------
# admin data
# ---------------------------------------------------------------------------
class TokenIn(BaseModel):
    label: str = Field(min_length=1, max_length=80)
    login: Optional[int] = None
    server: str = ""
    days: int = Field(default=30, ge=1, le=3650)
    demo_only: bool = True
    risk_pct: float = Field(default=0.5, gt=0, le=5)
    max_trades_day: int = Field(default=3, ge=0, le=50)
    symbols: str = "GBPUSD,XAUUSD"


class TokenPatch(BaseModel):
    enabled: Optional[bool] = None
    demo_only: Optional[bool] = None
    risk_pct: Optional[float] = Field(default=None, gt=0, le=5)
    max_trades_day: Optional[int] = Field(default=None, ge=0, le=50)
    symbols: Optional[str] = None
    login: Optional[int] = None
    server: Optional[str] = None
    days: Optional[int] = Field(default=None, ge=1, le=3650)


def token_public(row: sqlite3.Row) -> dict:
    return {
        "id": row["id"],
        "label": row["label"],
        "login": row["login"],
        "server": row["server"],
        "enabled": bool(row["enabled"]),
        "demo_only": bool(row["demo_only"]),
        "risk_pct": row["risk_pct"],
        "max_trades_day": row["max_trades_day"],
        "symbols": row["symbols"],
        "magic": row["magic"],
        "is_demo": None if row["is_demo"] is None else bool(row["is_demo"]),
        "created": row["created"],
        "expires": row["expires"],
        "last_seen": row["last_seen"],
        "last_ip": row["last_ip"],
        "online": bool(row["last_seen"] and row["last_seen"] > now() - ONLINE_SEC),
    }


@app.get("/api/admin/tokens")
def list_tokens(_: sqlite3.Row = Depends(require_admin)):
    with closing(db()) as con:
        rows = con.execute("SELECT * FROM tokens ORDER BY id DESC").fetchall()
    return {"tokens": [token_public(r) for r in rows]}


@app.post("/api/admin/tokens")
def create_token(body: TokenIn, request: Request,
                 _: sqlite3.Row = Depends(require_admin)):
    if body.demo_only is False and DEFAULT_DEMO_ONLY:
        raise HTTPException(400, "live tokens are disabled on this server")
    plain = "smc_" + secrets.token_urlsafe(32)
    exp = now() + body.days * 86400
    with closing(db()) as con, con:
        cur = con.execute(
            """INSERT INTO tokens(label, thash, login, server, enabled, demo_only,
                                  risk_pct, max_trades_day, symbols, magic,
                                  created, expires)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
            (body.label.strip(), token_hash(plain), body.login,
             body.server.strip(), 1, int(body.demo_only), body.risk_pct,
             body.max_trades_day, body.symbols.strip() or "GBPUSD",
             secrets.randbelow(900000) + 100000, now(), exp))
        log_event(con, "info",
                  f"token '{body.label}' created for login {body.login or '-'} "
                  f"by {client_ip(request)}")
        tid = cur.lastrowid
    return {"ok": True, "id": tid, "token": plain,
            "note": "Copy this token now. It is stored hashed and cannot be shown again."}


@app.patch("/api/admin/tokens/{tid}")
def patch_token(tid: int, body: TokenPatch,
                _: sqlite3.Row = Depends(require_admin)):
    sets, vals = [], []
    if body.enabled is not None:
        sets.append("enabled=?")
        vals.append(int(body.enabled))
    if body.demo_only is not None:
        sets.append("demo_only=?")
        vals.append(int(body.demo_only))
    if body.risk_pct is not None:
        sets.append("risk_pct=?")
        vals.append(body.risk_pct)
    if body.max_trades_day is not None:
        sets.append("max_trades_day=?")
        vals.append(body.max_trades_day)
    if body.symbols is not None:
        sets.append("symbols=?")
        vals.append(body.symbols.strip() or "GBPUSD")
    if body.login is not None:
        sets.append("login=?")
        vals.append(body.login)
    if body.server is not None:
        sets.append("server=?")
        vals.append(body.server.strip())
    if body.days is not None:
        sets.append("expires=?")
        vals.append(now() + body.days * 86400)
    if not sets:
        raise HTTPException(400, "nothing to update")
    vals.append(tid)
    with closing(db()) as con, con:
        cur = con.execute(f"UPDATE tokens SET {', '.join(sets)} WHERE id=?", vals)
        if cur.rowcount == 0:
            raise HTTPException(404, "token not found")
        log_event(con, "info", f"token {tid} updated: {', '.join(s.split('=')[0] for s in sets)}")
    return {"ok": True}


@app.delete("/api/admin/tokens/{tid}")
def delete_token(tid: int, _: sqlite3.Row = Depends(require_admin)):
    with closing(db()) as con, con:
        con.execute("DELETE FROM heartbeats WHERE token_id=?", (tid,))
        con.execute("DELETE FROM trades WHERE token_id=?", (tid,))
        cur = con.execute("DELETE FROM tokens WHERE id=?", (tid,))
        if cur.rowcount == 0:
            raise HTTPException(404, "token not found")
        log_event(con, "warn", f"token {tid} revoked")
    return {"ok": True}


@app.get("/api/admin/overview")
def overview(_: sqlite3.Row = Depends(require_admin)):
    with closing(db()) as con:
        tokens = con.execute("SELECT * FROM tokens ORDER BY id DESC").fetchall()
        hb = {}
        for r in tokens:
            h = con.execute(
                "SELECT * FROM heartbeats WHERE token_id=? ORDER BY ts DESC LIMIT 1",
                (r["id"],)).fetchone()
            if h:
                hb[r["id"]] = dict(h)
        stats = con.execute(
            """SELECT COUNT(*) n, COALESCE(SUM(profit),0) profit,
                      COALESCE(SUM(CASE WHEN profit>0 THEN 1 ELSE 0 END),0) wins
               FROM trades""").fetchone()
        today = con.execute(
            "SELECT COALESCE(SUM(profit),0) p FROM trades WHERE close_time > ?",
            (now() - 86400,)).fetchone()
        events = con.execute(
            "SELECT * FROM events ORDER BY id DESC LIMIT 20").fetchall()
        n_pos = con.execute(
            """SELECT COUNT(*) n FROM heartbeats h
               WHERE h.id IN (SELECT MAX(id) FROM heartbeats GROUP BY token_id)"""
        ).fetchone()

    out = []
    for r in tokens:
        d = token_public(r)
        d["heartbeat"] = hb.get(r["id"])
        out.append(d)
    positions = 0
    for d in out:
        h = d.get("heartbeat")
        if h:
            positions += int(h.get("positions") or 0)
    trade_n = int(stats["n"] or 0)
    wins = int(stats["wins"] or 0)

    live = {"available": False,
            "reason": "direct MT5 bridge disabled" if not DIRECT_ENABLED else "unknown"}
    if DIRECT_ENABLED:
        try:
            snap = direct.summary()
            live = {
                "available": True,
                "account": snap["account"],
                "position_count": snap["position_count"],
                "order_count": snap["order_count"],
            }
        except Exception as exc:
            live = {"available": False, "reason": str(exc)}

    return {
        "tokens": out,
        "stats": {
            "trades": trade_n,
            "wins": wins,
            "win_rate": (wins / trade_n) if trade_n else None,
            "profit": float(stats["profit"] or 0),
            "today_profit": float(today["p"] or 0),
            "positions": positions,
            "online": sum(1 for d in out if d["online"] and d["enabled"]),
        },
        "live": live,
        "events": [dict(e) for e in events],
        "server_time": now(),
        "demo_only_default": DEFAULT_DEMO_ONLY,
    }


@app.get("/api/admin/backtests")
def backtests(_: sqlite3.Row = Depends(require_admin)):
    rows: List[dict] = []
    for p in sorted(BACKTEST_DIR.glob("*.json")):
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        rows.append({
            "file": p.name,
              "symbol": data.get("symbol"),
              "range_tf": data.get("range_tf"),
              "stops": data.get("stop_mode"),
            "trades": data.get("trades"),
            "win_rate": data.get("win_rate"),
            "avg_R": data.get("avg_R"),
            "profit_factor": data.get("profit_factor"),
            "max_dd_pct": data.get("max_dd_pct"),
            "return_pct": data.get("return_pct"),
        })
    return {"backtests": rows,
            "note": "Research only. Live activation should stay disabled until "
                    "a setup has a positive expectancy over a large sample."}


# ---------------------------------------------------------------------------
# direct MT5 account (local Windows bridge)
# ---------------------------------------------------------------------------
class CloseIn(BaseModel):
    confirm: bool = False
    volume: Optional[float] = Field(default=None, gt=0)


class BreakEvenIn(BaseModel):
    confirm: bool = False
    buffer_points: float = Field(default=2.0, ge=0, le=1000)


class CloseAllIn(BaseModel):
    confirm: bool = False
    symbol: Optional[str] = None


class CalcIn(BaseModel):
    symbol: str = Field(min_length=1, max_length=32)
    side: str = Field(pattern="^(buy|sell)$")
    risk_pct: float = Field(gt=0, le=100)
    sl: float = Field(gt=0)
    tp: float = 0.0
    entry: float = 0.0


class ModifyIn(BaseModel):
    sl: Optional[float] = None
    tp: Optional[float] = None
    confirm: bool = False


class OrderIn(BaseModel):
    symbol: str = Field(min_length=1, max_length=32)
    side: str = Field(pattern="^(buy|sell)$")
    volume: float = Field(gt=0, le=1000)
    sl: float = 0.0
    tp: float = 0.0
    confirm: bool = False


def _direct_reason(exc: Exception) -> str:
    return str(exc) or exc.__class__.__name__


def _live_trade_guard() -> dict:
    if not DIRECT_ENABLED:
        raise HTTPException(503, "direct MT5 bridge is disabled")
    try:
        acc = direct.account()
    except direct.DirectError as exc:
        raise HTTPException(503, _direct_reason(exc))
    if not acc.get("demo") and not ALLOW_LIVE_TRADING:
        raise HTTPException(
            403, "this is a live account; set SMC_ALLOW_LIVE_TRADING=1 on the "
                 "server before placing manual trades")
    if not acc.get("trade_allowed"):
        raise HTTPException(403, "trading is disabled in the MT5 terminal")
    return acc


def _log_live(level: str, msg: str) -> None:
    with closing(db()) as con, con:
        log_event(con, level, msg)


@app.get("/api/admin/live")
def live_snapshot(_: sqlite3.Row = Depends(require_admin)):
    if not DIRECT_ENABLED:
        return {"available": False, "direct_enabled": False,
                "allow_live_trading": ALLOW_LIVE_TRADING,
                "reason": "direct MT5 bridge disabled (SMC_MT5_DIRECT=0)"}
    try:
        snap = direct.summary()
    except Exception as exc:
        return {"available": False, "direct_enabled": True,
                "allow_live_trading": ALLOW_LIVE_TRADING,
                "reason": _direct_reason(exc)}
    return {"available": True, "direct_enabled": True,
            "allow_live_trading": ALLOW_LIVE_TRADING, **snap}


@app.get("/api/admin/live/history")
def live_history(days: int = 7, limit: int = 50,
                 _: sqlite3.Row = Depends(require_admin)):
    if not DIRECT_ENABLED:
        return {"available": False, "deals": [],
                "reason": "direct MT5 bridge disabled"}
    try:
        deals = direct.history(days=days, limit=limit)
    except Exception as exc:
        return {"available": False, "deals": [], "reason": _direct_reason(exc)}
    return {"available": True, "deals": deals}


@app.post("/api/admin/live/positions/{ticket}/close")
def live_close(ticket: int, body: CloseIn,
               _: sqlite3.Row = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "confirmation required")
    acc = _live_trade_guard()
    try:
        result = direct.close_position(ticket, volume=body.volume)
    except direct.DirectError as exc:
        raise HTTPException(503, _direct_reason(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    what = f"{body.volume} lots" if body.volume else "full position"
    _log_live("warn", f"web close {what} #{ticket} on {acc['login']} "
                       f"({acc['server']}, demo={acc['demo']})")
    return {"ok": True, "result": result}


@app.post("/api/admin/live/positions/{ticket}/modify")
def live_modify(ticket: int, body: ModifyIn,
                _: sqlite3.Row = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "confirmation required")
    if body.sl is None and body.tp is None:
        raise HTTPException(400, "set at least one of SL or TP")
    acc = _live_trade_guard()
    try:
        result = direct.modify_position(ticket, sl=body.sl, tp=body.tp)
    except direct.DirectError as exc:
        raise HTTPException(503, _direct_reason(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    _log_live("warn", f"web modify #{ticket} on {acc['login']} "
                       f"SL={body.sl} TP={body.tp}")
    return {"ok": True, "result": result}


@app.post("/api/admin/live/orders")
def live_order(body: OrderIn, _: sqlite3.Row = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "confirmation required")
    acc = _live_trade_guard()
    try:
        result = direct.place_order(body.symbol.strip(), body.side,
                                    body.volume, body.sl, body.tp)
    except direct.DirectError as exc:
        raise HTTPException(503, _direct_reason(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    _log_live("warn", f"web {body.side.upper()} {body.volume} {body.symbol} "
                       f"on {acc['login']} ({acc['server']})")
    return {"ok": True, "result": result}


@app.post("/api/admin/live/positions/{ticket}/break-even")
def live_break_even(ticket: int, body: BreakEvenIn,
                    _: sqlite3.Row = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "confirmation required")
    acc = _live_trade_guard()
    try:
        result = direct.break_even(ticket, body.buffer_points)
    except direct.DirectError as exc:
        raise HTTPException(503, _direct_reason(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    _log_live("warn", f"web break-even #{ticket} on {acc['login']} "
                       f"buffer={body.buffer_points}pt")
    return {"ok": True, "result": result}


@app.post("/api/admin/live/close-all")
def live_close_all(body: CloseAllIn,
                   _: sqlite3.Row = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "confirmation required")
    acc = _live_trade_guard()
    symbol = body.symbol.strip() if body.symbol else None
    try:
        result = direct.close_all(symbol)
    except direct.DirectError as exc:
        raise HTTPException(503, _direct_reason(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    for c in result["closed"]:
        _log_live("warn", f"web close-all #{c['ticket']} {c['symbol']} "
                           f"on {acc['login']}")
    return {"ok": True, "result": result}


@app.get("/api/admin/live/symbols")
def live_symbols(limit: int = 40, _: sqlite3.Row = Depends(require_admin)):
    if not DIRECT_ENABLED:
        return {"available": False, "symbols": [],
                "reason": "direct MT5 bridge disabled"}
    try:
        syms = direct.symbols(limit=limit)
    except Exception as exc:
        return {"available": False, "symbols": [], "reason": _direct_reason(exc)}
    return {"available": True, "symbols": syms}


@app.get("/api/admin/live/analytics")
def live_analytics(days: int = 30, _: sqlite3.Row = Depends(require_admin)):
    if not DIRECT_ENABLED:
        return {"available": False, "reason": "direct MT5 bridge disabled"}
    try:
        stats = direct.analytics(days=days)
    except Exception as exc:
        return {"available": False, "reason": _direct_reason(exc)}
    return {"available": True, **stats}


@app.get("/api/admin/live/equity")
def live_equity(days: int = 30, _: sqlite3.Row = Depends(require_admin)):
    if not DIRECT_ENABLED:
        return {"available": False, "reason": "direct MT5 bridge disabled"}
    try:
        curve = direct.equity_curve(days=days)
    except Exception as exc:
        return {"available": False, "reason": _direct_reason(exc)}
    return {"available": True, **curve}


@app.post("/api/admin/live/calc")
def live_calc(body: CalcIn, _: sqlite3.Row = Depends(require_admin)):
    if not DIRECT_ENABLED:
        raise HTTPException(503, "direct MT5 bridge is disabled")
    try:
        return {"ok": True,
                "calc": direct.calc_lot(body.symbol.strip(), body.side,
                                        body.risk_pct, body.sl,
                                        body.tp, body.entry)}
    except direct.DirectError as exc:
        raise HTTPException(503, _direct_reason(exc))
    except ValueError as exc:
        raise HTTPException(400, str(exc))


# ---------------------------------------------------------------------------
# adaptive AI agent
# ---------------------------------------------------------------------------
class AgentStartIn(BaseModel):
    confirm: bool = False
    paper: bool = False


class AgentConfigIn(BaseModel):
    symbols: Optional[List[str]] = None
    timeframe: Optional[str] = None
    htf: Optional[str] = None
    risk_pct: Optional[float] = Field(default=None, gt=0, le=5)
    sl_buffer_atr: Optional[float] = Field(default=None, ge=0, le=2)
    sl_max_atr: Optional[float] = Field(default=None, ge=0.5, le=10)
    max_trades_day: Optional[int] = Field(default=None, ge=0, le=50)
    max_open: Optional[int] = Field(default=None, ge=1, le=20)
    min_rr: Optional[float] = Field(default=None, gt=0, le=20)
    min_score: Optional[float] = Field(default=None, ge=0, le=1)
    interval_sec: Optional[int] = Field(default=None, ge=5, le=300)
    max_spread_points: Optional[int] = Field(default=None, ge=0, le=500)
    max_daily_loss_pct: Optional[float] = Field(default=None, gt=0, le=20)
    session: Optional[str] = None
    magic: Optional[int] = Field(default=None, ge=1, le=999999999)
    scanner_mode: Optional[bool] = None
    auto_scan: Optional[bool] = None
    auto_scan_paper: Optional[bool] = None
    training_mode: Optional[bool] = None
    scan_universe: Optional[List[str]] = None
    scan_bars: Optional[int] = Field(default=None, ge=50, le=1000)
    max_scan_take: Optional[int] = Field(default=None, ge=1, le=10)


def research_gate_passed() -> bool:
    for p in BACKTEST_DIR.glob("*.json"):
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        if (d.get("trades") or 0) >= 100 and (d.get("profit_factor") or 0) > 1.2:
            return True
    return False


def agent_account() -> tuple[Optional[dict], Optional[str]]:
    if not DIRECT_ENABLED:
        return None, "direct MT5 bridge is disabled"
    try:
        return direct.account(), None
    except Exception as exc:
        return None, _direct_reason(exc)


@app.get("/api/admin/agent")
def agent_status(_: sqlite3.Row = Depends(require_admin)):
    acc, reason = agent_account()
    return {
        "state": agent.get_state(),
        "research_gate": research_gate_passed(),
        "allow_live": ALLOW_LIVE_TRADING,
        "account": acc,
        "reason": reason,
    }


@app.post("/api/admin/agent/start")
def agent_start(body: AgentStartIn, _: sqlite3.Row = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "confirmation required")
    acc, reason = agent_account()
    if acc is None:
        raise HTTPException(503, reason or "MT5 unavailable")
    if not body.paper:
        if not acc.get("demo"):
            if not ALLOW_LIVE_TRADING:
                raise HTTPException(403, "live agent trading is disabled on this server")
            if not research_gate_passed():
                raise HTTPException(403, "research gate has not passed")
        if not acc.get("trade_allowed"):
            raise HTTPException(403, "MT5 trading is disabled")
    result = agent.runtime.start(paper=body.paper)
    _log_live("info", f"AI agent start paper={body.paper} demo={acc.get('demo')}")
    return result


@app.post("/api/admin/agent/stop")
def agent_stop(_: sqlite3.Row = Depends(require_admin)):
    result = agent.runtime.stop()
    _log_live("info", "AI agent stop")
    return result


@app.post("/api/admin/agent/tick")
def agent_tick(_: sqlite3.Row = Depends(require_admin)):
    return {"ok": True, "state": agent.tick_once()}


@app.patch("/api/admin/agent/config")
def agent_config(body: AgentConfigIn, _: sqlite3.Row = Depends(require_admin)):
    state = agent.get_state()
    cfg = state["config"]
    updates = body.model_dump(exclude_unset=True)
    for key, value in updates.items():
        if value is not None:
            cfg[key] = value
    if cfg.get("timeframe") not in direct.TIMEFRAMES:
        raise HTTPException(400, "unsupported timeframe")
    if cfg.get("htf") not in direct.TIMEFRAMES:
        raise HTTPException(400, "unsupported HTF")
    if not isinstance(cfg.get("symbols"), list) or not cfg["symbols"]:
        raise HTTPException(400, "symbols must be a non-empty list")
    cfg["symbols"] = [str(s).strip().upper() for s in cfg["symbols"] if str(s).strip()]
    if not isinstance(cfg.get("scan_universe"), list) or not cfg["scan_universe"]:
        raise HTTPException(400, "scan_universe must be a non-empty list")
    cfg["scan_universe"] = [str(s).strip().upper()
                            for s in cfg["scan_universe"] if str(s).strip()]
    if cfg.get("session") not in ("any", "london", "newyork", "asia"):
        raise HTTPException(400, "unsupported session")
    agent._save(config=cfg)
    return {"ok": True, "config": cfg}


@app.get("/api/admin/agent/signals")
def agent_signals(limit: int = 50, _: sqlite3.Row = Depends(require_admin)):
    return {"signals": agent.signals(limit=max(1, min(limit, 500)))}


@app.get("/api/admin/agent/actions")
def agent_actions(limit: int = 50, _: sqlite3.Row = Depends(require_admin)):
    return {"actions": agent.actions(limit=max(1, min(limit, 500)))}


class AgentTrainIn(BaseModel):
    confirm: bool = False
    target_trades: int = Field(default=10, ge=3, le=100)
    max_trades: int = Field(default=60, ge=5, le=500)
    timeout_min: int = Field(default=30, ge=1, le=240)


@app.post("/api/admin/agent/train")
def agent_train(body: AgentTrainIn, _: sqlite3.Row = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "confirmation required")
    if body.max_trades < body.target_trades:
        raise HTTPException(400, "max_trades must be >= target_trades")
    acc, reason = agent_account()
    if acc is None:
        raise HTTPException(503, reason or "MT5 unavailable")
    if not acc.get("demo"):
        raise HTTPException(403, "training is demo-only")
    return agent.start_training(body.target_trades, body.max_trades,
                                body.timeout_min)


@app.get("/api/admin/agent/training")
def agent_training(_: sqlite3.Row = Depends(require_admin)):
    return {"training": agent.get_state()["stats"].get("training", {})}


class BacktestIn(BaseModel):
    confirm: bool = False
    epochs: int = Field(default=15, ge=1, le=200)
    limit: int = Field(default=1500, ge=500, le=5000)
    threshold: float = Field(default=0.5, ge=0.05, le=0.95)
    apply: bool = True
    min_test_trades: int = Field(default=10, ge=5, le=200)
    min_test_net: float = Field(default=0.0, ge=-100, le=100)
    min_test_pf: float = Field(default=1.0, ge=0.5, le=10)


@app.post("/api/admin/agent/backtest")
def agent_backtest(body: BacktestIn, _: sqlite3.Row = Depends(require_admin)):
    if not body.confirm:
        raise HTTPException(400, "confirmation required")
    return trainer.run(epochs=body.epochs, limit=body.limit,
                       threshold=body.threshold, apply=body.apply,
                       min_test_trades=body.min_test_trades,
                       min_test_net=body.min_test_net,
                       min_test_pf=body.min_test_pf)


@app.get("/api/admin/agent/backtest")
def agent_backtest_status(_: sqlite3.Row = Depends(require_admin)):
    return {"backtest": agent.get_state()["stats"].get("backtest", {})}


# ---------------------------------------------------------------------------
# EA API (bearer token)
# ---------------------------------------------------------------------------
class ActivateIn(BaseModel):
    login: int
    server: str = ""
    build: int = 0
    symbol: str = ""
    demo: bool = True


class HeartbeatIn(BaseModel):
    login: int
    server: str = ""
    account_name: str = ""
    currency: str = ""
    leverage: int = 0
    balance: float = 0.0
    equity: float = 0.0
    margin_free: float = 0.0
    demo: bool = True
    day_pnl: float = 0.0
    positions: List[dict] = Field(default_factory=list)
    closed: List[dict] = Field(default_factory=list)


def bearer(authorization: Optional[str]) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    return authorization[7:].strip()


def check_activation(con: sqlite3.Connection, token: str, login: int,
                     server: str, demo: bool, request: Request) -> sqlite3.Row:
    row = find_token(con, token)
    if row is None:
        log_event(con, "warn", f"invalid token from {client_ip(request)}")
        raise HTTPException(401, "invalid token")
    if row["expires"] and row["expires"] < now():
        raise HTTPException(403, "token expired")
    if not row["enabled"]:
        raise HTTPException(423, "activation disabled by the operator")
    if row["login"] and int(row["login"]) != int(login):
        raise HTTPException(403, "token is bound to another account")
    if row["server"] and server and row["server"].lower() != server.lower():
        raise HTTPException(403, "token is bound to another server")
    if row["demo_only"] and not demo:
        raise HTTPException(403, "this token is demo-only")
    return row


def config_flat(row: sqlite3.Row) -> dict:
    return {
        "status": "ok",
        "enabled": 1 if row["enabled"] else 0,
        "demo_only": 1 if row["demo_only"] else 0,
        "risk_pct": row["risk_pct"],
        "max_trades_day": row["max_trades_day"],
        "symbols": row["symbols"],
        "magic": row["magic"],
        "heartbeat_sec": HEARTBEAT_SEC,
        "server_time": int(now()),
    }


@app.post("/api/v1/activate")
def activate(body: ActivateIn, request: Request,
             authorization: Optional[str] = Header(default=None)):
    token = bearer(authorization)
    rate_limit(client_ip(request), "activate", 30, 60)
    with closing(db()) as con, con:
        row = check_activation(con, token, body.login, body.server, body.demo,
                               request)
        con.execute(
            "UPDATE tokens SET last_seen=?, last_ip=?, is_demo=? WHERE id=?",
            (now(), client_ip(request), int(body.demo), row["id"]))
        con.execute(
            """INSERT INTO heartbeats(token_id, ts, login, server, balance,
                                      equity, margin_free, positions, demo, raw)
               VALUES(?,?,?,?,NULL,NULL,NULL,0,?,?)""",
            (row["id"], now(), body.login, body.server, int(body.demo),
             json.dumps(body.model_dump())))
        log_event(con, "info",
                  f"activation ok: '{row['label']}' login {body.login} "
                  f"{body.server} build {body.build} demo={body.demo}")
    out = config_flat(row)
    out["message"] = "activated"
    return out


@app.post("/api/v1/heartbeat")
def heartbeat(body: HeartbeatIn, request: Request,
              authorization: Optional[str] = Header(default=None)):
    token = bearer(authorization)
    rate_limit(client_ip(request), "hb", 240, 60)
    with closing(db()) as con, con:
        row = check_activation(con, token, body.login, body.server, body.demo,
                               request)
        ts = now()
        con.execute(
            """INSERT INTO heartbeats(token_id, ts, login, server, name,
                                      currency, leverage, balance, equity,
                                      margin_free, day_pnl, positions, demo, raw)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (row["id"], ts, body.login, body.server, body.account_name,
             body.currency, body.leverage, body.balance, body.equity,
             body.margin_free, body.day_pnl, len(body.positions),
             int(body.demo), json.dumps(body.model_dump())))
        con.execute("DELETE FROM heartbeats WHERE token_id=? AND id NOT IN "
                    "(SELECT id FROM heartbeats WHERE token_id=? ORDER BY ts DESC LIMIT 500)",
                    (row["id"], row["id"]))
        for t in body.closed:
            try:
                ticket = int(t.get("ticket", 0))
            except Exception:
                continue
            if not ticket:
                continue
            con.execute(
                """INSERT INTO trades(token_id, ticket, symbol, dir, lots,
                                      open_time, close_time, open_price,
                                      close_price, profit, raw)
                   VALUES(?,?,?,?,?,?,?,?,?,?,?)
                   ON CONFLICT(token_id, ticket) DO UPDATE SET
                     profit=excluded.profit, close_time=excluded.close_time,
                     close_price=excluded.close_price, raw=excluded.raw""",
                (row["id"], ticket, str(t.get("symbol", "")),
                 str(t.get("dir", "")), float(t.get("lots", 0) or 0),
                 int(t.get("open_time", 0) or 0), int(t.get("close_time", 0) or 0),
                 float(t.get("open", 0) or 0), float(t.get("close", 0) or 0),
                 float(t.get("profit", 0) or 0), json.dumps(t)))
        con.execute("UPDATE tokens SET last_seen=?, is_demo=? WHERE id=?",
                    (ts, int(body.demo), row["id"]))
    out = config_flat(row)
    out["server_time"] = int(ts)
    return out


@app.get("/health")
def health():
    return {"ok": True, "time": int(now())}


@app.get("/manifest.webmanifest")
def manifest():
    return FileResponse(APP_DIR / "static" / "manifest.webmanifest",
                        media_type="application/manifest+json")


@app.get("/sw.js")
def service_worker():
    return FileResponse(
        APP_DIR / "static" / "sw.js",
        media_type="application/javascript",
        headers={"Service-Worker-Allowed": "/", "Cache-Control": "no-cache"},
    )


@app.get("/")
def index():
    return FileResponse(APP_DIR / "static" / "index.html")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app.main:app", host="0.0.0.0",
                port=int(os.environ.get("PORT", "8010")))
