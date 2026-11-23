//+------------------------------------------------------------------+
//|  SMC_Bias.mqh                                                    |
//|  Multi-timeframe bias engine (section 6) plus the HTF-POI lookup   |
//|  used for confluence (6.5) and counter-bias-zone detection (6.6).  |
//|                                                                  |
//|  Rule order is fixed and documented in Compute():                 |
//|    D1 confirmed range . H4 confirmed range . NEUTRAL.            |
//|  An optional W1 override (6.4) is evaluated on Sunday/Monday open  |
//|  and persists for the week (addendum A2).                          |
//+------------------------------------------------------------------+
#ifndef SMC_BIAS_MQH
#define SMC_BIAS_MQH

#include "SMC_Types.mqh"
#include "SMC_Structure.mqh"
#include "SMC_POI.mqh"

class CBiasEngine
{
private:
   CStructure*       m_w1;
   CStructure*       m_d1;
   CStructure*       m_h4;
   CStructure*       m_h1;
   CPOIEngine*       m_w1Poi;
   CPOIEngine*       m_d1Poi;
   CPOIEngine*       m_h4Poi;
   CPOIEngine*       m_h1Poi;

   bool              m_useWeekly;
   bool              m_requireWeeklyAgree;
   double            m_htfConflictTol;    // A1.7

   int               m_bias;
   bool              m_counterBiasZone;
   int               m_weeklyDir;
   datetime          m_weeklyDirTime;

   ENUM_TIMEFRAMES   m_rangeTF;           // selected by the top-down task

   bool ConfirmedDir(CStructure* s, int &dir)
   {
      if(s == NULL)
         return false;
      SMC_Range r;
      if(!s.GetLastRange(r))
         return false;
      if(r.status != SMC_RANGE_CONFIRMED || r.broken)
         return false;
      dir = r.dir;
      return true;
   }

   // 6.6: price inside an HTF POI that trades AGAINST the bias.
   bool InOpposingHtfZone(const double price, const int bias)
   {
      int want = (bias == SMC_BEAR) ? LVL_RES : LVL_SUP;
      CPOIEngine* engines[4];
      engines[0] = m_w1Poi;
      engines[1] = m_d1Poi;
      engines[2] = m_h4Poi;
      engines[3] = m_h1Poi;
      for(int e = 0; e < 4; e++)
      {
         CPOIEngine* eng = engines[e];
         if(eng == NULL)
            continue;
         // A bearish bias is contradicted by price sitting in a SUPPORT (buy)
         // zone; a bullish bias by price sitting in a RESISTANCE (sell) zone.
         int opposing = (bias == SMC_BEAR) ? LVL_SUP : LVL_RES;
         for(int i = 0; i < eng.Count(); i++)
         {
            SMC_POI p;
            if(!eng.Get(i, p) || p.mitigated || !p.active)
               continue;
            if((int)p.levelType != opposing)
               continue;
            if(price >= p.bottom && price <= p.top)
               return true;
         }
      }
      return false;
   }

public:
   void Init(CStructure* w1, CStructure* d1, CStructure* h4, CStructure* h1,
             CPOIEngine* w1p, CPOIEngine* d1p, CPOIEngine* h4p, CPOIEngine* h1p,
             const bool useWeekly, const bool requireWeeklyAgree,
             const double htfConflictTol)
   {
      m_w1 = w1; m_d1 = d1; m_h4 = h4; m_h1 = h1;
      m_w1Poi = w1p; m_d1Poi = d1p; m_h4Poi = h4p; m_h1Poi = h1p;
      m_useWeekly = useWeekly;
      m_requireWeeklyAgree = requireWeeklyAgree;
      m_htfConflictTol = htfConflictTol;
      m_bias = SMC_NEUTRAL;
      m_counterBiasZone = false;
      m_weeklyDir = SMC_NEUTRAL;
      m_weeklyDirTime = 0;
      m_rangeTF = PERIOD_H1;
   }

   // Section 6.4 / A2: refresh the weekly break direction. The caller should
   // invoke this only on a new W1 bar (Sunday/Monday open).
   void RefreshWeekly()
   {
      if(!m_useWeekly || m_w1 == NULL)
         return;
      int d = SMC_NEUTRAL;
      if(ConfirmedDir(m_w1, d) || m_w1.Bias() != SMC_NEUTRAL)
      {
         m_weeklyDir = (d != SMC_NEUTRAL) ? d : m_w1.Bias();
         m_weeklyDirTime = TimeCurrent();
      }
   }

   int Compute(const double price)
   {
      int d1 = SMC_NEUTRAL;
      bool haveD1 = ConfirmedDir(m_d1, d1);

      if(haveD1)
      {
         m_bias = d1;
         m_rangeTF = PERIOD_D1;
      }
      else
      {
         int h4 = SMC_NEUTRAL;
         bool haveH4 = ConfirmedDir(m_h4, h4);
         if(haveH4)
         {
            m_bias = h4;
            m_rangeTF = PERIOD_H4;
         }
         else
         {
            m_bias = SMC_NEUTRAL;
            // Fall back to a valid strong point on H4 (section 6 step 2).
            SMC_Swing sh, sl;
            if(m_h4 != NULL)
            {
               if(m_h4.GetStrongHigh(sh) && !sh.invalidated)
                  m_bias = SMC_BEAR;
               else if(m_h4.GetStrongLow(sl) && !sl.invalidated)
                  m_bias = SMC_BULL;
            }
            m_rangeTF = PERIOD_H4;
         }
      }

      // 6.4: weekly override, persisted for the week.
      if(m_useWeekly && m_weeklyDir != SMC_NEUTRAL)
      {
         if(m_requireWeeklyAgree)
         {
            if(m_bias != SMC_NEUTRAL && m_bias != m_weeklyDir)
               m_bias = SMC_NEUTRAL;   // explicit counter setups only
            else if(m_bias == SMC_NEUTRAL)
               m_bias = m_weeklyDir;
         }
         else
         {
            m_bias = m_weeklyDir;
         }
      }

      m_counterBiasZone = InOpposingHtfZone(price, m_bias);
      return m_bias;
   }

   // 6.5: does an entry zone overlap any HTF (D1/H4/H1, optionally W1) POI?
   bool OverlapsHtfPoi(const double top, const double bottom,
                       const int dir, int &count)
   {
      count = 0;
      CPOIEngine* engines[4];
      engines[0] = m_w1Poi;
      engines[1] = m_d1Poi;
      engines[2] = m_h4Poi;
      engines[3] = m_h1Poi;
      int want = (dir == SMC_BEAR) ? LVL_RES : LVL_SUP;
      for(int e = 0; e < 4; e++)
      {
         CPOIEngine* eng = engines[e];
         if(eng == NULL)
            continue;
         for(int i = 0; i < eng.Count(); i++)
         {
            SMC_POI p;
            if(!eng.Get(i, p) || p.mitigated || !p.active)
               continue;
            if((int)p.levelType != want)
               continue;
            bool overlap = (bottom <= p.top && top >= p.bottom) ||
                           (bottom - m_htfConflictTol <= p.top &&
                            top + m_htfConflictTol >= p.bottom);
            if(overlap)
               count++;
         }
      }
      return (count > 0);
   }

   // A1.7: reject a lower-TF level sitting beneath a stronger opposing HTF one.
   bool HasOpposingHtfConflict(const double price, const int dir)
   {
      int opposing = (dir == SMC_BEAR) ? LVL_SUP : LVL_RES;
      CPOIEngine* engines[3];
      engines[0] = m_w1Poi;
      engines[1] = m_d1Poi;
      engines[2] = m_h4Poi;
      for(int e = 0; e < 3; e++)
      {
         CPOIEngine* eng = engines[e];
         if(eng == NULL)
            continue;
         for(int i = 0; i < eng.Count(); i++)
         {
            SMC_POI p;
            if(!eng.Get(i, p) || !p.active)
               continue;
            if((int)p.levelType != opposing)
               continue;
            if(MathAbs(price - (p.top + p.bottom) / 2.0) <= m_htfConflictTol)
               return true;
         }
      }
      return false;
   }

   int Bias() const { return m_bias; }
   bool CounterBiasZone() const { return m_counterBiasZone; }
   int WeeklyDir() const { return m_weeklyDir; }
   ENUM_TIMEFRAMES RangeTF() const { return m_rangeTF; }
   void SetRangeTF(const ENUM_TIMEFRAMES tf) { m_rangeTF = tf; }
};

#endif // SMC_BIAS_MQH
