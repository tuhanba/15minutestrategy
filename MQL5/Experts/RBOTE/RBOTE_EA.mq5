//+------------------------------------------------------------------+
//| RBOTE_EA.mq5                                                     |
//| XAUUSD M15: PD Array (FVG / OB) -> Rejection Block -> 0.79 OTE    |
//| limit entry, fixed or structural stop, 6R (or 5R) target.        |
//|                                                                  |
//| Defaults are SAFE: live (real) accounts are refused unless three |
//| explicit inputs are set; the stop unit must be chosen by the     |
//| user; prop-firm limits are NOT assumed.                          |
//+------------------------------------------------------------------+
#property copyright "RBOTE"
#property version   "0.10"
#property description "M15 PD Array + Rejection Block + OTE 0.79. Demo/backtest by default."

#include <Trade/Trade.mqh>
#include <RBOTE/RejectionBlock.mqh>
#include <RBOTE/TradeMath.mqh>
#include <RBOTE/RiskGuard.mqh>
#include <RBOTE/Safety.mqh>
#include <RBOTE/MT5Bridge.mqh>
#include <RBOTE/Journal.mqh>

//--- inputs ---------------------------------------------------------
input group "Safety / mode"
input bool   InpAllowLiveTrading   = false;   // Allow REAL accounts (default: refused)
input long   InpLiveConfirmLogin   = 0;       // Real account: type the account login to confirm
input bool   InpPropRulesVerified  = false;   // Real account: prop-firm rules verified by you
input long   InpMagic              = 7915790; // Magic number

input group "PD arrays (M15)"
input bool   InpUseFVG             = true;    // Use Fair Value Gaps
input bool   InpUseOB              = true;    // Use Order Blocks
input double InpFvgMinATR          = 0.0;     // Min FVG height in ATR(14) (0 = off)
input int    InpObLookback         = 3;       // OB: bars searched before the displacement candle
input int    InpSwingN             = 2;       // OB: fractal strength of the broken swing
input int    InpZoneMaxAgeBars     = 192;     // Zone expiry in M15 bars (192 = 2 days)

input group "Rejection block"
input ENUM_RB_CLOSE_RULE InpRbCloseRule = RB_CLOSE_BODY_OUTSIDE; // Body must close outside the zone
input double InpRbMinWickRatio     = 0.5;     // Rejection wick / candle range (min)
input double InpRbMinWickATR       = 0.0;     // Rejection wick in ATR (0 = off)
input bool   InpRbRequireApproach  = true;    // Previous close must be outside the zone
input ENUM_RB_CONFIRM InpRbConfirm = RB_CONFIRM_RB_CLOSE; // Confirmation candle
input int    InpRbConfirmBars      = 3;       // NEXT_CLOSE: bars allowed for confirmation

input group "Entry / exit"
input double InpFibLevel           = 0.79;    // Fibonacci entry level on the RB range
input ENUM_RB_STOP_MODE InpStopMode = RB_STOP_FIXED; // Stop mode
input double InpStopDistance       = 10.0;    // Fixed stop distance (source: 10)
input ENUM_RB_DIST_UNIT InpStopUnit = RB_UNIT_NOT_SET; // Unit of the stop distance - MUST be chosen
input double InpStructuralBuffer   = 0.30;    // Structural stop: buffer beyond RB extreme (price)
input bool   InpRequireSlBeyondRb  = true;    // Fixed stop must be beyond the RB extreme
input double InpRR                 = 6.0;     // Target in R (6 source, 5 alternative)
input double InpMinStopSpreadMult  = 2.0;     // Stop >= mult x current spread
input double InpMaxSpreadPrice     = 0.0;     // Max spread for new orders (price, 0 = off)
input int    InpOrderExpiryBars    = 8;       // Pending order lifetime in M15 bars

input group "Risk (test values, NOT prop-firm rules)"
input double InpRiskPct            = 0.25;    // Risk per trade, % of min(balance, equity)
input double InpDailyLossPct       = 1.0;     // Personal daily loss limit, % of day-start ref
input double InpMaxOpenRiskPct     = 0.5;     // Open + pending + new risk cap, % of equity
input double InpMaxTotalDDPct      = 0.0;     // Total drawdown floor, % of initial balance (0 = off)
input double InpInitialBalance     = 0.0;     // Initial balance for total DD (0 = balance at first start)
input int    InpMaxTradesPerDay    = 3;       // Max entries per server day (0 = off)
input int    InpMaxPositions       = 1;       // Max open positions of this EA (0 = off)
input int    InpMaxPending         = 1;       // Max pending orders of this EA (0 = off)
input double InpCommissionPerLotRT = 0.0;     // Commission per lot, round turn (account currency)
input double InpSlippageTicks      = 10.0;    // Slippage allowance on the stop (ticks)
input double InpMaxLots            = 0.0;     // Hard lot cap (0 = broker max)

input group "Time / news filters"
input int    InpFridayCutoffHour   = 20;      // Friday: no new orders, cancel pending from this server hour (-1 off)
input int    InpBlockFromHour      = -1;      // Daily block window start, server hour (-1 off)
input int    InpBlockToHour        = -1;      // Daily block window end, server hour (exclusive)
input bool   InpNewsFilter         = true;    // Block new orders around high-impact news (live/demo only)
input string InpNewsCurrency       = "USD";   // Calendar currency
input int    InpNewsMinutesBefore  = 15;      // Minutes before the event
input int    InpNewsMinutesAfter   = 15;      // Minutes after the event

input group "Engine / logging"
input int    InpLookbackBars       = 600;     // Closed M15 bars scanned on every new bar
input bool   InpJournal            = true;    // Write CSV journal + trades file

//--- state ----------------------------------------------------------
CTrade        g_trade;
CRBJournal    g_log;
CRBMeta       g_meta;
RBConfig      g_cfg;
RBRiskLimits  g_lim;
RBSymbolSpec  g_spec;
bool          g_tester      = false;
bool          g_ready       = false;
bool          g_halted      = false;
datetime      g_last_bar    = 0;
datetime      g_day         = 0;
double        g_day_ref     = 0.0;
bool          g_day_blocked = false;
const ENUM_TIMEFRAMES TF    = PERIOD_M15;

//+------------------------------------------------------------------+
string DirText(int dir) { return dir == RB_DIR_BULL ? "BUY" : "SELL"; }

void BuildConfig(void)
  {
   g_cfg.Defaults();
   g_cfg.use_fvg              = InpUseFVG;
   g_cfg.use_ob               = InpUseOB;
   g_cfg.fvg_min_atr          = InpFvgMinATR;
   g_cfg.ob_lookback          = InpObLookback;
   g_cfg.swing_n              = InpSwingN;
   g_cfg.zone_max_age_bars    = InpZoneMaxAgeBars;
   g_cfg.rb_close_rule        = InpRbCloseRule;
   g_cfg.rb_min_wick_ratio    = InpRbMinWickRatio;
   g_cfg.rb_min_wick_atr      = InpRbMinWickATR;
   g_cfg.rb_require_approach  = InpRbRequireApproach;
   g_cfg.rb_confirm           = InpRbConfirm;
   g_cfg.rb_confirm_bars      = InpRbConfirmBars;
   g_cfg.fib_level            = InpFibLevel;
   g_cfg.stop_mode            = InpStopMode;
   g_cfg.stop_distance        = InpStopDistance;
   g_cfg.stop_unit            = InpStopUnit;
   g_cfg.structural_buffer    = InpStructuralBuffer;
   g_cfg.require_sl_beyond_rb = InpRequireSlBeyondRb;
   g_cfg.rr                   = InpRR;
   g_cfg.min_stop_spread_mult = InpMinStopSpreadMult;

   g_lim.Defaults();
   g_lim.risk_pct           = InpRiskPct / 100.0;
   g_lim.daily_loss_pct     = InpDailyLossPct / 100.0;
   g_lim.max_open_risk_pct  = InpMaxOpenRiskPct / 100.0;
   g_lim.max_total_dd_pct   = InpMaxTotalDDPct / 100.0;
   g_lim.max_trades_per_day = InpMaxTradesPerDay;
   g_lim.max_positions      = InpMaxPositions;
   g_lim.max_pending        = InpMaxPending;
  }

int AccountModeCode(void)
  {
   long m = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(m == ACCOUNT_TRADE_MODE_DEMO)
      return RB_ACC_DEMO;
   if(m == ACCOUNT_TRADE_MODE_CONTEST)
      return RB_ACC_CONTEST;
   return RB_ACC_REAL;
  }

//--- initial balance for the total drawdown floor (stored once per account+magic)
double InitialBalance(void)
  {
   if(InpInitialBalance > 0.0)
      return InpInitialBalance;
   string k = "RBOTE." + IntegerToString(InpMagic) + ".initial_balance";
   if(!GlobalVariableCheck(k))
      GlobalVariableSet(k, AccountInfoDouble(ACCOUNT_BALANCE));
   return GlobalVariableGet(k);
  }

//--- day rollover: reference = max(balance, equity) at day start.
//--- After a restart the day-start balance is rebuilt from today's closed deals.
void UpdateDay(void)
  {
   datetime d = RB_DayStart(TimeCurrent());
   if(d == g_day)
      return;
   string k = "RBOTE." + IntegerToString(InpMagic) + ".dayref." + IntegerToString((long)d);
   double ref;
   if(GlobalVariableCheck(k))
      ref = GlobalVariableGet(k);
   else
     {
      double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
      double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
      double bal0 = bal - RB_RealizedSince(d);
      ref = MathMax(bal0, MathMax(bal, eq));
      GlobalVariableSet(k, ref);
     }
   g_day         = d;
   g_day_ref     = ref;
   g_day_blocked = GlobalVariableCheck("RBOTE." + IntegerToString(InpMagic) + ".dayblock." + IntegerToString((long)d));
   g_log.Log("DAY_START", "", "day_start_ref=" + DoubleToString(ref, 2), g_day_blocked ? "BLOCKED_TODAY" : "");
  }

void BlockToday(const string why)
  {
   if(g_day_blocked)
      return;
   g_day_blocked = true;
   GlobalVariableSet("RBOTE." + IntegerToString(InpMagic) + ".dayblock." + IntegerToString((long)g_day), 1.0);
   g_log.Log("DAY_BLOCKED", "", why, "no new orders until next server day");
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_tester = (bool)MQLInfoInteger(MQL_TESTER);
   g_log.Init(InpJournal, InpMagic);
   g_meta.Init(InpMagic);
   BuildConfig();

   if(_Period != TF)
      g_log.Log("INFO", "", "chart period differs from M15", "EA always evaluates M15 bars");
   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      g_log.Log("WARN", "", "symbol " + _Symbol, "strategy was specified for XAUUSD");

   //--- 1. live trading gate
   int perm = RB_TradingPermission(g_tester, AccountModeCode(), InpAllowLiveTrading,
                                   InpLiveConfirmLogin, AccountInfoInteger(ACCOUNT_LOGIN), InpPropRulesVerified);
   if(perm != 0)
     {
      g_log.Log("INIT_REFUSED", "", "account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), RB_PermissionText(perm));
      return INIT_FAILED;
     }

   //--- 2. parameters that must be chosen explicitly
   if(InpStopMode == RB_STOP_FIXED && InpStopUnit == RB_UNIT_NOT_SET)
     {
      g_log.Log("INIT_REFUSED", "", "InpStopUnit not set",
                "choose PRICE / POINTS / TICKS for the 10-point stop; it is never assumed");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!(InpFibLevel > 0.0 && InpFibLevel < 1.0) || !(InpRR > 0.0) || !(InpRiskPct > 0.0) || InpRiskPct > 2.0 ||
      !(InpDailyLossPct > 0.0) || InpLookbackBars < InpZoneMaxAgeBars + 50)
     {
      g_log.Log("INIT_REFUSED", "", "invalid inputs", "check fib/rr/risk/lookback");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- 3. symbol specification
   if(!RB_ReadSymbolSpec(_Symbol, g_spec))
     {
      g_log.Log("INIT_REFUSED", "", RB_SpecText(g_spec), "BAD_SYMBOL_SPEC");
      return INIT_FAILED;
     }
   double stop_px = RB_DistanceToPrice(InpStopDistance, InpStopUnit, g_spec);
   g_log.Log("SYMBOL_SPEC", "", RB_SpecText(g_spec),
             StringFormat("stop %s %s = %s price = %s points = %s per lot",
                          DoubleToString(InpStopDistance, 2), EnumToString(InpStopUnit),
                          DoubleToString(stop_px, g_spec.digits),
                          DoubleToString(stop_px / g_spec.point, 1),
                          DoubleToString(stop_px / g_spec.tick_size * g_spec.tick_value_loss, 2)));
   if(!g_tester && InpCommissionPerLotRT <= 0.0)
      g_log.Log("WARN", "", "InpCommissionPerLotRT = 0", "lot sizing ignores commission; set the broker value");

   g_lim.initial_balance = InitialBalance();
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(0);

   UpdateDay();
   Reconcile("INIT");
   g_ready = true;
   g_log.Log("INIT_OK", "", g_tester ? "tester" : (AccountModeCode() == RB_ACC_DEMO ? "demo" : "LIVE"),
             StringFormat("rr=%.1f fib=%.2f stop_mode=%s risk=%.2f%% daily=%.2f%%",
                          InpRR, InpFibLevel, EnumToString(InpStopMode), InpRiskPct, InpDailyLossPct));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_log.Log("DEINIT", "", "reason=" + IntegerToString(reason),
             "pending orders stay at the broker with SL/TP and server-side expiry");
  }

//+------------------------------------------------------------------+
//| Restart reconciliation                                           |
//+------------------------------------------------------------------+
void Reconcile(const string when)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if(RB_ReconcileOrder(g_meta.Has(t)) == RB_REC_CANCEL)
        {
         string comment = OrderGetString(ORDER_COMMENT);
         bool ok = g_trade.OrderDelete(t);
         g_log.Log("RECONCILE_CANCEL", comment, when + " order " + IntegerToString((long)t),
                   ok ? "unknown order (no metadata) cancelled" : "cancel failed: " + IntegerToString((long)g_trade.ResultRetcode()));
        }
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      ulong id   = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      string cmt = PositionGetString(POSITION_COMMENT);
      double sl  = PositionGetDouble(POSITION_SL);
      double msl = g_meta.Get(id, "sl");
      int act = RB_ReconcilePosition(sl > 0.0, msl > 0.0);
      if(act == RB_REC_SET_SL)
        {
         bool ok = g_trade.PositionModify(t, msl, g_meta.Get(id, "tp"));
         g_log.Log("RECONCILE_SET_SL", cmt, when + " position " + IntegerToString((long)t),
                   ok ? "missing SL restored" : "modify failed: " + IntegerToString((long)g_trade.ResultRetcode()));
        }
      else if(act == RB_REC_CLOSE)
        {
         bool ok = g_trade.PositionClose(t);
         g_log.Log("RECONCILE_CLOSE", cmt, when + " position " + IntegerToString((long)t),
                   ok ? "unprotected position without metadata closed" : "close failed: " + IntegerToString((long)g_trade.ResultRetcode()));
        }
     }
  }

//+------------------------------------------------------------------+
void CancelOrder(ulong t, const string reason)
  {
   string id = "";
   if(OrderSelect(t))
      id = OrderGetString(ORDER_COMMENT);
   bool ok = g_trade.OrderDelete(t);
   g_log.Log(ok ? "ORDER_CANCELLED" : "ORDER_CANCEL_FAILED", id, "ticket " + IntegerToString((long)t),
             ok ? reason : reason + " retcode=" + IntegerToString((long)g_trade.ResultRetcode()));
   if(ok)
      g_meta.Delete(t);
  }

void CancelAllPending(const string reason)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      CancelOrder(t, reason);
     }
  }

//--- tick-level: target reached before the limit filled
void ManagePendingOnTick(double bid, double ask)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      int dir = (int)g_meta.Get(t, "dir");
      if(dir == 0)
         continue;
      if(RB_PendingTpReachedOnTick(dir, OrderGetDouble(ORDER_TP), bid, ask))
         CancelOrder(t, RB_CancelText(RB_CANCEL_TP_REACHED));
     }
  }

//--- bar-level: every closed bar since the signal is checked (restart-safe)
void ManagePendingOnBar(const MqlRates &rates[], int n)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      int dir = (int)g_meta.Get(t, "dir");
      if(dir == 0)
         continue;
      datetime sig_bar = (datetime)g_meta.Get(t, "bar");
      double tp  = OrderGetDouble(ORDER_TP);
      double rbl = g_meta.Get(t, "rbl"), rbh = g_meta.Get(t, "rbh");
      double zt  = g_meta.Get(t, "zt"),  zb  = g_meta.Get(t, "zb");
      int alive = 0;
      int code = RB_CANCEL_NONE;
      for(int k = 0; k < n && code == RB_CANCEL_NONE; k++)
        {
         if(rates[k].time <= sig_bar)
            continue;
         alive++;
         code = RB_PendingCancelOnBar(dir, tp, rbl, rbh, zt, zb, rates[k].high, rates[k].low, rates[k].close,
                                      alive, InpOrderExpiryBars);
        }
      if(code != RB_CANCEL_NONE)
         CancelOrder(t, RB_CancelText(code));
     }
  }

//+------------------------------------------------------------------+
bool TimeBlocked(string &why)
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(InpFridayCutoffHour >= 0 && ((dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour) || dt.day_of_week == 6 || dt.day_of_week == 0))
     {
      why = "FRIDAY_CUTOFF";
      return true;
     }
   if(InpBlockFromHour >= 0 && InpBlockToHour >= 0)
     {
      bool in = (InpBlockFromHour <= InpBlockToHour) ? (dt.hour >= InpBlockFromHour && dt.hour < InpBlockToHour)
                                                    : (dt.hour >= InpBlockFromHour || dt.hour < InpBlockToHour);
      if(in)
        {
         why = "BLOCKED_HOURS";
         return true;
        }
     }
   if(InpNewsFilter && !g_tester)
     {
      string ev;
      if(RB_NewsBlocked(InpNewsCurrency, InpNewsMinutesBefore, InpNewsMinutesAfter, ev))
        {
         why = "NEWS " + ev;
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Signal -> checks -> limit order                                  |
//+------------------------------------------------------------------+
void ProcessSignal(const RBSignal &sig)
  {
   string id = RB_SignalId(sig.dir, sig.rb_time);
   string ctx = StringFormat("%s RB[%s..%s] zone=%s[%s..%s] hits=%d", DirText(sig.dir),
                             DoubleToString(sig.rb_low, _Digits), DoubleToString(sig.rb_high, _Digits),
                             sig.zone_type == RB_ZONE_FVG ? "FVG" : "OB",
                             DoubleToString(sig.zone_bottom, _Digits), DoubleToString(sig.zone_top, _Digits), sig.zones_hit);

   //--- duplicate guard (global variable + broker comments)
   if(g_meta.Processed(id) || RB_SignalExistsAtBroker(_Symbol, InpMagic, id, 7))
     {
      g_log.Log("SIGNAL_DUPLICATE", id, ctx, "already processed");
      return;
     }
   g_meta.MarkProcessed(id);   // one attempt per signal, also when rejected below
   g_log.Log("SIGNAL", id, ctx, "RB confirmed");

   string why = "";
   if(g_day_blocked)
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, "DAILY_BLOCK");
      return;
     }
   if(TimeBlocked(why))
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, why);
      return;
     }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, "NO_QUOTE");
      return;
     }
   double spread = tick.ask - tick.bid;
   if(InpMaxSpreadPrice > 0.0 && spread > InpMaxSpreadPrice)
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, "SPREAD " + DoubleToString(spread, _Digits));
      return;
     }
   //--- refresh the specification (stops level can change)
   if(!RB_ReadSymbolSpec(_Symbol, g_spec))
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, "BAD_SYMBOL_SPEC " + RB_SpecText(g_spec));
      return;
     }

   RBPlan plan;
   int r = RB_BuildPlan(sig, g_cfg, g_spec, plan);
   if(r != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, RB_ReasonText(r));
      return;
     }
   string pctx = StringFormat("entry=%s sl=%s tp=%s risk_dist=%s (%s points) rr=%.1f fib=%.2f",
                              DoubleToString(plan.entry, _Digits), DoubleToString(plan.sl, _Digits),
                              DoubleToString(plan.tp, _Digits), DoubleToString(plan.risk_dist, _Digits),
                              DoubleToString(plan.risk_dist / g_spec.point, 1), InpRR, plan.fib_level);
   r = RB_CheckMarket(plan, g_cfg, g_spec, tick.bid, tick.ask);
   if(r != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + StringFormat(" bid=%s ask=%s", DoubleToString(tick.bid, _Digits),
                DoubleToString(tick.ask, _Digits)), RB_ReasonText(r));
      return;
     }

   //--- lot size: risk budget / (price loss per lot + commission + slippage)
   double bal = AccountInfoDouble(ACCOUNT_BALANCE), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_money = RB_RiskMoney(g_lim, bal, eq);
   ENUM_ORDER_TYPE mtype = plan.dir == RB_DIR_BULL ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double tick_loss = RB_LossPerLot(plan.risk_dist, g_spec, InpCommissionPerLotRT, InpSlippageTicks);
   double calc_loss = RB_LossBetween(_Symbol, mtype, 1.0, plan.entry, plan.sl);
   double loss_per_lot = tick_loss;
   if(calc_loss > 0.0)   // take the more conservative of terminal and tick math
      loss_per_lot = MathMax(tick_loss, calc_loss + InpCommissionPerLotRT + InpSlippageTicks * g_spec.tick_value_loss);
   double lots = 0.0;
   r = RB_CalcLots(risk_money, loss_per_lot, g_spec, InpMaxLots, lots);
   if(r != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + StringFormat(" risk_money=%.2f loss_per_lot=%.2f", risk_money, loss_per_lot),
                RB_ReasonText(r));
      return;
     }
   lots = NormalizeDouble(lots, 8);
   double trade_risk = lots * loss_per_lot;

   double margin = 0.0;
   if(!OrderCalcMargin(mtype, _Symbol, lots, plan.entry, margin) || margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + StringFormat(" lots=%.2f margin=%.2f", lots, margin), "INSUFFICIENT_MARGIN");
      return;
     }

   //--- account-wide guard
   RBRiskSnapshot snap;
   string err;
   if(!RB_BuildSnapshot(InpMagic, InpCommissionPerLotRT, g_day_ref, snap, err))
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx, "SNAPSHOT_FAILED " + err);
      return;
     }
   int g = RB_CheckNewOrder(g_lim, snap, trade_risk);
   string gctx = StringFormat(" lots=%.2f risk=%.2f realized=%.2f open=%.2f pending=%.2f day_ref=%.2f",
                              lots, trade_risk, snap.realized_today, snap.open_risk, snap.pending_risk, snap.day_start_ref);
   if(g != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + gctx, RB_GuardText(g));
      return;
     }

   //--- send. Server-side expiry when the symbol supports it.
   ENUM_ORDER_TYPE_TIME tt = ORDER_TIME_GTC;
   datetime exp = 0;
   int exp_modes = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((exp_modes & SYMBOL_EXPIRATION_SPECIFIED) != 0 && InpOrderExpiryBars > 0)
     {
      tt  = ORDER_TIME_SPECIFIED;
      exp = sig.confirm_time + PeriodSeconds(TF) * (InpOrderExpiryBars + 1);
     }
   bool sent = (plan.dir == RB_DIR_BULL)
               ? g_trade.BuyLimit(lots, plan.entry, _Symbol, plan.sl, plan.tp, tt, exp, id)
               : g_trade.SellLimit(lots, plan.entry, _Symbol, plan.sl, plan.tp, tt, exp, id);
   uint rc = g_trade.ResultRetcode();
   ulong ticket = g_trade.ResultOrder();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED) || ticket == 0)
     {
      g_log.Log("ORDER_REJECTED", id, pctx + gctx, "retcode=" + IntegerToString((long)rc) + " " + g_trade.ResultRetcodeDescription());
      return;
     }
   g_meta.Set(ticket, "dir", plan.dir);
   g_meta.Set(ticket, "entry", plan.entry);
   g_meta.Set(ticket, "sl", plan.sl);
   g_meta.Set(ticket, "tp", plan.tp);
   g_meta.Set(ticket, "rbl", sig.rb_low);
   g_meta.Set(ticket, "rbh", sig.rb_high);
   g_meta.Set(ticket, "zt", sig.zone_top);
   g_meta.Set(ticket, "zb", sig.zone_bottom);
   g_meta.Set(ticket, "bar", (double)sig.confirm_time);
   g_meta.Set(ticket, "rbt", (double)sig.rb_time);
   g_meta.Set(ticket, "risk", trade_risk);
   g_meta.Set(ticket, "atr", sig.atr);
   g_meta.Set(ticket, "zty", sig.zone_type);
   // order SENT is logged here; the FILL is logged separately from OnTradeTransaction
   g_log.Log("ORDER_SENT", id, pctx + gctx + " ticket=" + IntegerToString((long)ticket) +
             (tt == ORDER_TIME_SPECIFIED ? " expires=" + TimeToString(exp) : " GTC (EA-side expiry)"), "OK");
  }

//+------------------------------------------------------------------+
void OnNewBar(void)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int n = CopyRates(_Symbol, TF, 1, InpLookbackBars, rates);   // start=1: closed bars only
   if(n < InpZoneMaxAgeBars + 20)
     {
      g_log.Log("DATA_INSUFFICIENT", "", "bars=" + IntegerToString(n), "no evaluation");
      return;
     }
   bool connected = g_tester || (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   bool fresh = RB_DataFresh(connected, rates[n - 1].time, TimeCurrent(), PeriodSeconds(TF), 2);

   //--- pending order maintenance always runs on closed bars
   ManagePendingOnBar(rates, n);
   Reconcile("BAR");

   //--- day limit: existing exposure already at the limit -> cancel pending, block the day
   RBRiskSnapshot snap;
   string err;
   if(RB_BuildSnapshot(InpMagic, InpCommissionPerLotRT, g_day_ref, snap, err))
     {
      double day_pnl = snap.realized_today + (snap.equity - snap.balance);
      if(RB_DailyLimitBreached(g_lim, snap, day_pnl))
        {
         CancelAllPending("DAILY_LOSS_LIMIT");
         BlockToday(StringFormat("day_pnl=%.2f limit=%.2f", day_pnl, g_lim.daily_loss_pct * g_day_ref));
        }
     }
   string why;
   if(InpFridayCutoffHour >= 0 && TimeBlocked(why) && StringFind(why, "FRIDAY") == 0)
      CancelAllPending("FRIDAY_CUTOFF");

   if(!fresh)
     {
      g_log.Log("DATA_STALE", "", "last closed bar " + TimeToString(rates[n - 1].time), "no new signals this bar");
      return;
     }

   CRBSeries s;
   RBBar b;
   for(int i = 0; i < n; i++)
     {
      b.time  = rates[i].time;
      b.open  = rates[i].open;
      b.high  = rates[i].high;
      b.low   = rates[i].low;
      b.close = rates[i].close;
      s.Add(b);
     }
   CRBVec<RBZone>   zones;
   CRBVec<RBSignal> sigs;
   RB_Scan(s, g_cfg, zones, sigs);

   //--- act only on a signal confirmed by the bar that just closed
   RBSignal sig;
   for(int i = 0; i < sigs.Size(); i++)
     {
      sigs.Get(i, sig);
      if(sig.confirm_idx == n - 1)
         ProcessSignal(sig);
     }
  }

void OnTick(void)
  {
   if(!g_ready)
      return;
   if(!g_tester && !(bool)TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      if(!g_halted)
         g_log.Log("HALTED", "", "terminal disconnected", "no actions until reconnect");
      g_halted = true;
      return;
     }
   if(g_halted)
     {
      g_halted = false;
      g_log.Log("RESUMED", "", "terminal connected", "reconciling");
      Reconcile("RECONNECT");
     }
   UpdateDay();

   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick))
      ManagePendingOnTick(tick.bid, tick.ask);

   datetime t = iTime(_Symbol, TF, 0);
   if(t == 0 || t == g_last_bar)
      return;
   g_last_bar = t;
   OnNewBar();
  }

//+------------------------------------------------------------------+
//| Fills and closes, from broker deals                              |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_HISTORY_ADD &&
      (trans.order_state == ORDER_STATE_CANCELED || trans.order_state == ORDER_STATE_EXPIRED ||
       trans.order_state == ORDER_STATE_REJECTED) && g_meta.Has(trans.order))
     {
      g_log.Log(trans.order_state == ORDER_STATE_EXPIRED ? "ORDER_EXPIRED" : "ORDER_CLOSED_UNFILLED",
                "", "ticket " + IntegerToString((long)trans.order), EnumToString(trans.order_state));
      g_meta.Delete(trans.order);
      return;
     }
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic || HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   long entry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ulong pos   = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double px   = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   string id   = RB_SignalId((int)g_meta.Get(pos, "dir"), (datetime)g_meta.Get(pos, "rbt"));
   if(entry == DEAL_ENTRY_IN)
     {
      double planned = g_meta.Get(pos, "entry");
      g_log.Log("FILLED", id, StringFormat("position %I64u price=%s planned=%s slippage=%s vol=%.2f", pos,
                DoubleToString(px, _Digits), DoubleToString(planned, _Digits),
                DoubleToString(px - planned, _Digits), HistoryDealGetDouble(trans.deal, DEAL_VOLUME)), "OK");
      return;
     }
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   if(PositionSelectByTicket(pos))
      return;   // partially closed, wait for the final deal

   //--- position fully closed: net result from broker deals of this position
   if(!HistorySelectByPosition(pos))
      return;
   double net = 0.0, fill = 0.0, vol = 0.0;
   datetime t_open = 0, t_close = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
             HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
        {
         fill   = HistoryDealGetDouble(d, DEAL_PRICE);
         vol   += HistoryDealGetDouble(d, DEAL_VOLUME);
         t_open = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
        }
      else
         t_close = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
     }
   double risk = g_meta.Get(pos, "risk");
   double rr   = risk > 0.0 ? net / risk : 0.0;
   g_log.Log("CLOSED", id, StringFormat("position %I64u exit=%s net=%.2f risk=%.2f R=%.3f", pos,
             DoubleToString(px, _Digits), net, risk, rr), "broker deals");
   g_log.Trade(t_open, t_close, (int)g_meta.Get(pos, "dir"), g_meta.Get(pos, "entry"), fill,
               g_meta.Get(pos, "sl"), g_meta.Get(pos, "tp"), vol, risk, net, rr, id,
               g_meta.Get(pos, "atr"), (int)g_meta.Get(pos, "zty"), InpRR, InpStopMode, px);
   g_meta.Delete(pos);
  }

//+------------------------------------------------------------------+
//| Strategy Tester summary (net R statistics from broker deals)     |
//+------------------------------------------------------------------+
double OnTester(void)
  {
   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double net    = TesterStatistics(STAT_PROFIT);
   PrintFormat("[RBOTE] tester: trades=%.0f net=%.2f PF=%.2f maxEquityDD=%.2f%% rr=%.1f stop_mode=%s; trades file: Common\\Files\\%s",
               trades, net, pf, dd, InpRR, EnumToString(InpStopMode), g_log.TradesFile());
   // custom criterion: net profit per trade, 0 when the sample is too small to mean anything
   if(trades < 30)
      return 0.0;
   return net / trades;
  }
//+------------------------------------------------------------------+
