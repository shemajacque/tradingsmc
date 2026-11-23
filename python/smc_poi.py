"""
smc_poi.py
==========
Reference implementation of section 5 (POI detection / mitigation /
refinement / eligibility / priority) and section 6 (multi-TF bias engine).

It is a deliberate 1:1 port of ``MQL5/Include/SMC/SMC_POI.mqh`` and
``SMC_Bias.mqh`` so a CSV replay can be cross-checked outside MT5.

Every discretionary choice is an explicit constructor parameter.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional

from smc_engine import BULL, BEAR, NEUTRAL, CONFIRMED, StructureEngine

POI_ORDER_BLOCK = 0
POI_BREAKER = 1
POI_WICK = 2
POI_FVG = 3
POI_MITIGATION = 4
POI_CLOSE_LEVEL = 5

LVL_RES = 0
LVL_SUP = 1


@dataclass
class Poi:
    top: float
    bottom: float
    type: int
    level_type: int
    tf: str
    time: int
    origin_idx: int
    mitigated: bool = False
    broken: bool = False
    flipped_from: int = -1
    touch_count: int = 0
    overlap_count: int = 0
    quality: float = 1.0
    active: bool = True

    @property
    def mid(self) -> float:
        return (self.top + self.bottom) / 2.0

    @property
    def height(self) -> float:
        return self.top - self.bottom


class PoiEngine:
    """One instance per timeframe, fed by a StructureEngine."""

    def __init__(
        self,
        structure: StructureEngine,
        tf: str = "M15",
        min_wick_ratio: float = 0.5,
        ob_body_only: bool = False,
        max_height_atr: float = 0.6,
        equal_tol_atr: float = 0.1,
        ob_lookback: int = 12,
        max_pois: int = 512,
    ) -> None:
        self.structure = structure
        self.tf = tf
        self.min_wick_ratio = float(min_wick_ratio)
        self.ob_body_only = bool(ob_body_only)
        self.max_height_atr = float(max_height_atr)
        self.equal_tol_atr = float(equal_tol_atr)
        self.ob_lookback = max(2, int(ob_lookback))
        self.max_pois = max(32, int(max_pois))
        self.pois: List[Poi] = []
        self._mitigated_through = 0

    # ------------------------------------------------------------------
    @property
    def atr(self) -> float:
        return self.structure.atr[-1] if self.structure.atr else 0.0

    def _add(self, top, bottom, ptype, lt, time, idx, quality=1.0):
        if len(self.pois) >= self.max_pois:
            return
        self.pois.append(
            Poi(top=max(top, bottom), bottom=min(top, bottom), type=ptype,
                level_type=lt, tf=self.tf, time=time, origin_idx=idx,
                quality=quality)
        )

    def _order_blocks(self):
        bars = self.structure.bars
        for ev in self.structure.bos_events:
            start = ev.idx - 1
            if start < 0:
                continue
            stop = max(0, start - self.ob_lookback + 1)
            ob_idx = None
            for k in range(start, stop - 1, -1):
                b = bars[k]
                wanted = (b["close"] > b["open"]) if ev.direction == BEAR \
                    else (b["close"] < b["open"])
                if wanted:
                    ob_idx = k
                    break
            if ob_idx is None:
                continue
            ob = bars[ob_idx]
            top, bot = ob["high"], ob["low"]
            if self.ob_body_only:
                top, bot = max(ob["open"], ob["close"]), min(ob["open"], ob["close"])
            lt = LVL_RES if ev.direction == BEAR else LVL_SUP
            quality = 1.0
            disp = bars[ev.idx]
            swept = (disp["high"] > ob["high"] and disp["close"] < ob["low"]) \
                if ev.direction == BEAR else \
                (disp["low"] < ob["low"] and disp["close"] > ob["high"])
            if swept:
                quality += 1.0
            self._add(top, bot, POI_ORDER_BLOCK, lt, ob["time"], ob_idx, quality)

    def _wicks(self):
        bars = self.structure.bars
        for i in range(1, len(bars)):
            cur, prev = bars[i], bars[i - 1]
            span = cur["high"] - cur["low"]
            if span <= 0:
                continue
            upper = cur["high"] - max(cur["open"], cur["close"])
            if self.min_wick_ratio > 0 and upper >= self.min_wick_ratio * span \
                    and cur["high"] > prev["high"]:
                self._add(cur["high"], max(cur["open"], cur["close"]),
                          POI_WICK, LVL_RES, cur["time"], i)
            lower = min(cur["open"], cur["close"]) - cur["low"]
            if self.min_wick_ratio > 0 and lower >= self.min_wick_ratio * span \
                    and cur["low"] < prev["low"]:
                self._add(min(cur["open"], cur["close"]), cur["low"],
                          POI_WICK, LVL_SUP, cur["time"], i)

    def _fvgs(self):
        bars = self.structure.bars
        for i in range(2, len(bars)):
            a, c = bars[i - 2], bars[i]
            if c["low"] > a["high"]:
                self._add(c["low"], a["high"], POI_FVG, LVL_SUP, c["time"], i)
            if c["high"] < a["low"]:
                self._add(a["low"], c["high"], POI_FVG, LVL_RES, c["time"], i)

    def _apply_mitigation(self, start_from=0):
        bars = self.structure.bars
        for p in self.pois:
            for k in range(max(start_from, p.origin_idx + 1), len(bars)):
                b = bars[k]
                # Breaker check runs first: a body close through the far edge
                # flips usage and resets freshness (section 5 / breaker).
                if not p.broken and p.type == POI_ORDER_BLOCK:
                    through = (b["close"] > p.top) if p.level_type == LVL_RES \
                        else (b["close"] < p.bottom)
                    if through:
                        p.broken = True
                        p.flipped_from = p.level_type
                        p.type = POI_BREAKER
                        p.level_type = LVL_SUP if p.level_type == LVL_RES else LVL_RES
                        p.mitigated = False
                        p.touch_count = 0
                        continue
                if not p.mitigated and \
                        b["low"] <= p.top and b["high"] >= p.bottom:
                    p.mitigated = True
                    p.touch_count += 1
        self._mitigated_through = len(bars)

    def rebuild(self):
        self.pois = []
        self._mitigated_through = 0
        self._order_blocks()
        self._wicks()
        self._fvgs()
        self._apply_mitigation(0)

    def refresh(self):
        n = len(self.structure.bars)
        if n > self._mitigated_through:
            self._apply_mitigation(self._mitigated_through)

    def needs_refinement(self, p: Poi) -> bool:
        return (self.atr > 0 and p.height / self.atr > self.max_height_atr)

    def refine(self, htf: Poi, lower: "PoiEngine") -> Optional[Poi]:
        best, best_h = None, 1e18
        for p in lower.pois:
            if p.level_type != htf.level_type or p.mitigated:
                continue
            if p.top > htf.top or p.bottom < htf.bottom:
                continue
            if p.height < best_h:
                best, best_h = p, p.height
        return best

    def liquidity_beyond(self, p: Poi, tol: float) -> int:
        s = self.structure
        n = 0
        if p.level_type == LVL_RES:
            n += s.count_equal_levels(False, p.bottom, tol, True)
            if s.trendline_count(False, tol) >= 3:
                n += 1
        else:
            n += s.count_equal_levels(True, p.top, tol, True)
            if s.trendline_count(True, tol) >= 3:
                n += 1
        return n

    def best(self, direction: int, rng, price: float,
             skip_first_pullback: bool = True) -> Optional[Poi]:
        want_res = direction == BEAR
        best, best_score = None, -1e18
        for p in self.pois:
            if not p.active or p.mitigated:
                continue
            if (p.level_type == LVL_RES) != want_res:
                continue
            ratio = rng.ratio(p.mid)
            if (ratio < 0.5) if want_res else (ratio > 0.5):
                continue
            if skip_first_pullback and not rng.irl_taken and \
                    p.type == POI_ORDER_BLOCK:
                older = [q for q in self.pois
                         if not q.mitigated and q.level_type == p.level_type
                         and q.origin_idx < p.origin_idx]
                if not older:
                    continue
            score = p.quality + 2.0 * p.overlap_count
            if rng.irl_price > 0:
                score -= abs(p.mid - rng.irl_price)
            score -= abs(p.mid - rng.eq)
            if score > best_score:
                best, best_score = p, score
        return best

    @staticmethod
    def entry_level(p: Poi, level: float = 0.5) -> float:
        level = min(1.0, max(0.0, level))
        if p.level_type == LVL_RES:
            return p.bottom + level * (p.top - p.bottom)
        return p.top - level * (p.top - p.bottom)


class BiasEngine:
    """Section 6. Returns BULL/BEAR/NEUTRAL."""

    def __init__(self, w1=None, d1=None, h4=None, h1=None,
                 w1poi=None, d1poi=None, h4poi=None, h1poi=None,
                 use_weekly: bool = False,
                 require_weekly_agree: bool = True,
                 htf_conflict_tol: float = 0.0):
        self.w1, self.d1, self.h4, self.h1 = w1, d1, h4, h1
        self.w1poi, self.d1poi, self.h4poi, self.h1poi = \
            w1poi, d1poi, h4poi, h1poi
        self.use_weekly = use_weekly
        self.require_weekly_agree = require_weekly_agree
        self.htf_conflict_tol = htf_conflict_tol
        self.bias = NEUTRAL
        self.counter_bias_zone = False
        self.weekly_dir = NEUTRAL
        self.range_tf = "H1"

    @staticmethod
    def _confirmed_dir(s):
        if s is None:
            return None
        r = s.last_range
        if r is None or r.status != CONFIRMED or r.broken:
            return None
        return r.direction

    def refresh_weekly(self):
        if not self.use_weekly or self.w1 is None:
            return
        d = self._confirmed_dir(self.w1)
        if d is None:
            d = self.w1.bias
        if d != NEUTRAL:
            self.weekly_dir = d

    def compute(self, price: float) -> int:
        d1 = self._confirmed_dir(self.d1)
        if d1 is not None:
            self.bias, self.range_tf = d1, "D1"
        else:
            h4 = self._confirmed_dir(self.h4)
            if h4 is not None:
                self.bias, self.range_tf = h4, "H4"
            else:
                self.bias, self.range_tf = NEUTRAL, "H4"
                if self.h4 is not None:
                    if self.h4.strong_high and not self.h4.strong_high.invalidated:
                        self.bias = BEAR
                    elif self.h4.strong_low and not self.h4.strong_low.invalidated:
                        self.bias = BULL

        if self.use_weekly and self.weekly_dir != NEUTRAL:
            if self.require_weekly_agree:
                if self.bias != NEUTRAL and self.bias != self.weekly_dir:
                    self.bias = NEUTRAL
                elif self.bias == NEUTRAL:
                    self.bias = self.weekly_dir
            else:
                self.bias = self.weekly_dir

        opposing = LVL_SUP if self.bias == BEAR else LVL_RES
        self.counter_bias_zone = False
        for eng in (self.w1poi, self.d1poi, self.h4poi, self.h1poi):
            if eng is None:
                continue
            for p in eng.pois:
                if p.mitigated or not p.active or p.level_type != opposing:
                    continue
                if p.bottom <= price <= p.top:
                    self.counter_bias_zone = True
                    return self.bias
        return self.bias

    def overlaps_htf_poi(self, top, bottom, direction) -> int:
        want = LVL_RES if direction == BEAR else LVL_SUP
        count = 0
        for eng in (self.w1poi, self.d1poi, self.h4poi, self.h1poi):
            if eng is None:
                continue
            for p in eng.pois:
                if p.mitigated or not p.active or p.level_type != want:
                    continue
                if bottom <= p.top and top >= p.bottom:
                    count += 1
        return count
