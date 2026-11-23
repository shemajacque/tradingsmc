//+------------------------------------------------------------------+
//|                                                     SMC_Web.mqh  |
//| Minimal HTTPS/JSON client for the SMC Control Center.            |
//| Flat JSON only (the app answers flat objects).                    |
//+------------------------------------------------------------------+
#ifndef SMC_WEB_MQH
#define SMC_WEB_MQH

int g_smc_web_error = 0;

string SMC_JsonEscape(const string s)
{
   string o = s;
   StringReplace(o, "\\", "\\\\");
   StringReplace(o, "\"", "\\\"");
   StringReplace(o, "\n", "\\n");
   StringReplace(o, "\r", "\\r");
   return o;
}

string SMC_JsonGet(const string js, const string key, const string def = "")
{
   string pat = "\"" + key + "\"";
   int p = StringFind(js, pat);
   if(p < 0)
      return def;
   p = StringFind(js, ":", p + StringLen(pat));
   if(p < 0)
      return def;
   p++;
   int n = StringLen(js);
   while(p < n)
   {
      ushort c = StringGetCharacter(js, p);
      if(c != ' ' && c != '\t' && c != '\r' && c != '\n')
         break;
      p++;
   }
   if(p >= n)
      return def;
   ushort c0 = StringGetCharacter(js, p);
   if(c0 == '"')
   {
      int q = p + 1;
      int e = -1;
      while(q < n)
      {
         ushort c = StringGetCharacter(js, q);
         if(c == '"' && StringGetCharacter(js, q - 1) != '\\')
         {
            e = q;
            break;
         }
         q++;
      }
      if(e < 0)
         return def;
      string v = StringSubstr(js, p + 1, e - p - 1);
      StringReplace(v, "\\\"", "\"");
      StringReplace(v, "\\\\", "\\");
      return v;
   }
   int e = p;
   while(e < n)
   {
      ushort c = StringGetCharacter(js, e);
      if(c == ',' || c == '}' || c == ']' || c == '\n' || c == '\r')
         break;
      e++;
   }
   string v = StringSubstr(js, p, e - p);
   StringTrimLeft(v);
   StringTrimRight(v);
   return v;
}

bool SMC_JsonGetBool(const string js, const string key, const bool def = false)
{
   string v = SMC_JsonGet(js, key, "");
   if(v == "")
      return def;
   StringToLower(v);
   return (v == "true" || v == "1");
}

double SMC_JsonGetDouble(const string js, const string key, const double def = 0.0)
{
   string v = SMC_JsonGet(js, key, "");
   if(v == "")
      return def;
   return StringToDouble(v);
}

int SMC_JsonGetInt(const string js, const string key, const int def = 0)
{
   string v = SMC_JsonGet(js, key, "");
   if(v == "")
      return def;
   return (int)StringToInteger(v);
}

//--- POST JSON. Returns HTTP code, or -1 (check GetLastError()).
int SMC_HttpPost(const string url, const string token, const string body,
                 string &response)
{
   response = "";
   char data[];
   int len = StringLen(body);
   if(len > 0)
      StringToCharArray(body, data, 0, len, CP_UTF8);
   else
      ArrayResize(data, 0);

   char result[];
   string rheaders = "";
   string headers = "Content-Type: application/json\r\n";
   if(token != "")
      headers += "Authorization: Bearer " + token + "\r\n";

   ResetLastError();
   int code = WebRequest("POST", url, headers, 8000, data, result, rheaders);
   g_smc_web_error = 0;
   if(code == -1)
   {
      int err = GetLastError();
      g_smc_web_error = err;
      if(err == 4014 || err == 4060)
         PrintFormat("SMC Web: WebRequest blocked (err=%d, %s). Add the app URL in "
                     "Tools > Options > Expert Advisors > Allow WebRequest for listed "
                     "URL. MT5 only connects on port 80 (http) or 443 (https).",
                     err, url);
      else
         PrintFormat("SMC Web: request failed err=%d url=%s", err, url);
      return -1;
   }
   response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return code;
}

#endif // SMC_WEB_MQH
