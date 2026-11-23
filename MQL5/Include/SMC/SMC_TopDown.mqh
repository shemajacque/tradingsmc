//+------------------------------------------------------------------+
//|  SMC_TopDown.mqh                                                 |
//|  ADDENDUM A2 (top-down routine) and A4 (range-expansion state).    |
//|                                                                  |
//|  Scheduled tasks: MN1, W1, D1 new-bar and each KZ start. Results   |
//|  feed the bias engine as additional inputs.                       |
//+------------------------------------------------------------------+
#ifndef SMC_TOPDOWN_MQH
#define SMC_TOPDOWN_MQH

#include "SMC_Types.mqh"
#include "SMC_Structure.mqh"
#include "SMC_CloseLevel.mqh"

struct SMC_TopDownState
{
   int               monthlyDir;
   int               weeklyDir;
   double            monthlyNextAbove;
   double            monthlyNextBelow;
   double            weeklyNextAbove;
   double            weeklyNextBelow;
   ENUM_TIMEFRAMES   rangeTF;
   bool              expansionBear;
   bool              expansionBull;
   bool              weeklyAgree;
};

class CTopDown
{
private:
   CStructure*       m_mn1;
   CStructure*       m_w1;
   CStructure*       m_d1;
   CStructure*       m_h4;
   CCloseLevelEngine* m_mn1Lvl;
   CCloseLevelEngine* m_w1Lvl;
   CCloseLevelEngine* m_d1Lvl;
   CCloseLevelEngine* m_h4Lvl;
   bool              m_requireWeeklyAgree;
   int               m_counterBreakTf;  // SAME or ONE_LOWER
   SMC_TopDownState  m_st;

   int DirOf(CStructure* s)
   {
      if(s == NULL)
         return SMC_NEUTRAL;
      SMC_Range r;
      if(s.GetLastRange(r) && r.status == SMC_RANGE_CONFIRMED && !r.broken)
         return r.dir;
      return s.Bias();
   }

   void NearestLevels(CCloseLevelEngine* eng, const double price,
                      double &above, double &below)
   {
      above = 0.0;
      below = 0.0;
      if(eng == NULL)
         return;
      double da = 1e18, db = 1e18;
      for(int i = 0; i < eng.Count(); i++)
      {
         SMC_Level l;
         if(!eng.Get(i, l) || !l.active || !l.fresh)
            continue;
         if(l.price > price && l.price - price < da)
         {
            da = l.price - price;
            above = l.price;
         }
         if(l.price < price && price - l.price < db)
         {
            db = price - l.price;
            below = l.price;
         }
      }
   }

public:
   void Init(CStructure* mn1, CStructure* w1, CStructure* d1, CStructure* h4,
             CCloseLevelEngine* lmn1, CCloseLevelEngine* lw1,
             CCloseLevelEngine* ld1, CCloseLevelEngine* lh4,
             const bool requireWeeklyAgree, const int counterBreakTf)
   {
      m_mn1 = mn1; m_w1 = w1; m_d1 = d1; m_h4 = h4;
      m_mn1Lvl = lmn1; m_w1Lvl = lw1; m_d1Lvl = ld1; m_h4Lvl = lh4;
      m_requireWeeklyAgree = requireWeeklyAgree;
      m_counterBreakTf = counterBreakTf;
      Reset();
   }

   void Reset()
   {
      m_st.monthlyDir = SMC_NEUTRAL;
      m_st.weeklyDir = SMC_NEUTRAL;
      m_st.monthlyNextAbove = 0.0;
      m_st.monthlyNextBelow = 0.0;
      m_st.weeklyNextAbove = 0.0;
      m_st.weeklyNextBelow = 0.0;
      m_st.rangeTF = PERIOD_H4;
      m_st.expansionBear = false;
      m_st.expansionBull = false;
      m_st.weeklyAgree = true;
   }

   void OnMonthlyBar(const double price)
   {
      m_st.monthlyDir = DirOf(m_mn1);
      NearestLevels(m_mn1Lvl, price,
                    m_st.monthlyNextAbove, m_st.monthlyNextBelow);
   }

   void OnWeeklyBar(const double price)
   {
      m_st.weeklyDir = DirOf(m_w1);
      NearestLevels(m_w1Lvl, price,
                    m_st.weeklyNextAbove, m_st.weeklyNextBelow);
   }

   // A2 daily task: use D1 range if a strong point + confirmed range exists
   // in the direction of weeklyDir, otherwise use H4.
   void OnDailyBar()
   {
      bool useD1 = false;
      if(m_d1 != NULL)
      {
         SMC_Range r;
         bool haveR = m_d1.GetLastRange(r);
         bool strongOk = false;
         if(m_st.weeklyDir == SMC_BEAR)
         {
            SMC_Swing sh;
            strongOk = (m_d1.GetStrongHigh(sh) && !sh.invalidated);
         }
         else if(m_st.weeklyDir == SMC_BULL)
         {
            SMC_Swing sl;
            strongOk = (m_d1.GetStrongLow(sl) && !sl.invalidated);
         }
         useD1 = haveR && r.status == SMC_RANGE_CONFIRMED && !r.broken &&
                 (m_st.weeklyDir == SMC_NEUTRAL || r.dir == m_st.weeklyDir) &&
                 strongOk;
      }
      m_st.rangeTF = useD1 ? PERIOD_D1 : PERIOD_H4;
      m_st.weeklyAgree = (!m_requireWeeklyAgree ||
                          m_st.weeklyDir == SMC_NEUTRAL ||
                          DirOf(m_st.rangeTF == PERIOD_D1 ? m_d1 : m_h4)
                          == m_st.weeklyDir);
   }

   int DirOf(const ENUM_TIMEFRAMES tf)
   {
      return DirOf(tf == PERIOD_D1 ? m_d1 :
                   (tf == PERIOD_W1 ? m_w1 :
                    (tf == PERIOD_H4 ? m_h4 : m_mn1)));
   }

   // A4: expansion is set when price taps a higher-TF POI and then produces a
   // strong high / bearish BOS (mirror for bullish) on the range TF or one TF
   // lower. Called on every new bar of the relevant TF.
   void UpdateExpansion()
   {
      CStructure* rng = (m_st.rangeTF == PERIOD_D1) ? m_d1 : m_h4;
      if(rng == NULL)
         return;

      // reset on range invalidation or a new opposite range
      SMC_Range r;
      if(rng.GetLastRange(r))
      {
         if(r.broken)
         {
            m_st.expansionBear = false;
            m_st.expansionBull = false;
         }
         if(r.dir == SMC_BEAR)
            m_st.expansionBull = false;
         else if(r.dir == SMC_BULL)
            m_st.expansionBear = false;
      }

      CStructure* probe = rng;
      if(m_counterBreakTf == COUNTER_ONE_LOWER)
         probe = (m_st.rangeTF == PERIOD_D1) ? m_h4 : NULL;
      if(probe == NULL)
         return;

      SMC_Swing sh, sl;
      if(probe.GetStrongHigh(sh) && !sh.invalidated &&
         probe.BosCount() > 0)
      {
         SMC_Bos b;
         probe.GetBosAt(probe.BosCount() - 1, b);
         if(b.dir == SMC_BEAR)
            m_st.expansionBear = true;
      }
      if(probe.GetStrongLow(sl) && !sl.invalidated &&
         probe.BosCount() > 0)
      {
         SMC_Bos b;
         probe.GetBosAt(probe.BosCount() - 1, b);
         if(b.dir == SMC_BULL)
            m_st.expansionBull = true;
      }
   }

   bool AllowDirection(const int dir) const
   {
      if(m_st.expansionBear && dir == SMC_BULL)
         return false;
      if(m_st.expansionBull && dir == SMC_BEAR)
         return false;
      return true;
   }

   SMC_TopDownState State() const { return m_st; }
};

#endif // SMC_TOPDOWN_MQH
