//+------------------------------------------------------------------+
//|  SMC_Risk.mqh                                                    |
//|  Position sizing, daily/weekly/equity guards, news filter,        |
//|  spread filter and state persistence (sections 8 and 10).         |
//+------------------------------------------------------------------+
#ifndef SMC_RISK_MQH
#define SMC_RISK_MQH

#include "SMC_Types.mqh"
#include "SMC_Time.mqh"

struct SMC_NewsEvent
{
   datetime time;
   string   currency;
   int      impact;        // 3 = high/red, 2 = medium, 1 = low
};

class CRisk
{
private:
   //--- configuration
   int      m_riskMode;           // 0 = percent, 1 = fixed money
   double   m_riskPercent;
   double   m_riskMoney;
   double   m_dailyLossPct;
   double   m_weeklyLossPct;
   double   m_maxOpenRiskPct;
   double   m_equityStopPct;
   int      m_maxTradesPerDay;
   int      m_maxConsecLosses;
   int      m_maxOpenTrades;
   int      m_maxCorrelated;
   double   m_maxSpreadPoints;
   int      m_newsBufferMin;
   string   m_symbol;
   string   m_currency;
   ulong    m_magic;

   //--- runtime state
   int      m_tradesToday;
   int      m_consecLosses;
   double   m_dayStartEquity;
   double   m_weekStartEquity;
   double   m_startBalance;
   datetime m_dayStamp;
   datetime m_weekStamp;
   bool     m_halted;

   SMC_NewsEvent m_news[];
   int           m_newsCount;

   string StateKey(const string suffix)
   {
      return "SMC_" + m_symbol + "_" + IntegerToString((int)m_magic) +
             "_" + suffix;
   }

   static string Trim(string s)
   {
      StringTrimRight(s);
      StringTrimLeft(s);
      return s;
   }

public:
   void Init(const string symbol, const ulong magic,
             const int riskMode, const double riskPercent,
             const double riskMoney, const double dailyLossPct,
             const double weeklyLossPct, const double maxOpenRiskPct,
             const double equityStopPct, const int maxTradesPerDay,
             const int maxConsecLosses, const int maxOpenTrades,
             const int maxCorrelated, const double maxSpreadPoints,
             const int newsBufferMin)
   {
      m_symbol = symbol;
      m_magic = magic;
      m_riskMode = riskMode;
      m_riskPercent = riskPercent;
      m_riskMoney = riskMoney;
      m_dailyLossPct = dailyLossPct;
      m_weeklyLossPct = weeklyLossPct;
      m_maxOpenRiskPct = maxOpenRiskPct;
      m_equityStopPct = equityStopPct;
      m_maxTradesPerDay = maxTradesPerDay;
      m_maxConsecLosses = maxConsecLosses;
      m_maxOpenTrades = maxOpenTrades;
      m_maxCorrelated = maxCorrelated;
      m_maxSpreadPoints = maxSpreadPoints;
      m_newsBufferMin = newsBufferMin;
      m_newsCount = 0;
      ArrayResize(m_news, 0);

      m_currency = "USD";
      string cur = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
      if(cur != "")
         m_currency = cur;

      m_startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      m_weekStartEquity = m_dayStartEquity;
      m_dayStamp = 0;
      m_weekStamp = 0;
      m_halted = false;
      m_tradesToday = 0;
      m_consecLosses = 0;
   }

   //--- news calendar ------------------------------------------------
   bool LoadNews(const string path)
   {
      if(path == "")
         return true;
      int h = FileOpen(path, FILE_READ | FILE_CSV | FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
      {
         Print("SMC_Risk: news file not found: ", path);
         return false;
      }
      m_newsCount = 0;
      ArrayResize(m_news, 0);
      while(!FileIsEnding(h))
      {
         string line = FileReadString(h);
         if(line == "")
            continue;
         string parts[];
         int n = StringSplit(line, ',', parts);
         if(n < 3)
            continue;
         SMC_NewsEvent e;
         e.time = 0;
         string ds = Trim(parts[0]);
         if(StringFind(ds, "-") >= 0)
            e.time = StringToTime(ds);
         else
            e.time = (datetime)StringToInteger(ds);
         e.currency = Trim(parts[1]);
         e.impact = (int)StringToInteger(Trim(parts[2]));
         if(e.time == 0 || e.impact <= 0)
            continue;
         ArrayResize(m_news, m_newsCount + 1);
         m_news[m_newsCount] = e;
         m_newsCount++;
      }
      FileClose(h);
      Print("SMC_Risk: loaded ", m_newsCount, " news events");
      return true;
   }

   bool NewsBlocked(const datetime nowServer, const string symbolCurrency = "")
   {
      string cur = (symbolCurrency != "") ? symbolCurrency : m_currency;
      int buf = m_newsBufferMin * 60;
      for(int i = 0; i < m_newsCount; i++)
      {
         if(m_news[i].impact < 3)
            continue;
         if(cur != "" && m_news[i].currency != cur &&
            m_news[i].currency != "USD" && cur != "USD")
            continue;
         if(MathAbs((double)(m_news[i].time - nowServer)) <= (double)buf)
            return true;
      }
      return false;
   }

   // A3.1 NEWS_DAY: a red event during the NY window (07:00-12:00 NY).
   bool HasNewsDayWindow(const datetime nyDayStart, const int fromHour,
                         const int toHour, CTimeEngine* timeEng)
   {
      if(timeEng == NULL)
         return false;
      for(int i = 0; i < m_newsCount; i++)
      {
         if(m_news[i].impact < 3)
            continue;
         datetime ny = timeEng.ToNY(m_news[i].time);
         datetime ds = CTimeEngine::StartOfDay(ny);
         if(ds != CTimeEngine::StartOfDay(nyDayStart))
            continue;
         int m = CTimeEngine::MinutesOfDay(ny);
         if(m >= fromHour * 60 && m < toHour * 60)
            return true;
      }
      return false;
   }

   //--- spread filter ------------------------------------------------
   bool SpreadOk()
   {
      long sp = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      return (sp >= 0 && (double)sp <= m_maxSpreadPoints);
   }

   double SpreadPoints()
   {
      long sp = SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      return (sp > 0) ? (double)sp : 0.0;
   }

   //--- daily / weekly rollover --------------------------------------
   void NewBarCheck()
   {
      datetime now = TimeCurrent();
      MqlDateTime st;
      TimeToStruct(now, st);
      datetime day = CTimeEngine::StartOfDay(now);
      if(day != m_dayStamp)
      {
         m_dayStamp = day;
         m_tradesToday = 0;
         m_consecLosses = 0;
         m_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      }
      int week = st.year * 100 + st.day_of_year / 7;
      if(week != m_weekStamp)
      {
         m_weekStamp = week;
         m_weekStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      }
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(m_equityStopPct > 0.0 && m_startBalance > 0.0 &&
         eq < m_startBalance * (1.0 - m_equityStopPct / 100.0))
         m_halted = true;
   }

   //--- gates --------------------------------------------------------
   bool CanOpen(const double plannedRiskMoney, const int openPositions,
                const int oppPositions, const bool hedging)
   {
      if(m_halted)
         return false;
      if(!SpreadOk())
         return false;
      if(m_tradesToday >= m_maxTradesPerDay)
         return false;
      if(m_consecLosses >= m_maxConsecLosses)
         return false;
      if(openPositions >= m_maxOpenTrades)
         return false;
      if(!hedging && oppPositions > 0)
         return false;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      double lossPct = (m_dayStartEquity > 0.0)
                     ? (m_dayStartEquity - eq) / m_dayStartEquity * 100.0 : 0.0;
      if(lossPct >= m_dailyLossPct)
         return false;
      double wLoss = (m_weekStartEquity > 0.0)
                   ? (m_weekStartEquity - eq) / m_weekStartEquity * 100.0 : 0.0;
      if(wLoss >= m_weeklyLossPct)
         return false;
      double openRisk = CurrentOpenRisk();
      if(m_maxOpenRiskPct > 0.0 && eq > 0.0 &&
         (openRisk + plannedRiskMoney) / eq * 100.0 > m_maxOpenRiskPct)
         return false;
      return true;
   }

   double CurrentOpenRisk()
   {
      double risk = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != (long)m_magic)
            continue;
         double sl = PositionGetDouble(POSITION_SL);
         double op = PositionGetDouble(POSITION_PRICE_OPEN);
         double vol = PositionGetDouble(POSITION_VOLUME);
         if(sl <= 0.0 || op <= 0.0)
            continue;
         double dist = MathAbs(op - sl);
         double tv = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
         double ts = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
         if(ts <= 0.0 || tv <= 0.0)
            continue;
         risk += vol * (dist / ts) * tv;
      }
      return risk;
   }

   //--- sizing -------------------------------------------------------
   double RiskMoney(const double scoreMult)
   {
      double base = (m_riskMode == 1)
                  ? m_riskMoney
                  : AccountInfoDouble(ACCOUNT_EQUITY) * m_riskPercent / 100.0;
      return base * scoreMult;
   }

   double LotSize(const double riskMoney, const double slDistance)
   {
      double ts = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      double tv = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      double minL = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double maxL = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      if(ts <= 0.0 || tv <= 0.0 || slDistance <= 0.0 || step <= 0.0)
         return 0.0;
      double lots = riskMoney / ((slDistance / ts) * tv);
      lots = MathFloor(lots / step) * step;
      if(lots < minL)
         return 0.0;
      if(lots > maxL)
         lots = MathFloor(maxL / step) * step;
      return NormalizeDouble(lots, 2);
   }

   //--- state --------------------------------------------------------
   void OnDeal(const ulong dealTicket)
   {
      if(!HistoryDealSelect(dealTicket))
         return;
      if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (long)m_magic)
         return;
      long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
      {
         m_tradesToday++;
         SaveState();
      }
      else if(entry == DEAL_ENTRY_OUT)
      {
         double pnl = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                      HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                      HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         if(pnl < 0.0)
            m_consecLosses++;
         else
            m_consecLosses = 0;
         SaveState();
      }
   }

   void SaveState()
   {
      GlobalVariableSet(StateKey("trades"), (double)m_tradesToday);
      GlobalVariableSet(StateKey("losses"), (double)m_consecLosses);
      GlobalVariableSet(StateKey("daystamp"), (double)m_dayStamp);
      GlobalVariableSet(StateKey("halted"), m_halted ? 1.0 : 0.0);
   }

   void LoadState()
   {
      if(GlobalVariableCheck(StateKey("trades")))
         m_tradesToday = (int)GlobalVariableGet(StateKey("trades"));
      if(GlobalVariableCheck(StateKey("losses")))
         m_consecLosses = (int)GlobalVariableGet(StateKey("losses"));
      if(GlobalVariableCheck(StateKey("daystamp")))
         m_dayStamp = (datetime)GlobalVariableGet(StateKey("daystamp"));
      if(GlobalVariableCheck(StateKey("halted")))
         m_halted = (GlobalVariableGet(StateKey("halted")) > 0.5);
   }

   //--- runtime overrides set by the management web app (file based)
   void SetRiskPercent(const double p)
   {
      if(p > 0.0 && p <= 100.0)
         m_riskPercent = p;
   }
   void SetMaxSpread(const double pts)
   {
      if(pts > 0.0)
         m_maxSpreadPoints = pts;
   }
   void SetMaxTradesPerDay(const int n)
   {
      if(n > 0)
         m_maxTradesPerDay = n;
   }
   void SetDailyLossPct(const double p)
   {
      if(p > 0.0)
         m_dailyLossPct = p;
   }
   double RiskPercent() const { return m_riskPercent; }
   double MaxSpreadPoints() const { return m_maxSpreadPoints; }
   int MaxTradesPerDay() const { return m_maxTradesPerDay; }

   void Halt() { m_halted = true; SaveState(); }
   bool Halted() const { return m_halted; }
   int TradesToday() const { return m_tradesToday; }
   int ConsecLosses() const { return m_consecLosses; }
   void ClearHalt()
   {
      m_halted = false;
      m_startBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      SaveState();
   }
};

#endif // SMC_RISK_MQH
