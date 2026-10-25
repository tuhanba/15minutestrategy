//+------------------------------------------------------------------+
//| MT5Bridge.mqh - terminal access: symbol spec, account snapshot,  |
//| per-order metadata (global variables), duplicate detection,      |
//| economic-calendar filter. MQL5 only.                             |
//+------------------------------------------------------------------+
#ifndef RBOTE_MT5BRIDGE_MQH
#define RBOTE_MT5BRIDGE_MQH

#include "RiskGuard.mqh"
#include "TradeMath.mqh"
#include "Safety.mqh"

//--- read and validate the broker's symbol properties
bool RB_ReadSymbolSpec(const string sym, RBSymbolSpec &sp)
  {
   sp.digits          = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sp.point           = SymbolInfoDouble(sym, SYMBOL_POINT);
   sp.tick_size       = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   sp.tick_value_loss = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(!(sp.tick_value_loss > 0.0))
      sp.tick_value_loss = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   sp.vol_min         = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   sp.vol_max         = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   sp.vol_step        = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   sp.stops_level     = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   sp.freeze_level    = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   return RB_ValidateSpec(sp) == 0;
  }

string RB_SpecText(const RBSymbolSpec &sp)
  {
   return StringFormat("digits=%d point=%s tick_size=%s tick_value_loss=%s vol[min=%s max=%s step=%s] stops_level=%d freeze_level=%d",
                       sp.digits, DoubleToString(sp.point, 8), DoubleToString(sp.tick_size, 8),
                       DoubleToString(sp.tick_value_loss, 4), DoubleToString(sp.vol_min, 2),
                       DoubleToString(sp.vol_max, 2), DoubleToString(sp.vol_step, 2),
                       sp.stops_level, sp.freeze_level);
  }

//+------------------------------------------------------------------+
//| Global-variable namespace: "RB." + 8-hex FNV-1a of               |
//| login|symbol|magic. Short enough that every key stays <= 63      |
//| chars, unique per account + symbol + magic.                      |
//+------------------------------------------------------------------+
string RB_KeyPrefix(long login, const string sym, long magic)
  {
   string src = IntegerToString(login) + "|" + sym + "|" + IntegerToString(magic);
   uchar  b[];
   int    n = StringToCharArray(src, b, 0, WHOLE_ARRAY, CP_UTF8);
   const uint prime = 16777619;
   uint   h = (uint)2166136261;
   for(int i = 0; i < n; i++)
     {
      if(b[i] == 0)
         break;
      h ^= (uint)b[i];
      h *= prime;
     }
   return "RB." + StringFormat("%08X", h);
  }

//+------------------------------------------------------------------+
//| Order metadata in terminal global variables (survive restarts).  |
//| Key: <prefix>.<order ticket>.<field>                             |
//| POSITION_IDENTIFIER equals the opening order ticket, so the same |
//| record serves the resulting position.                            |
//+------------------------------------------------------------------+
class CRBMeta
  {
private:
   string            m_prefix;
   string            Key(ulong ticket, const string field) const
     {
      return m_prefix + "." + IntegerToString((long)ticket) + "." + field;
     }
public:
   void              Init(const string prefix)             { m_prefix = prefix; }
   string            Prefix(void) const                    { return m_prefix; }
   void              Set(ulong ticket, const string f, double v) { GlobalVariableSet(Key(ticket, f), v); }
   bool              Has(ulong ticket)                     { return GlobalVariableCheck(Key(ticket, "dir")); }
   double            Get(ulong ticket, const string f)
     {
      string k = Key(ticket, f);
      if(!GlobalVariableCheck(k))
         return 0.0;
      return GlobalVariableGet(k);
     }
   void              Delete(ulong ticket)
     {
      GlobalVariablesDeleteAll(m_prefix + "." + IntegerToString((long)ticket) + ".");
      GlobalVariablesFlush();
     }
   void              Flush(void)                           { GlobalVariablesFlush(); }
   //--- every ticket with stored metadata (keys <prefix>.<digits>.dir)
   int               Tickets(ulong &out[])
     {
      ArrayResize(out, 0);
      string head = m_prefix + ".";
      int hl = StringLen(head);
      for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
        {
         string name = GlobalVariableName(i);
         int l = StringLen(name);
         if(l <= hl + 4 || StringSubstr(name, 0, hl) != head || StringSubstr(name, l - 4) != ".dir")
            continue;
         string mid = StringSubstr(name, hl, l - 4 - hl);
         bool digits = StringLen(mid) > 0;
         for(int c = 0; c < StringLen(mid) && digits; c++)
           {
            ushort ch = StringGetCharacter(mid, c);
            digits = (ch >= '0' && ch <= '9');
           }
         if(!digits)
            continue;
         ulong t = (ulong)StringToInteger(mid);
         if(t == 0)
            continue;
         int k = ArraySize(out);
         ArrayResize(out, k + 1);
         out[k] = t;
        }
      return ArraySize(out);
     }
   //--- processed-signal markers (duplicate guard)
   string            SigKey(const string signal_id) const
     {
      string k = signal_id;
      StringReplace(k, "|", ".");
      return m_prefix + ".sig." + k;
     }
   bool              Processed(const string signal_id)     { return GlobalVariableCheck(SigKey(signal_id)); }
   void              MarkProcessed(const string signal_id)
     {
      GlobalVariableSet(SigKey(signal_id), (double)TimeCurrent());
      GlobalVariablesFlush();
     }
   //--- atomic claim: only one EA instance (same account/symbol/magic) wins a signal.
   //--- The temporary variable starts at 0; SetOnCondition flips it to 1 exactly once.
   bool              Claim(const string signal_id)
     {
      string k = signal_id;
      StringReplace(k, "|", ".");
      k = m_prefix + ".clm." + k;
      if(!GlobalVariableCheck(k) && !GlobalVariableTemp(k))
         return false;
      return GlobalVariableSetOnCondition(k, 1.0, 0.0);
     }
  };

//--- is there already an order, position or historical order with this signal id?
bool RB_SignalExistsAtBroker(const string sym, long magic, const string signal_id, int history_days)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) == magic && OrderGetString(ORDER_SYMBOL) == sym &&
         OrderGetString(ORDER_COMMENT) == signal_id)
         return true;
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetString(POSITION_COMMENT) == signal_id)
         return true;
     }
   if(HistorySelect(TimeCurrent() - history_days * 86400, TimeCurrent() + 86400))
     {
      for(int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = HistoryOrderGetTicket(i);
         if(t == 0)
            continue;
         if(HistoryOrderGetInteger(t, ORDER_MAGIC) == magic &&
            HistoryOrderGetString(t, ORDER_SYMBOL) == sym &&
            HistoryOrderGetString(t, ORDER_COMMENT) == signal_id)
            return true;
        }
     }
   return false;
  }

//--- loss in account currency if a trade of `volume` goes from `from` to `to` (>= 0)
double RB_LossBetween(const string sym, ENUM_ORDER_TYPE type, double volume, double from, double to)
  {
   double p = 0.0;
   if(!OrderCalcProfit(type, sym, volume, from, to, p))
      return -1.0;
   return p < 0.0 ? -p : 0.0;
  }

//--- server time of the last 00:00 UTC (Upcomers resets the daily drawdown at 00:00 UTC).
//--- offset_sec = server time - UTC.
datetime RB_DayStart(datetime server_t, int offset_sec)
  {
   long utc = (long)server_t - offset_sec;
   long utc0 = utc - (utc % 86400);
   return (datetime)(utc0 + offset_sec);
  }

//--- slippage allowance in account currency for `volume` lots of `sym`
double RB_SlippageMoney(const string sym, double volume, double slippage_ticks)
  {
   if(!(slippage_ticks > 0.0))
      return 0.0;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(!(tv > 0.0))
      tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   return slippage_ticks * MathMax(tv, 0.0) * volume;
  }

//+------------------------------------------------------------------+
//| Account-wide risk snapshot. ALL positions and pending orders on  |
//| the account are included (any magic, any symbol) and treated as |
//| fully correlated. Every risk includes commission and the         |
//| slippage allowance (slippage_ticks x tick value per lot).        |
//+------------------------------------------------------------------+
bool RB_BuildSnapshot(long magic, double commission_rt_per_lot, double slippage_ticks, double day_start_ref,
                      int offset_sec, RBRiskSnapshot &s, string &err)
  {
   s.balance              = AccountInfoDouble(ACCOUNT_BALANCE);
   s.equity               = AccountInfoDouble(ACCOUNT_EQUITY);
   s.day_start_ref        = day_start_ref;
   s.realized_today       = 0.0;
   s.open_risk            = 0.0;
   s.open_risk_now        = 0.0;
   s.pending_risk         = 0.0;
   s.trades_today         = 0;
   s.positions            = 0;
   s.pending              = 0;
   s.unprotected_position = false;
   err = "";

   datetime day0 = RB_DayStart(TimeCurrent(), offset_sec);
   if(!HistorySelect(day0, TimeCurrent() + 60))
     {
      err = "HistorySelect failed";
      return false;
     }
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      s.realized_today += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                          HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) == magic && HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         s.trades_today++;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      string sym  = PositionGetString(POSITION_SYMBOL);
      double sl   = PositionGetDouble(POSITION_SL);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      bool   buy  = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      ENUM_ORDER_TYPE ot = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(PositionGetInteger(POSITION_MAGIC) == magic)
         s.positions++;
      if(sl <= 0.0)
        {
         s.unprotected_position = true;
         continue;
        }
      double costs = commission_rt_per_lot * vol + RB_SlippageMoney(sym, vol, slippage_ticks);
      // open_risk: loss from OPEN price to SL (exposure / total DD caps)
      double loss = RB_LossBetween(sym, ot, vol, open, sl);
      if(loss < 0.0)
        {
         err = "OrderCalcProfit failed for position " + IntegerToString((long)t);
         return false;
        }
      s.open_risk += loss + costs;
      // open_risk_now: loss from the CURRENT close price to SL (daily check against equity,
      // which already contains the floating P/L)
      MqlTick tk;
      if(!SymbolInfoTick(sym, tk) || tk.bid <= 0.0 || tk.ask <= 0.0)
        {
         err = "no quote for position " + IntegerToString((long)t);
         return false;
        }
      double now_loss = RB_LossBetween(sym, ot, vol, buy ? tk.bid : tk.ask, sl);
      if(now_loss < 0.0)
        {
         err = "OrderCalcProfit failed (current) for position " + IntegerToString((long)t);
         return false;
        }
      s.open_risk_now += now_loss + costs;
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ENUM_ORDER_TYPE ot;
      if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT)
         ot = ORDER_TYPE_BUY;
      else if(type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT)
         ot = ORDER_TYPE_SELL;
      else
         continue;
      if(OrderGetInteger(ORDER_MAGIC) == magic)
         s.pending++;
      string sym   = OrderGetString(ORDER_SYMBOL);
      double sl    = OrderGetDouble(ORDER_SL);
      double vol   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      if(sl <= 0.0)
        {
         s.unprotected_position = true;   // a pending order without SL is unbounded risk too
         continue;
        }
      double loss = RB_LossBetween(sym, ot, vol, price, sl);
      if(loss < 0.0)
        {
         err = "OrderCalcProfit failed for order " + IntegerToString((long)t);
         return false;
        }
      s.pending_risk += loss + commission_rt_per_lot * vol + RB_SlippageMoney(sym, vol, slippage_ticks);
     }
   return true;
  }

//--- realized P/L since day start, used to reconstruct the day-start balance after a restart
double RB_RealizedSince(datetime from)
  {
   double sum = 0.0;
   if(!HistorySelect(from, TimeCurrent() + 60))
      return 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      sum += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
             HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
     }
   return sum;
  }

//--- high-impact news window check (economic calendar; not available in the Strategy Tester).
//--- CalendarValueHistory returns bool; the event count is ArraySize(values). When the
//--- calendar cannot be read the check fails safe: blocked with what = "CALENDAR_UNAVAILABLE".
bool RB_NewsBlocked(const string currency, int minutes_before, int minutes_after, string &what)
  {
   what = "";
   datetime now = TimeTradeServer();
   MqlCalendarValue values[];
   ResetLastError();
   if(!CalendarValueHistory(values, now - minutes_after * 60, now + minutes_before * 60, NULL, currency))
     {
      what = "CALENDAR_UNAVAILABLE err=" + IntegerToString(GetLastError());
      return true;
     }
   int n = ArraySize(values);
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
        {
         what = ev.name + " @ " + TimeToString(values[i].time, TIME_DATE | TIME_MINUTES);
         return true;
        }
     }
   return false;
  }

#endif
