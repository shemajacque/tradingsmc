//+------------------------------------------------------------------+
//|  SMC_POI.mqh                                                     |
//|  POINT OF INTEREST engine - LEGACY zone model (section 5.x).      |
//|                                                                  |
//|  Detects order blocks, breakers, rejection (swept) wicks and      |
//|  unfilled fair value gaps on CLOSED bars only, applies mitigation |
//|  (5.1), eligibility (5.2), refinement (5.3) and priority (5.5).   |
//|                                                                  |
//|  The CLOSE_LEVEL model of addendum A1 lives in SMC_CloseLevel.mqh |
//|  and is selected by InpPOIModel.  This file is never modified by  |
//|  that model - LEGACY stays the default.                           |
//+------------------------------------------------------------------+
#ifndef SMC_POI_MQH
#define SMC_POI_MQH

#include "SMC_Types.mqh"
#include "SMC_Structure.mqh"

class CPOIEngine
{
private:
   CStructure*       m_struct;        // not owned
   ENUM_TIMEFRAMES   m_tf;

   //--- config (inputs, never hard-coded)
   double            m_minWickRatio;  // InpMinWickRatio  (0.5)
   bool              m_obBodyOnly;    // InpOBBodyOnly
   double            m_maxHeightATR;  // InpMaxPOIHeightATR (0.6)
   double            m_equalTolAtr;   // InpEqualTol
   int               m_obLookback;    // bars searched back for an OB candle
   int               m_maxPois;       // bounded storage

   SMC_POI           m_pois[];
   int               m_count;

   //--- index of the last bar whose mitigation state was evaluated
   int               m_mitigatedThrough;

   double Atr()
   {
      return (m_struct != NULL) ? m_struct.AtrLast() : 0.0;
   }

   int Bars()
   {
      return (m_struct != NULL) ? m_struct.BarsCount() : 0;
   }

   bool Bar(const int i, MqlRates &r)
   {
      return (m_struct != NULL) && m_struct.GetRate(i, r);
   }

   void AddPoi(const double top, const double bottom,
               const ENUM_POI_TYPE type, const ENUM_LEVEL_TYPE lt,
               const datetime time, const int idx, const double quality)
   {
      if(m_count >= m_maxPois)
         return;
      SMC_POI p;
      p.top          = MathMax(top, bottom);
      p.bottom       = MathMin(top, bottom);
      p.type         = type;
      p.levelType    = lt;
      p.tf           = m_tf;
      p.time         = time;
      p.originIdx    = idx;
      p.mitigated    = false;
      p.broken       = false;
      p.flippedFrom  = -1;
      p.touchCount   = 0;
      p.overlapCount = 0;
      p.quality      = quality;
      p.active       = true;
      ArrayResize(m_pois, m_count + 1);
      m_pois[m_count] = p;
      m_count++;
   }

   // A bearish OB is a bullish candle immediately preceding a down displacer.
   bool FindOrderBlock(const int bosIdx, const int dir,
                       int &outIdx, MqlRates &outCandle)
   {
      outIdx = -1;
      int start = bosIdx - 1;
      if(start < 0)
         return false;
      int stop = MathMax(0, start - m_obLookback + 1);
      for(int k = start; k >= stop; k--)
      {
         MqlRates r;
         if(!Bar(k, r))
            continue;
         bool wanted = (dir == SMC_BEAR) ? (r.close > r.open)
                                         : (r.close < r.open);
         if(wanted)
         {
            outIdx = k;
            outCandle = r;
            return true;
         }
      }
      return false;
   }

   void DetectOrderBlocks()
   {
      int nb = (m_struct != NULL) ? m_struct.BosCount() : 0;
      for(int b = 0; b < nb; b++)
      {
         SMC_Bos ev;
         if(!m_struct.GetBosAt(b, ev))
            continue;
         int obIdx;
         MqlRates ob;
         if(!FindOrderBlock(ev.idx, ev.dir, obIdx, ob))
            continue;

         double top = ob.high;
         double bot = ob.low;
         if(m_obBodyOnly)
         {
            top = MathMax(ob.open, ob.close);
            bot = MathMin(ob.open, ob.close);
         }
         ENUM_LEVEL_TYPE lt = (ev.dir == SMC_BEAR) ? LVL_RES : LVL_SUP;
         // A swept displacement candle gives the OB priority (5.5).
         double quality = 1.0;
         MqlRates disp;
         if(Bar(ev.idx, disp))
         {
            bool swept = (ev.dir == SMC_BEAR)
                       ? (disp.high > ob.high && disp.close < ob.low)
                       : (disp.low < ob.low && disp.close > ob.high);
            if(swept)
               quality += 1.0;
         }
         AddPoi(top, bot, POI_ORDER_BLOCK, lt, ob.time, obIdx, quality);
      }
   }

   void DetectWicks()
   {
      int n = Bars();
      double minR = m_minWickRatio;
      for(int i = 1; i < n; i++)
      {
         MqlRates cur, prev;
         if(!Bar(i, cur) || !Bar(i - 1, prev))
            continue;
         double span = cur.high - cur.low;
         if(span <= 0.0)
            continue;

         // Bearish rejection: upper wick >= ratio and exceeds previous high.
         double upper = cur.high - MathMax(cur.open, cur.close);
         if(minR > 0.0 && upper >= minR * span && cur.high > prev.high)
            AddPoi(cur.high, MathMax(cur.open, cur.close), POI_WICK, LVL_RES,
                   cur.time, i, 1.0);
         // Bullish rejection: lower wick mirrored.
         double lower = MathMin(cur.open, cur.close) - cur.low;
         if(minR > 0.0 && lower >= minR * span && cur.low < prev.low)
            AddPoi(MathMin(cur.open, cur.close), cur.low, POI_WICK, LVL_SUP,
                   cur.time, i, 1.0);
      }
   }

   void DetectFvgs()
   {
      int n = Bars();
      for(int i = 2; i < n; i++)
      {
         MqlRates a, c;
         if(!Bar(i - 2, a) || !Bar(i, c))
            continue;
         // Bullish FVG: gap between the old high and the new low.
         if(c.low > a.high)
            AddPoi(c.low, a.high, POI_FVG, LVL_SUP, c.time, i, 1.0);
         // Bearish FVG: gap between the old low and the new high.
         if(c.high < a.low)
            AddPoi(a.low, c.high, POI_FVG, LVL_RES, c.time, i, 1.0);
      }
   }

   // 5.1: a zone is mitigated once a later candle trades into it.
   // A body close through the opposite edge turns an OB into a breaker (5.x).
   void ApplyMitigation(const int from)
   {
      int n = Bars();
      for(int p = 0; p < m_count; p++)
      {
         for(int k = MathMax(from, m_pois[p].originIdx + 1); k < n; k++)
         {
            MqlRates r;
            if(!Bar(k, r))
               continue;
            // Breaker check runs first: a body close beyond the far edge flips
            // the usage direction and resets freshness for the retest.
            if(!m_pois[p].broken && m_pois[p].type == POI_ORDER_BLOCK)
            {
               bool through = (m_pois[p].levelType == LVL_RES)
                            ? (r.close > m_pois[p].top)
                            : (r.close < m_pois[p].bottom);
               if(through)
               {
                  m_pois[p].broken = true;
                  m_pois[p].flippedFrom = (int)m_pois[p].levelType;
                  m_pois[p].type = POI_BREAKER;
                  m_pois[p].levelType = (m_pois[p].levelType == LVL_RES)
                                        ? LVL_SUP : LVL_RES;
                  m_pois[p].mitigated = false;
                  m_pois[p].touchCount = 0;
                  continue;
               }
            }
            bool overlap = (r.low <= m_pois[p].top && r.high >= m_pois[p].bottom);
            if(!m_pois[p].mitigated && overlap)
            {
               m_pois[p].mitigated = true;
               m_pois[p].touchCount++;
            }
         }
      }
   }

public:
   void Init(CStructure* s, const ENUM_TIMEFRAMES tf,
             const double minWickRatio, const bool obBodyOnly,
             const double maxHeightATR, const double equalTolAtr,
             const int obLookback = 12, const int maxPois = 512)
   {
      m_struct       = s;
      m_tf           = tf;
      m_minWickRatio = minWickRatio;
      m_obBodyOnly   = obBodyOnly;
      m_maxHeightATR = maxHeightATR;
      m_equalTolAtr  = equalTolAtr;
      m_obLookback   = MathMax(2, obLookback);
      m_maxPois      = MathMax(32, maxPois);
      Reset();
   }

   void Reset()
   {
      ArrayResize(m_pois, 0);
      m_count = 0;
      m_mitigatedThrough = 0;
   }

   // Full rebuild from the structure's closed bars. Called on a new bar.
   void Rebuild()
   {
      Reset();
      DetectOrderBlocks();
      DetectWicks();
      DetectFvgs();
      ApplyMitigation(0);
      m_mitigatedThrough = Bars();
   }

   // Cheap incremental refresh: only re-evaluate mitigation for new bars.
   void Refresh()
   {
      int n = Bars();
      if(n > m_mitigatedThrough)
      {
         ApplyMitigation(m_mitigatedThrough);
         m_mitigatedThrough = n;
      }
   }

   int Count() const { return m_count; }

   bool Get(const int i, SMC_POI &out)
   {
      if(i < 0 || i >= m_count)
         return false;
      out = m_pois[i];
      return true;
   }

   double HeightAtr(const SMC_POI &p)
   {
      double a = Atr();
      if(a <= 0.0)
         return 0.0;
      return (p.top - p.bottom) / a;
   }

   // 5.3: too tall . needs refinement on a lower TF.
   bool NeedsRefinement(const SMC_POI &p)
   {
      return (HeightAtr(p) > m_maxHeightATR);
   }

   // 5.3: find a smaller same-direction POI from a lower TF engine that sits
   // inside theHTF zone.  Returns the best (smallest) by height.
   bool Refine(const SMC_POI &htf, CPOIEngine* lower, SMC_POI &out)
   {
      if(lower == NULL)
         return false;
      bool found = false;
      double bestH = 1e18;
      SMC_POI best;
      ZeroMemory(best);
      for(int i = 0; i < lower.Count(); i++)
      {
         SMC_POI p;
         if(!lower.Get(i, p))
            continue;
         if(p.levelType != htf.levelType)
            continue;
         if(p.mitigated || p.top > htf.top || p.bottom < htf.bottom)
            continue;
         double h = p.top - p.bottom;
         if(h < bestH)
         {
            bestH = h;
            best = p;
            found = true;
         }
      }
      if(found)
         out = best;
      return found;
   }

   // 5.2 liquidity fed into the POI: a pool on the opposite side of where
   // price will travel. For a sell (LVL_RES) that means a pool BELOW it.
   int LiquidityBeyond(const SMC_POI &p, const double tol)
   {
      if(m_struct == NULL)
         return 0;
      int n = 0;
      if(p.levelType == LVL_RES)
      {
         n += m_struct.CountEqualLevels(false, p.bottom, tol, true);
         if(m_struct.TrendlineCount(false, tol) >= 3)
            n++;
      }
      else
      {
         n += m_struct.CountEqualLevels(true, p.top, tol, true);
         if(m_struct.TrendlineCount(true, tol) >= 3)
            n++;
      }
      return n;
   }

   // 5.5 priority among unmitigated POIs matching a direction & range side.
   // Criteria: (a) swept IRL proximity, (b) most HTF overlaps, (c) closest to
   // EQ on the correct side.  Overlap counts are supplied by the setup layer.
   bool Best(const int dir, const SMC_Range &range, const double price,
             const bool skipFirstPullback, SMC_POI &out)
   {
      bool found = false;
      double bestScore = -1e18;
      bool wantRes = (dir == SMC_BEAR);
      for(int i = 0; i < m_count; i++)
      {
         SMC_POI p = m_pois[i];
         if(!p.active || p.mitigated)
            continue;
         if((p.levelType == LVL_RES) != wantRes)
            continue;
         // correct side of the confirmed range (premium for sells)
         double ratio = range.Ratio((p.top + p.bottom) / 2.0);
         if(wantRes ? (ratio < 0.5) : (ratio > 0.5))
            continue;
         // 5.2 first-pullback inducement: no IRL taken yet and this is the
         // very first pullback after the BOS (oldest unmitigated OB).
         if(skipFirstPullback && !range.irlTaken && p.type == POI_ORDER_BLOCK)
         {
            bool isFirst = true;
            for(int k = 0; k < m_count; k++)
            {
               if(k == i)
                  continue;
               if(!m_pois[k].mitigated && m_pois[k].levelType == p.levelType &&
                  m_pois[k].originIdx < p.originIdx)
               {
                  isFirst = false;
                  break;
               }
            }
            if(isFirst)
               continue;
         }
         double score = p.quality + 2.0 * p.overlapCount;
         if(range.irlPrice > 0.0)
            score -= MathAbs((p.bottom + p.top) / 2.0 - range.irlPrice);
         score -= MathAbs((p.top + p.bottom) / 2.0 - range.eq);
         if(score <= bestScore)
            continue;
         bestScore = score;
         out = p;
         found = true;
      }
      return found;
   }

   // Entry level inside the zone (5.4). level=0.5 . midpoint, 0 . proximal.
   double EntryLevel(const SMC_POI &p, const double level) const
   {
      double f = MathMin(1.0, MathMax(0.0, level));
      if(p.levelType == LVL_RES)
         return p.bottom + f * (p.top - p.bottom);
      return p.top - f * (p.top - p.bottom);
   }
};

#endif // SMC_POI_MQH
