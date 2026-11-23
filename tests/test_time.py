import datetime as dt
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "python"))

import smc_time as T  # noqa: E402

D = dt.datetime


class TestDST(unittest.TestCase):
    def test_us_dst_spring_2024(self):
        self.assertFalse(T.is_us_dst(D(2024, 3, 10, 6, 59)))
        self.assertTrue(T.is_us_dst(D(2024, 3, 10, 7, 0)))
        self.assertEqual(T.ny_offset(D(2024, 3, 10, 6, 59)),
                         dt.timedelta(hours=-5))
        self.assertEqual(T.ny_offset(D(2024, 3, 10, 7, 0)),
                         dt.timedelta(hours=-4))

    def test_us_dst_autumn_2024(self):
        self.assertTrue(T.is_us_dst(D(2024, 11, 3, 5, 59)))
        self.assertFalse(T.is_us_dst(D(2024, 11, 3, 6, 0)))
        self.assertEqual(T.ny_offset(D(2024, 11, 3, 5, 59)),
                         dt.timedelta(hours=-4))
        self.assertEqual(T.ny_offset(D(2024, 11, 3, 6, 0)),
                         dt.timedelta(hours=-5))

    def test_eu_dst_bounds_2024(self):
        # last Sunday of March 2024 = 31 Mar 01:00 UTC
        self.assertFalse(T.is_eu_dst(D(2024, 3, 31, 0, 59)))
        self.assertTrue(T.is_eu_dst(D(2024, 3, 31, 1, 0)))
        # last Sunday of October 2024 = 27 Oct 01:00 UTC
        self.assertTrue(T.is_eu_dst(D(2024, 10, 27, 0, 59)))
        self.assertFalse(T.is_eu_dst(D(2024, 10, 27, 1, 0)))

    def test_nth_sunday(self):
        self.assertEqual(T.nth_weekday(2024, 3, 6, 2), dt.date(2024, 3, 10))
        self.assertEqual(T.nth_weekday(2026, 3, 6, 2), dt.date(2026, 3, 8))
        self.assertEqual(T.nth_weekday(2024, 11, 6, 1), dt.date(2024, 11, 3))


class TestServerConversion(unittest.TestCase):
    def setUp(self):
        # EU-shifting broker: +2 winter / +3 summer
        self.te = T.TimeEngine(2, 3, T.DST_EU)

    def test_us_dst_mismatch_with_eu_server(self):
        # 15 Mar: US DST already on, EU not yet -> server +2, NY -4 = -6h
        ny = self.te.server_to_ny(D(2024, 3, 15, 12, 0))
        self.assertEqual(ny, D(2024, 3, 15, 6, 0))
        # 15 Jul: server +3, NY -4 -> -7h
        ny = self.te.server_to_ny(D(2024, 7, 15, 12, 0))
        self.assertEqual(ny, D(2024, 7, 15, 5, 0))
        # 15 Jan: server +2, NY -5 -> -7h
        ny = self.te.server_to_ny(D(2024, 1, 15, 12, 0))
        self.assertEqual(ny, D(2024, 1, 15, 5, 0))
        # 15 Apr: server +3, NY -4 -> -7h
        ny = self.te.server_to_ny(D(2024, 4, 15, 12, 0))
        self.assertEqual(ny, D(2024, 4, 15, 5, 0))

    def test_us_server_same_offset_all_year(self):
        te = T.TimeEngine(2, 3, T.DST_US)
        self.assertEqual(te.server_to_ny(D(2024, 1, 15, 12, 0)),
                         D(2024, 1, 15, 5, 0))
        self.assertEqual(te.server_to_ny(D(2024, 7, 15, 12, 0)),
                         D(2024, 7, 15, 5, 0))

    def test_round_trip_noon(self):
        for day in (D(2024, 3, 9, 12), D(2024, 3, 10, 12),
                    D(2024, 3, 11, 12), D(2024, 11, 2, 12),
                    D(2024, 11, 3, 12), D(2024, 11, 4, 12)):
            ny = self.te.server_to_ny(day)
            back = self.te.ny_to_server(ny)
            self.assertEqual(back, day, msg=f"failure at {day}")

    def test_ny_to_server_asia_box(self):
        # Asia box of 2024-07-16 NY starts 17:00 on the 15th = 00:00 server
        te = T.TimeEngine(2, 3, T.DST_EU)
        start, end = T.session_window_ny(dt.date(2024, 7, 16), T.ASIA_ICT)
        self.assertEqual(start, D(2024, 7, 15, 17, 0))
        self.assertEqual(end, D(2024, 7, 16, 0, 0))
        self.assertEqual(te.ny_to_server(start), D(2024, 7, 16, 0, 0))
        self.assertEqual(te.ny_to_server(end), D(2024, 7, 16, 7, 0))


class TestSessions(unittest.TestCase):
    def setUp(self):
        self.te = T.TimeEngine(2, 3, T.DST_US)

    def test_asia_boundaries(self):
        s = T.ASIA_ICT
        self.assertFalse(s.contains_minutes(16 * 60 + 59))
        self.assertTrue(s.contains_minutes(17 * 60))
        self.assertTrue(s.contains_minutes(23 * 60 + 59))
        self.assertFalse(s.contains_minutes(0))
        self.assertFalse(s.contains_minutes(1))
        self.assertTrue(T.ASIA_STANDARD.contains_minutes(19 * 60))
        self.assertFalse(T.ASIA_STANDARD.contains_minutes(18 * 60 + 59))

    def test_kill_zones(self):
        ny = lambda h, m: D(2024, 7, 16, h, m)  # noqa: E731
        self.assertIsNone(self.te.in_kill_zone(ny(1, 59)))
        self.assertEqual(self.te.in_kill_zone(ny(2, 0)), "LONDON")
        self.assertEqual(self.te.in_kill_zone(ny(4, 59)), "LONDON")
        self.assertIsNone(self.te.in_kill_zone(ny(5, 0)))
        self.assertEqual(self.te.in_kill_zone(ny(7, 0)), "NEW_YORK")
        self.assertEqual(self.te.in_kill_zone(ny(9, 59)), "NEW_YORK")
        self.assertIsNone(self.te.in_kill_zone(ny(10, 0)))

    def test_kill_zone_grace(self):
        ny = lambda h, m: D(2024, 7, 16, h, m)  # noqa: E731
        self.assertIsNone(self.te.in_kill_zone(ny(5, 0)))
        self.assertEqual(self.te.in_kill_zone(ny(5, 0), 30), "LONDON")
        self.assertEqual(self.te.in_kill_zone(ny(5, 29), 30), "LONDON")
        self.assertIsNone(self.te.in_kill_zone(ny(5, 30), 30))
        self.assertEqual(self.te.in_kill_zone(ny(10, 10), 30), "NEW_YORK")

    def test_no_entry_in_asia(self):
        self.assertFalse(self.te.in_entry_window(D(2024, 7, 16, 18, 0)))
        self.assertTrue(self.te.in_entry_window(D(2024, 7, 16, 3, 0)))
        self.assertTrue(self.te.in_entry_window(D(2024, 7, 16, 8, 0)))

    def test_weekday_helpers(self):
        fri = D(2024, 7, 19, 12, 30)
        self.assertTrue(T.TimeEngine.is_friday(fri))
        self.assertTrue(T.TimeEngine.after_friday_cutoff(fri, 12))
        self.assertFalse(T.TimeEngine.after_friday_cutoff(fri, 13))
        self.assertTrue(T.TimeEngine.is_monday(D(2024, 7, 22, 9, 0)))

    def test_asia_box_filter(self):
        day = dt.date(2024, 7, 16)
        starts = [D(2024, 7, 15, 16, 45), D(2024, 7, 15, 17, 0),
                  D(2024, 7, 15, 23, 45), D(2024, 7, 16, 0, 0)]
        got = self.te.asia_box_bars(starts, day)
        self.assertEqual(got, [starts[1], starts[2]])


if __name__ == "__main__":
    unittest.main(verbosity=2)
