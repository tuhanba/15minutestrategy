//+------------------------------------------------------------------+
//| Regime.mqh - volatility / range classification and per-regime    |
//| trading policy (pure logic, closed bars only).                   |
//|                                                                  |
//| Volatility ratio  VR = ATR14(M15)[k] / mean(ATR14 over the last  |
//|                        atr_lookback bars up to k)                |
//|   EXTREME : VR >= extreme_thr   (news spikes, crashes)           |
//|   HIGH    : VR >= high_thr                                       |
//|   LOW     : VR <= low_thr                                        |
//|   NORMAL  : otherwise                                            |
//| Range (sideways) market, Kaufman efficiency ratio over N bars:   |
//|   ER = |C[k] - C[k-N]| / sum |C[i] - C[i-1]|   (0 = chop, 1 = trend)|
//|   RANGING : ER <= range_er                                       |
//|                                                                  |
//| The source strategy defines no regime rules. Every threshold and |
//| policy below is a configurable ASSUMPTION to be validated with   |
//| the per-regime backtest breakdown.                               |
//+------------------------------------------------------------------+
#ifndef RBOTE_REGIME_MQH
#define RBOTE_REGIME_MQH

#include "Types.mqh"

#define RB_VOL_NORMAL  0
#define RB_VOL_LOW     1
#define RB_VOL_HIGH    2
#define RB_VOL_EXTREME 3

string RB_VolText(int c)
  {
   switch(c)
     {
      case RB_VOL_NORMAL:  return "NORMAL";
      case RB_VOL_LOW:     return "LOW";
      case RB_VOL_HIGH:    return "HIGH";
      case RB_VOL_EXTREME: return "EXTREME";
     }
   return "UNKNOWN";
  }

struct RBRegime
  {
   bool   valid;
   double vol_ratio;
   double er;
   int    vol_class;   // RB_VOL_*
   bool   ranging;
  };

struct RBRegimeCfg
  {
   bool   enabled;
   int    atr_lookback;      // bars for the ATR baseline (960 = 10 trading days of M15)
   double low_thr;
   double high_thr;
   double extreme_thr;
   int    er_period;         // bars for the efficiency ratio (32 = 8 hours)
   double range_er;
   // policy per regime: trade or skip, risk multiplier, RR override (0 = keep base RR)
   bool   trade_low;
   double risk_mult_low;
   double rr_low;
   bool   trade_high;
   double risk_mult_high;
   double rr_high;
   bool   trade_extreme;
   bool   trade_range;
   double risk_mult_range;
   double rr_range;

   void              Defaults(void)
     {
      enabled         = true;
      atr_lookback    = 960;
      low_thr         = 0.70;
      high_thr        = 1.50;
      extreme_thr     = 2.50;
      er_period       = 32;
      range_er        = 0.20;
      trade_low       = true;
      risk_mult_low   = 0.5;
      rr_low          = 0.0;
      trade_high      = true;
      risk_mult_high  = 0.5;
      rr_high         = 0.0;
      trade_extreme   = false;
      trade_range     = true;
      risk_mult_range = 0.5;
      rr_range        = 0.0;
     }

   //--- source-faithful baseline: classify and log, but trade every regime at full risk
   void              Neutral(void)
     {
      Defaults();
      risk_mult_low   = 1.0;
      risk_mult_high  = 1.0;
      risk_mult_range = 1.0;
      trade_extreme   = true;
     }
  };

//--- requires ATR already computed on the series (RB_Scan does it)
bool RB_ClassifyRegime(const CRBSeries &s, int k, const RBRegimeCfg &c, RBRegime &r)
  {
   r.valid     = false;
   r.vol_ratio = 0.0;
   r.er        = 0.0;
   r.vol_class = RB_VOL_NORMAL;
   r.ranging   = false;
   if(k < 0 || k >= s.Size() || c.atr_lookback < 2 || c.er_period < 1)
      return false;
   double atr = s.ATR(k);
   if(!(atr > 0.0))
      return false;
   double sum = 0.0;
   int cnt = 0;
   for(int i = k; i >= 0 && i > k - c.atr_lookback; i--)
     {
      double a = s.ATR(i);
      if(a > 0.0)
        {
         sum += a;
         cnt++;
        }
     }
   if(cnt < c.atr_lookback / 2 || k - c.er_period < 0)
      return false;
   r.vol_ratio = atr / (sum / cnt);

   double path = 0.0;
   for(int i = k - c.er_period + 1; i <= k; i++)
      path += MathAbs(s.C(i) - s.C(i - 1));
   r.er = path > 0.0 ? MathAbs(s.C(k) - s.C(k - c.er_period)) / path : 0.0;

   if(r.vol_ratio >= c.extreme_thr)
      r.vol_class = RB_VOL_EXTREME;
   else if(r.vol_ratio >= c.high_thr)
      r.vol_class = RB_VOL_HIGH;
   else if(r.vol_ratio <= c.low_thr)
      r.vol_class = RB_VOL_LOW;
   r.ranging = r.er <= c.range_er;
   r.valid   = true;
   return true;
  }

struct RBRegimeDecision
  {
   bool   allow;
   double risk_mult;
   double rr;
   string reason;
  };

//+------------------------------------------------------------------+
//| Combine volatility and range policies, most conservative wins:   |
//|  - EXTREME -> only trade_extreme decides                         |
//|  - skip if the volatility policy OR the range policy says skip   |
//|  - risk multiplier = min of applicable multipliers               |
//|  - RR override: range policy first, then volatility policy       |
//|  - unknown regime (not enough history) -> skip (fail safe)       |
//+------------------------------------------------------------------+
void RB_RegimeDecide(const RBRegime &r, const RBRegimeCfg &c, double base_rr, RBRegimeDecision &d)
  {
   d.allow     = true;
   d.risk_mult = 1.0;
   d.rr        = base_rr;
   d.reason    = "REGIME_OFF";
   if(!c.enabled)
      return;
   if(!r.valid)
     {
      d.allow  = false;
      d.reason = "REGIME_UNKNOWN";
      return;
     }
   string tag = RB_VolText(r.vol_class) + (r.ranging ? "+RANGE" : "");
   d.reason = tag;
   if(r.vol_class == RB_VOL_EXTREME)
     {
      d.allow = c.trade_extreme;
      return;
     }
   double vol_rr = 0.0;
   if(r.vol_class == RB_VOL_LOW)
     {
      if(!c.trade_low)
         d.allow = false;
      d.risk_mult = MathMin(d.risk_mult, c.risk_mult_low);
      vol_rr = c.rr_low;
     }
   else if(r.vol_class == RB_VOL_HIGH)
     {
      if(!c.trade_high)
         d.allow = false;
      d.risk_mult = MathMin(d.risk_mult, c.risk_mult_high);
      vol_rr = c.rr_high;
     }
   if(vol_rr > 0.0)
      d.rr = vol_rr;
   if(r.ranging)
     {
      if(!c.trade_range)
         d.allow = false;
      d.risk_mult = MathMin(d.risk_mult, c.risk_mult_range);
      if(c.rr_range > 0.0)
         d.rr = c.rr_range;
     }
   if(!(d.risk_mult > 0.0))
      d.allow = false;
  }

#endif
