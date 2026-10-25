//+------------------------------------------------------------------+
//| TradeMath.mqh - Fibonacci entry, SL/TP, unit conversion, lots    |
//| Pure logic.                                                      |
//|                                                                  |
//| Fibonacci is drawn on the RB boundaries only (never a swing leg):|
//|   bull: 1 = RB low (wick), 0 = RB high (body low)                |
//|         Entry = H - f * (H - L)        -> Buy Limit              |
//|   bear: 1 = RB high (wick), 0 = RB low (body high)               |
//|         Entry = L + f * (H - L)        -> Sell Limit             |
//|   RiskDistance = |Entry - SL|,  TP = Entry +/- rr * RiskDistance |
//+------------------------------------------------------------------+
#ifndef RBOTE_TRADEMATH_MQH
#define RBOTE_TRADEMATH_MQH

#include "Config.mqh"

#define RB_EPS 1e-9

//--- reject reasons (logged as text)
string RB_ReasonText(int code)
  {
   switch(code)
     {
      case 0:  return "OK";
      case 1:  return "BAD_RB_RANGE";
      case 2:  return "BAD_FIB_LEVEL";
      case 3:  return "ENTRY_OUTSIDE_RB";
      case 4:  return "STOP_UNIT_NOT_SET";
      case 5:  return "BAD_STOP_DISTANCE";
      case 6:  return "SL_WRONG_SIDE";
      case 7:  return "SL_INSIDE_RB";
      case 8:  return "TP_WRONG_SIDE";
      case 9:  return "BAD_SYMBOL_SPEC";
      case 10: return "LIMIT_PRICE_WRONG_SIDE";
      case 11: return "STOP_BELOW_BROKER_MIN";
      case 12: return "STOP_TOO_CLOSE_TO_SPREAD";
      case 13: return "ENTRY_TOO_CLOSE_TO_PRICE";
      case 14: return "LOT_BELOW_MIN";
      case 15: return "RISK_EXCEEDED_AFTER_ROUNDING";
      case 16: return "BAD_LOSS_PER_LOT";
      case 17: return "BAD_RISK_MONEY";
      case 18: return "BAD_RR";
      case 19: return "STOP_TOO_WIDE_ATR";
     }
   return "UNKNOWN";
  }

//--- 0 when the symbol specification is usable, else 9 (BAD_SYMBOL_SPEC)
int RB_ValidateSpec(const RBSymbolSpec &sp)
  {
   if(sp.digits < 0 || sp.digits > 8)              return 9;
   if(!(sp.point > 0.0) || !(sp.tick_size > 0.0))  return 9;
   if(sp.tick_size + RB_EPS < sp.point)            return 9;
   if(!(sp.tick_value_loss > 0.0))                 return 9;
   if(!(sp.vol_min > 0.0) || !(sp.vol_step > 0.0)) return 9;
   if(sp.vol_max < sp.vol_min)                     return 9;
   if(sp.stops_level < 0 || sp.freeze_level < 0)  return 9;
   if(!MathIsValidNumber(sp.point) || !MathIsValidNumber(sp.tick_size) ||
      !MathIsValidNumber(sp.tick_value_loss))
      return 9;
   return 0;
  }

//--- distance expressed in a unit -> price distance. Returns -1 when the unit is unknown.
double RB_DistanceToPrice(double value, int unit, const RBSymbolSpec &sp)
  {
   if(unit == RB_UNIT_PRICE)  return value;
   if(unit == RB_UNIT_POINTS) return value * sp.point;
   if(unit == RB_UNIT_TICKS)  return value * sp.tick_size;
   return -1.0;
  }

double RB_RoundDownToTick(double price, double tick) { return MathFloor(price / tick + RB_EPS) * tick; }
double RB_RoundUpToTick(double price, double tick)   { return MathCeil(price / tick - RB_EPS) * tick; }
double RB_RoundToTick(double price, double tick)     { return MathRound(price / tick) * tick; }

//--- Fibonacci entry on the RB boundaries (no rounding).
double RB_FibEntry(int dir, double rb_low, double rb_high, double f)
  {
   if(dir == RB_DIR_BULL)
      return rb_high - f * (rb_high - rb_low);
   return rb_low + f * (rb_high - rb_low);
  }

//+------------------------------------------------------------------+
//| Build Entry/SL/TP. Returns 0 on success or a reason code.        |
//+------------------------------------------------------------------+
int RB_BuildPlan(const RBSignal &sig, const RBConfig &cfg, const RBSymbolSpec &sp, RBPlan &plan)
  {
   if(RB_ValidateSpec(sp) != 0)
      return 9;
   double L = sig.rb_low, H = sig.rb_high;
   if(!(H > L) || (H - L) < cfg.rb_min_range_ticks * sp.tick_size - RB_EPS)
      return 1;
   if(!(cfg.fib_level > 0.0 && cfg.fib_level < 1.0))
      return 2;
   if(!(cfg.rr > 0.0))
      return 18;

   int dir = sig.dir;
   double raw = RB_FibEntry(dir, L, H, cfg.fib_level);
   // Buy limit rounds down, sell limit rounds up: never a worse price than the level.
   double entry = (dir == RB_DIR_BULL) ? RB_RoundDownToTick(raw, sp.tick_size)
                                       : RB_RoundUpToTick(raw, sp.tick_size);
   if(!(entry > L - RB_EPS && entry < H + RB_EPS))
      return 3;

   double dist;
   double sl;
   if(cfg.stop_mode == RB_STOP_FIXED)
     {
      if(cfg.stop_unit < 0)
         return 4;
      dist = RB_DistanceToPrice(cfg.stop_distance, cfg.stop_unit, sp);
      if(!(dist > 0.0))
         return 5;
      // SL is rounded TOWARD the entry: rounding never widens the stop.
      sl = (dir == RB_DIR_BULL) ? RB_RoundUpToTick(entry - dist, sp.tick_size)
                                : RB_RoundDownToTick(entry + dist, sp.tick_size);
      if(cfg.require_sl_beyond_rb)
        {
         if(dir == RB_DIR_BULL && sl > L + RB_EPS)
            return 7;
         if(dir == RB_DIR_BEAR && sl < H - RB_EPS)
            return 7;
        }
     }
   else
     {
      if(cfg.structural_buffer < 0.0)
         return 5;
      sl = (dir == RB_DIR_BULL) ? RB_RoundDownToTick(L - cfg.structural_buffer, sp.tick_size)
                                : RB_RoundUpToTick(H + cfg.structural_buffer, sp.tick_size);
     }
   if(dir == RB_DIR_BULL && !(sl < entry))
      return 6;
   if(dir == RB_DIR_BEAR && !(sl > entry))
      return 6;

   double risk = MathAbs(entry - sl);
   if(risk < sp.tick_size - RB_EPS)
      return 5;
   // Structural stop on an oversized RB: lot would collapse and the setup is atypical, skip it.
   if(cfg.stop_mode == RB_STOP_STRUCTURAL && cfg.max_stop_atr > 0.0 && sig.atr > 0.0
      && risk > cfg.max_stop_atr * sig.atr + RB_EPS)
      return 19;
   double tp = (dir == RB_DIR_BULL) ? entry + cfg.rr * risk : entry - cfg.rr * risk;
   tp = RB_RoundToTick(tp, sp.tick_size);
   if(dir == RB_DIR_BULL && !(tp > entry))
      return 8;
   if(dir == RB_DIR_BEAR && !(tp < entry))
      return 8;

   plan.dir       = dir;
   plan.entry     = entry;
   plan.sl        = sl;
   plan.tp        = tp;
   plan.risk_dist = risk;
   plan.fib_level = cfg.fib_level;
   return 0;
  }

//+------------------------------------------------------------------+
//| Market checks right before sending the limit order.              |
//|  bid/ask = current quotes, spread = ask - bid                    |
//+------------------------------------------------------------------+
int RB_CheckMarket(const RBPlan &plan, const RBConfig &cfg, const RBSymbolSpec &sp,
                   double bid, double ask)
  {
   double spread    = ask - bid;
   double min_level = (sp.stops_level + sp.freeze_level) * sp.point;
   // Buy limit must be below Ask, sell limit above Bid.
   if(plan.dir == RB_DIR_BULL && !(plan.entry < ask))
      return 10;
   if(plan.dir == RB_DIR_BEAR && !(plan.entry > bid))
      return 10;
   if(plan.risk_dist + RB_EPS < min_level)
      return 11;
   if(MathAbs(plan.tp - plan.entry) + RB_EPS < min_level)
      return 11;
   if(plan.risk_dist + RB_EPS < cfg.min_stop_spread_mult * spread)
      return 12;
   double gap = (plan.dir == RB_DIR_BULL) ? ask - plan.entry : plan.entry - bid;
   if(gap + RB_EPS < min_level)
      return 13;
   return 0;
  }

//+------------------------------------------------------------------+
//| Loss of 1 lot when SL is hit, from tick math, plus costs.        |
//|  price part = |entry - sl| / tick_size * tick_value_loss         |
//|  + commission (round turn, per lot) + slippage ticks * tick value|
//+------------------------------------------------------------------+
double RB_LossPerLot(double risk_dist, const RBSymbolSpec &sp,
                     double commission_rt_per_lot, double slippage_ticks)
  {
   double ticks = risk_dist / sp.tick_size;
   return ticks * sp.tick_value_loss + commission_rt_per_lot + slippage_ticks * sp.tick_value_loss;
  }

//+------------------------------------------------------------------+
//| Lot size. lots = floor(risk_money / loss_per_lot / step) * step  |
//| capped at min(vol_max, max_lots). Never rounded up.              |
//+------------------------------------------------------------------+
int RB_CalcLots(double risk_money, double loss_per_lot, const RBSymbolSpec &sp,
                double max_lots, double &lots)
  {
   lots = 0.0;
   if(!(risk_money > 0.0))
      return 17;
   if(!(loss_per_lot > 0.0) || !MathIsValidNumber(loss_per_lot))
      return 16;
   double raw = risk_money / loss_per_lot;
   double cap = sp.vol_max;
   if(max_lots > 0.0)
      cap = MathMin(cap, max_lots);
   raw = MathMin(raw, cap);
   double steps = MathFloor(raw / sp.vol_step + RB_EPS);
   double v = steps * sp.vol_step;
   // guard against representation error pushing v above raw
   if(v > raw + RB_EPS)
      v -= sp.vol_step;
   if(v + RB_EPS < sp.vol_min)
      return 14;
   if(v * loss_per_lot > risk_money + 1e-6)
      return 15;
   lots = v;
   return 0;
  }

#endif
