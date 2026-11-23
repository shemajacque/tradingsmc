//+------------------------------------------------------------------+
//|  SMC_Logger.mqh                                                  |
//|  Decision + trade logging to CSV and Print() (section 10).        |
//|  Every line carries a reason code so backtest logs can be matched |
//|  to forward-test behaviour.                                       |
//+------------------------------------------------------------------+
#ifndef SMC_LOGGER_MQH
#define SMC_LOGGER_MQH

#include "SMC_Types.mqh"

class CDecisionLogger
{
private:
   int      m_handle;
   string   m_symbol;
   string   m_fileName;
   bool     m_open;

public:
   CDecisionLogger() : m_handle(INVALID_HANDLE), m_symbol(""), m_open(false) {}

   bool Init(const string fileName, const string symbol)
   {
      m_symbol = symbol;
      m_fileName = fileName;
      m_open = true;
      // Truncate once, then append-and-close on every write so external
      // readers (the management web app) never see an exclusively locked file.
      int h = FileOpen(m_fileName, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
      {
         Print("SMC_Logger: cannot open ", m_fileName, " err=", GetLastError());
         m_open = false;
         return false;
      }
      FileWrite(h, "time_local,time_ny,symbol,event,reason,setup,dir,entry,sl,tp1,tprunner,score,riskmult,detail");
      FileClose(h);
      return true;
   }

   void Shutdown()
   {
      m_open = false;
   }

   void WriteRaw(const string line)
   {
      if(!m_open)
         return;
      int h = FileOpen(m_fileName, FILE_WRITE | FILE_CSV | FILE_COMMON, ',');
      if(h == INVALID_HANDLE)
         return;
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, line);
      FileClose(h);
   }

   void Decision(const string event, const string reason,
                 const TradeSignal &s, const string detail = "")
   {
      string sv = "";
      switch(s.setupType)
      {
         case SETUP_A: sv = "A"; break;
         case SETUP_B: sv = "B"; break;
         case SETUP_C: sv = "C"; break;
         case SETUP_D: sv = "D"; break;
         case SETUP_E: sv = "E"; break;
         case SETUP_F: sv = "F"; break;
         case SETUP_M: sv = "M"; break;
         default:      sv = "-"; break;
      }
      string dir = (s.dir == SMC_BULL) ? "BUY"
                 : (s.dir == SMC_BEAR) ? "SELL" : "NONE";
      string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "," +
         TimeToString(s.signalTime, TIME_DATE | TIME_SECONDS) + "," + m_symbol + "," +
         event + "," + reason + "," + sv + "," + dir + "," +
         DoubleToString(s.entry, 5) + "," + DoubleToString(s.sl, 5) + "," +
         DoubleToString(s.tp1, 5) + "," + DoubleToString(s.tpRunner, 5) + "," +
         IntegerToString(s.score) + "," + DoubleToString(s.riskMult, 2) + "," +
         detail;
      WriteRaw(line);
   }

   void Message(const string event, const string reason,
                const string detail = "")
   {
      TradeSignal empty;
      ResetSignal(empty);
      Decision(event, reason, empty, detail);
   }

   void PrintSignal(const string tag, const TradeSignal &s)
   {
      Print(tag, " ", m_symbol, " ",
            (s.dir == SMC_BULL ? "BUY" : (s.dir == SMC_BEAR ? "SELL" : "NONE")),
            " entry=", DoubleToString(s.entry, 5),
            " sl=", DoubleToString(s.sl, 5),
            " tp1=", DoubleToString(s.tp1, 5),
            " runner=", DoubleToString(s.tpRunner, 5),
            " score=", s.score, " mult=", DoubleToString(s.riskMult, 2),
            " reason=", s.reason);
   }
};

#endif // SMC_LOGGER_MQH
