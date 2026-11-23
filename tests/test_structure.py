import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))

from smc_engine import (  # noqa: E402
    BEAR, BULL, CONFIRMED, PROVISIONAL, StructureEngine,
)

T0 = 1_700_000_000


def run(series, **kw):
    """series = [(high, low, close), ...]; open = previous close."""
    eng = StructureEngine(**kw)
    t = T0
    prev = None
    for h, l, c in series:
        o = prev if prev is not None else c
        eng.push_bar(t, o, h, l, c)
        t += 900
        prev = c
    return eng


# bars 0..7: prior swing high 1.1020, origin low 1.0975, swept swing high
# 1.1035 at bar 5 and a bearish BOS through the origin low at bar 7.
STRONG_BASE = [
    (1.1000, 1.0990, 1.0995),   # 0
    (1.1020, 1.1000, 1.1010),   # 1  swing high (confirmed at 2)
    (1.1015, 1.0990, 1.1000),   # 2
    (1.1010, 1.0975, 1.0980),   # 3  swing low  (confirmed at 4)
    (1.1005, 1.0985, 1.0995),   # 4
    (1.1035, 1.0995, 1.1015),   # 5  swept swing high (confirmed at 6)
    (1.1030, 1.1000, 1.1005),   # 6
    (1.1020, 1.0968, 1.0970),   # 7  bearish BOS through 1.0975
]

# bars 8..16: lower high 1.0990 (pivot, the high immediately before the LL),
# new LL 1.0930 at bar 12, minor break of 1.0955 at bar 15, confirmation of the
# range only at bar 16 when 1.0990 is closed above.
RANGE_TAIL = [
    (1.0980, 1.0960, 1.0975),   # 8  LL 1.0960
    (1.0990, 1.0970, 1.0980),   # 9  pivot swing high (confirmed at 10)
    (1.0975, 1.0960, 1.0965),   # 10
    (1.0970, 1.0940, 1.0945),   # 11 LL 1.0940
    (1.0950, 1.0930, 1.0940),   # 12 LL 1.0930 (range low)
    (1.0955, 1.0935, 1.0948),   # 13 lower high (confirmed at 14)
    (1.0952, 1.0938, 1.0940),   # 14
    (1.0960, 1.0940, 1.0958),   # 15 minor break of 1.0955 - must NOT confirm
    (1.0995, 1.0955, 1.0992),   # 16 close above 1.0990 -> CONFIRMED
]


class TestSwings(unittest.TestCase):
    def test_strict_fractal(self):
        eng = run(STRONG_BASE[:5])
        self.assertEqual([s.idx for s in eng.swing_highs], [1])
        self.assertEqual([s.price for s in eng.swing_highs], [1.1020])
        self.assertEqual([s.idx for s in eng.swing_lows], [3])
        self.assertEqual([s.price for s in eng.swing_lows], [1.0975])

    def test_equal_high_plateau_is_not_a_swing(self):
        bars = [
            (1.1000, 1.0990, 1.0995),
            (1.1010, 1.0995, 1.1000),
            (1.1015, 1.1000, 1.1010),
            (1.1030, 1.1005, 1.1020),
            (1.1030, 1.1010, 1.1025),
            (1.1020, 1.1000, 1.1005),
        ]
        eng = run(bars)
        self.assertEqual(eng.swing_highs, [])

    def test_swing_confirmed_only_after_next_close(self):
        bars = STRONG_BASE[:3]
        eng = run(bars)
        # bar 1 becomes a swing only when bar 2 is pushed
        eng2 = StructureEngine()
        eng2.push_bar(T0, 1.0995, 1.1000, 1.0990, 1.0995)
        eng2.push_bar(T0 + 900, 1.0995, 1.1020, 1.1000, 1.1010)
        self.assertEqual(eng2.swing_highs, [])
        eng2.push_bar(T0 + 1800, 1.1010, 1.1015, 1.0990, 1.1000)
        self.assertEqual(len(eng2.swing_highs), 1)


class TestStrongPoints(unittest.TestCase):
    def test_swept_high_plus_origin_bos_is_strong(self):
        eng = run(STRONG_BASE)
        sh = eng.strong_high
        self.assertIsNotNone(sh)
        self.assertEqual(sh.idx, 5)
        self.assertEqual(sh.price, 1.1035)
        self.assertTrue(sh.swept)
        self.assertTrue(sh.strong)
        prov = eng.provisional_range()
        self.assertIsNotNone(prov)
        self.assertEqual(prov.status, PROVISIONAL)
        self.assertEqual(prov.direction, BEAR)
        self.assertEqual(prov.rh, 1.1035)
        self.assertEqual(prov.rl, 1.0968)
        self.assertEqual(eng.bias, 0)
        self.assertEqual(len(eng.ranges), 0)

    def test_swept_high_without_bos_is_weak(self):
        series = list(STRONG_BASE)
        series[7] = (1.1020, 1.0968, 1.0990)      # close back above origin low
        eng = run(series)
        self.assertIsNone(eng.strong_high)
        sh = [s for s in eng.swing_highs if s.idx == 5][0]
        self.assertTrue(sh.swept)
        self.assertFalse(sh.strong)

    def test_unswept_high_with_bos_is_weak(self):
        series = list(STRONG_BASE)
        series[5] = (1.1015, 1.0995, 1.1015)      # does not exceed 1.1020
        series[6] = (1.1010, 1.1000, 1.1005)
        eng = run(series)
        self.assertIsNone(eng.strong_high)
        sh = [s for s in eng.swing_highs if s.idx == 5][0]
        self.assertFalse(sh.swept)
        self.assertFalse(sh.strong)

    def test_wick_bos_mode(self):
        series = list(STRONG_BASE)
        series[7] = (1.1020, 1.0968, 1.0990)      # wick only through 1.0975
        close_eng = run(series, bos_by_close=True)
        self.assertIsNone(close_eng.strong_high)
        wick_eng = run(series, bos_by_close=False)
        self.assertIsNotNone(wick_eng.strong_high)
        self.assertEqual(wick_eng.strong_high.price, 1.1035)


class TestRanges(unittest.TestCase):
    def test_minor_break_does_not_confirm(self):
        eng = run(STRONG_BASE + RANGE_TAIL[:8])   # up to bar 15
        self.assertEqual(len(eng.ranges), 0)
        self.assertEqual(eng.bias, 0)
        self.assertEqual(eng.last_bos.direction, BULL)
        self.assertEqual(eng.last_bos.swing_price, 1.0955)
        # provisional view is still available
        prov = eng.provisional_range()
        self.assertIsNotNone(prov)
        self.assertEqual(prov.rl, 1.0930)

    def test_confirmation_requires_break_of_pivot(self):
        eng = run(STRONG_BASE + RANGE_TAIL)
        self.assertEqual(len(eng.ranges), 1)
        r = eng.ranges[0]
        self.assertEqual(r.status, CONFIRMED)
        self.assertEqual(r.direction, BEAR)
        self.assertEqual(r.rh, 1.1035)
        self.assertEqual(r.rl, 1.0930)
        self.assertEqual(r.rh_idx, 5)
        self.assertEqual(r.rl_idx, 12)
        self.assertAlmostEqual(r.eq, (1.1035 + 1.0930) / 2)
        self.assertEqual(eng.bias, BEAR)
        self.assertTrue(eng.bias_valid)
        # the confirming bullish break also creates a mirror (bullish)
        # candidate on the same bar - that is expected by section 4.5/4.4
        prov = eng.provisional_range()
        self.assertTrue(prov is None or prov.direction == BULL)

    def test_irl_marked_taken_by_confirmation_break(self):
        eng = run(STRONG_BASE + RANGE_TAIL)
        r = eng.ranges[0]
        self.assertEqual(r.irl_price, 1.0990)
        self.assertEqual(r.irl_idx, 9)
        self.assertTrue(r.irl_taken)

    def test_premium_discount_and_extreme(self):
        eng = run(STRONG_BASE + RANGE_TAIL)
        r = eng.ranges[0]
        self.assertTrue(r.in_premium(1.1000))
        self.assertTrue(r.in_discount(1.0950))
        self.assertEqual(eng.range_zone(1.1030), "EXTREME_PREMIUM")
        self.assertEqual(eng.range_zone(1.0940), "EXTREME_DISCOUNT")
        self.assertEqual(eng.range_zone(1.1000), "PREMIUM")
        self.assertTrue(eng.extreme_zone(1.1030))
        self.assertFalse(eng.extreme_zone(1.1000))

    def test_bullish_range_is_mirror(self):
        K = 2.0
        mirror = [(K - l, K - h, K - c)
                  for (h, l, c) in STRONG_BASE + RANGE_TAIL]
        eng = run(mirror)
        self.assertEqual(len(eng.ranges), 1)
        r = eng.ranges[0]
        self.assertEqual(r.direction, BULL)
        self.assertAlmostEqual(r.rl, K - 1.1035)
        self.assertAlmostEqual(r.rh, K - 1.0930)
        self.assertAlmostEqual(r.irl_price, K - 1.0990)
        self.assertEqual(eng.bias, BULL)
        self.assertIsNotNone(eng.strong_low)
        self.assertAlmostEqual(eng.strong_low.price, K - 1.1035)

    def test_liquidity_helpers(self):
        eng = run(STRONG_BASE + RANGE_TAIL)
        n = eng.count_equal_levels(is_high=False, price=1.0931, tol=0.0002)
        self.assertEqual(n, 1)
        self.assertEqual(eng.count_equal_levels(is_high=False, price=1.0931,
                                                tol=0.0002, only_beyond=False), 1)
        self.assertGreaterEqual(len(eng.swings_inside(eng.ranges[0], False)), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
