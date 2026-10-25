//+------------------------------------------------------------------+
//| RBOTE_EA.mq5                                                     |
//| XAUUSD M15, two strategies in one EA (spec 02 section 5):        |
//|  RBOTE (sid 1, InpMagic): PD Array (FVG / OB) -> Rejection Block |
//|   -> 0.79 OTE limit entry, fixed or structural stop, 6R target.  |
//|  DTBS (sid 2, InpMagicDTBS): HTF trend + triangle break (A-B-C,  |
//|   20-bar extension), market entry, adaptive stop, 1.5R target.   |
//| Risk and firm limits are account-wide; no hedging on the symbol. |
//|                                                                  |
//| Defaults are SAFE: outside the tester every account (also demo / |
//| prop evaluation) needs InpLiveConfirmLogin = its login; real     |
//| accounts additionally need two more explicit inputs; the stop    |
//| unit must be chosen; only hedging accounts are supported.        |
//+------------------------------------------------------------------+
#property copyright "RBOTE"
#property version   "1.00"
#property description "M15 RBOTE (PD Array + Rejection Block + OTE 0.79) + DTBS (trend break). Demo/backtest by default."

#include <Trade/Trade.mqh>
#include <RBOTE/RejectionBlock.mqh>
#include <RBOTE/TradeMath.mqh>
#include <RBOTE/RiskGuard.mqh>
#include <RBOTE/Safety.mqh>
#include <RBOTE/MT5Bridge.mqh>
#include <RBOTE/Journal.mqh>
#include <RBOTE/Regime.mqh>
#include <RBOTE/Adaptive.mqh>
#include <RBOTE/DTBS.mqh>

//--- inputs ---------------------------------------------------------
input group "Safety / mode"
input bool   InpAllowLiveTrading   = false;   // Allow REAL accounts (default: refused)
input long   InpLiveConfirmLogin   = 0;       // REQUIRED on every non-tester account (demo/prop too): its login
input bool   InpPropRulesVerified  = false;   // Real account: prop-firm rules verified by you
input long   InpMagic              = 7915790; // Magic number (RBOTE)

input group "Strategies"
input bool   InpEnableRBOTE        = false;   // Strategy 1: RBOTE (OFF: no edge in 2020-2023 backtest, D-038)
input bool   InpEnableDTBS         = true;    // Strategy 2: DTBS (dynamic trend break, market entry)
input long   InpMagicDTBS          = 7915791; // Magic number (DTBS), must differ from InpMagic

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

// Stop unit offered in the inputs. No "not set" value: an old cached tester value can no
// longer block the start (RB_UNIT_NOT_SET stays in the core library for its own checks).
enum ENUM_RB_EA_STOP_UNIT
  {
   RB_EA_UNIT_PRICE  = 0, // price distance (10.0 = 10.00 $ on XAUUSD)
   RB_EA_UNIT_POINTS = 1, // multiples of SYMBOL_POINT
   RB_EA_UNIT_TICKS  = 2  // multiples of SYMBOL_TRADE_TICK_SIZE
  };

input group "Entry / exit"
input double InpFibLevel           = 0.79;    // Fibonacci entry level on the RB range
input ENUM_RB_STOP_MODE InpRbStopMode = RB_STOP_FIXED; // RBOTE stop mode (FIXED 10.00 = least bad in 2020-2023, D-038)
input double InpStopDistance       = 10.0;    // FIXED mode only: stop distance (comparison variant)
input ENUM_RB_EA_STOP_UNIT InpRbStopUnit = RB_EA_UNIT_PRICE; // FIXED mode only: unit of the stop distance
input double InpStructuralBuffer   = 0.30;    // STRUCTURAL/ATR stop: buffer beyond RB extreme (price)
input double InpRbStopATR          = 3.0;     // ATR stop: distance = x ATR(14) (never inside the RB extreme)
input double InpMaxStopATR         = 3.0;     // STRUCTURAL/ATR stop: skip trade if stop > x ATR(14) (0 = off)
input double InpMinStopATR         = 0.0;     // STRUCTURAL/ATR stop: skip trade if stop < x ATR(14) (0 = off)
input bool   InpRequireSlBeyondRb  = true;    // Fixed stop must be beyond the RB extreme
input double InpRR                 = 6.0;     // Target in R (6 source, 5 alternative)
input double InpMinStopSpreadMult  = 2.0;     // Stop >= mult x current spread
input double InpMaxSpreadPrice     = 0.0;     // Max spread for new orders (price, 0 = off)
input int    InpOrderExpiryBars    = 8;       // Pending order lifetime in M15 bars

input group "DTBS - Dynamic Trend Break (spec docs/02, ASSUMPTIONS marked there)"
input int    InpDtbsExtBars        = 20;      // Horizontal extension B -> C in M15 bars (confirmed: 20)
input ENUM_RB_DTBS_BREAK_DIRS InpDtbsBreakDirs = RB_DTBS_BOTH;          // Break directions that signal
input ENUM_RB_DTBS_CONFIRM    InpDtbsConfirm   = RB_DTBS_CONFIRM_CLOSE; // Break confirmation (close / wick)
input ENUM_RB_DTBS_SL_MODE    InpDtbsSlMode    = RB_DTBS_SL_ADAPTIVE;   // Stop mode (ADAPTIVE: from the break start)
input double InpDtbsSlBuffer       = 0.30;    // Stop buffer, price (buffer = max(this, spread))
input double InpDtbsSlAtrMult      = 1.5;     // ATR stop mode: k x ATR
input double InpDtbsMinStopATR     = 0.5;     // ADAPTIVE: min stop distance in ATR
input double InpDtbsMaxStopATR     = 3.0;     // Max stop distance in ATR (0 = off)
input double InpDtbsRR             = 1.5;     // Target in R (confirmed: 1.5)
input ENUM_RB_DTBS_HTF_AGREE  InpDtbsHtfAgree  = RB_DTBS_HTF_ALL;       // H1 + H4 main trend agreement
input int    InpDtbsSwingN         = 2;       // M15 fractal strength (ASSUMPTION 2)
input int    InpDtbsHtfSwingN      = 2;       // H1/H4 fractal strength for the main trend
input double InpDtbsMinLegATR      = 1.0;     // Counter leg pB - pA >= x ATR (ASSUMPTION 1.0)
input int    InpDtbsMaxLegBars     = 200;     // A searched at most this many bars before B
input int    InpDtbsAtrPeriod      = 14;      // ATR period
input int    InpDtbsHtfBars        = 600;     // Closed H1 and H4 bars copied for the main trend
input double InpDtbsRiskPct        = 0.25;    // DTBS risk per trade, % of min(balance, equity)

input group "Risk (test values, NOT prop-firm rules)"
input double InpRiskPct            = 0.25;    // RBOTE risk per trade, % of min(balance, equity)
input double InpDailyLossPct       = 2.0;     // Personal daily loss limit, % (base below; Ash Turbo firm: 3% of initial)
input bool   InpDailyOnInitial     = true;    // Daily limit = % of INITIAL balance (Ash Turbo rule); false = of day-start ref
input double InpMaxOpenRiskPct     = 0.5;     // Open + pending + new risk cap, % of equity
input double InpMaxTotalDDPct      = 4.0;     // Personal total drawdown, % of initial balance (Ash firm: 6%)
input bool   InpTrailingDD         = true;    // Floor follows the equity peak, locks at initial (Ash rule)
input double InpInitialBalance     = 0.0;     // Initial balance for total DD (0 = balance at first start)
input int    InpMaxTradesPerDay    = 3;       // Max entries per UTC day PER STRATEGY (00:00 UTC reset, 0 = off)
input int    InpMaxPositions       = 1;       // Max open positions PER STRATEGY (its magic, 0 = off)
input int    InpMaxPending         = 1;       // Max pending orders PER STRATEGY (its magic, 0 = off)
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
RBDtbsConfig  g_dcfg;
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

//--- both strategies' orders and positions belong to this EA (also while a strategy is disabled:
//--- its open trades are still reconciled, booked and protected)
bool IsOwnMagic(long m) { return m == InpMagic || m == InpMagicDTBS; }

//--- strategy of a metadata record; records written before the "sid" field existed are RBOTE
int MetaSid(ulong t) { return (int)g_meta.Get(t, "sid") == RB_SID_DTBS ? RB_SID_DTBS : RB_SID_RBOTE; }

string MetaSignalId(ulong t)
  {
   int dir = (int)g_meta.Get(t, "dir");
   datetime st = (datetime)g_meta.Get(t, "rbt");
   return MetaSid(t) == RB_SID_DTBS ? RB_DtbsSignalId(dir, st) : RB_SignalId(dir, st);
  }

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
   g_cfg.stop_mode            = InpRbStopMode;
   g_cfg.stop_distance        = InpStopDistance;
   g_cfg.stop_unit            = (int)InpRbStopUnit;
   g_cfg.structural_buffer    = InpStructuralBuffer;
   g_cfg.max_stop_atr         = InpMaxStopATR;
   g_cfg.min_stop_atr         = InpMinStopATR;
   g_cfg.stop_atr_mult        = InpRbStopATR;
   g_cfg.require_sl_beyond_rb = InpRequireSlBeyondRb;
   g_cfg.rr                   = InpRR;
   g_cfg.min_stop_spread_mult = InpMinStopSpreadMult;

   g_dcfg.Defaults();
   g_dcfg.swing_n         = InpDtbsSwingN;
   g_dcfg.htf_swing_n     = InpDtbsHtfSwingN;
   g_dcfg.atr_period      = InpDtbsAtrPeriod;
   g_dcfg.min_leg_atr     = InpDtbsMinLegATR;
   g_dcfg.ext_bars        = InpDtbsExtBars;
   g_dcfg.max_leg_bars    = InpDtbsMaxLegBars;
   g_dcfg.break_dirs      = InpDtbsBreakDirs;
   g_dcfg.confirm         = InpDtbsConfirm;
   g_dcfg.sl_mode         = InpDtbsSlMode;
   g_dcfg.sl_buffer_price = InpDtbsSlBuffer;
   g_dcfg.sl_atr_mult     = InpDtbsSlAtrMult;
   g_dcfg.rr              = InpDtbsRR;
   g_dcfg.min_stop_atr    = InpDtbsMinStopATR;
   g_dcfg.max_stop_atr    = InpDtbsMaxStopATR;
   g_dcfg.htf_agreement   = InpDtbsHtfAgree;

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
      if(t != 0 && IsOwnMagic(OrderGetInteger(ORDER_MAGIC)) && OrderGetString(ORDER_SYMBOL) == _Symbol)
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
      if(t == 0 || !IsOwnMagic(PositionGetInteger(POSITION_MAGIC)) || PositionGetString(POSITION_SYMBOL) != _Symbol)
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

   if(!(InpFibLevel > 0.0 && InpFibLevel < 1.0) || !(InpRR > 0.0) || !(InpRiskPct > 0.0) || InpRiskPct > 2.0 ||
      !(InpDailyLossPct > 0.0) || InpLookbackBars < InpZoneMaxAgeBars + 50 ||
      (InpRegimeEnabled && (InpLookbackBars < InpRegimeAtrLookback + InpRangeErPeriod + 20 ||
                            InpRiskMultHighVol > 1.0 || InpRiskMultLowVol > 1.0 || InpRiskMultRange > 1.0 ||
                            !(InpVolLowThr < InpVolHighThr && InpVolHighThr < InpVolExtremeThr))) ||
      InpMaxRiskPct < InpRiskPct || InpMaxRiskPct > 2.0 || InpProfitSharePct < 0.0 ||
      InpEdgeMinMult <= 0.0 || InpEdgeMinMult > 1.0 || InpEdgeMaxMult < 1.0 || InpEdgePrior < 0.0 ||
      InpMaxStopATR < 0.0 || InpMinStopATR < 0.0 || !(InpRbStopATR > 0.0) || InpStructuralBuffer < 0.0)
     {
      g_log.Log("INIT_REFUSED", "", "invalid inputs", "check fib/rr/risk/lookback");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMagicDTBS == InpMagic || InpMagicDTBS <= 0)
     {
      g_log.Log("INIT_REFUSED", "", "InpMagicDTBS=" + IntegerToString(InpMagicDTBS), "must be > 0 and differ from InpMagic");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpEnableDTBS &&
      (!(InpDtbsRiskPct > 0.0) || InpDtbsRiskPct > 2.0 || InpMaxRiskPct < InpDtbsRiskPct || !(InpDtbsRR > 0.0) ||
       InpDtbsExtBars < 1 || InpDtbsSwingN < 1 || InpDtbsHtfSwingN < 1 || InpDtbsAtrPeriod < 1 ||
       InpDtbsMaxLegBars < 2 * InpDtbsSwingN + 1 || InpDtbsSlBuffer < 0.0 || InpDtbsMinStopATR < 0.0 ||
       InpDtbsMaxStopATR < 0.0 || (InpDtbsMaxStopATR > 0.0 && InpDtbsMaxStopATR < InpDtbsMinStopATR) ||
       InpDtbsHtfBars < 4 * InpDtbsHtfSwingN + 20 || InpLookbackBars < InpDtbsMaxLegBars + InpDtbsExtBars + 50))
     {
      g_log.Log("INIT_REFUSED", "", "invalid DTBS inputs", "check risk/rr/ext bars/swing/stop ATR bounds/HTF bars/lookback");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!InpEnableRBOTE && !InpEnableDTBS)
      g_log.Log("WARN", "", "both strategies disabled", "no new orders; existing trades are still managed");
   g_log.Log("STRATEGIES", "", StringFormat("RBOTE=%s magic=%I64d risk=%.2f%% | DTBS=%s magic=%I64d risk=%.2f%%",
             InpEnableRBOTE ? "on" : "off", InpMagic, InpRiskPct, InpEnableDTBS ? "on" : "off", InpMagicDTBS, InpDtbsRiskPct),
             StringFormat("DTBS ext=%d dirs=%s confirm=%s sl=%s buf=%.2f stopATR[%.2f..%.2f] rr=%.2f htf=H1+H4 %s",
                          InpDtbsExtBars, InpDtbsBreakDirs == RB_DTBS_BOTH ? "BOTH" : "WITH_TREND_ONLY",
                          InpDtbsConfirm == RB_DTBS_CONFIRM_CLOSE ? "CLOSE" : "WICK", RB_DtbsSlModeText(InpDtbsSlMode),
                          InpDtbsSlBuffer, InpDtbsMinStopATR, InpDtbsMaxStopATR, InpDtbsRR,
                          InpDtbsHtfAgree == RB_DTBS_HTF_ALL ? "ALL" : "MAJORITY"));

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
   double stop_px = RB_DistanceToPrice(InpStopDistance, (int)InpRbStopUnit, g_spec);
   g_log.Log("SYMBOL_SPEC", "", RB_SpecText(g_spec),
             StringFormat("stop %s %s = %s price = %s points = %s per lot",
                          DoubleToString(InpStopDistance, 2), EnumToString(InpRbStopUnit),
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
                          login, g_prefix, InpRR, InpFibLevel, EnumToString(InpRbStopMode), InpRiskPct, InpDailyLossPct,
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
         if(t == 0 || !IsOwnMagic(OrderGetInteger(ORDER_MAGIC)) || OrderGetString(ORDER_SYMBOL) != _Symbol)
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
      if(t == 0 || !IsOwnMagic(OrderGetInteger(ORDER_MAGIC)) || OrderGetString(ORDER_SYMBOL) != _Symbol)
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
      if(t == 0 || !IsOwnMagic(PositionGetInteger(POSITION_MAGIC)) || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      ulong id   = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      string cmt = PositionGetString(POSITION_COMMENT);
      g_trade.SetExpertMagicNumber((ulong)PositionGetInteger(POSITION_MAGIC));   // close/modify under the position's own magic
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
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
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
      if(t == 0 || !IsOwnMagic(OrderGetInteger(ORDER_MAGIC)) || OrderGetString(ORDER_SYMBOL) != _Symbol)
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
      if(t == 0 || !IsOwnMagic(OrderGetInteger(ORDER_MAGIC)) || OrderGetString(ORDER_SYMBOL) != _Symbol)
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
      if(t == 0 || !IsOwnMagic(OrderGetInteger(ORDER_MAGIC)) || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      int dir = (int)g_meta.Get(t, "dir");
      if(dir == 0)
         continue;
      datetime sig_bar = (datetime)g_meta.Get(t, "bar");
      double tp  = OrderGetDouble(ORDER_TP);
      if(MetaSid(t) == RB_SID_DTBS)
        {
         //--- DTBS has no RB/zone structure: only target-before-fill and expiry (no pending orders by default)
         int alive_d = 0, code_d = RB_CANCEL_NONE;
         for(int k = 0; k < n && code_d == RB_CANCEL_NONE; k++)
           {
            if(rates[k].time <= sig_bar)
               continue;
            alive_d++;
            if((dir == RB_DIR_BULL && rates[k].high >= tp) || (dir == RB_DIR_BEAR && rates[k].low <= tp))
               code_d = RB_CANCEL_TP_REACHED;
            else if(InpOrderExpiryBars > 0 && alive_d >= InpOrderExpiryBars)
               code_d = RB_CANCEL_EXPIRED;
           }
         if(code_d != RB_CANCEL_NONE)
            CancelOrder(t, RB_CancelText(code_d));
         continue;
        }
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
   //--- atomic claim first: of several instances (same account/symbol/magic) only one proceeds
   if(!g_meta.Claim(id))
     {
      g_log.Log("SIGNAL_DUPLICATE", id, ctx, "claimed by another EA instance (or claim failed, err=" +
                IntegerToString(GetLastError()) + ")");
      return;
     }
   g_meta.MarkProcessed(id);   // one attempt per signal, also when rejected below (flushed)
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
                              DoubleToString(plan.risk_dist / g_spec.point, 1), cfg.rr, plan.fib_level);
   r = RB_CheckMarket(plan, g_cfg, g_spec, tick.bid, tick.ask);
   if(r != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + StringFormat(" bid=%s ask=%s", DoubleToString(tick.bid, _Digits),
                DoubleToString(tick.ask, _Digits)), RB_ReasonText(r));
      return;
     }
   //--- restart / late evaluation: the running bar already reached the target -> setup is spent
   double h0 = iHigh(_Symbol, TF, 0), l0 = iLow(_Symbol, TF, 0);
   if((plan.dir == RB_DIR_BULL && h0 > 0.0 && h0 >= plan.tp) || (plan.dir == RB_DIR_BEAR && l0 > 0.0 && l0 <= plan.tp))
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + StringFormat(" bar0 high=%s low=%s", DoubleToString(h0, _Digits),
                DoubleToString(l0, _Digits)), "TP_TOUCHED_CURRENT_BAR (target reached before the order could be placed)");
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
   if(!RB_BuildSnapshot(InpMagic, InpCommissionPerLotRT, InpSlippageTicks, g_day_ref, ServerOffsetSec(), snap, err))
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx, "SNAPSHOT_FAILED " + err);
      return;
     }
   int g = RB_CheckNewOrder(g_lim, snap, trade_risk);
   string gctx = StringFormat(" lots=%.2f risk=%.2f realized=%.2f open=%.2f open_now=%.2f pending=%.2f day_ref=%.2f daily_limit=%.2f",
                              lots, trade_risk, snap.realized_today, snap.open_risk, snap.open_risk_now, snap.pending_risk,
                              snap.day_start_ref, RB_DailyLimitMoney(g_lim, snap));
   if(g != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + gctx, RB_GuardText(g));
      return;
     }

   //--- expiry: server-side when the symbol supports it, else GTC / DAY as allowed (EA-side expiry)
   ENUM_ORDER_TYPE_TIME tt;
   datetime exp = 0;
   int exp_modes = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((exp_modes & SYMBOL_EXPIRATION_SPECIFIED) != 0 && InpOrderExpiryBars > 0)
     {
      tt  = ORDER_TIME_SPECIFIED;
      exp = sig.confirm_time + PeriodSeconds(TF) * (InpOrderExpiryBars + 1);
     }
   else if((exp_modes & SYMBOL_EXPIRATION_GTC) != 0)
      tt = ORDER_TIME_GTC;
   else if((exp_modes & SYMBOL_EXPIRATION_DAY) != 0)
      tt = ORDER_TIME_DAY;
   else
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + gctx, "NO_EXPIRATION_MODE expiration_mode=" + IntegerToString(exp_modes));
      return;
     }

   //--- no hedging (Upcomers): refuse when the symbol carries opposite exposure (any magic)
   string opp;
   if(RB_OppositeExposure(_Symbol, plan.dir, opp))
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + gctx + " " + opp, "OPPOSITE_EXPOSURE");
      return;
     }

   //--- account gate again right before sending (login / connection / mode may have changed)
   int perm = TradingPermission();
   if(perm != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + gctx, "PERMISSION " + RB_PermissionText(perm));
      return;
     }

   //--- send: prices on the symbol grid; RETURN filling for pending limits where allowed
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   double entry = NormalizeDouble(plan.entry, _Digits);
   double sl    = NormalizeDouble(plan.sl, _Digits);
   double tp    = NormalizeDouble(plan.tp, _Digits);
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE) != SYMBOL_TRADE_EXECUTION_MARKET)
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   bool sent = (plan.dir == RB_DIR_BULL)
               ? g_trade.BuyLimit(lots, entry, _Symbol, sl, tp, tt, exp, id)
               : g_trade.SellLimit(lots, entry, _Symbol, sl, tp, tt, exp, id);
   g_trade.SetTypeFillingBySymbol(_Symbol);   // back to the market-order filling for PositionClose
   uint rc = g_trade.ResultRetcode();
   ulong ticket = g_trade.ResultOrder();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED) || ticket == 0)
     {
      g_log.Log("ORDER_REJECTED", id, pctx + gctx, "retcode=" + IntegerToString((long)rc) + " " + g_trade.ResultRetcodeDescription());
      return;
     }
   g_meta.Set(ticket, "dir", plan.dir);
   g_meta.Set(ticket, "sid", RB_SID_RBOTE);
   g_meta.Set(ticket, "entry", entry);
   g_meta.Set(ticket, "sl", sl);
   g_meta.Set(ticket, "tp", tp);
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
   g_meta.Flush();
   // order SENT is logged here; the FILL is logged separately from OnTradeTransaction
   g_log.Log("ORDER_SENT", id, pctx + gctx + " ticket=" + IntegerToString((long)ticket) +
             (tt == ORDER_TIME_SPECIFIED ? " expires=" + TimeToString(exp) :
              tt == ORDER_TIME_DAY ? " DAY (EA-side expiry)" : " GTC (EA-side expiry, cancelled on EA removal)"), "OK");
  }

//+------------------------------------------------------------------+
//| DTBS: signal -> checks -> MARKET order (spec 02 sections 3-5)    |
//| Same pipeline as RBOTE: duplicate claim, regime, challenge, day  |
//| block, time/news filters, spread, plan (live bid/ask), market    |
//| checks, lots at InpDtbsRiskPct, margin, account-wide guard,      |
//| no-hedging check, account gate, send under InpMagicDTBS.         |
//| Regime: same allow/skip and risk multiplier as RBOTE; the RR     |
//| overrides (InpRR*Vol / InpRRRange) are RBOTE-scale R values and  |
//| are NOT applied: DTBS keeps InpDtbsRR (spec: 1.5).               |
//| Profit scaling uses the same formula with base InpDtbsRiskPct;   |
//| edge weighting (RBOTE setup features) is not applied (x1.00).    |
//+------------------------------------------------------------------+
void ProcessDtbsSignal(const RBDtbsSignal &sig, const CRBSeries &series)
  {
   string id = RB_DtbsSignalId(sig.dir, sig.break_time);
   string ctx = StringFormat("%s %s break trend=%s A[%s @%s] B[%s @%s] C[%s @%s] line=%s close=%s %s",
                             DirText(sig.dir), sig.with_trend ? "WITH_TREND" : "COUNTER", RB_DtbsTrendText(sig.main_trend),
                             DoubleToString(sig.a_price, _Digits), TimeToString(series.Time(sig.a_idx)),
                             DoubleToString(sig.b_price, _Digits), TimeToString(series.Time(sig.b_idx)),
                             DoubleToString(sig.c_price, _Digits),
                             TimeToString(series.Time(sig.b_idx) + (datetime)(PeriodSeconds(TF) * InpDtbsExtBars)),
                             DoubleToString(sig.line_at_break, _Digits), DoubleToString(series.C(sig.break_idx), _Digits),
                             sig.close_confirmed ? "CLOSE_CONFIRMED" : "WICK_ONLY");

   //--- duplicate guard (global variable + broker comments) and atomic claim
   if(g_meta.Processed(id) || RB_SignalExistsAtBroker(_Symbol, InpMagicDTBS, id, 7))
     {
      g_log.Log("SIGNAL_DUPLICATE", id, ctx, "already processed");
      return;
     }
   if(!g_meta.Claim(id))
     {
      g_log.Log("SIGNAL_DUPLICATE", id, ctx, "claimed by another EA instance (or claim failed, err=" +
                IntegerToString(GetLastError()) + ")");
      return;
     }
   g_meta.MarkProcessed(id);
   //--- regime at the break (closed) bar
   RBRegime reg;
   RB_ClassifyRegime(series, sig.break_idx, g_reg, reg);
   RBRegimeDecision rd;
   RB_RegimeDecide(reg, g_reg, InpDtbsRR, rd);
   ctx += StringFormat(" regime=%s VR=%.2f ER=%.2f", rd.reason, reg.vol_ratio, reg.er);
   g_log.Log("SIGNAL", id, ctx, "DTBS break confirmed");
   if(!rd.allow)
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, "REGIME_SKIP " + rd.reason);
      return;
     }
   RBDtbsConfig dcfg = g_dcfg;   // RR stays InpDtbsRR (regime RR overrides are RBOTE-scale, see header)

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
   if(!RB_ReadSymbolSpec(_Symbol, g_spec))
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx, "BAD_SYMBOL_SPEC " + RB_SpecText(g_spec));
      return;
     }

   //--- plan from the live price: buy at ask, sell at bid
   double live = sig.dir == RB_DIR_BULL ? tick.ask : tick.bid;
   RBPlan plan;
   int used_mode = -1;
   int r = RB_DtbsBuildPlanEx(sig, dcfg, g_spec, live, spread, plan, used_mode);
   if(r != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, ctx + StringFormat(" live=%s spread=%s atr=%s start=%s", DoubleToString(live, _Digits),
                DoubleToString(spread, _Digits), DoubleToString(sig.atr, _Digits),
                sig.start_valid ? DoubleToString(sig.start_price, _Digits) : "n/a"), RB_DtbsReasonText(r));
      return;
     }
   string pctx = StringFormat("entry=%s (market) sl=%s tp=%s risk_dist=%s (%s points) rr=%.2f sl_mode=%s",
                              DoubleToString(plan.entry, _Digits), DoubleToString(plan.sl, _Digits),
                              DoubleToString(plan.tp, _Digits), DoubleToString(plan.risk_dist, _Digits),
                              DoubleToString(plan.risk_dist / g_spec.point, 1), dcfg.rr, RB_DtbsSlModeText(used_mode));
   //--- broker minimum (stops + freeze level) and stop >= InpMinStopSpreadMult x spread
   r = RB_DtbsCheckMarket(plan, g_spec, tick.bid, tick.ask, InpMinStopSpreadMult);
   if(r != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + StringFormat(" bid=%s ask=%s", DoubleToString(tick.bid, _Digits),
                DoubleToString(tick.ask, _Digits)), RB_DtbsReasonText(r));
      return;
     }

   //--- lot size: same formula as RBOTE, base risk InpDtbsRiskPct
   double bal = AccountInfoDouble(ACCOUNT_BALANCE), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double ref_eq = MathMin(bal, eq);
   RBScaleCfg sc = g_scale;
   sc.base_pct = InpDtbsRiskPct / 100.0;
   string scale_why;
   double pct = RB_ProfitScaledPct(sc, g_lim.initial_balance, bal, GvGet("hwm", bal), ref_eq,
                                   (int)GvGet("consec_losses", 0.0), scale_why);
   double edge_mult = 1.0;
   double risk_money = RB_FinalRiskMoney(pct, ref_eq, rd.risk_mult, edge_mult, sc.max_pct);
   double stop_atr = sig.atr > 0.0 ? plan.risk_dist / sig.atr : 0.0;
   MqlDateTime sdt;
   TimeToStruct(ServerToUtc(sig.break_time + PeriodSeconds(TF)), sdt);
   RBFeatures feat;
   RB_MakeFeatures(sig.dir, -1, reg.valid ? reg.vol_class : RB_VOL_NORMAL, reg.ranging, sdt.hour, feat);
   string card = StringFormat("WHY: DTBS %s break (%s) main trend=%s (H1+H4 %s) A=%s B=%s C=%s (B+%d bars) line=%s "
                              "leg=%.2f ATR stop=%s %.2f ATR (start=%s candle=[%s..%s]) | regime=%s VR=%.2f ER=%.2f -> x%.2f rr=%.2f | "
                              "base=%.3f%% profit-scale=%s -> %.3f%% | edge=N/A x1.000 | final risk=%.2f (%.3f%% of %.2f)",
                              DirText(sig.dir), sig.with_trend ? "with trend" : "counter", RB_DtbsTrendText(sig.main_trend),
                              InpDtbsHtfAgree == RB_DTBS_HTF_ALL ? "ALL" : "MAJORITY",
                              DoubleToString(sig.a_price, _Digits), DoubleToString(sig.b_price, _Digits),
                              DoubleToString(sig.c_price, _Digits), InpDtbsExtBars, DoubleToString(sig.line_at_break, _Digits),
                              sig.atr > 0.0 ? MathAbs(sig.b_price - sig.a_price) / sig.atr : 0.0,
                              RB_DtbsSlModeText(used_mode), stop_atr,
                              sig.start_valid ? DoubleToString(sig.start_price, _Digits) : "n/a",
                              DoubleToString(sig.break_low, _Digits), DoubleToString(sig.break_high, _Digits),
                              rd.reason, reg.vol_ratio, reg.er, rd.risk_mult, dcfg.rr,
                              sc.base_pct * 100.0, scale_why, pct * 100.0, risk_money,
                              ref_eq > 0.0 ? risk_money / ref_eq * 100.0 : 0.0, ref_eq);
   g_log.Log("DECISION", id, card, "risk inputs");
   ENUM_ORDER_TYPE mtype = plan.dir == RB_DIR_BULL ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double tick_loss = RB_LossPerLot(plan.risk_dist, g_spec, InpCommissionPerLotRT, InpSlippageTicks);
   double calc_loss = RB_LossBetween(_Symbol, mtype, 1.0, plan.entry, plan.sl);
   double loss_per_lot = tick_loss;
   if(calc_loss > 0.0)
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

   //--- account-wide guard (daily / open risk / total DD shared); positions, pending and trades
   //--- per day are counted for the DTBS magic
   RBRiskSnapshot snap;
   string err;
   if(!RB_BuildSnapshot(InpMagicDTBS, InpCommissionPerLotRT, InpSlippageTicks, g_day_ref, ServerOffsetSec(), snap, err))
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx, "SNAPSHOT_FAILED " + err);
      return;
     }
   int g = RB_CheckNewOrder(g_lim, snap, trade_risk);
   string gctx = StringFormat(" lots=%.2f risk=%.2f realized=%.2f open=%.2f open_now=%.2f pending=%.2f day_ref=%.2f daily_limit=%.2f",
                              lots, trade_risk, snap.realized_today, snap.open_risk, snap.open_risk_now, snap.pending_risk,
                              snap.day_start_ref, RB_DailyLimitMoney(g_lim, snap));
   if(g != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + gctx, RB_GuardText(g));
      return;
     }
   string opp;
   if(RB_OppositeExposure(_Symbol, plan.dir, opp))
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + gctx + " " + opp, "OPPOSITE_EXPOSURE");
      return;
     }
   int perm = TradingPermission();
   if(perm != 0)
     {
      g_log.Log("SIGNAL_REJECTED", id, pctx + gctx, "PERMISSION " + RB_PermissionText(perm));
      return;
     }

   //--- send: market order under the DTBS magic, SL/TP from the plan
   double sl = NormalizeDouble(plan.sl, _Digits);
   double tp = NormalizeDouble(plan.tp, _Digits);
   g_trade.SetExpertMagicNumber((ulong)InpMagicDTBS);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   bool sent = (plan.dir == RB_DIR_BULL) ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, id)
                                         : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, id);
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   uint rc = g_trade.ResultRetcode();
   ulong ticket = g_trade.ResultOrder();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_DONE_PARTIAL && rc != TRADE_RETCODE_PLACED) || ticket == 0)
     {
      g_log.Log("ORDER_REJECTED", id, pctx + gctx, "retcode=" + IntegerToString((long)rc) + " " + g_trade.ResultRetcodeDescription());
      return;
     }
   double entry = NormalizeDouble(plan.entry, _Digits);
   g_meta.Set(ticket, "dir", plan.dir);
   g_meta.Set(ticket, "sid", RB_SID_DTBS);
   g_meta.Set(ticket, "entry", entry);
   g_meta.Set(ticket, "sl", sl);
   g_meta.Set(ticket, "tp", tp);
   g_meta.Set(ticket, "bar", (double)sig.break_time);
   g_meta.Set(ticket, "rbt", (double)sig.break_time);
   g_meta.Set(ticket, "risk", trade_risk);
   g_meta.Set(ticket, "atr", sig.atr);
   g_meta.Set(ticket, "zty", -1.0);
   g_meta.Set(ticket, "vr", reg.vol_ratio);
   g_meta.Set(ticket, "er", reg.er);
   g_meta.Set(ticket, "vc", reg.valid ? reg.vol_class : -1);
   g_meta.Set(ticket, "rng", reg.ranging ? 1.0 : 0.0);
   g_meta.Set(ticket, "rr", dcfg.rr);
   g_meta.Set(ticket, "rmul", rd.risk_mult);
   g_meta.Set(ticket, "pct", pct);
   g_meta.Set(ticket, "emul", edge_mult);
   g_meta.Set(ticket, "srs", ScaleReasonCode(scale_why));
   g_meta.Set(ticket, "zh", 0.0);
   g_meta.Set(ticket, "wr", 0.0);
   g_meta.Set(ticket, "rba", 0.0);
   g_meta.Set(ticket, "sta", stop_atr);
   g_meta.Set(ticket, "wt", sig.with_trend ? 1.0 : 0.0);
   g_meta.Set(ticket, "slm", used_mode);
   g_meta.Set(ticket, "mfe", 0.0);
   g_meta.Set(ticket, "mae", 0.0);
   for(int d = 0; d < RB_FEAT_DIMS; d++)
      g_meta.Set(ticket, "f" + IntegerToString(d), feat.b[d]);
   g_meta.Flush();
   g_log.Log("ORDER_SENT", id, pctx + gctx + " ticket=" + IntegerToString((long)ticket) +
             StringFormat(" market %s filled=%s", DirText(plan.dir), DoubleToString(g_trade.ResultPrice(), _Digits)), "OK");
  }

//+------------------------------------------------------------------+
//| DTBS evaluation on the closed-M15 window `rates` (fresh data).   |
//| Main trend per M15 bar = H1 and H4 trend of the last HTF bar     |
//| CLOSED at that M15 bar's close (RB_DtbsAlignTrend), combined     |
//| with InpDtbsHtfAgree. Acts only on a break of the last bar.      |
//+------------------------------------------------------------------+
//--- HTF freshness: the forming HTF bar must contain the close of the last closed M15 bar, so
//--- every HTF bar that closed by then is in the copied (closed-only) history. Unlike a fixed lag
//--- this also holds right after the weekend gap.
bool CopyHtfSeries(ENUM_TIMEFRAMES tf, datetime ltf_close, CRBSeries &out, bool connected, string &why)
  {
   out.Clear();
   int per = PeriodSeconds(tf);
   datetime cur = iTime(_Symbol, tf, 0);
   if(!connected || cur <= 0 || cur > ltf_close || ltf_close >= cur + per)
     {
      why = StringFormat("%s stale: forming bar %s, last M15 close %s", EnumToString(tf), TimeToString(cur),
                         TimeToString(ltf_close));
      return false;
     }
   MqlRates hr[];
   ArraySetAsSeries(hr, false);
   int hn = CopyRates(_Symbol, tf, 1, InpDtbsHtfBars, hr);   // start=1: closed HTF bars only
   if(hn < 4 * InpDtbsHtfSwingN + 20)
     {
      why = StringFormat("%s bars=%d err=%d", EnumToString(tf), hn, GetLastError());
      return false;
     }
   if(hr[hn - 1].time >= cur)
     {
      why = StringFormat("%s copy not closed-only: last %s forming %s", EnumToString(tf), TimeToString(hr[hn - 1].time),
                         TimeToString(cur));
      return false;
     }
   RBBar b;
   for(int i = 0; i < hn; i++)
     {
      b.time  = hr[i].time;
      b.open  = hr[i].open;
      b.high  = hr[i].high;
      b.low   = hr[i].low;
      b.close = hr[i].close;
      out.Add(b);
     }
   return true;
  }

void EvaluateDtbs(const MqlRates &rates[], int n, bool connected)
  {
   string why;
   CRBSeries h1, h4;
   datetime ltf_close = rates[n - 1].time + PeriodSeconds(TF);
   if(!CopyHtfSeries(PERIOD_H1, ltf_close, h1, connected, why) || !CopyHtfSeries(PERIOD_H4, ltf_close, h4, connected, why))
     {
      g_log.Log("DATA_INSUFFICIENT", "", "DTBS " + why, "no DTBS evaluation this bar", "DTBS");
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
   CRBVec<int> t1, t4, a1, a4, mt;
   RB_DtbsTrendSeries(h1, g_dcfg.htf_swing_n, t1);
   RB_DtbsTrendSeries(h4, g_dcfg.htf_swing_n, t4);
   RB_DtbsAlignTrend(s, PeriodSeconds(TF), h1, PeriodSeconds(PERIOD_H1), t1, a1);
   RB_DtbsAlignTrend(s, PeriodSeconds(TF), h4, PeriodSeconds(PERIOD_H4), t4, a4);
   RB_DtbsCombineSeries(a1, a4, g_dcfg.htf_agreement, mt);
   CRBVec<RBDtbsTriangle> tris;
   CRBVec<RBDtbsSignal>   sigs;
   RB_DtbsScanEx(s, mt, g_dcfg, tris, sigs);   // also computes ATR on s (regime uses it)

   RBDtbsSignal sig;
   for(int i = 0; i < sigs.Size(); i++)
     {
      sigs.Get(i, sig);
      if(sig.break_idx == n - 1)
         ProcessDtbsSignal(sig, s);
     }
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
   SweepClosed("BAR");
   CheckInactivity();
   CheckChallenge();
   UpdateHighWaterMark();

   //--- day limit: existing exposure already at the limit -> cancel pending, block the day
   RBRiskSnapshot snap;
   string err;
   if(RB_BuildSnapshot(InpMagic, InpCommissionPerLotRT, InpSlippageTicks, g_day_ref, ServerOffsetSec(), snap, err))
     {
      if(RB_DailyLimitBreached(g_lim, snap))
        {
         CancelAllPending("DAILY_LOSS_LIMIT");
         BlockToday(StringFormat("equity=%.2f day_ref=%.2f equity-day_ref=%.2f limit=%.2f", snap.equity, snap.day_start_ref,
                                 snap.equity - snap.day_start_ref, RB_DailyLimitMoney(g_lim, snap)));
        }
     }
   else
      g_log.Log("SNAPSHOT_FAILED", "", err, "daily-limit check skipped this bar; new orders are refused");
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
   if(InpEnableRBOTE)
     {
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
   //--- DTBS on the same closed-M15 window, same freshness rule (break bar = bar that just closed)
   if(InpEnableDTBS)
      EvaluateDtbs(rates, n, connected);
  }

void OnTick(void)
  {
   if(!g_ready)
     {
      if(g_wait_account)
         TryAccountInit();
      if(!g_ready)
         return;
     }
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

   //--- news window: cancel own pending orders (calendar read at most once per 60 s)
   if(InpNewsFilter && !g_tester && GetTickCount64() - g_news_ms >= 60000)
     {
      g_news_ms = GetTickCount64();
      if(OwnPendingCount() > 0)
        {
         string ev;
         if(RB_NewsBlocked(InpNewsCurrency, InpNewsMinutesBefore, InpNewsMinutesAfter, ev))
            CancelAllPending("NEWS " + ev);
        }
     }

   datetime t = iTime(_Symbol, TF, 0);
   if(t == 0 || t == g_last_bar)
      return;
   g_last_bar = t;
   OnNewBar();
  }

//+------------------------------------------------------------------+
//| Closed-trade accounting. Called from OnTradeTransaction and from |
//| the sweep (OnInit, every new bar) so manual closes, stop-outs and|
//| closes while the EA was off are booked exactly once (metadata is |
//| deleted afterwards). order_gone: caller knows the order is gone. |
//| Returns true when the position was booked.                       |
//+------------------------------------------------------------------+
bool ProcessClosedPosition(ulong pos, bool order_gone = false)
  {
   if(!g_meta.Has(pos) || PositionExistsById(pos))
      return false;
   if(!order_gone && OrderPending(pos))
      return false;   // remainder of a partially filled order still pending: book later
   if(!HistorySelectByPosition(pos))
      return false;
   double net = 0.0, in_vol = 0.0, out_vol = 0.0, in_px = 0.0, out_px = 0.0;
   datetime t_open = 0, t_close = 0;
   long last_reason = -1;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long   e = HistoryDealGetInteger(d, DEAL_ENTRY);
      double v = HistoryDealGetDouble(d, DEAL_VOLUME);
      double p = HistoryDealGetDouble(d, DEAL_PRICE);
      datetime dt = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
      net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
             HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      if(e == DEAL_ENTRY_IN)
        {
         in_vol += v;
         in_px  += p * v;
         if(t_open == 0 || dt < t_open)
            t_open = dt;
        }
      else if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY || e == DEAL_ENTRY_INOUT)
        {
         out_vol += v;
         out_px  += p * v;
         if(dt >= t_close)
           {
            t_close     = dt;
            last_reason = HistoryDealGetInteger(d, DEAL_REASON);
           }
        }
     }
   if(!(in_vol > 0.0) || out_vol < in_vol - 1e-8)
      return false;   // never filled, or not fully closed yet
   double fill = in_px / in_vol;      // volume-weighted entry
   double px   = out_px / out_vol;    // volume-weighted exit

   int sid     = MetaSid(pos);
   string id   = MetaSignalId(pos);
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
   row.volume          = in_vol;
   row.risk_money      = risk;
   row.net             = net;
   row.r               = rr;
   row.signal_id       = id;
   row.atr             = g_meta.Get(pos, "atr");
   row.zone_type       = (int)g_meta.Get(pos, "zty");
   row.rr              = g_meta.Get(pos, "rr");
   row.stop_mode       = sid == RB_SID_DTBS ? -1 : (int)InpRbStopMode;   // RBOTE column; DTBS sl mode is in the journal
   row.exit_price      = px;
   row.vol_class       = (int)g_meta.Get(pos, "vc");
   row.ranging         = g_meta.Get(pos, "rng") > 0.5;
   row.vol_ratio       = g_meta.Get(pos, "vr");
   row.er              = g_meta.Get(pos, "er");
   row.risk_mult       = g_meta.Get(pos, "rmul");
   row.exit_reason     = ExitReasonText(last_reason);
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
   row.strategy        = RB_StrategyText(sid);
   if(sid == RB_SID_DTBS)
     {
      row.zone_type = -1;   // RBOTE-only columns: no PD array / rejection block
      row.zones_hit = 0;
      row.wick_ratio = 0.0;
      row.rb_range_atr = 0.0;
     }

   //--- outcome explanation: what happened and under which conditions
   RBFeatures feat;
   ZeroMemory(feat);
   for(int d = 0; d < RB_FEAT_DIMS; d++)   // clamp: a damaged global variable must not index out of range
      feat.b[d] = (int)MathMax(0, MathMin(RB_FEAT_BUCKETS - 1, (int)g_meta.Get(pos, "f" + IntegerToString(d))));
   string cond = "";
   for(int d = 0; d < RB_FEAT_DIMS; d++)
      cond += (d > 0 ? (string)" " : (string)"") + RB_DimText(d) + "=" + RB_BucketText(d, feat.b[d]);
   string outcome = rr > 0.0 ? "WIN" : "LOSS";
   string story;
   if(sid == RB_SID_DTBS)
      story = StringFormat("%s %.2fR by %s | went +%.2fR / %.2fR before exit | DTBS %s break sl_mode=%s stop=%.2f ATR | "
                           "regime=%s%s | risk %.3f%% (%s, regime x%.2f)",
                           outcome, rr, row.exit_reason, row.mfe_r, row.mae_r,
                           g_meta.Get(pos, "wt") > 0.5 ? "with-trend" : "counter",
                           RB_DtbsSlModeText((int)g_meta.Get(pos, "slm")), row.stop_atr,
                           row.vol_class < 0 ? "UNKNOWN" : RB_VolText(row.vol_class), row.ranging ? "+RANGE" : "",
                           row.risk_pct * 100.0, row.scale_reason, row.risk_mult);
   else
      story = StringFormat("%s %.2fR by %s | went +%.2fR / %.2fR before exit | %s | zone hits=%d wick=%.0f%% "
                           "RB=%.2f ATR stop=%.2f ATR | filled after %d bars | risk %.3f%% (%s, edge x%.2f, regime x%.2f)",
                           outcome, rr, row.exit_reason, row.mfe_r, row.mae_r, cond, row.zones_hit,
                           row.wick_ratio * 100.0, row.rb_range_atr, row.stop_atr, row.fill_delay_bars,
                           row.risk_pct * 100.0, row.scale_reason, row.edge_mult, row.risk_mult);
   g_log.Log("CLOSED", id, StringFormat("position %I64u exit=%s (vol-weighted) net=%.2f risk=%.2f", pos,
             DoubleToString(px, _Digits), net, risk), story);
   g_log.Trade(row);

   //--- learn from the closed trade (past trades only -> no lookahead). The edge buckets describe
   //--- RBOTE setups (zone type ...), so only RBOTE trades feed them; the loss streak is account-wide.
   if(sid != RB_SID_DTBS)
     {
      g_stats.Add(feat, rr);
      SaveEdgeStats();
     }
   GvSet("consec_losses", net < 0.0 ? GvGet("consec_losses", 0.0) + 1.0 : 0.0);
   GvSet("last_close", (double)TimeCurrent());
   UpdateHighWaterMark();
   g_meta.Delete(pos);   // flushes
   return true;
  }

//--- metadata whose order and position are gone: book the closed trade, or drop the record
//--- of an order that ended unfilled (cancelled / expired / rejected while the EA was off)
void SweepClosed(const string when)
  {
   ulong tickets[];
   int n = g_meta.Tickets(tickets);
   for(int i = 0; i < n; i++)
     {
      ulong t = tickets[i];
      if(PositionExistsById(t) || OrderPending(t))
         continue;
      if(ProcessClosedPosition(t))
        {
         g_log.Log("SWEEP_BOOKED", "", when + " position " + IntegerToString((long)t), "closed trade booked from history");
         continue;
        }
      //--- no fill in history: drop only when the order is in history with a final state
      if(!HistoryOrderSelect(t))
         continue;
      long st = HistoryOrderGetInteger(t, ORDER_STATE);
      if(st == ORDER_STATE_CANCELED || st == ORDER_STATE_EXPIRED || st == ORDER_STATE_REJECTED)
        {
         g_log.Log("SWEEP_CLEANUP", HistoryOrderGetString(t, ORDER_COMMENT), when + " order " + IntegerToString((long)t),
                   "ended unfilled (" + EnumToString((ENUM_ORDER_STATE)st) + "): metadata removed");
         g_meta.Delete(t);
        }
     }
  }

//+------------------------------------------------------------------+
//| Fills and closes, from broker deals. Our trades are recognised   |
//| by their metadata (POSITION_ID), not by DEAL_MAGIC: manual and   |
//| stop-out closes carry magic 0.                                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(g_prefix == "")
      return;   // account init not done yet
   if(trans.type == TRADE_TRANSACTION_HISTORY_ADD &&
      (trans.order_state == ORDER_STATE_CANCELED || trans.order_state == ORDER_STATE_EXPIRED ||
       trans.order_state == ORDER_STATE_REJECTED) && g_meta.Has(trans.order))
     {
      g_log.Log(trans.order_state == ORDER_STATE_EXPIRED ? "ORDER_EXPIRED" : "ORDER_CLOSED_UNFILLED",
                "", "ticket " + IntegerToString((long)trans.order), EnumToString(trans.order_state));
      ReleaseOrderMeta(trans.order);   // keeps the record while a partial-fill position exists
      return;
     }
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   ulong pos = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   if(!g_meta.Has(pos))
      return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      double px      = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      double planned = g_meta.Get(pos, "entry");
      string id      = MetaSignalId(pos);
      g_log.Log("FILLED", id, StringFormat("position %I64u price=%s planned=%s slippage=%s vol=%.2f", pos,
                DoubleToString(px, _Digits), DoubleToString(planned, _Digits),
                DoubleToString(px - planned, _Digits), HistoryDealGetDouble(trans.deal, DEAL_VOLUME)), "OK");
      return;
     }
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
      return;
   ProcessClosedPosition(pos);   // no-op while partially closed or the order remainder is pending
  }

//+------------------------------------------------------------------+
//| Strategy Tester summary (net R statistics from broker deals)     |
//+------------------------------------------------------------------+
//--- per-strategy closed trades and net profit from the deal history: a position belongs to the
//--- strategy whose magic opened it (closing deals by SL/TP/stop-out may carry another magic)
void StrategyTotals(int &n_rb, double &net_rb, int &n_dt, double &net_dt, int &n_other, double &net_other)
  {
   n_rb = n_dt = n_other = 0;
   net_rb = net_dt = net_other = 0.0;
   if(!HistorySelect(0, TimeCurrent() + 86400))
      return;
   int total = HistoryDealsTotal();
   long pid[], pmag[];
   int np = 0;
   ArrayResize(pid, 0, 1024);
   ArrayResize(pmag, 0, 1024);
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0 || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      ArrayResize(pid, np + 1, 1024);
      ArrayResize(pmag, np + 1, 1024);
      pid[np]  = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      pmag[np] = HistoryDealGetInteger(d, DEAL_MAGIC);
      np++;
     }
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      long p = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      long m = HistoryDealGetInteger(d, DEAL_MAGIC);
      for(int j = 0; j < np; j++)
         if(pid[j] == p)
           {
            m = pmag[j];
            break;
           }
      double v = HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                 HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      bool out = (e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY || e == DEAL_ENTRY_INOUT);
      if(m == InpMagic)
        {
         net_rb += v;
         if(out) n_rb++;
        }
      else if(m == InpMagicDTBS)
        {
         net_dt += v;
         if(out) n_dt++;
        }
      else
        {
         net_other += v;
         if(out) n_other++;
        }
     }
  }

double OnTester(void)
  {
   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double net    = TesterStatistics(STAT_PROFIT);
   PrintFormat("[RBOTE] tester: trades=%.0f net=%.2f PF=%.2f maxEquityDD=%.2f%% rr=%.1f stop_mode=%s; trades file: Common\\Files\\%s",
               trades, net, pf, dd, InpRR, EnumToString(InpRbStopMode), g_log.TradesFile());
   int n_rb, n_dt, n_ot;
   double net_rb, net_dt, net_ot;
   StrategyTotals(n_rb, net_rb, n_dt, net_dt, n_ot, net_ot);
   PrintFormat("[RBOTE] tester per strategy: RBOTE(%s, magic %I64d) trades=%d net=%.2f | DTBS(%s, magic %I64d) trades=%d net=%.2f | "
               "other trades=%d net=%.2f | total trades=%d net=%.2f (closing deals, incl. commission/swap)",
               InpEnableRBOTE ? "on" : "off", InpMagic, n_rb, net_rb, InpEnableDTBS ? "on" : "off", InpMagicDTBS, n_dt, net_dt,
               n_ot, net_ot, n_rb + n_dt + n_ot, net_rb + net_dt + net_ot);
   // custom criterion: net profit per trade, 0 when the sample is too small to mean anything
   if(trades < 30)
      return 0.0;
   return net / trades;
  }
//+------------------------------------------------------------------+
