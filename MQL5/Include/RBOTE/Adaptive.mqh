//+------------------------------------------------------------------+
//| Adaptive.mqh - trade features, profit-funded risk scaling and    |
//| setup-edge weighting from the EA's own closed trades (pure).     |
//|                                                                  |
//| 1. Profit-funded scaling (anti-martingale, bounded):             |
//|    profit = balance - start_balance                              |
//|    pct = base_pct + profit_share * max(0, profit) / ref_equity   |
//|    capped at max_pct; back to base_pct when                      |
//|      balance < high-water mark * (1 - brake_dd_pct)  or          |
//|      consecutive losses >= loss_reset.                           |
//|    Extra risk is only ever paid from realized profit.            |
//|                                                                  |
//| 2. Edge weighting ("risk up in the direction that works"):       |
//|    per feature dimension (direction, zone type, volatility,      |
//|    range, session) the mean R of past CLOSED trades in the same  |
//|    bucket, shrunk toward 0:  shrunk = sum_r / (n + prior)        |
//|    mult = clamp(1 + gain * sum_over_dimensions(shrunk), min, max)|
//|    Inactive (mult = 1) until min_total trades are closed.        |
//|                                                                  |
//| Both are ASSUMPTIONS: correlation, not proven causation.         |
//+------------------------------------------------------------------+
#ifndef RBOTE_ADAPTIVE_MQH
#define RBOTE_ADAPTIVE_MQH

#include "Regime.mqh"

#define RB_FEAT_DIMS    5
#define RB_FEAT_BUCKETS 4

#define RB_DIM_DIR      0   // 0 long, 1 short
#define RB_DIM_ZONE     1   // 0 FVG, 1 OB
#define RB_DIM_VOL      2   // RB_VOL_NORMAL/LOW/HIGH/EXTREME
#define RB_DIM_RANGE    3   // 0 trending, 1 ranging
#define RB_DIM_SESSION  4   // server-hour buckets 0-5, 6-11, 12-17, 18-23

//--- session bucket from the SERVER hour (broker time, not UTC)
int RB_SessionBucket(int server_hour)
  {
   if(server_hour < 0 || server_hour > 23)
      return 0;
   return server_hour / 6;
  }

string RB_SessionText(int b)
  {
   switch(b)
     {
      case 0: return "H00-05";
      case 1: return "H06-11";
      case 2: return "H12-17";
      case 3: return "H18-23";
     }
   return "H??";
  }

struct RBFeatures
  {
   int b[RB_FEAT_DIMS];
  };

void RB_MakeFeatures(int dir, int zone_type, int vol_class, bool ranging, int server_hour, RBFeatures &f)
  {
   f.b[RB_DIM_DIR]     = (dir == RB_DIR_BULL) ? 0 : 1;
   f.b[RB_DIM_ZONE]    = (zone_type == RB_ZONE_OB) ? 1 : 0;
   f.b[RB_DIM_VOL]     = (vol_class >= 0 && vol_class < RB_FEAT_BUCKETS) ? vol_class : RB_VOL_NORMAL;
   f.b[RB_DIM_RANGE]   = ranging ? 1 : 0;
   f.b[RB_DIM_SESSION] = RB_SessionBucket(server_hour);
  }

//+------------------------------------------------------------------+
//| 1. Profit-funded risk scaling                                    |
//+------------------------------------------------------------------+
struct RBScaleCfg
  {
   bool   enabled;
   double base_pct;      // fraction, e.g. 0.0025
   double max_pct;       // hard cap, e.g. 0.005
   double profit_share;  // fraction of realized profit added as extra risk per trade
   double brake_dd_pct;  // fall back to base when balance is this far below its high-water mark
   int    loss_reset;    // fall back to base after this many consecutive losses (0 = off)

   void              Defaults(void)
     {
      enabled      = true;
      base_pct     = 0.0025;
      max_pct      = 0.005;
      profit_share = 0.02;
      brake_dd_pct = 0.02;
      loss_reset   = 3;
     }
  };

//--- returns the risk fraction to use; `why` explains it
double RB_ProfitScaledPct(const RBScaleCfg &c, double start_balance, double balance, double hwm,
                          double ref_equity, int consecutive_losses, string &why)
  {
   why = "BASE";
   if(!c.enabled)
      return c.base_pct;
   if(!(start_balance > 0.0) || !(ref_equity > 0.0))
     {
      why = "BASE_NO_REFERENCE";
      return c.base_pct;
     }
   if(c.loss_reset > 0 && consecutive_losses >= c.loss_reset)
     {
      why = "BASE_LOSS_STREAK";
      return c.base_pct;
     }
   if(hwm > 0.0 && balance < hwm * (1.0 - c.brake_dd_pct))
     {
      why = "BASE_DRAWDOWN_BRAKE";
      return c.base_pct;
     }
   double profit = balance - start_balance;
   if(profit <= 0.0)
      return c.base_pct;
   double pct = c.base_pct + c.profit_share * profit / ref_equity;
   if(pct > c.max_pct)
     {
      why = "SCALED_CAPPED";
      return c.max_pct;
     }
   why = "SCALED";
   return pct;
  }

//+------------------------------------------------------------------+
//| 2. Edge statistics per feature bucket                            |
//+------------------------------------------------------------------+
struct RBEdgeCfg
  {
   bool   enabled;
   int    min_total;   // closed trades before weighting starts
   double prior;       // shrinkage weight (pseudo-trades at 0R)
   double gain;
   double min_mult;
   double max_mult;

   void              Defaults(void)
     {
      enabled   = true;
      min_total = 40;
      prior     = 20.0;
      gain      = 0.15;
      min_mult  = 0.5;
      max_mult  = 1.5;
     }
  };

class CRBEdgeStats
  {
public:
   double            n[RB_FEAT_DIMS][RB_FEAT_BUCKETS];
   double            sum_r[RB_FEAT_DIMS][RB_FEAT_BUCKETS];
   double            total;

                     CRBEdgeStats(void) { Reset(); }
   void              Reset(void)
     {
      total = 0.0;
      for(int d = 0; d < RB_FEAT_DIMS; d++)
         for(int b = 0; b < RB_FEAT_BUCKETS; b++)
           {
            n[d][b]     = 0.0;
            sum_r[d][b] = 0.0;
           }
     }
   //--- record one CLOSED trade (net R)
   void              Add(const RBFeatures &f, double r)
     {
      total += 1.0;
      for(int d = 0; d < RB_FEAT_DIMS; d++)
        {
         n[d][f.b[d]]     += 1.0;
         sum_r[d][f.b[d]] += r;
        }
     }
   double            Shrunk(int d, int b, double prior) const
     {
      return sum_r[d][b] / (n[d][b] + prior);
     }
   double            Mult(const RBFeatures &f, const RBEdgeCfg &c, string &why) const
     {
      why = "EDGE_OFF";
      if(!c.enabled)
         return 1.0;
      if(total < c.min_total)
        {
         why = "EDGE_WARMUP";
         return 1.0;
        }
      double score = 0.0;
      for(int d = 0; d < RB_FEAT_DIMS; d++)
         score += Shrunk(d, f.b[d], c.prior);
      double m = 1.0 + c.gain * score;
      if(m < c.min_mult)
         m = c.min_mult;
      if(m > c.max_mult)
         m = c.max_mult;
      why = "EDGE";
      return m;
     }
  };

string RB_BucketText(int d, int b)
  {
   if(d == RB_DIM_DIR)     return b == 0 ? "LONG" : "SHORT";
   if(d == RB_DIM_ZONE)    return b == 0 ? "FVG" : "OB";
   if(d == RB_DIM_VOL)     return RB_VolText(b);
   if(d == RB_DIM_RANGE)   return b == 1 ? "RANGE" : "TREND";
   if(d == RB_DIM_SESSION) return RB_SessionText(b);
   return "?";
  }

string RB_DimText(int d)
  {
   switch(d)
     {
      case RB_DIM_DIR:     return "dir";
      case RB_DIM_ZONE:    return "zone";
      case RB_DIM_VOL:     return "vol";
      case RB_DIM_RANGE:   return "range";
      case RB_DIM_SESSION: return "session";
     }
   return "?";
  }

//--- human-readable breakdown of the edge multiplier: what each condition contributed and why
//--- e.g. "dir=LONG n=25 avgR=+0.80 contrib=+0.083 | zone=FVG ..."
string RB_EdgeExplain(const CRBEdgeStats &st, const RBFeatures &f, const RBEdgeCfg &c)
  {
   string out = "";
   for(int d = 0; d < RB_FEAT_DIMS; d++)
     {
      int b = f.b[d];
      double n = st.n[d][b];
      double avg = n > 0.0 ? st.sum_r[d][b] / n : 0.0;
      double contrib = c.gain * st.Shrunk(d, b, c.prior);
      if(d > 0)
         out += " | ";
      out += RB_DimText(d) + "=" + RB_BucketText(d, b) + " n=" + IntegerToString((long)n) +
             " avgR=" + DoubleToString(avg, 2) + " contrib=" + DoubleToString(contrib, 3);
     }
   return out;
  }

//--- final risk money: profit-scaled pct x regime x edge, never above max_pct of reference
double RB_FinalRiskMoney(double pct, double ref_equity, double regime_mult, double edge_mult, double max_pct)
  {
   if(!(ref_equity > 0.0) || !(pct > 0.0))
      return 0.0;
   double m = pct * regime_mult * edge_mult;
   if(max_pct > 0.0 && m > max_pct)
      m = max_pct;
   return m * ref_equity;
  }

//--- excursion in R (signed: favourable > 0) of `price` relative to entry
double RB_ExcursionR(int dir, double entry, double price, double risk_dist)
  {
   if(!(risk_dist > 0.0))
      return 0.0;
   return (dir == RB_DIR_BULL ? price - entry : entry - price) / risk_dist;
  }

#endif
