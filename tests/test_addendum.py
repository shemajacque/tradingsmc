import os
import sys
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))

from smc_engine import BULL, BEAR, NEUTRAL, Range, StructureEngine  # noqa: E402
from smc_poi import LVL_RES, LVL_SUP  # noqa: E402
from smc_addendum import (  # noqa: E402
    DAY_CONSOLIDATING, DAY_NEWS, DAY_STRONG_HIGH, DAY_STRONG_LOW,
    DAY_TRENDING, CloseLevelEngine, RangeExpansion, classify_day,
)

T0 = 1_700_000_000
CLOSES = [1.1000, 1.1010, 1.1000, 1.0990, 1.1000,
          1.1005, 1.1000, 1.0995, 1.0990, 1.1000]

STRONG_BASE = [
    (1.1000, 1.0990, 1.0995), (1.1020, 1.1000, 1.1010),
    (1.1015, 1.0990, 1.1000), (1.1010, 1.0975, 1.0980),
    (1.1005, 1.0985, 1.0995), (1.1035, 1.0995, 1.1015),
    (1.1030, 1.1000, 1.1005), (1.1020, 1.0968, 1.0970),
]


def from_closes(closes, pad=0.0001):
    t = T0
    prev = None
    rows = []
    for c in closes:
        o = c
        rows.append((c + pad, c - pad, c))
        t += 900
    return rows


def engine(series, **kw):
    e = StructureEngine(**kw)
    t = T0
    prev = None
    for h, l, c in series:
        o = prev if prev is not None else c
        e.push_bar(t, o, h, l, c)
        prev = c
        t += 900
    return e


def levels(tf="H4", closes=None, **kw):
    e = engine(from_closes(closes or CLOSES))
    eng = CloseLevelEngine(e, tf=tf, **kw)
    eng.rebuild()
    return eng


class TestCloseLevels(unittest.TestCase):
    def test_closing_peaks_and_troughs(self):
        eng = levels()
        res = [round(l.price, 5) for l in eng.levels if l.type == LVL_RES]
        sup = [round(l.price, 5) for l in eng.levels if l.type == LVL_SUP]
        self.assertIn(1.1010, res)
        self.assertIn(1.1005, res)
        self.assertIn(1.0990, sup)

    def test_min_level_tf_blocks_low_tfs(self):
        eng = levels(tf="M5", min_tf="M15")
        self.assertEqual(eng.levels, [])

    def test_freshness(self):
        eng = levels()
        l = [x for x in eng.levels if round(x.price, 5) == 1.1010][0]
        self.assertTrue(l.fresh)
        self.assertEqual(l.touch_count, 0)
        # a later candle spanning the level marks it used
        l2 = close_level_with_touch(1.1010)
        self.assertFalse(l2.fresh)
        self.assertGreater(l2.touch_count, 0)

    def test_sbr_rbs_flip_by_body_close(self):
        closes = CLOSES + [1.1030]
        eng = levels(closes=closes)
        flipped = [l for l in eng.levels if l.broken]
        self.assertTrue(flipped)
        self.assertEqual(flipped[0].flipped_from, LVL_RES)
        self.assertEqual(flipped[0].type, LVL_SUP)

    def test_wick_only_break_does_not_flip(self):
        closes = list(CLOSES)
        e = engine(from_closes(closes))
        eng = CloseLevelEngine(e, tf="H4", body_close_break=True)
        eng.rebuild()
        l = [x for x in eng.levels if round(x.price, 5) == 1.1010][0]
        self.assertFalse(l.broken)

    def test_direction_filter(self):
        eng = levels()
        best = eng.best_level(BEAR, 1.1010, 0.0005)
        self.assertIsNotNone(best)
        self.assertEqual(best.type, LVL_RES)
        best_buy = eng.best_level(BULL, 1.0990, 0.0005)
        self.assertIsNotNone(best_buy)
        self.assertEqual(best_buy.type, LVL_SUP)

    def test_htf_priority_and_conflict(self):
        h4 = levels(tf="H4")
        h1 = levels(tf="H1")
        h1.htf_conflict_tol = 0.0010
        low = [x for x in h1.levels if x.type == LVL_SUP][0]
        # opposing H4 resistance near the same price -> conflict
        h4.levels[0].price = low.price
        h4.levels[0].type = LVL_RES
        self.assertTrue(low.price == h4.levels[0].price)

    def test_top_bottom_rule(self):
        eng = levels()
        pair = eng.two_close_levels(BEAR, 1.1010, 0.0010)
        self.assertIsNotNone(pair)
        self.assertEqual(pair[0].type, LVL_RES)
        self.assertEqual(pair[1].type, LVL_RES)
        self.assertGreater(pair[0].price, pair[1].price)

    def test_refinement_distance(self):
        h4 = levels(tf="H4")
        l = [x for x in h4.levels if x.type == LVL_RES][0]
        h4.max_refine_dist = 0.0005
        near = CloseLevelEngine(engine(from_closes(CLOSES)), tf="H1")
        near.rebuild()
        near.levels = near.levels[:1]
        near.levels[0].price = l.price + 0.0002
        near.levels[0].type = LVL_RES
        near.levels[0].fresh = True
        self.assertIsNotNone(h4.refine(l, near))
        far = CloseLevelEngine(engine(from_closes(CLOSES)), tf="H1")
        far.rebuild()
        far.levels = far.levels[:1]
        far.levels[0].price = l.price + 0.0050
        far.levels[0].type = LVL_RES
        far.levels[0].fresh = True
        self.assertIsNone(h4.refine(l, far))


def close_level_with_touch(level_price):
    closes = list(CLOSES)
    e = engine(from_closes(closes))
    eng = CloseLevelEngine(e, tf="H4")
    eng.rebuild()
    l = [x for x in eng.levels if round(x.price, 5) == 1.1010][0]
    # simulate a candle spanning the level
    e.push_bar(T0 + 10000, level_price - 0.0005,
               level_price + 0.0005, level_price - 0.0005, level_price)
    eng.rebuild()
    l = [x for x in eng.levels if round(x.price, 5) == 1.1010][0]
    return l


class TestDayType(unittest.TestCase):
    def test_news_overrides(self):
        asia = types.SimpleNamespace(efficiency=0.9, high_strong=True,
                                     low_strong=True)
        self.assertEqual(classify_day(asia, True, 0.65), DAY_NEWS)

    def test_trending(self):
        asia = types.SimpleNamespace(efficiency=0.9, high_strong=True,
                                     low_strong=True)
        self.assertEqual(classify_day(asia, False, 0.65), DAY_TRENDING)

    def test_strong_high_low(self):
        hi = types.SimpleNamespace(efficiency=0.2, high_strong=True,
                                   low_strong=False)
        lo = types.SimpleNamespace(efficiency=0.2, high_strong=False,
                                   low_strong=True)
        both = types.SimpleNamespace(efficiency=0.2, high_strong=True,
                                     low_strong=True)
        self.assertEqual(classify_day(hi, False, 0.65), DAY_STRONG_HIGH)
        self.assertEqual(classify_day(lo, False, 0.65), DAY_STRONG_LOW)
        self.assertEqual(classify_day(both, False, 0.65), DAY_TRENDING)

    def test_consolidating(self):
        asia = types.SimpleNamespace(efficiency=0.2, high_strong=False,
                                     low_strong=False)
        self.assertEqual(classify_day(asia, False, 0.65), DAY_CONSOLIDATING)


class TestRangeExpansion(unittest.TestCase):
    def test_bearish_expansion_and_gate(self):
        e = engine(STRONG_BASE)
        self.assertIsNotNone(e.strong_high)
        self.assertEqual(e.bos_events[-1].direction, BEAR)
        rx = RangeExpansion()
        rx.update(e)
        self.assertTrue(rx.expansion_bear)
        self.assertFalse(rx.allow(BULL))
        self.assertTrue(rx.allow(BEAR))

    def test_reset_on_broken_range(self):
        e = engine(STRONG_BASE)
        rx = RangeExpansion()
        rx.update(e)
        self.assertTrue(rx.expansion_bear)
        e.ranges.append(Range(direction=BEAR, rh=1.1035, rl=1.0968))
        e.ranges[-1].broken = True
        rx.update(e)
        self.assertFalse(rx.expansion_bear)


if __name__ == "__main__":
    unittest.main(verbosity=2)
