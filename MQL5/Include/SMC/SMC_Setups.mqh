//+------------------------------------------------------------------+
//|  SMC_Setups.mqh                                                  |
//|  Entry models A/B/C/D (sections 7.A-7.D) and the probability      |
//|  score (section 9). Produces a TradeSignal structure.             |
//|                                                                  |
//|  Interpretation notes (documented, not hidden):                  |
//|   * TP1 (8): "max(1.5R, nearest opposite internal swing), closer   |
//|     in R terms but at least 1R" is implemented as: use the nearer  |
//|     of 1.5R and the nearest internal target provided that target  |
//|     is >= 1R, otherwise 1.5R.                                     |
//|   * SL buffer (8): POI edge + spread*mult + buffer points.        |
//|   * Strong-point SL uses the strong high/low when enabled.        |
//|   * All price distances use _Point and the symbol tick value; no  |
//|     literal pip values are hard-coded.                            |
//+------------------------------------------------------------------+
#ifndef SMC_SETUPS_MQH
#define SMC_SETUPS_MQH

#include "SMC_Types.mqh"
#include "SMC_Time.mqh"
#include "SMC_Structure.mqh"
#include "SMC_POI.mqh"
#include "SMC_Bias.mqh"
#include "SMC_CloseLevel.mqh"

//--- tunable thresholds, all supplied by EA inputs
struct SMC_SetupCfg
{
   double point;                // SYMBOL_POINT
   double tickValue;            // tick value in account currency
   double spreadPoints;         // current spread in points
   double equalTolAtr;          // 0.1
   double slBufferPoints;       // InpSLBufferPoints
   double slBufferSpreadMult;   // InpSLBufferSpreadMult
   double slExtraPoints;        // A5 InpSLExtraPoints
   double prefSLMinPips;        // 2
   double prefSLMaxPips;        // 5
   bool   goldMode;             // XAUUSD uses ATR limits
   double goldSLMinAtr;         // 0.15
   double goldSLMaxAtr;         // 0.5
   double maxSLPoints;          // InpMaxSLPoints (0 = disabled)
   bool   slAboveStrongHigh;    // InpSLAboveStrongHigh
   double tp1R;                 // 1.5
   double tp1Percent;           // 0.4
   double erlOffsetPoints;      // InpERLOffsetPoints
   double maxTargetR;           // 15
   double sweepMinPoints;       // InpSweepMinPoints
   int    sweepToBosBars;       // InpSweepToBOSMaxBars
   int    pendingExpiryBars;    // InpPendingExpiryBars
   double entryLevel;           // 0.5
   bool   requireHtfPoi;        // InpRequireHTFPOI
   bool   skipFirstPullback;    // InpSkipFirstPullbackPOI
   bool   useBodyWhenWick;      // InpUseBodyWhenWick
   double deepLevel;            // 0.705
   bool   requireDeepDiscount;  // InpRequireDeepDiscount
   double minLiqPools;          // InpMinLiquidityPools
   int    minScore;             // 3 . below = no trade
   int    fullScore;            // 7
   int    midScore;             // 5
   double provisionalRiskMult;  // 0.25
};

class CSetups
{
private:
   CTimeEngine*      m_time;
   CStructure*       m_rangeS;
   CStructure*       m_entryS;
   CStructure*       m_refineS;
   CStructure*       m_h4S;
   CPOIEngine*       m_rangePoi;
   CPOIEngine*       m_entryPoi;
   CPOIEngine*       m_refinePoi;
   CPOIEngine*       m_h4Poi;
   CBiasEngine*      m_bias;
   SMC_SetupCfg      m_cfg;
   SMC_AsiaBox       m_asia;

   //--- addendum A3 state (optional, set via InitAddendum)
   CCloseLevelEngine* m_h4Levels;
   CCloseLevelEngine* m_h1Levels;
   ENUM_DAYTYPE        m_dayType;
   double             m_londonHigh;
   double             m_londonLow;
   bool               m_londonValid;

   double Pip()
   {
      return 10.0 * m_cfg.point;   // documented: 1 pip = 10 points (GBPUSD/JPY-style);
   }

   double Buffer()
   {
      return m_cfg.slBufferSpreadMult * m_cfg.spreadPoints * m_cfg.point
           + m_cfg.slBufferPoints * m_cfg.point
           + m_cfg.slExtraPoints * m_cfg.point;
   }

   // 8: choose TP1 distance. Nearest internal swing (opposite side) is read
   // from the entry structure; the nearer of it and tp1R is used, floored at 1R.
   double Tp1Distance(const int dir, const double entry, const double risk)
   {
      double d = m_cfg.tp1R * risk;
      if(m_entryS != NULL)
      {
         double best = 0.0;
         for(int i = 0; i < m_entryS.HighCount(); i++)
         {
            SMC_Swing s;
            if(!m_entryS.GetHigh(i, s))
               continue;
            if(dir == SMC_BEAR && s.price < entry)
            {
               double cand = entry - s.price;
               if(cand > 0.0 && (best == 0.0 || cand < best))
                  best = cand;
            }
         }
         for(int i = 0; i < m_entryS.LowCount(); i++)
         {
            SMC_Swing s;
            if(!m_entryS.GetLow(i, s))
               continue;
            if(dir == SMC_BULL && s.price > entry)
            {
               double cand = s.price - entry;
               if(cand > 0.0 && (best == 0.0 || cand < best))
                  best = cand;
            }
         }
         if(best > 0.0 && best >= risk && best < d)
            d = best;
         if(best > 0.0 && best < risk)
            d = risk;
      }
      return d;
   }

   double RunnerTarget(const int dir, const double entry, const double risk,
                       const SMC_Range &rng)
   {
      double target = (dir == SMC_BEAR)
                    ? rng.rl + m_cfg.erlOffsetPoints * m_cfg.point
                    : rng.rh - m_cfg.erlOffsetPoints * m_cfg.point;
      double maxDist = m_cfg.maxTargetR * risk;
      if(risk > 0.0)
      {
         if(dir == SMC_BEAR && entry - target > maxDist)
            target = entry - maxDist;
         if(dir == SMC_BULL && target - entry > maxDist)
            target = entry + maxDist;
      }
      return target;
   }

   // 9: probability score (10 binary items).
   int Score(const int dir, const double entry, const SMC_Range &rng,
             const SMC_POI &poi, const int liqBeyond, const bool sweptAsiaInKz,
             const bool fastDisplacement, const bool irlTaken,
             const bool fakeMove, const int htfOverlap, const bool rangeConfirmed)
   {
      int s = 0;
      double ratio = rng.Ratio(entry);
      if(dir == SMC_BEAR ? (ratio >= 0.5) : (ratio <= 0.5))
         s++;                                            // 1 correct EQ side
      if(ratio >= 0.79 || ratio <= 0.21)
         s++;                                            // 2 extreme zone
      if(liqBeyond >= (int)m_cfg.minLiqPools)
         s++;                                            // 3 liquidity beyond
      if(htfOverlap > 0)
         s++;                                            // 4 HTF POI overlap
      if(poi.type == POI_FVG || poi.type == POI_MITIGATION ||
         (m_asia.valid && MathAbs(entry - m_asia.mid) <=
          0.1 * (m_refineS != NULL ? m_refineS.AtrLast() : 0.0)))
         s++;                                            // 5 FVG / mid confluence
      if(sweptAsiaInKz)
         s++;                                            // 6 Asia sweep in KZ
      if(fastDisplacement)
         s++;                                            // 7 fast displacement
      if(m_bias != NULL && m_bias.WeeklyDir() != SMC_NEUTRAL &&
         m_bias.WeeklyDir() == dir)
         s++;                                            // 8 bias alignment (proxy)
      if(irlTaken)
         s++;                                            // 9 IRL taken
      if(fakeMove)
         s++;                                            // 10 fake move at open
      if(!rangeConfirmed && m_cfg.provisionalRiskMult > 0.0)
         s = MathMin(s, m_cfg.fullScore - 1);             // provisional can't be full
      return s;
   }

   double Multiplier(int score, double extraMult)
   {
      double m = 0.0;
      if(score >= m_cfg.fullScore)
         m = 1.0;
      else if(score >= m_cfg.midScore)
         m = 0.75;
      else if(score >= m_cfg.minScore)
         m = 0.5;
      return m * extraMult;
   }

   bool StopOk(const double sl, const double entry)
   {
      double dist = MathAbs(entry - sl);
      if(dist <= 0.0)
         return false;
      if(m_cfg.maxSLPoints > 0.0 && dist > m_cfg.maxSLPoints * m_cfg.point)
         return false;
      if(m_cfg.goldMode)
      {
         double a = (m_entryS != NULL) ? m_entryS.AtrLast() : 0.0;
         if(a > 0.0 && (dist < m_cfg.goldSLMinAtr * a ||
                        dist > m_cfg.goldSLMaxAtr * a))
            return false;
      }
      else
      {
         double pip = Pip();
         if(dist < m_cfg.prefSLMinPips * pip ||
            dist > m_cfg.prefSLMaxPips * pip)
            return false;
      }
      return true;
   }

   bool FastDisplacement(const int dir)
   {
      if(m_entryS == NULL || m_entryS.BarsCount() < 4)
         return false;
      double a = m_entryS.AtrLast();
      if(a <= 0.0)
         return false;
      double sum = 0.0;
      int n = m_entryS.BarsCount();
      for(int k = n - 3; k < n; k++)
      {
         MqlRates r;
         if(m_entryS.GetRate(k, r))
            sum += (r.high - r.low);
      }
      return (sum >= 1.5 * a);
   }

   void FillSignal(TradeSignal &sig, const int dir, const double entry,
                   const double sl, const double risk, const SMC_Range &rng,
                   const SMC_POI &poi, const int liqBeyond,
                   const bool sweptAsiaInKz, const bool irlTaken,
                   const bool fakeMove, const int htfOverlap,
                   const bool rangeConfirmed, const ENUM_SETUP st,
                   const string reason, const double extraMult)
   {
      ResetSignal(sig);
      int sc = Score(dir, entry, rng, poi, liqBeyond, sweptAsiaInKz,
                     FastDisplacement(dir), irlTaken, fakeMove, htfOverlap,
                     rangeConfirmed);
      double riskMult = Multiplier(sc, extraMult);
      if(!rangeConfirmed && m_cfg.provisionalRiskMult > 0.0)
         riskMult = MathMin(riskMult, m_cfg.provisionalRiskMult);
      sig.dir       = dir;
      sig.entry     = entry;
      sig.sl        = sl;
      sig.tp1       = entry + (dir == SMC_BEAR ? -1.0 : 1.0) * Tp1Distance(dir, entry, risk);
      sig.tpRunner  = RunnerTarget(dir, entry, risk, rng);
      sig.score     = sc;
      sig.riskMult  = riskMult;
      sig.setupType = st;
      sig.reason    = reason;
      sig.tf        = (m_rangeS != NULL) ? PERIOD_H1 : PERIOD_M15;
      sig.signalTime = TimeCurrent();
      sig.poiTop    = poi.top;
      sig.poiBottom = poi.bottom;
      sig.poiType   = (int)poi.type;
      sig.valid     = (riskMult > 0.0 && sc >= m_cfg.minScore);
   }

public:
   void Init(CTimeEngine* timeEng, CStructure* rangeS, CStructure* entryS,
             CStructure* refineS, CStructure* h4S,
             CPOIEngine* rangePoi, CPOIEngine* entryPoi,
             CPOIEngine* refinePoi, CPOIEngine* h4Poi,
             CBiasEngine* bias, const SMC_SetupCfg &cfg)
   {
      m_time = timeEng; m_rangeS = rangeS; m_entryS = entryS;
      m_refineS = refineS; m_h4S = h4S;
      m_rangePoi = rangePoi; m_entryPoi = entryPoi;
      m_refinePoi = refinePoi; m_h4Poi = h4Poi;
      m_bias = bias; m_cfg = cfg;
      m_h4Levels = NULL;
      m_h1Levels = NULL;
      m_dayType = DAY_UNSET;
      m_londonHigh = 0.0;
      m_londonLow = 0.0;
      m_londonValid = false;
   }

   void InitAddendum(CCloseLevelEngine* h4Levels, CCloseLevelEngine* h1Levels)
   {
      m_h4Levels = h4Levels;
      m_h1Levels = h1Levels;
   }

   void SetAsia(const SMC_AsiaBox &a) { m_asia = a; }
   void SetDayType(const ENUM_DAYTYPE dt) { m_dayType = dt; }
   void SetLondonBox(const double hi, const double lo)
   {
      m_londonHigh = hi;
      m_londonLow = lo;
      m_londonValid = (hi > lo);
   }

   // 7.A Setup A: range sweep, limit entry.
   bool SetupA(const double price, const int dir, TradeSignal &sig)
   {
      ResetSignal(sig);
      if(m_rangeS == NULL || m_rangePoi == NULL || m_bias == NULL)
         return false;
      SMC_Range rng;
      if(!m_rangeS.GetLastRange(rng))
         return false;
      if(rng.status != SMC_RANGE_CONFIRMED || rng.broken || rng.dir != dir)
         return false;
      double ratio = rng.Ratio(price);
      if(dir == SMC_BEAR ? (ratio < 0.5 && !m_cfg.requireDeepDiscount)
                         : (ratio > 0.5 && !m_cfg.requireDeepDiscount))
         return false;
      if(m_cfg.requireDeepDiscount)
      {
         double lim = m_cfg.deepLevel;
         if(dir == SMC_BEAR ? (ratio < lim) : (ratio > 1.0 - lim))
            return false;
      }

      SMC_POI poi;
      if(!m_rangePoi.Best(dir, rng, price, m_cfg.skipFirstPullback, poi))
         return false;
      double entry = m_rangePoi.EntryLevel(poi, m_cfg.entryLevel);
      if(entry <= rng.irlPrice || entry > rng.rh + 0.5 * m_cfg.point)
         return false;   // must be above IRL at/below RH

      int htfOverlap = 0;
      if(m_bias != NULL)
         m_bias.OverlapsHtfPoi(poi.top, poi.bottom, dir, htfOverlap);
      if(m_cfg.requireHtfPoi && htfOverlap == 0)
         return false;
      int liq = m_rangePoi.LiquidityBeyond(poi,
                m_cfg.equalTolAtr * m_rangeS.AtrLast());
      if(liq < (int)m_cfg.minLiqPools)
         return false;

      double sl = (dir == SMC_BEAR) ? poi.top + Buffer()
                                    : poi.bottom - Buffer();
      if(m_cfg.slAboveStrongHigh)
      {
         SMC_Swing sh;
         if(dir == SMC_BEAR && m_rangeS.GetStrongHigh(sh) && !sh.invalidated)
            sl = MathMax(sl, sh.price + Buffer());
         SMC_Swing slw;
         if(dir == SMC_BULL && m_rangeS.GetStrongLow(slw) && !slw.invalidated)
            sl = MathMin(sl, slw.price - Buffer());
      }
      double risk = MathAbs(entry - sl);
      if(!StopOk(sl, entry))
         return false;

      bool sweptAsia = m_asia.valid &&
                       ((dir == SMC_BEAR && m_asia.high > 0.0 &&
                         price > m_asia.high) ||
                        (dir == SMC_BULL && m_asia.low > 0.0 &&
                         price < m_asia.low));
      bool fake = false;
      if(m_entryS != NULL && m_entryS.BarsCount() >= 2)
      {
         MqlRates first;
         if(m_entryS.GetRate(0, first))
            fake = (dir == SMC_BEAR) ? (first.close > first.open)
                                     : (first.close < first.open);
      }
      FillSignal(sig, dir, entry, sl, risk, rng, poi, liq, sweptAsia,
                 rng.irlTaken, fake, htfOverlap, true, SETUP_A,
                 "A:range_sweep_limit", 1.0);
      return sig.valid;
   }

   // 7.B Setup B: LTF confirmation inside an HTF POI.
   bool SetupB(const double price, const int dir, TradeSignal &sig)
   {
      ResetSignal(sig);
      if(m_entryS == NULL || m_entryPoi == NULL || m_h4Poi == NULL)
         return false;
      // (1) price inside an HTF POI matching the bias side
      int want = (dir == SMC_BEAR) ? LVL_RES : LVL_SUP;
      bool insideHtf = false;
      for(int i = 0; i < m_h4Poi.Count(); i++)
      {
         SMC_POI p;
         if(!m_h4Poi.Get(i, p) || p.mitigated || !p.active)
            continue;
         if((int)p.levelType != want)
            continue;
         if(price >= p.bottom && price <= p.top)
         {
            insideHtf = true;
            break;
         }
      }
      if(!insideHtf)
         return false;

      // (2) LTF strong high/low formed inside the HTF POI
      SMC_Swing strong;
      bool haveStrong = (dir == SMC_BEAR) ? m_entryS.GetStrongHigh(strong)
                                          : m_entryS.GetStrongLow(strong);
      if(!haveStrong || strong.invalidated)
         return false;

      // (3) confirmed LTF range
      SMC_Range rng;
      if(!m_entryS.GetLastRange(rng) ||
         rng.status != SMC_RANGE_CONFIRMED || rng.dir != dir || rng.broken)
         return false;

      // (4) LTF POI above IRL
      SMC_POI poi;
      if(!m_entryPoi.Best(dir, rng, price, m_cfg.skipFirstPullback, poi))
         return false;
      double entry = m_entryPoi.EntryLevel(poi, m_cfg.entryLevel);
      if(entry <= rng.irlPrice)
         return false;
      double sl = (dir == SMC_BEAR)
                ? MathMax(poi.top, strong.price) + Buffer()
                : MathMin(poi.bottom, strong.price) - Buffer();
      double risk = MathAbs(entry - sl);
      if(!StopOk(sl, entry))
         return false;
      int liq = m_entryPoi.LiquidityBeyond(poi,
                m_cfg.equalTolAtr * m_entryS.AtrLast());
      FillSignal(sig, dir, entry, sl, risk, rng, poi, liq, false,
                 rng.irlTaken, false, 1, true, SETUP_B,
                 "B:ltf_confirmation_in_htf_poi", 1.0);
      return sig.valid;
   }

   // 7.C Setup C: Asia sweep / Judas swing.
   bool SetupC(const double price, const int dir, TradeSignal &sig)
   {
      ResetSignal(sig);
      if(!m_asia.valid || m_refineS == NULL || m_entryS == NULL ||
         m_time == NULL)
         return false;
      bool badExtreme = (dir == SMC_BEAR) ? m_asia.highStrong : m_asia.lowStrong;
      if(badExtreme)
         return false;
      datetime ny = m_time.ToNY(TimeCurrent());
      string kz = m_time.KillZone(ny, 0);
      if(kz == "")
         return false;

      double extreme = (dir == SMC_BEAR) ? m_asia.high : m_asia.low;
      bool swept = (dir == SMC_BEAR)
                 ? (price > extreme + m_cfg.sweepMinPoints * m_cfg.point)
                 : (price < extreme - m_cfg.sweepMinPoints * m_cfg.point);
      if(!swept)
         return false;

      // M5 bearish/bullish BOS within the allowed bars after the sweep
      bool bosOk = false;
      SMC_Swing origin;
      if(dir == SMC_BEAR)
      {
         if(m_refineS.GetStrongHigh(origin) && !origin.invalidated &&
            m_refineS.BosCount() > 0)
         {
            SMC_Bos b;
            m_refineS.GetBosAt(m_refineS.BosCount() - 1, b);
            bosOk = (b.dir == SMC_BEAR &&
                     (b.idx - origin.idx) <= m_cfg.sweepToBosBars);
         }
      }
      else
      {
         if(m_refineS.GetStrongLow(origin) && !origin.invalidated &&
            m_refineS.BosCount() > 0)
         {
            SMC_Bos b;
            m_refineS.GetBosAt(m_refineS.BosCount() - 1, b);
            bosOk = (b.dir == SMC_BULL &&
                     (b.idx - origin.idx) <= m_cfg.sweepToBosBars);
         }
      }
      if(!bosOk)
         return false;

      // entry at the M15 candle that swept (body when configured)
      MqlRates sweepCandle;
      ZeroMemory(sweepCandle);
      bool haveSweep = false;
      for(int i = m_entryS.BarsCount() - 1;
          i >= MathMax(0, m_entryS.BarsCount() - 8); i--)
      {
         MqlRates r;
         if(!m_entryS.GetRate(i, r))
            continue;
         if((dir == SMC_BEAR && r.high > extreme) ||
            (dir == SMC_BULL && r.low < extreme))
         {
            sweepCandle = r;
            haveSweep = true;
            break;
         }
      }
      if(!haveSweep)
         return false;

      SMC_POI poi;
      poi.top          = sweepCandle.high;
      poi.bottom       = m_cfg.useBodyWhenWick
                         ? MathMin(sweepCandle.open, sweepCandle.close)
                         : sweepCandle.low;
      poi.type         = POI_WICK;
      poi.levelType    = (dir == SMC_BEAR) ? LVL_RES : LVL_SUP;
      poi.tf           = PERIOD_M15;
      poi.time         = sweepCandle.time;
      poi.originIdx    = m_entryS.BarsCount() - 1;
      poi.mitigated    = false;
      poi.broken       = false;
      poi.flippedFrom  = -1;
      poi.touchCount   = 0;
      poi.overlapCount = 0;
      poi.quality      = 1.0;
      poi.active       = true;

      double entry = m_cfg.useBodyWhenWick
                     ? (poi.top + poi.bottom) / 2.0
                     : m_entryPoi.EntryLevel(poi, m_cfg.entryLevel);
      double sweepHigh = MathMax(extreme, sweepCandle.high);
      double sl = (dir == SMC_BEAR) ? sweepHigh + Buffer()
                                    : MathMin(extreme, sweepCandle.low) - Buffer();
      double risk = MathAbs(entry - sl);
      if(!StopOk(sl, entry))
         return false;

      SMC_Range rng;
      bool haveRng = m_rangeS != NULL && m_rangeS.GetLastRange(rng);
      if(!haveRng)
      {
         // provisional view: [Asia extremes] used only for target construction
         rng.dir       = dir;
         rng.rh        = (dir == SMC_BEAR) ? MathMax(sweepHigh, extreme) : extreme;
         rng.rl        = (dir == SMC_BEAR) ? m_asia.low : MathMin(sweepHigh, extreme);
         rng.status    = SMC_RANGE_PROVISIONAL;
         rng.eq        = (rng.rh + rng.rl) / 2.0;
         rng.irlPrice  = 0.0;
         rng.irlIdx    = -1;
         rng.irlTaken  = false;
         rng.broken    = false;
      }

      int htfOverlap = 0;
      if(m_bias != NULL)
         m_bias.OverlapsHtfPoi(poi.top, poi.bottom, dir, htfOverlap);
      if(m_cfg.requireHtfPoi && htfOverlap == 0)
         return false;
      int liq = m_entryPoi.LiquidityBeyond(poi,
                m_cfg.equalTolAtr * m_entryS.AtrLast());
      bool fake = false;
      if(m_entryS.BarsCount() >= 2)
      {
         MqlRates f;
         if(m_entryS.GetRate(0, f))
            fake = (dir == SMC_BEAR) ? (f.close > f.open) : (f.close < f.open);
      }
      FillSignal(sig, dir, entry, sl, risk, rng, poi, liq, true,
                 false, fake, htfOverlap, haveRng, SETUP_C,
                 "C:asia_sweep_judas", haveRng ? 1.0 : m_cfg.provisionalRiskMult);
      return sig.valid;
   }

   // 7.D Setup D: ping-pong counter-trend scalp (default disabled by EA).
   bool SetupD(const double price, const int dir, const SMC_Range &parent,
               const double riskMult, TradeSignal &sig)
   {
      ResetSignal(sig);
      if(m_entryPoi == NULL)
         return false;
      SMC_POI poi;
      if(!m_entryPoi.Best(dir, parent, price, false, poi))
         return false;
      double entry = m_entryPoi.EntryLevel(poi, m_cfg.entryLevel);
      double sl = (dir == SMC_BEAR) ? poi.top + Buffer()
                                    : poi.bottom - Buffer();
      double risk = MathAbs(entry - sl);
      if(!StopOk(sl, entry))
         return false;
      // target IRL only, never ERL
      double target = parent.irlPrice;
      if(target <= 0.0)
         return false;
      SMC_Range r = parent;
      r.rl = (dir == SMC_BEAR) ? target : r.rl;
      r.rh = (dir == SMC_BULL) ? target : r.rh;
      FillSignal(sig, dir, entry, sl, risk, r, poi, 1, false, false,
                 false, 0, true, SETUP_D, "D:ping_pong_scalp", riskMult);
      sig.tpRunner = target;
      return sig.valid;
   }

   // A3.3 Setup E: Asia-strong mitigation (continuation in bias direction).
   // Asia created a strong low (buy) / strong high (sell). London is expected
   // to TAP the H4 level and continue, not sweep beyond the strong point.
   bool SetupE(const double price, const int dir, const int bias,
               TradeSignal &sig)
   {
      ResetSignal(sig);
      if(m_h4Levels == NULL || !m_asia.valid || m_time == NULL)
         return false;
      if(bias != dir)
         return false;                       // A3.3 (5) must align with bias
      bool okDay = (dir == SMC_BULL && m_dayType == DAY_STRONG_LOW) ||
                   (dir == SMC_BEAR && m_dayType == DAY_STRONG_HIGH);
      if(!okDay)
         return false;
      string kz = m_time.KillZone(m_time.ToNY(TimeCurrent()), 0);
      if(kz == "")
         return false;

      double anchor = (dir == SMC_BULL) ? m_asia.low : m_asia.high;
      double tol = (m_h4S != NULL)
                 ? 0.1 * m_h4S.AtrLast() : m_cfg.equalTolAtr * m_cfg.point;
      SMC_Level lvl;
      if(!m_h4Levels.BestLevel(dir, anchor, MathMax(tol, 5.0 * m_cfg.point), lvl))
         return false;

      // A1.9: when two levels cluster, the top needs an M15 BOS confirmation
      // (handled by SetupB) and the extreme level takes the limit.
      SMC_Level top, bottom;
      double cluster = 0.4 * ((m_entryS != NULL) ? m_entryS.AtrLast() : tol);
      if(m_h4Levels.TwoCloseLevels(dir, anchor, cluster, top, bottom))
         lvl = bottom;

      double entry = lvl.price;
      bool tapped = (dir == SMC_BULL) ? (price <= entry + m_cfg.point)
                                      : (price >= entry - m_cfg.point);
      if(!tapped)
         return false;

      double sl;
      SMC_Swing sp;
      bool haveSp = (dir == SMC_BULL) ? m_h4S.GetStrongLow(sp)
                                      : m_h4S.GetStrongHigh(sp);
      if(haveSp && !sp.invalidated)
         sl = (dir == SMC_BULL) ? sp.price - Buffer() : sp.price + Buffer();
      else
         sl = (dir == SMC_BULL) ? entry - Buffer() : entry + Buffer();
      double risk = MathAbs(entry - sl);
      if(!StopOk(sl, entry))
         return false;

      SMC_Range rng;
      bool haveRng = (m_rangeS != NULL) && m_rangeS.GetLastRange(rng) &&
                     rng.dir == dir;
      if(!haveRng)
      {
         rng.dir       = dir;
         rng.rh        = (dir == SMC_BEAR) ? m_asia.high : anchor;
         rng.rl        = (dir == SMC_BEAR) ? anchor : m_asia.low;
         rng.status    = SMC_RANGE_PROVISIONAL;
         rng.eq        = (rng.rh + rng.rl) / 2.0;
         rng.irlPrice  = anchor;
         rng.irlIdx    = -1;
         rng.irlTaken  = false;
         rng.broken    = false;
      }
      SMC_POI poi;
      ZeroMemory(poi);
      poi.top = entry + m_cfg.point;
      poi.bottom = entry - m_cfg.point;
      poi.type = POI_CLOSE_LEVEL;
      poi.levelType = (dir == SMC_BEAR) ? LVL_RES : LVL_SUP;
      poi.tf = PERIOD_H4;
      poi.time = lvl.barTime;
      poi.quality = lvl.quality;
      poi.active = true;

      FillSignal(sig, dir, entry, sl, risk, rng, poi, 1, false,
                 rng.irlTaken, false, 1, haveRng, SETUP_E,
                 "E:asia_strong_mitigation",
                 haveRng ? 1.0 : m_cfg.provisionalRiskMult);
      sig.tp1 = (dir == SMC_BULL) ? m_asia.high : m_asia.low;
      return sig.valid;
   }

   // A3.4 Setup F: news day, NY kill zone only. London builds liquidity.
   bool SetupF(const double price, const int dir, const int bias,
               TradeSignal &sig)
   {
      ResetSignal(sig);
      if(m_dayType != DAY_NEWS || m_time == NULL || m_h4Levels == NULL)
         return false;
      if(bias != dir)
         return false;
      datetime ny = m_time.ToNY(TimeCurrent());
      if(m_time.KillZone(ny, 0) != "NEW_YORK")
         return false;
      if(!m_londonValid)
         return false;

      double source = (dir == SMC_BEAR) ? m_londonHigh : m_londonLow;
      bool swept = (dir == SMC_BEAR)
                 ? (price > source + m_cfg.sweepMinPoints * m_cfg.point)
                 : (price < source - m_cfg.sweepMinPoints * m_cfg.point);
      if(!swept)
         return false;

      SMC_Level lvl;
      if(!m_h4Levels.BestLevel(dir, source,
                               0.5 * ((m_h4S != NULL) ? m_h4S.AtrLast()
                                                      : m_cfg.point), lvl))
         return false;
      double entry = lvl.price;
      bool reached = (dir == SMC_BEAR) ? (price >= entry - m_cfg.point)
                                       : (price <= entry + m_cfg.point);
      if(!reached)
         return false;

      double sl;
      SMC_Swing sp;
      bool haveSp = false;
      if(dir == SMC_BEAR)
         haveSp = (m_h4S != NULL && m_h4S.GetStrongHigh(sp) && !sp.invalidated);
      else
         haveSp = (m_h4S != NULL && m_h4S.GetStrongLow(sp) && !sp.invalidated);
      if(haveSp)
         sl = (dir == SMC_BEAR) ? sp.price + Buffer() : sp.price - Buffer();
      else
         sl = entry + (dir == SMC_BEAR ? 1.0 : -1.0) *
              m_cfg.prefSLMaxPips * Pip();
      double risk = MathAbs(entry - sl);
      if(!StopOk(sl, entry))
         return false;

      SMC_Range rng;
      bool haveRng = (m_rangeS != NULL) && m_rangeS.GetLastRange(rng) &&
                     rng.dir == dir;
      if(!haveRng)
      {
         rng.dir = dir;
         rng.rh = (dir == SMC_BEAR) ? MathMax(source, m_asia.high) : source;
         rng.rl = (dir == SMC_BEAR) ? source : MathMin(source, m_asia.low);
         rng.status = SMC_RANGE_PROVISIONAL;
         rng.eq = (rng.rh + rng.rl) / 2.0;
         rng.irlPrice = source;
         rng.irlIdx = -1;
         rng.irlTaken = false;
         rng.broken = false;
      }
      SMC_POI poi;
      ZeroMemory(poi);
      poi.top = entry + m_cfg.point;
      poi.bottom = entry - m_cfg.point;
      poi.type = POI_CLOSE_LEVEL;
      poi.levelType = (dir == SMC_BEAR) ? LVL_RES : LVL_SUP;
      poi.tf = PERIOD_H4;
      poi.time = lvl.barTime;
      poi.quality = lvl.quality;
      poi.active = true;
      FillSignal(sig, dir, entry, sl, risk, rng, poi, 1, false,
                 false, false, 1, haveRng, SETUP_F,
                 "F:news_day_ny", haveRng ? 1.0 : m_cfg.provisionalRiskMult);
      sig.tp1 = (dir == SMC_BULL) ? m_asia.low : m_asia.high;
      return sig.valid;
   }

   // Evaluate in priority order A, B, C, then addendum E/F when enabled.
   bool Evaluate(const double price, const int dir, TradeSignal &sig)
   {
      if(SetupA(price, dir, sig))
         return true;
      if(SetupB(price, dir, sig))
         return true;
      if(SetupC(price, dir, sig))
         return true;
      if(m_dayType == DAY_STRONG_HIGH || m_dayType == DAY_STRONG_LOW)
      {
         if(SetupE(price, dir, m_bias != NULL ? m_bias.Bias() : dir, sig))
            return true;
      }
      if(m_dayType == DAY_NEWS)
      {
         if(SetupF(price, dir, m_bias != NULL ? m_bias.Bias() : dir, sig))
            return true;
      }
      return false;
   }

   int ScoreOf(const TradeSignal &s) const { return s.score; }
};

#endif // SMC_SETUPS_MQH
