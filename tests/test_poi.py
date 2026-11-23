import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))

from smc_engine import BULL, BEAR, NEUTRAL, StructureEngine  # noqa: E402
from smc_poi import (  # noqa: E402
    LVL_RES, LVL_SUP, POI_BREAKER, POI_FVG, POI_ORDER_BLOCK, POI_WICK,
    Poi, PoiEngine, BiasEngine,
)

T0 = 1_700_000_000

# A bearish BOS requires a confirmed swing low first. This series builds:
#   bar1  bullish candle 1.1020/1.1000  -> bearish OB candidate
#   bar3  swing low 1.0970 (confirmed at bar4)
#   bar5  close 1.0950 < 1.0970         -> bearish BOS
BEAR_BOS = [
    (1.1000, 1.0990, 1.1000),
    (1.1020, 1.1000, 1.1015),
    (1.1015, 1.0990, 1.1000),
    (1.1010, 1.0970, 1.0975),
    (1.0990, 1.0975, 1.0965),
    (1.0980, 1.0965, 1.0950),
]

BULL_BOS = [(2.30 - l, 2.30 - h, 2.30 - c) for h, l, c in BEAR_BOS]

TREND_BARS = [
    (1.1000, 1.0990, 1.0995), (1.1020, 1.1000, 1.1010),
    (1.1015, 1.0990, 1.1000), (1.1035, 1.0995, 1.1015),
    (1.1030, 1.1000, 1.1005), (1.1020, 1.0968, 1.0970),
    (1.0980, 1.0960, 1.0975), (1.0990, 1.0970, 1.0980),
    (1.0975, 1.0960, 1.0965), (1.0970, 1.0940, 1.0945),
    (1.0950, 1.0930, 1.0940), (1.0955, 1.0935, 1.0948),
    (1.0952, 1.0938, 1.0940), (1.0960, 1.0940, 1.0958),
    (1.0995, 1.0955, 1.0992),
]


def make(hlc):
    t = T0
    prev = None
    out = []
    for h, l, c in hlc:
        o = prev if prev is not None else c
        out.append({"time": t, "open": o, "high": h, "low": l, "close": c})
        prev = c
        t += 900
    return out


def engine_with(hlc, **kw):
    e = StructureEngine(**kw)
    for b in make(hlc):
        e.push_bar(b["time"], b["open"], b["high"], b["low"], b["close"])
    return e


class TestPoiDetection(unittest.TestCase):
    def test_order_block_after_bearish_bos(self):
        eng = engine_with(BEAR_BOS)
        self.assertGreater(len(eng.bos_events), 0)
        poi = PoiEngine(eng)
        poi.rebuild()
        obs = [p for p in poi.pois if p.type == POI_ORDER_BLOCK
               and p.level_type == LVL_RES]
        self.assertTrue(obs)
        self.assertAlmostEqual(obs[0].top, 1.1020)
        self.assertAlmostEqual(obs[0].bottom, 1.1000)

    def test_bullish_order_block_mirror(self):
        eng = engine_with(BULL_BOS)
        poi = PoiEngine(eng)
        poi.rebuild()
        obs = [p for p in poi.pois if p.type == POI_ORDER_BLOCK
               and p.level_type == LVL_SUP]
        self.assertTrue(obs)

    def test_fvg_gap_detected(self):
        eng = engine_with([
            (1.1000, 1.0990, 1.0995),
            (1.1005, 1.0995, 1.1000),
            (1.1015, 1.1010, 1.1012),
        ])
        poi = PoiEngine(eng)
        poi.rebuild()
        gaps = [p for p in poi.pois if p.type == POI_FVG]
        self.assertTrue(gaps)
        self.assertAlmostEqual(gaps[0].bottom, 1.1000)
        self.assertAlmostEqual(gaps[0].top, 1.1010)

    def test_wick_rejection_requires_prev_extreme(self):
        eng = engine_with([
            (1.1000, 1.0990, 1.0995),
            (1.1030, 1.0985, 1.0990),
            (1.1025, 1.1000, 1.1015),
        ])
        poi = PoiEngine(eng, min_wick_ratio=0.5)
        poi.rebuild()
        wicks = [p for p in poi.pois
                 if p.type == POI_WICK and p.level_type == LVL_RES]
        self.assertTrue(wicks)
        self.assertAlmostEqual(wicks[0].top, 1.1030)

    def test_body_only_option(self):
        base = engine_with(BEAR_BOS)
        p1 = PoiEngine(base, ob_body_only=False)
        p1.rebuild()
        p2 = PoiEngine(base, ob_body_only=True)
        p2.rebuild()
        ob1 = [p for p in p1.pois if p.type == POI_ORDER_BLOCK][0]
        ob2 = [p for p in p2.pois if p.type == POI_ORDER_BLOCK][0]
        self.assertGreater(ob1.height, ob2.height)


class TestMitigation(unittest.TestCase):
    def test_zone_mitigated_when_price_enters(self):
        hlc = BEAR_BOS + [(1.1010, 1.0995, 1.1005)]
        poi = PoiEngine(engine_with(hlc))
        poi.rebuild()
        ob = [p for p in poi.pois if p.type == POI_ORDER_BLOCK]
        self.assertTrue(ob)
        self.assertTrue(ob[0].mitigated)

    def test_breaker_flips_direction(self):
        hlc = BEAR_BOS + [(1.1045, 1.1000, 1.1035)]
        poi = PoiEngine(engine_with(hlc))
        poi.rebuild()
        p = [q for q in poi.pois if q.type == POI_BREAKER]
        self.assertTrue(p)
        self.assertEqual(p[0].level_type, LVL_SUP)
        self.assertEqual(p[0].flipped_from, LVL_RES)


class TestBias(unittest.TestCase):
    def test_d1_confirmed_overrides_h4(self):
        d1 = engine_with(TREND_BARS)
        h4 = StructureEngine()
        b = BiasEngine(d1=d1, h4=h4)
        self.assertEqual(b.compute(1.0980), BEAR)
        self.assertEqual(b.range_tf, "D1")

    def test_weekly_agreement_gate(self):
        d1 = engine_with(TREND_BARS)
        w1 = engine_with([(2.30 - l, 2.30 - h, 2.30 - c)
                          for h, l, c in TREND_BARS])
        b = BiasEngine(w1=w1, d1=d1, use_weekly=True,
                       require_weekly_agree=True)
        b.refresh_weekly()
        self.assertEqual(b.weekly_dir, BULL)
        self.assertEqual(b.compute(1.0980), NEUTRAL)

    def test_counter_bias_zone(self):
        d1 = engine_with(TREND_BARS)
        h4 = StructureEngine()
        pe = PoiEngine(h4, tf="H4")
        pe.pois.append(Poi(1.0960, 1.0950, POI_ORDER_BLOCK, LVL_SUP,
                           "H4", T0, 1))
        b = BiasEngine(d1=d1, h4=h4, h4poi=pe)
        self.assertEqual(b.compute(1.0955), BEAR)
        self.assertTrue(b.counter_bias_zone)


if __name__ == "__main__":
    unittest.main(verbosity=2)
