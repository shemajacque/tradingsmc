//+------------------------------------------------------------------+
//|                                                     SMC_Link.mq5 |
//| Token activation + heartbeat client for the SMC Control Center.  |
//| This EA does NOT trade. It validates the activation token, keeps  |
//| the app updated with the account snapshot and exposes the remote  |
//| config to the trading engine (SMC_LinkEnabled() etc.).            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Connects MT5 to the hosted SMC Control Center using an activation token."

#include <SMC/SMC_Web.mqh>

input string InpAppUrl        = "https://your-app.example.com"; // App URL (no trailing slash)
input string InpToken         = "";                             // Activation token (smc_...)
input int    InpHeartbeatSec  = 30;                             // Heartbeat seconds (min 10)
input bool   InpAllowLive     = false;                          // Allow real (non-demo) accounts
input bool   InpVerbose       = true;                           // Print every heartbeat

bool     g_ok          = false;
bool     g_enabled     = false;
bool     g_demo_only   = true;
double   g_risk_pct    = 0.5;
int      g_max_trades  = 3;
string   g_symbols     = "";
int      g_magic       = 0;
string   g_last_error  = "";
datetime g_last_ok     = 0;
string   g_base        = "";
int      g_fail_count  = 0;

// ---------------------------------------------------------------------------
string TrimTrailingSlash(string s)
{
   while(StringLen(s) > 0 && StringGetCharacter(s, StringLen(s) - 1) == '/')
      s = StringSubstr(s, 0, StringLen(s) - 1);
   return s;
}

bool IsDemoAccount()
{
   return (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE)
          == ACCOUNT_TRADE_MODE_DEMO;
}

string AccountJsonHead()
{
   return "\"login\":" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) +
          ",\"server\":\"" + SMC_JsonEscape(AccountInfoString(ACCOUNT_SERVER)) + "\"";
}

string PositionsJson()
{
   string out = "[";
   int total = PositionsTotal();
   bool first = true;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      long   typ = PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      double pr  = PositionGetDouble(POSITION_PROFIT);
      long   tm  = (long)PositionGetInteger(POSITION_TIME);
      if(!first)
         out += ",";
      first = false;
      out += "{\"ticket\":" + IntegerToString((long)ticket) +
             ",\"symbol\":\"" + SMC_JsonEscape(sym) + "\"" +
             ",\"dir\":\"" + (typ == POSITION_TYPE_BUY ? "buy" : "sell") + "\"" +
             ",\"lots\":" + DoubleToString(vol, 2) +
             ",\"open\":" + DoubleToString(op, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)) +
             ",\"profit\":" + DoubleToString(pr, 2) +
             ",\"open_time\":" + IntegerToString(tm) + "}";
   }
   return out + "]";
}

void ApplyConfig(const string js)
{
   g_enabled    = SMC_JsonGetBool(js, "enabled", false);
   g_demo_only  = SMC_JsonGetBool(js, "demo_only", true);
   g_risk_pct   = SMC_JsonGetDouble(js, "risk_pct", 0.5);
   g_max_trades = SMC_JsonGetInt(js, "max_trades_day", 3);
   g_symbols    = SMC_JsonGet(js, "symbols", "");
   g_magic      = SMC_JsonGetInt(js, "magic", 0);

   if(g_demo_only && !IsDemoAccount())
   {
      g_enabled = false;
      g_last_error = "token is demo-only but this account is real";
   }
   if(!InpAllowLive && !IsDemoAccount())
   {
      g_enabled = false;
      g_last_error = "live account blocked by InpAllowLive=false";
   }
}

bool Activate()
{
   string body = "{" + AccountJsonHead() +
                 ",\"build\":" + IntegerToString((long)TerminalInfoInteger(TERMINAL_BUILD)) +
                 ",\"symbol\":\"" + SMC_JsonEscape(_Symbol) + "\"" +
                 ",\"demo\":" + (IsDemoAccount() ? "true" : "false") + "}";
   string resp = "";
   int code = SMC_HttpPost(g_base + "/api/v1/activate", InpToken, body, resp);
   if(code != 200)
   {
      string detail = SMC_JsonGet(resp, "detail", "");
      g_last_error = "activate failed HTTP " + IntegerToString(code) +
                     (detail != "" ? ": " + detail : "") +
                     (g_smc_web_error > 0 ? " [" + IntegerToString(g_smc_web_error) + "]" : "");
      if(g_smc_web_error == 4014 || g_smc_web_error == 4060)
         g_last_error += " - allow the app URL in MT5 Options";
      g_ok = false;
      g_enabled = false;
      return false;
   }
   if(SMC_JsonGet(resp, "status", "") != "ok")
   {
      g_last_error = "activate: unexpected response";
      g_ok = false;
      g_enabled = false;
      return false;
   }
   ApplyConfig(resp);
   g_ok = true;
   g_last_ok = TimeLocal();
   g_fail_count = 0;
   g_last_error = "";
   PrintFormat("SMC Link: activated for %s (%s) demo=%s enabled=%s risk=%.2f%%",
               IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)),
               AccountInfoString(ACCOUNT_SERVER),
               IsDemoAccount() ? "yes" : "NO",
               g_enabled ? "yes" : "no", g_risk_pct);
   return true;
}

bool Heartbeat()
{
   string pos = PositionsJson();
   string body = "{" + AccountJsonHead() +
                 ",\"account_name\":\"" + SMC_JsonEscape(AccountInfoString(ACCOUNT_NAME)) + "\"" +
                 ",\"currency\":\"" + SMC_JsonEscape(AccountInfoString(ACCOUNT_CURRENCY)) + "\"" +
                 ",\"leverage\":" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LEVERAGE)) +
                 ",\"balance\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) +
                 ",\"equity\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) +
                 ",\"margin_free\":" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2) +
                 ",\"demo\":" + (IsDemoAccount() ? "true" : "false") +
                 ",\"day_pnl\":0" +
                 ",\"positions\":" + pos +
                 ",\"closed\":[]}";
   string resp = "";
   int code = SMC_HttpPost(g_base + "/api/v1/heartbeat", InpToken, body, resp);
   if(code != 200)
   {
      g_fail_count++;
      string detail = SMC_JsonGet(resp, "detail", "");
      g_last_error = "heartbeat failed HTTP " + IntegerToString(code) +
                     (detail != "" ? ": " + detail : "") +
                     (g_smc_web_error > 0 ? " [" + IntegerToString(g_smc_web_error) + "]" : "");
      g_enabled = false;
      if(g_fail_count >= 3)
         g_ok = false;
      return false;
   }
   ApplyConfig(resp);
   g_ok = true;
   g_fail_count = 0;
   g_last_ok = TimeLocal();
   g_last_error = "";
   if(InpVerbose)
      PrintFormat("SMC Link: heartbeat ok, enabled=%s positions=%d",
                  g_enabled ? "yes" : "no", PositionsTotal());
   return true;
}

void RefreshComment()
{
   string state;
   if(!g_ok)
      state = "OFFLINE " + (g_last_error != "" ? "(" + g_last_error + ")" : "");
   else if(!g_enabled)
      state = "CONNECTED / TRADING DISABLED" +
              (g_last_error != "" ? " (" + g_last_error + ")" : "");
   else
      state = "ACTIVE";
   string txt = "SMC LINK  |  " + state + "\n" +
                "Account: " + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) +
                "  " + AccountInfoString(ACCOUNT_SERVER) +
                "  " + (IsDemoAccount() ? "DEMO" : "LIVE") + "\n" +
                "Risk: " + DoubleToString(g_risk_pct, 2) + "%/trade   Max/day: " +
                IntegerToString(g_max_trades) + "\n" +
                "Symbols: " + (g_symbols == "" ? "-" : g_symbols) +
                "   Magic: " + IntegerToString(g_magic) + "\n" +
                "Last sync: " + (g_last_ok > 0 ? TimeToString(g_last_ok, TIME_MINUTES | TIME_SECONDS) : "never");
   Comment(txt);
}

// ---------------------------------------------------------------------------
int OnInit()
{
   g_base = TrimTrailingSlash(InpAppUrl);
   if(InpToken == "" || StringFind(InpToken, "smc_") != 0)
   {
      Print("SMC Link: set InpToken to the token created in the app (starts with smc_).");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(StringFind(g_base, "http://") != 0 && StringFind(g_base, "https://") != 0)
   {
      Print("SMC Link: InpAppUrl must start with http:// or https://");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(MQLInfoInteger(MQL_TESTER))
   {
      Print("SMC Link: WebRequest is disabled in the strategy tester.");
      return INIT_FAILED;
   }
   PrintFormat("SMC Link: connecting to %s ...", g_base);
   if(!Activate())
      PrintFormat("SMC Link: activation failed - %s", g_last_error);
   EventSetTimer(MathMax(10, InpHeartbeatSec));
   RefreshComment();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}

void OnTimer()
{
   if(!g_ok)
      Activate();
   else
      Heartbeat();
   RefreshComment();
}

void OnTick()
{
   RefreshComment();
}

// ---------------------------------------------------------------------------
// Public helpers for the trading EA (copy into the trading EA or refactor
// into an include when the strategy layer is added).
// ---------------------------------------------------------------------------
bool   SMC_LinkReady()    { return g_ok; }
bool   SMC_LinkEnabled()  { return g_ok && g_enabled; }
double SMC_LinkRiskPct()  { return g_risk_pct; }
string SMC_LinkSymbols()  { return g_symbols; }
int    SMC_LinkMagic()    { return g_magic; }
int    SMC_LinkMaxTradesDay() { return g_max_trades; }
