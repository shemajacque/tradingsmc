"""
smc_engine.py
=============
Reference implementation (Python) of sections 4.x ("market structure engine")
of the SMC rule set.  It is a deliberate 1:1 port of
``MQL5/Include/SMC/SMC_Structure.mqh`` so that CSV candle data can be run
outside MT5 and both implementations can be cross-checked (section 13).

Usage
-----
    from smc_engine import StructureEngine
    eng = StructureEngine()
    for bar in bars:            # only CLOSED bars, chronological order
        eng.push_bar(bar["time"], bar["open"], bar["high"],
                     bar["low"], bar["close"])
    print(eng.bias, eng.ranges[-1] if eng.ranges else None)

    # CSV replay:
    python smc_engine.py --csv data/GBPUSD_M15.csv

Interpretations of the written spec (all explicit, none hidden)
---------------------------------------------------------------
* Only closed bars are fed.  Nothing is recalculated, nothing repaints.
* Swing length L (InpSwingLen).  A swing at bar i is confirmed at bar i+L.
  Strict comparisons are used: an equal high/low is **not** a swing.
* The BOS uses a candle close by default (InpBOSByClose=True).  One close can
  break several older swings; every swing below/above the close is flagged
  broken but exactly one BOS event is emitted - for the most recent unbroken
  swing.
* Sweep (4.3) is frozen when the swing is confirmed, using the swings known at
  that moment:
     high sweep  = price > previous swing high
                   OR price at/above an equal-high pool (tolerance = 0.1*ATR)
                   OR price > Asia high OR price > previous day high.
  The tolerance only detects the pool; price must still reach the pool level.
* Strong high (4.4) = swept swing high that is followed by a bearish BOS which
  breaks *exactly* its origin low (the swing low immediately before it).
  A BOS breaking any other low never creates it.  Mirror for strong low.
* Range confirmation (4.5): after a strong high the running lowest low LL is
  tracked.  The range is confirmed only when a close exceeds the swing high
  that immediately precedes LL (and which lies after the strong high).  A close
  above any other swing high ("minor break") confirms nothing.  Provisional
  range = [LL, SH price].
* IRL (4.7) = highest swing high inside the confirmed bearish range (mirror for
  bullish).  ``irl_taken`` flips when price trades through it on/after the
  confirmation bar.
* Bias (4.8) = direction of the last confirmed range (bearish range = -1).
* ATR(14) in this file is a simple moving average of true range (Wilder is not
  required by the spec; the constant is exposed as ``atr_period``).
"""

from __future__ import annotations

import bisect
import heapq
from dataclasses import dataclass
from typing import Dict, List, Optional

BULL = 1
BEAR = -1
NEUTRAL = 0

CONFIRMED = "CONFIRMED"
PROVISIONAL = "PROVISIONAL"


@dataclass
class Swing:
    """A confirmed 3-candle (or 2L+1 candle) fractal."""

    idx: int
    time: int
    price: float
    is_high: bool
    broken: bool = False
    broken_time: int = 0
    broken_by_wick: bool = False
    swept: bool = False
    strong: bool = False
    invalidated: bool = False
    origin_idx: int = -1
    origin_price: float = 0.0


@dataclass
class Bos:
    direction: int          # +1 bullish, -1 bearish
    idx: int
    time: int
    swing_idx: int          # bar index of the swing that was broken
    swing_price: float


@dataclass
class Range:
    direction: int          # -1 bearish range (RH=strong high), +1 bullish
    rh: float
    rl: float
    status: str = CONFIRMED
    confirm_idx: int = -1
    confirm_time: int = 0
    rh_idx: int = -1
    rl_idx: int = -1
    strong_idx: int = -1
    eq: float = 0.0
    irl_price: float = 0.0
    irl_idx: int = -1
    irl_taken: bool = False
    broken: bool = False

    def __post_init__(self) -> None:
        self.eq = (self.rh + self.rl) / 2.0

    # ---- section 4.6 -----------------------------------------------------
    def ratio(self, price: float) -> float:
        """0 at RL, 1 at RH (may leave [0,1] outside the range)."""
        if self.rh <= self.rl:
            return 0.0
        return (price - self.rl) / (self.rh - self.rl)

    def in_premium(self, price: float) -> bool:
        return self.ratio(price) >= 0.5

    def in_discount(self, price: float) -> bool:
        return self.ratio(price) <= 0.5


@dataclass
class _RangeCandidate:
    """State that precedes a confirmed range (PROVISIONAL)."""

    direction: int
    rh: float
    idx_extreme: int         # bar index of the strong point
    price_extreme: float
    extreme_low: float       # running LL (bearish) / running HH (bullish)
    extreme_idx: int


class StructureEngine:
    """One instance per symbol/timeframe.  Feed closed bars with push_bar()."""

    def __init__(
        self,
        swing_len: int = 1,
        bos_by_close: bool = True,
        equal_tol_atr: float = 0.1,
        atr_period: int = 14,
        range_history: int = 3,
        strong_invalidate_by_close: bool = True,
    ) -> None:
        self.swing_len = max(1, int(swing_len))
        self.bos_by_close = bool(bos_by_close)
        self.equal_tol_atr = float(equal_tol_atr)
        self.atr_period = max(1, int(atr_period))
        self.range_history = max(1, int(range_history))
        self.strong_invalidate_by_close = bool(strong_invalidate_by_close)

        self.bars: List[dict] = []
        self.atr: List[float] = []

        self.swing_highs: List[Swing] = []
        self.swing_lows: List[Swing] = []
        self.bos_events: List[Bos] = []

        # Indexes that keep the reference engine O(n log n) on years of M15
        # data.  They are pure accelerators: every query below returns exactly
        # what the original linear scans returned (same ties too).
        self._high_idx: List[int] = []
        self._low_idx: List[int] = []
        self._high_sorted: List[float] = []
        self._low_sorted: List[float] = []
        self._sh_by_origin: Dict[int, List[Swing]] = {}
        self._sl_by_origin: Dict[int, List[Swing]] = {}
        # unbroken swings: (price, idx, swing) and (-idx, idx, swing)
        self._hi_price_heap: List[tuple] = []
        self._hi_idx_heap: List[tuple] = []
        self._lo_price_heap: List[tuple] = []
        self._lo_idx_heap: List[tuple] = []

        self.strong_high: Optional[Swing] = None
        self.strong_low: Optional[Swing] = None
        self.candidate: Optional[_RangeCandidate] = None
        self.ranges: List[Range] = []

        # external liquidity used by 4.3 (set by the session layer)
        self.ext_asia_high: Optional[float] = None
        self.ext_asia_low: Optional[float] = None
        self.ext_pdh: Optional[float] = None
        self.ext_pdl: Optional[float] = None

        # diagnostics
        self.last_bos: Optional[Bos] = None

    # =====================================================================
    # public API
    # =====================================================================
    def push_bar(self, t: int, o: float, h: float, l: float, c: float) -> None:
        """Feed one CLOSED bar.  Do not feed the forming bar."""
        i = len(self.bars)
        self.bars.append({"time": int(t), "open": float(o), "high": float(h),
                          "low": float(l), "close": float(c)})
        self.atr.append(self._calc_atr())

        self._detect_swing(i)
        # Confirmation is evaluated *before* break processing on purpose: the
        # close that confirms a bearish range is also a bullish BOS and would
        # otherwise immediately start a mirror (bullish) candidate, swallowing
        # the just-built range state.
        self._update_candidate(i)
        self._process_breaks(i)
        self._update_active_range(i)

    def set_external_liquidity(
        self,
        asia_high: Optional[float] = None,
        asia_low: Optional[float] = None,
        prev_day_high: Optional[float] = None,
        prev_day_low: Optional[float] = None,
    ) -> None:
        if asia_high is not None:
            self.ext_asia_high = float(asia_high)
        if asia_low is not None:
            self.ext_asia_low = float(asia_low)
        if prev_day_high is not None:
            self.ext_pdh = float(prev_day_high)
        if prev_day_low is not None:
            self.ext_pdl = float(prev_day_low)

    @property
    def last_range(self) -> Optional[Range]:
        return self.ranges[-1] if self.ranges else None

    @property
    def confirmed_range(self) -> Optional[Range]:
        return self.ranges[-1] if self.ranges else None

    @property
    def bias(self) -> int:
        r = self.last_range
        return r.direction if r is not None else NEUTRAL

    @property
    def bias_valid(self) -> bool:
        r = self.last_range
        return r is not None and not r.broken

    def provisional_range(self) -> Optional[Range]:
        c = self.candidate
        if c is None:
            return None
        if c.direction == BEAR:
            return Range(direction=BEAR, rh=c.rh, rl=c.extreme_low,
                         status=PROVISIONAL, rh_idx=c.idx_extreme,
                         rl_idx=c.extreme_idx, strong_idx=c.idx_extreme)
        return Range(direction=BULL, rh=c.extreme_low, rl=c.rh,
                     status=PROVISIONAL, rh_idx=c.extreme_idx,
                     rl_idx=c.idx_extreme, strong_idx=c.idx_extreme)

    def active_range(self) -> Optional[Range]:
        """Confirmed range if any, otherwise the provisional one."""
        return self.last_range or self.provisional_range()

    # ---- helpers used by POI / setup layers ------------------------------
    def last_swing_high_before(self, price: float) -> Optional[Swing]:
        best = None
        for s in self.swing_highs:
            if s.price <= price:
                best = s
        return best

    def last_swing_low_above(self, price: float) -> Optional[Swing]:
        best = None
        for s in self.swing_lows:
            if s.price >= price:
                best = s
        return best

    def swings_inside(self, rng: Range, is_high: bool) -> List[Swing]:
        pool = self.swing_highs if is_high else self.swing_lows
        lo = min(rng.rl, rng.rh)
        hi = max(rng.rl, rng.rh)
        return [s for s in pool if lo < s.price < hi]

    def count_equal_levels(self, is_high: bool, price: float,
                           tol: Optional[float] = None,
                           only_beyond: bool = True) -> int:
        """Number of swing points (same type) inside ``tol`` of ``price``.

        With ``only_beyond`` the pool counts only points at/above the price for
        highs (they hold buy stops) and at/below for lows.
        """
        if tol is None:
            tol = self.equal_tol_atr * (self.atr[-1] if self.atr else 0.0)
        arr = self._high_sorted if is_high else self._low_sorted
        if only_beyond:
            lo, hi = (price, price + tol) if is_high else (price - tol, price)
        else:
            lo, hi = price - tol, price + tol
        return bisect.bisect_right(arr, hi) - bisect.bisect_left(arr, lo)

    def trendline_count(self, is_high: bool, tol: Optional[float] = None) -> int:
        """Largest number of aligned swing points (section 7.E), last 30 swings.

        A trendline is a straight line through >= 3 same-type swings whose
        prices sit within ``tol`` of that line.  It is only a liquidity pool,
        never an entry trigger.
        """
        if tol is None:
            tol = self.equal_tol_atr * (self.atr[-1] if self.atr else 0.0)
        pool = self.swing_highs if is_high else self.swing_lows
        pts = pool[-30:]
        if len(pts) < 3:
            return len(pts)
        best = 1
        for a in range(len(pts)):
            for b in range(a + 1, len(pts)):
                span = pts[b].idx - pts[a].idx
                if span <= 0:
                    continue
                slope = (pts[b].price - pts[a].price) / span
                n = 2
                for k in range(b + 1, len(pts)):
                    exp = pts[b].price + slope * (pts[k].idx - pts[b].idx)
                    if abs(pts[k].price - exp) <= tol:
                        n += 1
                best = max(best, n)
        return best

    def range_zone(self, price: float, rng: Optional[Range] = None) -> str:
        r = rng or self.last_range
        if r is None:
            return "NO_RANGE"
        p = r.ratio(price)
        if p >= 0.79:
            return "EXTREME_PREMIUM"
        if p >= 0.5:
            return "PREMIUM"
        if p <= 0.21:
            return "EXTREME_DISCOUNT"
        return "DISCOUNT"

    def extreme_zone(self, price: float, rng: Optional[Range] = None) -> bool:
        return self.range_zone(price, rng) in ("EXTREME_PREMIUM", "EXTREME_DISCOUNT")

    # =====================================================================
    # internals
    # =====================================================================
    def _calc_atr(self) -> float:
        i = len(self.bars) - 1
        b = self.bars[i]
        if i == 0:
            tr = b["high"] - b["low"]
        else:
            pc = self.bars[i - 1]["close"]
            tr = max(b["high"] - b["low"], abs(b["high"] - pc),
                     abs(b["low"] - pc))
        n = min(len(self.bars), self.atr_period)
        if n <= 1:
            return tr
        # simple average of the last n true ranges (recompute for clarity)
        s = 0.0
        for k in range(i - n + 1, i + 1):
            if k == 0:
                s += self.bars[k]["high"] - self.bars[k]["low"]
            else:
                pc = self.bars[k - 1]["close"]
                bb = self.bars[k]
                s += max(bb["high"] - bb["low"], abs(bb["high"] - pc),
                         abs(bb["low"] - pc))
        return s / n

    def _detect_swing(self, i: int) -> None:
        L = self.swing_len
        center = i - L
        if center - L < 0:
            return
        highs = self.bars[center - L:center]
        highs_after = self.bars[center + 1:i + 1]
        if len(highs_after) < L:
            return
        cbar = self.bars[center]
        if cbar["high"] > max(b["high"] for b in highs) and \
           cbar["high"] > max(b["high"] for b in highs_after):
            price = cbar["high"]
            swept = self._is_sweep_high(price, self.atr[center])
            sh = Swing(idx=center, time=cbar["time"], price=price,
                       is_high=True, swept=swept)
            prev_low = self.swing_lows[-1] if self.swing_lows else None
            if prev_low is not None and prev_low.idx < center:
                sh.origin_idx = prev_low.idx
                sh.origin_price = prev_low.price
            self.swing_highs.append(sh)
            self._high_idx.append(center)
            bisect.insort(self._high_sorted, price)
            if sh.origin_idx >= 0:
                self._sh_by_origin.setdefault(sh.origin_idx, []).append(sh)
            heapq.heappush(self._hi_price_heap, (price, center, sh))
            heapq.heappush(self._hi_idx_heap, (-center, center, sh))

        lows_before = self.bars[center - L:center]
        lows_after = self.bars[center + 1:i + 1]
        if cbar["low"] < min(b["low"] for b in lows_before) and \
           cbar["low"] < min(b["low"] for b in lows_after):
            price = cbar["low"]
            swept = self._is_sweep_low(price, self.atr[center])
            sl = Swing(idx=center, time=cbar["time"], price=price,
                       is_high=False, swept=swept)
            prev_high = self.swing_highs[-1] if self.swing_highs else None
            if prev_high is not None and prev_high.idx < center:
                sl.origin_idx = prev_high.idx
                sl.origin_price = prev_high.price
            self.swing_lows.append(sl)
            self._low_idx.append(center)
            bisect.insort(self._low_sorted, price)
            if sl.origin_idx >= 0:
                self._sl_by_origin.setdefault(sl.origin_idx, []).append(sl)
            heapq.heappush(self._lo_price_heap, (-price, center, sl))
            heapq.heappush(self._lo_idx_heap, (-center, center, sl))

    def _is_sweep_high(self, price: float, atr: float) -> bool:
        if self.swing_highs and price > self.swing_highs[-1].price:
            return True
        tol = self.equal_tol_atr * atr
        arr = self._high_sorted
        p = bisect.bisect_left(arr, price)
        if p < len(arr) and arr[p] == price:
            return True
        if p > 0 and arr[p - 1] >= price - tol:
            return True
        if self.ext_asia_high is not None and price > self.ext_asia_high:
            return True
        if self.ext_pdh is not None and price > self.ext_pdh:
            return True
        return False

    def _is_sweep_low(self, price: float, atr: float) -> bool:
        if self.swing_lows and price < self.swing_lows[-1].price:
            return True
        tol = self.equal_tol_atr * atr
        arr = self._low_sorted
        p = bisect.bisect_left(arr, price)
        if p < len(arr) and arr[p] <= price + tol:
            return True
        if self.ext_asia_low is not None and price < self.ext_asia_low:
            return True
        if self.ext_pdl is not None and price < self.ext_pdl:
            return True
        return False

    def _last_unbroken_high(self) -> Optional[Swing]:
        while self._hi_idx_heap and self._hi_idx_heap[0][2].broken:
            heapq.heappop(self._hi_idx_heap)
        return self._hi_idx_heap[0][2] if self._hi_idx_heap else None

    def _last_unbroken_low(self) -> Optional[Swing]:
        while self._lo_idx_heap and self._lo_idx_heap[0][2].broken:
            heapq.heappop(self._lo_idx_heap)
        return self._lo_idx_heap[0][2] if self._lo_idx_heap else None

    def _break_highs_below(self, val: float, t: int) -> None:
        by_wick = not self.bos_by_close
        while self._hi_price_heap and self._hi_price_heap[0][0] < val:
            _, _, s = heapq.heappop(self._hi_price_heap)
            if not s.broken:
                s.broken = True
                s.broken_time = t
                s.broken_by_wick = by_wick

    def _break_lows_above(self, val: float, t: int) -> None:
        by_wick = not self.bos_by_close
        while self._lo_price_heap and -self._lo_price_heap[0][0] > val:
            _, _, s = heapq.heappop(self._lo_price_heap)
            if not s.broken:
                s.broken = True
                s.broken_time = t
                s.broken_by_wick = by_wick

    def _process_breaks(self, i: int) -> None:
        b = self.bars[i]
        val = b["close"] if self.bos_by_close else b["high"]
        # ---- bullish break of the most recent unbroken swing high ---------
        target = self._last_unbroken_high()
        if target is not None and val > target.price:
            self._break_highs_below(val, b["time"])
            ev = Bos(BULL, i, b["time"], target.idx, target.price)
            self.bos_events.append(ev)
            self.last_bos = ev
            self._on_bos(ev, target)

        val = b["close"] if self.bos_by_close else b["low"]
        # ---- bearish break -------------------------------------------------
        target = self._last_unbroken_low()
        if target is not None and val < target.price:
            self._break_lows_above(val, b["time"])
            ev = Bos(BEAR, i, b["time"], target.idx, target.price)
            self.bos_events.append(ev)
            self.last_bos = ev
            self._on_bos(ev, target)

    def _on_bos(self, ev: Bos, broken: Swing) -> None:
        """Section 4.4: try to promote a swept swing to a strong point."""
        if ev.direction == BEAR:
            # a low was broken -> look for the newest swept swing high whose
            # origin low is exactly the broken low (origin low precedes SH)
            for s in reversed(self._sh_by_origin.get(broken.idx, ())):
                if s.broken or not s.swept:
                    continue
                self._set_strong_high(s)
                break
        else:
            for s in reversed(self._sl_by_origin.get(broken.idx, ())):
                if s.broken or not s.swept:
                    continue
                self._set_strong_low(s)
                break

    def _set_strong_high(self, s: Swing) -> None:
        if self.strong_high is s:
            return
        s.strong = True
        self.strong_high = s
        start = s.idx + 1
        ll = self.bars[start]["low"] if start < len(self.bars) else s.price
        ll_idx = start
        for k in range(start, len(self.bars)):
            if self.bars[k]["low"] <= ll:
                ll = self.bars[k]["low"]
                ll_idx = k
        self.candidate = _RangeCandidate(
            direction=BEAR, rh=s.price, idx_extreme=s.idx,
            price_extreme=s.price, extreme_low=ll, extreme_idx=ll_idx)
        # a new strong high replaces the old; old range keeps its record

    def _set_strong_low(self, s: Swing) -> None:
        if self.strong_low is s:
            return
        s.strong = True
        self.strong_low = s
        start = s.idx + 1
        hh = self.bars[start]["high"] if start < len(self.bars) else s.price
        hh_idx = start
        for k in range(start, len(self.bars)):
            if self.bars[k]["high"] >= hh:
                hh = self.bars[k]["high"]
                hh_idx = k
        self.candidate = _RangeCandidate(
            direction=BULL, rh=s.price, idx_extreme=s.idx,
            price_extreme=s.price, extreme_low=hh, extreme_idx=hh_idx)

    def _update_candidate(self, i: int) -> None:
        c = self.candidate
        if c is None:
            return
        b = self.bars[i]
        if c.direction == BEAR:
            if b["low"] < c.extreme_low:
                c.extreme_low = b["low"]
                c.extreme_idx = i
            if self.strong_invalidate_by_close and b["close"] > c.rh:
                self._cancel_candidate()
                return
            pivot = None
            k0 = bisect.bisect_right(self._high_idx, c.idx_extreme)
            for k in range(k0, len(self.swing_highs)):
                s = self.swing_highs[k]
                if s.idx >= c.extreme_idx:
                    break
                if s.price < c.rh:
                    pivot = s
            if pivot is not None and b["close"] > pivot.price:
                self._confirm_bear_range(c, pivot, i)
        else:
            if b["high"] > c.extreme_low:
                c.extreme_low = b["high"]
                c.extreme_idx = i
            if self.strong_invalidate_by_close and b["close"] < c.rh:
                self._cancel_candidate()
                return
            pivot = None
            k0 = bisect.bisect_right(self._low_idx, c.idx_extreme)
            for k in range(k0, len(self.swing_lows)):
                s = self.swing_lows[k]
                if s.idx >= c.extreme_idx:
                    break
                if s.price > c.rh:
                    pivot = s
            if pivot is not None and b["close"] < pivot.price:
                self._confirm_bull_range(c, pivot, i)

    def _cancel_candidate(self) -> None:
        if self.strong_high is not None and \
                self.candidate is not None and \
                self.candidate.direction == BEAR:
            self.strong_high.invalidated = True
        if self.strong_low is not None and \
                self.candidate is not None and \
                self.candidate.direction == BULL:
            self.strong_low.invalidated = True
        self.candidate = None

    def _confirm_bear_range(self, c: _RangeCandidate, pivot: Swing,
                            i: int) -> None:
        rng = Range(direction=BEAR, rh=c.rh, rl=c.extreme_low,
                    status=CONFIRMED, confirm_idx=i,
                    confirm_time=self.bars[i]["time"],
                    rh_idx=c.idx_extreme, rl_idx=c.extreme_idx,
                    strong_idx=c.idx_extreme)
        self._attach_irl(rng, i)
        self.ranges.append(rng)
        if len(self.ranges) > self.range_history:
            self.ranges = self.ranges[-self.range_history:]
        self.candidate = None

    def _confirm_bull_range(self, c: _RangeCandidate, pivot: Swing,
                            i: int) -> None:
        rng = Range(direction=BULL, rh=c.extreme_low, rl=c.rh,
                    status=CONFIRMED, confirm_idx=i,
                    confirm_time=self.bars[i]["time"],
                    rh_idx=c.extreme_idx, rl_idx=c.idx_extreme,
                    strong_idx=c.idx_extreme)
        self._attach_irl(rng, i)
        self.ranges.append(rng)
        if len(self.ranges) > self.range_history:
            self.ranges = self.ranges[-self.range_history:]
        self.candidate = None

    def _attach_irl(self, rng: Range, i: int) -> None:
        """Highest swing high (bear) / lowest swing low (bull) inside range.

        Only swings formed *inside* the new range count (after its strong
        point); older swings that happen to sit between RL and RH are not
        internal liquidity of this range.
        """
        best = None
        if rng.direction == BEAR:
            k0 = bisect.bisect_right(self._high_idx, rng.rh_idx)
            for k in range(k0, len(self.swing_highs)):
                s = self.swing_highs[k]
                if s.idx > i:
                    break
                if rng.rl < s.price < rng.rh:
                    if best is None or s.price > best.price:
                        best = s
        else:
            k0 = bisect.bisect_right(self._low_idx, rng.rl_idx)
            for k in range(k0, len(self.swing_lows)):
                s = self.swing_lows[k]
                if s.idx > i:
                    break
                if rng.rl < s.price < rng.rh:
                    if best is None or s.price < best.price:
                        best = s
        if best is not None:
            rng.irl_price = best.price
            rng.irl_idx = best.idx

    def _update_active_range(self, i: int) -> None:
        r = self.last_range
        b = self.bars[i]
        if r is None:
            return
        if r.irl_idx >= 0 and not r.irl_taken:
            if r.direction == BEAR and b["high"] >= r.irl_price:
                r.irl_taken = True
            if r.direction == BULL and b["low"] <= r.irl_price:
                r.irl_taken = True
        if not r.broken:
            if r.direction == BEAR and b["close"] > r.rh:
                r.broken = True
            if r.direction == BULL and b["close"] < r.rl:
                r.broken = True
        # 4.4 strong point invalidation by close
        if self.strong_invalidate_by_close:
            if self.strong_high is not None and \
                    b["close"] > self.strong_high.price:
                self.strong_high.invalidated = True
            if self.strong_low is not None and \
                    b["close"] < self.strong_low.price:
                self.strong_low.invalidated = True


# =========================================================================
# CSV replay helper (section 13 cross-check)
# =========================================================================
def load_csv(path: str) -> List[dict]:
    """CSV columns: time,open,high,low,close  (time = unix ts or ISO string)."""
    import csv
    import datetime as dt

    rows: List[dict] = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            key = {k.lower().strip(): v for k, v in row.items()}
            raw = key.get("time") or key.get("date") or key.get("datetime")
            if raw is None:
                continue
            raw = raw.strip()
            if raw.isdigit():
                ts = int(raw)
            else:
                ts = int(dt.datetime.fromisoformat(
                    raw.replace("Z", "+00:00")).timestamp())
            rows.append({"time": ts,
                         "open": float(key["open"]),
                         "high": float(key["high"]),
                         "low": float(key["low"]),
                         "close": float(key["close"])})
    return rows


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="SMC structure engine (4.x)")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--swing-len", type=int, default=1)
    ap.add_argument("--wick-bos", action="store_true",
                    help="use wicks instead of closes for BOS")
    ap.add_argument("--tol", type=float, default=0.1)
    args = ap.parse_args(argv)

    eng = StructureEngine(swing_len=args.swing_len,
                          bos_by_close=not args.wick_bos,
                          equal_tol_atr=args.tol)
    for b in load_csv(args.csv):
        eng.push_bar(b["time"], b["open"], b["high"], b["low"], b["close"])

    print(f"bars={len(eng.bars)} swingsH={len(eng.swing_highs)} "
          f"swingsL={len(eng.swing_lows)} bos={len(eng.bos_events)}")
    print(f"strong_high={eng.strong_high.price if eng.strong_high else None} "
          f"strong_low={eng.strong_low.price if eng.strong_low else None}")
    for r in eng.ranges:
        print(f"range dir={r.direction} RH={r.rh:.5f} RL={r.rl:.5f} "
              f"EQ={r.eq:.5f} irl={r.irl_price:.5f} "
              f"taken={r.irl_taken} broken={r.broken}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
