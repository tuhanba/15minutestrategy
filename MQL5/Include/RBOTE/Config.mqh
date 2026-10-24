//+------------------------------------------------------------------+
//| Config.mqh - strategy parameters (pure logic)                    |
//| Defaults follow the source chart; every item that the source     |
//| does not define is marked ASSUMPTION and documented in README.   |
//+------------------------------------------------------------------+
#ifndef RBOTE_CONFIG_MQH
#define RBOTE_CONFIG_MQH

#include "Types.mqh"

struct RBConfig
  {
   // --- PD arrays
   int    atr_period;           // ATR used only for optional size filters
   bool   use_fvg;
   bool   use_ob;
   double fvg_min_atr;          // ASSUMPTION: min FVG height in ATR (0 = off)
   int    ob_lookback;          // bars before the displacement candle searched for the OB candle
   int    swing_n;              // fractal strength for the OB break-of-structure check
   int    swing_search;         // how far back the BOS swing is searched
   int    zone_max_age_bars;    // ASSUMPTION: zone expiry
   // --- rejection block
   int    rb_close_rule;        // ENUM_RB_CLOSE_RULE
   double rb_min_wick_ratio;    // ASSUMPTION: rejection wick / candle range
   double rb_min_wick_atr;      // ASSUMPTION: min rejection wick in ATR (0 = off)
   bool   rb_require_approach;  // previous close must be outside the zone (price comes INTO it)
   int    rb_confirm;           // ENUM_RB_CONFIRM
   int    rb_confirm_bars;      // only for RB_CONFIRM_NEXT_CLOSE
   double rb_min_range_ticks;   // RB height must be at least this many ticks
   // --- entry / exit
   double fib_level;            // 0.79 (source)
   int    stop_mode;            // ENUM_RB_STOP_MODE
   double stop_distance;        // source: 10 - unit MUST be set explicitly
   int    stop_unit;            // ENUM_RB_DIST_UNIT, RB_UNIT_NOT_SET rejects every trade
   double structural_buffer;    // price units, only for RB_STOP_STRUCTURAL
   bool   require_sl_beyond_rb; // fixed stop must sit at/below RB low (bull) / at/above RB high (bear)
   double rr;                   // 6 (source), 5 as alternative
   double min_stop_spread_mult; // stop distance must be >= mult * current spread

   void              Defaults(void)
     {
      atr_period           = 14;
      use_fvg              = true;
      use_ob               = true;
      fvg_min_atr          = 0.0;
      ob_lookback          = 3;
      swing_n              = 2;
      swing_search         = 100;
      zone_max_age_bars    = 192;
      rb_close_rule        = RB_CLOSE_BODY_OUTSIDE;
      rb_min_wick_ratio    = 0.5;
      rb_min_wick_atr      = 0.0;
      rb_require_approach  = true;
      rb_confirm           = RB_CONFIRM_RB_CLOSE;
      rb_confirm_bars      = 3;
      rb_min_range_ticks   = 1.0;
      fib_level            = 0.79;
      stop_mode            = RB_STOP_FIXED;
      stop_distance        = 10.0;
      stop_unit            = RB_UNIT_NOT_SET;
      structural_buffer    = 0.0;
      require_sl_beyond_rb = true;
      rr                   = 6.0;
      min_stop_spread_mult = 2.0;
     }
  };

#endif
