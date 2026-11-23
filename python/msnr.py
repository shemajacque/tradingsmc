"""
msnr.py
=======
Python reference for the OPTIONAL MSNR module (addendum A6-A8, Phase 7).

Mirrors ``MSNR_Levels.mqh``, ``MSNR_Storyline.mqh`` and ``MSNR_SetupM.mqh``.
GBO is deliberately not implemented (the source does not explain it).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Tuple

from smc_engine import BULL, BEAR, NEUTRAL, StructureEngine

MSNR_CLASSIC_V = 0
MSNR_CLASSIC_A = 1
MSNR_OCL = 2
MSNR_SBR = 3
MSNR_RBS = 4
MSNR_QM = 5

SELL_TYPES = (MSNR_CLASSIC_A, MSNR_RBS, MSNR_QM)


@dataclass
class MsLevel:
    price: float
    price2: float
    type: int
    tf: str
    time: int
    touch_count: int = 0
    fresh: bool = True
    active: bool = True
    strong: bool = False
    sl_wick: float = 0.0


@dataclass
class Story:
    confirmed: bool = False
    direction: int = NEUTRAL
    reject_tf: str = "D1"
    break_tf: str = "H4"
    breakout_level: float = 0.0
    targets: Tuple[float, ...] = ()
    obstacles: Tuple[float, ...] = ()
    last_liquidity_taken: bool = False


def turtle_soup(cur: dict, prev: dict) -> int:
    """Return BULL/BEAR/0 for A6.2 turtle soup."""
    if cur["low"] < prev["low"] and cur["close"] > prev["low"]:
        return BULL
    if cur["high"] > prev["high"] and cur["close"] < prev["high"]:
        return BEAR
    return 0


class MsLevels:
    def __init__(self, structure: StructureEngine, tf: str = "H4",
                 min_gap_points: float = 3.0, point: float = 0.00001,
                 qm_sl_buffer: float = 5.0, require_ts: bool = True,
                 protected_retrace_pct: float = 50.0,
                 allow_fresh_on_htf: bool = True) -> None:
        self.structure = structure
        self.tf = tf
        self.min_gap_points = float(min_gap_points)
        self.point = float(point)
        self.qm_sl_buffer = float(qm_sl_buffer)
        self.require_ts = bool(require_ts)
        self.protected_retrace_pct = float(protected_retrace_pct)
        self.allow_fresh_on_htf = bool(allow_fresh_on_htf)
        self.levels: List[MsLevel] = []

    def rebuild(self):
        self.levels = []
        bars = self.structure.bars
        for i in range(1, len(bars)):
            prev, cur = bars[i - 1], bars[i]
            prev_bull = prev["close"] > prev["open"]
            cur_bear = cur["close"] < cur["open"]
            prev_bear = prev["close"] < prev["open"]
            cur_bull = cur["close"] > cur["open"]

            classic_v = prev_bear and cur_bull and cur["close"] > prev["open"]
            classic_a = prev_bull and cur_bear and cur["close"] < prev["open"]
            if classic_v:
                self._add(prev["close"], prev["close"], MSNR_CLASSIC_V,
                          prev["time"], prev["low"])
            elif classic_a:
                self._add(prev["close"], prev["close"], MSNR_CLASSIC_A,
                          prev["time"], prev["high"])
            elif abs(cur["open"] - prev["close"]) >= self.min_gap_points * self.point:
                self._add(prev["close"], cur["open"], MSNR_OCL, prev["time"])
        self._flips_strength()
        self._quasimodo()

    def _add(self, price, price2, ltype, time, sl_wick=0.0):
        self.levels.append(MsLevel(price=price, price2=price2, type=ltype,
                                   tf=self.tf, time=time, sl_wick=sl_wick))

    def _origin(self, time: int) -> int:
        for i, b in enumerate(self.structure.bars):
            if b["time"] == time:
                return i
        return -1

    def _flips_strength(self):
        bars = self.structure.bars
        for l in self.levels:
            origin = self._origin(l.time)
            for i in range(origin + 1, len(bars)):
                b = bars[i]
                if i > 0:
                    ts = turtle_soup(b, bars[i - 1])
                    same = (l.type == MSNR_CLASSIC_V and ts == BULL) or \
                           (l.type == MSNR_CLASSIC_A and ts == BEAR)
                    if same:
                        l.strong = True
                buy_level = l.type in (MSNR_CLASSIC_V, MSNR_SBR)
                through = (b["close"] < l.price) if buy_level \
                    else (b["close"] > l.price)
                if through:
                    if l.type == MSNR_CLASSIC_V:
                        l.type = MSNR_SBR
                    elif l.type == MSNR_CLASSIC_A:
                        l.type = MSNR_RBS
                    l.touch_count = 0
                    l.fresh = True
                if b["low"] <= l.price <= b["high"]:
                    l.touch_count += 1
                    l.fresh = False

    def _quasimodo(self):
        bars = self.structure.bars
        rbs = [l for l in self.levels if l.type == MSNR_RBS]
        for l in rbs:
            origin = self._origin(l.time)
            if any(b["close"] < l.price for b in bars[origin + 1:]):
                q = MsLevel(price=l.price, price2=l.price, type=MSNR_QM,
                            tf=self.tf, time=l.time, sl_wick=l.sl_wick,
                            strong=l.strong)
                self.levels.append(q)

    def usable(self, l: MsLevel, higher: Optional["MsLevels"] = None) -> bool:
        fresh_ok = l.fresh
        if not fresh_ok and self.allow_fresh_on_htf and higher is not None:
            fresh_ok = any(h.fresh and h.active and abs(h.price - l.price) <= self.point
                           for h in higher.levels)
        if not fresh_ok or not l.active:
            return False
        if self.require_ts and not l.strong:
            return False
        return True

    def fresh_key_level(self, direction: int,
                        higher: Optional["MsLevels"] = None) -> Optional[MsLevel]:
        for l in self.levels:
            if not self.usable(l, higher):
                continue
            sell = l.type in SELL_TYPES
            if direction == BEAR and not sell:
                continue
            if direction == BULL and sell:
                continue
            return l
        return None


def _rejected_at(s: StructureEngine, level: float) -> int:
    n = len(s.bars)
    for i in range(max(0, n - 3), n):
        b = s.bars[i]
        if b["high"] > level and b["close"] < level:
            return BEAR
        if b["low"] < level and b["close"] > level:
            return BULL
    return NEUTRAL


def _breakout_on(s: StructureEngine, direction: int) -> bool:
    if not s.bos_events:
        return False
    b = s.bos_events[-1]
    if b.direction != direction:
        return False
    last = s.bars[-1]
    return (last["close"] > b.swing_price) if direction == BULL \
        else (last["close"] < b.swing_price)


def _ordered_levels(eng: Optional[MsLevels], price: float,
                    direction: int, ahead_only: bool, cap: int) -> List[float]:
    if eng is None:
        return []
    out = []
    for l in eng.levels:
        if not l.active or not l.fresh:
            continue
        ahead = (l.price > price) if direction == BULL else (l.price < price)
        if ahead_only and not ahead:
            continue
        out.append(l.price)
    out.sort(key=lambda p: abs(p - price))
    return out[:cap]


def evaluate_story(mn1, w1, d1, h4, lmn1, lw1, ld1, price) -> Story:
    """A7.1 state machine. Highest TF that confirms wins."""
    st = Story()
    for reject_s, reject_l, break_s, rtf, btf in (
        (mn1, lmn1, w1, "MN1", "W1"),
        (w1, lw1, d1, "W1", "D1"),
        (d1, ld1, h4, "D1", "H4"),
    ):
        if reject_s is None or reject_l is None or not reject_l.levels:
            continue
        level = reject_l.levels[0].price
        direction = _rejected_at(reject_s, level)
        if direction == NEUTRAL:
            continue
        if break_s is not None:
            if not _breakout_on(break_s, direction):
                continue
            st.confirmed = True
        st.direction = direction
        st.reject_tf = rtf
        st.break_tf = btf
        if st.confirmed:
            break

    if not st.confirmed:
        return st

    targets = _ordered_levels(ld1, price, st.direction, True, 3)
    if len(targets) < 3:
        targets += _ordered_levels(lw1, price, st.direction, True, 3 - len(targets))
    if len(targets) < 3:
        targets += _ordered_levels(lmn1, price, st.direction, True, 3 - len(targets))
    obstacles = _ordered_levels(ld1, price, st.direction, False, 8)
    st.targets = tuple(targets)
    st.obstacles = tuple(obstacles)
    ref = mn1 if st.reject_tf == "MN1" else (w1 if st.reject_tf == "W1" else d1)
    tol = 0.0005
    if ref is not None:
        liq = ref.count_equal_levels(st.direction == BULL, price, tol, True)
        st.last_liquidity_taken = (liq == 0)
    return st


def setup_m_score(st: Story, lv: MsLevel, liq_beyond: bool,
                  ht_overlap: bool, inducement: bool) -> int:
    s = 0
    s += bool(st.confirmed)
    s += bool(lv.strong)
    s += bool(lv.fresh)
    s += bool(st.last_liquidity_taken)
    s += bool(liq_beyond)
    s += bool(ht_overlap)
    s += bool(inducement)
    return int(s)
