//+------------------------------------------------------------------+
//|  SMC_Structure.mqh                                               |
//|  Market-structure engine, sections 4.1 - 4.8. One instance per   |
//|  symbol/timeframe. Mirrors python/smc_engine.py 1:1.              |
//|                                                                  |
//|  Feed only CLOSED bars: Update() pulls M15/H1/... rates and      |
//|  intentionally skips the newest (forming) bar, so nothing        |
//|  repaints.  PushBar() is public for unit tests / CSV replay.     |
//+------------------------------------------------------------------+
#ifndef SMC_STRUCTURE_MQH
#define SMC_STRUCTURE_MQH

#include "SMC_Types.mqh"

class CStructure
{
private:
   //--- configuration
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_swingLen;
   bool              m_bosByClose;
   double            m_equalTolAtr;
   int               m_atrPeriod;
   int               m_rangeHistory;
   bool              m_invalidateByClose;

   //--- data
   MqlRates          m_rates[];
   double            m_atr[];
   SMC_Swing         m_highs[];
   SMC_Swing         m_lows[];
   SMC_Bos           m_bos[];
   SMC_Range         m_ranges[];
   int               m_rangeCount;
   SMC_RangeCandidate m_cand;
   bool              m_candActive;

   int               m_strongHighIdx;   // index into m_highs, -1 = none
   int               m_strongLowIdx;    // index into m_lows,  -1 = none
   bool              m_hasStrongHigh;
   bool              m_hasStrongLow;

   datetime          m_lastProcessed;

   //--- external liquidity (section 4.3 c)
   bool              m_hasAsiaHigh;
   bool              m_hasAsiaLow;
   bool              m_hasPdh;
   bool              m_hasPdl;
   double            m_asiaHigh;
   double            m_asiaLow;
   double            m_pdh;
   double            m_pdl;

   //--- bar accessors ------------------------------------------------
   double BarHigh(const int i)
   {
      if(i < 0 || i >= ArraySize(m_rates))
         return 0.0;
      return m_rates[i].high;
   }
   double BarLow(const int i)
   {
      if(i < 0 || i >= ArraySize(m_rates))
         return 0.0;
      return m_rates[i].low;
   }
   double BarClose(const int i)
   {
      if(i < 0 || i >= ArraySize(m_rates))
         return 0.0;
      return m_rates[i].close;
   }
   datetime BarTime(const int i)
   {
      if(i < 0 || i >= ArraySize(m_rates))
         return 0;
      return m_rates[i].time;
   }

   double CalcAtr(const int i)
   {
      int n = MathMin(i + 1, m_atrPeriod);
      if(n <= 1)
         return (m_rates[i].high - m_rates[i].low);
      double sum = 0.0;
      for(int k = i - n + 1; k <= i; k++)
      {
         double tr;
         if(k == 0)
            tr = m_rates[k].high - m_rates[k].low;
         else
         {
            double pc = m_rates[k - 1].close;
            tr = MathMax(m_rates[k].high - m_rates[k].low,
                         MathMax(MathAbs(m_rates[k].high - pc),
                                 MathAbs(m_rates[k].low - pc)));
         }
         sum += tr;
      }
      return sum / (double)n;
   }

   //--- 4.3 sweep detection (evaluated once, when the swing confirms) --
   bool IsSweepHigh(const double price, const double atr, const int priors)
   {
      if(priors > 0 && price > m_highs[priors - 1].price)
         return true;
      double tol = m_equalTolAtr * atr;
      for(int k = 0; k < priors; k++)
      {
         if(price >= m_highs[k].price && MathAbs(price - m_highs[k].price) <= tol)
            return true;
      }
      if(m_hasAsiaHigh && price > m_asiaHigh)
         return true;
      if(m_hasPdh && price > m_pdh)
         return true;
      return false;
   }

   bool IsSweepLow(const double price, const double atr, const int priors)
   {
      if(priors > 0 && price < m_lows[priors - 1].price)
         return true;
      double tol = m_equalTolAtr * atr;
      for(int k = 0; k < priors; k++)
      {
         if(price <= m_lows[k].price && MathAbs(price - m_lows[k].price) <= tol)
            return true;
      }
      if(m_hasAsiaLow && price < m_asiaLow)
         return true;
      if(m_hasPdl && price < m_pdl)
         return true;
      return false;
   }

   //--- 4.1 swing detection ------------------------------------------
   void DetectSwing(const int i)
   {
      int L = m_swingLen;
      int center = i - L;
      if(center - L < 0)
         return;
      double cHigh = m_rates[center].high;
      double cLow  = m_rates[center].low;
      bool isHigh = true;
      for(int k = center - L; k < center; k++)
         if(!(cHigh > m_rates[k].high))
            isHigh = false;
      for(int k = center + 1; k <= i; k++)
         if(!(cHigh > m_rates[k].high))
            isHigh = false;

      if(isHigh)
      {
         SMC_Swing sw;
         sw.idx           = center;
         sw.time          = m_rates[center].time;
         sw.price         = cHigh;
         sw.isHigh        = true;
         sw.broken        = false;
         sw.brokenTime    = 0;
         sw.brokenByWick  = false;
         sw.swept         = false;
         sw.strong        = false;
         sw.invalidated   = false;
         sw.originIdx     = -1;
         sw.originPrice   = 0.0;
         int nHigh = ArraySize(m_highs);
         if(ArraySize(m_lows) > 0)
         {
            int li = ArraySize(m_lows) - 1;
            if(m_lows[li].idx < center)
            {
               sw.originIdx   = m_lows[li].idx;
               sw.originPrice = m_lows[li].price;
            }
         }
         sw.swept = IsSweepHigh(cHigh, m_atr[center], nHigh);
         ArrayResize(m_highs, nHigh + 1);
         m_highs[nHigh] = sw;
      }

      bool isLow = true;
      for(int k = center - L; k < center; k++)
         if(!(cLow < m_rates[k].low))
            isLow = false;
      for(int k = center + 1; k <= i; k++)
         if(!(cLow < m_rates[k].low))
            isLow = false;

      if(isLow)
      {
         SMC_Swing sw;
         sw.idx           = center;
         sw.time          = m_rates[center].time;
         sw.price         = cLow;
         sw.isHigh        = false;
         sw.broken        = false;
         sw.brokenTime    = 0;
         sw.brokenByWick  = false;
         sw.swept         = false;
         sw.strong        = false;
         sw.invalidated   = false;
         sw.originIdx     = -1;
         sw.originPrice   = 0.0;
         int nLow = ArraySize(m_lows);
         if(ArraySize(m_highs) > 0)
         {
            int hi = ArraySize(m_highs) - 1;
            if(m_highs[hi].idx < center)
            {
               sw.originIdx   = m_highs[hi].idx;
               sw.originPrice = m_highs[hi].price;
            }
         }
         sw.swept = IsSweepLow(cLow, m_atr[center], nLow);
         ArrayResize(m_lows, nLow + 1);
         m_lows[nLow] = sw;
      }
   }

   //--- 4.2 BOS -------------------------------------------------------
   void AppendBos(SMC_Bos &ev)
   {
      int n = ArraySize(m_bos);
      ArrayResize(m_bos, n + 1);
      m_bos[n] = ev;
   }

   void ProcessBreaks(const int i)
   {
      datetime bt = m_rates[i].time;

      // bullish: close (or wick) above the most recent unbroken swing high
      double val = m_bosByClose ? m_rates[i].close : m_rates[i].high;
      int tgt = -1;
      for(int k = 0; k < ArraySize(m_highs); k++)
         if(!m_highs[k].broken)
            tgt = k;
      if(tgt >= 0 && val > m_highs[tgt].price)
      {
         for(int k = 0; k < ArraySize(m_highs); k++)
         {
            if(m_highs[k].broken)
               continue;
            if(m_highs[k].price < val || k == tgt)
            {
               m_highs[k].broken       = true;
               m_highs[k].brokenTime   = bt;
               m_highs[k].brokenByWick = !m_bosByClose;
            }
         }
         SMC_Bos ev;
         ev.dir        = SMC_BULL;
         ev.idx        = i;
         ev.time       = bt;
         ev.swingIdx   = m_highs[tgt].idx;
         ev.swingPrice = m_highs[tgt].price;
         AppendBos(ev);
         OnBos(ev, tgt);
      }

      // bearish: close (or wick) below the most recent unbroken swing low
      val = m_bosByClose ? m_rates[i].close : m_rates[i].low;
      tgt = -1;
      for(int k = 0; k < ArraySize(m_lows); k++)
         if(!m_lows[k].broken)
            tgt = k;
      if(tgt >= 0 && val < m_lows[tgt].price)
      {
         for(int k = 0; k < ArraySize(m_lows); k++)
         {
            if(m_lows[k].broken)
               continue;
            if(m_lows[k].price > val || k == tgt)
            {
               m_lows[k].broken       = true;
               m_lows[k].brokenTime   = bt;
               m_lows[k].brokenByWick = !m_bosByClose;
            }
         }
         SMC_Bos ev;
         ev.dir        = SMC_BEAR;
         ev.idx        = i;
         ev.time       = bt;
         ev.swingIdx   = m_lows[tgt].idx;
         ev.swingPrice = m_lows[tgt].price;
         AppendBos(ev);
         OnBos(ev, tgt);
      }
   }

   //--- 4.4 promote a swept swing to a strong point --------------------
   void OnBos(SMC_Bos &ev, const int brokenIdx)
   {
      if(ev.dir == SMC_BEAR)
      {
         int bidx = m_lows[brokenIdx].idx;
         for(int k = ArraySize(m_highs) - 1; k >= 0; k--)
         {
            if(m_highs[k].broken || !m_highs[k].swept)
               continue;
            if(m_highs[k].originIdx != bidx)
               continue;
            SetStrongHigh(k);
            break;
         }
      }
      else
      {
         int bidx = m_highs[brokenIdx].idx;
         for(int k = ArraySize(m_lows) - 1; k >= 0; k--)
         {
            if(m_lows[k].broken || !m_lows[k].swept)
               continue;
            if(m_lows[k].originIdx != bidx)
               continue;
            SetStrongLow(k);
            break;
         }
      }
   }

   void SetStrongHigh(const int k)
   {
      if(m_hasStrongHigh && m_strongHighIdx == k)
         return;
      m_highs[k].strong = true;
      m_strongHighIdx   = k;
      m_hasStrongHigh   = true;

      int start = m_highs[k].idx + 1;
      int n = ArraySize(m_rates);
      double ll;
      int llIdx;
      if(start < n)
      {
         ll = m_rates[start].low;
         llIdx = start;
         for(int j = start; j < n; j++)
         {
            if(m_rates[j].low <= ll)
            {
               ll = m_rates[j].low;
               llIdx = j;
            }
         }
      }
      else
      {
         ll = m_highs[k].price;
         llIdx = m_highs[k].idx;
      }
      m_cand.direction  = SMC_BEAR;
      m_cand.rh         = m_highs[k].price;
      m_cand.idxExtreme = m_highs[k].idx;
      m_cand.extremeLow = ll;
      m_cand.extremeIdx = llIdx;
      m_candActive      = true;
   }

   void SetStrongLow(const int k)
   {
      if(m_hasStrongLow && m_strongLowIdx == k)
         return;
      m_lows[k].strong = true;
      m_strongLowIdx   = k;
      m_hasStrongLow   = true;

      int start = m_lows[k].idx + 1;
      int n = ArraySize(m_rates);
      double hh;
      int hhIdx;
      if(start < n)
      {
         hh = m_rates[start].high;
         hhIdx = start;
         for(int j = start; j < n; j++)
         {
            if(m_rates[j].high >= hh)
            {
               hh = m_rates[j].high;
               hhIdx = j;
            }
         }
      }
      else
      {
         hh = m_lows[k].price;
         hhIdx = m_lows[k].idx;
      }
      m_cand.direction  = SMC_BULL;
      m_cand.rh         = m_lows[k].price;
      m_cand.idxExtreme = m_lows[k].idx;
      m_cand.extremeLow = hh;
      m_cand.extremeIdx = hhIdx;
      m_candActive      = true;
   }

   void CancelCandidate()
   {
      if(m_candActive && m_cand.direction == SMC_BEAR && m_hasStrongHigh)
         m_highs[m_strongHighIdx].invalidated = true;
      if(m_candActive && m_cand.direction == SMC_BULL && m_hasStrongLow)
         m_lows[m_strongLowIdx].invalidated = true;
      m_candActive = false;
   }

   //--- 4.5 range confirmation ---------------------------------------
   void UpdateCandidate(const int i)
   {
      if(!m_candActive)
         return;
      double c = m_rates[i].close;

      if(m_cand.direction == SMC_BEAR)
      {
         if(m_rates[i].low < m_cand.extremeLow)
         {
            m_cand.extremeLow = m_rates[i].low;
            m_cand.extremeIdx = i;
         }
         if(m_invalidateByClose && c > m_cand.rh)
         {
            CancelCandidate();
            return;
         }
         int pivot = -1;
         for(int k = 0; k < ArraySize(m_highs); k++)
         {
            if(m_highs[k].idx > m_cand.idxExtreme &&
               m_highs[k].idx < m_cand.extremeIdx &&
               m_highs[k].price < m_cand.rh)
               pivot = k;
         }
         if(pivot >= 0 && c > m_highs[pivot].price)
            ConfirmBearRange(i);
      }
      else
      {
         if(m_rates[i].high > m_cand.extremeLow)
         {
            m_cand.extremeLow = m_rates[i].high;
            m_cand.extremeIdx = i;
         }
         if(m_invalidateByClose && c < m_cand.rh)
         {
            CancelCandidate();
            return;
         }
         int pivot = -1;
         for(int k = 0; k < ArraySize(m_lows); k++)
         {
            if(m_lows[k].idx > m_cand.idxExtreme &&
               m_lows[k].idx < m_cand.extremeIdx &&
               m_lows[k].price > m_cand.rh)
               pivot = k;
         }
         if(pivot >= 0 && c < m_lows[pivot].price)
            ConfirmBullRange(i);
      }
   }

   void TrimRanges()
   {
      while(m_rangeCount > m_rangeHistory)
      {
         for(int k = 1; k < m_rangeCount; k++)
            m_ranges[k - 1] = m_ranges[k];
         m_rangeCount--;
         ArrayResize(m_ranges, m_rangeCount);
      }
   }

   void ConfirmBearRange(const int i)
   {
      SMC_Range r;
      r.dir         = SMC_BEAR;
      r.rh          = m_cand.rh;
      r.rl          = m_cand.extremeLow;
      r.status      = SMC_RANGE_CONFIRMED;
      r.confirmIdx  = i;
      r.confirmTime = m_rates[i].time;
      r.rhIdx       = m_cand.idxExtreme;
      r.rlIdx       = m_cand.extremeIdx;
      r.strongIdx   = m_cand.idxExtreme;
      r.irlPrice    = 0.0;
      r.irlIdx      = -1;
      r.irlTaken    = false;
      r.broken      = false;
      r.RecalcEq();
      m_candActive = false;

      ArrayResize(m_ranges, m_rangeCount + 1);
      m_ranges[m_rangeCount] = r;
      m_rangeCount++;
      AttachIrl(m_rangeCount - 1, i);
      TrimRanges();
   }

   void ConfirmBullRange(const int i)
   {
      SMC_Range r;
      r.dir         = SMC_BULL;
      r.rh          = m_cand.extremeLow;
      r.rl          = m_cand.rh;
      r.status      = SMC_RANGE_CONFIRMED;
      r.confirmIdx  = i;
      r.confirmTime = m_rates[i].time;
      r.rhIdx       = m_cand.extremeIdx;
      r.rlIdx       = m_cand.idxExtreme;
      r.strongIdx   = m_cand.idxExtreme;
      r.irlPrice    = 0.0;
      r.irlIdx      = -1;
      r.irlTaken    = false;
      r.broken      = false;
      r.RecalcEq();
      m_candActive = false;

      ArrayResize(m_ranges, m_rangeCount + 1);
      m_ranges[m_rangeCount] = r;
      m_rangeCount++;
      AttachIrl(m_rangeCount - 1, i);
      TrimRanges();
   }

   // 4.7: highest swing high (bear) / lowest swing low (bull) inside range
   void AttachIrl(const int rangeIdx, const int i)
   {
      SMC_Range r = m_ranges[rangeIdx];
      int bestIdx = -1;
      if(r.dir == SMC_BEAR)
      {
         for(int k = 0; k < ArraySize(m_highs); k++)
         {
            if(m_highs[k].idx > r.rhIdx && m_highs[k].idx <= i &&
               m_highs[k].price > r.rl && m_highs[k].price < r.rh)
            {
               if(bestIdx < 0 || m_highs[k].price > m_highs[bestIdx].price)
                  bestIdx = k;
            }
         }
         if(bestIdx >= 0)
         {
            r.irlPrice = m_highs[bestIdx].price;
            r.irlIdx   = m_highs[bestIdx].idx;
         }
      }
      else
      {
         for(int k = 0; k < ArraySize(m_lows); k++)
         {
            if(m_lows[k].idx > r.rlIdx && m_lows[k].idx <= i &&
               m_lows[k].price > r.rl && m_lows[k].price < r.rh)
            {
               if(bestIdx < 0 || m_lows[k].price < m_lows[bestIdx].price)
                  bestIdx = k;
            }
         }
         if(bestIdx >= 0)
         {
            r.irlPrice = m_lows[bestIdx].price;
            r.irlIdx   = m_lows[bestIdx].idx;
         }
      }
      m_ranges[rangeIdx] = r;
   }

   void UpdateActiveRange(const int i)
   {
      if(m_rangeCount <= 0)
         return;
      double hi = m_rates[i].high;
      double lo = m_rates[i].low;
      double c  = m_rates[i].close;
      if(m_ranges[m_rangeCount - 1].irlIdx >= 0 &&
         !m_ranges[m_rangeCount - 1].irlTaken)
      {
         if(m_ranges[m_rangeCount - 1].dir == SMC_BEAR &&
            hi >= m_ranges[m_rangeCount - 1].irlPrice)
            m_ranges[m_rangeCount - 1].irlTaken = true;
         if(m_ranges[m_rangeCount - 1].dir == SMC_BULL &&
            lo <= m_ranges[m_rangeCount - 1].irlPrice)
            m_ranges[m_rangeCount - 1].irlTaken = true;
      }
      if(!m_ranges[m_rangeCount - 1].broken)
      {
         if(m_ranges[m_rangeCount - 1].dir == SMC_BEAR &&
            c > m_ranges[m_rangeCount - 1].rh)
            m_ranges[m_rangeCount - 1].broken = true;
         if(m_ranges[m_rangeCount - 1].dir == SMC_BULL &&
            c < m_ranges[m_rangeCount - 1].rl)
            m_ranges[m_rangeCount - 1].broken = true;
      }
      // 4.4 strong point invalidation by close
      if(m_hasStrongHigh && m_invalidateByClose &&
         c > m_highs[m_strongHighIdx].price)
         m_highs[m_strongHighIdx].invalidated = true;
      if(m_hasStrongLow && m_invalidateByClose &&
         c < m_lows[m_strongLowIdx].price)
         m_lows[m_strongLowIdx].invalidated = true;
   }

public:
   void Init(const string symbol, const ENUM_TIMEFRAMES tf,
             const int swingLen, const bool bosByClose,
             const double equalTolAtr, const int atrPeriod,
             const int rangeHistory, const bool invalidateByClose)
   {
      m_symbol            = symbol;
      m_tf                = tf;
      m_swingLen          = MathMax(1, swingLen);
      m_bosByClose        = bosByClose;
      m_equalTolAtr       = equalTolAtr;
      m_atrPeriod         = MathMax(1, atrPeriod);
      m_rangeHistory      = MathMax(1, rangeHistory);
      m_invalidateByClose = invalidateByClose;
      Reset();
   }

   void Reset()
   {
      ArrayResize(m_rates, 0);
      ArrayResize(m_atr, 0);
      ArrayResize(m_highs, 0);
      ArrayResize(m_lows, 0);
      ArrayResize(m_bos, 0);
      ArrayResize(m_ranges, 0);
      m_rangeCount    = 0;
      m_candActive    = false;
      m_strongHighIdx = -1;
      m_strongLowIdx  = -1;
      m_hasStrongHigh = false;
      m_hasStrongLow  = false;
      m_lastProcessed = 0;
      m_hasAsiaHigh   = false;
      m_hasAsiaLow    = false;
      m_hasPdh        = false;
      m_hasPdl        = false;
      m_asiaHigh      = 0.0;
      m_asiaLow       = 0.0;
      m_pdh           = 0.0;
      m_pdl           = 0.0;
   }

   //--- external liquidity used by 4.3 -------------------------------
   void SetAsiaLiquidity(const bool hasHigh, const double high,
                         const bool hasLow, const double low)
   {
      m_hasAsiaHigh = hasHigh;
      m_asiaHigh    = high;
      m_hasAsiaLow  = hasLow;
      m_asiaLow     = low;
   }

   void SetPrevDayLiquidity(const bool hasHigh, const double high,
                            const bool hasLow, const double low)
   {
      m_hasPdh = hasHigh;
      m_pdh    = high;
      m_hasPdl = hasLow;
      m_pdl    = low;
   }

   //--- feed one closed bar (tests / CSV replay) ---------------------
   void PushBar(const datetime t, const double o, const double h,
                const double l, const double c)
   {
      int i = ArraySize(m_rates);
      ArrayResize(m_rates, i + 1);
      m_rates[i].time        = t;
      m_rates[i].open        = o;
      m_rates[i].high        = h;
      m_rates[i].low         = l;
      m_rates[i].close       = c;
      m_rates[i].tick_volume = 0;
      m_rates[i].spread      = 0;
      m_rates[i].real_volume = 0;

      ArrayResize(m_atr, i + 1);
      m_atr[i] = CalcAtr(i);

      DetectSwing(i);
      // confirmation before breaks (see python engine for rationale)
      UpdateCandidate(i);
      ProcessBreaks(i);
      UpdateActiveRange(i);
      m_lastProcessed = t;
   }

   //--- incremental load from the chart ------------------------------
   int Update(const int barsToLoad = 2500)
   {
      MqlRates rates[];
      ArraySetAsSeries(rates, false);
      int copied = CopyRates(m_symbol, m_tf, 0, barsToLoad, rates);
      if(copied <= 1)
         return 0;
      int processed = 0;
      // the last element is the forming bar -> never process it
      for(int k = 0; k < copied - 1; k++)
      {
         if(rates[k].time <= m_lastProcessed)
            continue;
         PushBar(rates[k].time, rates[k].open, rates[k].high,
                 rates[k].low, rates[k].close);
         processed++;
      }
      return processed;
   }

   //--- accessors ----------------------------------------------------
   int BarsCount()
   {
      return ArraySize(m_rates);
   }

   // Time of a confirmed bar (used by the Asia strong-extreme check).
   datetime BarTimeAt(const int i)
   {
      return BarTime(i);
   }

   // Read-only access to a confirmed bar (used by the POI / setup engines).
   bool GetRate(const int i, MqlRates &out)
   {
      if(i < 0 || i >= ArraySize(m_rates))
         return false;
      out = m_rates[i];
      return true;
   }

   // Close-only series helper used by the CLOSE_LEVEL model (A1).
   bool GetClose(const int i, double &out)
   {
      if(i < 0 || i >= ArraySize(m_rates))
         return false;
      out = m_rates[i].close;
      return true;
   }

   int HighCount()
   {
      return ArraySize(m_highs);
   }

   int LowCount()
   {
      return ArraySize(m_lows);
   }

   bool GetHigh(const int i, SMC_Swing &out)
   {
      if(i < 0 || i >= ArraySize(m_highs))
         return false;
      out = m_highs[i];
      return true;
   }

   bool GetLow(const int i, SMC_Swing &out)
   {
      if(i < 0 || i >= ArraySize(m_lows))
         return false;
      out = m_lows[i];
      return true;
   }

   bool GetStrongHigh(SMC_Swing &out)
   {
      if(!m_hasStrongHigh)
         return false;
      out = m_highs[m_strongHighIdx];
      return true;
   }

   bool GetStrongLow(SMC_Swing &out)
   {
      if(!m_hasStrongLow)
         return false;
      out = m_lows[m_strongLowIdx];
      return true;
   }

   bool HasStrongHigh()
   {
      return m_hasStrongHigh;
   }

   bool HasStrongLow()
   {
      return m_hasStrongLow;
   }

   bool GetLastBos(SMC_Bos &out)
   {
      int n = ArraySize(m_bos);
      if(n <= 0)
         return false;
      out = m_bos[n - 1];
      return true;
   }

   int BosCount()
   {
      return ArraySize(m_bos);
   }

   bool GetBosAt(const int i, SMC_Bos &out)
   {
      if(i < 0 || i >= ArraySize(m_bos))
         return false;
      out = m_bos[i];
      return true;
   }

   int RangeCount()
   {
      return m_rangeCount;
   }

   bool GetLastRange(SMC_Range &out)
   {
      if(m_rangeCount <= 0)
         return false;
      out = m_ranges[m_rangeCount - 1];
      return true;
   }

   bool GetRangeAt(const int fromEnd, SMC_Range &out)
   {
      int idx = m_rangeCount - 1 - fromEnd;
      if(idx < 0 || idx >= m_rangeCount)
         return false;
      out = m_ranges[idx];
      return true;
   }

   bool GetProvisionalRange(SMC_Range &out)
   {
      if(!m_candActive)
         return false;
      out.dir         = m_cand.direction;
      out.rhIdx       = (m_cand.direction == SMC_BEAR) ? m_cand.idxExtreme
                                                       : m_cand.extremeIdx;
      out.rlIdx       = (m_cand.direction == SMC_BEAR) ? m_cand.extremeIdx
                                                       : m_cand.idxExtreme;
      if(m_cand.direction == SMC_BEAR)
      {
         out.rh = m_cand.rh;
         out.rl = m_cand.extremeLow;
      }
      else
      {
         out.rh = m_cand.extremeLow;
         out.rl = m_cand.rh;
      }
      out.status      = SMC_RANGE_PROVISIONAL;
      out.confirmIdx  = -1;
      out.confirmTime = 0;
      out.strongIdx   = m_cand.idxExtreme;
      out.irlPrice    = 0.0;
      out.irlIdx      = -1;
      out.irlTaken    = false;
      out.broken      = false;
      out.RecalcEq();
      return true;
   }

   bool GetActiveRange(SMC_Range &out)
   {
      if(GetLastRange(out))
         return true;
      return GetProvisionalRange(out);
   }

   int Bias()
   {
      if(m_rangeCount <= 0)
         return SMC_NEUTRAL;
      return m_ranges[m_rangeCount - 1].dir;
   }

   bool BiasValid()
   {
      if(m_rangeCount <= 0)
         return false;
      return (!m_ranges[m_rangeCount - 1].broken);
   }

   double AtrLast()
   {
      int n = ArraySize(m_atr);
      if(n <= 0)
         return 0.0;
      return m_atr[n - 1];
   }

   //--- structure helpers used by the POI / setup layers --------------
   bool FindLastSwingHighBelow(const double price, SMC_Swing &out)
   {
      bool found = false;
      for(int k = 0; k < ArraySize(m_highs); k++)
      {
         if(m_highs[k].price <= price)
         {
            out = m_highs[k];
            found = true;
         }
      }
      return found;
   }

   bool FindLastSwingLowAbove(const double price, SMC_Swing &out)
   {
      bool found = false;
      for(int k = 0; k < ArraySize(m_lows); k++)
      {
         if(m_lows[k].price >= price)
         {
            out = m_lows[k];
            found = true;
         }
      }
      return found;
   }

   int CountEqualLevels(const bool isHigh, const double price,
                        const double tol, const bool onlyBeyond)
   {
      int n = 0;
      if(isHigh)
      {
         for(int k = 0; k < ArraySize(m_highs); k++)
         {
            if(MathAbs(m_highs[k].price - price) > tol)
               continue;
            if(onlyBeyond && m_highs[k].price < price)
               continue;
            n++;
         }
      }
      else
      {
         for(int k = 0; k < ArraySize(m_lows); k++)
         {
            if(MathAbs(m_lows[k].price - price) > tol)
               continue;
            if(onlyBeyond && m_lows[k].price > price)
               continue;
            n++;
         }
      }
      return n;
   }

   // largest count of aligned same-type swings over the last 30 (7.E)
   int TrendlineCount(const bool isHigh, const double tol)
   {
      SMC_Swing pts[];
      int total = 0;
      if(isHigh)
      {
         int n = ArraySize(m_highs);
         total = MathMin(n, 30);
         ArrayResize(pts, total);
         for(int k = 0; k < total; k++)
            pts[k] = m_highs[n - total + k];
      }
      else
      {
         int n = ArraySize(m_lows);
         total = MathMin(n, 30);
         ArrayResize(pts, total);
         for(int k = 0; k < total; k++)
            pts[k] = m_lows[n - total + k];
      }
      if(total < 3)
         return total;
      int best = 1;
      for(int a = 0; a < total; a++)
      {
         for(int b = a + 1; b < total; b++)
         {
            int span = pts[b].idx - pts[a].idx;
            if(span <= 0)
               continue;
            double slope = (pts[b].price - pts[a].price) / (double)span;
            int cnt = 2;
            for(int k = b + 1; k < total; k++)
            {
               double exp = pts[b].price + slope * (pts[k].idx - pts[b].idx);
               if(MathAbs(pts[k].price - exp) <= tol)
                  cnt++;
            }
            if(cnt > best)
               best = cnt;
         }
      }
      return best;
   }

   // 0 at RL, 1 at RH
   double RangeRatio(SMC_Range &r, const double price)
   {
      return r.Ratio(price);
   }

   string RangeZone(SMC_Range &r, const double price)
   {
      double p = r.Ratio(price);
      if(p >= 0.79)
         return "EXTREME_PREMIUM";
      if(p >= 0.5)
         return "PREMIUM";
      if(p <= 0.21)
         return "EXTREME_DISCOUNT";
      return "DISCOUNT";
   }

   bool ExtremeZone(SMC_Range &r, const double price)
   {
      string z = RangeZone(r, price);
      return (z == "EXTREME_PREMIUM" || z == "EXTREME_DISCOUNT");
   }

   bool IsProvisionalRange()
   {
      if(m_rangeCount > 0)
         return false;
      return m_candActive;
   }
};

#endif // SMC_STRUCTURE_MQH
