//+------------------------------------------------------------------+
//|  SMC_CloseLevel.mqh                                              |
//|  ADDENDUM A1: CLOSE_LEVEL POI model.                              |
//|                                                                  |
//|  Active only when InpPOIModel = CLOSE_LEVEL.  It replaces the     |
//|  zone-based POI types with single closing-price LEVELS.           |
//|                                                                  |
//|  Explicit interpretations (documented, not hidden):              |
//|   * Opening prices are never used (gaps differ between brokers).  |
//|   * A "touch" is any candle whose [low,high] spans the level.      |
//|   * A flip (SBR/RBS) requires a BODY close through the level;      |
//|     wick-only breaks are ignored (InpBreakByBodyClose = true).    |
//|   * HTF rank: MN1 > W1 > D1 > H4 > H1 > M30 > M15.                |
//|   * The two-close "top and bottom" rule (A1.9) uses a cluster      |
//|     distance of InpClusterPoints ATR(M15) / 10 by default.        |
//+------------------------------------------------------------------+
#ifndef SMC_CLOSELEVEL_MQH
#define SMC_CLOSELEVEL_MQH

#include "SMC_Types.mqh"
#include "SMC_Structure.mqh"

class CCloseLevelEngine
{
private:
   CStructure*       m_struct;
   ENUM_TIMEFRAMES   m_tf;
   double            m_bandPoints;
   bool              m_bodyCloseBreak;
   bool              m_obMap;
   int               m_minTFRank;
   double            m_htfConflictTol;
   double            m_maxRefineDist;
   int               m_maxLevels;
   SMC_Level         m_levels[];
   int               m_count;

   static int Rank(const ENUM_TIMEFRAMES tf)
   {
      switch(tf)
      {
         case PERIOD_MN1: return 7;
         case PERIOD_W1:  return 6;
         case PERIOD_D1:  return 5;
         case PERIOD_H4:  return 4;
         case PERIOD_H1:  return 3;
         case PERIOD_M30: return 2;
         case PERIOD_M15: return 1;
         default:         return 0;   // M5/M1/seconds are never marked
      }
   }

   void Add(const double price, const ENUM_LEVEL_TYPE type,
            const datetime time, const double quality = 1.0)
   {
      if(Rank(m_tf) < m_minTFRank)
         return;
      if(m_count >= m_maxLevels)
         return;
      SMC_Level l;
      l.price = price;
      l.type = type;
      l.tf = m_tf;
      l.barTime = time;
      l.touchCount = 0;
      l.used = false;
      l.broken = false;
      l.flippedFrom = -1;
      l.fresh = true;
      l.active = true;
      l.quality = quality;
      ArrayResize(m_levels, m_count + 1);
      m_levels[m_count] = l;
      m_count++;
   }

   // A1.2 closing-price peak/trough, strict 3-bar fractal on CLOSES.
   void DetectPeaks()
   {
      int n = (m_struct != NULL) ? m_struct.BarsCount() : 0;
      for(int i = 1; i < n - 1; i++)
      {
         double a, b, c;
         if(!m_struct.GetClose(i - 1, a) || !m_struct.GetClose(i, b) ||
            !m_struct.GetClose(i + 1, c))
            continue;
         datetime t = 0;
         MqlRates r;
         if(m_struct.GetRate(i, r))
            t = r.time;
         if(b > a && b > c)
            Add(b, LVL_RES, t);
         else if(b < a && b < c)
            Add(b, LVL_SUP, t);
      }
   }

   // A1.4 flips and A1.3 freshness.
   void ApplyFlipsAndTouches()
   {
      int n = (m_struct != NULL) ? m_struct.BarsCount() : 0;
      for(int l = 0; l < m_count; l++)
      {
         int origin = -1;
         MqlRates rr;
         if(m_struct.GetRate(0, rr) && rr.time > 0)
         {
            for(int i = 0; i < n; i++)
            {
               MqlRates r;
               if(m_struct.GetRate(i, r) && r.time == m_levels[l].barTime)
               {
                  origin = i;
                  break;
               }
            }
         }
         for(int i = origin + 1; i < n; i++)
         {
            MqlRates r;
            if(!m_struct.GetRate(i, r))
               continue;
            bool through = (m_levels[l].type == LVL_RES)
                         ? (r.close > m_levels[l].price)
                         : (r.close < m_levels[l].price);
            if(m_bodyCloseBreak && !m_levels[l].broken && through)
            {
               m_levels[l].broken = true;
               m_levels[l].flippedFrom = (int)m_levels[l].type;
               m_levels[l].type = (m_levels[l].type == LVL_RES)
                                  ? LVL_SUP : LVL_RES;
               m_levels[l].touchCount = 0;
               m_levels[l].fresh = true;
            }
            bool touch = (r.low <= m_levels[l].price &&
                          r.high >= m_levels[l].price);
            if(touch)
            {
               m_levels[l].touchCount++;
               m_levels[l].fresh = false;
            }
         }
      }
   }

   // A1.5 direction filter: bearish -> only resistance (sells), etc.
   bool DirectionOk(const SMC_Level &l, const int trendDir) const
   {
      if(trendDir == SMC_NEUTRAL)
         return true;
      if(trendDir == SMC_BEAR)
         return (l.type == LVL_RES);
      return (l.type == LVL_SUP);
   }

public:
   void Init(CStructure* s, const ENUM_TIMEFRAMES tf,
             const double bandPoints, const bool bodyCloseBreak,
             const bool useObMap, const int minTFRank,
             const double htfConflictTol, const double maxRefineDist,
             const int maxLevels = 512)
   {
      m_struct = s;
      m_tf = tf;
      m_bandPoints = bandPoints;
      m_bodyCloseBreak = bodyCloseBreak;
      m_obMap = useObMap;
      m_minTFRank = minTFRank;
      m_htfConflictTol = htfConflictTol;
      m_maxRefineDist = maxRefineDist;
      m_maxLevels = maxLevels;
      Reset();
   }

   void Reset()
   {
      ArrayResize(m_levels, 0);
      m_count = 0;
   }

   void Rebuild()
   {
      Reset();
      DetectPeaks();
      ApplyFlipsAndTouches();
   }

   int Count() const { return m_count; }

   bool Get(const int i, SMC_Level &out)
   {
      if(i < 0 || i >= m_count)
         return false;
      out = m_levels[i];
      return true;
   }

   static int TimeframeRank(const ENUM_TIMEFRAMES tf) { return Rank(tf); }

   // A1.7 higher-TF priority: pick the highest-ranked fresh level in a cluster.
   bool BestLevel(const int trendDir, const double price, const double tol,
                  SMC_Level &out)
   {
      bool found = false;
      int bestRank = -1;
      double bestScore = -1e18;
      for(int i = 0; i < m_count; i++)
      {
         SMC_Level l = m_levels[i];
         if(!l.active || !l.fresh || l.used)
            continue;
         if(!DirectionOk(l, trendDir))
            continue;
         if(MathAbs(l.price - price) > tol)
            continue;
         int r = Rank(l.tf);
         double sc = l.quality - MathAbs(l.price - price) / (tol + 1e-12);
         if(r > bestRank || (r == bestRank && sc > bestScore))
         {
            bestRank = r;
            bestScore = sc;
            out = l;
            found = true;
         }
      }
      return found;
   }

   // A1.7 reject a lower-TF level under a stronger opposing HTF level.
   bool HasConflict(const SMC_Level &l, CCloseLevelEngine* higher)
   {
      if(higher == NULL)
         return false;
      int opposing = (l.type == LVL_RES) ? LVL_SUP : LVL_RES;
      for(int i = 0; i < higher.Count(); i++)
      {
         SMC_Level h;
         if(!higher.Get(i, h) || !h.active)
            continue;
         if(h.type != opposing)
            continue;
         if(Rank(h.tf) <= Rank(l.tf))
            continue;
         if(MathAbs(h.price - l.price) <= m_htfConflictTol)
            return true;
      }
      return false;
   }

   // A1.8 refinement: nearest same-direction lower-TF level within max dist.
   bool Refine(const SMC_Level &htf, CCloseLevelEngine* lower,
               SMC_Level &out)
   {
      if(lower == NULL || Rank(lower.m_tf) >= Rank(htf.tf))
         return false;
      bool found = false;
      double bestD = 1e18;
      for(int i = 0; i < lower.Count(); i++)
      {
         SMC_Level l;
         if(!lower.Get(i, l) || !l.fresh || !l.active)
            continue;
         if(l.type != htf.type)
            continue;
         double d = MathAbs(l.price - htf.price);
         if(d > m_maxRefineDist || d >= bestD)
            continue;
         bestD = d;
         out = l;
         found = true;
      }
      return found;
   }

   // A1.9 top/bottom rule: returns the two closest opposite-side fresh levels
   // within the cluster distance. "top" is the first reached for a sell
   // (higher price), "bottom" the extreme (lower price).
   bool TwoCloseLevels(const int dir, const double price,
                       const double clusterDist,
                       SMC_Level &top, SMC_Level &bottom)
   {
      bool haveTop = false, haveBottom = false;
      SMC_Level bestTop, bestBottom;
      ZeroMemory(bestTop);
      ZeroMemory(bestBottom);
      double topPrice = -1e18, botPrice = 1e18;
      int want = (dir == SMC_BEAR) ? LVL_RES : LVL_SUP;
      for(int i = 0; i < m_count; i++)
      {
         SMC_Level l = m_levels[i];
         if(!l.active || !l.fresh || l.used || l.type != want)
            continue;
         if(MathAbs(l.price - price) > clusterDist * 3.0)
            continue;
         if(dir == SMC_BEAR)
         {
            if(l.price > topPrice && l.price <= price + clusterDist)
            {
               topPrice = l.price; bestTop = l; haveTop = true;
            }
            if(l.price < botPrice && l.price >= price - clusterDist)
            {
               botPrice = l.price; bestBottom = l; haveBottom = true;
            }
         }
         else
         {
            if(l.price < topPrice && l.price >= price - clusterDist)
            {
               topPrice = l.price; bestTop = l; haveTop = true;
            }
            if(l.price > botPrice && l.price <= price + clusterDist)
            {
               botPrice = l.price; bestBottom = l; haveBottom = true;
            }
         }
      }
      if(haveTop)
         top = bestTop;
      if(haveBottom)
         bottom = bestBottom;
      return (haveTop && haveBottom && MathAbs(topPrice - botPrice) <= clusterDist);
   }

   void MarkUsed(const datetime barTime)
   {
      for(int i = 0; i < m_count; i++)
         if(m_levels[i].barTime == barTime)
         {
            m_levels[i].used = true;
            m_levels[i].fresh = false;
         }
   }
};

#endif // SMC_CLOSELEVEL_MQH
