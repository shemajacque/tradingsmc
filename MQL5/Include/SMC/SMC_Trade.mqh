//+------------------------------------------------------------------+
//|  SMC_Trade.mqh                                                   |
//|  Order sending, pending management, partials, break-even,          |
//|  trailing, invalidation and time stops (sections 8 and 10).        |
//|                                                                  |
//|  All retcodes are handled with up to 3 retries. Stops respect      |
//|  SYMBOL_TRADE_STOPS_LEVEL / SYMBOL_TRADE_FREEZE_LEVEL.             |
//+------------------------------------------------------------------+
#ifndef SMC_TRADE_MQH
#define SMC_TRADE_MQH

#include "SMC_Types.mqh"
#include "SMC_Time.mqh"
#include "SMC_Setups.mqh"
#include "SMC_Logger.mqh"
#include <Trade/Trade.mqh>

class CTradeEngine
{
private:
   CTrade        m_trade;
   string        m_symbol;
   ulong         m_magic;
   bool          m_live;
   CDecisionLogger* m_log;
   int           m_maxRetries;

   double StopLevelPoints()
   {
      return (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   }

   double FreezeLevelPoints()
   {
      return (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   }

   bool TerminalReady()
   {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
         return false;
      if(SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
         return false;
      return true;
   }

   bool Retryable(const uint retcode)
   {
      return (retcode == TRADE_RETCODE_REQUOTE ||
              retcode == TRADE_RETCODE_PRICE_CHANGED ||
              retcode == TRADE_RETCODE_PRICE_OFF ||
              retcode == TRADE_RETCODE_TIMEOUT ||
              retcode == TRADE_RETCODE_CONNECTION ||
              retcode == TRADE_RETCODE_SERVER_DISABLES_AT ||
              retcode == TRADE_RETCODE_TOO_MANY_REQUESTS);
   }

   void LogRet(const string op, const uint rc)
   {
      Print("SMC_Trade ", op, " failed retcode=", rc,
            " (", m_trade.ResultRetcodeDescription(), ")");
   }

   // Normalize stops to broker levels. Returns false if too close.
   bool NormalizeStops(const int type, double &price, double &sl, double &tp)
   {
      double pt = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double slvl = StopLevelPoints() * pt;
      double fz = FreezeLevelPoints() * pt;
      if(slvl < 0.0)
         slvl = 0.0;
      double tick = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tick <= 0.0)
         tick = pt;
      if(sl > 0.0)
      {
         if(type == ORDER_TYPE_SELL || type == ORDER_TYPE_SELL_LIMIT ||
            type == ORDER_TYPE_SELL_STOP)
         {
            if(sl - price < slvl)
               sl = price + slvl + tick;
         }
         else
         {
            if(price - sl < slvl)
               sl = price - slvl - tick;
         }
      }
      if(tp > 0.0)
      {
         if(type == ORDER_TYPE_SELL || type == ORDER_TYPE_SELL_LIMIT ||
            type == ORDER_TYPE_SELL_STOP)
         {
            if(price - tp < slvl)
               tp = price - slvl - tick;
         }
         else
         {
            if(tp - price < slvl)
               tp = price + slvl + tick;
         }
      }
      return (fz <= 0.0 || MathAbs(price - sl) > fz || sl == 0.0);
   }

public:
   void Init(const string symbol, const ulong magic, const bool live,
             CDecisionLogger* logger)
   {
      m_symbol = symbol;
      m_magic = magic;
      m_live = live;
      m_log = logger;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(30);
      m_trade.SetTypeFillingBySymbol(symbol);
      m_maxRetries = 3;
      m_tp1Pct = 0.4;
   }

   void EnableLive(const bool v) { m_live = v; }
   bool LiveEnabled() const { return m_live; }

   //--- pending order placement --------------------------------------
   bool PlacePending(const TradeSignal &sig, const double lots,
                     const datetime expiry, ulong &ticketOut)
   {
      ticketOut = 0;
      if(!sig.valid || lots <= 0.0)
         return false;
      if(!TerminalReady())
         return false;
      if(m_log != NULL)
         m_log.PrintSignal("SIGNAL", sig);
      if(!m_live)
      {
         if(m_log != NULL)
            m_log.Decision("PAPER", sig.reason, sig, "paper mode, no order");
         return false;
      }

      bool isSell = (sig.dir == SMC_BEAR);
      ENUM_ORDER_TYPE type = isSell ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT;
      double price = sig.entry;
      double sl = sig.sl;
      double tp = sig.tp1;
      if(!NormalizeStops(type, price, sl, tp))
         return false;

      for(int attempt = 0; attempt < m_maxRetries; attempt++)
      {
         bool ok = m_trade.OrderOpen(m_symbol, type, lots, 0.0,
                                     price, sl, tp, ORDER_TIME_GTC, expiry,
                                     sig.reason);
         uint rc = m_trade.ResultRetcode();
         if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
         {
            ticketOut = m_trade.ResultOrder();
            if(m_log != NULL)
               m_log.Decision("ORDER", sig.reason, sig,
                               "ticket=" + IntegerToString((long)ticketOut));
            return true;
         }
         LogRet("OrderOpen", rc);
         if(!Retryable(rc))
            break;
         Sleep(200 * (attempt + 1));
      }
      return false;
   }

   //--- market order (for confirmation entries) -----------------------
   bool PlaceMarket(const TradeSignal &sig, const double lots, ulong &ticketOut)
   {
      ticketOut = 0;
      if(!sig.valid || lots <= 0.0 || !TerminalReady())
         return false;
      if(!m_live)
      {
         if(m_log != NULL)
         {
            m_log.PrintSignal("SIGNAL", sig);
            m_log.Decision("PAPER", sig.reason, sig, "paper mode");
         }
         return false;
      }
      ENUM_ORDER_TYPE type = (sig.dir == SMC_BULL) ? ORDER_TYPE_BUY
                                                   : ORDER_TYPE_SELL;
      double price = (sig.dir == SMC_BULL)
                   ? SymbolInfoDouble(m_symbol, SYMBOL_ASK)
                   : SymbolInfoDouble(m_symbol, SYMBOL_BID);
      double sl = sig.sl;
      double tp = sig.tpRunner;
      if(!NormalizeStops(type, price, sl, tp))
         return false;
      for(int attempt = 0; attempt < m_maxRetries; attempt++)
      {
          bool ok = (type == ORDER_TYPE_BUY)
                    ? m_trade.Buy(lots, m_symbol, 0.0, sl, tp, sig.reason)
                    : m_trade.Sell(lots, m_symbol, 0.0, sl, tp, sig.reason);
         uint rc = m_trade.ResultRetcode();
         if(ok && rc == TRADE_RETCODE_DONE)
         {
            ticketOut = m_trade.ResultDeal();
            if(m_log != NULL)
               m_log.Decision("MARKET", sig.reason, sig,
                               "deal=" + IntegerToString((long)ticketOut));
            return true;
         }
         LogRet("OrderSend", rc);
         if(!Retryable(rc))
            break;
         Sleep(200 * (attempt + 1));
      }
      return false;
   }

   //--- pending cancellation -----------------------------------------
   int CancelAllPending(const string reasonCode)
   {
      int n = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong t = OrderGetTicket(i);
         if(t == 0 || !OrderSelect(t))
            continue;
         if((long)OrderGetInteger(ORDER_MAGIC) != (long)m_magic)
            continue;
         long type = OrderGetInteger(ORDER_TYPE);
         if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT &&
            type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
            continue;
         if(m_live)
         {
            for(int a = 0; a < m_maxRetries; a++)
            {
               if(m_trade.OrderDelete(t))
                  break;
               if(!Retryable(m_trade.ResultRetcode()))
                  break;
               Sleep(150);
            }
         }
         if(m_log != NULL)
            m_log.Message("CANCEL", reasonCode,
                           "order=" + IntegerToString((long)t));
         n++;
      }
      return n;
   }

   //--- partial close -------------------------------------------------
   bool PartialClose(const ulong ticket, const double percent,
                     const string reasonCode)
   {
      if(!PositionSelectByTicket(ticket))
         return false;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double step = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      double minL = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double closeVol = MathFloor((vol * percent) / step) * step;
      if(closeVol < minL)
         closeVol = minL;
      if(closeVol >= vol)
         closeVol = vol;
      if(!m_live)
      {
         if(m_log != NULL)
            m_log.Message("PARTIAL_PAPER", reasonCode,
                           "ticket=" + IntegerToString((long)ticket));
         return true;
      }
      for(int a = 0; a < m_maxRetries; a++)
      {
         if(m_trade.PositionClosePartial(ticket, closeVol))
            return true;
         if(!Retryable(m_trade.ResultRetcode()))
            break;
         Sleep(150);
      }
      return false;
   }

   // Kill switch: cancel every pending order and close every own position.
   void CloseAll(const string reasonCode)
   {
      CancelAllPending(reasonCode + "_PENDING");
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !PositionSelectByTicket(t))
            continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != (long)m_magic)
            continue;
         ClosePosition(t, reasonCode);
      }
   }

   bool ClosePosition(const ulong ticket, const string reasonCode)
   {
      if(!PositionSelectByTicket(ticket))
         return false;
      if(!m_live)
      {
         if(m_log != NULL)
            m_log.Message("CLOSE_PAPER", reasonCode,
                           "ticket=" + IntegerToString((long)ticket));
         return true;
      }
      for(int a = 0; a < m_maxRetries; a++)
      {
         if(m_trade.PositionClose(ticket))
            return true;
         if(!Retryable(m_trade.ResultRetcode()))
            break;
         Sleep(150);
      }
      return false;
   }

   bool ModifySlTp(const ulong ticket, const double sl, const double tp,
                   const string reasonCode)
   {
      if(!PositionSelectByTicket(ticket))
         return false;
      double curSl = PositionGetDouble(POSITION_SL);
      double curTp = PositionGetDouble(POSITION_TP);
      if(MathAbs(curSl - sl) < SymbolInfoDouble(m_symbol, SYMBOL_POINT) &&
         MathAbs(curTp - tp) < SymbolInfoDouble(m_symbol, SYMBOL_POINT))
         return true;
      if(!m_live)
         return true;
      for(int a = 0; a < m_maxRetries; a++)
      {
         if(m_trade.PositionModify(ticket, sl, tp))
         {
            if(m_log != NULL)
               m_log.Message("MODIFY", reasonCode,
                              "ticket=" + IntegerToString((long)ticket));
            return true;
         }
         if(!Retryable(m_trade.ResultRetcode()))
            break;
         Sleep(150);
      }
      return false;
   }

   //--- position helpers ---------------------------------------------
   int CountPositions(int dir = 0)
   {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !PositionSelectByTicket(t))
            continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != (long)m_magic)
            continue;
         if(dir == 0)
            n++;
         else
         {
            long ty = PositionGetInteger(POSITION_TYPE);
            if(dir == SMC_BULL && ty == POSITION_TYPE_BUY)
               n++;
            if(dir == SMC_BEAR && ty == POSITION_TYPE_SELL)
               n++;
         }
      }
      return n;
   }

   //--- management ----------------------------------------------------
   // Called on every new bar / timer. Handles TP1, BE, invalidation,
   // time stop, trailing by LTF swing and Friday hard close.
   void Manage(const datetime ny, CTimeEngine &timeEng,
               const double beBufferPoints, const bool trailBySwing,
               const int closeHourNY, const int fridayCloseHourNY,
               const double strongHigh, const double strongLow,
               const bool invalidateByClose, const double invalidateExtraPoints,
               const bool noTimerStopIfProfit)
   {
      double pt = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket))
            continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != (long)m_magic)
            continue;

         long ty = PositionGetInteger(POSITION_TYPE);
         bool isBuy = (ty == POSITION_TYPE_BUY);
         double op = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         double vol = PositionGetDouble(POSITION_VOLUME);
         double bid = SymbolInfoDouble(m_symbol, SYMBOL_BID);
         double ask = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
         double price = isBuy ? bid : ask;
         double initVol = PositionGetDouble(POSITION_VOLUME);

         // Friday hard close
         if(timeEng.AfterFridayCutoff(ny, fridayCloseHourNY))
         {
            ClosePosition(ticket, "TIME_FRIDAY_CLOSE");
            continue;
         }

         // TP1 partial: detected by the position having less than initial
         // volume OR price reaching the TP level that was set at entry.
         // The EA stores initial volume in a global variable keyed by ticket.
         string vk = "SMC_vol_" + IntegerToString((long)ticket);
         double initial = GlobalVariableCheck(vk) ? GlobalVariableGet(vk) : initVol;
         bool tp1Done = (initial > 0.0 && vol < initial - 0.5 *
                        SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP));
         if(!tp1Done && tp > 0.0)
         {
            bool hit = isBuy ? (bid >= tp) : (ask <= tp);
            if(hit)
            {
               PartialClose(ticket, m_tp1Pct, "TP1");
               tp1Done = true;
               double be = op + (isBuy ? 1.0 : -1.0) * beBufferPoints * pt;
               ModifySlTp(ticket, be, 0.0, "BE_AFTER_TP1");
            }
         }

         // Early BE (0.7R) is handled by the EA passing a pre-set flag via
         // the global variable "SMC_earlybe_<ticket>".
         string ek = "SMC_earlybe_" + IntegerToString((long)ticket);
         if(GlobalVariableCheck(ek) && GlobalVariableGet(ek) > 0.5 && !tp1Done)
         {
            double risk = MathAbs(op - PositionGetDouble(POSITION_SL));
            double move = isBuy ? (bid - op) : (op - ask);
            if(risk > 0.0 && move >= 0.7 * risk)
            {
               double be = op + (isBuy ? 1.0 : -1.0) * beBufferPoints * pt;
               ModifySlTp(ticket, be, tp, "EARLY_BE");
               GlobalVariableSet(ek, 0.0);
            }
         }

         // Invalidation: close beyond strong point on entry TF
         if(invalidateByClose && strongHigh > 0.0 && !isBuy &&
            bid > strongHigh + invalidateExtraPoints * pt)
            ClosePosition(ticket, "INVALIDATE_STRONG_HIGH");
         if(invalidateByClose && strongLow > 0.0 && isBuy &&
            ask < strongLow - invalidateExtraPoints * pt)
            ClosePosition(ticket, "INVALIDATE_STRONG_LOW");

         // Time stop
         int m = CTimeEngine::MinutesOfDay(ny);
         if(m >= closeHourNY * 60)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(!(noTimerStopIfProfit && profit > 0.0))
               ClosePosition(ticket, "TIME_STOP");
         }

         // Trailing by LTF swing: use global vars set by the EA at each new
         // confirmed swing on the entry TF.
         if(trailBySwing && tp1Done)
         {
            string sk = isBuy ? "SMC_trailLow_" : "SMC_trailHigh_";
            sk += IntegerToString((long)m_magic);
            if(GlobalVariableCheck(sk))
            {
               double sw = GlobalVariableGet(sk);
               double newSl = isBuy ? sw - beBufferPoints * pt
                                    : sw + beBufferPoints * pt;
               bool better = isBuy ? (newSl > sl) : (sl == 0.0 || newSl < sl);
               if(better)
                  ModifySlTp(ticket, newSl, tp, "TRAIL_SWING");
            }
         }
      }
   }

   void SetTp1Percent(double pct) { m_tp1Pct = pct; }

private:
   double m_tp1Pct;
};

#endif // SMC_TRADE_MQH
