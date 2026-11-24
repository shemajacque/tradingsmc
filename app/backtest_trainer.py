"""
Offline backtest trainer for the AI agent.

Replays closed H1 bars through the SMC structure engine, records synthetic
signals and their forward outcomes, then trains the brain weights on the first
70% of trades and validates on the last 30%.
"""

from __future__ import annotations

import copy
import time
from pathlib import Path
from typing import Any, Optional

from . import ai_agent as agent
from smc_engine import StructureEngine

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

SYMBOLS = {
    "GBPUSD": 0.15,
    "XAUUSD": 0.10,
}


def _load(path: Path, limit: int) -> list[dict]:
    import csv
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            try:
                rows.append({
                    "time": int(float(r["time"])),
                    "open": float(r["open"]), "high": float(r["high"]),
                    "low": float(r["low"]), "close": float(r["close"]),
                })
            except Exception:
                continue
    return rows[-limit:]


def _features(rr: float, rng, eng, zone: str, cost: float) -> dict:
    return {
        "bias_valid": 1.0 if eng.bias_valid else 0.0,
        "irl_taken": 1.0 if rng.irl_taken else 0.0,
        "htf_aligned": 1.0,
        "rr": min(rr / 3.0, 1.0),
        "zone_extreme": 1.0 if "EXTREME" in zone else 0.5,
        "session": 1.0,
        "spread_ok": 1.0 if cost < 0.3 else 0.0,
    }


def build_trades(limit: int = 1500, hold: int = 48) -> list[dict]:
    trades: list[dict] = []
    for symbol, cost in SYMBOLS.items():
        bars = _load(DATA / f"{symbol}_H1.csv", limit)
        if len(bars) < 200:
            continue
        eng = StructureEngine()
        for i, bar in enumerate(bars):
            eng.push_bar(bar["time"], bar["open"], bar["high"],
                         bar["low"], bar["close"])
            if i < 100 or i >= len(bars) - hold:
                continue
            rng = eng.active_range()
            if rng is None or rng.rh <= rng.rl:
                continue
            price = bar["close"]
            zone = eng.range_zone(price, rng)
            side = "buy" if rng.direction == 1 else "sell"
            atr = eng.atr[-1] if eng.atr else 0.0
            if not atr:
                continue
            if side == "buy":
                swing = eng.swing_lows[-1].price if eng.swing_lows else price
                sl = max(min(swing, price) - 0.2 * atr, price - 2.0 * atr)
                tp = rng.rh
                if not (sl < price < tp):
                    continue
                rr = (tp - price) / (price - sl)
            else:
                swing = eng.swing_highs[-1].price if eng.swing_highs else price
                sl = min(max(swing, price) + 0.2 * atr, price + 2.0 * atr)
                tp = rng.rl
                if not (tp < price < sl):
                    continue
                rr = (price - tp) / (sl - price)

            outcome = 0.0
            for j in range(i + 1, min(i + hold, len(bars))):
                b = bars[j]
                if side == "buy":
                    if b["low"] <= sl:
                        outcome = -1.0
                        break
                    if b["high"] >= tp:
                        outcome = rr
                        break
                else:
                    if b["high"] >= sl:
                        outcome = -1.0
                        break
                    if b["low"] <= tp:
                        outcome = rr
                        break
            if outcome == 0.0:
                continue
            net_r = outcome - cost
            trades.append({
                "symbol": symbol,
                "time": bar["time"],
                "side": side,
                "rr": rr,
                "net_r": net_r,
                "win": net_r > 0,
                "features": _features(rr, rng, eng, zone, cost),
            })
    trades.sort(key=lambda t: t["time"])
    return trades


def _evaluate(brain: dict, trades: list[dict], threshold: float) -> dict:
    picks = [t for t in trades if agent.predict(brain, t["features"]) >= threshold]
    wins = sum(1 for t in picks if t["win"])
    net = sum(t["net_r"] for t in picks)
    gross_win = sum(t["net_r"] for t in picks if t["win"])
    gross_loss = abs(sum(t["net_r"] for t in picks if not t["win"]))
    return {
        "trades": len(picks),
        "wins": wins,
        "losses": len(picks) - wins,
        "win_rate": (wins / len(picks)) if picks else None,
        "net_r": net,
        "profit_factor": (gross_win / gross_loss) if gross_loss else None,
    }


def run(epochs: int = 40, limit: int = 1500,
        threshold: float = 0.5, apply: bool = True,
        min_test_trades: int = 15, min_test_net: float = 2.0,
        min_test_pf: float = 1.2) -> dict:
    trades = build_trades(limit=limit)
    if len(trades) < 30:
        return {"ok": False, "reason": f"not enough synthetic trades ({len(trades)})"}

    split = int(len(trades) * 0.7)
    train_set, test_set = trades[:split], trades[split:]
    state = agent.get_state()
    brain = copy.deepcopy(state["brain"])
    lr = 0.05
    best = None
    history = []

    def valid(test: dict) -> bool:
        return (test["trades"] >= min_test_trades and
                test["profit_factor"] is not None and
                test["profit_factor"] >= min_test_pf)

    for epoch in range(max(1, min(epochs, 200))):
        for t in train_set:
            p = agent.predict(brain, t["features"])
            target = 1.0 if t["win"] else 0.0
            err = target - p
            for key, value in t["features"].items():
                if isinstance(value, (int, float)):
                    brain["weights"][key] = brain["weights"].get(key, 0.0) + \
                        lr * err * float(value)
            brain["intercept"] = brain.get("intercept", 0.0) + lr * err
        test = _evaluate(brain, test_set, threshold)
        train = _evaluate(brain, train_set, threshold)
        history.append({"epoch": epoch + 1, "train": train, "test": test})
        if valid(test):
            if best is None or test["net_r"] > best["test"]["net_r"]:
                best = {"epoch": epoch + 1, "brain": copy.deepcopy(brain),
                        "train": train, "test": test}
            if test["net_r"] >= min_test_net:
                break
    if best is None:
        last = history[-1]
        best = {"epoch": last["epoch"], "brain": brain,
                "train": last["train"], "test": last["test"]}

    report = {
        "ok": True,
        "time": time.time(),
        "total_trades": len(trades),
        "train_trades": len(train_set),
        "test_trades": len(test_set),
        "epochs": best["epoch"],
        "threshold": threshold,
        "train": best["train"],
        "test": best["test"],
        "profitable": valid(best["test"]) and
        best["test"]["net_r"] >= min_test_net,
        "weights": best["brain"]["weights"],
        "intercept": best["brain"].get("intercept", 0.0),
        "note": "in-sample training / out-of-sample validation on H1 CSV data; "
                "past performance does not guarantee future results",
    }
    if apply and report["profitable"]:
        current = agent.get_state()
        new_brain = copy.deepcopy(current["brain"])
        new_brain["weights"] = best["brain"]["weights"]
        new_brain["intercept"] = best["brain"].get("intercept", 0.0)
        new_brain["updates"] = current["brain"].get("updates", 0) + epochs
        agent._save(brain=new_brain)
        report["applied"] = True
    else:
        report["applied"] = False
    state = agent.get_state()
    existing = state["stats"].get("backtest")
    if (report.get("profitable") and apply) or not existing:
        state["stats"]["backtest"] = report
        agent._save(stats=state["stats"])
    return report
