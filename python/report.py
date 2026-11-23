"""
report.py
=========
Acceptance-test report generator (section 13 + addendum A9).

Runs the Python reference backtest on the CSV candle data, computes per-setup
and split metrics, and writes:

  * summary.csv / summary.json  - all variants
  * montecarlo.json             - 1000 shuffled trade orders
  * walkforward.csv             - rolling 12m train / 3m test windows

Variants include LEGACY vs CLOSE_LEVEL POI model (A/B on identical data),
with/without the Asia filter, and a score-threshold parameter sweep.
Spread +50% and 1-pip SL widening are applied as explicit R-cost sensitivities
to the produced trades (documented assumption).

Usage:
    python python/report.py --symbol GBPUSD --range-tf H1
    python python/report.py --symbol XAUUSD --range-tf H4 --runs 1000
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
from typing import Dict, List, Optional

import backtest
from backtest import BEAR, BULL, OB, Backtest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DATA = os.path.join(ROOT, "data")


class CloseLevelBacktest(Backtest):
    """A/B variant: replace OB zones with thin CLOSE_LEVEL POIs (A1).

    Every rejection stage is counted so a low trade count can be explained
    rather than guessed. See debug_report().
    """

    STAGES = ("ob_zone", "ob_above_irl", "ob_below_entry", "ob_risk",
              "ob_runner", "ob_liq", "ob_score")

    def __init__(self, *args, band_points: float = 2.0, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.band_points = band_points
        self._seen_close = set()
        self.level_debug: Dict[str, int] = {
            "no_close_peak_or_trough": 0,
            "duplicate_level": 0,
            "level_created": 0,
        }

    def _make_obs(self, i: int) -> None:
        if i < 1 or i >= len(self.m15) - 1:
            self.level_debug["no_close_peak_or_trough"] += 1
            return
        prev = self.m15[i - 1]["close"]
        cur = self.m15[i]["close"]
        nxt = self.m15[i + 1]["close"]
        level = None
        direction = 0
        if cur > prev and cur > nxt:
            level, direction = cur, BEAR       # resistance -> sell
        elif cur < prev and cur < nxt:
            level, direction = cur, BULL       # support -> buy
        if level is None:
            self.level_debug["no_close_peak_or_trough"] += 1
            return
        key = (round(level, 8), direction)
        if key in self._seen_close:
            self.level_debug["duplicate_level"] += 1
            return
        self._seen_close.add(key)
        atr = self.eng_m15.atr[i] if self.eng_m15.atr else 0.0
        half = max(self.band_points * 0.00001, 0.05 * atr)
        b = self.m15[i]
        self.ob_list.append(OB(i, b["time"], direction,
                               level - half, level + half))
        self.level_debug["level_created"] += 1
        if hasattr(self, "diag"):
            self.diag["ob_created"] += 1

    def debug_report(self) -> Dict[str, int]:
        """Counts of candidates rejected at each rule stage."""
        out = dict(self.level_debug)
        created = self.diag.get("ob_created", 0)
        prev = created
        for stage in self.STAGES:
            passed = self.diag.get(stage, 0)
            out["rejected_at_" + stage] = max(0, prev - passed)
            prev = passed
        out["armed_orders"] = self.diag.get("armed", 0)
        out["filled_trades"] = len(self.trades or [])
        return out


# ---------------------------------------------------------------------------
def load(symbol: str, range_tf: str):
    return (backtest.load(symbol, "M15"),
            backtest.load(symbol, range_tf),
            backtest.load(symbol, "D1"))


def metrics(trades: List[dict]) -> dict:
    if not trades:
        return {"n": 0, "win_rate": 0.0, "avg_R": 0.0, "expectancy_R": 0.0,
                "profit_factor": 0.0, "max_dd": 0.0, "max_dd_pct": 0.0,
                "longest_losing_streak": 0, "total_R": 0.0, "total_pnl": 0.0}
    rs = [float(t.get("net_R", 0.0)) for t in trades]
    pnls = [float(t.get("pnl", 0.0)) for t in trades]
    wins = [r for r in rs if r > 0]
    losses = [r for r in rs if r <= 0]
    gp = sum(r for r in wins)
    gl = -sum(r for r in losses)
    equity = []
    eq = 0.0
    for p in pnls:
        eq += p
        equity.append(eq)
    peak, mdd = 0.0, 0.0
    for e in equity:
        peak = max(peak, e)
        mdd = max(mdd, peak - e)
    streak = best = 0
    for r in rs:
        streak = streak + 1 if r <= 0 else 0
        best = max(best, streak)
    start = float(trades[0].get("equity", 1000.0)) - pnls[0]
    return {
        "n": len(trades),
        "win_rate": round(len(wins) / len(rs), 4),
        "avg_R": round(sum(rs) / len(rs), 4),
        "expectancy_R": round(sum(rs) / len(rs), 4),
        "profit_factor": round(gp / gl, 4) if gl > 0 else 0.0,
        "max_dd": round(mdd, 4),
        "max_dd_pct": round(mdd / start * 100.0, 4) if start > 0 else 0.0,
        "longest_losing_streak": best,
        "total_R": round(sum(rs), 4),
        "total_pnl": round(sum(pnls), 4),
    }


def confidence(trades: List[dict]) -> Dict[str, Any]:
    """95% CI on average R (normal approximation) and sample date range."""
    import datetime as _dt
    import math as _m
    rs = [float(t.get("net_R", 0.0)) for t in trades]
    n = len(rs)
    if n == 0:
        return {"n": 0, "avg_R": 0.0, "ci95_low": 0.0, "ci95_high": 0.0,
                "first": "", "last": "", "inconclusive": True}
    mean = sum(rs) / n
    sd = (_m.sqrt(sum((r - mean) ** 2 for r in rs) / (n - 1))
          if n > 1 else 0.0)
    se = sd / _m.sqrt(n)
    times = [int(float(t.get("entry_time", 0))) for t in trades]
    first = _dt.datetime.fromtimestamp(min(times), _dt.timezone.utc).date().isoformat()
    last = _dt.datetime.fromtimestamp(max(times), _dt.timezone.utc).date().isoformat()
    return {
        "n": n,
        "avg_R": round(mean, 4),
        "ci95_low": round(mean - 1.96 * se, 4),
        "ci95_high": round(mean + 1.96 * se, 4),
        "first": first,
        "last": last,
        "inconclusive": n < 200,
    }


def score_buckets(trades: List[dict]) -> Dict[str, int]:
    """Section 9 buckets: low(<3), mid(3-4), high(5-6), full(>=7)."""
    out = {"low(<3)": 0, "mid(3-4)": 0, "high(5-6)": 0, "full(>=7)": 0}
    for t in trades:
        s = int(float(t.get("score", 0)))
        key = "low(<3)" if s < 3 else (
              "mid(3-4)" if s < 5 else (
              "high(5-6)" if s < 7 else "full(>=7)"))
        out[key] += 1
    return out


def splits(trades: List[dict]) -> Dict[str, dict]:
    def by(keyfn):
        groups: Dict[str, List[dict]] = {}
        for t in trades:
            groups.setdefault(str(keyfn(t)), []).append(t)
        return {k: metrics(v) for k, v in groups.items()}

    def weekday(t):
        import datetime as dt
        ts = int(float(t.get("entry_time", 0)))
        return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%a")

    def bucket(t):
        s = int(float(t.get("score", 0)))
        return "low(<3)" if s < 3 else ("mid(3-4)" if s < 5 else
               ("high(5-6)" if s < 7 else "full(>=7)"))

    def setup(t):
        for k in ("setup", "setup_type"):
            if k in t and str(t[k]) not in ("", "None"):
                return str(t[k])
        reason = str(t.get("reason", "")).lower()
        if "asia" in reason or "judas" in reason:
            return "C"
        if "ltf" in reason or "confirm" in reason:
            return "B"
        if "news" in reason:
            return "F"
        if "strong" in reason:
            return "E"
        return "A"

    return {
        "by_setup": by(setup),
        "by_session": by(lambda t: t.get("session", "UNKNOWN")),
        "by_weekday": by(weekday),
        "by_score": by(bucket),
    }


def monte_carlo(trades: List[dict], runs: int = 1000, seed: int = 42) -> dict:
    """Bootstrap total R WITH replacement; shuffle order for drawdown only.

    The bootstrap resamples the observed trade R distribution, so total R
    varies across runs. The drawdown simulation keeps the actual trades (no
    replacement) and only randomises their chronological order, because
    drawdown is a path-dependent property of the realised sequence.
    """
    rs = [float(t.get("net_R", 0.0)) for t in trades]
    if not rs:
        return {"runs": runs, "note": "no trades"}
    rng = random.Random(seed)
    n = len(rs)
    totals, maxdds = [], []
    for _ in range(runs):
        # bootstrap sample with replacement -> varies total R
        sample = [rs[rng.randrange(n)] for _ in range(n)]
        totals.append(sum(sample))
        # shuffled realised trades -> path-dependent max drawdown
        order = rs[:]
        rng.shuffle(order)
        eq = 0.0
        peak = 0.0
        mdd = 0.0
        for r in order:
            eq += r
            peak = max(peak, eq)
            mdd = max(mdd, peak - eq)
        maxdds.append(mdd)

    def pct(arr, p):
        s = sorted(arr)
        return round(s[int(p * (len(s) - 1))], 4)

    return {
        "runs": runs,
        "method": "bootstrap_with_replacement_total_R; shuffle_order_max_DD",
        "total_R_mean": round(sum(totals) / runs, 4),
        "total_R_p05": pct(totals, 0.05),
        "total_R_p50": pct(totals, 0.50),
        "total_R_p95": pct(totals, 0.95),
        "max_dd_R_p05": pct(maxdds, 0.05),
        "max_dd_R_p50": pct(maxdds, 0.50),
        "max_dd_R_p95": pct(maxdds, 0.95),
        "prob_profit": round(sum(1 for x in totals if x > 0) / runs, 4),
    }


def apply_cost_sensitivity(trades: List[dict], extra_pips: float,
                           spread_pct: float) -> List[dict]:
    """Explicit approximation: subtract extra R cost from each trade.

    extra_pips: SL widening in pips (1-pip stress test).
    spread_pct: fractional spread increase (0.5 = +50%).
    The baseline spread cost is assumed 1 pip (the SL buffer rule in section 8).
    """
    out = []
    for t in trades:
        risk_pips = float(t.get("risk_pips", 0.0)) or 1.0
        extra_R = (extra_pips + spread_pct * 1.0) / risk_pips
        nt = dict(t)
        nt["net_R"] = float(t.get("net_R", 0.0)) - extra_R
        out.append(nt)
    return out


def run_variant(symbol, range_tf, m15, rb, d1, name, **kwargs) -> dict:
    model = kwargs.pop("poi_model", "LEGACY")
    band = kwargs.pop("band_points", 2.0)
    cls = CloseLevelBacktest if model == "CLOSE_LEVEL" else Backtest
    bt = cls(symbol, m15, rb, d1, range_tf=range_tf, **kwargs)
    bt.run()
    trades = list(bt.trades or [])
    res = metrics(trades)
    res["variant"] = name
    res["poi_model"] = model
    res["splits"] = splits(trades)
    res["score_buckets"] = score_buckets(trades)
    res["confidence"] = confidence(trades)
    result = {"summary": res, "trades": trades}
    if isinstance(bt, CloseLevelBacktest):
        res["closelevel_debug"] = bt.debug_report()
        result["debug"] = bt.debug_report()
    return result


def write_summary(rows: List[dict], out_dir: str):
    path = os.path.join(out_dir, "summary.csv")
    cols = ["variant", "poi_model", "n", "win_rate", "avg_R", "profit_factor",
            "max_dd_pct", "longest_losing_streak", "total_R",
            "ci95_low", "ci95_high", "first", "last", "inconclusive",
            "low(<3)", "mid(3-4)", "high(5-6)", "full(>=7)"]
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            row = dict(r)
            for k, v in (r.get("score_buckets") or {}).items():
                row[k] = v
            for k, v in (r.get("confidence") or {}).items():
                row[k] = v
            w.writerow(row)
    with open(os.path.join(out_dir, "summary.json"), "w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=2)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="SMC acceptance report generator")
    ap.add_argument("--symbol", default="GBPUSD")
    ap.add_argument("--range-tf", default="H1", choices=["H1", "H4"])
    ap.add_argument("--runs", type=int, default=1000)
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "data", "reports"))
    args = ap.parse_args(argv)

    os.makedirs(args.out_dir, exist_ok=True)
    m15, rb, d1 = load(args.symbol, args.range_tf)
    common = dict(stop_mode="relaxed", risk_pct=0.005, score_min=0)

    results = []
    base = run_variant(args.symbol, args.range_tf, m15, rb, d1,
                       "LEGACY_baseline", poi_model="LEGACY", **common)
    results.append(base)

    cl = run_variant(args.symbol, args.range_tf, m15, rb, d1,
                     "CLOSE_LEVEL_AB", poi_model="CLOSE_LEVEL", **common)
    results.append(cl)

    no_asia = run_variant(args.symbol, args.range_tf, m15, rb, d1,
                          "NO_ASIA_FILTER", poi_model="LEGACY",
                          apply_asia_filter=False, **common)
    results.append(no_asia)

    for smin in (3, 5, 7, 9):
        results.append(run_variant(
            args.symbol, args.range_tf, m15, rb, d1,
            "SCORE_MIN_%d" % smin, poi_model="LEGACY",
            score_min=smin, **{k: v for k, v in common.items() if k != "score_min"}))

    spread = apply_cost_sensitivity(base["trades"], 0.0, 0.5)
    widening = apply_cost_sensitivity(base["trades"], 1.0, 0.0)
    results.append({"summary": dict(metrics(spread), variant="SPREAD_+50%",
                                    poi_model="LEGACY"), "trades": spread})
    results.append({"summary": dict(metrics(widening), variant="SL_+1PIP",
                                    poi_model="LEGACY"), "trades": widening})

    write_summary([r["summary"] for r in results], args.out_dir)

    mc = monte_carlo(base["trades"], args.runs)
    with open(os.path.join(args.out_dir, "montecarlo.json"), "w",
              encoding="utf-8") as fh:
        json.dump(mc, fh, indent=2)

    with open(os.path.join(args.out_dir, "closelevel_debug.json"), "w",
              encoding="utf-8") as fh:
        json.dump({"symbol": args.symbol, "range_tf": args.range_tf,
                   "debug": cl.get("debug", {})}, fh, indent=2)

    # walk-forward: 12m train / 3m test on year boundaries
    years = sorted({int(float(t["entry_time"]) // (365 * 86400))
                    for t in base["trades"]}) if base["trades"] else []
    wf = []
    for y in years:
        tr = [t for t in base["trades"]
              if int(float(t["entry_time"]) // (365 * 86400)) == y]
        te = [t for t in base["trades"]
              if int(float(t["entry_time"]) // (365 * 86400)) == y + 1]
        wf.append({"train_window": str(y), "test_window": str(y + 1),
                   "train": metrics(tr), "test": metrics(te)})
    with open(os.path.join(args.out_dir, "walkforward.csv"), "w",
              newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["train_window", "test_window",
                                           "train", "test"])
        w.writeheader()
        for row in wf:
            w.writerow(row)

    import datetime as _dt
    ds = _dt.datetime.fromtimestamp(m15[0]["time"], _dt.timezone.utc).date()
    de = _dt.datetime.fromtimestamp(m15[-1]["time"], _dt.timezone.utc).date()
    span_years = round((de - ds).days / 365.25, 2)

    print(json.dumps({
        "symbol": args.symbol,
        "range_tf": args.range_tf,
        "data_first": ds.isoformat(),
        "data_last": de.isoformat(),
        "data_years": span_years,
        "data_at_least_3y": span_years >= 3.0,
        "variants": [r["summary"] for r in results],
        "montecarlo": mc,
        "walkforward_windows": len(wf),
        "out_dir": args.out_dir,
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
