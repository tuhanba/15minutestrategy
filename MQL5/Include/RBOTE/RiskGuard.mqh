//+------------------------------------------------------------------+
//| RiskGuard.mqh - personal / prop-style risk limits (pure logic)   |
//|                                                                  |
//| These are TEST limits, not any prop firm's official rules.       |
//|                                                                  |
//| Each risk is counted exactly once:                               |
//|  realized_today  : closed P/L since day start (commission, swap) |
//|  open_risk       : for each open position, loss from its OPEN    |
//|                    price to its SL (already includes floating)   |
//|  pending_risk    : for each pending order, loss from order price |
//|                    to its SL                                     |
//|  new_risk        : the order being evaluated                     |
//+------------------------------------------------------------------+
#ifndef RBOTE_RISKGUARD_MQH
#define RBOTE_RISKGUARD_MQH

#include "Compat.mqh"

struct RBRiskLimits
  {
   double risk_pct;              // per trade, fraction of equity reference (0.0025)
   double daily_loss_pct;        // fraction of day-start reference (0.01)
   double max_open_risk_pct;     // open + pending + new, fraction of equity (0.005)
   double max_total_dd_pct;      // from initial balance, 0 = off
   double initial_balance;       // reference for total DD (0 = off)
   bool   trailing_dd;           // floor follows the equity peak (Upcomers Ash "Dynamic Risk Shield")
   double peak_equity;           // highest equity seen (trailing mode)
   bool   daily_on_initial;      // daily limit amount = pct * initial balance (Ash Turbo: 3% of initial)
   int    max_trades_per_day;    // filled entries per day, 0 = off
   int    max_positions;         // open positions of this EA, 0 = off
   int    max_pending;           // pending orders of this EA, 0 = off

   void              Defaults(void)
     {
      risk_pct           = 0.0025;
      daily_loss_pct     = 0.01;
      max_open_risk_pct  = 0.005;
      max_total_dd_pct   = 0.0;
      initial_balance    = 0.0;
      trailing_dd        = false;
      peak_equity        = 0.0;
      daily_on_initial   = false;
      max_trades_per_day = 3;
      max_positions      = 1;
      max_pending        = 1;
     }
  };

struct RBRiskSnapshot
  {
   double balance;
   double equity;
   double day_start_ref;         // max(balance, equity) at 00:00 UTC (firm reference)
   double realized_today;        // signed; losses negative (reporting only)
   double open_risk;             // >= 0, loss from OPEN price to SL (+ costs): exposure / DD caps
   double open_risk_now;         // >= 0, loss from CURRENT price to SL (+ costs): daily worst case
   double pending_risk;          // >= 0
   int    trades_today;
   int    positions;
   int    pending;
   bool   unprotected_position;  // a position without SL exists
  };

//--- per-trade risk budget in account currency: risk_pct * min(balance, equity)
double RB_RiskMoney(const RBRiskLimits &lim, double balance, double equity)
  {
   double ref = MathMin(balance, equity);
   if(!(ref > 0.0))
      return 0.0;
   return lim.risk_pct * ref;
  }

string RB_GuardText(int code)
  {
   switch(code)
     {
      case 0: return "ALLOW";
      case 1: return "UNPROTECTED_POSITION";
      case 2: return "DAILY_LOSS_LIMIT";
      case 3: return "MAX_OPEN_RISK";
      case 4: return "MAX_TOTAL_DRAWDOWN";
      case 5: return "MAX_TRADES_PER_DAY";
      case 6: return "MAX_POSITIONS";
      case 7: return "MAX_PENDING";
      case 8: return "BAD_ACCOUNT_STATE";
     }
   return "UNKNOWN";
  }

//--- total drawdown floor. Static: initial*(1-dd). Trailing: peak - dd*initial,
//--- never below the static floor and locked at the initial balance (Ash challenge rule).
double RB_TotalDDFloor(const RBRiskLimits &lim)
  {
   double static_floor = lim.initial_balance * (1.0 - lim.max_total_dd_pct);
   if(!lim.trailing_dd)
      return static_floor;
   double trail = lim.peak_equity - lim.max_total_dd_pct * lim.initial_balance;
   return MathMin(lim.initial_balance, MathMax(static_floor, trail));
  }

//--- daily loss allowance in money
double RB_DailyLimitMoney(const RBRiskLimits &lim, const RBRiskSnapshot &s)
  {
   double base = (lim.daily_on_initial && lim.initial_balance > 0.0) ? lim.initial_balance : s.day_start_ref;
   return lim.daily_loss_pct * base;
  }

//--- 0 = allow, otherwise the denial reason code
int RB_CheckNewOrder(const RBRiskLimits &lim, const RBRiskSnapshot &s, double new_risk)
  {
   if(!(s.equity > 0.0) || !(s.balance > 0.0) || !(s.day_start_ref > 0.0) || new_risk < 0.0)
      return 8;
   if(s.unprotected_position)
      return 1;
   // daily: worst-case equity if every stop is hit, measured against the firm's day reference
   // (equity-based, so overnight floating profit/loss is counted exactly once)
   double worst_eq = s.equity - s.open_risk_now - s.pending_risk - new_risk;
   if(worst_eq < s.day_start_ref - RB_DailyLimitMoney(lim, s) - 1e-6)
      return 2;
   if(lim.max_open_risk_pct > 0.0 &&
      s.open_risk + s.pending_risk + new_risk > lim.max_open_risk_pct * s.equity + 1e-6)
      return 3;
   if(lim.max_total_dd_pct > 0.0 && lim.initial_balance > 0.0)
     {
      double floor_eq = RB_TotalDDFloor(lim);
      if(s.equity - s.open_risk - s.pending_risk - new_risk < floor_eq - 1e-6)
         return 4;
     }
   if(lim.max_trades_per_day > 0 && s.trades_today >= lim.max_trades_per_day)
      return 5;
   if(lim.max_positions > 0 && s.positions >= lim.max_positions)
      return 6;
   if(lim.max_pending > 0 && s.pending >= lim.max_pending)
      return 7;
   return 0;
  }

//+------------------------------------------------------------------+
//| Challenge state (Upcomers Ash Turbo: 2% target, max 7 trading    |
//| days = days with a closed trade, within 30 calendar days).       |
//+------------------------------------------------------------------+
#define RB_CH_CONTINUE  0
#define RB_CH_TARGET    1   // target reached: stop opening trades
#define RB_CH_DAYS_USED 2   // all trading days used without reaching the target
#define RB_CH_EXPIRED   3   // calendar limit passed

string RB_ChallengeText(int s)
  {
   switch(s)
     {
      case RB_CH_CONTINUE:  return "CONTINUE";
      case RB_CH_TARGET:    return "TARGET_REACHED";
      case RB_CH_DAYS_USED: return "TRADING_DAYS_USED";
      case RB_CH_EXPIRED:   return "CHALLENGE_EXPIRED";
     }
   return "UNKNOWN";
  }

//--- today_counted: a trade already closed today, so today is one of the active_days
//--- (more trades may still be taken today without using a new trading day)
int RB_ChallengeState(double balance, double initial, double target_pct, int active_days, bool today_counted,
                      int max_days, datetime now, datetime end)
  {
   if(target_pct > 0.0 && initial > 0.0 && balance >= initial * (1.0 + target_pct) - 1e-6)
      return RB_CH_TARGET;
   if(end > 0 && now >= end)
      return RB_CH_EXPIRED;
   if(max_days > 0 && (active_days > max_days || (active_days == max_days && !today_counted)))
      return RB_CH_DAYS_USED;
   return RB_CH_CONTINUE;
  }

//--- true when current equity already reached the daily limit below the day reference
//--- (used to cancel pending orders and stop new ones for the rest of the day)
bool RB_DailyLimitBreached(const RBRiskLimits &lim, const RBRiskSnapshot &s)
  {
   return s.equity - s.day_start_ref <= -RB_DailyLimitMoney(lim, s) + 1e-6;
  }

#endif
