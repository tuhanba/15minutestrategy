//+------------------------------------------------------------------+
//| TradeMgmt.mqh - open-position management (pure logic)            |
//|                                                                  |
//| All levels are in R of the ORIGINAL risk distance |entry - sl0|. |
//|  breakeven : when the best favourable excursion >= be_at_r,      |
//|              SL -> entry + dir * be_offset_r * R                 |
//|  trailing  : when best excursion >= trail_start_r,               |
//|              SL -> best_price - dir * trail_dist_r * R           |
//|  partial   : close partial_frac of the volume once at +partial_at_r |
//| The stop only ever moves in the position's favour.               |
//| Every feature is OFF by default (source strategy = plain SL/TP). |
//+------------------------------------------------------------------+
#ifndef RBOTE_TRADEMGMT_MQH
#define RBOTE_TRADEMGMT_MQH

#include "Safety.mqh"

struct RBMgmtCfg
  {
   double be_at_r;        // 0 = off
   double be_offset_r;    // e.g. 0.1 to cover costs
   double trail_start_r;  // 0 = off
   double trail_dist_r;
   double partial_at_r;   // 0 = off
   double partial_frac;   // 0..1

   void              Defaults(void)
     {
      be_at_r       = 0.0;
      be_offset_r   = 0.0;
      trail_start_r = 0.0;
      trail_dist_r  = 0.0;
      partial_at_r  = 0.0;
      partial_frac  = 0.0;
     }
  };

//--- best favourable excursion in R
double RB_MgmtExcursionR(int dir, double entry, double best_price, double risk0)
  {
   if(!(risk0 > 0.0))
      return 0.0;
   return (dir == RB_DIR_BULL ? best_price - entry : entry - best_price) / risk0;
  }

//--- the stop that management wants now; never worse than sl_now
double RB_MgmtStop(int dir, double entry, double sl_now, double risk0, double best_price,
                   const RBMgmtCfg &c, double tick)
  {
   double fav = RB_MgmtExcursionR(dir, entry, best_price, risk0);
   double sl = sl_now;
   if(c.be_at_r > 0.0 && fav >= c.be_at_r)
     {
      double be = entry + dir * c.be_offset_r * risk0;
      if(RB_SlChangeAllowed(dir, sl, be))
         sl = be;
     }
   if(c.trail_start_r > 0.0 && c.trail_dist_r > 0.0 && fav >= c.trail_start_r)
     {
      double tr = best_price - dir * c.trail_dist_r * risk0;
      if(RB_SlChangeAllowed(dir, sl, tr))
         sl = tr;
     }
   if(tick > 0.0 && sl != sl_now)
      sl = (dir == RB_DIR_BULL) ? MathFloor(sl / tick + 1e-9) * tick : MathCeil(sl / tick - 1e-9) * tick;
   if(!RB_SlChangeAllowed(dir, sl_now, sl))
      return sl_now;
   return sl;
  }

//--- volume to close for the partial (0 = none). Remaining volume must stay >= vol_min.
double RB_MgmtPartialVolume(double volume, const RBMgmtCfg &c, double vol_min, double vol_step)
  {
   if(!(c.partial_at_r > 0.0) || !(c.partial_frac > 0.0) || c.partial_frac >= 1.0 || !(vol_step > 0.0))
      return 0.0;
   double v = MathFloor(volume * c.partial_frac / vol_step + 1e-9) * vol_step;
   if(v + 1e-9 < vol_min || volume - v + 1e-9 < vol_min)
      return 0.0;
   return v;
  }

double RB_MgmtPartialPrice(int dir, double entry, double risk0, const RBMgmtCfg &c)
  {
   return entry + dir * c.partial_at_r * risk0;
  }

#endif
