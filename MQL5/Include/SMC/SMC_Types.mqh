//+------------------------------------------------------------------+
//|  SMC_Types.mqh                                                   |
//|  Shared enums / structures for the SMC bot (MT5, build 3000+)     |
//|  Part of the Phase-1 deliverable: no inputs, no trading code.     |
//+------------------------------------------------------------------+
#ifndef SMC_TYPES_MQH
#define SMC_TYPES_MQH

//--- direction
#define SMC_BULL             1
#define SMC_BEAR            -1
#define SMC_NEUTRAL          0

//--- range status (kept as string so logs/reports match the Python engine)
#define SMC_RANGE_CONFIRMED   "CONFIRMED"
#define SMC_RANGE_PROVISIONAL "PROVISIONAL"

//--- broker DST modes
#define SMC_DST_NONE 0
#define SMC_DST_US   1
#define SMC_DST_EU   2

//+------------------------------------------------------------------+
//| A session window expressed in minutes after New York midnight.    |
//| endMin is exclusive; startMin > endMin means the window wraps.    |
//+------------------------------------------------------------------+
struct SMC_Session
{
   string            name;
   int               startMin;
   int               endMin;

   bool Wraps()
   {
      return (startMin > endMin);
   }

   bool Contains(int minutes)
   {
      int m = minutes % 1440;
      if(m < 0)
         m += 1440;
      if(Wraps())
         return (m >= startMin || m < endMin);
      return (m >= startMin && m < endMin);
   }

   // inside, or within `grace` minutes after the end (section 3)
   bool ContainsGrace(int minutes, int grace)
   {
      int m = minutes % 1440;
      if(m < 0)
         m += 1440;
      if(Contains(m))
         return true;
      if(grace <= 0)
         return false;
      int d = m - endMin;
      if(d < 0)
         d += 1440;
      return (d < grace);
   }
};

//+------------------------------------------------------------------+
//| Confirmed fractal point (section 4.1)                            |
//+------------------------------------------------------------------+
struct SMC_Swing
{
   int               idx;            // chronological bar index in the engine
   datetime          time;
   double            price;
   bool              isHigh;
   bool              broken;
   datetime          brokenTime;
   bool              brokenByWick;
   bool              swept;          // section 4.3
   bool              strong;         // section 4.4
   bool              invalidated;    // close beyond it
   int               originIdx;      // bar index of the opposite swing before it
   double            originPrice;
};

//+------------------------------------------------------------------+
//| Break of structure event (section 4.2)                           |
//+------------------------------------------------------------------+
struct SMC_Bos
{
   int               dir;            // +1 bullish, -1 bearish
   int               idx;            // bar that produced the close/break
   datetime          time;
   int               swingIdx;       // bar index of the broken swing
   double            swingPrice;
};

//+------------------------------------------------------------------+
//| Trading range (section 4.5) with premium/discount helpers (4.6)  |
//+------------------------------------------------------------------+
struct SMC_Range
{
   int               dir;            // -1 bearish, +1 bullish
   double            rh;
   double            rl;
   string            status;
   int               confirmIdx;
   datetime          confirmTime;
   int               rhIdx;
   int               rlIdx;
   int               strongIdx;
   double            eq;
   double            irlPrice;
   int               irlIdx;
   bool              irlTaken;
   bool              broken;

   void RecalcEq()
   {
      eq = (rh + rl) / 2.0;
   }

   double Ratio(double price) const
   {
      if(rh <= rl)
         return 0.0;
      return (price - rl) / (rh - rl);
   }

   bool InPremium(double price) const
   {
      return (Ratio(price) >= 0.5);
   }

   bool InDiscount(double price) const
   {
      return (Ratio(price) <= 0.5);
   }
};

//+------------------------------------------------------------------+
//| Pre-confirmation state (PROVISIONAL range)                       |
//+------------------------------------------------------------------+
struct SMC_RangeCandidate
{
   int               direction;      // -1 after strong high, +1 after strong low
   double            rh;             // strong-point price
   int               idxExtreme;     // bar index of the strong point
   double            extremeLow;     // running LL (bear) / running HH (bull)
   int               extremeIdx;
};

//=============================================================================
//  PHASE 2+ additions.  The rules these represent are additive: LEGACY POI
//  behaviour stays the default, new behaviour is selected by inputs.
//=============================================================================

//--- POI types (section 5). Values are stable across MQL5 and Python.
enum ENUM_POI_TYPE
{
   POI_ORDER_BLOCK = 0,      // 5.x order block (zone)
   POI_BREAKER     = 1,      // failed OB used in the opposite direction
   POI_WICK        = 2,      // rejection / swept-liquidity wick
   POI_FVG         = 3,      // 3-candle imbalance
   POI_MITIGATION  = 4,      // optional hidden base
   POI_CLOSE_LEVEL = 5       // A1 close-price level (degenerate zone)
};

//--- close-level types (A1.2) and flips (A1.4)
enum ENUM_LEVEL_TYPE
{
   LVL_RES = 0,              // "A" closing-price peak -> resistance/sell
   LVL_SUP = 1               // "V" closing-price trough -> support/buy
};

//--- setups (7.A-7.D, A3.3, A3.4, A8)
enum ENUM_SETUP
{
   SETUP_NONE = 0,
   SETUP_A    = 1,
   SETUP_B    = 2,
   SETUP_C    = 3,
   SETUP_D    = 4,
   SETUP_E    = 5,
   SETUP_F    = 6,
   SETUP_M    = 7
};

//--- day types (A3.1)
enum ENUM_DAYTYPE
{
   DAY_UNSET = 0,
   DAY_NEWS,
   DAY_TRENDING,
   DAY_STRONG_HIGH,
   DAY_STRONG_LOW,
   DAY_CONSOLIDATING
};

//--- close-level POI model selector (addendum switch)
enum ENUM_POI_MODEL
{
   POI_MODEL_LEGACY      = 0,
   POI_MODEL_CLOSE_LEVEL = 1
};

//--- stop-loss mode (A1.10)
enum ENUM_SL_MODE
{
   SL_MODE_TIGHT         = 0,
   SL_MODE_STRONG_POINT  = 1
};

//--- counter-trend break TFs for range expansion (A4)
enum ENUM_COUNTER_BREAK_TF
{
   COUNTER_SAME     = 0,
   COUNTER_ONE_LOWER = 1
};

//+------------------------------------------------------------------+
//| Point of interest (section 5 zone / A1 level).                    |
//| For LEVEL model top==bottom==price (band applied at order time).  |
//+------------------------------------------------------------------+
struct SMC_POI
{
   double            top;             // upper edge of zone (or level price)
   double            bottom;          // lower edge of zone (or level price)
   ENUM_POI_TYPE     type;
   ENUM_LEVEL_TYPE   levelType;       // LVL_RES / LVL_SUP for close levels
   ENUM_TIMEFRAMES   tf;
   datetime          time;            // formation time (bar time)
   int               originIdx;       // bar index in the source structure
   bool              mitigated;       // 5.1
   bool              broken;          // A1.4 body-close break
   int               flippedFrom;     // A1.4: LVL_RES/LVL_SUP or -1
   int               touchCount;      // A1.3 freshness
   int               overlapCount;    // 5.5 number of overlapping HTF POIs
   double            quality;         // A1.6 level quality / 5.5 priority
   bool              active;          // currently usable
};

//+------------------------------------------------------------------+
//| Close-price level (addendum A1). A degenerate POI zone.           |
//+------------------------------------------------------------------+
struct SMC_Level
{
   double            price;
   ENUM_LEVEL_TYPE   type;          // LVL_RES (A peak) / LVL_SUP (V trough)
   ENUM_TIMEFRAMES   tf;
   datetime          barTime;
   int               touchCount;    // A1.3 freshness
   bool              used;
   bool              broken;        // A1.4 body-close break
   int               flippedFrom;   // original type before flip, else -1
   bool              fresh;
   bool              active;
   double            quality;       // A1.6
};

//+------------------------------------------------------------------+
//| Asia box snapshot (section 3 / 7.0).                              |
//+------------------------------------------------------------------+
struct SMC_AsiaBox
{
   datetime          day;             // NY date whose midnight ends the box
   double            high;
   double            low;
   double            mid;
   double            range;
   double            openP;
   double            closeP;
   double            efficiency;
   bool              valid;
   bool              highStrong;
   bool              lowStrong;
};

//+------------------------------------------------------------------+
//| Trade signal produced by any entry model (section 12).            |
//+------------------------------------------------------------------+
struct TradeSignal
{
   int               dir;             // SMC_BULL / SMC_BEAR / SMC_NEUTRAL
   double            entry;
   double            sl;
   double            tp1;
   double            tpRunner;
   int               score;
   double            riskMult;
   ENUM_SETUP        setupType;
   string            reason;          // reason code, also logged
   ENUM_TIMEFRAMES   tf;
   datetime          signalTime;
   datetime          kzStart;         // A5 timing sanity check
   double            poiTop;
   double            poiBottom;
   int               poiType;
   bool              valid;
};

void ResetSignal(TradeSignal &s)
{
   s.dir       = SMC_NEUTRAL;
   s.entry     = 0.0;
   s.sl        = 0.0;
   s.tp1       = 0.0;
   s.tpRunner  = 0.0;
   s.score     = 0;
   s.riskMult  = 1.0;
   s.setupType = SETUP_NONE;
   s.reason    = "";
   s.tf        = PERIOD_CURRENT;
   s.signalTime = 0;
   s.kzStart   = 0;
   s.poiTop    = 0.0;
   s.poiBottom = 0.0;
   s.poiType   = POI_ORDER_BLOCK;
   s.valid     = false;
}

#endif // SMC_TYPES_MQH
