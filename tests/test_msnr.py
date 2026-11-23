import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))

from smc_engine import BULL, BEAR, NEUTRAL, StructureEngine  # noqa: E402
from msnr import (  # noqa: E402
    MSNR_CLASSIC_A, MSNR_CLASSIC_V, MSNR_OCL, MSNR_QM, MSNR_RBS,
    MsLevel, MsLevels, Story, evaluate_story, setup_m_score,
    turtle_soup, _ordered_levels,
)

T0 = 1_700_000_000


def engine(ohlcs):
    e = StructureEngine()
    t = T0
    for o, h, l, c in ohlcs:
        e.push_bar(t, o, h, l, c)
        t += 900
    return e


def lv(levels, tf="H4", **kw):
    e = engine([(1.1000, 1.1005, 1.0995, 1.1000)])
    m = MsLevels(e, tf=tf, **kw)
    m.rebuild()
    m.levels = list(levels)
    return m


class TestMsLevels(unittest.TestCase):
    def test_classic_v(self):
        e = engine([
            (1.1000, 1.1010, 1.0980, 1.0990),
            (1.0985, 1.1020, 1.0985, 1.1015),
        ])
        m = MsLevels(e, tf="H4", require_ts=False)
        m.rebuild()
        vs = [l for l in m.levels if l.type == MSNR_CLASSIC_V]
        self.assertTrue(vs)
        self.assertAlmostEqual(vs[0].price, 1.0990)
        self.assertAlmostEqual(vs[0].sl_wick, 1.0980)

    def test_classic_a(self):
        e = engine([
            (1.0990, 1.1010, 1.0985, 1.1005),
            (1.1008, 1.1020, 1.0990, 1.0985),
        ])
        m = MsLevels(e, tf="H4", require_ts=False)
        m.rebuild()
        aa = [l for l in m.levels if l.type == MSNR_CLASSIC_A]
        self.assertTrue(aa)
        self.assertAlmostEqual(aa[0].price, 1.1005)
        self.assertAlmostEqual(aa[0].sl_wick, 1.1010)

    def test_ocl_when_no_engulf(self):
        e = engine([
            (1.1000, 1.1005, 1.0995, 1.1000),
            (1.1010, 1.1015, 1.1005, 1.1012),
        ])
        m = MsLevels(e, tf="H4", min_gap_points=3, point=0.0001,
                     require_ts=False)
        m.rebuild()
        gaps = [l for l in m.levels if l.type == MSNR_OCL]
        self.assertTrue(gaps)
        self.assertAlmostEqual(gaps[0].price, 1.1000)
        self.assertAlmostEqual(gaps[0].price2, 1.1010)

    def test_turtle_soup(self):
        prev = {"low": 1.0990, "high": 1.1010, "close": 1.1000}
        bull = {"low": 1.0985, "high": 1.1005, "close": 1.0995}
        bear = {"low": 1.0995, "high": 1.1015, "close": 1.1005}
        self.assertEqual(turtle_soup(bull, prev), BULL)
        self.assertEqual(turtle_soup(bear, prev), BEAR)
        flat = {"low": 1.0995, "high": 1.1005, "close": 1.1000}
        self.assertEqual(turtle_soup(flat, prev), 0)

    def test_qm_sequence(self):
        e = engine([
            (1.0990, 1.1010, 1.0985, 1.1005),   # bullish -> Classic A base
            (1.1008, 1.1020, 1.0990, 1.0985),   # bearish engulf -> Classic A
            (1.0988, 1.1018, 1.0988, 1.1012),   # body close > level -> RBS
            (1.1010, 1.1015, 1.0985, 1.0990),   # RBS broken -> QM
        ])
        m = MsLevels(e, tf="H4", require_ts=False)
        m.rebuild()
        qm = [l for l in m.levels if l.type == MSNR_QM]
        self.assertTrue(qm)
        self.assertAlmostEqual(qm[0].price, 1.1005)

    def test_fresh_key_level_requires_ts(self):
        l = MsLevel(price=1.1000, price2=1.1000, type=MSNR_QM,
                    tf="H4", time=T0, strong=False)
        m = lv([l], require_ts=True)
        self.assertIsNone(m.fresh_key_level(BEAR))
        m.require_ts = False
        self.assertIsNotNone(m.fresh_key_level(BEAR))


BEAR = BEAR
BEAR_BOS = [
    (1.1000, 1.1000, 1.0990, 1.0995),
    (1.0995, 1.1020, 1.0995, 1.1015),
    (1.1015, 1.1015, 1.0990, 1.1000),
    (1.1000, 1.1010, 1.0970, 1.0975),
    (1.0975, 1.0990, 1.0975, 1.0965),
    (1.0965, 1.0980, 1.0955, 1.0950),
]


class TestStoryline(unittest.TestCase):
    def test_daily_reject_h4_break(self):
        d1_bars = list(BEAR_BOS) + [(1.0990, 1.1030, 1.0985, 1.0990)]
        h4 = engine(BEAR_BOS)
        d1 = engine(d1_bars)
        d1l = lv([MsLevel(1.1020, 1.1020, MSNR_CLASSIC_A, "D1", T0,
                          strong=True)])
        st = evaluate_story(None, None, d1, h4, None, None, d1l, 1.1000)
        self.assertTrue(st.confirmed)
        self.assertEqual(st.direction, BEAR)
        self.assertEqual(st.reject_tf, "D1")
        self.assertEqual(st.break_tf, "H4")

    def test_story_unconfirmed_without_break(self):
        d1_bars = list(BEAR_BOS) + [(1.0990, 1.1030, 1.0985, 1.0990)]
        d1 = engine(d1_bars)
        d1l = lv([MsLevel(1.1020, 1.1020, MSNR_CLASSIC_A, "D1", T0,
                          strong=True)])
        st = evaluate_story(None, None, d1, None, None, None, d1l, 1.1000)
        self.assertFalse(st.confirmed)

    def test_target_and_obstacle_ordering(self):
        levels = [
            MsLevel(1.1040, 1.1040, MSNR_CLASSIC_A, "D1", T0),
            MsLevel(1.1010, 1.1010, MSNR_CLASSIC_A, "D1", T0),
            MsLevel(1.1020, 1.1020, MSNR_CLASSIC_A, "D1", T0),
            MsLevel(1.0990, 1.0990, MSNR_CLASSIC_V, "D1", T0),
        ]
        m = lv(levels, tf="D1")
        ahead = _ordered_levels(m, 1.1000, BULL, True, 3)
        self.assertEqual(ahead, [1.1010, 1.1020, 1.1040])
        behind = _ordered_levels(m, 1.1000, BEAR, True, 3)
        self.assertEqual(behind, [1.0990])
        allv = _ordered_levels(m, 1.1000, BULL, False, 8)
        self.assertEqual(allv[0], 1.1010)

    def test_msnr_score_threshold(self):
        st = Story(confirmed=True, direction=BULL, last_liquidity_taken=True)
        strong = MsLevel(1.1, 1.1, MSNR_CLASSIC_V, "H4", T0,
                         fresh=True, strong=True)
        score = setup_m_score(st, strong, True, True, True)
        self.assertEqual(score, 7)
        weak = MsLevel(1.1, 1.1, MSNR_CLASSIC_V, "H4", T0,
                       fresh=False, strong=False)
        self.assertLess(setup_m_score(st, weak, False, False, False), 4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
