//+------------------------------------------------------------------+
//| Safety.mqh - pure decision functions for live gating, data       |
//| freshness, pending-order invalidation and restart reconciliation |
//+------------------------------------------------------------------+
#ifndef RBOTE_SAFETY_MQH
#define RBOTE_SAFETY_MQH

#include "Types.mqh"

#define RB_ACC_DEMO    0
#define RB_ACC_CONTEST 1
#define RB_ACC_REAL    2

//--- 0 = trading allowed; otherwise reason code
//--- Real accounts need ALL of: allow_live, confirm_login == login, prop rules verified.
int RB_TradingPermission(bool is_tester, int account_mode, bool allow_live,
                         long confirm_login, long login, bool prop_verified)
  {
   if(is_tester)
      return 0;
   if(account_mode == RB_ACC_DEMO)
      return 0;
   if(account_mode == RB_ACC_CONTEST)
      return 1;              // treat like real: refuse
   if(!allow_live)
      return 2;
   if(confirm_login <= 0 || confirm_login != login)
      return 3;
   if(!prop_verified)
      return 4;
   return 0;
  }

string RB_PermissionText(int code)
  {
   switch(code)
     {
      case 0: return "ALLOWED";
      case 1: return "CONTEST_ACCOUNT_REFUSED";
      case 2: return "LIVE_DISABLED_BY_DEFAULT";
      case 3: return "LIVE_CONFIRM_LOGIN_MISMATCH";
      case 4: return "PROP_RULES_NOT_VERIFIED";
     }
   return "UNKNOWN";
  }

//--- data is fresh when connected and the newest closed bar is the previous period
//--- (allowing max_lag_bars missing bars, e.g. weekend gaps must be handled by caller)
bool RB_DataFresh(bool connected, datetime last_closed_bar_open, datetime now,
                  int period_sec, int max_lag_bars)
  {
   if(!connected || period_sec <= 0)
      return false;
   if(last_closed_bar_open <= 0 || now <= 0)
      return false;
   datetime expected_close = last_closed_bar_open + period_sec;
   return (now - expected_close) < (datetime)(max_lag_bars * period_sec);
  }

#define RB_CANCEL_NONE        0
#define RB_CANCEL_EXPIRED     1
#define RB_CANCEL_TP_REACHED  2
#define RB_CANCEL_STRUCTURE   3
#define RB_CANCEL_ZONE        4

string RB_CancelText(int code)
  {
   switch(code)
     {
      case 0: return "KEEP";
      case 1: return "EXPIRED";
      case 2: return "TARGET_REACHED_BEFORE_FILL";
      case 3: return "RB_STRUCTURE_BROKEN";
      case 4: return "PD_ARRAY_INVALIDATED";
     }
   return "UNKNOWN";
  }

//--- Evaluate a pending limit order on a freshly CLOSED bar.
//--- high/low/close = that bar, bars_alive = closed bars since placement.
int RB_PendingCancelOnBar(int dir, double tp, double rb_low, double rb_high,
                          double zone_top, double zone_bottom,
                          double high, double low, double close,
                          int bars_alive, int expiry_bars)
  {
   if(dir == RB_DIR_BULL)
     {
      if(high >= tp)            return RB_CANCEL_TP_REACHED;
      if(close < rb_low)        return RB_CANCEL_STRUCTURE;
      if(close < zone_bottom)   return RB_CANCEL_ZONE;
     }
   else
     {
      if(low <= tp)             return RB_CANCEL_TP_REACHED;
      if(close > rb_high)       return RB_CANCEL_STRUCTURE;
      if(close > zone_top)      return RB_CANCEL_ZONE;
     }
   if(expiry_bars > 0 && bars_alive >= expiry_bars)
      return RB_CANCEL_EXPIRED;
   return RB_CANCEL_NONE;
  }

//--- Tick-level check: target reached before the limit filled.
bool RB_PendingTpReachedOnTick(int dir, double tp, double bid, double ask)
  {
   if(dir == RB_DIR_BULL)
      return bid >= tp;
   return ask <= tp;
  }

#define RB_REC_KEEP       0
#define RB_REC_CANCEL     1  // pending order without stored metadata -> unknown origin
#define RB_REC_SET_SL     2  // position without SL, stored SL available
#define RB_REC_CLOSE      3  // position without SL and no stored SL

int RB_ReconcileOrder(bool has_meta)
  {
   return has_meta ? RB_REC_KEEP : RB_REC_CANCEL;
  }

int RB_ReconcilePosition(bool has_sl, bool has_meta_sl)
  {
   if(has_sl)
      return RB_REC_KEEP;
   return has_meta_sl ? RB_REC_SET_SL : RB_REC_CLOSE;
  }

//--- Stop-loss may only move in the position's favour (never widened).
bool RB_SlChangeAllowed(int dir, double old_sl, double new_sl)
  {
   if(old_sl <= 0.0)
      return true;          // adding a missing SL is always allowed
   if(dir == RB_DIR_BULL)
      return new_sl >= old_sl;
   return new_sl <= old_sl;
  }

//--- Signal id used in the order comment (<= 31 chars): RBOTE|B|<rb_time>
string RB_SignalId(int dir, datetime rb_time)
  {
   return (string)"RBOTE|" + (dir == RB_DIR_BULL ? "B" : "S") + "|" + IntegerToString((long)rb_time);
  }

#endif
