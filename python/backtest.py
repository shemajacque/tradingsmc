"""
backtest.py
===========
First reference backtest of the SMC rule set on real M15 history exported
from the demo terminal (``SMC_ExportData.mq5``).

Scope of this v0 (explicit, not hidden)
---------------------------------------
* Setup A only: HTF confirmed range -> IRL sweep -> M15 order block in
  premium/discount -> limit at the OB 50% -> SL beyond the OB -> 40% off
  at 1.5R, BE, runner to the ERL (range extreme offset), 15R cap.
* Timeframes: M15 entries, H1 range/bias, D1 bias.  No H4 (D1 takes over).
* No M5 refinement, no FVG/breaker POIs, no Setup B/C, no news filter,
  no LTF strong points, no HTF-POI overlap requirement, no score filter.
  These are Phase 2/3 items; the numbers below are a first edge check.
* Stops: ``relaxed`` = 0.15..0.5 * ATR(M15); ``spec`` = GBPUSD 2..5 pips,
  XAUUSD 0.15..0.5 * ATR.  The strict MQL5 rule needs M5 refinement to pass
  often on GBPUSD, which this v0 does not do.
* Conservative fills: a limit fills on the next bar; SL is checked before
  TP on every bar; after TP1 the BE stop is checked before the runner.
* Costs: one spread per trade (default GBPUSD 1.0 pip, XAUUSD 0.30).
* Asia box filter and PDH/PDL are fed to the structure engine at NY midnight.

Server time of the export is GMT (export_meta.txt), so the TimeEngine is
built with 0/0 offsets and US DST.
"""

from __future__ import annotations

import argparse
import calendar
import csv
import datetime as dt
import json
import os
import sys
from collections import defaultdict
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from smc_engine import BEAR, BULL, NEUTRAL, StructureEngine, load_csv  # noqa: E402
from smc_time import TimeEngine  # noqa: E402

CONF = {
    "GBPUSD": {"pip": 0.0001, "spread": 0.00010, "digits": 5},
    "XAUUSD": {"pip": 0.1, "spread": 0.30, "digits": 2},
}


def utc_dt(ts: int) -> dt.datetime:
    return dt.datetime.fromtimestamp(ts, dt.UTC).replace(tzinfo=None)


def to_server_ts(naive: dt.datetime) -> int:
    return int(calendar.timegm(naive.timetuple()))


def day_key(ny: dt.datetime) -> dt.date:
    return ny.date()


def pct(x: float) -> str:
    return f"{x * 100:.1f}%"


# ---------------------------------------------------------------------------
class OB:
    __slots__ = ("idx", "time", "dir", "lo", "hi", "entry", "mitigated",
                 "used")

    def __init__(self, idx: int, t: int, direction: int, lo: float, hi: float):
        self.idx = idx
        self.time = t
        self.dir = direction
        self.lo = lo
        self.hi = hi
        self.entry = (lo + hi) / 2.0
        self.mitigated = False
        self.used = False


class Trade:
    __slots__ = ("dir", "entry", "sl", "tp1", "runner", "risk", "fill_idx",
                 "fill_time", "tp1_hit", "session", "score", "ob_idx",
                 "entry_ny", "filled", "expiry", "risk_r")

    def __init__(self):
        self.filled = False
        self.tp1_hit = False


class Backtest:
    def __init__(self, symbol: str, m15: List[dict], range_bars: List[dict],
                 d1: List[dict], range_tf: str = "H1", stop_mode: str = "relaxed",
                 risk_pct: float = 0.005, start_equity: float = 1000.0,
                 max_trades_day: int = 3, daily_stop_pct: float = 0.03,
                 weekly_stop_pct: float = 0.06, max_consec_losses: int = 3,
                 allow_asia: bool = False, apply_asia_filter: bool = True,
                 score_min: int = 0, verbose: bool = False) -> None:
        self.symbol = symbol
        self.m15 = m15
        self.range_tf = range_tf
        self.range_bars = range_bars
        self.range_secs = 3600 if range_tf == "H1" else 14400
        self.d1 = d1
        self.stop_mode = stop_mode
        self.risk_pct = risk_pct
        self.start_equity = start_equity
        self.max_trades_day = max_trades_day
        self.daily_stop_pct = daily_stop_pct
        self.weekly_stop_pct = weekly_stop_pct
        self.max_consec_losses = max_consec_losses
        self.allow_asia = allow_asia
        self.apply_asia_filter = apply_asia_filter
        self.score_min = score_min
        self.verbose = verbose

        c = CONF[symbol]
        self.pip = c["pip"]
        self.spread = c["spread"]
        self.digits = c["digits"]

        self.te = TimeEngine(0.0, 0.0, "US")

        self.eng_m15 = StructureEngine(swing_len=1, bos_by_close=True,
                                       equal_tol_atr=0.1)
        self.eng_range = StructureEngine(swing_len=1, bos_by_close=True,
                                         equal_tol_atr=0.1)
        self.eng_d1 = StructureEngine(swing_len=1, bos_by_close=True,
                                      equal_tol_atr=0.1)

        self.diag = defaultdict(int)
        self.ob_list: List[OB] = []
        self.pending: Optional[Trade] = None
        self.open: Optional[Trade] = None
        self.trades: List[dict] = []
        self.equity = start_equity
        self.peak = start_equity
        self.max_dd = 0.0

        self.day = None
        self.day_equity0 = start_equity
        self.day_pnl = 0.0
        self.day_trades = 0
        self.day_losses = 0
        self.day_stopped = False
        self.week = None
        self.week_equity0 = start_equity
        self.week_pnl = 0.0
        self.week_stopped = False
        self.skip_day = False
        self.consec_losses = 0

        self.asia: Dict[dt.date, dict] = {}
        self.days: Dict[dt.date, dict] = {}
        self.ny_cache: List[dt.datetime] = []
        self._precompute_days()

    # ------------------------------------------------------------------
    def _precompute_days(self) -> None:
        cache: List[dt.datetime] = []
        for b in self.m15:
            ny = self.te.server_to_ny(utc_dt(b["time"]))
            cache.append(ny)
            d = ny.date()
            agg = self.days.get(d)
            if agg is None:
                self.days[d] = {"high": b["high"], "low": b["low"],
                                "open": b["open"], "close": b["close"],
                                "count": 1}
            else:
                agg["high"] = max(agg["high"], b["high"])
                agg["low"] = min(agg["low"], b["low"])
                agg["close"] = b["close"]
                agg["count"] += 1
            if ny.hour >= 17:
                nd = d + dt.timedelta(days=1)
                ab = self.asia.get(nd)
                if ab is None:
                    self.asia[nd] = {"high": b["high"], "low": b["low"],
                                     "open": b["open"], "close": b["close"],
                                     "count": 1}
                else:
                    ab["high"] = max(ab["high"], b["high"])
                    ab["low"] = min(ab["low"], b["low"])
                    ab["close"] = b["close"]
                    ab["count"] += 1
        self.ny_cache = cache

    def _prev_day(self, d: dt.date) -> Optional[dict]:
        for k in range(1, 8):
            dd = d - dt.timedelta(days=k)
            if dd in self.days:
                return self.days[dd]
        return None

    # ------------------------------------------------------------------
    def _risk_bounds(self, atr: float) -> tuple:
        if self.stop_mode == "spec" and self.symbol == "GBPUSD":
            return 0.0002, 0.0005
        return 0.15 * atr, 0.5 * atr

    def _make_obs(self, i: int) -> None:
        eng = self.eng_m15
        b = self.m15[i]
        before = getattr(self, "_bos_count", 0)
        new = eng.bos_events[before:]
        self._bos_count = len(eng.bos_events)
        if not new:
            return
        atr = eng.atr[i] if eng.atr else 0.0
        for ev in new:
            if ev.idx != i or atr <= 0:
                continue
            if ev.direction == BEAR:
                j = None
                for k in range(i - 1, max(-1, i - 5), -1):
                    bk = self.m15[k]
                    if bk["close"] > bk["open"]:
                        j = k
                        break
                if j is None:
                    continue
                c = self.m15[j]
                lo, hi = min(c["open"], c["close"]), max(c["open"], c["close"])
                if hi - lo < 0.10 * atr:
                    continue
                if c["high"] - b["close"] < 0.80 * atr:
                    continue
                self.ob_list.append(OB(i, b["time"], BEAR, lo, hi)); self.diag["ob_created"] += 1
            else:
                j = None
                for k in range(i - 1, max(-1, i - 5), -1):
                    bk = self.m15[k]
                    if bk["close"] < bk["open"]:
                        j = k
                        break
                if j is None:
                    continue
                c = self.m15[j]
                lo, hi = min(c["open"], c["close"]), max(c["open"], c["close"])
                if hi - lo < 0.10 * atr:
                    continue
                if b["close"] - c["low"] < 0.80 * atr:
                    continue
                self.ob_list.append(OB(i, b["time"], BULL, lo, hi)); self.diag["ob_created"] += 1

    def _refresh_obs(self, i: int) -> None:
        b = self.m15[i]
        keep: List[OB] = []
        for ob in self.ob_list:
            if i - ob.idx > 160:
                continue
            if ob.mitigated:
                continue
            if i > ob.idx:
                if ob.dir == BEAR and b["high"] >= ob.entry:
                    ob.mitigated = True
                    continue
                if ob.dir == BULL and b["low"] <= ob.entry:
                    ob.mitigated = True
                    continue
            keep.append(ob)
        self.ob_list = keep

    def _score(self, ob: OB, h1r, session: str, atr: float,
               i: int, ny: dt.datetime) -> int:
        """Section 9 ten-item probability score (binary items).

        The Python reference has no POI engine, so HTF-POI overlap (item 4)
        uses the nearest D1 range extreme or D1 swing within 0.5*ATR(D1);
        FVG/Asia-mid confluence (item 5) uses the Asia midline only. These
        approximations are documented here and in the README.
        """
        s = 0
        ratio = h1r.ratio(ob.entry)

        # 1. correct side of EQ (premium for sells, discount for buys)
        if (ob.dir == BEAR and ratio >= 0.5) or \
           (ob.dir == BULL and ratio <= 0.5):
            s += 1

        # 2. extreme premium/discount
        if ratio >= 0.79 or ratio <= 0.21:
            s += 1

        # 3. liquidity beyond the POI
        if self._liq_beyond(ob, atr):
            s += 1

        # 4. HTF POI overlap (approximated by D1 extreme / D1 swing)
        d1atr = self.eng_d1.atr[-1] if self.eng_d1.atr else 0.0
        tol = 0.5 * d1atr if d1atr > 0 else 0.0
        htf = False
        d1r = self.eng_d1.last_range
        if d1r is not None:
            lvl = d1r.rh if ob.dir == BEAR else d1r.rl
            if abs(ob.entry - lvl) <= tol:
                htf = True
        if not htf:
            pool = (self.eng_d1.swing_highs if ob.dir == BEAR
                    else self.eng_d1.swing_lows)
            htf = any(abs(p.price - ob.entry) <= tol for p in pool[-20:])
        if htf:
            s += 1

        # 5. FVG / mitigation / Asia midline confluence (Asia midline here)
        ab = self.asia.get(ny.date())
        if ab and abs(ob.entry - (ab["high"] + ab["low"]) / 2.0) <= 0.1 * atr:
            s += 1

        # 6. sweep of the Asia extreme inside a kill zone
        if ab and session in ("LONDON", "NEW_YORK"):
            if ob.dir == BEAR and ab["high"] and ob.hi > ab["high"]:
                s += 1
            elif ob.dir == BULL and ab["low"] and ob.lo < ab["low"]:
                s += 1

        # 7. fast displacement: last three M15 bars >= 1.5 * ATR
        if i >= 3:
            span = sum(self.m15[k]["high"] - self.m15[k]["low"]
                       for k in range(i - 2, i + 1))
            if atr > 0 and span >= 1.5 * atr:
                s += 1

        # 8. bias aligned on D1 and range TF (H4 when range_tf == H4)
        if self.eng_d1.bias == ob.dir:
            s += 1
        if self.eng_range.bias == ob.dir:
            s += 1

        # 9. IRL already taken
        if h1r.irl_taken:
            s += 1

        # 10. fake move at session open (first 15m candle opposite to trade)
        start_hour = 2 if session == "LONDON" else 7
        if session in ("LONDON", "NEW_YORK"):
            start_server = to_server_ts(
                self.te.ny_to_server(dt.datetime.combine(
                    ny.date(), dt.time(start_hour, 0))))
            first = next((b for b in self.m15 if b["time"] >= start_server), None)
            if first is not None:
                if ob.dir == BEAR and first["close"] > first["open"]:
                    s += 1
                if ob.dir == BULL and first["close"] < first["open"]:
                    s += 1
        return s

    def _liq_beyond(self, ob: OB, atr: float) -> bool:
        eng = self.eng_m15
        tol = 0.1 * atr
        if ob.dir == BEAR:
            if eng.count_equal_levels(True, ob.hi, tol, True) >= 1:
                return True
            if eng.ext_asia_high is not None and eng.ext_asia_high > ob.hi:
                return True
            if eng.ext_pdh is not None and eng.ext_pdh > ob.hi:
                return True
        else:
            if eng.count_equal_levels(False, ob.lo, tol, True) >= 1:
                return True
            if eng.ext_asia_low is not None and eng.ext_asia_low < ob.lo:
                return True
            if eng.ext_pdl is not None and eng.ext_pdl < ob.lo:
                return True
        return False

    def _try_signal(self, i: int, ny: dt.datetime, session: str,
                    h1r, atr: float) -> None:
        b = self.m15[i]
        close = b["close"]
        min_lo, max_risk = self._risk_bounds(atr)

        d = self.diag
        best: Optional[tuple] = None
        for ob in self.ob_list:
            d["ob_seen"] += 1
            if ob.used or ob.mitigated:
                continue
            if ob.dir != h1r.direction:
                continue
            d["ob_dir"] += 1
            d["ob_after_confirm"] += 1
            if ob.dir == BEAR:
                if not (h1r.rl < ob.lo and ob.hi < h1r.rh):
                    continue
                d["ob_zone"] += 1
                if not (ob.entry > h1r.eq and ob.entry > h1r.irl_price):
                    continue
                d["ob_above_irl"] += 1
                if not (close < ob.entry):
                    continue
                d["ob_below_entry"] += 1
                sl = ob.hi + max(1.5 * self.spread, 0.05 * atr)
                if sl >= h1r.rh:
                    continue
                risk = sl - ob.entry
                if risk < min_lo or risk > max_risk:
                    continue
                d["ob_risk"] += 1
                tp1 = ob.entry - 1.5 * risk
                runner = h1r.rl + 0.1 * atr
                runner_r = (ob.entry - runner) / risk
                if runner_r < 1.5:
                    continue
                d["ob_runner"] += 1
                runner_r = min(runner_r, 15.0)
            else:
                if not (h1r.rl < ob.lo and ob.hi < h1r.rh):
                    continue
                d["ob_zone"] += 1
                if not (ob.entry < h1r.eq and ob.entry < h1r.irl_price):
                    continue
                d["ob_above_irl"] += 1
                if not (close > ob.entry):
                    continue
                d["ob_below_entry"] += 1
                sl = ob.lo - max(1.5 * self.spread, 0.05 * atr)
                if sl <= h1r.rl:
                    continue
                risk = ob.entry - sl
                if risk < min_lo or risk > max_risk:
                    continue
                d["ob_risk"] += 1
                tp1 = ob.entry + 1.5 * risk
                runner = h1r.rh - 0.1 * atr
                runner_r = (runner - ob.entry) / risk
                if runner_r < 1.5:
                    continue
                d["ob_runner"] += 1
                runner_r = min(runner_r, 15.0)

            if ob.dir == BEAR and not self._liq_beyond(ob, atr):
                continue
            if ob.dir == BULL and not self._liq_beyond(ob, atr):
                continue
            d["ob_liq"] += 1
            score = self._score(ob, h1r, session, atr, i, ny)
            if score < self.score_min:
                continue
            d["ob_score"] += 1
            dist = abs(ob.entry - close)
            if best is None or dist < best[0]:
                best = (dist, ob, sl, tp1, runner, runner_r, risk, score)

        if best is None:
            return

        _, ob, sl, tp1, runner, runner_r, risk, score = best
        t = Trade()
        t.dir = ob.dir
        t.entry = ob.entry
        t.sl = sl
        t.tp1 = tp1
        t.runner = runner
        t.risk = risk
        t.tp1_hit = False
        t.session = session
        t.score = score
        t.ob_idx = ob.idx
        t.entry_ny = ny
        t.risk_r = runner_r
        ob.used = True

        exp_ny = dt.datetime.combine(ny.date(), dt.time(12, 0))
        t.expiry = to_server_ts(self.te.ny_to_server(exp_ny))
        self.pending = t
        self.diag["armed"] += 1

    # ------------------------------------------------------------------
    def _close_trade(self, t: Trade, exit_price: float, exit_time: int,
                     reason: str) -> None:
        gross = (t.entry - exit_price) / t.risk if t.dir == BEAR else \
                (exit_price - t.entry) / t.risk
        if t.tp1_hit:
            gross = 0.6 + 0.6 * gross
        net = gross - self.spread / t.risk
        risk_usd = self.equity * self.risk_pct
        pnl = net * risk_usd
        self.equity += pnl
        self.peak = max(self.peak, self.equity)
        dd = (self.peak - self.equity) / self.peak if self.peak > 0 else 0.0
        self.max_dd = max(self.max_dd, dd)
        self.day_pnl += pnl
        self.week_pnl += pnl
        self.day_trades += 1
        if net < 0:
            self.consec_losses += 1
        else:
            self.consec_losses = 0
        self.trades.append({
            "symbol": self.symbol, "dir": t.dir, "session": t.session,
            "score": t.score, "entry_time": t.fill_time, "entry": t.entry,
            "sl": t.sl, "tp1": t.tp1, "runner": t.runner,
            "risk_pips": t.risk / self.pip, "exit_time": exit_time,
            "exit": exit_price, "reason": reason, "gross_R": gross,
            "net_R": net, "pnl": pnl, "equity": self.equity,
            "tp1_hit": t.tp1_hit, "runner_R": getattr(t, "risk_r", 0.0),
        })
        self.open = None

    def _manage(self, i: int) -> None:
        t = self.open
        b = self.m15[i]
        ny = self.ny_cache[i]
        mins = ny.hour * 60 + ny.minute
        if ny.weekday() == 4 and mins >= 16 * 60:
            self._close_trade(t, b["open"], b["time"], "friday_close")
            return
        if not t.tp1_hit:
            sl_hit = (b["high"] >= t.sl) if t.dir == BEAR else (b["low"] <= t.sl)
            if sl_hit:
                self._close_trade(t, t.sl, b["time"], "sl")
                return
            tp_hit = (b["low"] <= t.tp1) if t.dir == BEAR else (b["high"] >= t.tp1)
            if tp_hit:
                t.tp1_hit = True
                if t.dir == BEAR:
                    if i > t.fill_idx and b["low"] <= t.runner:
                        self._close_trade(t, t.runner, b["time"], "runner")
                        return
                else:
                    if i > t.fill_idx and b["high"] >= t.runner:
                        self._close_trade(t, t.runner, b["time"], "runner")
                        return
                return
            if mins >= 12 * 60:
                self._close_trade(t, b["open"], b["time"], "time_1200")
                return
        else:
            be_hit = (b["high"] >= t.entry) if t.dir == BEAR else \
                     (b["low"] <= t.entry)
            if be_hit:
                self._close_trade(t, t.entry, b["time"], "be")
                return
            r_hit = (b["low"] <= t.runner) if t.dir == BEAR else \
                    (b["high"] >= t.runner)
            if r_hit:
                self._close_trade(t, t.runner, b["time"], "runner")
                return
            if ny.weekday() == 4 and mins >= 16 * 60:
                self._close_trade(t, b["open"], b["time"], "friday_close")
                return
            if i - t.fill_idx > 192:
                self._close_trade(t, b["open"], b["time"], "max_hold")
                return

    def _pending_step(self, i: int) -> None:
        t = self.pending
        b = self.m15[i]
        if b["time"] > getattr(t, "expiry", b["time"]):
            self.pending = None
            return
        r = self.eng_range.last_range
        if r is not None and r.broken:
            self.pending = None
            return
        filled = False
        if t.dir == BEAR:
            if b["open"] >= t.entry:
                fill = b["open"]
                filled = True
            elif b["high"] >= t.entry:
                fill = t.entry
                filled = True
        else:
            if b["open"] <= t.entry:
                fill = b["open"]
                filled = True
            elif b["low"] <= t.entry:
                fill = t.entry
                filled = True
        if not filled:
            return
        t.filled = True
        t.fill_idx = i
        t.fill_time = b["time"]
        self.pending = None
        self.open = t
        self.diag["filled"] += 1
        self._manage(i)

    # ------------------------------------------------------------------
    def run(self) -> dict:
        h1_ptr = 0
        d1_ptr = 0
        cur_day = None
        self._bos_count = 0


        for i, b in enumerate(self.m15):
            t = b["time"]
            ny = self.ny_cache[i]
            d = ny.date()
            mins = ny.hour * 60 + ny.minute

            while h1_ptr < len(self.range_bars) and \
                    self.range_bars[h1_ptr]["time"] + self.range_secs <= t + 900:
                c = self.range_bars[h1_ptr]
                self.eng_range.push_bar(c["time"], c["open"], c["high"],
                                        c["low"], c["close"])
                h1_ptr += 1
            while d1_ptr < len(self.d1) and self.d1[d1_ptr]["time"] + 86400 <= t + 900:
                c = self.d1[d1_ptr]
                self.eng_d1.push_bar(c["time"], c["open"], c["high"],
                                     c["low"], c["close"])
                d1_ptr += 1

            if cur_day != d:
                if cur_day is not None:
                    self.day_equity0 = self.equity
                    self.day_pnl = 0.0
                    self.day_trades = 0
                    self.day_losses = 0
                    self.day_stopped = False
                    self.consec_losses = 0
                if d.weekday() == 0 or self.week is None:
                    self.week = d.isocalendar()[:2]
                    self.week_equity0 = self.equity
                    self.week_pnl = 0.0
                    self.week_stopped = False
                cur_day = d
                self.day = d
                prev = self._prev_day(d)
                ab = self.asia.get(d)
                self.skip_day = False
                if self.apply_asia_filter and ab and ab["count"] >= 20:
                    rng = ab["high"] - ab["low"]
                    eff = abs(ab["close"] - ab["open"]) / rng if rng > 0 else 0.0
                    h1_atr = self.eng_range.atr[-1] if self.eng_range.atr else 0.0
                    if (h1_atr > 0 and rng > 0.8 * h1_atr) or eff > 0.6:
                        self.skip_day = True
                if ab:
                    self.eng_m15.set_external_liquidity(
                        ab["high"], ab["low"],
                        prev["high"] if prev else None,
                        prev["low"] if prev else None)
                    self.eng_range.set_external_liquidity(
                        ab["high"], ab["low"],
                        prev["high"] if prev else None,
                        prev["low"] if prev else None)

            self.eng_m15.push_bar(t, b["open"], b["high"], b["low"], b["close"])
            self._make_obs(i)
            self._refresh_obs(i)
            atr = self.eng_m15.atr[i] if self.eng_m15.atr else 0.0

            if self.open is not None:
                self._manage(i)
                continue
            if self.pending is not None:
                self._pending_step(i)
                continue

            dg = self.diag
            session = self.te.in_kill_zone(ny, 30)
            if session is None or self.skip_day:
                continue
            dg["kz_bars"] += 1
            if ny.weekday() == 4 and mins >= 12 * 60:
                continue
            if self.day_stopped or self.week_stopped:
                continue
            if self.day_trades >= self.max_trades_day:
                continue
            if self.day_pnl <= -self.daily_stop_pct * self.day_equity0:
                self.day_stopped = True
                continue
            if self.week_pnl <= -self.weekly_stop_pct * self.week_equity0:
                self.week_stopped = True
                continue
            if self.consec_losses >= self.max_consec_losses:
                self.day_stopped = True
                continue
            if atr <= 0 or not self.eng_range.ranges:
                continue
            dg["has_range"] += 1

            h1r = self.eng_range.last_range
            if h1r is None or h1r.broken or h1r.strong_idx < 0:
                continue
            dg["range_valid"] += 1
            d1r = self.eng_d1.last_range
            if d1r is not None and not d1r.broken and d1r.direction != h1r.direction:
                continue
            dg["bias_ok"] += 1
            ratio = h1r.ratio(b["close"])
            if not (0.0 < ratio < 1.0):
                continue
            dg["in_range"] += 1
            if h1r.direction == BEAR and not (ratio >= 0.5 and h1r.irl_taken):
                continue
            if h1r.direction == BULL and not (ratio <= 0.5 and h1r.irl_taken):
                continue
            dg["prem_irl"] += 1

            self._try_signal(i, ny, session, h1r, atr)

        if self.open is not None:
            b = self.m15[-1]
            self._close_trade(self.open, b["close"], b["time"], "end")

        return self.stats()

    # ------------------------------------------------------------------
    def stats(self) -> dict:
        n = len(self.trades)
        wins = [t for t in self.trades if t["net_R"] > 0]
        losses = [t for t in self.trades if t["net_R"] <= 0]
        gp = sum(t["net_R"] for t in wins)
        gl = -sum(t["net_R"] for t in losses)
        total_r = sum(t["net_R"] for t in self.trades)
        by = defaultdict(list)
        for t in self.trades:
            by[t["session"]].append(t)
            by[f"score{t['score']}"].append(t)
            by[f"dir{t['dir']}"].append(t)
        years = defaultdict(list)
        for t in self.trades:
            years[dt.datetime.fromtimestamp(t["entry_time"], dt.UTC).year].append(t)

        def wr(ts):
            if not ts:
                return None
            return sum(1 for x in ts if x["net_R"] > 0) / len(ts)

        return {
            "symbol": self.symbol, "stop_mode": self.stop_mode,
            "trades": n, "wins": len(wins), "losses": len(losses),
            "win_rate": wr(self.trades),
            "tp1_rate": (sum(1 for t in self.trades if t["tp1_hit"]) / n) if n else None,
            "avg_R": (total_r / n) if n else 0.0,
            "total_R": total_r, "gross_profit_R": gp, "gross_loss_R": gl,
            "profit_factor": (gp / gl) if gl > 0 else None,
            "expectancy_R": (total_r / n) if n else 0.0,
            "max_dd_pct": self.max_dd * 100.0,
            "end_equity": self.equity,
            "return_pct": (self.equity / self.start_equity - 1.0) * 100.0,
            "by_session": {k: {"n": len(v), "wr": wr(v),
                               "avg_R": sum(x["net_R"] for x in v) / len(v)}
                           for k, v in by.items() if k in ("LONDON", "NEW_YORK")},
            "by_score": {k: {"n": len(v), "wr": wr(v),
                             "avg_R": sum(x["net_R"] for x in v) / len(v)}
                         for k, v in by.items() if k.startswith("score")},
            "by_year": {str(k): {"n": len(v), "wr": wr(v),
                                 "avg_R": sum(x["net_R"] for x in v) / len(v)}
                        for k, v in sorted(years.items())},
            "first": dt.datetime.fromtimestamp(self.trades[0]["entry_time"], dt.UTC).isoformat() if n else None,
            "last": dt.datetime.fromtimestamp(self.trades[-1]["entry_time"], dt.UTC).isoformat() if n else None,
        }


# ---------------------------------------------------------------------------
def load(sym: str, tf: str) -> List[dict]:
    return load_csv(os.path.join(os.path.dirname(__file__), "..", "data",
                                 f"{sym}_{tf}.csv"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="GBPUSD")
    ap.add_argument("--stops", default="relaxed", choices=["relaxed", "spec"])
    ap.add_argument("--risk", type=float, default=0.5)
    ap.add_argument("--score-min", type=int, default=0)
    ap.add_argument("--range-tf", default="H1", choices=["H1", "H4"])
    ap.add_argument("--csv", default=None, help="trade log output")
    ap.add_argument("--json", default=None)
    ap.add_argument("--debug", action="store_true")
    args = ap.parse_args(argv)

    m15 = load(args.symbol, "M15")
    rbars = load(args.symbol, args.range_tf)
    d1 = load(args.symbol, "D1")
    bt = Backtest(args.symbol, m15, rbars, d1, range_tf=args.range_tf,
                  stop_mode=args.stops, risk_pct=args.risk / 100.0,
                  score_min=args.score_min)
    s = bt.run()

    if args.csv:
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=list(bt.trades[0].keys()) if bt.trades else [])
            if bt.trades:
                w.writeheader()
                w.writerows(bt.trades)
    if args.json:
        s["range_tf"] = args.range_tf
        s["risk_pct"] = args.risk
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(s, fh, indent=2)

    if args.debug:
        print(json.dumps(dict(bt.diag), indent=2, sort_keys=True))
    print(json.dumps(s, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())



