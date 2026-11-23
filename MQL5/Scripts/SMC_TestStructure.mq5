//+------------------------------------------------------------------+
//|  SMC_TestStructure.mq5                                           |
//|  Phase-1 smoke test / self-check for SMC_Time + SMC_Structure.   |
//|                                                                  |
//|  Run it from MetaEditor (F7) or drag it on a chart.  It prints   |
//|  PASS/FAIL lines to the Experts journal and a summary.  The same |
//|  cases live in tests/test_time.py and tests/test_structure.py.   |
//+------------------------------------------------------------------+
#property script_show_inputs
#include <SMC/SMC_Time.mqh>
#include <SMC/SMC_Structure.mqh>

int g_pass = 0;
int g_fail = 0;
string g_report = "";

void LogLine(const string s)
{
   Print(s);
   g_report += s + "\r\n";
}

void Check(const bool cond, const string label)
{
   if(cond)
   {
      g_pass++;
      LogLine("PASS  " + label);
   }
   else
   {
      g_fail++;
      LogLine("FAIL  " + label);
   }
}

void CheckEq(const long a, const long b, const string label)
{
   Check(a == b, StringFormat("%s  (got %I64d, want %I64d)", label, a, b));
}

void CheckNear(const double a, const double b, const string label)
{
   Check(MathAbs(a - b) < 1e-9,
         StringFormat("%s  (got %.10f, want %.10f)", label, a, b));
}

//--- helper: feed (h,l,c) with open = previous close -----------------
void Push(CStructure &eng, datetime &t, double &prev,
          const double h, const double l, const double c)
{
   double o = (prev > 0.0 ? prev : c);
   eng.PushBar(t, o, h, l, c);
   t += 900;
   prev = c;
}

void TestTime()
{
   CTimeEngine te;
   te.Init(false, 2.0, 3.0, SMC_DST_EU);

   Check(!CTimeEngine::IsUsDst(D'2024.03.10 06:59'), "US DST false at 06:59");
   Check(CTimeEngine::IsUsDst(D'2024.03.10 07:00'), "US DST true at 07:00");
   Check(CTimeEngine::IsUsDst(D'2024.11.03 05:59'), "US DST true before autumn");
   Check(!CTimeEngine::IsUsDst(D'2024.11.03 06:00'), "US DST false after autumn");
   Check(!CTimeEngine::IsEuDst(D'2024.03.31 00:59'), "EU DST false at 00:59");
   Check(CTimeEngine::IsEuDst(D'2024.03.31 01:00'), "EU DST true at 01:00");
   Check(CTimeEngine::IsEuDst(D'2024.10.27 00:59'), "EU DST true before October end");
   Check(!CTimeEngine::IsEuDst(D'2024.10.27 01:00'), "EU DST false after October end");

   CheckEq(te.ToNY(D'2024.03.15 12:00'), D'2024.03.15 06:00',
           "server->NY EU/US mismatch (Mar)");
   CheckEq(te.ToNY(D'2024.07.15 12:00'), D'2024.07.15 05:00',
           "server->NY summer");
   CheckEq(te.ToNY(D'2024.01.15 12:00'), D'2024.01.15 05:00',
           "server->NY winter");
   CheckEq(te.ToNY(D'2024.04.15 12:00'), D'2024.04.15 05:00',
           "server->NY EU summer");
   CheckEq(te.ToServer(D'2024.07.15 05:00'), D'2024.07.15 12:00',
           "NY->server summer");

   Check(te.KillZone(D'2024.07.16 05:00', 0) == "",
         "LKZ closed exactly at 05:00");
   Check(te.KillZone(D'2024.07.16 05:00', 30) == "LONDON",
         "LKZ grace 05:00");
   Check(te.KillZone(D'2024.07.16 05:29', 30) == "LONDON",
         "LKZ grace 05:29");
   Check(te.KillZone(D'2024.07.16 05:30', 30) == "",
         "LKZ grace expired 05:30");
   Check(te.KillZone(D'2024.07.16 07:00', 0) == "NEW_YORK",
         "NY KZ start");
   Check(te.KillZone(D'2024.07.16 01:59', 30) == "",
         "no KZ before London");
   Check(te.InAsia(D'2024.07.16 18:00', false), "Asia 18:00");
   Check(!te.InAsia(D'2024.07.16 00:00', false), "Asia ends at midnight");
   Check(CTimeEngine::AsiaBoxStart(D'2024.07.16 00:00', false)
         == D'2024.07.15 17:00', "Asia box start 17:00 previous day");
   Check(CTimeEngine::AsiaBoxStart(D'2024.07.16 00:00', true)
         == D'2024.07.15 19:00', "ICT standard Asia start 19:00");
}

void TestStructure()
{
   //--- 1. strict fractal --------------------------------------------
   {
      CStructure eng;
      eng.Init("TEST", PERIOD_M15, 1, true, 0.1, 14, 3, true);
      datetime t = 1700000000; double prev = 0.0;
      Push(eng, t, prev, 1.1000, 1.0990, 1.0995);
      Push(eng, t, prev, 1.1020, 1.1000, 1.1010);
      Push(eng, t, prev, 1.1015, 1.0990, 1.1000);
      Push(eng, t, prev, 1.1010, 1.0975, 1.0980);
      Push(eng, t, prev, 1.1005, 1.0985, 1.0995);
      SMC_Swing sw;
      CheckEq(eng.HighCount(), 1, "swings: one strict high");
      Check(eng.GetHigh(0, sw) && sw.idx == 1, "swings: high at bar 1");
      CheckNear(sw.price, 1.1020, "swings: high price");
      CheckEq(eng.LowCount(), 1, "swings: one strict low");
      Check(eng.GetLow(0, sw) && sw.idx == 3, "swings: low at bar 3");
   }

   //--- 2. equal-high plateau is not a swing --------------------------
   {
      CStructure eng;
      eng.Init("TEST", PERIOD_M15, 1, true, 0.1, 14, 3, true);
      datetime t = 1700000000; double prev = 0.0;
      Push(eng, t, prev, 1.1000, 1.0990, 1.0995);
      Push(eng, t, prev, 1.1010, 1.0995, 1.1000);
      Push(eng, t, prev, 1.1015, 1.1000, 1.1010);
      Push(eng, t, prev, 1.1030, 1.1005, 1.1020);
      Push(eng, t, prev, 1.1030, 1.1010, 1.1025);
      Push(eng, t, prev, 1.1020, 1.1000, 1.1005);
      CheckEq(eng.HighCount(), 0, "equal highs are excluded");
   }

   //--- 3. swept high + origin BOS = strong high, provisional range ---
   {
      CStructure eng;
      eng.Init("TEST", PERIOD_M15, 1, true, 0.1, 14, 3, true);
      datetime t = 1700000000; double prev = 0.0;
      Push(eng, t, prev, 1.1000, 1.0990, 1.0995);
      Push(eng, t, prev, 1.1020, 1.1000, 1.1010);
      Push(eng, t, prev, 1.1015, 1.0990, 1.1000);
      Push(eng, t, prev, 1.1010, 1.0975, 1.0980);
      Push(eng, t, prev, 1.1005, 1.0985, 1.0995);
      Push(eng, t, prev, 1.1035, 1.0995, 1.1015);
      Push(eng, t, prev, 1.1030, 1.1000, 1.1005);
      Push(eng, t, prev, 1.1020, 1.0968, 1.0970);
      SMC_Swing sh;
      Check(eng.GetStrongHigh(sh), "strong high exists");
      CheckEq(sh.idx, 5, "strong high bar");
      CheckNear(sh.price, 1.1035, "strong high price");
      Check(sh.swept, "strong high swept");
      SMC_Range prov;
      Check(eng.GetProvisionalRange(prov), "provisional range exists");
      CheckEq(prov.dir, SMC_BEAR, "provisional is bearish");
      CheckNear(prov.rh, 1.1035, "provisional RH");
      CheckNear(prov.rl, 1.0968, "provisional RL");
      CheckEq(eng.RangeCount(), 0, "no confirmed range yet");
      CheckEq(eng.Bias(), SMC_NEUTRAL, "bias neutral before confirm");
   }

   //--- 4. minor break does not confirm, pivot break does ------------
   {
      CStructure eng;
      eng.Init("TEST", PERIOD_M15, 1, true, 0.1, 14, 3, true);
      datetime t = 1700000000; double prev = 0.0;
      double H[] = {1.1000, 1.1020, 1.1015, 1.1010, 1.1005, 1.1035, 1.1030,
                    1.1020, 1.0980, 1.0990, 1.0975, 1.0970, 1.0950, 1.0955,
                    1.0952, 1.0960, 1.0995};
      double L[] = {1.0990, 1.1000, 1.0990, 1.0975, 1.0985, 1.0995, 1.1000,
                    1.0968, 1.0960, 1.0970, 1.0960, 1.0940, 1.0930, 1.0935,
                    1.0938, 1.0940, 1.0955};
      double C[] = {1.0995, 1.1010, 1.1000, 1.0980, 1.0995, 1.1015, 1.1005,
                    1.0970, 1.0975, 1.0980, 1.0965, 1.0945, 1.0940, 1.0948,
                    1.0940, 1.0958, 1.0992};
      for(int k = 0; k < 16; k++)
         Push(eng, t, prev, H[k], L[k], C[k]);
      CheckEq(eng.RangeCount(), 0, "minor break does not confirm");
      SMC_Bos bos;
      Check(eng.GetLastBos(bos), "last BOS present");
      CheckEq(bos.dir, SMC_BULL, "minor RANGE break is a bullish BOS");
      CheckNear(bos.swingPrice, 1.0955, "minor break level");

      Push(eng, t, prev, H[16], L[16], C[16]);
      CheckEq(eng.RangeCount(), 1, "range confirmed at pivot break");
      SMC_Range r;
      Check(eng.GetLastRange(r), "confirmed range present");
      CheckEq(r.dir, SMC_BEAR, "range direction bearish");
      CheckNear(r.rh, 1.1035, "range RH");
      CheckNear(r.rl, 1.0930, "range RL");
      CheckNear(r.eq, (1.1035 + 1.0930) / 2.0, "range EQ");
      CheckNear(r.irlPrice, 1.0990, "range IRL price");
      Check(r.irlTaken, "IRL taken");
      CheckEq(eng.Bias(), SMC_BEAR, "bias bearish");
      Check(eng.BiasValid(), "bias valid");
      Check(eng.RangeZone(r, 1.1030) == "EXTREME_PREMIUM",
            "extreme premium zone");
      Check(eng.RangeZone(r, 1.0940) == "EXTREME_DISCOUNT",
            "extreme discount zone");
      Check(eng.RangeZone(r, 1.1000) == "PREMIUM", "premium zone");
   }

   //--- 5. BOS by wick ------------------------------------------------
   {
      CStructure eng;
      eng.Init("TEST", PERIOD_M15, 1, false, 0.1, 14, 3, true);
      datetime t = 1700000000; double prev = 0.0;
      Push(eng, t, prev, 1.1000, 1.0990, 1.0995);
      Push(eng, t, prev, 1.1020, 1.1000, 1.1010);
      Push(eng, t, prev, 1.1015, 1.0990, 1.1000);
      Push(eng, t, prev, 1.1010, 1.0975, 1.0980);
      Push(eng, t, prev, 1.1005, 1.0985, 1.0995);
      Push(eng, t, prev, 1.1035, 1.0995, 1.1015);
      Push(eng, t, prev, 1.1030, 1.1000, 1.1005);
      Push(eng, t, prev, 1.1020, 1.0968, 1.0990);
      // the close is above the origin low, only the wick breaks it
      SMC_Swing sh;
      Check(eng.GetStrongHigh(sh), "wick BOS produces strong high");
      CheckNear(sh.price, 1.1035, "wick BOS strong high price");
   }

   //--- 6. bullish mirror ---------------------------------------------
   {
      CStructure eng;
      eng.Init("TEST", PERIOD_M15, 1, true, 0.1, 14, 3, true);
      datetime t = 1700000000; double prev = 0.0;
      double K = 2.0;
      double H[] = {1.1000, 1.1020, 1.1015, 1.1010, 1.1005, 1.1035, 1.1030,
                    1.1020, 1.0980, 1.0990, 1.0975, 1.0970, 1.0950, 1.0955,
                    1.0952, 1.0960, 1.0995};
      double L[] = {1.0990, 1.1000, 1.0990, 1.0975, 1.0985, 1.0995, 1.1000,
                    1.0968, 1.0960, 1.0970, 1.0960, 1.0940, 1.0930, 1.0935,
                    1.0938, 1.0940, 1.0955};
      double C[] = {1.0995, 1.1010, 1.1000, 1.0980, 1.0995, 1.1015, 1.1005,
                    1.0970, 1.0975, 1.0980, 1.0965, 1.0945, 1.0940, 1.0948,
                    1.0940, 1.0958, 1.0992};
      for(int k = 0; k < 17; k++)
         Push(eng, t, prev, K - L[k], K - H[k], K - C[k]);
      SMC_Range r;
      Check(eng.GetLastRange(r), "mirror: bullish range confirmed");
      CheckEq(r.dir, SMC_BULL, "mirror: direction bullish");
      CheckNear(r.rl, K - 1.1035, "mirror: range low");
      CheckNear(r.rh, K - 1.0930, "mirror: range high");
      CheckNear(r.irlPrice, K - 1.0990, "mirror: IRL");
      CheckEq(eng.Bias(), SMC_BULL, "mirror: bias bullish");
   }
}

void OnStart()
{
   Print("=== SMC Phase-1 self-test ===");
   g_report = "SMC Phase-1 self-test\r\n";
   g_report += "terminal build: " + IntegerToString((int)TerminalInfoInteger(TERMINAL_BUILD)) + "\r\n";
   g_report += "server time: " + TimeToString(TimeTradeServer(), TIME_DATE | TIME_MINUTES) + "\r\n\r\n";
   TestTime();
   TestStructure();
   LogLine(StringFormat("=== %d passed, %d failed ===", g_pass, g_fail));
   if(g_fail > 0)
      LogLine("RESULT: FAIL");
   else
      LogLine("RESULT: OK");
   LogLine("SMC_TEST_DONE");

   int fh = FileOpen("SMC_Phase1_Test.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh != INVALID_HANDLE)
   {
      FileWriteString(fh, g_report);
      FileClose(fh);
      Print("Report written to MQL5\\Files\\SMC_Phase1_Test.txt");
   }
   else
      Print("Could not write report, error ", GetLastError());
}
