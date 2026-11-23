"""
Direct MetaTrader 5 bridge.

This only works when the app runs on the same Windows machine as the MT5
terminal (or a Windows VPS with MT5 installed and logged in).  It is used for
the local dashboard: live account, open positions, pending orders, history and
trade management.  When the app is hosted on Linux, use the EA heartbeat API
instead.

Nothing in this module is imported by the EA.  All calls are serialized because
the MetaTrader5 Python package is not thread-safe.
"""

from __future__ import annotations

import atexit
import math
import threading
from datetime import datetime, timedelta
from typing import Any, Optional

try:
    import MetaTrader5 as mt5

    HAS_MT5 = True
except Exception:  # pragma: no cover - package is optional on Linux
    mt5 = None
    HAS_MT5 = False


class DirectError(RuntimeError):
    pass


_LOCK = threading.RLock()
_CONNECTED = False


def _shutdown() -> None:
    global _CONNECTED
    with _LOCK:
        if _CONNECTED and HAS_MT5:
            try:
                mt5.shutdown()
            except Exception:
                pass
        _CONNECTED = False


atexit.register(_shutdown)


def _ensure() -> None:
    global _CONNECTED
    if not HAS_MT5:
        raise DirectError("MetaTrader5 package is not installed on this server")
    with _LOCK:
        if _CONNECTED and mt5.account_info() is not None:
            return
        if not mt5.initialize():
            code, msg = mt5.last_error()
            _CONNECTED = False
            raise DirectError(f"MT5 initialize failed ({code}): {msg}")
        _CONNECTED = True


def _account_raw():
    _ensure()
    info = mt5.account_info()
    if info is None:
        code, msg = mt5.last_error()
        raise DirectError(f"MT5 account unavailable ({code}): {msg}")
    return info


def account() -> dict:
    with _LOCK:
        a = _account_raw()
        demo = a.trade_mode == mt5.ACCOUNT_TRADE_MODE_DEMO
        mode = {0: "demo", 1: "contest", 2: "real"}.get(a.trade_mode, "unknown")
        return {
            "login": a.login,
            "name": a.name,
            "server": a.server,
            "company": a.company,
            "currency": a.currency,
            "leverage": a.leverage,
            "balance": a.balance,
            "equity": a.equity,
            "margin": a.margin,
            "margin_free": a.margin_free,
            "margin_level": a.margin_level,
            "profit": a.profit,
            "credit": a.credit,
            "demo": demo,
            "trade_mode": mode,
            "trade_allowed": bool(a.trade_allowed),
            "trade_expert": bool(a.trade_expert),
        }


def _position_dict(p) -> dict:
    risk = reward = None
    if p.sl:
        risk = mt5.order_calc_profit(p.type, p.symbol, p.volume,
                                     p.price_open, p.sl)
    if p.tp:
        reward = mt5.order_calc_profit(p.type, p.symbol, p.volume,
                                       p.price_open, p.tp)
    rr = None
    if risk not in (None, 0) and reward is not None:
        rr = reward / abs(risk)
    return {
        "ticket": p.ticket,
        "time": p.time,
        "symbol": p.symbol,
        "side": "BUY" if p.type == mt5.POSITION_TYPE_BUY else "SELL",
        "volume": p.volume,
        "open": p.price_open,
        "current": p.price_current,
        "sl": p.sl,
        "tp": p.tp,
        "swap": p.swap,
        "profit": p.profit,
        "risk": risk,
        "reward": reward,
        "rr": rr,
        "magic": p.magic,
        "comment": p.comment,
        "identifier": p.identifier,
    }


def positions() -> list[dict]:
    with _LOCK:
        _ensure()
        rows = mt5.positions_get()
        if rows is None:
            code, msg = mt5.last_error()
            raise DirectError(f"positions unavailable ({code}): {msg}")
        return [_position_dict(p) for p in rows]


def _order_dict(o) -> dict:
    types = {
        mt5.ORDER_TYPE_BUY: "BUY LIMIT",
        mt5.ORDER_TYPE_SELL: "SELL LIMIT",
        mt5.ORDER_TYPE_BUY_STOP: "BUY STOP",
        mt5.ORDER_TYPE_SELL_STOP: "SELL STOP",
        mt5.ORDER_TYPE_BUY_STOP_LIMIT: "BUY STOP LIMIT",
        mt5.ORDER_TYPE_SELL_STOP_LIMIT: "SELL STOP LIMIT",
    }
    return {
        "ticket": o.ticket,
        "time": o.time_setup,
        "symbol": o.symbol,
        "type": types.get(o.type, str(o.type)),
        "volume": o.volume_current,
        "open": o.price_open,
        "current": o.price_current,
        "sl": o.sl,
        "tp": o.tp,
        "magic": o.magic,
        "comment": o.comment,
    }


def orders() -> list[dict]:
    with _LOCK:
        _ensure()
        rows = mt5.orders_get()
        if rows is None:
            code, msg = mt5.last_error()
            raise DirectError(f"orders unavailable ({code}): {msg}")
        return [_order_dict(o) for o in rows]


def history(days: int = 7, limit: int = 500, magic: Optional[int] = None) -> list[dict]:
    days = max(1, min(int(days), 365))
    limit = max(1, min(int(limit), 500))
    with _LOCK:
        _ensure()
        start = datetime.now() - timedelta(days=days)
        end = datetime.now() + timedelta(days=1)
        rows = mt5.history_deals_get(start, end)
        if rows is None:
            code, msg = mt5.last_error()
            raise DirectError(f"history unavailable ({code}): {msg}")
        if magic is not None:
            rows = [d for d in rows if int(d.magic) == int(magic)]
        out = []
        for d in rows[-limit:][::-1]:
            out.append({
                "ticket": d.ticket,
                "order": d.order,
                "position_id": d.position_id,
                "time": d.time,
                "symbol": d.symbol,
                "type": {0: "BUY", 1: "SELL", 2: "BALANCE"}.get(d.type, str(d.type)),
                "entry": {0: "IN", 1: "OUT", 2: "INOUT", 3: "OUT BY"}.get(d.entry, str(d.entry)),
                "volume": d.volume,
                "price": d.price,
                "profit": d.profit,
                "commission": d.commission,
                "swap": d.swap,
                "fee": d.fee,
                "comment": d.comment,
                "magic": d.magic,
            })
        return out


TIMEFRAMES = {
    "M1": getattr(mt5, "TIMEFRAME_M1", 1) if mt5 else 1,
    "M5": getattr(mt5, "TIMEFRAME_M5", 5) if mt5 else 5,
    "M15": getattr(mt5, "TIMEFRAME_M15", 15) if mt5 else 15,
    "M30": getattr(mt5, "TIMEFRAME_M30", 30) if mt5 else 30,
    "H1": getattr(mt5, "TIMEFRAME_H1", 60) if mt5 else 60,
    "H4": getattr(mt5, "TIMEFRAME_H4", 240) if mt5 else 240,
    "D1": getattr(mt5, "TIMEFRAME_D1", 1440) if mt5 else 1440,
}


def rates(symbol: str, timeframe: str = "H1", count: int = 300) -> list[dict]:
    tf = TIMEFRAMES.get(str(timeframe).upper())
    if tf is None:
        raise ValueError(f"unsupported timeframe {timeframe}")
    count = max(30, min(int(count), 2000))
    with _LOCK:
        _ensure()
        _symbol(symbol)
        rows = mt5.copy_rates_from_pos(symbol, tf, 0, count)
        if rows is None:
            code, msg = mt5.last_error()
            raise DirectError(f"rates unavailable ({code}): {msg}")
        bars = [{"time": int(r["time"]), "open": float(r["open"]),
                 "high": float(r["high"]), "low": float(r["low"]),
                 "close": float(r["close"])} for r in rows]
        return bars[:-1]


def spread(symbol: str) -> tuple[float, float]:
    with _LOCK:
        info = _symbol(symbol)
        return float(info.spread), float(info.point)


def server_time(symbol: str = "EURUSD") -> int:
    with _LOCK:
        _ensure()
        tick = mt5.symbol_info_tick(symbol)
        return int(tick.time) if tick is not None else int(datetime.now().timestamp())


def symbols(limit: int = 40) -> list[dict]:
    with _LOCK:
        _ensure()
        rows = mt5.symbols_get()
        if rows is None:
            code, msg = mt5.last_error()
            raise DirectError(f"symbols unavailable ({code}): {msg}")
        disabled = getattr(mt5, "SYMBOL_TRADE_MODE_DISABLED", 0)
        out = []
        for s in rows:
            if not getattr(s, "visible", False):
                continue
            if getattr(s, "trade_mode", 0) == disabled:
                continue
            out.append({
                "name": s.name,
                "spread": int(getattr(s, "spread", 0)),
                "digits": int(getattr(s, "digits", 0)),
                "volume_min": float(getattr(s, "volume_min", 0.01)),
                "currency": getattr(s, "currency_base", ""),
            })
        out.sort(key=lambda x: (x["spread"], x["name"]))
        return out[:max(1, min(int(limit), 200))]


def summary() -> dict:
    with _LOCK:
        a = account()
        pos = positions()
        pending = orders()
        return {
            "available": True,
            "account": a,
            "position_count": len(pos),
            "order_count": len(pending),
            "positions": pos,
            "orders": pending,
        }


def _net(d) -> float:
    return float(d.profit) + float(d.commission) + float(d.swap) + \
        float(getattr(d, "fee", 0.0) or 0.0)


def equity_curve(days: int = 30) -> dict:
    days = max(1, min(int(days), 365))
    with _LOCK:
        _ensure()
        a = _account_raw()
        start = datetime.now() - timedelta(days=days)
        end = datetime.now() + timedelta(days=1)
        deals = mt5.history_deals_get(start, end) or ()
        balance_type = getattr(mt5, "DEAL_TYPE_BALANCE", 2)
        deals = sorted((d for d in deals if d.type != balance_type),
                       key=lambda d: d.time)
        base = float(a.balance) - sum(_net(d) for d in deals)
        points = [{"t": int(start.timestamp()),
                   "balance": round(base, 2), "equity": round(base, 2)}]
        bal = base
        for d in deals:
            bal += _net(d)
            points.append({"t": int(d.time), "balance": round(bal, 2),
                           "equity": round(bal, 2)})
        points.append({"t": int(datetime.now().timestamp()),
                       "balance": round(a.balance, 2),
                       "equity": round(a.equity, 2)})
        return {"days": days, "currency": a.currency,
                "note": "deposits and withdrawals are excluded",
                "points": points[-300:]}


def analytics(days: int = 30) -> dict:
    days = max(1, min(int(days), 365))
    out_entry = getattr(mt5, "DEAL_ENTRY_OUT", 1)
    out_by_entry = getattr(mt5, "DEAL_ENTRY_OUT_BY", 3)
    inout_entry = getattr(mt5, "DEAL_ENTRY_INOUT", 2)
    balance_type = getattr(mt5, "DEAL_TYPE_BALANCE", 2)
    with _LOCK:
        _ensure()
        a = _account_raw()
        pos = positions()
        start = datetime.now() - timedelta(days=days)
        end = datetime.now() + timedelta(days=1)
        deals = mt5.history_deals_get(start, end) or ()

        nets = []
        for d in deals:
            if d.type == balance_type or not d.symbol:
                continue
            if d.entry not in (out_entry, out_by_entry, inout_entry):
                continue
            nets.append(_net(d))

        trades = len(nets)
        wins = sum(1 for n in nets if n > 0)
        losses = sum(1 for n in nets if n < 0)
        gross_profit = sum(n for n in nets if n > 0)
        gross_loss = sum(n for n in nets if n < 0)
        net_total = sum(nets)
        avg_win = gross_profit / wins if wins else None
        avg_loss = gross_loss / losses if losses else None
        pf = gross_profit / abs(gross_loss) if gross_loss else None
        payoff = (avg_win / abs(avg_loss)) if (avg_win and avg_loss) else None
        expectancy = net_total / trades if trades else None

        exposure: dict[str, dict] = {}
        open_risk = open_reward = floating = 0.0
        long_vol = short_vol = total_vol = 0.0
        for p in pos:
            e = exposure.setdefault(p["symbol"], {
                "symbol": p["symbol"], "long": 0.0, "short": 0.0,
                "floating": 0.0, "risk": 0.0,
            })
            if p["side"] == "BUY":
                e["long"] += p["volume"]
                long_vol += p["volume"]
            else:
                e["short"] += p["volume"]
                short_vol += p["volume"]
            total_vol += p["volume"]
            e["floating"] += p["profit"] + p["swap"]
            floating += p["profit"] + p["swap"]
            if p["risk"] is not None and p["risk"] < 0:
                e["risk"] += abs(p["risk"])
                open_risk += abs(p["risk"])
            if p["reward"] is not None and p["reward"] > 0:
                open_reward += p["reward"]

        return {
            "days": days,
            "currency": a.currency,
            "account": {
                "balance": a.balance, "equity": a.equity,
                "margin_level": a.margin_level,
                "free_margin": a.margin_free,
            },
            "closed": {
                "trades": trades, "wins": wins, "losses": losses,
                "scratches": trades - wins - losses,
                "win_rate": (wins / trades) if trades else None,
                "net": net_total, "gross_profit": gross_profit,
                "gross_loss": gross_loss, "profit_factor": pf,
                "avg_win": avg_win, "avg_loss": avg_loss,
                "payoff": payoff, "expectancy": expectancy,
                "best": max(nets) if nets else None,
                "worst": min(nets) if nets else None,
                "result": nets,
            },
            "open": {
                "count": len(pos), "volume": total_vol,
                "long_volume": long_vol, "short_volume": short_vol,
                "floating": floating, "risk": open_risk,
                "reward": open_reward,
                "risk_pct": (open_risk / a.equity * 100) if a.equity else None,
            },
            "exposure": list(exposure.values()),
        }


def calc_lot(symbol: str, side: str, risk_pct: float, sl: float,
             tp: float = 0.0, entry: float = 0.0) -> dict:
    side = side.lower().strip()
    if side not in ("buy", "sell"):
        raise ValueError("side must be buy or sell")
    if risk_pct <= 0 or risk_pct > 100:
        raise ValueError("risk_pct must be between 0 and 100")
    with _LOCK:
        _ensure()
        a = _account_raw()
        info = _symbol(symbol)
        tick = mt5.symbol_info_tick(symbol)
        if tick is None:
            raise DirectError(f"no tick for {symbol}")
        is_buy = side == "buy"
        entry = float(entry) if entry else (tick.ask if is_buy else tick.bid)
        sl = round(float(sl), info.digits)
        tp = round(float(tp), info.digits) if tp else 0.0
        if sl <= 0:
            raise ValueError("SL is required for risk sizing")
        if is_buy and sl >= entry:
            raise ValueError("buy SL must be below entry")
        if not is_buy and sl <= entry:
            raise ValueError("sell SL must be above entry")
        if tp:
            if is_buy and tp <= entry:
                raise ValueError("buy TP must be above entry")
            if not is_buy and tp >= entry:
                raise ValueError("sell TP must be below entry")

        action = mt5.ORDER_TYPE_BUY if is_buy else mt5.ORDER_TYPE_SELL
        loss_per_lot = mt5.order_calc_profit(action, symbol, 1.0, entry, sl)
        if loss_per_lot is None or loss_per_lot >= 0:
            raise ValueError("cannot calculate loss for that SL")

        risk_money = a.balance * risk_pct / 100.0
        step = float(info.volume_step or 0.01)
        lots = math.floor((risk_money / abs(loss_per_lot)) / step + 1e-9) * step
        lots = round(lots, 8)
        note = ""
        if lots < info.volume_min:
            note = f"risk budget is below the minimum lot ({info.volume_min})"
            lots = 0.0
        lots = min(lots, info.volume_max)
        actual_risk = 0.0
        reward = None
        rr = None
        if lots > 0:
            actual_risk = abs(mt5.order_calc_profit(action, symbol, lots, entry, sl))
            if tp:
                reward = mt5.order_calc_profit(action, symbol, lots, entry, tp)
                if actual_risk:
                    rr = reward / actual_risk
        return {
            "side": side, "symbol": symbol,
            "entry": round(entry, info.digits), "sl": sl, "tp": tp,
            "lots": lots, "volume_min": info.volume_min,
            "volume_step": step, "risk_pct": risk_pct,
            "risk_money": risk_money, "actual_risk": actual_risk,
            "reward": reward, "rr": rr, "note": note,
        }


def _symbol(symbol: str):
    _ensure()
    info = mt5.symbol_info(symbol)
    if info is None:
        raise ValueError(f"unknown symbol {symbol}")
    if not info.visible:
        mt5.symbol_select(symbol, True)
        info = mt5.symbol_info(symbol)
    return info


def _filling(symbol: str) -> int:
    info = _symbol(symbol)
    if info.filling_mode & 2:
        return mt5.ORDER_FILLING_IOC
    if info.filling_mode & 1:
        return mt5.ORDER_FILLING_FOK
    return mt5.ORDER_FILLING_RETURN


def _send(filling: int, request: dict):
    request = dict(request)
    request["type_filling"] = filling
    result = mt5.order_send(request)
    if result is None:
        code, msg = mt5.last_error()
        raise DirectError(f"order_send failed ({code}): {msg}")
    return result


def _send_any_fill(symbol: str, request: dict):
    first = _filling(symbol)
    result = _send(first, request)
    if result.retcode == mt5.TRADE_RETCODE_INVALID_FILL:
        for alt in (mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_FOK,
                    mt5.ORDER_FILLING_RETURN):
            if alt != first:
                result = _send(alt, request)
                if result.retcode == mt5.TRADE_RETCODE_DONE:
                    break
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        raise ValueError(f"{result.retcode}: {result.comment or 'order rejected'}")
    return {
        "ok": True,
        "order": result.order,
        "deal": result.deal,
        "volume": result.volume,
        "price": result.price,
        "comment": result.comment,
    }


def _volume(symbol: str, volume: float) -> float:
    info = _symbol(symbol)
    step = float(info.volume_step or 0.01)
    v = math.floor(float(volume) / step + 1e-9) * step
    v = round(v, 8)
    if v < info.volume_min:
        raise ValueError(f"volume below minimum {info.volume_min}")
    if v > info.volume_max:
        raise ValueError(f"volume above maximum {info.volume_max}")
    return v


def _price(symbol: str, digits: int, value: float) -> float:
    return round(float(value), digits) if value else 0.0


def place_order(symbol: str, side: str, volume: float,
                sl: float = 0.0, tp: float = 0.0,
                magic: int = 0, comment: str = "SMC web") -> dict:
    side = side.lower().strip()
    if side not in ("buy", "sell"):
        raise ValueError("side must be buy or sell")
    with _LOCK:
        _ensure()
        info = _symbol(symbol)
        vol = _volume(symbol, volume)
        tick = mt5.symbol_info_tick(symbol)
        if tick is None:
            raise DirectError(f"no tick for {symbol}")
        is_buy = side == "buy"
        price = tick.ask if is_buy else tick.bid
        sl = _price(symbol, info.digits, sl)
        tp = _price(symbol, info.digits, tp)
        if sl:
            if is_buy and sl >= price:
                raise ValueError("buy SL must be below the entry price")
            if not is_buy and sl <= price:
                raise ValueError("sell SL must be above the entry price")
        if tp:
            if is_buy and tp <= price:
                raise ValueError("buy TP must be above the entry price")
            if not is_buy and tp >= price:
                raise ValueError("sell TP must be below the entry price")
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": vol,
            "type": mt5.ORDER_TYPE_BUY if is_buy else mt5.ORDER_TYPE_SELL,
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 30,
            "magic": int(magic),
            "comment": comment[:30],
            "type_time": mt5.ORDER_TIME_GTC,
        }
        return _send_any_fill(symbol, request)


def close_position(ticket: int, volume: Optional[float] = None) -> dict:
    with _LOCK:
        _ensure()
        rows = mt5.positions_get(ticket=int(ticket))
        if not rows:
            raise ValueError(f"position {ticket} not found")
        p = rows[0]
        vol = p.volume if volume is None else _volume(p.symbol, volume)
        if vol > p.volume + 1e-9:
            raise ValueError(f"volume {vol} is larger than position {p.volume}")
        tick = mt5.symbol_info_tick(p.symbol)
        if tick is None:
            raise DirectError(f"no tick for {p.symbol}")
        is_buy = p.type == mt5.POSITION_TYPE_BUY
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "position": p.ticket,
            "symbol": p.symbol,
            "volume": vol,
            "type": mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY,
            "price": tick.bid if is_buy else tick.ask,
            "deviation": 30,
            "magic": p.magic,
            "comment": "SMC web close",
            "type_time": mt5.ORDER_TIME_GTC,
        }
        result = _send_any_fill(p.symbol, request)
        result["volume_closed"] = vol
        return result


def break_even(ticket: int, buffer_points: float = 2.0) -> dict:
    with _LOCK:
        _ensure()
        rows = mt5.positions_get(ticket=int(ticket))
        if not rows:
            raise ValueError(f"position {ticket} not found")
        p = rows[0]
        info = _symbol(p.symbol)
        buf = max(0.0, float(buffer_points)) * info.point
        is_buy = p.type == mt5.POSITION_TYPE_BUY
        new_sl = p.price_open + buf if is_buy else p.price_open - buf
        new_sl = round(new_sl, info.digits)
        request = {
            "action": mt5.TRADE_ACTION_SLTP,
            "position": p.ticket,
            "symbol": p.symbol,
            "sl": new_sl,
            "tp": p.tp,
        }
        result = mt5.order_send(request)
        if result is None:
            code, msg = mt5.last_error()
            raise DirectError(f"order_send failed ({code}): {msg}")
        if result.retcode != mt5.TRADE_RETCODE_DONE:
            raise ValueError(f"{result.retcode}: {result.comment or 'break-even rejected'}")
        return {"ok": True, "ticket": p.ticket, "sl": new_sl, "tp": p.tp}


def close_all(symbol: Optional[str] = None) -> dict:
    with _LOCK:
        _ensure()
        rows = mt5.positions_get(symbol=symbol) if symbol else mt5.positions_get()
        if rows is None:
            code, msg = mt5.last_error()
            raise DirectError(f"positions unavailable ({code}): {msg}")
        closed, failed = [], []
        for p in rows:
            try:
                r = close_position(p.ticket)
                closed.append({"ticket": p.ticket, "symbol": p.symbol,
                               "volume": p.volume, "price": r.get("price")})
            except Exception as exc:
                failed.append({"ticket": p.ticket, "symbol": p.symbol,
                               "error": str(exc)})
        return {"closed": closed, "failed": failed}


def modify_position(ticket: int, sl: Optional[float] = None,
                    tp: Optional[float] = None) -> dict:
    with _LOCK:
        _ensure()
        rows = mt5.positions_get(ticket=int(ticket))
        if not rows:
            raise ValueError(f"position {ticket} not found")
        p = rows[0]
        info = _symbol(p.symbol)
        new_sl = _price(p.symbol, info.digits, sl if sl is not None else p.sl)
        new_tp = _price(p.symbol, info.digits, tp if tp is not None else p.tp)
        request = {
            "action": mt5.TRADE_ACTION_SLTP,
            "position": p.ticket,
            "symbol": p.symbol,
            "sl": new_sl,
            "tp": new_tp,
        }
        result = mt5.order_send(request)
        if result is None:
            code, msg = mt5.last_error()
            raise DirectError(f"order_send failed ({code}): {msg}")
        if result.retcode != mt5.TRADE_RETCODE_DONE:
            raise ValueError(f"{result.retcode}: {result.comment or 'modify rejected'}")
        return {"ok": True, "ticket": p.ticket, "sl": new_sl, "tp": new_tp}
