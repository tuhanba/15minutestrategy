//+------------------------------------------------------------------+
//| RBOTE_ImportDukascopy.mq5                                        |
//| Builds a custom symbol from Dukascopy M1 BID/ASK candles (UTC):  |
//|   time;bid_o;bid_h;bid_l;bid_c;ask_o;ask_h;ask_l;ask_c;volume    |
//| - M1 bars = BID OHLC, MqlRates.spread = ask_open-bid_open (pts)  |
//| - 4 synthetic ticks per minute built from BID+ASK OHLC so the    |
//|   tester's "real ticks" model sees real bid/ask spreads:         |
//|     bullish minute: O(:00) L(:15) H(:30) C(:45)                  |
//|     bearish minute: O(:00) H(:15) L(:30) C(:45)                  |
//|   the low tick pairs bid_low with ask_low, the high tick pairs   |
//|   bid_high with ask_high (so ask_low and bid_high are reachable  |
//|   exactly like the C++ fill model).                              |
//| Files are read from <Common>\Files\<InpDir>\.                    |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

input string InpSymbol   = "XAUUSD.DK";
input string InpDir      = "RBOTE_DATA";
input string InpFiles    = "XAUUSD_M1_2020.csv";  // comma-separated
input bool   InpTicks    = true;                  // also write synthetic ticks
input int    InpDigits   = 3;                     // Dukascopy XAU has 3 decimals
input double InpTickSize = 0.01;                  // same as the C++ backtester
input double InpTickVal  = 1.0;                   // USD per 0.01 per 1 lot (100 oz)

MqlRates g_rates[];
MqlTick  g_ticks[];
int      g_nr = 0, g_nt = 0;
long     g_total_rates = 0, g_total_ticks = 0;
datetime g_first = 0, g_last = 0;

bool Chk(bool r, int line)
  {
   if(!r)
      PrintFormat("symbol property at line %d failed, err %d", line, GetLastError());
   ResetLastError();
   return r;
  }

bool SetupSymbol(void)
  {
   if(!SymbolInfoInteger(InpSymbol, SYMBOL_CUSTOM))
     {
      ResetLastError();
      if(!CustomSymbolCreate(InpSymbol, "Custom\\Dukascopy", NULL))
        {
         PrintFormat("CustomSymbolCreate failed %d", GetLastError());
         return false;
        }
     }
   string s = InpSymbol;
   bool ok = true;
   ok = Chk(CustomSymbolSetString(s, SYMBOL_DESCRIPTION, "XAUUSD Dukascopy M1 (UTC), RBOTE cross-check"), __LINE__) && ok;
   ok = Chk(CustomSymbolSetString(s, SYMBOL_CURRENCY_BASE, "XAU"), __LINE__) && ok;
   ok = Chk(CustomSymbolSetString(s, SYMBOL_CURRENCY_PROFIT, "USD"), __LINE__) && ok;
   ok = Chk(CustomSymbolSetString(s, SYMBOL_CURRENCY_MARGIN, "USD"), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_DIGITS, InpDigits), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_POINT, MathPow(10.0, -InpDigits)), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_TRADE_TICK_SIZE, InpTickSize), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_TRADE_TICK_VALUE, InpTickVal), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_TRADE_CONTRACT_SIZE, 100.0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_TRADE_CALC_MODE, SYMBOL_CALC_MODE_CFDLEVERAGE), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_CHART_MODE, SYMBOL_CHART_MODE_BID), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_VOLUME_MIN, 0.01), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_VOLUME_MAX, 100.0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_VOLUME_STEP, 0.01), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_VOLUME_LIMIT, 0.0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_TRADE_MODE, SYMBOL_TRADE_MODE_FULL), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_TRADE_EXEMODE, SYMBOL_TRADE_EXECUTION_MARKET), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_TRADE_STOPS_LEVEL, 0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_TRADE_FREEZE_LEVEL, 0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_SPREAD_FLOAT, true), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_SPREAD, 0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_FILLING_MODE, SYMBOL_FILLING_FOK | SYMBOL_FILLING_IOC), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_EXPIRATION_MODE,
                                SYMBOL_EXPIRATION_GTC | SYMBOL_EXPIRATION_DAY | SYMBOL_EXPIRATION_SPECIFIED |
                                SYMBOL_EXPIRATION_SPECIFIED_DAY), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_ORDER_MODE,
                                SYMBOL_ORDER_MARKET | SYMBOL_ORDER_LIMIT | SYMBOL_ORDER_STOP | SYMBOL_ORDER_STOP_LIMIT |
                                SYMBOL_ORDER_SL | SYMBOL_ORDER_TP), __LINE__) && ok;
   ok = Chk(CustomSymbolSetInteger(s, SYMBOL_SWAP_MODE, SYMBOL_SWAP_MODE_DISABLED), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_SWAP_LONG, 0.0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_SWAP_SHORT, 0.0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_MARGIN_INITIAL, 0.0), __LINE__) && ok;
   ok = Chk(CustomSymbolSetDouble(s, SYMBOL_MARGIN_MAINTENANCE, 0.0), __LINE__) && ok;
   for(int t = (int)ORDER_TYPE_BUY; t <= (int)ORDER_TYPE_SELL_STOP_LIMIT; t++)
      ok = Chk(CustomSymbolSetMarginRate(s, (ENUM_ORDER_TYPE)t, 1.0, 1.0), __LINE__) && ok;
   //--- 24h quote/trade sessions every day (data gaps define the real market hours)
   for(int d = 0; d < 7; d++)
     {
      ok = Chk(CustomSymbolSetSessionQuote(s, (ENUM_DAY_OF_WEEK)d, 0, 0, 86400), __LINE__) && ok;
      ok = Chk(CustomSymbolSetSessionTrade(s, (ENUM_DAY_OF_WEEK)d, 0, 0, 86400), __LINE__) && ok;
     }
   if(!ok)
      PrintFormat("WARNING: some symbol properties failed, last error %d", GetLastError());
   SymbolSelect(s, true);
   return true;
  }

void AddTick(datetime t, int ms, double bid, double ask)
  {
   if(g_nt >= ArraySize(g_ticks))
      ArrayResize(g_ticks, g_nt + 8192);
   MqlTick k;
   ZeroMemory(k);
   k.time     = t;
   k.time_msc = (long)t * 1000 + ms;
   k.bid      = bid;
   k.ask      = ask;
   k.flags    = TICK_FLAG_BID | TICK_FLAG_ASK;
   g_ticks[g_nt++] = k;
  }

bool Flush(void)
  {
   if(g_nr == 0)
      return true;
   ArrayResize(g_rates, g_nr);
   if(InpTicks && g_nt > 0)
     {
      ArrayResize(g_ticks, g_nt);
      long from = (long)g_rates[0].time * 1000;
      long to   = (long)g_rates[g_nr - 1].time * 1000 + 59999;
      ResetLastError();
      int n = CustomTicksReplace(InpSymbol, from, to, g_ticks);
      if(n != g_nt)
         PrintFormat("CustomTicksReplace %s: %d of %d (err %d)", TimeToString(g_rates[0].time), n, g_nt, GetLastError());
      g_total_ticks += MathMax(n, 0);
     }
   ResetLastError();
   int r = CustomRatesUpdate(InpSymbol, g_rates);
   if(r != g_nr)
      PrintFormat("CustomRatesUpdate %s: %d of %d (err %d)", TimeToString(g_rates[0].time), r, g_nr, GetLastError());
   g_total_rates += MathMax(r, 0);
   g_nr = 0;
   g_nt = 0;
   ArrayResize(g_rates, 0, 2048);
   ArrayResize(g_ticks, 0, 8192);
   return true;
  }

bool ImportFile(const string name)
  {
   string path = InpDir + "\\" + name;
   int h = FileOpen(path, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("cannot open Common\\Files\\%s (err %d)", path, GetLastError());
      return false;
     }
   FileReadString(h);   // header
   long lines = 0;
   long cur_day = -1;
   string f[];
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      if(StringLen(line) < 20)
         continue;
      if(StringSplit(line, ';', f) < 10)
         continue;
      StringReplace(f[0], "-", ".");
      datetime t = StringToTime(f[0]);
      double bo = StringToDouble(f[1]), bh = StringToDouble(f[2]), bl = StringToDouble(f[3]), bc = StringToDouble(f[4]);
      double ao = StringToDouble(f[5]), ah = StringToDouble(f[6]), al = StringToDouble(f[7]), ac = StringToDouble(f[8]);
      if(t <= 0 || bo <= 0 || ao <= 0)
         continue;
      if(t <= g_last && g_last > 0)
         continue;   // overlap between files / unsorted line
      long day = (long)t / 86400;
      if(day != cur_day)
        {
         Flush();
         cur_day = day;
        }
      if(g_nr >= ArraySize(g_rates))
         ArrayResize(g_rates, g_nr + 2048);
      MqlRates r;
      ZeroMemory(r);
      r.time        = t;
      r.open        = bo;
      r.high        = bh;
      r.low         = bl;
      r.close       = bc;
      r.tick_volume = 4;
      r.real_volume = 0;
      r.spread      = (int)MathRound((ao - bo) / MathPow(10.0, -InpDigits));
      g_rates[g_nr++] = r;
      if(InpTicks)
        {
         AddTick(t, 0, bo, ao);
         if(bc >= bo)
           {
            AddTick(t + 15, 0, bl, al);
            AddTick(t + 30, 0, bh, ah);
           }
         else
           {
            AddTick(t + 15, 0, bh, ah);
            AddTick(t + 30, 0, bl, al);
           }
         AddTick(t + 45, 0, bc, ac);
        }
      if(g_first == 0)
         g_first = t;
      g_last = t;
      lines++;
     }
   Flush();
   FileClose(h);
   PrintFormat("imported %s: %I64d minutes", name, lines);
   return true;
  }

void OnStart(void)
  {
   if(!SetupSymbol())
      return;
   string files[];
   int nf = StringSplit(InpFiles, ',', files);
   for(int i = 0; i < nf; i++)
     {
      StringTrimLeft(files[i]);
      StringTrimRight(files[i]);
      if(files[i] != "")
         ImportFile(files[i]);
     }
   MqlTick chk[];
   int nt = InpTicks ? CopyTicksRange(InpSymbol, chk, COPY_TICKS_ALL, (ulong)g_first * 1000, (ulong)g_last * 1000 + 59999) : 0;
   PrintFormat("RBOTE import done: %s %s..%s rates=%I64d ticks=%I64d bars(M1)=%d bars(M15)=%d ticks_readback=%d "
               "digits=%d point=%g tick_size=%g tick_value=%g contract=%g",
               InpSymbol, TimeToString(g_first), TimeToString(g_last), g_total_rates, g_total_ticks,
               Bars(InpSymbol, PERIOD_M1), Bars(InpSymbol, PERIOD_M15), nt,
               (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS), SymbolInfoDouble(InpSymbol, SYMBOL_POINT),
               SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE), SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE),
               SymbolInfoDouble(InpSymbol, SYMBOL_TRADE_CONTRACT_SIZE));
  }
