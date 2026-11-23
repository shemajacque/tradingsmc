//+------------------------------------------------------------------+
//|  SMC_Bot.mq5                                                     |
//|  Smart-money / liquidity intraday Expert Advisor.                 |
//|                                                                  |
//|  Primary implementation of the rule set in sections 1-15 and the  |
//|  addendum (A1-A10).  One EA instance per symbol (GBPUSD / XAUUSD).|
//|                                                                  |
//|  KNOWN LIMITS (see README):                                       |
//|   - The source methodology is partly discretionary; this is an    |
//|     explicit rule-based approximation and may differ from the     |
//|     instructor's discretionary trading.                           |
//|   - Tight stops (2-5 pips) are very sensitive to spread, slippage |
//|     and broker feed differences.                                  |
//|   - Past performance does not guarantee future results. Demo      |
//|     first. This is not financial advice.                          |
//+------------------------------------------------------------------+
#property strict
#property copyright "SMC rule-based EA"
#property version "1.00"
#property description "Rule-based SMC/liquidity EA. DEMO BY DEFAULT (InpLiveTradingEnabled=false)."

#include <SMC/SMC_Types.mqh>
#include <SMC/SMC_Time.mqh>
#include <SMC/SMC_Structure.mqh>
#include <SMC/SMC_POI.mqh>
#include <SMC/SMC_Bias.mqh>
#include <SMC/SMC_Setups.mqh>
#include <SMC/SMC_Logger.mqh>
#include <SMC/SMC_Risk.mqh>
#include <SMC/SMC_Trade.mqh>
#include <SMC/SMC_CloseLevel.mqh>
#include <SMC/SMC_TopDown.mqh>
#include <SMC/MSNR_Levels.mqh>
#include <SMC/MSNR_Storyline.mqh>
#include <SMC/MSNR_SetupM.mqh>

//==================== INPUTS ================================================
input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpBiasTF1   = PERIOD_D1;
input ENUM_TIMEFRAMES InpBiasTF2   = PERIOD_H4;
input ENUM_TIMEFRAMES InpRangeTF   = PERIOD_H1;
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M15;
input ENUM_TIMEFRAMES InpRefineTF  = PERIOD_M5;
input ENUM_TIMEFRAMES InpConfirmTF = PERIOD_M15;
input ENUM_TIMEFRAMES InpMinLevelTF= PERIOD_M15;

input group "=== Session / time (New York) ==="
input bool   InpAutoServerOffset      = true;
input double InpBrokerGMTOffsetWinter = 2.0;
input double InpBrokerGMTOffsetSummer = 3.0;
input int    InpBrokerDSTMode         = SMC_DST_US;   // 0 none, 1 US, 2 EU
input bool   InpAsiaStandardPreset    = false;        // false ICT 17-00, true 19-00
input int    InpAsiaStartHour         = 17;
input int    InpLKZStartHour          = 2;
input int    InpLKZEndHour            = 5;
input int    InpNYKZStartHour         = 7;
input int    InpNYKZEndHour           = 10;
input int    InpEntryGraceMinutes     = 30;
input bool   InpNoAsiaTrading         = true;
input int    InpCloseHourNY           = 12;
input int    InpFridayCutoffHourNY    = 12;
input int    InpFridayCloseHourNY     = 16;
input int    InpNoEntryAfterHourNY    = 12;

input group "=== Structure (4.x) ==="
input int    InpSwingLen              = 1;
input bool   InpBOSByClose            = true;
input double InpEqualTolATR           = 0.1;
input int    InpATRPeriod             = 14;
input int    InpRangeHistory          = 3;
input bool   InpStrongInvalidateByClose = true;
input bool   InpAllowProvisionalRange = false;

input group "=== POI (5.x LEGACY) ==="
input int    InpPOIModel              = POI_MODEL_LEGACY;  // 0 LEGACY, 1 CLOSE_LEVEL
input double InpMinWickRatio          = 0.5;
input bool   InpOBBodyOnly            = false;
input double InpMaxPOIHeightATR       = 0.6;
input double InpEntryLevel            = 0.5;
input bool   InpUseBodyWhenWick       = true;
input bool   InpUseMitigation         = false;
input bool   InpSkipFirstPullbackPOI  = true;
input int    InpMinLiquidityPools     = 1;
input bool   InpRequireHTFPOI         = true;
input double InpTrendToleranceATR     = 0.15;
input int    InpOBLookback            = 12;

input group "=== Stops / targets (8) ==="
input int    InpSLMode                = SL_MODE_TIGHT;  // 0 TIGHT, 1 STRONG_POINT
input double InpSLBufferPoints        = 0.0;
input double InpSLBufferSpreadMult    = 1.0;
input double InpSLExtraPoints         = 0.0;
input bool   InpSLAboveStrongHigh     = false;
input double InpPreferredSLMinPips    = 2.0;
input double InpPreferredSLMaxPips    = 5.0;
input double InpMaxSLPoints           = 0.0;
input double InpGoldSLMinATR          = 0.15;
input double InpGoldSLMaxATR          = 0.5;
input double InpGoldMaxSLPips         = 20.0;
input double InpGoldPipSize           = 0.10;
input double InpTP1Percent            = 40.0;
input double InpTP1_R                 = 1.5;
input double InpBEBufferPoints        = 0.0;
input double InpERLOffsetPoints       = 0.0;
input double InpMaxTargetR            = 15.0;
input bool   InpTrailBySwing          = false;
input bool   InpEarlyBE               = true;
input double InpEarlyBE_R             = 0.7;
input bool   InpInvalidateByClose     = true;
input double InpInvalidateExtraPoints = 0.0;
input int    InpMaxReentries          = 1;

input group "=== Probability score (9) ==="
input int    InpScoreFull             = 7;
input int    InpScoreMid              = 5;
input int    InpScoreMin              = 3;
input double InpDeepLevel             = 0.705;
input bool   InpRequireDeepDiscount   = false;

input group "=== Risk (10) ==="
input int    InpRiskMode              = 0;      // 0 percent, 1 fixed money
input double InpRiskPercent           = 0.5;
input double InpRiskMoney             = 100.0;
input double InpMaxTradesPerDay        = 3;
input double InpMaxDailyLossPct        = 3.0;
input double InpMaxWeeklyLossPct       = 6.0;
input double InpMaxOpenRiskPct         = 1.5;
input double InpEquityStopPct          = 20.0;
input int    InpMaxConsecLosses        = 3;
input int    InpMaxOpenTrades          = 2;
input int    InpMaxCorrelatedTrades    = 1;
input bool   InpEnableHedging          = false;
input bool   InpEnablePingPong         = false;
input double InpPingPongRiskMult       = 0.5;
input double InpRiskReduceFactor       = 0.5;

input group "=== Filters / entries (7) ==="
input double InpMaxSpreadPoints       = 30.0;
input int    InpNewsBufferMin          = 30;
input string InpNewsFilePath           = "news.csv";
input double InpAsiaTrendMax          = 0.65;
input double InpAsiaMinRangeATR       = 1.0;
input bool   InpSkipMonday            = false;
input double InpSweepMinPoints        = 0.0;
input int    InpSweepToBOSMaxBars     = 24;
input int    InpPendingExpiryBars     = 8;
input bool   InpTradeNeutralBias      = false;
input bool   InpTradeAgainstBiasAsia  = false;
input int    InpSweepEarlyMinutes     = 45;
input int    InpGraceMinutes          = 45;
input bool   InpTradeNewsDay          = true;
input int    InpNewsDayWindowStart     = 7;
input int    InpNewsDayWindowEnd       = 12;

input group "=== Addendum: top-down / close-level / MSNR ==="
input bool   InpRequireWeeklyAgree    = true;
input int    InpCounterBreakTFs       = COUNTER_SAME;
input bool   InpOneSetupPerDay        = false;
input bool   InpNoRunnerIfNoExpansion = true;
input bool   InpEnableMSNR            = false;
input double InpMaxRefinePips         = 5.0;
input double InpMaxRefineATR          = 0.25;
input double InpLevelBandPoints       = 2.0;
input int    InpHTFConflictTolerancePoints = 5;
input double InpClusterPoints         = 4.0;
input double InpConfirmRiskMult       = 0.5;
input bool   InpLevelUseOrderBlockMap = false;
input bool   InpBreakByBodyClose      = true;

input group "=== MSNR (optional, A6-A8) ==="
input int    InpMSNRMinScore          = 4;
input double InpMSNRSLBufferPoints    = 5.0;
input double InpMSNR_TP1_Percent      = 40.0;
input double InpMSNR_TP2_Percent      = 30.0;
input double InpMSNR_TP3_Percent      = 30.0;
input double InpMinGapPoints          = 3.0;
input double InpQMSLBufferPoints      = 5.0;
input bool   InpRequireTurtleSoup     = true;
input double InpProtectedRetracePct   = 50.0;
input bool   InpAllowFreshOnHTF       = true;
input bool   InpLastLiquidityRequired = true;

input group "=== Execution / safety ==="
input bool   InpLiveTradingEnabled    = false;   // DEMO BY DEFAULT
input ulong  InpMagic                 = 20240601;
input int    InpSlippagePoints        = 30;
input int    InpBarsToLoad            = 2500;
input string InpLogFile               = "decisions_log.csv";
input bool   InpDebugLog              = true;

//==================== GLOBALS ===============================================
CTimeEngine        g_time;
CStructure*        g_structs[8];
CPOIEngine*        g_pois[8];
CCloseLevelEngine* g_levels[8];
CTopDown           g_topDown;
CMSNRLevels*       g_msnrL[8];
CMSNRStoryline     g_msnrStory;
CMSNRSetupM        g_msnrSetup;
bool               g_msnrReady = false;
CBiasEngine        g_bias;
CSetups            g_setups;
CDecisionLogger    g_log;
CRisk              g_risk;
CTradeEngine       g_trade;
SMC_SetupCfg       g_cfg;
SMC_AsiaBox        g_asia;
bool               g_ready = false;
datetime           g_lastEntryBar = 0;
datetime           g_lastStructureBar = 0;
datetime           g_lastDayChecked = 0;
datetime           g_lastWeekChecked = 0;
datetime           g_lastMonthChecked = 0;
datetime           g_lastD1Checked = 0;
ENUM_DAYTYPE        g_dayType = DAY_UNSET;
datetime           g_kzStart = 0;
int                g_mainSetupsToday = 0;
string             g_symbol;

//--- runtime overrides from the management web app (SMC_bot_config.csv)
bool               g_webEnabled = true;
bool               g_webLive = false;
double             g_webRiskPercent = 0.0;
double             g_webMaxSpread = 0.0;
int                g_webMaxTrades = 0;
int                g_webScoreMin = 0;
datetime           g_webConfigTime = 0;
datetime           g_webLastSeen = 0;
string             g_lastSignalReason = "NONE";
datetime           g_lastSignalTime = 0;
bool               g_killSwitch = false;
bool               g_killApplied = false;
datetime           g_equityDay = 0;

bool EffectiveLive()
{
   return (InpLiveTradingEnabled || g_webLive);
}

//==================== HELPERS ===============================================
int TfIndex(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return 0;
      case PERIOD_M5:  return 0;
      case PERIOD_M15: return 1;
      case PERIOD_M30: return 2;
      case PERIOD_H1:  return 3;
      case PERIOD_H4:  return 4;
      case PERIOD_D1:  return 5;
      case PERIOD_W1:  return 6;
      case PERIOD_MN1: return 7;
   }
   return 1;
}

bool IsGold()
{
   return (StringFind(g_symbol, "XAU") >= 0 || StringFind(g_symbol, "GOLD") >= 0);
}

double PipSize()
{
   return IsGold() ? InpGoldPipSize : 10.0 * _Point;
}

bool NewBar(const ENUM_TIMEFRAMES tf, datetime &last)
{
   datetime t = iTime(g_symbol, tf, 0);
   if(t <= 0)
      return false;
   if(t == last)
      return false;
   last = t;
   return true;
}

void UpdateAllStructures()
{
   for(int i = 0; i < 8; i++)
   {
      if(g_structs[i] == NULL)
         continue;
      g_structs[i].Update(InpBarsToLoad);
   }
   for(int i = 0; i < 8; i++)
   {
      if(g_pois[i] == NULL)
         continue;
      g_pois[i].Rebuild();
      if(g_levels[i] != NULL)
         g_levels[i].Rebuild();
   }
}

// Section 3 / 7.0: compute the Asia box from M15 highs/lows only.
void ComputeAsiaBox(const datetime nyMidnight)
{
   datetime start = nyMidnight - 86400 +
                    (InpAsiaStandardPreset ? 19 : InpAsiaStartHour) * 3600;
   datetime end = nyMidnight;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(g_symbol, PERIOD_M15, start, end, r);
   ZeroMemory(g_asia);
   if(n <= 0)
      return;
   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < n; i++)
   {
      if(r[i].high > hi) hi = r[i].high;
      if(r[i].low < lo) lo = r[i].low;
   }
   g_asia.high = hi;
   g_asia.low = lo;
   g_asia.mid = (hi + lo) / 2.0;
   g_asia.range = hi - lo;
   g_asia.openP = r[0].open;
   g_asia.closeP = r[n - 1].close;
   g_asia.efficiency = (g_asia.range > 0.0)
                     ? MathAbs(g_asia.closeP - g_asia.openP) / g_asia.range : 0.0;
   g_asia.day = nyMidnight;
   g_asia.valid = true;

   // strong extremes: sweep + BOS inside Asia on M15 (section 7.0)
   CStructure* asia = g_structs[TfIndex(PERIOD_M15)];
   if(asia != NULL)
   {
      SMC_Swing sh, sl;
      g_asia.highStrong = (asia.GetStrongHigh(sh) && !sh.invalidated &&
                           sh.swept && sh.idx >= 0 &&
                           asia.BarTimeAt(sh.idx) >= start);
      g_asia.lowStrong = (asia.GetStrongLow(sl) && !sl.invalidated &&
                          sl.swept && sl.idx >= 0 &&
                          asia.BarTimeAt(sl.idx) >= start);
   }
   g_setups.SetAsia(g_asia);
   if(InpDebugLog)
      Print("ASIA day=", TimeToString(nyMidnight, TIME_DATE),
            " H=", DoubleToString(hi, 5), " L=", DoubleToString(lo, 5),
            " eff=", DoubleToString(g_asia.efficiency, 3),
            " Hstrong=", g_asia.highStrong, " Lstrong=", g_asia.lowStrong);
}

// A3.1 day-type classifier. Section 7.0 (skip day) is applied upstream.
ENUM_DAYTYPE ClassifyDay(const datetime nyMidnight)
{
   if(!g_asia.valid)
      return DAY_CONSOLIDATING;
   if(g_risk.HasNewsDayWindow(nyMidnight, InpNewsDayWindowStart,
                              InpNewsDayWindowEnd, &g_time))
      return DAY_NEWS;
   if(g_asia.efficiency > InpAsiaTrendMax)
      return DAY_TRENDING;
   if(g_asia.highStrong && g_asia.lowStrong)
      return DAY_TRENDING;
   if(g_asia.highStrong)
      return DAY_STRONG_HIGH;
   if(g_asia.lowStrong)
      return DAY_STRONG_LOW;
   return DAY_CONSOLIDATING;
}

// A3.4: London session high/low (NY 02:00-05:00) used as the news-day sweep
// source and as a liquidity-build reference.
void ComputeLondonBox(const datetime nyMidnight)
{
   datetime start = nyMidnight + InpLKZStartHour * 3600;
   datetime end   = nyMidnight + InpLKZEndHour * 3600;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(g_symbol, PERIOD_M15, start, end, r);
   if(n <= 0)
      return;
   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < n; i++)
   {
      if(r[i].high > hi) hi = r[i].high;
      if(r[i].low < lo) lo = r[i].low;
   }
   g_setups.SetLondonBox(hi, lo);
}

bool SkipDay()
{
   if(!g_asia.valid)
      return false;
   if(InpSkipMonday && CTimeEngine::IsMonday(g_time.ToNY(TimeCurrent())))
      return true;
   if(g_asia.efficiency > InpAsiaTrendMax)
   {
      CStructure* h1 = g_structs[TfIndex(PERIOD_H1)];
      double a = (h1 != NULL) ? h1.AtrLast() : 0.0;
      if(a > 0.0 && g_asia.range > InpAsiaMinRangeATR * a)
         return true;
   }
   return false;
}

//--- read runtime overrides written by the management web app --------------
void ReadWebConfig()
{
   int h = FileOpen("SMC_bot_config.csv", FILE_READ | FILE_CSV | FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
      return;
   while(!FileIsEnding(h))
   {
      string key = FileReadString(h);
      string val = FileReadString(h);
      if(key == "")
         continue;
      StringToLower(key);
      if(key == "enabled")           g_webEnabled = (StringToInteger(val) != 0);
      else if(key == "live")         g_webLive = (StringToInteger(val) != 0);
      else if(key == "risk_percent") g_webRiskPercent = StringToDouble(val);
      else if(key == "max_spread")   g_webMaxSpread = StringToDouble(val);
      else if(key == "max_trades")   g_webMaxTrades = (int)StringToInteger(val);
      else if(key == "score_min")    g_webScoreMin = (int)StringToInteger(val);
      else if(key == "kill_switch")  g_killSwitch = (StringToInteger(val) != 0);
   }
   FileClose(h);
   g_webConfigTime = TimeCurrent();

   g_trade.EnableLive(EffectiveLive());
   if(g_webRiskPercent > 0.0)
      g_risk.SetRiskPercent(g_webRiskPercent);
   if(g_webMaxSpread > 0.0)
      g_risk.SetMaxSpread(g_webMaxSpread);
   if(g_webMaxTrades > 0)
      g_risk.SetMaxTradesPerDay(g_webMaxTrades);
   if(!g_webEnabled)
      g_trade.CancelAllPending("WEB_DISABLED");

   // Kill switch: flatten and halt on the 0 -> 1 transition only; clear on
   // the explicit 1 -> 0 resume. No repeated close orders every 5 s.
   if(g_killSwitch && !g_killApplied)
   {
      g_trade.CloseAll("WEB_KILL_SWITCH");
      g_risk.Halt();
      g_killApplied = true;
   }
   else if(!g_killSwitch && g_killApplied)
   {
      g_risk.ClearHalt();
      g_killApplied = false;
   }
}

//--- heartbeat/status consumed by the management web app ------------------
void WriteStatus()
{
   int h = FileOpen("SMC_bot_status.csv", FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
   if(h == INVALID_HANDLE)
      return;
   FileWrite(h, "key", "value");
   FileWrite(h, "last_seen", (long)TimeCurrent());
   FileWrite(h, "symbol", g_symbol);
   FileWrite(h, "enabled", g_webEnabled ? 1 : 0);
   FileWrite(h, "live", EffectiveLive() ? 1 : 0);
   FileWrite(h, "risk_percent", DoubleToString(g_risk.RiskPercent(), 2));
   FileWrite(h, "max_spread", DoubleToString(g_risk.MaxSpreadPoints(), 1));
   FileWrite(h, "max_trades", g_risk.MaxTradesPerDay());
   FileWrite(h, "score_min", g_cfg.minScore);
   FileWrite(h, "bias", g_bias.Bias());
   FileWrite(h, "day_type", (int)g_dayType);
   FileWrite(h, "positions", g_trade.CountPositions());
   FileWrite(h, "equity", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   FileWrite(h, "config_time", (long)g_webConfigTime);
   FileWrite(h, "last_signal_time", (long)g_lastSignalTime);
   FileWrite(h, "last_signal_reason", g_lastSignalReason);
   FileWrite(h, "kill_switch", g_killSwitch ? 1 : 0);
   FileWrite(h, "halted", g_risk.Halted() ? 1 : 0);
   FileClose(h);

   // Live equity curve points (one per heartbeat, reset each NY day).
   datetime day = CTimeEngine::StartOfDay(TimeCurrent());
   int mode = (day == g_equityDay) ? (FILE_READ | FILE_WRITE) : FILE_WRITE;
   int eh = FileOpen("SMC_bot_equity.csv", mode | FILE_CSV | FILE_COMMON, ',');
   if(eh != INVALID_HANDLE)
   {
      g_equityDay = day;
      FileSeek(eh, 0, SEEK_END);
      FileWrite(eh, (long)TimeCurrent(),
                DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
      FileClose(eh);
   }
}

void ConfigureSetups()
{
   ZeroMemory(g_cfg);
   g_cfg.point = _Point;
   g_cfg.tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   g_cfg.spreadPoints = g_risk.SpreadPoints();
   g_cfg.equalTolAtr = InpEqualTolATR;
   g_cfg.slBufferPoints = InpSLBufferPoints;
   g_cfg.slBufferSpreadMult = InpSLBufferSpreadMult;
   g_cfg.slExtraPoints = InpSLExtraPoints;
   g_cfg.prefSLMinPips = InpPreferredSLMinPips;
   g_cfg.prefSLMaxPips = InpPreferredSLMaxPips;
   g_cfg.goldMode = IsGold();
   g_cfg.goldSLMinAtr = InpGoldSLMinATR;
   g_cfg.goldSLMaxAtr = InpGoldSLMaxATR;
   g_cfg.maxSLPoints = InpMaxSLPoints;
   g_cfg.slAboveStrongHigh = InpSLAboveStrongHigh;
   g_cfg.tp1R = InpTP1_R;
   g_cfg.tp1Percent = InpTP1Percent / 100.0;
   g_cfg.erlOffsetPoints = InpERLOffsetPoints;
   g_cfg.maxTargetR = InpMaxTargetR;
   g_cfg.sweepMinPoints = InpSweepMinPoints;
   g_cfg.sweepToBosBars = InpSweepToBOSMaxBars;
   g_cfg.pendingExpiryBars = InpPendingExpiryBars;
   g_cfg.entryLevel = InpEntryLevel;
   g_cfg.requireHtfPoi = InpRequireHTFPOI;
   g_cfg.skipFirstPullback = InpSkipFirstPullbackPOI;
   g_cfg.useBodyWhenWick = InpUseBodyWhenWick;
   g_cfg.deepLevel = InpDeepLevel;
   g_cfg.requireDeepDiscount = InpRequireDeepDiscount;
   g_cfg.minLiqPools = InpMinLiquidityPools;
   g_cfg.minScore = (g_webScoreMin > 0) ? g_webScoreMin : InpScoreMin;
   g_cfg.fullScore = InpScoreFull;
   g_cfg.midScore = InpScoreMid;
   g_cfg.provisionalRiskMult = InpAllowProvisionalRange ? 0.25 : 0.0;
}

// Common CanTrade() preconditions (section 7).
bool CanTrade(const datetime ny, const int dir)
{
   if(!g_webEnabled)
      return false;
   if(!EffectiveLive())
      return true;   // paper mode still evaluates & logs signals
   if(InpNoAsiaTrading && g_time.InAsia(ny, InpAsiaStandardPreset))
      return false;
   if(g_time.KillZone(ny, InpEntryGraceMinutes) == "")
      return false;
   if(CTimeEngine::IsFriday(ny) &&
      CTimeEngine::MinutesOfDay(ny) >= InpFridayCutoffHourNY * 60)
      return false;
   if(CTimeEngine::MinutesOfDay(ny) >= InpNoEntryAfterHourNY * 60)
      return false;
   if(g_risk.NewsBlocked(TimeCurrent()))
      return false;
   if(InpOneSetupPerDay && g_mainSetupsToday >= 1)
      return false;
   double planned = g_risk.RiskMoney(1.0);
   int openAll = g_trade.CountPositions();
   int opp = g_trade.CountPositions(-dir);
   return g_risk.CanOpen(planned, openAll, opp, InpEnableHedging);
}

//-----------------------------------------------------------------------------
// Evaluate setups and place an order for one direction.
//-----------------------------------------------------------------------------
void EvaluateAndTrade(const datetime ny, const int dir)
{
   if(SkipDay())
      return;
   if(!g_topDown.AllowDirection(dir))
      return;
   if(!CanTrade(ny, dir))
      return;

   double price = (dir == SMC_BULL) ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                                    : SymbolInfoDouble(g_symbol, SYMBOL_BID);
   TradeSignal sig;
   bool found = g_setups.Evaluate(price, dir, sig);
   if((!found || !sig.valid) && g_msnrReady)
   {
      g_msnrStory.Evaluate(price);
      bool biasOk = (g_msnrStory.Story().dir == dir);
      if(g_msnrSetup.Try(price, sig, true, true, true, biasOk))
         found = true;
   }
   if(!found || !sig.valid)
   {
      if(InpDebugLog)
         g_log.Message("NO_SETUP", "no_valid_signal", "dir=" + IntegerToString(dir));
      return;
   }

   g_lastSignalTime = TimeCurrent();
   g_lastSignalReason = sig.reason;
   g_log.PrintSignal("SIGNAL", sig);
   g_log.Decision("SIGNAL", sig.reason, sig);

   // A3.6 no late London-type entries
   if((sig.setupType == SETUP_C || sig.setupType == SETUP_E) &&
      CTimeEngine::MinutesOfDay(ny) >= InpNoEntryAfterHourNY * 60)
      return;

   double riskMoney = g_risk.RiskMoney(sig.riskMult);
   double slDist = MathAbs(sig.entry - sig.sl);
   double lots = g_risk.LotSize(riskMoney, slDist);
   if(lots <= 0.0)
   {
      g_log.Message("SKIP", "invalid_lot_size", "risk=" + DoubleToString(riskMoney, 2));
      return;
   }

   datetime expiry = 0;
   if(sig.setupType == SETUP_A)
      expiry = TimeCurrent() + InpPendingExpiryBars * PERIOD_M15 * 60;

   ulong ticket = 0;
   bool sent = g_trade.PlacePending(sig, lots, expiry, ticket);
   WriteStatus();
   if(sent && InpLiveTradingEnabled && ticket > 0)
   {
      string vk = "SMC_vol_" + IntegerToString((long)ticket);
      // pending volume is not known until fill; EA will set it OnTradeTransaction
      g_mainSetupsToday++;
      if(GlobalVariableCheck("SMC_kz_" + IntegerToString((long)ticket)))
         GlobalVariableSet("SMC_kz_" + IntegerToString((long)ticket),
                           (double)g_kzStart);
   }
}

//-----------------------------------------------------------------------------
void OnNewEntryBar()
{
   UpdateAllStructures();
   ConfigureSetups();
   if(g_msnrReady)
   {
      for(int i = 0; i < 8; i++)
         if(g_msnrL[i] != NULL)
            g_msnrL[i].Rebuild();
   }

   datetime ny = g_time.ToNY(TimeCurrent());
   datetime nyDay = CTimeEngine::StartOfDay(ny);

   // Asia box completes at NY midnight
   if(nyDay != g_lastDayChecked)
   {
      g_lastDayChecked = nyDay;
      ComputeAsiaBox(nyDay);
      ComputeLondonBox(nyDay);
      g_dayType = ClassifyDay(nyDay);
      g_setups.SetDayType(g_dayType);
      g_mainSetupsToday = 0;
      if(InpDebugLog)
         Print("DAYTYPE ", (int)g_dayType, " skip=", SkipDay());
   }

   // A2 scheduled top-down tasks on new period bars
   double px = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(NewBar(PERIOD_MN1, g_lastMonthChecked))
      g_topDown.OnMonthlyBar(px);
   if(NewBar(PERIOD_W1, g_lastWeekChecked))
      g_topDown.OnWeeklyBar(px);
   if(NewBar(PERIOD_D1, g_lastD1Checked))
      g_topDown.OnDailyBar();
   g_topDown.UpdateExpansion();
   g_bias.SetRangeTF(g_topDown.State().rangeTF);

   g_bias.Compute(px);
   string kz = g_time.KillZone(ny, 0);
   if(kz == "LONDON")
      g_kzStart = ny - CTimeEngine::MinutesOfDay(ny) * 60 + InpLKZStartHour * 3600;
   else if(kz == "NEW_YORK")
      g_kzStart = ny - CTimeEngine::MinutesOfDay(ny) * 60 + InpNYKZStartHour * 3600;

   if(g_dayType == DAY_TRENDING || g_dayType == DAY_UNSET)
      return;
   if(g_dayType == DAY_NEWS && !InpTradeNewsDay)
      return;

   int bias = g_bias.Bias();
   if(bias == SMC_BEAR)
      EvaluateAndTrade(ny, SMC_BEAR);
   else if(bias == SMC_BULL)
      EvaluateAndTrade(ny, SMC_BULL);
   else if(InpTradeNeutralBias)
   {
      EvaluateAndTrade(ny, SMC_BEAR);
      EvaluateAndTrade(ny, SMC_BULL);
   }
}

void CancelAtAsiaStart()
{
   datetime ny = g_time.ToNY(TimeCurrent());
   if(InpNoAsiaTrading && g_time.InAsia(ny, InpAsiaStandardPreset))
      g_trade.CancelAllPending("ASIA_START");
}

//==================== EA EVENTS ==============================================
int OnInit()
{
   g_symbol = _Symbol;
   if(!IsGold() && StringFind(g_symbol, "GBP") < 0 && InpLiveTradingEnabled)
      Print("SMC_Bot: warning: symbol ", g_symbol,
            " is not GBPUSD/XAUUSD; inputs are tuned for those symbols.");

   g_time.Init(InpAutoServerOffset, InpBrokerGMTOffsetWinter,
               InpBrokerGMTOffsetSummer, InpBrokerDSTMode);

   for(int i = 0; i < 8; i++)
   {
      ENUM_TIMEFRAMES tf = PERIOD_M15;
      switch(i)
      {
         case 0: tf = PERIOD_M5;  break;
         case 1: tf = PERIOD_M15; break;
         case 2: tf = PERIOD_M30; break;
         case 3: tf = PERIOD_H1;  break;
         case 4: tf = PERIOD_H4;  break;
         case 5: tf = PERIOD_D1;  break;
         case 6: tf = PERIOD_W1;  break;
         case 7: tf = PERIOD_MN1; break;
      }
      g_structs[i] = new CStructure();
      g_structs[i].Init(g_symbol, tf, InpSwingLen, InpBOSByClose,
                        InpEqualTolATR, InpATRPeriod, InpRangeHistory,
                        InpStrongInvalidateByClose);
      g_structs[i].Update(InpBarsToLoad);
      g_pois[i] = new CPOIEngine();
      g_pois[i].Init(g_structs[i], tf, InpMinWickRatio, InpOBBodyOnly,
                     InpMaxPOIHeightATR, InpEqualTolATR, InpOBLookback);
            g_pois[i].Rebuild();
      g_levels[i] = new CCloseLevelEngine();
      g_levels[i].Init(g_structs[i], tf, InpLevelBandPoints,
                       InpBreakByBodyClose, InpLevelUseOrderBlockMap,
                       CCloseLevelEngine::TimeframeRank(InpMinLevelTF),
                       InpHTFConflictTolerancePoints * _Point,
                       InpMaxRefinePips * PipSize());
      g_levels[i].Rebuild();
   }
   // A1.8 gold refinement may be ATR based; use the larger of the two.
   double refineDist = MathMax(InpMaxRefinePips * PipSize(),
                               InpMaxRefineATR * g_structs[1].AtrLast());
   for(int i = 0; i < 8; i++)
      if(g_levels[i] != NULL)
         g_levels[i].Init(g_structs[i], (i == 0) ? PERIOD_M5 :
                          (i == 1) ? PERIOD_M15 : (i == 2) ? PERIOD_M30 :
                          (i == 3) ? PERIOD_H1  : (i == 4) ? PERIOD_H4 :
                          (i == 5) ? PERIOD_D1  : (i == 6) ? PERIOD_W1 : PERIOD_MN1,
                          InpLevelBandPoints, InpBreakByBodyClose,
                          InpLevelUseOrderBlockMap,
                          CCloseLevelEngine::TimeframeRank(InpMinLevelTF),
                          InpHTFConflictTolerancePoints * _Point,
                          refineDist);

   g_topDown.Init(g_structs[7], g_structs[6], g_structs[5], g_structs[4],
                  g_levels[7], g_levels[6], g_levels[5], g_levels[4],
                  InpRequireWeeklyAgree, InpCounterBreakTFs);

   g_bias.Init(
g_structs[7], g_structs[5], g_structs[4], g_structs[3],
               g_pois[7], g_pois[5], g_pois[4], g_pois[3],
               true, InpRequireWeeklyAgree,
               InpHTFConflictTolerancePoints * _Point);
   g_bias.RefreshWeekly();

   ConfigureSetups();
   g_setups.Init(&g_time, g_structs[TfIndex(InpRangeTF)],
                 g_structs[TfIndex(InpEntryTF)], g_structs[TfIndex(InpRefineTF)],
                 g_structs[TfIndex(InpBiasTF2)],
                 g_pois[TfIndex(InpRangeTF)], g_pois[TfIndex(InpEntryTF)],
                 g_pois[TfIndex(InpRefineTF)], g_pois[TfIndex(InpBiasTF2)],
                                   &g_bias, g_cfg);
   g_setups.InitAddendum(g_levels[4], g_levels[3]);

   g_risk.Init(
g_symbol, InpMagic, InpRiskMode, InpRiskPercent, InpRiskMoney,
               InpMaxDailyLossPct, InpMaxWeeklyLossPct, InpMaxOpenRiskPct,
               InpEquityStopPct, (int)InpMaxTradesPerDay, InpMaxConsecLosses,
               InpMaxOpenTrades, InpMaxCorrelatedTrades, InpMaxSpreadPoints,
               InpNewsBufferMin);
   g_risk.LoadNews(InpNewsFilePath);
   g_risk.LoadState();
   g_risk.NewBarCheck();

   if(!g_log.Init(InpLogFile, g_symbol))
      Print("SMC_Bot: logging disabled (file open failed)");
   g_trade.Init(g_symbol, InpMagic, InpLiveTradingEnabled, &g_log);
   g_trade.SetTp1Percent(InpTP1Percent / 100.0);

   if(InpEnableMSNR)
   {
      for(int i = 0; i < 8; i++)
         g_msnrL[i] = NULL;
      int mtf[5] = {4, 3, 5, 6, 7};
      ENUM_TIMEFRAMES tfs[5] = {PERIOD_H4, PERIOD_H1, PERIOD_D1,
                                PERIOD_W1, PERIOD_MN1};
      for(int k = 0; k < 5; k++)
      {
         int i = mtf[k];
         g_msnrL[i] = new CMSNRLevels();
         g_msnrL[i].Init(g_structs[i], tfs[k], InpMinGapPoints,
                         InpQMSLBufferPoints, InpRequireTurtleSoup,
                         InpProtectedRetracePct, InpAllowFreshOnHTF);
         g_msnrL[i].Rebuild();
      }
      g_msnrStory.Init(g_structs[7], g_structs[6], g_structs[5], g_structs[4],
                       g_msnrL[7], g_msnrL[6], g_msnrL[5],
                       InpEqualTolATR, _Point);
      g_msnrSetup.Init(g_msnrL[4], g_msnrL[3], &g_msnrStory, &g_bias,
                       InpMSNRSLBufferPoints, _Point, InpMSNRMinScore,
                       InpMSNR_TP1_Percent, InpMSNR_TP2_Percent,
                       InpMSNR_TP3_Percent, InpLastLiquidityRequired);
      g_msnrReady = true;
      Print("SMC_Bot: MSNR module enabled (Setup M)");
   }

   ReadWebConfig();
   WriteStatus();
   EventSetTimer(5);   // 5 s heartbeat: status file + runtime config read
   g_ready = true;
   Print("SMC_Bot initialised: ", g_symbol,
         " live=", InpLiveTradingEnabled, " poiModel=", InpPOIModel,
         " slMode=", InpSLMode, " gold=", IsGold());
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   g_log.Shutdown();
   for(int i = 0; i < 8; i++)
   {
      if(g_structs[i] != NULL) delete g_structs[i];
      if(g_pois[i] != NULL)    delete g_pois[i];
      if(g_levels[i] != NULL)  delete g_levels[i];
      g_structs[i] = NULL;
      g_pois[i] = NULL;
      g_levels[i] = NULL;
      if(g_msnrL[i] != NULL)
      {
         delete g_msnrL[i];
         g_msnrL[i] = NULL;
      }
   }
}

void OnTick()
{
   if(!g_ready)
      return;
   g_time.RefreshAuto();
   g_risk.NewBarCheck();

   if(NewBar(InpEntryTF, g_lastEntryBar))
      OnNewEntryBar();

   // tick-level: Asia pending cancellation and position management
   CancelAtAsiaStart();
   datetime ny = g_time.ToNY(TimeCurrent());
   CStructure* es = g_structs[TfIndex(InpEntryTF)];
   double sh = 0.0, sl = 0.0;
   if(es != NULL)
   {
      SMC_Swing x;
      if(es.GetStrongHigh(x) && !x.invalidated) sh = x.price;
      if(es.GetStrongLow(x) && !x.invalidated) sl = x.price;
   }
   g_trade.Manage(ny, g_time, InpBEBufferPoints, InpTrailBySwing,
                  InpCloseHourNY, InpFridayCloseHourNY,
                  sh, sl, InpInvalidateByClose, InpInvalidateExtraPoints,
                  true);
}

void OnTimer()
{
   if(!g_ready)
      return;
   g_time.RefreshAuto();
   g_risk.NewBarCheck();
   ReadWebConfig();
   WriteStatus();
   if(g_bias.WeeklyDir() == SMC_NEUTRAL)
      g_bias.RefreshWeekly();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!g_ready)
      return;
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      g_risk.OnDeal(trans.deal);
}

double OnTester()
{
   // Expose expectancy-like metric for parameter sweeps.
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   return (pf > 0.0) ? pf : 0.0;
}
