"""
smc_addendum.py
===============
Python reference for addendum A1-A5 (Phase 6):

* close-price levels ("CLOSE_LEVEL" POI model) with freshness, SBR/RBS flips,
  direction filter, HTF priority and the top/bottom rule;
* the Asia day-type classifier (A3.1);
* the range-expansion state machine (A4).

Mirrors ``SMC_CloseLevel.mqh``, ``SMC_TopDown.mqh`` and the Phase-6 parts of
``SMC_Setups.mqh``.  Every discretionary choice is a constructor parameter.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Tuple

from smc_engine import BULL, BEAR, NEUTRAL, CONFIRMED, StructureEngine
from smc_poi import LVL_RES, LVL_SUP, BiasEngine

DAY_NEWS = 1
DAY_TRENDING = 2
DAY_STRONG_HIGH = 3
DAY_STRONG_LOW = 4
DAY_CONSOLIDATING = 5

TF_RANK = {"M1": 0, "M5": 0, "M15": 1, "M30": 2, "H1": 3,
           "H4": 4, "D1": 5, "W1": 6, "MN1": 7}


@dataclass
class Level:
    price: float
    type: int                  # LVL_RES / LVL_SUP
    tf: str
    bar_time: int
    touch_count: int = 0
    used: bool = False
    broken: bool = False
    flipped_from: int = -1
    fresh: bool = True
    active: bool = True
    quality: float = 1.0


class CloseLevelEngine:
    """A1 close-price level engine, one instance per timeframe."""

    def __init__(self, structure: StructureEngine, tf: str = "H4",
                 band_points: float = 2.0, body_close_break: bool = True,
                 use_ob_map: bool = False, min_tf: str = "M15",
                 htf_conflict_tol: float = 0.0,
                 max_refine_dist: float = 0.0, max_levels: int = 512) -> None:
        self.structure = structure
        self.tf = tf
        self.band_points = float(band_points)
        self.body_close_break = bool(body_close_break)
        self.use_ob_map = bool(use_ob_map)
        self.min_rank = TF_RANK.get(min_tf, 1)
        self.htf_conflict_tol = float(htf_conflict_tol)
        self.max_refine_dist = float(max_refine_dist)
        self.max_levels = max_levels
        self.levels: List[Level] = []

    @property
    def rank(self) -> int:
        return TF_RANK.get(self.tf, 0)

    def rebuild(self):
        self.levels = []
        if self.rank < self.min_rank:
            return
        bars = self.structure.bars
        for i in range(1, len(bars) - 1):
            a, b, c = bars[i - 1]["close"], bars[i]["close"], bars[i + 1]["close"]
            if b > a and b > c:
                self._add(b, LVL_RES, bars[i]["time"])
            elif b < a and b < c:
                self._add(b, LVL_SUP, bars[i]["time"])
        self._flips_and_touches()

    def _add(self, price, ltype, time, quality=1.0):
        if len(self.levels) >= self.max_levels:
            return
        self.levels.append(Level(price=price, type=ltype, tf=self.tf,
                                 bar_time=time, quality=quality))

    def _flips_and_touches(self):
        bars = self.structure.bars
        for l in self.levels:
            origin = -1
            for i, b in enumerate(bars):
                if b["time"] == l.bar_time:
                    origin = i
                    break
            for b in bars[origin + 1:]:
                if self.body_close_break and not l.broken:
                    through = (b["close"] > l.price) if l.type == LVL_RES \
                        else (b["close"] < l.price)
                    if through:
                        l.broken = True
                        l.flipped_from = l.type
                        l.type = LVL_SUP if l.type == LVL_RES else LVL_RES
                        l.touch_count = 0
                        l.fresh = True
                if b["low"] <= l.price <= b["high"]:
                    l.touch_count += 1
                    l.fresh = False

    def _direction_ok(self, l: Level, trend_dir: int) -> bool:
        if trend_dir == NEUTRAL:
            return True
        return (l.type == LVL_RES) if trend_dir == BEAR else (l.type == LVL_SUP)

    def best_level(self, trend_dir: int, price: float, tol: float) -> Optional[Level]:
        best, best_rank, best_score = None, -1, -1e18
        for l in self.levels:
            if not l.active or not l.fresh or l.used:
                continue
            if not self._direction_ok(l, trend_dir):
                continue
            if abs(l.price - price) > tol:
                continue
            sc = l.quality - abs(l.price - price) / (tol + 1e-12)
            if self.rank > best_rank or (self.rank == best_rank and sc > best_score):
                best_rank, best_score, best = self.rank, sc, l
        return best

    def has_conflict(self, l: Level, higher: "CloseLevelEngine") -> bool:
        opposing = LVL_SUP if l.type == LVL_RES else LVL_RES
        for h in higher.levels:
            if not h.active or h.type != opposing:
                continue
            if TF_RANK.get(h.tf, 0) <= self.rank:
                continue
            if abs(h.price - l.price) <= self.htf_conflict_tol:
                return True
        return False

    def refine(self, htf: Level, lower: "CloseLevelEngine") -> Optional[Level]:
        if lower.rank >= self.rank:
            return None
        best, best_d = None, 1e18
        for l in lower.levels:
            if not l.fresh or not l.active or l.type != htf.type:
                continue
            d = abs(l.price - htf.price)
            if d > self.max_refine_dist or d >= best_d:
                continue
            best, best_d = l, d
        return best

    def two_close_levels(self, direction: int, price: float,
                         cluster: float) -> Optional[Tuple[Level, Level]]:
        want = LVL_RES if direction == BEAR else LVL_SUP
        cands = [l for l in self.levels
                 if l.active and l.fresh and not l.used and l.type == want
                 and abs(l.price - price) <= cluster * 3]
        if not cands:
            return None
        if direction == BEAR:
            top = [l for l in cands if l.price <= price + cluster]
            bottom = [l for l in cands if l.price >= price - cluster]
            top = max(top, key=lambda x: x.price, default=None)
            bottom = min(bottom, key=lambda x: x.price, default=None)
        else:
            top = [l for l in cands if l.price >= price - cluster]
            bottom = [l for l in cands if l.price <= price + cluster]
            top = min(top, key=lambda x: x.price, default=None)
            bottom = max(bottom, key=lambda x: x.price, default=None)
        if top and bottom and abs(top.price - bottom.price) <= cluster:
            return top, bottom
        return None


def classify_day(asia, news_in_window: bool, trend_max: float) -> int:
    """A3.1. Section-7.0 skip filter is applied by the caller first."""
    if news_in_window:
        return DAY_NEWS
    if asia.efficiency > trend_max:
        return DAY_TRENDING
    if asia.high_strong and asia.low_strong:
        return DAY_TRENDING
    if asia.high_strong:
        return DAY_STRONG_HIGH
    if asia.low_strong:
        return DAY_STRONG_LOW
    return DAY_CONSOLIDATING


class RangeExpansion:
    """A4 state machine."""

    def __init__(self, counter_one_lower: bool = False) -> None:
        self.expansion_bear = False
        self.expansion_bull = False
        self.counter_one_lower = counter_one_lower

    def reset(self):
        self.expansion_bear = False
        self.expansion_bull = False

    def update(self, range_engine: StructureEngine,
               probe_engine: Optional[StructureEngine] = None):
        probe = probe_engine if self.counter_one_lower else range_engine
        if probe is None:
            probe = range_engine
        r = range_engine.last_range
        if r is not None:
            if r.broken:
                self.reset()
                return
            if r.direction == BEAR:
                self.expansion_bull = False
            elif r.direction == BULL:
                self.expansion_bear = False
        if probe.bos_events and probe.strong_high and not probe.strong_high.invalidated:
            if probe.bos_events[-1].direction == BEAR:
                self.expansion_bear = True
        if probe.bos_events and probe.strong_low and not probe.strong_low.invalidated:
            if probe.bos_events[-1].direction == BULL:
                self.expansion_bull = True

    def allow(self, direction: int) -> bool:
        if self.expansion_bear and direction == BULL:
            return False
        if self.expansion_bull and direction == BEAR:
            return False
        return True
