//+------------------------------------------------------------------+
//| RBOTE_EA.mq5                                                     |
//| XAUUSD M15: PD Array (FVG / OB) -> Rejection Block -> 0.79 OTE    |
//| limit entry, fixed or structural stop, 6R (or 5R) target.        |
//|                                                                  |
//| Defaults are SAFE: outside the tester every account (also demo / |
//| prop evaluation) needs InpLiveConfirmLogin = its login; real     |
//| accounts additionally need two more explicit inputs; the stop    |
//| unit must be chosen; only hedging accounts are supported.        |
//+------------------------------------------------------------------+
#property copyright "RBOTE"
#property version   "1.00"
#property description "M15 PD Array + Rejection Block + OTE 0.79. Demo/backtest by default."

#include <Trade/Trade.mqh>
#include <RBOTE/RejectionBlock.mqh>
#include <RBOTE/TradeMath.mqh>
#include <RBOTE/RiskGuard.mqh>
#include <RBOTE/Safety.mqh>
#include <RBOTE/MT5Bridge.mqh>
#include <RBOTE/Journal.mqh>
#include <RBOTE/Regime.mqh>
#include <RBOTE/Adaptive.mqh>

//--- inputs ---------------------------------------------------------
input group "Safety / mode"
input bool   InpAllowLiveTrading   = false;   // Allow REAL accounts (default: refused)
input long   InpLiveConfirmLogin   = 0;       // REQUIRED on every non-tester account (demo/prop too): its login
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
input double InpDailyLossPct       = 2.0;     // Personal daily loss limit, % (base below; Ash Turbo firm: 3% of initial)
input bool   InpDailyOnInitial     = true;    // Daily limit = % of INITIAL balance (Ash Turbo rule); false = of day-start ref
input double InpMaxOpenRiskPct     = 0.5;     // Open + pending + new risk cap, % of equity
input double InpMaxTotalDDPct      = 4.0;     // Personal total drawdown, % of initial balance (Ash firm: 6%)
input bool   InpTrailingDD         = true;    // Floor follows the equity peak, locks at initial (Ash rule)
input double InpInitialBalance     = 0.0;     // Initial balance for total DD (0 = balance at first start)
input int    InpMaxTradesPerDay    = 3;       // Max entries per UTC day (00:00 UTC reset, 0 = off)
input int    InpMaxPositions       = 1;       // Max open positions of this EA (0 = off)
input int    InpMaxPending         = 1;       // Max pending orders of this EA (0 = off)
input double InpCommissionPerLotRT = 0.0;     // Commission per lot, round turn (account currency)
input double InpSlippageTicks      = 10.0;    // Slippage allowance on the stop (ticks)
input double InpMaxLots            = 50.0;    // Hard lot cap (Upcomers: 50 lots)

input group "Challenge (Upcomers Ash Turbo)"
input double   InpProfitTargetPct  = 0.0;     // Stop opening trades once closed balance is +X% (0 = off; Ash Turbo: 2)
input int      InpMaxTradingDays   = 0;       // Max days with a closed trade (0 = off; Ash Turbo: 7)
input int      InpChallengeDays    = 0;       // Calendar-day limit from the start (0 = off; Ash Turbo: 30)
input datetime InpChallengeStart   = 0;       // Challenge start (server time, 0 = first EA start)

input group "Time / news filters"
input int    InpServerUtcOffset    = -99;     // Server time - UTC, hours (-99 = auto; tester: 2 winter / 3 US DST; custom UTC data: 0)
input int    InpFridayCutoffHour   = 20;      // Friday: no new orders, cancel pending from this UTC hour (-1 off)
input int    InpBlockFromHour      = -1;      // Daily block window start, UTC hour (-1 off)
input int    InpBlockToHour        = -1;      // Daily block window end, UTC hour (exclusive)
input int    InpInactivityWarnDays = 25;      // Warn when no trade closed for N days (Upcomers fails at 35)
input bool   InpNewsFilter         = true;    // Block new orders around high-impact news (live/demo only)
input string InpNewsCurrency       = "USD";   // Calendar currency
input int    InpNewsMinutesBefore  = 15;      // Minutes before the event
input int    InpNewsMinutesAfter   = 15;      // Minutes after the event

input group "Volatility / range regime (ASSUMPTIONS - validate per regime)"
input bool   InpRegimeEnabled      = true;    // Classify volatility/range and apply the policy below
input int    InpRegimeAtrLookback  = 960;     // ATR baseline bars (960 = ~10 trading days)
input double InpVolLowThr          = 0.70;    // LOW volatility: ATR / baseline <=
input double InpVolHighThr         = 1.50;    // HIGH volatility: ATR / baseline >=
input double InpVolExtremeThr      = 2.50;    // EXTREME volatility: ATR / baseline >=
input int    InpRangeErPeriod      = 32;      // Efficiency-ratio bars (32 = 8 hours)
input double InpRangeEr            = 0.20;    // RANGE (sideways): efficiency ratio <=
input bool   InpTradeHighVol       = true;    // HIGH volatility: trade?
input double InpRiskMultHighVol    = 0.5;     // HIGH volatility: risk multiplier
input double InpRRHighVol          = 0.0;     // HIGH volatility: RR override (0 = keep)
input bool   InpTradeExtremeVol    = false;   // EXTREME volatility: trade?
input bool   InpTradeLowVol        = true;    // LOW volatility: trade?
input double InpRiskMultLowVol     = 0.5;     // LOW volatility: risk multiplier
input double InpRRLowVol           = 0.0;     // LOW volatility: RR override (0 = keep)
input bool   InpTradeRange         = true;    // RANGE market: trade?
input double InpRiskMultRange      = 0.5;     // RANGE market: risk multiplier
input double InpRRRange            = 0.0;     // RANGE market: RR override (0 = keep)

input group "Adaptive risk (ASSUMPTIONS - bounded, profit-funded)"
input bool   InpScaleEnabled       = false;   // Raise risk from realized profit (off for the challenge, D-015)
input double InpMaxRiskPct         = 0.5;     // Absolute cap per trade, % (all multipliers included)
input double InpProfitSharePct     = 2.0;     // % of realized profit added as extra risk per trade
input double InpBrakeDDPct         = 2.0;     // Back to base risk when balance is this % below its peak
input int    InpLossReset          = 3;       // Back to base risk after N consecutive losses (0 = off)
input bool   InpEdgeEnabled        = false;   // Weight risk by the track record of similar setups (off, D-021)
input int    InpEdgeMinTrades      = 40;      // Closed trades before edge weighting starts
input double InpEdgePrior          = 20.0;    // Shrinkage (pseudo-trades at 0R per bucket)
input double InpEdgeGain           = 0.15;    // Multiplier change per 1R of shrunk average
input double InpEdgeMinMult        = 0.5;     // Edge multiplier floor
input double InpEdgeMaxMult        = 1.5;     // Edge multiplier ceiling

input group "Engine / logging"
input int    InpLookbackBars       = 1200;    // Closed M15 bars scanned on every new bar
input bool   InpJournal            = true;    // Write CSV journal + trades file

//--- state ----------------------------------------------------------
CTrade        g_trade;
CRBJournal    g_log;
CRBMeta       g_meta;
RBConfig      g_cfg;
RBRiskLimits  g_lim;
RBRegimeCfg   g_reg;
RBScaleCfg    g_scale;
RBEdgeCfg     g_edge;
CRBEdgeStats  g_stats;
RBSymbolSpec  g_spec;
bool          g_tester      = false;
bool          g_ready       = false;
bool          g_halted      = false;
datetime      g_last_bar    = 0;
datetime      g_day         = 0;
double        g_day_ref     = 0.0;
bool          g_day_blocked = false;
bool          g_wait_account = false;   // init deferred: account not known / not connected yet
string        g_prefix      = "";       // global-variable namespace (login|symbol|magic hash)
ulong         g_news_ms     = 0;        // last news check for pending orders (GetTickCount64)
const ENUM_TIMEFRAMES TF    = PERIOD_M15;

//+------------------------------------------------------------------+
string DirText(int dir) { return dir == RB_DIR_BULL ? "BUY" : "SELL"; }

//--- n-th Sunday (n >= 1) of a month, 00:00
datetime NthSunday(int year, int mon, int n)
  {
   MqlDateTime d;
   ZeroMemory(d);
   d.year = year;
   d.mon  = mon;
   d.day  = 1;
   datetime first = StructToTime(d);
   MqlDateTime f;
   TimeToStruct(first, f);
   int day = 1 + (7 - f.day_of_week) % 7 + 7 * (n - 1);
   return first + (day - 1) * 86400;
  }

//--- US daylight saving time: second Sunday of March .. first Sunday of November (date resolution)
bool UsDstActive(datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return t >= NthSunday(d.year, 3, 2) && t < NthSunday(d.year, 11, 1);
  }

//--- server time minus UTC, in seconds, at server time `at` (0 = now). Day boundaries, sessions
//--- and the Friday cutoff are UTC. In the Strategy Tester TimeGMT() equals server time, so the
//--- offset comes from the input or, with -99, from the usual "New York close" broker clock:
//--- UTC+2 in winter, UTC+3 while the US is on daylight saving time. Custom symbols built from
//--- UTC data (backtest/ pipeline) must set InpServerUtcOffset = 0.
int ServerOffsetSec(datetime at = 0)
  {
   if(InpServerUtcOffset != -99)
      return InpServerUtcOffset * 3600;
   if(g_tester)
     {
      static long cache_day = -1;
      static int  cache_off = 2 * 3600;
      datetime t = at > 0 ? at : TimeCurrent();
      long day = (long)t / 86400;
      if(day != cache_day)
        {
         cache_day = day;
         cache_off = UsDstActive(t) ? 3 * 3600 : 2 * 3600;
        }
      return cache_off;
     }
   long diff = (long)TimeTradeServer() - (long)TimeGMT();
   return (int)(MathRound(diff / 900.0) * 900);
  }

datetime ServerToUtc(datetime t) { return (datetime)((long)t - ServerOffsetSec(t)); }

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

   g_reg.Defaults();
   g_reg.enabled         = InpRegimeEnabled;
   g_reg.atr_lookback    = InpRegimeAtrLookback;
   g_reg.low_thr         = InpVolLowThr;
   g_reg.high_thr        = InpVolHighThr;
   g_reg.extreme_thr     = InpVolExtremeThr;
   g_reg.er_period       = InpRangeErPeriod;
   g_reg.range_er        = InpRangeEr;
   g_reg.trade_high      = InpTradeHighVol;
   g_reg.risk_mult_high  = InpRiskMultHighVol;
   g_reg.rr_high         = InpRRHighVol;
   g_reg.trade_extreme   = InpTradeExtremeVol;
   g_reg.trade_low       = InpTradeLowVol;
   g_reg.risk_mult_low   = InpRiskMultLowVol;
   g_reg.rr_low          = InpRRLowVol;
   g_reg.trade_range     = InpTradeRange;
   g_reg.risk_mult_range = InpRiskMultRange;
   g_reg.rr_range        = InpRRRange;

   g_scale.Defaults();
   g_scale.enabled      = InpScaleEnabled;
   g_scale.base_pct     = InpRiskPct / 100.0;
   g_scale.max_pct      = InpMaxRiskPct / 100.0;
   g_scale.profit_share = InpProfitSharePct / 100.0;
   g_scale.brake_dd_pct = InpBrakeDDPct / 100.0;
   g_scale.loss_reset   = InpLossReset;

   g_edge.Defaults();
   g_edge.enabled   = InpEdgeEnabled;
   g_edge.min_total = InpEdgeMinTrades;
   g_edge.prior     = InpEdgePrior;
   g_edge.gain      = InpEdgeGain;
   g_edge.min_mult  = InpEdgeMinMult;
   g_edge.max_mult  = InpEdgeMaxMult;

   g_lim.Defaults();
   g_lim.risk_pct           = InpRiskPct / 100.0;
   g_lim.daily_loss_pct     = InpDailyLossPct / 100.0;
   g_lim.daily_on_initial   = InpDailyOnInitial;
   g_lim.max_open_risk_pct  = InpMaxOpenRiskPct / 100.0;
   g_lim.max_total_dd_pct   = InpMaxTotalDDPct / 100.0;
   g_lim.trailing_dd        = InpTrailingDD;
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

//--- account gate, evaluated at init and again right before every order
int TradingPermission(void)
  {
   bool connected = g_tester || (bool)TerminalInfoInteger(TERMINAL_CONNECTED);
   return RB_TradingPermission(g_tester, AccountModeCode(), InpAllowLiveTrading, InpLiveConfirmLogin,
                               AccountInfoInteger(ACCOUNT_LOGIN), InpPropRulesVerified, connected);
  }

//--- is a position with POSITION_IDENTIFIER == id open? (partial fills keep the order's metadata)
bool PositionExistsById(ulong id)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER) == id)
         return true;
     }
   return false;
  }

//--- is an order with this ticket still pending at the broker?
bool OrderPending(ulong ticket)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) == ticket)
         return true;
   return false;
  }

int OwnPendingCount(void)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t != 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic && OrderGetString(ORDER_SYMBOL) == _Symbol)
         n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| EA state in global variables (survives restarts). Every key is   |
//| <g_prefix>.<name>, g_prefix = "RB." + FNV-1a(login|symbol|magic) |
//+------------------------------------------------------------------+
string GvKey(const string name) { return g_prefix + "." + name; }

double GvGet(const string name, double def)
  {
   string k = GvKey(name);
   return GlobalVariableCheck(k) ? GlobalVariableGet(k) : def;
  }

void GvSet(const string name, double v) { GlobalVariableSet(GvKey(name), v); }

//--- initial balance for the total drawdown floor (stored once per account+symbol+magic)
double InitialBalance(void)
  {
   if(InpInitialBalance > 0.0)
      return InpInitialBalance;
   string k = GvKey("initial_balance");
   if(!GlobalVariableCheck(k))
     {
      GlobalVariableSet(k, AccountInfoDouble(ACCOUNT_BALANCE));
      GlobalVariablesFlush();
     }
   return GlobalVariableGet(k);
  }

//--- day rollover: reference = max(balance, equity) at day start.
//--- After a restart the day-start balance is rebuilt from today's closed deals.
void UpdateDay(void)
  {
   datetime d = RB_DayStart(TimeCurrent(), ServerOffsetSec());
   if(d == g_day)
      return;
   string k = GvKey("dayref." + IntegerToString((long)d));
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
      GlobalVariablesFlush();
     }
   g_day         = d;
   g_day_ref     = ref;
   g_day_blocked = GlobalVariableCheck(GvKey("dayblock." + IntegerToString((long)d)));
   g_log.Log("DAY_START", "", "day_start_ref=" + DoubleToString(ref, 2), g_day_blocked ? "BLOCKED_TODAY" : "");
  }

void BlockToday(const string why)
  {
   if(g_day_blocked)
      return;
   g_day_blocked = true;
   GlobalVariableSet(GvKey("dayblock." + IntegerToString((long)g_day)), 1.0);
   GlobalVariablesFlush();
   g_log.Log("DAY_BLOCKED", "", why, "no new orders until the next UTC day");
  }

//+------------------------------------------------------------------+
//| Adaptive-risk state                                              |
//+------------------------------------------------------------------+
void UpdateHighWaterMark(void)
  {
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(bal > GvGet("hwm", 0.0))
      GvSet("hwm", bal);
   if(eq > GvGet("eq_peak", 0.0))
      GvSet("eq_peak", eq);
   g_lim.peak_equity = MathMax(GvGet("eq_peak", eq), g_lim.initial_balance);
  }

void LoadEdgeStats(void)
  {
   g_stats.Reset();
   g_stats.total = GvGet("st.total", 0.0);
   for(int d = 0; d < RB_FEAT_DIMS; d++)
      for(int b = 0; b < RB_FEAT_BUCKETS; b++)
        {
         g_stats.n[d][b]     = GvGet("st.n." + IntegerToString(d) + "." + IntegerToString(b), 0.0);
         g_stats.sum_r[d][b] = GvGet("st.s." + IntegerToString(d) + "." + IntegerToString(b), 0.0);
        }
  }

void SaveEdgeStats(void)
  {
   GvSet("st.total", g_stats.total);
   for(int d = 0; d < RB_FEAT_DIMS; d++)
      for(int b = 0; b < RB_FEAT_BUCKETS; b++)
        {
         GvSet("st.n." + IntegerToString(d) + "." + IntegerToString(b), g_stats.n[d][b]);
         GvSet("st.s." + IntegerToString(d) + "." + IntegerToString(b), g_stats.sum_r[d][b]);
        }
   GlobalVariablesFlush();
  }

int ScaleReasonCode(const string why)
  {
   if(why == "SCALED")              return 1;
   if(why == "SCALED_CAPPED")       return 2;
   if(why == "BASE_DRAWDOWN_BRAKE") return 3;
   if(why == "BASE_LOSS_STREAK")    return 4;
   if(why == "BASE_NO_REFERENCE")   return 5;
   return 0;
  }

string ScaleReasonText(int code)
  {
   switch(code)
     {
      case 1: return "SCALED";
      case 2: return "SCALED_CAPPED";
      case 3: return "BASE_DRAWDOWN_BRAKE";
      case 4: return "BASE_LOSS_STREAK";
      case 5: return "BASE_NO_REFERENCE";
     }
   return "BASE";
  }

string ExitReasonText(long reason)
  {
   if(reason == DEAL_REASON_SL)     return "SL";
   if(reason == DEAL_REASON_TP)     return "TP";
   if(reason == DEAL_REASON_SO)     return "STOP_OUT";
   if(reason == DEAL_REASON_EXPERT) return "EA";
   if(reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB)
      return "MANUAL";
   return "OTHER";
  }

//--- track max favourable / adverse excursion of open positions (price distance from entry)
void UpdateExcursions(double bid, double ask)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      ulong id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      int dir = (int)g_meta.Get(id, "dir");
      if(dir == 0)
         continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double px   = dir == RB_DIR_BULL ? bid : ask;   // price the position would close at
      double exc  = dir == RB_DIR_BULL ? px - open : open - px;
      if(exc > g_meta.Get(id, "mfe"))
         g_meta.Set(id, "mfe", exc);
      if(exc < g_meta.Get(id, "mae"))
         g_meta.Set(id, "mae", exc);
     }
  }

//--- Upcomers fails an account after 35 days without a closed trade: warn early, once per day
void CheckInactivity(void)
  {
   if(InpInactivityWarnDays <= 0)
      return;
   if(!GlobalVariableCheck(GvKey("last_close")))
      GvSet("last_close", (double)TimeCurrent());
   double days = (TimeCurrent() - (datetime)GvGet("last_close", (double)TimeCurrent())) / 86400.0;
   if(days < InpInactivityWarnDays)
      return;
   datetime today = RB_DayStart(TimeCurrent(), ServerOffsetSec());
   if((datetime)GvGet("inactivity_warned", 0.0) == today)
      return;
   GvSet("inactivity_warned", (double)today);
   string msg = StringFormat("RBOTE: no closed trade for %.0f days (prop rule: 35)", days);
   g_log.Log("INACTIVITY_WARNING", "", msg, "consider a manual minimum trade per firm rules");
   if(!g_tester)
      SendNotification(msg);
  }

//+------------------------------------------------------------------+
//| Challenge tracking: target, trading days (= UTC days with a      |
//| closed trade on the account), calendar limit                     |
//+------------------------------------------------------------------+
datetime ChallengeStart(void)
  {
   if(InpChallengeStart > 0)
      return InpChallengeStart;
   if(!GlobalVariableCheck(GvKey("challenge_start")))
      GvSet("challenge_start", (double)TimeCurrent());
   return (datetime)GvGet("challenge_start", (double)TimeCurrent());
  }

int ActiveTradingDays(bool &today_counted)
  {
   today_counted = false;
   int off = ServerOffsetSec();
   datetime start = ChallengeStart();
   if(!HistorySelect(start, TimeCurrent() + 60))
      return 0;
   long today = ((long)TimeCurrent() - off) / 86400;   // UTC day numbers
   long seen[];
   int n = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;
      long day = (long)ServerToUtc((datetime)HistoryDealGetInteger(d, DEAL_TIME)) / 86400;
      bool dup = false;
      for(int j = 0; j < n && !dup; j++)
         dup = (seen[j] == day);
      if(dup)
         continue;
      ArrayResize(seen, n + 1);
      seen[n++] = day;
      if(day == today)
         today_counted = true;
     }
   return n;
  }

int g_ch_state = RB_CH_CONTINUE;

//--- evaluates the challenge; on a terminal state cancels pending orders and notifies once
int CheckChallenge(void)
  {
   bool today_counted;
   int days = ActiveTradingDays(today_counted);
   datetime end = InpChallengeDays > 0 ? ChallengeStart() + InpChallengeDays * 86400 : 0;
   int st = RB_ChallengeState(AccountInfoDouble(ACCOUNT_BALANCE), g_lim.initial_balance, InpProfitTargetPct / 100.0,
                              days, today_counted, InpMaxTradingDays, TimeCurrent(), end);
   if(st != RB_CH_CONTINUE && st != g_ch_state)
     {
      string msg = StringFormat("RBOTE challenge: %s (balance %.2f, trading days %d/%d)", RB_ChallengeText(st),
                                AccountInfoDouble(ACCOUNT_BALANCE), days, InpMaxTradingDays);
      CancelAllPending(RB_ChallengeText(st));
      g_log.Log("CHALLENGE", "", msg, "no new trades; open positions keep their SL/TP");
      if(!g_tester)
         SendNotification(msg);
     }
   else if(st == RB_CH_CONTINUE && InpMaxTradingDays > 0 && days == InpMaxTradingDays - 1 && !today_counted &&
           g_ch_state == RB_CH_CONTINUE && (int)GvGet("ch_lastday_warned", 0.0) != days)
     {
      GvSet("ch_lastday_warned", days);
      g_log.Log("CHALLENGE", "", StringFormat("next trading day is the last one (%d/%d used)", days, InpMaxTradingDays), "WARN");
     }
   g_ch_state = st;
   return st;
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_tester = (bool)MQLInfoInteger(MQL_TESTER);
   g_log.Init(InpJournal, InpMagic);
   BuildConfig();

   if(_Period != TF)
      g_log.Log("INFO", "", "chart period differs from M15", "EA always evaluates M15 bars");
   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      g_log.Log("WARN", "", "symbol " + _Symbol, "strategy was specified for XAUUSD");

   //--- 1. parameters that must be chosen explicitly
   if(InpStopMode == RB_STOP_FIXED && InpStopUnit == RB_UNIT_NOT_SET)
     {
      g_log.Log("INIT_REFUSED", "", "InpStopUnit not set",
                "choose PRICE / POINTS / TICKS for the 10-point stop; it is never assumed");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!(InpFibLevel > 0.0 && InpFibLevel < 1.0) || !(InpRR > 0.0) || !(InpRiskPct > 0.0) || InpRiskPct > 2.0 ||
      !(InpDailyLossPct > 0.0) || InpLookbackBars < InpZoneMaxAgeBars + 50 ||
      (InpRegimeEnabled && (InpLookbackBars < InpRegimeAtrLookback + InpRangeErPeriod + 20 ||
                            InpRiskMultHighVol > 1.0 || InpRiskMultLowVol > 1.0 || InpRiskMultRange > 1.0 ||
                            !(InpVolLowThr < InpVolHighThr && InpVolHighThr < InpVolExtremeThr))) ||
      InpMaxRiskPct < InpRiskPct || InpMaxRiskPct > 2.0 || InpProfitSharePct < 0.0 ||
      InpEdgeMinMult <= 0.0 || InpEdgeMinMult > 1.0 || InpEdgeMaxMult < 1.0 || InpEdgePrior < 0.0)
     {
      g_log.Log("INIT_REFUSED", "", "invalid inputs", "check fib/rr/risk/lookback");
      return INIT_PARAMETERS_INCORRECT;
     }

   //--- 2. account gate. Every non-tester account (demo / prop evaluation included) needs
   //--- InpLiveConfirmLogin = its login. An account that is not known yet (terminal still
   //--- logging in / disconnected) is not a permanent refusal: re-checked on later ticks.
   int perm = TradingPermission();
   if(perm == 5)
     {
      g_wait_account = true;
      g_ready = false;
      g_log.Log("INIT_WAIT", "", "account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)),
                RB_PermissionText(perm) + "; re-checked on every tick, no trading until known");
      return INIT_SUCCEEDED;
     }
   if(perm != 0)
     {
      g_log.Log("INIT_REFUSED", "", "account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), RB_PermissionText(perm));
      return INIT_FAILED;
     }
   return AccountInit();
  }

//--- everything that needs a known account: margin mode, key namespace, state, reconciliation
int AccountInit(void)
  {
   g_wait_account = false;
   long login = AccountInfoInteger(ACCOUNT_LOGIN);

   //--- 3. only hedging accounts: metadata, partial fills and close accounting assume one
   //--- position per order (POSITION_IDENTIFIER = order ticket). Netting would merge positions.
   long mm = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(mm != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      g_log.Log("INIT_REFUSED", "", StringFormat("account %I64d margin_mode=%s%s", login,
                EnumToString((ENUM_ACCOUNT_MARGIN_MODE)mm), g_tester ? " (tester account)" : ""),
                "HEDGING_ACCOUNT_REQUIRED (netting/exchange accounts are not supported)");
      return INIT_FAILED;
     }

   //--- 4. global-variable namespace per account + symbol + magic
   g_prefix = RB_KeyPrefix(login, _Symbol, InpMagic);
   g_meta.Init(g_prefix);
   if(!g_tester)
      g_log.Init(InpJournal, InpMagic);   // file name now carries the known login
   if(g_tester)
     {
      // optimization passes / repeated runs on one agent must not inherit state
      int del = GlobalVariablesDeleteAll(g_prefix + ".");
      g_log.Log("TESTER_RESET", "", "prefix " + g_prefix, StringFormat("%d global variables deleted", del));
     }
   else if(GlobalVariableCheck("RBOTE." + IntegerToString(InpMagic) + ".initial_balance"))
      g_log.Log("WARN", "", "legacy keys RBOTE." + IntegerToString(InpMagic) + ".* found",
                "ignored: state is now namespaced by account+symbol+magic (" + g_prefix + ")");

   //--- 5. symbol specification
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
   int exp_modes = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   long gtc_mode = SymbolInfoInteger(_Symbol, SYMBOL_ORDER_GTC_MODE);
   if((exp_modes & SYMBOL_EXPIRATION_SPECIFIED) == 0)
      g_log.Log("WARN", "", StringFormat("expiration_mode=%d gtc_mode=%s", exp_modes,
                EnumToString((ENUM_SYMBOL_ORDER_GTC_MODE)gtc_mode)),
                "no server-side expiry: EA-side expiry only, own pending orders are cancelled on EA removal");
   if(gtc_mode == SYMBOL_ORDERS_DAILY)
      g_log.Log("WARN", "", "SYMBOL_ORDER_GTC_MODE = DAILY",
                "broker deletes SL/TP at day end: Reconcile restores the SL every bar (or closes)");

   g_lim.initial_balance = InitialBalance();
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(50);   // used by PositionClose (Reconcile)

   UpdateDay();
   UpdateHighWaterMark();
   LoadEdgeStats();
   if(InpMaxOpenRiskPct < InpMaxRiskPct)
      g_log.Log("WARN", "", "InpMaxOpenRiskPct < InpMaxRiskPct", "scaled-up orders will be denied by MAX_OPEN_RISK");
   g_log.Log("ADAPTIVE", "", StringFormat("start_balance=%.2f hwm=%.2f consecutive_losses=%d edge_trades=%.0f",
             g_lim.initial_balance, GvGet("hwm", 0.0), (int)GvGet("consec_losses", 0.0), g_stats.total),
             StringFormat("scale=%s share=%.2f%% cap=%.2f%% edge=%s", InpScaleEnabled ? "on" : "off",
                          InpProfitSharePct, InpMaxRiskPct, InpEdgeEnabled ? "on" : "off"));
   Reconcile("INIT");
   SweepClosed("INIT");
   g_log.Log("CHALLENGE", "", StringFormat("target=%.2f%% max_trading_days=%d calendar_days=%d start=%s",
             InpProfitTargetPct, InpMaxTradingDays, InpChallengeDays, TimeToString(ChallengeStart())),
             RB_ChallengeText(CheckChallenge()));
   g_ready = true;
   g_log.Log("INIT_OK", "", g_tester ? "tester" : (AccountModeCode() == RB_ACC_DEMO ? "demo" : "LIVE"),
             StringFormat("login=%I64d keys=%s rr=%.1f fib=%.2f stop_mode=%s risk=%.2f%% daily=%.2f%% of %s utc_offset=%dh",
                          login, g_prefix, InpRR, InpFibLevel, EnumToString(InpStopMode), InpRiskPct, InpDailyLossPct,
                          InpDailyOnInitial ? "initial" : "day-start ref", ServerOffsetSec() / 3600));
   return INIT_SUCCEEDED;
  }

//--- deferred init: account was unknown at OnInit
void TryAccountInit(void)
  {
   int perm = TradingPermission();
   if(perm == 5)
      return;   // still unknown; logged once at OnInit
   if(perm != 0)
     {
      g_wait_account = false;
      g_log.Log("INIT_REFUSED", "", "account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), RB_PermissionText(perm));
      ExpertRemove();
      return;
     }
   g_log.Log("ACCOUNT_KNOWN", "", "account " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)), "completing init");
   if(AccountInit() != INIT_SUCCEEDED)
     {
      g_ready = false;
      ExpertRemove();
     }
  }

void OnDeinit(const int reason)
  {
   //--- orders without server-side expiry would outlive the EA-side expiry: cancel them (best effort)
   int cancelled = 0, failed = 0;
   if(g_prefix != "")
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = OrderGetTicket(i);
         if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic || OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
         if(OrderGetInteger(ORDER_TYPE_TIME) == ORDER_TIME_SPECIFIED)
            continue;
         string cmt = OrderGetString(ORDER_COMMENT);
         if(g_trade.OrderDelete(t))
           {
            cancelled++;
            g_log.Log("ORDER_CANCELLED", cmt, "ticket " + IntegerToString((long)t), "DEINIT_NO_SERVER_EXPIRY");
            ReleaseOrderMeta(t);
           }
         else
           {
            failed++;
            g_log.Log("ORDER_CANCEL_FAILED", cmt, "ticket " + IntegerToString((long)t),
                      "DEINIT_NO_SERVER_EXPIRY retcode=" + IntegerToString((long)g_trade.ResultRetcode()));
           }
        }
   g_log.Log("DEINIT", "", "reason=" + IntegerToString(reason),
             StringFormat("orders without server expiry: %d cancelled, %d failed; others stay with SL/TP and server-side expiry",
                          cancelled, failed));
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
      bool   buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double msl = g_meta.Get(id, "sl");
      int act = RB_ReconcilePosition(sl > 0.0, msl > 0.0);
      if(act == RB_REC_SET_SL)
        {
         //--- restore the stored SL; if price is already beyond it or the modify fails, close
         MqlTick tk;
         bool have   = SymbolInfoTick(_Symbol, tk) && tk.bid > 0.0 && tk.ask > 0.0;
         bool beyond = have && (buy ? tk.bid <= msl : tk.ask >= msl);
         bool ok = false;
         if(have && !beyond)
            ok = g_trade.PositionModify(t, NormalizeDouble(msl, _Digits), NormalizeDouble(g_meta.Get(id, "tp"), _Digits));
         if(ok)
           {
            g_log.Log("RECONCILE_SET_SL", cmt, when + " position " + IntegerToString((long)t), "missing SL restored");
            continue;
           }
         string why = !have ? "no quote" : beyond ? "price already beyond stored SL " + DoubleToString(msl, _Digits)
                                                  : "SL restore failed: " + IntegerToString((long)g_trade.ResultRetcode());
         bool closed = g_trade.PositionClose(t);
         g_log.Log("RECONCILE_CLOSE", cmt, when + " position " + IntegerToString((long)t),
                   why + (closed ? " -> unprotected position closed" : " -> close failed: " + IntegerToString((long)g_trade.ResultRetcode())));
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
//--- the order `t` is no longer pending: drop its metadata, unless a (partially filled)
//--- position with that identifier lives on or its closed trade still needs accounting
void ReleaseOrderMeta(ulong t)
  {
   if(!g_meta.Has(t))
      return;
   if(PositionExistsById(t))
     {
      g_log.Log("META_KEPT", "", "order " + IntegerToString((long)t), "partially filled: metadata kept for the open position");
      return;
     }
   if(ProcessClosedPosition(t, true))
      return;
   g_meta.Delete(t);
  }

void CancelOrder(ulong t, const string reason)
  {
   string id = "";
   if(OrderSelect(t))
      id = OrderGetString(ORDER_COMMENT);
   bool ok = g_trade.OrderDelete(t);
   g_log.Log(ok ? "ORDER_CANCELLED" : "ORDER_CANCEL_FAILED", id, "ticket " + IntegerToString((long)t),
             ok ? reason : reason + " retcode=" + IntegerToString((long)g_trade.ResultRetcode()));
   if(ok)
      ReleaseOrderMeta(t);
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
   TimeToStruct(ServerToUtc(TimeCurrent()), dt);
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
void ProcessSignal(const RBSignal &sig, const CRBSeries &series)
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
   //--- volatility / range regime at the confirming (closed) bar
   RBRegime reg;
   RB_ClassifyRegime(series, sig.confirm_idx, g_reg, reg);
   RBRegimeDecision rd;
   RB_RegimeDecide(reg, g_reg, InpRR, rd);
   ctx += StringFormat(" regime=%s VR=%.2f ER=%.2f", rd.reason, reg.vol_ratio, reg.er);
   g_log.Log("SIGNAL", id, ctx, "RB confirmed");
   if(!rd.allow)
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, "REGIME_SKIP " + rd.reason);
      return;
     }
   RBConfig cfg = g_cfg;
   cfg.rr = rd.rr;

   string why = "";
   int ch = CheckChallenge();
   if(ch != RB_CH_CONTINUE)
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, RB_ChallengeText(ch));
      return;
     }
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
   int r = RB_BuildPlan(sig, cfg, g_spec, plan);
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
   double ref_eq = MathMin(bal, eq);
   string scale_why;
   double pct = RB_ProfitScaledPct(g_scale, g_lim.initial_balance, bal, GvGet("hwm", bal), ref_eq,
                                   (int)GvGet("consec_losses", 0.0), scale_why);
   MqlDateTime sdt;
   TimeToStruct(ServerToUtc(sig.confirm_time + PeriodSeconds(TF)), sdt);   // decision time (UTC) = close of the confirming bar
   RBFeatures feat;
   RB_MakeFeatures(sig.dir, sig.zone_type, reg.valid ? reg.vol_class : RB_VOL_NORMAL, reg.ranging, sdt.hour, feat);
   string edge_why;
   double edge_mult = g_stats.Mult(feat, g_edge, edge_why);
   double risk_money = RB_FinalRiskMoney(pct, ref_eq, rd.risk_mult, edge_mult, g_scale.max_pct);
   double candle_range = series.H(sig.rb_idx) - series.L(sig.rb_idx);
   double wick_ratio   = candle_range > 0.0 ? (sig.rb_high - sig.rb_low) / candle_range : 0.0;
   double rb_range_atr = sig.atr > 0.0 ? (sig.rb_high - sig.rb_low) / sig.atr : 0.0;
   double stop_atr     = sig.atr > 0.0 ? plan.risk_dist / sig.atr : 0.0;
   //--- decision card: every input of the risk decision, readable
   string card = StringFormat("WHY: zone=%s(hits %d) RB wick=%.0f%% of candle, RB height=%.2f ATR, stop=%.2f ATR | "
                              "regime=%s VR=%.2f ER=%.2f -> x%.2f rr=%.1f | base=%.3f%% profit-scale=%s -> %.3f%% | "
                              "edge=%s x%.3f [%s] | final risk=%.2f (%.3f%% of %.2f)",
                              sig.zone_type == RB_ZONE_FVG ? "FVG" : "OB", sig.zones_hit, wick_ratio * 100.0,
                              rb_range_atr, stop_atr, rd.reason, reg.vol_ratio, reg.er, rd.risk_mult, cfg.rr,
                              g_scale.base_pct * 100.0, scale_why, pct * 100.0, edge_why, edge_mult,
                              RB_EdgeExplain(g_stats, feat, g_edge), risk_money,
                              ref_eq > 0.0 ? risk_money / ref_eq * 100.0 : 0.0, ref_eq);
   g_log.Log("DECISION", id, card, "risk inputs");
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
   if(!RB_BuildSnapshot(InpMagic, InpCommissionPerLotRT, g_day_ref, ServerOffsetSec(), snap, err))
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
   g_meta.Set(ticket, "vr", reg.vol_ratio);
   g_meta.Set(ticket, "er", reg.er);
   g_meta.Set(ticket, "vc", reg.valid ? reg.vol_class : -1);
   g_meta.Set(ticket, "rng", reg.ranging ? 1.0 : 0.0);
   g_meta.Set(ticket, "rr", cfg.rr);
   g_meta.Set(ticket, "rmul", rd.risk_mult);
   g_meta.Set(ticket, "pct", pct);
   g_meta.Set(ticket, "emul", edge_mult);
   g_meta.Set(ticket, "srs", ScaleReasonCode(scale_why));
   g_meta.Set(ticket, "zh", sig.zones_hit);
   g_meta.Set(ticket, "wr", wick_ratio);
   g_meta.Set(ticket, "rba", rb_range_atr);
   g_meta.Set(ticket, "sta", stop_atr);
   g_meta.Set(ticket, "mfe", 0.0);
   g_meta.Set(ticket, "mae", 0.0);
   for(int d = 0; d < RB_FEAT_DIMS; d++)
      g_meta.Set(ticket, "f" + IntegerToString(d), feat.b[d]);
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
   CheckInactivity();
   CheckChallenge();
   UpdateHighWaterMark();

   //--- day limit: existing exposure already at the limit -> cancel pending, block the day
   RBRiskSnapshot snap;
   string err;
   if(RB_BuildSnapshot(InpMagic, InpCommissionPerLotRT, g_day_ref, ServerOffsetSec(), snap, err))
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
         ProcessSignal(sig, s);
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
     {
      ManagePendingOnTick(tick.bid, tick.ask);
      UpdateExcursions(tick.bid, tick.ask);
      UpdateHighWaterMark();
     }

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
   int dir     = (int)g_meta.Get(pos, "dir");
   double rdist = MathAbs(g_meta.Get(pos, "entry") - g_meta.Get(pos, "sl"));

   RBTradeRow row;
   row.open_time       = t_open;
   row.close_time      = t_close;
   row.signal_time     = ServerToUtc((datetime)g_meta.Get(pos, "bar") + PeriodSeconds(TF));
   row.dir             = dir;
   row.planned_entry   = g_meta.Get(pos, "entry");
   row.fill_price      = fill;
   row.sl              = g_meta.Get(pos, "sl");
   row.tp              = g_meta.Get(pos, "tp");
   row.volume          = vol;
   row.risk_money      = risk;
   row.net             = net;
   row.r               = rr;
   row.signal_id       = id;
   row.atr             = g_meta.Get(pos, "atr");
   row.zone_type       = (int)g_meta.Get(pos, "zty");
   row.rr              = g_meta.Get(pos, "rr");
   row.stop_mode       = InpStopMode;
   row.exit_price      = px;
   row.vol_class       = (int)g_meta.Get(pos, "vc");
   row.ranging         = g_meta.Get(pos, "rng") > 0.5;
   row.vol_ratio       = g_meta.Get(pos, "vr");
   row.er              = g_meta.Get(pos, "er");
   row.risk_mult       = g_meta.Get(pos, "rmul");
   row.exit_reason     = ExitReasonText(HistoryDealGetInteger(trans.deal, DEAL_REASON));
   row.mfe_r           = rdist > 0.0 ? g_meta.Get(pos, "mfe") / rdist : 0.0;
   row.mae_r           = rdist > 0.0 ? g_meta.Get(pos, "mae") / rdist : 0.0;
   row.zones_hit       = (int)g_meta.Get(pos, "zh");
   row.wick_ratio      = g_meta.Get(pos, "wr");
   row.rb_range_atr    = g_meta.Get(pos, "rba");
   row.stop_atr        = g_meta.Get(pos, "sta");
   row.fill_delay_bars = (int)((ServerToUtc(t_open) - row.signal_time) / PeriodSeconds(TF));
   row.risk_pct        = g_meta.Get(pos, "pct");
   row.edge_mult       = g_meta.Get(pos, "emul");
   row.scale_reason    = ScaleReasonText((int)g_meta.Get(pos, "srs"));

   //--- outcome explanation: what happened and under which conditions
   RBFeatures feat;
   ZeroMemory(feat);
   for(int d = 0; d < RB_FEAT_DIMS; d++)
      feat.b[d] = (int)g_meta.Get(pos, "f" + IntegerToString(d));
   string cond = "";
   for(int d = 0; d < RB_FEAT_DIMS; d++)
      cond += (d > 0 ? (string)" " : (string)"") + RB_DimText(d) + "=" + RB_BucketText(d, feat.b[d]);
   string outcome = rr > 0.0 ? "WIN" : "LOSS";
   string story = StringFormat("%s %.2fR by %s | went +%.2fR / %.2fR before exit | %s | zone hits=%d wick=%.0f%% "
                               "RB=%.2f ATR stop=%.2f ATR | filled after %d bars | risk %.3f%% (%s, edge x%.2f, regime x%.2f)",
                               outcome, rr, row.exit_reason, row.mfe_r, row.mae_r, cond, row.zones_hit,
                               row.wick_ratio * 100.0, row.rb_range_atr, row.stop_atr, row.fill_delay_bars,
                               row.risk_pct * 100.0, row.scale_reason, row.edge_mult, row.risk_mult);
   g_log.Log("CLOSED", id, StringFormat("position %I64u exit=%s net=%.2f risk=%.2f", pos,
             DoubleToString(px, _Digits), net, risk), story);
   g_log.Trade(row);

   //--- learn from the closed trade (past trades only -> no lookahead)
   g_stats.Add(feat, rr);
   SaveEdgeStats();
   GvSet("consec_losses", net < 0.0 ? GvGet("consec_losses", 0.0) + 1.0 : 0.0);
   GvSet("last_close", (double)TimeCurrent());
   UpdateHighWaterMark();
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
