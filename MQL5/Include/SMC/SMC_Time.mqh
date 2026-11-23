//+------------------------------------------------------------------+
//|  SMC_Time.mqh                                                    |
//|  New-York session / DST model for the SMC bot (section 3).       |
//|                                                                  |
//|  Everything downstream works in *New York time*; broker server   |
//|  time is converted once per timestamp.                           |
//|                                                                  |
//|  US DST (since 2007): 2nd Sunday March 07:00 UTC ->              |
//|                      1st Sunday November 06:00 UTC               |
//|  EU DST:             last Sunday March 01:00 UTC ->               |
//|                      last Sunday October 01:00 UTC               |
//|                                                                  |
//|  Assumption: the broker server changes its offset at the same    |
//|  instants as the selected DST mode (US by default, EU available  |
//|  for EET brokers).  In live trading InpAutoServerOffset samples  |
//|  TimeTradeServer()-TimeGMT() and is refreshed daily, which makes |
//|  the assumption unnecessary.  Auto mode is disabled inside the   |
//|  Strategy Tester (manual offsets are used there).                |
//+------------------------------------------------------------------+
#ifndef SMC_TIME_MQH
#define SMC_TIME_MQH

#include "SMC_Types.mqh"

class CTimeEngine
{
private:
   bool              m_auto;
   int               m_winterSec;
   int               m_summerSec;
   int               m_dstMode;
   int               m_autoOffsetSec;
   datetime          m_lastRefresh;

   static datetime MakeTime(const int y, const int mo, const int d,
                            const int h, const int mi, const int s)
   {
      MqlDateTime st;
      st.year = y;
      st.mon  = mo;
      st.day  = d;
      st.hour = h;
      st.min  = mi;
      st.sec  = s;
      st.day_of_week = 0;
      st.day_of_year = 0;
      return StructToTime(st);
   }

public:
   void Init(const bool autoDetect, const double winterHours,
             const double summerHours, const int dstMode)
   {
      m_auto         = autoDetect;
      m_winterSec    = (int)MathRound(winterHours * 3600.0);
      m_summerSec    = (int)MathRound(summerHours * 3600.0);
      m_dstMode      = dstMode;
      m_autoOffsetSec = 0;
      m_lastRefresh  = 0;
      // The tester has no reliable GMT source: force manual offsets there.
      if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
         m_auto = false;
      RefreshAuto();
   }

   // Re-sample the broker offset (call once per day from OnTimer).
   void RefreshAuto()
   {
      if(!m_auto)
         return;
      datetime now = TimeTradeServer();
      if(m_lastRefresh > 0 && (now - m_lastRefresh) < 3600)
         return;
      m_lastRefresh = now;
      int off = (int)MathRound((double)(TimeTradeServer() - TimeGMT()) / 900.0) * 900;
      // 90 min is far outside any real broker offset; reject garbage
      if(off > -14 * 3600 && off < 14 * 3600)
         m_autoOffsetSec = off;
   }

   bool AutoMode()
   {
      return m_auto;
   }

   int WinterOffsetSec()
   {
      return m_winterSec;
   }

   int SummerOffsetSec()
   {
      return m_summerSec;
   }

   //--- DST calendar ------------------------------------------------
   static datetime NthSundayUTC(const int year, const int month,
                                const int nth, const int hourUTC)
   {
      datetime first = MakeTime(year, month, 1, 0, 0, 0);
      MqlDateTime st;
      TimeToStruct(first, st);                    // day_of_week: 0 = Sunday
      int day = 1 + ((7 - st.day_of_week) % 7) + 7 * (nth - 1);
      return MakeTime(year, month, day, hourUTC, 0, 0);
   }

   static datetime LastSundayUTC(const int year, const int month,
                                 const int hourUTC)
   {
      int y = year;
      int m = month + 1;
      if(m > 12)
      {
         m = 1;
         y++;
      }
      datetime lastDay = MakeTime(y, m, 1, 0, 0, 0) - 86400;
      MqlDateTime st;
      TimeToStruct(lastDay, st);
      int day = st.day - st.day_of_week;
      return MakeTime(year, month, day, hourUTC, 0, 0);
   }

   static bool IsUsDst(const datetime utc)
   {
      MqlDateTime st;
      TimeToStruct(utc, st);
      datetime start = NthSundayUTC(st.year, 3, 2, 7);
      datetime end   = NthSundayUTC(st.year, 11, 1, 6);
      return (utc >= start && utc < end);
   }

   static bool IsEuDst(const datetime utc)
   {
      MqlDateTime st;
      TimeToStruct(utc, st);
      datetime start = LastSundayUTC(st.year, 3, 1);
      datetime end   = LastSundayUTC(st.year, 10, 1);
      return (utc >= start && utc < end);
   }

   static int NYOffsetSec(const datetime utc)
   {
      return IsUsDst(utc) ? -4 * 3600 : -5 * 3600;
   }

   //--- server offset ------------------------------------------------
   int ServerOffsetSec(const datetime utc)
   {
      if(m_auto)
         return m_autoOffsetSec;
      bool dst = false;
      if(m_dstMode == SMC_DST_EU)
         dst = IsEuDst(utc);
      else if(m_dstMode == SMC_DST_US)
         dst = IsUsDst(utc);
      return dst ? m_summerSec : m_winterSec;
   }

   //--- conversions --------------------------------------------------
   datetime ToNY(const datetime serverTime)
   {
      int off = ServerOffsetSec(serverTime - m_winterSec);
      for(int k = 0; k < 4; k++)
      {
         datetime utc = serverTime - off;
         int no = ServerOffsetSec(utc);
         if(no == off)
            break;
         off = no;
      }
      datetime utc2 = serverTime - off;
      return utc2 + NYOffsetSec(utc2);
   }

   datetime ToServer(const datetime nyTime)
   {
      int off = -5 * 3600;
      for(int k = 0; k < 4; k++)
      {
         datetime utc = nyTime - off;
         int no = NYOffsetSec(utc);
         if(no == off)
            break;
         off = no;
      }
      datetime utc2 = nyTime - off;
      return utc2 + ServerOffsetSec(utc2);
   }

   //--- calendar helpers ---------------------------------------------
   static int MinutesOfDay(const datetime t)
   {
      MqlDateTime st;
      TimeToStruct(t, st);
      return st.hour * 60 + st.min;
   }

   static datetime StartOfDay(const datetime t)
   {
      MqlDateTime st;
      TimeToStruct(t, st);
      st.hour = 0;
      st.min  = 0;
      st.sec  = 0;
      return StructToTime(st);
   }

   static int DayOfWeek(const datetime t)
   {
      MqlDateTime st;
      TimeToStruct(t, st);
      return st.day_of_week;                       // 0 = Sunday
   }

   static bool IsFriday(const datetime t)
   {
      return (DayOfWeek(t) == 5);
   }

   static bool IsMonday(const datetime t)
   {
      return (DayOfWeek(t) == 1);
   }

   //--- session presets ---------------------------------------------
   static SMC_Session SessionAsia(const bool standard)
   {
      SMC_Session s;
      s.name     = standard ? "ASIA_STD" : "ASIA";
      s.startMin = standard ? 19 * 60 : 17 * 60;
      s.endMin   = 0;
      return s;
   }

   static SMC_Session SessionLondonKZ()
   {
      SMC_Session s;
      s.name     = "LONDON_KZ";
      s.startMin = 2 * 60;
      s.endMin   = 5 * 60;
      return s;
   }

   static SMC_Session SessionNYKZ()
   {
      SMC_Session s;
      s.name     = "NY_KZ";
      s.startMin = 7 * 60;
      s.endMin   = 10 * 60;
      return s;
   }

   static SMC_Session SessionLondonOpen()
   {
      SMC_Session s;
      s.name     = "LONDON_OPEN";
      s.startMin = 3 * 60;
      s.endMin   = 3 * 60 + 1;
      return s;
   }

   static SMC_Session SessionNYOpen()
   {
      SMC_Session s;
      s.name     = "NY_OPEN";
      s.startMin = 8 * 60;
      s.endMin   = 8 * 60 + 1;
      return s;
   }

   //--- queries -------------------------------------------------------
   bool InSession(const datetime ny, SMC_Session &s)
   {
      return s.Contains(MinutesOfDay(ny));
   }

   bool InAsia(const datetime ny, const bool standard)
   {
      SMC_Session s = SessionAsia(standard);
      return InSession(ny, s);
   }

   // "LONDON" / "NEW_YORK" / "" (section 3)
   string KillZone(const datetime ny, const int graceMin)
   {
      int m = MinutesOfDay(ny);
      SMC_Session lkz = SessionLondonKZ();
      if(lkz.ContainsGrace(m, graceMin))
         return "LONDON";
      SMC_Session nkz = SessionNYKZ();
      if(nkz.ContainsGrace(m, graceMin))
         return "NEW_YORK";
      return "";
   }

   bool InEntryWindow(const datetime ny, const int graceMin, const bool noAsia)
   {
      if(noAsia && InAsia(ny, false))
         return false;
      return (KillZone(ny, graceMin) != "");
   }

   bool AfterFridayCutoff(const datetime ny, const int cutoffHour)
   {
      return (IsFriday(ny) && MinutesOfDay(ny) >= cutoffHour * 60);
   }

   bool BeforeHardClose(const datetime ny, const int closeHour)
   {
      return (MinutesOfDay(ny) < closeHour * 60);
   }

   //--- Asia box absolute NY window for the day that ENDS at midnight ---
   static datetime AsiaBoxStart(const datetime nyDayMidnight, const bool standard)
   {
      int startMin = standard ? 19 * 60 : 17 * 60;
      return nyDayMidnight - 86400 + startMin * 60;
   }

   static datetime AsiaBoxEnd(const datetime nyDayMidnight)
   {
      return nyDayMidnight;
   }
};

#endif // SMC_TIME_MQH
