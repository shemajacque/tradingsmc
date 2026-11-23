//+------------------------------------------------------------------+
//|                                              SMC_ExportData.mq5  |
//| Export server-time OHLC history to MQL5\Files for the Python     |
//| reference backtest.                                               |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs
#property version   "1.00"

input datetime InpFrom        = D'2024.01.01';   // export start (server time)
input string   InpSymbols     = "GBPUSD,XAUUSD"; // comma separated
input int      InpMaxAttempts = 60;              // CopyRates retries (x500 ms)

string TfName(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M15: return "M15";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      default:         return EnumToString(tf);
   }
}

int Export(const string sym, const ENUM_TIMEFRAMES tf)
{
   MqlRates r[];
   int n = -1;
   for(int a = 0; a < InpMaxAttempts; a++)
   {
      n = CopyRates(sym, tf, InpFrom, TimeTradeServer() + 86400, r);
      if(n > 0)
         break;
      if(n == 0)
         break;
      Sleep(500);
   }
   if(n <= 0)
   {
      PrintFormat("EXPORT %s %s: NO DATA (%d)", sym, TfName(tf), n);
      return 0;
   }
   ArraySetAsSeries(r, false);

   string fn = sym + "_" + TfName(tf) + ".csv";
   int h = FileOpen(fn, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("EXPORT %s: open failed err=%d", fn, GetLastError());
      return 0;
   }
   FileWriteString(h, "time,open,high,low,close\n");
   for(int i = 0; i < n; i++)
   {
      FileWriteString(h,
         IntegerToString((long)r[i].time) + "," +
         DoubleToString(r[i].open, 8) + "," +
         DoubleToString(r[i].high, 8) + "," +
         DoubleToString(r[i].low, 8) + "," +
         DoubleToString(r[i].close, 8) + "\n");
   }
   FileClose(h);
   PrintFormat("EXPORT %s %s: %d bars %s .. %s",
      sym, TfName(tf), n,
      TimeToString(r[0].time, TIME_DATE | TIME_MINUTES),
      TimeToString(r[n - 1].time, TIME_DATE | TIME_MINUTES));
   return n;
}

void OnStart()
{
   long off_gmt   = (long)(TimeTradeServer() - TimeGMT());
   long off_local = (long)(TimeTradeServer() - TimeLocal());

   ENUM_TIMEFRAMES tfs[4];
   tfs[0] = PERIOD_M15;
   tfs[1] = PERIOD_H1;
   tfs[2] = PERIOD_H4;
   tfs[3] = PERIOD_D1;

   string parts[];
   int k = StringSplit(InpSymbols, ',', parts);
   if(k <= 0)
   {
      Print("EXPORT: empty symbol list");
      return;
   }

   int meta = FileOpen("export_meta.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(meta == INVALID_HANDLE)
   {
      PrintFormat("EXPORT: meta open failed err=%d", GetLastError());
      return;
   }
   FileWriteString(meta,
      "local=" + TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS) + "\n" +
      "gmt=" + TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS) + "\n" +
      "server=" + TimeToString(TimeTradeServer(), TIME_DATE | TIME_SECONDS) + "\n" +
      "server_minus_gmt_sec=" + IntegerToString(off_gmt) + "\n" +
      "server_minus_local_sec=" + IntegerToString(off_local) + "\n" +
      "terminal_build=" + IntegerToString((int)TerminalInfoInteger(TERMINAL_BUILD)) + "\n" +
      "company=" + TerminalInfoString(TERMINAL_COMPANY) + "\n" +
      "server_name=" + AccountInfoString(ACCOUNT_SERVER) + "\n" +
      "currency=" + AccountInfoString(ACCOUNT_CURRENCY) + "\n");

   for(int s = 0; s < k; s++)
   {
      string sym = parts[s];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if(StringLen(sym) == 0)
         continue;
      if(!SymbolSelect(sym, true))
      {
         PrintFormat("EXPORT %s: SymbolSelect failed", sym);
         continue;
      }
      for(int t = 0; t < 4; t++)
      {
         int n = Export(sym, tfs[t]);
         FileWriteString(meta, "bars " + sym + " " + TfName(tfs[t]) + "=" + IntegerToString(n) + "\n");
      }
   }
   FileWriteString(meta, "SMC_EXPORT_DONE\n");
   FileClose(meta);
   Print("SMC_EXPORT_DONE");
}
