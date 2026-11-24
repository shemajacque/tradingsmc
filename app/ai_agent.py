"""
Adaptive SMC trading agent.

Signal -> Brain (online learned score) -> Risk gates -> MT5 execution ->
outcome feedback.  It never runs live by default; every start is explicit and
the research gate plus SMC_ALLOW_LIVE_TRADING protect real accounts.
"""

from __future__ import annotations

import json
import math
import os
import sqlite3
import sys
import threading
import time
from contextlib import closing
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

APP_DIR = Path(__file__).resolve().parent
ROOT = APP_DIR.parent
PY_DIR = ROOT / "python"
if str(PY_DIR) not in sys.path:
    sys.path.insert(0, str(PY_DIR))

from smc_engine import StructureEngine

from . import mt5_direct as direct

DATA_DIR = Path(os.environ.get("SMC_DATA_DIR", APP_DIR / "data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = os.environ.get("SMC_DB", str(DATA_DIR / "smc.db"))
ALLOW_LIVE = os.environ.get("SMC_ALLOW_LIVE_TRADING", "0") == "1"

DEFAULT_CONFIG = {
    "symbols": ["GBPUSD", "EURUSD", "XAUUSD"],
    "timeframe": "H1",
    "htf": "H4",
    "risk_pct": 1.0,
    "sl_buffer_atr": 0.2,
    "sl_max_atr": 2.0,
    "max_trades_day": 3,
    "max_open": 3,
    "min_rr": 1.5,
    "min_score": 0.66,
    "interval_sec": 15,
    "max_spread_points": 35,
    "max_daily_loss_pct": 1.0,
    "session": "any",
    "magic": 730999,
    "scanner_mode": True,
    "auto_scan": True,
    "auto_scan_paper": True,
    "training_mode": False,
    "scan_universe": ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCAD", "XAUUSD"],
    "scan_bars": 200,
    "max_scan_take": 2,
    "train_max_hold_sec": 120,
}

DEFAULT_BRAIN = {
    "intercept": 0.0,
    "weights": {
        "bias_valid": 0.8,
        "irl_taken": 0.6,
        "htf_aligned": 0.5,
        "rr": 0.4,
        "zone_extreme": 0.5,
        "session": 0.2,
        "spread_ok": 0.1,
    },
    "seen": [],
    "features_by_deal": {},
    "updates": 0,
}

DEFAULT_STATS = {"signals": 0, "taken": 0, "wins": 0, "losses": 0,
                 "net": 0.0, "last_tick": 0, "last_error": "",
                 "training": {}, "training_runs": []}


def _db() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH, timeout=15)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    return con


def init_agent_db() -> None:
    with closing(_db()) as con, con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS agent_state (
                id INTEGER PRIMARY KEY CHECK(id = 1),
                running INTEGER NOT NULL DEFAULT 0,
                paper INTEGER NOT NULL DEFAULT 1,
                config TEXT NOT NULL,
                brain TEXT NOT NULL,
                stats TEXT NOT NULL,
                started REAL
            );
            CREATE TABLE IF NOT EXISTS agent_signals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                symbol TEXT NOT NULL,
                tf TEXT NOT NULL,
                side TEXT,
                score REAL,
                rr REAL,
                entry REAL,
                sl REAL,
                tp REAL,
                decision TEXT NOT NULL,
                reason TEXT NOT NULL,
                features TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS agent_actions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                ticket INTEGER,
                symbol TEXT,
                detail TEXT NOT NULL,
                result TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                level TEXT NOT NULL,
                msg TEXT NOT NULL
            );
            """
        )
        con.execute(
            "INSERT OR IGNORE INTO agent_state(id, running, paper, config, brain, stats) "
            "VALUES(1, 0, 0, ?, ?, ?)",
            (json.dumps(DEFAULT_CONFIG), json.dumps(DEFAULT_BRAIN),
             json.dumps(DEFAULT_STATS)),
        )


init_agent_db()


def _event(level: str, msg: str) -> None:
    with closing(_db()) as con, con:
        con.execute("INSERT INTO events(ts, level, msg) VALUES(?,?,?)",
                    (time.time(), level, msg[:500]))


def get_state() -> dict:
    with closing(_db()) as con:
        row = con.execute("SELECT * FROM agent_state WHERE id=1").fetchone()
    return {
        "running": bool(row["running"]),
        "paper": bool(row["paper"]),
        "config": json.loads(row["config"]),
        "brain": json.loads(row["brain"]),
        "stats": json.loads(row["stats"]),
        "started": row["started"],
    }


def _save(running: Optional[bool] = None, paper: Optional[bool] = None,
          config: Optional[dict] = None, brain: Optional[dict] = None,
          stats: Optional[dict] = None, started: Optional[float] = None) -> None:
    sets, vals = [], []
    for col, value in (("running", running), ("paper", paper),
                       ("config", config), ("brain", brain), ("stats", stats),
                       ("started", started)):
        if value is None:
            continue
        sets.append(f"{col}=?")
        if col in ("config", "brain", "stats"):
            vals.append(json.dumps(value))
        elif col in ("running", "paper"):
            vals.append(int(value))
        else:
            vals.append(value)
    if not sets:
        return
    with closing(_db()) as con, con:
        con.execute(f"UPDATE agent_state SET {', '.join(sets)} WHERE id=1", vals)


def _log_signal(symbol: str, tf: str, side: Optional[str], score: float,
                rr: float, entry: float, sl: float, tp: float,
                decision: str, reason: str, features: dict) -> None:
    with closing(_db()) as con, con:
        con.execute(
            """INSERT INTO agent_signals(ts, symbol, tf, side, score, rr,
                                          entry, sl, tp, decision, reason, features)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
            (time.time(), symbol, tf, side, score, rr, entry, sl, tp,
             decision, reason, json.dumps(features)))
        con.execute("DELETE FROM agent_signals WHERE id NOT IN "
                    "(SELECT id FROM agent_signals ORDER BY id DESC LIMIT 500)")


def _log_action(kind: str, ticket: Optional[int], symbol: str,
                detail: str, result: Any) -> None:
    with closing(_db()) as con, con:
        con.execute(
            """INSERT INTO agent_actions(ts, kind, ticket, symbol, detail, result)
               VALUES(?,?,?,?,?,?)""",
            (time.time(), kind, ticket, symbol, detail, str(result)[:400]))
        con.execute("DELETE FROM agent_actions WHERE id NOT IN "
                    "(SELECT id FROM agent_actions ORDER BY id DESC LIMIT 500)")


def signals(limit: int = 50) -> list[dict]:
    with closing(_db()) as con:
        rows = con.execute("SELECT * FROM agent_signals ORDER BY id DESC LIMIT ?",
                           (limit,)).fetchall()
    return [dict(r) for r in rows]


def actions(limit: int = 50) -> list[dict]:
    with closing(_db()) as con:
        rows = con.execute("SELECT * FROM agent_actions ORDER BY id DESC LIMIT ?",
                           (limit,)).fetchall()
    return [dict(r) for r in rows]


def predict(brain: dict, features: dict) -> float:
    z = float(brain.get("intercept", 0.0))
    for key, value in features.items():
        if isinstance(value, (int, float)):
            z += float(brain["weights"].get(key, 0.0)) * float(value)
    try:
        return 1.0 / (1.0 + math.exp(-z))
    except OverflowError:
        return 0.0 if z < 0 else 1.0


def _learn(brain: dict, cfg: dict, stats: dict) -> None:
    magic = int(cfg["magic"])
    deals = direct.history(days=30, limit=500, magic=magic)
    seen = set(brain.get("seen", []))
    mapping = brain.get("features_by_deal", {})
    targets = []
    for d in deals:
        entry = str(d.get("entry", ""))
        if entry not in ("OUT", "OUT BY", "INOUT"):
            continue
        pid = d.get("position_id")
        if not pid or int(pid) in seen:
            continue
        seen.add(int(pid))
        net = float(d.get("profit", 0) or 0) + float(d.get("commission", 0) or 0) + \
            float(d.get("swap", 0) or 0) + float(d.get("fee", 0) or 0)
        feats = mapping.get(str(d.get("position_id"))) or \
            mapping.get(str(d.get("order"))) or \
            mapping.get(str(d.get("ticket")))
        targets.append((feats, net))
        mapping.pop(str(d.get("position_id")), None)
        mapping.pop(str(d.get("order")), None)
        mapping.pop(str(d.get("ticket")), None)

    for _, net in targets:
        if net > 0:
            stats["wins"] = stats.get("wins", 0) + 1
        elif net < 0:
            stats["losses"] = stats.get("losses", 0) + 1
        stats["net"] = stats.get("net", 0.0) + net
    if not targets:
        brain["seen"] = list(seen)[-500:]
        return
    lr = 0.08
    for feats, net in targets:
        target = 1.0 if net > 0 else 0.0
        if feats:
            p = predict(brain, feats)
            err = target - p
            for key, value in feats.items():
                if isinstance(value, (int, float)):
                    brain["weights"][key] = \
                        brain["weights"].get(key, 0.0) + lr * err * float(value)
            brain["intercept"] = brain.get("intercept", 0.0) + lr * err
        brain["updates"] = brain.get("updates", 0) + 1
    brain["seen"] = list(seen)[-500:]
    brain["features_by_deal"] = dict(list(mapping.items())[-200:])


def _session_ok(session: str) -> bool:
    hour = datetime.utcnow().hour
    if session == "london":
        return 7 <= hour < 16
    if session == "newyork":
        return 12 <= hour < 21
    if session == "asia":
        return hour >= 23 or hour < 8
    return True


def _build_signal(symbol: str, cfg: dict, brain: dict) -> dict:
    tf = str(cfg["timeframe"])
    htf = str(cfg["htf"])
    bars = int(cfg.get("scan_bars", 300))
    ltf_bars = direct.rates(symbol, tf, bars)
    htf_bars = direct.rates(symbol, htf, bars)
    eng = StructureEngine()
    for b in ltf_bars:
        eng.push_bar(b["time"], b["open"], b["high"], b["low"], b["close"])
    htf_eng = StructureEngine()
    for b in htf_bars:
        htf_eng.push_bar(b["time"], b["open"], b["high"], b["low"], b["close"])

    training = bool(cfg.get("training_mode"))
    rng = eng.active_range() if training else eng.last_range
    if rng is None or (not training and (not eng.bias_valid or rng.broken)):
        return {"decision": "SKIP", "reason": "no valid range/bias",
                "features": {}, "score": 0.0}
    if not training and not rng.irl_taken:
        return {"decision": "SKIP", "reason": "IRL not taken",
                "features": {}, "score": 0.0}

    tick_spread, point = direct.spread(symbol)
    tick = eng.bars[-1]["close"]
    zone = eng.range_zone(tick, rng)
    if training:
        side = "buy" if rng.direction == 1 else "sell"
    elif rng.direction == 1 and zone in ("DISCOUNT", "EXTREME_DISCOUNT"):
        side = "buy"
    elif rng.direction == -1 and zone in ("PREMIUM", "EXTREME_PREMIUM"):
        side = "sell"
    else:
        return {"decision": "SKIP", "reason": f"zone {zone} not tradable",
                "features": {}, "score": 0.0}

    htf_aligned = int(htf_eng.bias_valid and htf_eng.bias == rng.direction)
    atr = eng.atr[-1] if eng.atr else point * 50
    buf_atr = float(cfg.get("sl_buffer_atr", 0.2))
    cap_atr = float(cfg.get("sl_max_atr", 2.0))
    if side == "buy":
        swing = eng.swing_lows[-1].price if eng.swing_lows else tick
        raw = min(swing, tick) - buf_atr * atr
        sl = max(raw, tick - cap_atr * atr)
        tp = rng.rh
        if not (sl < tick < tp) or abs(tick - sl) < point:
            return {"decision": "SKIP", "reason": "SL too tight for buy",
                    "features": {}, "score": 0.0}
    else:
        swing = eng.swing_highs[-1].price if eng.swing_highs else tick
        raw = max(swing, tick) + buf_atr * atr
        sl = min(raw, tick + cap_atr * atr)
        tp = rng.rl
        if not (tp < tick < sl) or abs(tick - sl) < point:
            return {"decision": "SKIP", "reason": "SL too tight for sell",
                    "features": {}, "score": 0.0}

    rr = abs(tp - tick) / abs(tick - sl) if sl != tick else 0.0
    spread_ok = int(tick_spread <= int(cfg["max_spread_points"]))
    features = {
        "bias_valid": 1.0 if eng.bias_valid else 0.0,
        "irl_taken": 1.0 if rng.irl_taken else 0.0,
        "htf_aligned": float(htf_aligned),
        "rr": min(rr / 3.0, 1.0),
        "zone_extreme": 1.0 if "EXTREME" in zone else 0.5,
        "session": float(_session_ok(str(cfg["session"]))),
        "spread_ok": float(spread_ok),
    }
    score = predict(brain, features)
    result = {
        "decision": "TAKE" if score >= float(cfg["min_score"]) and
        rr >= float(cfg["min_rr"]) and spread_ok and htf_aligned else "SKIP",
        "reason": "", "features": features, "score": score,
        "side": side, "entry": tick, "sl": sl, "tp": tp, "rr": rr,
        "zone": zone, "spread": tick_spread,
    }
    if result["decision"] == "SKIP":
        if score < float(cfg["min_score"]):
            result["reason"] = f"score {score:.2f} below {cfg['min_score']}"
        elif rr < float(cfg["min_rr"]):
            result["reason"] = f"RR {rr:.2f} below {cfg['min_rr']}"
        elif not spread_ok:
            result["reason"] = f"spread {tick_spread} too high"
        else:
            result["reason"] = "HTF bias not aligned"
    return result


def _manage_open(cfg: dict) -> None:
    magic = int(cfg["magic"])
    max_hold = int(cfg.get("train_max_hold_sec", 0) or 0)
    srv_now = direct.server_time() if max_hold else 0
    for p in direct.positions():
        if int(p.get("magic", 0)) != magic:
            continue
        if max_hold and p.get("time") and srv_now - float(p["time"]) > max_hold:
            try:
                r = direct.close_position(p["ticket"])
                _log_action("TRAIN_EXIT", p["ticket"], p["symbol"],
                            f"held > {max_hold}s", r)
            except Exception as exc:
                _log_action("ERROR", p["ticket"], p["symbol"],
                            "training exit", str(exc))
            continue
        if not p.get("sl"):
            continue
        dist = abs(float(p["open"]) - float(p["sl"]))
        if dist <= 0:
            continue
        is_buy = p["side"] == "BUY"
        if is_buy:
            target = float(p["open"]) + dist
            reached = float(p["current"]) >= target
            be_ok = float(p["sl"]) < float(p["open"])
        else:
            target = float(p["open"]) - dist
            reached = float(p["current"]) <= target
            be_ok = float(p["sl"]) > float(p["open"])
        if reached and be_ok:
            try:
                r = direct.break_even(p["ticket"], 2)
                _log_action("BREAK_EVEN", p["ticket"], p["symbol"], "1R reached", r)
            except Exception as exc:
                _log_action("ERROR", p["ticket"], p["symbol"], "break-even", str(exc))


def _safety_stop(cfg: dict, stats: dict, reason: str) -> None:
    stats["last_error"] = reason
    _save(running=False, stats=stats)
    _log_action("STOP", None, "", reason, "agent stopped")
    _event("warn", "AI agent stopped: " + reason)


def _tick(force: bool = False) -> None:
    state = get_state()
    if not state["running"] and not force:
        return
    cfg = state["config"]
    brain = state["brain"]
    stats = state["stats"]
    stats["last_tick"] = time.time()
    try:
        acc = direct.account()
        if not acc.get("demo") and not ALLOW_LIVE:
            _safety_stop(cfg, stats, "live account blocked; SMC_ALLOW_LIVE_TRADING=0")
            return
        if not acc.get("trade_allowed"):
            _log_action("WARN", None, "", "trade_allowed=false", "skipping tick")
            _save(stats=stats)
            return

        _learn(brain, cfg, stats)
        _manage_open(cfg)

        magic = int(cfg["magic"])
        today = direct.history(days=1, limit=500, magic=magic)
        entries_today = sum(1 for d in today if str(d.get("entry")) == "IN")
        day_net = sum(float(d.get("profit", 0) or 0) +
                      float(d.get("commission", 0) or 0) +
                      float(d.get("swap", 0) or 0) +
                      float(d.get("fee", 0) or 0) for d in today)
        max_loss = acc["balance"] * float(cfg["max_daily_loss_pct"]) / 100.0
        if day_net <= -max_loss:
            _safety_stop(cfg, stats, f"daily loss limit hit ({day_net:.2f})")
            return
        open_agents = [p for p in direct.positions()
                       if int(p.get("magic", 0)) == magic]
        if len(open_agents) >= int(cfg["max_open"]):
            _save(brain=brain, stats=stats)
            return

        def process(symbol: str, sig: dict) -> None:
            nonlocal entries_today, open_agents
            stats["signals"] = stats.get("signals", 0) + 1
            decision = sig.get("decision", "SKIP")
            if decision == "TAKE" and not state["paper"]:
                if entries_today >= int(cfg["max_trades_day"]) or \
                        len(open_agents) >= int(cfg["max_open"]):
                    decision = "SKIP"
                    sig["reason"] = "trade cap reached"
                else:
                    try:
                        sized = direct.calc_lot(symbol, sig["side"], cfg["risk_pct"],
                                                sig["sl"], sig["tp"])
                        if sized["lots"] <= 0:
                            decision = "SKIP"
                            sig["reason"] = sized.get("note") or "lot size below minimum"
                        else:
                            result = direct.place_order(
                                symbol, sig["side"], sized["lots"], sig["sl"], sig["tp"],
                                magic=magic, comment="SMC AI")
                            brain.setdefault("features_by_deal", {})[
                                str(result.get("order"))] = sig["features"]
                            brain["features_by_deal"][
                                str(result.get("deal"))] = sig["features"]
                            stats["taken"] = stats.get("taken", 0) + 1
                            entries_today += 1
                            open_agents.append({"ticket": result.get("deal")})
                            _log_action("ORDER", result.get("deal"), symbol,
                                        f"{sig['side']} {sized['lots']} lots score={sig['score']:.3f}",
                                        result)
                    except Exception as exc:
                        decision = "SKIP"
                        sig["reason"] = str(exc)
                        _log_action("ERROR", None, symbol, "order", str(exc))
            _log_signal(symbol, str(cfg["timeframe"]), sig.get("side"),
                        sig.get("score", 0.0), sig.get("rr", 0.0),
                        sig.get("entry", 0.0), sig.get("sl", 0.0),
                        sig.get("tp", 0.0), decision, sig.get("reason", ""),
                        sig.get("features", {}))

        if cfg.get("scanner_mode"):
            universe = cfg.get("scan_universe") or cfg["symbols"]
            ranked = []
            for symbol in universe:
                try:
                    sig = _build_signal(symbol, cfg, brain)
                except Exception as exc:
                    _log_action("ERROR", None, symbol, "signal build", str(exc))
                    continue
                if sig.get("decision") == "TAKE":
                    ranked.append((symbol, sig))
                else:
                    process(symbol, sig)
            ranked.sort(key=lambda item: (item[1].get("score", 0.0),
                                          item[1].get("rr", 0.0)), reverse=True)
            limit = int(cfg.get("max_scan_take", 2))
            for symbol, sig in ranked[:limit]:
                process(symbol, sig)
            for symbol, sig in ranked[limit:]:
                sig["reason"] = "scanner rank"
                sig["decision"] = "SKIP"
                process(symbol, sig)
        else:
            for symbol in cfg["symbols"]:
                if entries_today >= int(cfg["max_trades_day"]) or \
                        len(open_agents) >= int(cfg["max_open"]):
                    break
                try:
                    sig = _build_signal(symbol, cfg, brain)
                except Exception as exc:
                    _log_action("ERROR", None, symbol, "signal build", str(exc))
                    continue
                process(symbol, sig)
        stats["last_error"] = ""
    except Exception as exc:
        stats["last_error"] = str(exc)
        _log_action("ERROR", None, "", "tick", str(exc))
    current_training = get_state()["stats"].get("training")
    if current_training:
        stats["training"] = current_training
    _save(brain=brain, stats=stats)


class AgentRuntime:
    def __init__(self) -> None:
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()

    def start(self, paper: bool = True) -> dict:
        with self._lock:
            state = get_state()
            if state["running"] and self._thread and self._thread.is_alive():
                return {"ok": True, "already": True}
            self._stop.clear()
            _save(running=True, paper=paper, started=time.time())
            self._thread = threading.Thread(target=self._loop, daemon=True,
                                            name="smc-ai-agent")
            self._thread.start()
            _event("info", f"AI agent started paper={paper}")
            return {"ok": True, "already": False}

    def stop(self) -> dict:
        with self._lock:
            self._stop.set()
            if self._thread and self._thread.is_alive():
                self._thread.join(timeout=8)
            self._thread = None
            _save(running=False)
            _event("info", "AI agent stopped")
            return {"ok": True}

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                _tick()
            except Exception as exc:
                _log_action("ERROR", None, "", "loop", str(exc))
            state = get_state()
            if not state["running"]:
                break
            interval = max(5, min(300, int(state["config"].get("interval_sec", 15))))
            self._stop.wait(interval)


runtime = AgentRuntime()


def _training_loop(target_trades: int, max_trades: int, timeout_min: int) -> None:
    state = get_state()
    stats = state["stats"]
    training = stats.get("training") or {}
    if training.get("status") == "running":
        return
    runs = stats.setdefault("training_runs", [])
    if training.get("status") == "done":
        runs.append(dict(training))
        stats["training_runs"] = runs[-20:]
    backup = dict(state["config"])
    try:
        start_equity = float(direct.account()["equity"])
    except Exception as exc:
        training = {"status": "done", "result": f"MT5 unavailable: {exc}"}
        stats["training"] = training
        _save(stats=stats)
        return

    stats["wins"] = 0
    stats["losses"] = 0
    stats["net"] = 0.0
    stats["taken"] = 0
    training = {
        "status": "running",
        "started": time.time(),
        "start_equity": start_equity,
        "target_trades": target_trades,
        "max_trades": max_trades,
        "closed": 0,
        "net": 0.0,
        "result": "",
    }
    stats["training"] = training

    cfg = dict(backup)
    cfg.update({
        "scanner_mode": True,
        "training_mode": True,
        "symbols": ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCAD",
                    "XAUUSD", "EURJPY", "GBPJPY", "NZDUSD", "USDCHF"],
        "timeframe": "M15",
        "htf": "H1",
        "scan_bars": 150,
        "risk_pct": 0.3,
        "min_score": 0.35,
        "min_rr": 0.8,
        "max_spread_points": 100,
        "max_trades_day": max_trades,
        "max_open": 5,
        "max_scan_take": 8,
        "interval_sec": 5,
        "max_daily_loss_pct": 3.0,
        "train_max_hold_sec": 60,
    })
    _save(config=cfg, stats=stats)
    _log_action("TRAIN", None, "", "training started",
                f"target={target_trades} max={max_trades} timeout={timeout_min}m")
    runtime.stop()
    runtime.start(paper=False)

    deadline = time.time() + timeout_min * 60
    while time.time() < deadline:
        time.sleep(5)
        current = get_state()
        live_stats = current["stats"]
        closed = int(live_stats.get("wins", 0) + live_stats.get("losses", 0))
        net = float(live_stats.get("net", 0.0))
        training["closed"] = closed
        training["net"] = net
        live_stats["training"] = dict(training)
        _save(stats=live_stats)
        if not current["running"]:
            training["result"] = "agent stopped"
            break
        if closed >= target_trades and net > 0:
            training["result"] = "profitable"
            break
        if closed >= max_trades:
            training["result"] = "target not met"
            break
    runtime.stop()
    _save(config=backup)
    try:
        final_equity = float(direct.account()["equity"])
    except Exception:
        final_equity = start_equity
    training["status"] = "done"
    training["ended"] = time.time()
    training["final_net"] = training["net"]
    training["final_equity"] = final_equity
    live_stats = get_state()["stats"]
    live_stats["training"] = training
    live_runs = live_stats.setdefault("training_runs", [])
    live_runs.append(dict(training))
    live_stats["training_runs"] = live_runs[-20:]
    _save(stats=live_stats)
    _log_action("TRAIN", None, "", "training finished",
                f"{training['result']} closed={training['closed']} net={training['net']:.2f}")


def start_training(target_trades: int = 10, max_trades: int = 60,
                   timeout_min: int = 30) -> dict:
    state = get_state()
    training = state["stats"].get("training") or {}
    if training.get("status") == "running":
        return {"ok": False, "reason": "training is already running"}
    threading.Thread(target=_training_loop,
                     args=(target_trades, max_trades, timeout_min),
                     daemon=True, name="smc-ai-training").start()
    return {"ok": True}


def tick_once() -> dict:
    _tick(force=True)
    return get_state()
