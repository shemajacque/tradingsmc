"""
smc_time.py
===========
New-York session / DST model, mirror of ``MQL5/Include/SMC/SMC_Time.mqh``.

All times inside the bot are handled in **New York time** and converted from
broker server time at the boundary.  US DST rule (since 2007):

* starts 2nd Sunday of March, 02:00 local standard time = 07:00 UTC
* ends   1st Sunday of November, 02:00 local daylight time = 06:00 UTC

The broker server offset is configured with a winter/summer pair and a DST
mode.  ``"US"`` is the default (most FX brokers shift with the US), but ``"EU"``
(last Sunday March 01:00 UTC -> last Sunday October 01:00 UTC) is provided
because EET brokers are common.  Documented assumption: within a DST mode the
server switches at the same instants as that region's clocks.
"""

from __future__ import annotations

import datetime as dt
from dataclasses import dataclass
from typing import Optional, Tuple

DST_NONE = "NONE"
DST_US = "US"
DST_EU = "EU"


def nth_weekday(year: int, month: int, weekday: int, n: int) -> dt.date:
    """weekday: Monday=0.  n: 1-based (1st, 2nd ...)."""
    d = dt.date(year, month, 1)
    shift = (weekday - d.weekday()) % 7
    return d + dt.timedelta(days=shift + 7 * (n - 1))


def last_weekday(year: int, month: int, weekday: int) -> dt.date:
    d = dt.date(year, month, 1)
    nxt = dt.date(year + (month == 12), month % 12 + 1, 1)
    last = nxt - dt.timedelta(days=1)
    return last - dt.timedelta(days=(last.weekday() - weekday) % 7)


def us_dst_utc_bounds(year: int) -> Tuple[dt.datetime, dt.datetime]:
    start = dt.datetime.combine(nth_weekday(year, 3, 6, 2), dt.time(7, 0))
    end = dt.datetime.combine(nth_weekday(year, 11, 6, 1), dt.time(6, 0))
    return start, end


def eu_dst_utc_bounds(year: int) -> Tuple[dt.datetime, dt.datetime]:
    start = dt.datetime.combine(last_weekday(year, 3, 6), dt.time(1, 0))
    end = dt.datetime.combine(last_weekday(year, 10, 6), dt.time(1, 0))
    return start, end


def _in_bounds(utc: dt.datetime, bounds: Tuple[dt.datetime, dt.datetime]) -> bool:
    return bounds[0] <= utc < bounds[1]


def is_us_dst(utc: dt.datetime) -> bool:
    return _in_bounds(utc, us_dst_utc_bounds(utc.year))


def is_eu_dst(utc: dt.datetime) -> bool:
    return _in_bounds(utc, eu_dst_utc_bounds(utc.year))


def ny_offset(utc: dt.datetime) -> dt.timedelta:
    """UTC offset of New York at the given UTC instant."""
    return dt.timedelta(hours=-4 if is_us_dst(utc) else -5)


def dst_active(utc: dt.datetime, mode: str) -> bool:
    if mode == DST_EU:
        return is_eu_dst(utc)
    if mode == DST_US:
        return is_us_dst(utc)
    return False


# ---------------------------------------------------------------------------
# sessions
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class Session:
    name: str
    start_min: int          # minutes after NY midnight
    end_min: int            # exclusive; may wrap past midnight

    @property
    def wraps(self) -> bool:
        return self.start_min > self.end_min

    def contains_minutes(self, minutes: int) -> bool:
        m = minutes % 1440
        if self.wraps:
            return m >= self.start_min or m < self.end_min
        return self.start_min <= m < self.end_min

    def contains_grace(self, minutes: int, grace_min: int) -> bool:
        """Inside the session, or within ``grace_min`` after its end."""
        m = minutes % 1440
        if self.contains_minutes(m):
            return True
        if grace_min <= 0:
            return False
        return ((m - self.end_min) % 1440) < grace_min


ASIA_ICT = Session("ASIA", 17 * 60, 0)
ASIA_STANDARD = Session("ASIA_STD", 19 * 60, 0)
LONDON_KZ = Session("LONDON_KZ", 2 * 60, 5 * 60)
NY_KZ = Session("NY_KZ", 7 * 60, 10 * 60)
LONDON_OPEN = Session("LONDON_OPEN", 3 * 60, 3 * 60 + 1)
NY_OPEN = Session("NY_OPEN", 8 * 60, 8 * 60 + 1)


def session_window_ny(day: dt.date, s: Session) -> Tuple[dt.datetime, dt.datetime]:
    """Absolute NY window for a session that *ends* on ``day``.

    For the Asia box this returns [previous day 17:00, day 00:00).
    """
    end = dt.datetime.combine(day, dt.time(s.end_min // 60, s.end_min % 60))
    start = dt.datetime.combine(day, dt.time(s.start_min // 60, s.start_min % 60))
    if s.wraps:
        start -= dt.timedelta(days=1)
    return start, end


class TimeEngine:
    """Server <-> NY conversion plus session helpers."""

    def __init__(
        self,
        winter_offset_hours: float = 2.0,
        summer_offset_hours: float = 3.0,
        server_dst_mode: str = DST_US,
    ) -> None:
        self.winter = winter_offset_hours
        self.summer = summer_offset_hours
        self.mode = server_dst_mode

    # -- offsets -----------------------------------------------------------
    def server_offset(self, utc: dt.datetime) -> dt.timedelta:
        h = self.summer if dst_active(utc, self.mode) else self.winter
        return dt.timedelta(hours=h)

    def server_to_ny(self, server: dt.datetime) -> dt.datetime:
        if server.tzinfo is not None:
            server = server.replace(tzinfo=None)   # broker wall clock
        off = dt.timedelta(hours=self.winter)
        utc = server - off
        for _ in range(4):
            new_off = self.server_offset(utc)
            new_utc = server - new_off
            if new_utc == utc:
                break
            off, utc = new_off, new_utc
        return utc + ny_offset(utc)

    def ny_to_server(self, ny: dt.datetime) -> dt.datetime:
        if ny.tzinfo is not None:
            ny = ny.replace(tzinfo=None)
        off = dt.timedelta(hours=-5)
        utc = ny - off
        for _ in range(4):
            new_off = ny_offset(utc)
            new_utc = ny - new_off
            if new_utc == utc:
                break
            off, utc = new_off, new_utc
        return utc + self.server_offset(utc)

    # -- convenience -------------------------------------------------------
    @staticmethod
    def minutes_of_day(ny: dt.datetime) -> int:
        return ny.hour * 60 + ny.minute

    def in_session(self, ny: dt.datetime, s: Session) -> bool:
        return s.contains_minutes(self.minutes_of_day(ny))

    def in_asia(self, ny: dt.datetime, standard: bool = False) -> bool:
        return self.in_session(ny, ASIA_STANDARD if standard else ASIA_ICT)

    def in_kill_zone(self, ny: dt.datetime, grace_min: int = 0) -> Optional[str]:
        """'LONDON' / 'NEW_YORK' / None."""
        m = self.minutes_of_day(ny)
        if LONDON_KZ.contains_grace(m, grace_min):
            return "LONDON"
        if NY_KZ.contains_grace(m, grace_min):
            return "NEW_YORK"
        return None

    def in_entry_window(self, ny: dt.datetime, grace_min: int = 30,
                        no_asia: bool = True) -> bool:
        if no_asia and self.in_asia(ny):
            return False
        return self.in_kill_zone(ny, grace_min) is not None

    @staticmethod
    def is_friday(ny: dt.datetime) -> bool:
        return ny.weekday() == 4

    @staticmethod
    def is_monday(ny: dt.datetime) -> bool:
        return ny.weekday() == 0

    @staticmethod
    def after_friday_cutoff(ny: dt.datetime, cutoff_hour: int = 12) -> bool:
        return ny.weekday() == 4 and (ny.hour * 60 + ny.minute) >= cutoff_hour * 60

    @staticmethod
    def before_hard_close(ny: dt.datetime, close_hour: int = 16) -> bool:
        return ny.hour * 60 + ny.minute < close_hour * 60

    def asia_box_bars(self, bar_ny_times, day: dt.date,
                      standard: bool = False):
        """Filter of M15 bar *open* times belonging to the Asia box of ``day``."""
        s = ASIA_STANDARD if standard else ASIA_ICT
        start, end = session_window_ny(day, s)
        return [t for t in bar_ny_times if start <= t < end]
