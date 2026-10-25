// SINGLE-FILE BUILD generated from RBOTE_EA.mq5 by tools/make_single_file.py - do not edit, regenerate.
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
//==== begin MQL5/Include/RBOTE/RejectionBlock.mqh ====
//+------------------------------------------------------------------+
//| RejectionBlock.mqh - zone life cycle + M15 Rejection Block       |
//|                                                                  |
//| Bullish RB at candle k on an ACTIVE bullish zone Z:              |
//|  1. wick into the zone:        low[k] <= Z.top                   |
//|  2. body rejected:             BODY_OUTSIDE: min(o,c) > Z.top    |
//|                                NOT_THROUGH : close    > Z.bottom |
//|  3. rejection wick:            (min(o,c)-low)/(high-low) >= ratio|
//|  4. approach (optional):       close[k-1] > Z.top                |
//|  RB boundaries: low = low[k] (wick), high = min(open,close)      |
//| Bearish RB mirrors it: high = high[k] (wick), low = max(o,c).    |
//|                                                                  |
//| Confirmation:                                                    |
//|  RB_CLOSE      -> signal on the close of candle k                |
//|  NEXT_CLOSE    -> a candle in (k, k+confirm_bars] closes above   |
//|                   high[k] (bull) before any low < RB low.        |
//+------------------------------------------------------------------+
#ifndef RBOTE_REJECTIONBLOCK_MQH
#define RBOTE_REJECTIONBLOCK_MQH

//==== begin MQL5/Include/RBOTE/PDArray.mqh ====
//+------------------------------------------------------------------+
//| PDArray.mqh - ATR, fractal swings, FVG and Order Block detection |
//| Pure logic. Every function only reads bars <= the index it is    |
//| asked about, so results never depend on future candles.         |
//+------------------------------------------------------------------+
#ifndef RBOTE_PDARRAY_MQH
#define RBOTE_PDARRAY_MQH

//==== begin MQL5/Include/RBOTE/Config.mqh ====
//+------------------------------------------------------------------+
//| Config.mqh - strategy parameters (pure logic)                    |
//| Defaults follow the source chart; every item that the source     |
//| does not define is marked ASSUMPTION and documented in README.   |
//+------------------------------------------------------------------+
#ifndef RBOTE_CONFIG_MQH
#define RBOTE_CONFIG_MQH

//==== begin MQL5/Include/RBOTE/Types.mqh ====
//+------------------------------------------------------------------+
//| Types.mqh - shared enums, structs and containers (pure logic)    |
//+------------------------------------------------------------------+
#ifndef RBOTE_TYPES_MQH
#define RBOTE_TYPES_MQH

//==== begin MQL5/Include/RBOTE/Compat.mqh ====
//+------------------------------------------------------------------+
//| Compat.mqh                                                       |
//| Lets the pure-logic headers compile both in MQL5 and in C++      |
//| (g++) so the same source can be unit-tested outside MetaTrader.  |
//| Under MQL5 this file is empty.                                   |
//+------------------------------------------------------------------+
#ifndef RBOTE_COMPAT_MQH
#define RBOTE_COMPAT_MQH

#ifndef __MQL5__
#include <cmath>
#include <cfloat>
#include <cstdio>
#include <string>
#include <vector>

typedef long long          datetime;
typedef unsigned long      ulong;   // 64-bit on LP64 (matches <sys/types.h>)
typedef unsigned int       uint;    // matches <sys/types.h>
typedef unsigned char      uchar;
typedef std::string        string;

inline double MathAbs(double x)             { return std::fabs(x); }
inline double MathMax(double a, double b)   { return a > b ? a : b; }
inline double MathMin(double a, double b)   { return a < b ? a : b; }
inline int    MathMax(int a, int b)         { return a > b ? a : b; }
inline int    MathMin(int a, int b)         { return a < b ? a : b; }
inline double MathFloor(double x)           { return std::floor(x); }
inline double MathCeil(double x)            { return std::ceil(x); }
inline double MathRound(double x)           { return std::round(x); }
inline double MathSqrt(double x)            { return std::sqrt(x); }
inline bool   MathIsValidNumber(double x)   { return std::isfinite(x); }

inline string IntegerToString(long long v)  { return std::to_string(v); }
inline int StringFind(const string &s, const string &sub, int start = 0)
  {
   std::string::size_type p = s.find(sub, (std::string::size_type)start);
   return p == std::string::npos ? -1 : (int)p;
  }
inline string DoubleToString(double v, int digits)
  {
   char buf[64];
   std::snprintf(buf, sizeof(buf), "%.*f", digits, v);
   return string(buf);
  }
#endif

#endif
//==== end MQL5/Include/RBOTE/Compat.mqh ====

#define RB_DIR_BULL  1
#define RB_DIR_BEAR -1

enum ENUM_RB_ZONE_TYPE
  {
   RB_ZONE_FVG = 0,
   RB_ZONE_OB  = 1
  };

enum ENUM_RB_ZONE_STATUS
  {
   RB_ZONE_ACTIVE   = 0,
   RB_ZONE_USED     = 1,  // produced a signal, never signals again
   RB_ZONE_INVALID  = 2,  // a candle closed through the far side
   RB_ZONE_EXPIRED  = 3   // older than zone_max_age_bars
  };

// How the rejection candle body must close relative to the zone.
enum ENUM_RB_CLOSE_RULE
  {
   RB_CLOSE_BODY_OUTSIDE = 0, // bull: min(open,close) > zone.top (source image)
   RB_CLOSE_NOT_THROUGH  = 1  // bull: close > zone.bottom (looser)
  };

// When the RB counts as confirmed.
enum ENUM_RB_CONFIRM
  {
   RB_CONFIRM_RB_CLOSE   = 0, // the rejection candle itself has closed
   RB_CONFIRM_NEXT_CLOSE = 1  // a later candle closes beyond the RB candle extreme
  };

enum ENUM_RB_STOP_MODE
  {
   RB_STOP_FIXED      = 0, // fixed distance from entry (source: "Stop: 10.00")
   RB_STOP_STRUCTURAL = 1, // RB extreme -/+ buffer
   RB_STOP_ATR        = 2  // k x ATR from entry, never inside the RB extreme -/+ buffer
  };

enum ENUM_RB_DIST_UNIT
  {
   RB_UNIT_NOT_SET = -1, // default: EA refuses to start until the unit is chosen
   RB_UNIT_PRICE  = 0, // absolute price distance (e.g. 10.00)
   RB_UNIT_POINTS = 1, // multiples of SYMBOL_POINT
   RB_UNIT_TICKS  = 2  // multiples of SYMBOL_TRADE_TICK_SIZE
  };

struct RBBar
  {
   datetime time;
   double   open;
   double   high;
   double   low;
   double   close;
  };

struct RBZone
  {
   int      id;          // sequential inside one scan
   int      type;        // ENUM_RB_ZONE_TYPE
   int      dir;         // RB_DIR_BULL = support (long), RB_DIR_BEAR = resistance (short)
   double   top;
   double   bottom;
   int      src_idx;     // FVG: middle candle, OB: the order-block candle
   int      formed_idx;  // bar whose close made the zone known
   datetime formed_time; // open time of formed_idx bar
   int      status;      // ENUM_RB_ZONE_STATUS
   int      status_idx;  // bar index where status last changed (-1 if active)
  };

// A confirmed rejection block = one trade signal.
struct RBSignal
  {
   int      dir;
   int      rb_idx;        // rejection candle
   datetime rb_time;
   int      confirm_idx;   // bar whose close confirmed the RB (signal known after its close)
   datetime confirm_time;
   double   rb_low;        // RB lower boundary  (bull: wick low,  bear: body high)
   double   rb_high;       // RB upper boundary  (bull: body low,  bear: wick high)
   int      zone_id;       // primary PD array
   int      zone_type;
   double   zone_top;
   double   zone_bottom;
   int      zones_hit;     // confluence count
   double   atr;           // ATR at the RB candle (for reporting / regimes)
  };

// Entry plan derived from a signal and the stop/target configuration.
struct RBPlan
  {
   int    dir;
   double entry;
   double sl;
   double tp;
   double risk_dist;     // |entry - sl|
   double fib_level;
  };

struct RBSymbolSpec
  {
   int    digits;
   double point;
   double tick_size;
   double tick_value_loss; // account currency per 1 lot per tick (loss side)
   double vol_min;
   double vol_max;
   double vol_step;
   int    stops_level;     // in points
   int    freeze_level;    // in points
  };

//+------------------------------------------------------------------+
//| Minimal growable array usable from MQL5 and C++                  |
//+------------------------------------------------------------------+
template<typename T>
class CRBVec
  {
private:
#ifdef __MQL5__
   T                 m_a[];
#else
   std::vector<T>    m_a;
#endif
public:
#ifdef __MQL5__
   int               Size(void) const       { return ArraySize(m_a); }
   void              Clear(void)            { ArrayResize(m_a, 0); }
   void              Push(const T &v)       { int n = ArraySize(m_a); ArrayResize(m_a, n + 1, 256); m_a[n] = v; }
#else
   int               Size(void) const       { return (int)m_a.size(); }
   void              Clear(void)            { m_a.clear(); }
   void              Push(const T &v)       { m_a.push_back(v); }
#endif
   void              Get(int i, T &out) const { out = m_a[i]; }
   void              Set(int i, const T &v)   { m_a[i] = v; }
  };

//+------------------------------------------------------------------+
//| Chronological bar series (index 0 = oldest, last = newest CLOSED)|
//+------------------------------------------------------------------+
class CRBSeries
  {
private:
   CRBVec<RBBar>     m_bars;
   CRBVec<double>    m_atr;
public:
   void              Clear(void)              { m_bars.Clear(); m_atr.Clear(); }
   void              Add(const RBBar &b)      { m_bars.Push(b); double z = 0.0; m_atr.Push(z); }
   int               Size(void) const         { return m_bars.Size(); }
   void              Bar(int i, RBBar &b) const { m_bars.Get(i, b); }
   datetime          Time(int i) const        { RBBar b; m_bars.Get(i, b); return b.time; }
   double            O(int i) const           { RBBar b; m_bars.Get(i, b); return b.open; }
   double            H(int i) const           { RBBar b; m_bars.Get(i, b); return b.high; }
   double            L(int i) const           { RBBar b; m_bars.Get(i, b); return b.low; }
   double            C(int i) const           { RBBar b; m_bars.Get(i, b); return b.close; }
   double            BodyHigh(int i) const    { return MathMax(O(i), C(i)); }
   double            BodyLow(int i) const     { return MathMin(O(i), C(i)); }
   double            ATR(int i) const         { double v; m_atr.Get(i, v); return v; }
   void              SetATR(int i, double v)  { m_atr.Set(i, v); }
  };

#endif
//==== end MQL5/Include/RBOTE/Types.mqh ====

struct RBConfig
  {
   // --- PD arrays
   int    atr_period;           // ATR used only for optional size filters
   bool   use_fvg;
   bool   use_ob;
   double fvg_min_atr;          // ASSUMPTION: min FVG height in ATR (0 = off); structural mode only
   int    ob_lookback;          // bars before the displacement candle searched for the OB candle
   int    swing_n;              // fractal strength for the OB break-of-structure check
   int    swing_search;         // how far back the BOS swing is searched
   int    zone_max_age_bars;    // ASSUMPTION: zone expiry
   // --- rejection block
   int    rb_close_rule;        // ENUM_RB_CLOSE_RULE
   double rb_min_wick_ratio;    // ASSUMPTION: rejection wick / candle range
   double rb_min_wick_atr;      // ASSUMPTION: min rejection wick in ATR (0 = off); structural mode only
   bool   rb_require_approach;  // previous close must be outside the zone (price comes INTO it)
   int    rb_confirm;           // ENUM_RB_CONFIRM
   int    rb_confirm_bars;      // only for RB_CONFIRM_NEXT_CLOSE
   double rb_min_range_ticks;   // RB height must be at least this many ticks
   // --- entry / exit
   double fib_level;            // 0.79 (source)
   int    stop_mode;            // ENUM_RB_STOP_MODE
   double stop_distance;        // source: 10 - unit MUST be set explicitly
   int    stop_unit;            // ENUM_RB_DIST_UNIT, RB_UNIT_NOT_SET rejects every trade
   double structural_buffer;    // price units, RB_STOP_STRUCTURAL and RB_STOP_ATR
   double stop_atr_mult;        // RB_STOP_ATR: stop distance = mult * ATR at the RB
   bool   require_sl_beyond_rb; // fixed stop must sit at/below RB low (bull) / at/above RB high (bear)
   double rr;                   // 6 (source), 5 as alternative
   double min_stop_spread_mult; // stop distance must be >= mult * current spread
   double max_stop_atr;         // stop distance must be <= mult * ATR at the RB (0 = off); structural mode only
   double min_stop_atr;         // stop distance must be >= mult * ATR at the RB (0 = off); structural mode only

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
      stop_atr_mult        = 2.0;
      require_sl_beyond_rb = true;
      rr                   = 6.0;
      min_stop_spread_mult = 2.0;
      max_stop_atr         = 3.0;
      min_stop_atr         = 0.0;
     }
  };

#endif
//==== end MQL5/Include/RBOTE/Config.mqh ====

//--- Wilder ATR. ATR(i) is 0 until enough history exists.
void RB_ComputeATR(CRBSeries &s, int period)
  {
   int n = s.Size();
   double sum = 0.0;
   double atr = 0.0;
   for(int i = 0; i < n; i++)
     {
      s.SetATR(i, 0.0);
      if(i == 0 || period <= 0)
         continue;
      double tr = MathMax(s.H(i) - s.L(i),
                  MathMax(MathAbs(s.H(i) - s.C(i - 1)), MathAbs(s.L(i) - s.C(i - 1))));
      if(i <= period)
        {
         sum += tr;
         if(i == period)
           {
            atr = sum / period;
            s.SetATR(i, atr);
           }
         continue;
        }
      atr = (atr * (period - 1) + tr) / period;
      s.SetATR(i, atr);
     }
  }

//--- Fractal swing high at j with strength n (needs bars j-n .. j+n).
bool RB_IsSwingHigh(const CRBSeries &s, int j, int n)
  {
   if(j - n < 0 || j + n >= s.Size())
      return false;
   for(int k = 1; k <= n; k++)
     {
      if(!(s.H(j) > s.H(j - k)))
         return false;
      if(!(s.H(j) >= s.H(j + k)))
         return false;
     }
   return true;
  }

bool RB_IsSwingLow(const CRBSeries &s, int j, int n)
  {
   if(j - n < 0 || j + n >= s.Size())
      return false;
   for(int k = 1; k <= n; k++)
     {
      if(!(s.L(j) < s.L(j - k)))
         return false;
      if(!(s.L(j) <= s.L(j + k)))
         return false;
     }
   return true;
  }

//--- Most recent swing that is already CONFIRMED at bar asof
//--- (i.e. swing index s with s + n <= asof). Returns -1 if none.
int RB_LastConfirmedSwing(const CRBSeries &s, int asof, int n, bool high, int max_back)
  {
   for(int j = asof - n; j >= 0 && j >= asof - max_back; j--)
     {
      if(high && RB_IsSwingHigh(s, j, n))
         return j;
      if(!high && RB_IsSwingLow(s, j, n))
         return j;
     }
   return -1;
  }

bool RB_HasZone(CRBVec<RBZone> &zones, int type, int dir, int src_idx)
  {
   RBZone z;
   for(int i = 0; i < zones.Size(); i++)
     {
      zones.Get(i, z);
      if(z.type == type && z.dir == dir && z.src_idx == src_idx)
         return true;
     }
   return false;
  }

void RB_PushZone(CRBVec<RBZone> &zones, const CRBSeries &s, int type, int dir,
                 double top, double bottom, int src_idx, int formed_idx)
  {
   RBZone z;
   z.id          = zones.Size();
   z.type        = type;
   z.dir         = dir;
   z.top         = top;
   z.bottom      = bottom;
   z.src_idx     = src_idx;
   z.formed_idx  = formed_idx;
   z.formed_time = s.Time(formed_idx);
   z.status      = RB_ZONE_ACTIVE;
   z.status_idx  = -1;
   zones.Push(z);
  }

//+------------------------------------------------------------------+
//| FVG (three candles i-2, i-1, i; known after i closes)            |
//|  bull: high[i-2] < low[i]  -> zone [high[i-2], low[i]]           |
//|  bear: low[i-2]  > high[i] -> zone [high[i], low[i-2]]           |
//+------------------------------------------------------------------+
int RB_FvgDirAt(const CRBSeries &s, const RBConfig &cfg, int i, double &top, double &bottom)
  {
   if(i < 2)
      return 0;
   double min_size = cfg.fvg_min_atr * s.ATR(i);
   if(cfg.fvg_min_atr > 0.0 && s.ATR(i) <= 0.0)
      return 0;
   if(s.H(i - 2) < s.L(i))
     {
      bottom = s.H(i - 2);
      top    = s.L(i);
      if(top - bottom >= min_size)
         return RB_DIR_BULL;
     }
   if(s.L(i - 2) > s.H(i))
     {
      top    = s.L(i - 2);
      bottom = s.H(i);
      if(top - bottom >= min_size)
         return RB_DIR_BEAR;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Order Block, evaluated when an FVG forms at i (displacement leg).|
//|  bull: last bearish candle j in [i-1-ob_lookback, i-2] AND some  |
//|        close in (j, i] above the last swing high confirmed at j. |
//|        zone = [low[j], high[j]]                                  |
//|  bear: mirror (last bullish candle, close below last swing low). |
//+------------------------------------------------------------------+
int RB_FindOrderBlock(const CRBSeries &s, const RBConfig &cfg, int i, int dir)
  {
   int from = i - 2;
   int to   = MathMax(0, i - 1 - cfg.ob_lookback);
   int j = -1;
   for(int k = from; k >= to; k--)
     {
      bool opposite = (dir == RB_DIR_BULL) ? (s.C(k) < s.O(k)) : (s.C(k) > s.O(k));
      if(opposite)
        {
         j = k;
         break;
        }
     }
   if(j < 0)
      return -1;
   int sw = RB_LastConfirmedSwing(s, j, cfg.swing_n, dir == RB_DIR_BULL, cfg.swing_search);
   if(sw < 0)
      return -1;
   for(int k = j + 1; k <= i; k++)
     {
      if(dir == RB_DIR_BULL && s.C(k) > s.H(sw))
         return j;
      if(dir == RB_DIR_BEAR && s.C(k) < s.L(sw))
         return j;
     }
   return -1;
  }

//--- Detect every FVG / OB in the series, in formation order.
void RB_DetectZones(const CRBSeries &s, const RBConfig &cfg, CRBVec<RBZone> &zones)
  {
   zones.Clear();
   for(int i = 2; i < s.Size(); i++)
     {
      double top = 0.0, bottom = 0.0;
      int dir = RB_FvgDirAt(s, cfg, i, top, bottom);
      if(dir == 0)
         continue;
      if(cfg.use_fvg)
         RB_PushZone(zones, s, RB_ZONE_FVG, dir, top, bottom, i - 1, i);
      if(cfg.use_ob)
        {
         int j = RB_FindOrderBlock(s, cfg, i, dir);
         if(j >= 0 && !RB_HasZone(zones, RB_ZONE_OB, dir, j))
            RB_PushZone(zones, s, RB_ZONE_OB, dir, s.H(j), s.L(j), j, i);
        }
     }
  }

#endif
//==== end MQL5/Include/RBOTE/PDArray.mqh ====

//--- Is candle k a rejection of zone z? Fills RB boundaries.
bool RB_IsRejection(const CRBSeries &s, const RBConfig &cfg, int k, const RBZone &z,
                    double &rb_low, double &rb_high)
  {
   if(k < 1)
      return false;
   double range = s.H(k) - s.L(k);
   if(range <= 0.0)
      return false;
   double wick;
   if(z.dir == RB_DIR_BULL)
     {
      if(!(s.L(k) <= z.top))
         return false;
      if(cfg.rb_close_rule == RB_CLOSE_BODY_OUTSIDE && !(s.BodyLow(k) > z.top))
         return false;
      if(cfg.rb_close_rule == RB_CLOSE_NOT_THROUGH && !(s.C(k) > z.bottom))
         return false;
      if(cfg.rb_require_approach && !(s.C(k - 1) > z.top))
         return false;
      wick    = s.BodyLow(k) - s.L(k);
      rb_low  = s.L(k);
      rb_high = s.BodyLow(k);
     }
   else
     {
      if(!(s.H(k) >= z.bottom))
         return false;
      if(cfg.rb_close_rule == RB_CLOSE_BODY_OUTSIDE && !(s.BodyHigh(k) < z.bottom))
         return false;
      if(cfg.rb_close_rule == RB_CLOSE_NOT_THROUGH && !(s.C(k) < z.top))
         return false;
      if(cfg.rb_require_approach && !(s.C(k - 1) < z.bottom))
         return false;
      wick    = s.H(k) - s.BodyHigh(k);
      rb_low  = s.BodyHigh(k);
      rb_high = s.H(k);
     }
   if(wick / range < cfg.rb_min_wick_ratio)
      return false;
   if(cfg.rb_min_wick_atr > 0.0 && (s.ATR(k) <= 0.0 || wick < cfg.rb_min_wick_atr * s.ATR(k)))
      return false;
   if(rb_high <= rb_low)
      return false;
   return true;
  }

//--- Zone is invalidated when a candle CLOSES through its far side.
bool RB_ClosesThrough(const CRBSeries &s, int k, const RBZone &z)
  {
   if(z.dir == RB_DIR_BULL)
      return s.C(k) < z.bottom;
   return s.C(k) > z.top;
  }

//--- Primary zone among several hit by the same candle:
//--- newest formed first, then FVG before OB, then nearest to price (bull: highest top).
bool RB_ZoneBetter(const RBZone &a, const RBZone &b)
  {
   if(a.formed_idx != b.formed_idx)
      return a.formed_idx > b.formed_idx;
   if(a.type != b.type)
      return a.type == RB_ZONE_FVG;
   if(a.dir == RB_DIR_BULL)
      return a.top > b.top;
   return a.bottom < b.bottom;
  }

struct RBCandidate
  {
   bool   active;
   RBSignal sig;
  };

void RB_SetZoneStatus(CRBVec<RBZone> &zones, int i, int status, int k)
  {
   RBZone z;
   zones.Get(i, z);
   z.status     = status;
   z.status_idx = k;
   zones.Set(i, z);
  }

//+------------------------------------------------------------------+
//| Full deterministic scan over a closed-bar window.                |
//| Outputs: zones with final status, every confirmed signal.        |
//| The EA acts only on a signal whose confirm_idx is the last bar.  |
//+------------------------------------------------------------------+
void RB_Scan(CRBSeries &s, const RBConfig &cfg, CRBVec<RBZone> &zones, CRBVec<RBSignal> &signals)
  {
   signals.Clear();
   RB_ComputeATR(s, cfg.atr_period);
   RB_DetectZones(s, cfg, zones);

   RBCandidate cand[2]; // [0] bull, [1] bear
   cand[0].active = false;
   cand[1].active = false;

   int n = s.Size();
   for(int k = 1; k < n; k++)
     {
      //--- 1. pending NEXT_CLOSE candidates: confirm or cancel
      for(int c = 0; c < 2; c++)
        {
         if(!cand[c].active)
            continue;
         RBSignal sig = cand[c].sig;
         bool swept   = (sig.dir == RB_DIR_BULL) ? (s.L(k) < sig.rb_low) : (s.H(k) > sig.rb_high);
         bool confirm = (sig.dir == RB_DIR_BULL) ? (s.C(k) > s.H(sig.rb_idx)) : (s.C(k) < s.L(sig.rb_idx));
         if(swept)
            cand[c].active = false;
         else if(confirm)
           {
            sig.confirm_idx  = k;
            sig.confirm_time = s.Time(k);
            signals.Push(sig);
            cand[c].active = false;
           }
         else if(k - sig.rb_idx >= cfg.rb_confirm_bars)
            cand[c].active = false;
        }

      //--- 2. zone life cycle + rejection candidates on candle k
      int    best[2]  = {-1, -1};
      int    hits[2]  = {0, 0};
      double lo[2]    = {0.0, 0.0};
      double hi[2]    = {0.0, 0.0};
      RBZone z, bz;
      for(int i = 0; i < zones.Size(); i++)
        {
         zones.Get(i, z);
         if(z.status != RB_ZONE_ACTIVE || z.formed_idx >= k)
            continue;
         if(k - z.formed_idx > cfg.zone_max_age_bars)
           {
            RB_SetZoneStatus(zones, i, RB_ZONE_EXPIRED, k);
            continue;
           }
         double l = 0.0, h = 0.0;
         if(RB_IsRejection(s, cfg, k, z, l, h))
           {
            int d = (z.dir == RB_DIR_BULL) ? 0 : 1;
            hits[d]++;
            lo[d] = l;
            hi[d] = h;
            if(best[d] < 0)
               best[d] = i;
            else
              {
               zones.Get(best[d], bz);
               if(RB_ZoneBetter(z, bz))
                  best[d] = i;
              }
            continue;
           }
         if(RB_ClosesThrough(s, k, z))
            RB_SetZoneStatus(zones, i, RB_ZONE_INVALID, k);
        }

      //--- ambiguous candle (rejects both a bull and a bear zone): no signal
      if(hits[0] > 0 && hits[1] > 0)
         continue;

      for(int d = 0; d < 2; d++)
        {
         if(hits[d] == 0)
            continue;
         int dir = (d == 0) ? RB_DIR_BULL : RB_DIR_BEAR;
         //--- every zone rejected by this candle is consumed (one signal per zone)
         for(int i = 0; i < zones.Size(); i++)
           {
            zones.Get(i, z);
            if(z.status != RB_ZONE_ACTIVE || z.formed_idx >= k || z.dir != dir)
               continue;
            double l = 0.0, h = 0.0;
            if(RB_IsRejection(s, cfg, k, z, l, h))
               RB_SetZoneStatus(zones, i, RB_ZONE_USED, k);
           }
         if(cand[d].active)
            continue; // one open candidate per direction
         zones.Get(best[d], bz);
         RBSignal sig;
         sig.dir          = dir;
         sig.rb_idx       = k;
         sig.rb_time      = s.Time(k);
         sig.confirm_idx  = k;
         sig.confirm_time = s.Time(k);
         sig.rb_low       = lo[d];
         sig.rb_high      = hi[d];
         sig.zone_id      = bz.id;
         sig.zone_type    = bz.type;
         sig.zone_top     = bz.top;
         sig.zone_bottom  = bz.bottom;
         sig.zones_hit    = hits[d];
         sig.atr          = s.ATR(k);
         if(cfg.rb_confirm == RB_CONFIRM_RB_CLOSE)
            signals.Push(sig);
         else
           {
            cand[d].active = true;
            cand[d].sig    = sig;
           }
        }
     }
  }

#endif
//==== end MQL5/Include/RBOTE/RejectionBlock.mqh ====
//==== begin MQL5/Include/RBOTE/TradeMath.mqh ====
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
      case 20: return "STOP_TOO_TIGHT_ATR";
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
      if(cfg.stop_mode == RB_STOP_ATR)
        {
         if(!(cfg.stop_atr_mult > 0.0) || !(sig.atr > 0.0))
            return 5;
         // k x ATR from the entry; the RB extreme still bounds it (the farther of the two wins)
         double sl_atr = (dir == RB_DIR_BULL) ? RB_RoundDownToTick(entry - cfg.stop_atr_mult * sig.atr, sp.tick_size)
                                              : RB_RoundUpToTick(entry + cfg.stop_atr_mult * sig.atr, sp.tick_size);
         sl = (dir == RB_DIR_BULL) ? MathMin(sl, sl_atr) : MathMax(sl, sl_atr);
        }
     }
   if(dir == RB_DIR_BULL && !(sl < entry))
      return 6;
   if(dir == RB_DIR_BEAR && !(sl > entry))
      return 6;

   double risk = MathAbs(entry - sl);
   if(risk < sp.tick_size - RB_EPS)
      return 5;
   // Structural stop on an oversized RB: lot would collapse and the setup is atypical, skip it.
   if(cfg.stop_mode != RB_STOP_FIXED && cfg.max_stop_atr > 0.0 && sig.atr > 0.0
      && risk > cfg.max_stop_atr * sig.atr + RB_EPS)
      return 19;
   // Stop inside the bar-to-bar noise: a big lot gets stopped by spread and wicks within minutes.
   if(cfg.stop_mode != RB_STOP_FIXED && cfg.min_stop_atr > 0.0 && sig.atr > 0.0
      && risk < cfg.min_stop_atr * sig.atr - RB_EPS)
      return 20;
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
//==== end MQL5/Include/RBOTE/TradeMath.mqh ====
//==== begin MQL5/Include/RBOTE/RiskGuard.mqh ====
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
//==== end MQL5/Include/RBOTE/RiskGuard.mqh ====
//==== begin MQL5/Include/RBOTE/Safety.mqh ====
//+------------------------------------------------------------------+
//| Safety.mqh - pure decision functions for live gating, data       |
//| freshness, pending-order invalidation and restart reconciliation |
//+------------------------------------------------------------------+
#ifndef RBOTE_SAFETY_MQH
#define RBOTE_SAFETY_MQH


#define RB_ACC_DEMO    0
#define RB_ACC_CONTEST 1
#define RB_ACC_REAL    2

//--- 0 = trading allowed; otherwise reason code.
//--- Outside the tester EVERY account (prop evaluations are usually "demo" trade mode) needs
//--- confirm_login == login, and the account must be known (logged in, connected).
//--- Real accounts additionally need allow_live and verified prop rules.
int RB_TradingPermission(bool is_tester, int account_mode, bool allow_live,
                         long confirm_login, long login, bool prop_verified, bool connected)
  {
   if(is_tester)
      return 0;
   if(login <= 0 || !connected)
      return 5;
   if(confirm_login <= 0 || confirm_login != login)
      return 3;
   if(account_mode == RB_ACC_DEMO)
      return 0;
   if(account_mode == RB_ACC_CONTEST)
      return 1;              // treat like real: refuse
   if(!allow_live)
      return 2;
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
      case 3: return "CONFIRM_LOGIN_MISMATCH (set InpLiveConfirmLogin = this account's login)";
      case 4: return "PROP_RULES_NOT_VERIFIED";
      case 5: return "ACCOUNT_UNKNOWN (not logged in / not connected)";
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
//==== end MQL5/Include/RBOTE/Safety.mqh ====
//==== begin MQL5/Include/RBOTE/MT5Bridge.mqh ====
//+------------------------------------------------------------------+
//| MT5Bridge.mqh - terminal access: symbol spec, account snapshot,  |
//| per-order metadata (global variables), duplicate detection,      |
//| economic-calendar filter. MQL5 only.                             |
//+------------------------------------------------------------------+
#ifndef RBOTE_MT5BRIDGE_MQH
#define RBOTE_MT5BRIDGE_MQH


//--- read and validate the broker's symbol properties
bool RB_ReadSymbolSpec(const string sym, RBSymbolSpec &sp)
  {
   sp.digits          = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sp.point           = SymbolInfoDouble(sym, SYMBOL_POINT);
   sp.tick_size       = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   sp.tick_value_loss = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(!(sp.tick_value_loss > 0.0))
      sp.tick_value_loss = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   sp.vol_min         = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   sp.vol_max         = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   sp.vol_step        = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   sp.stops_level     = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   sp.freeze_level    = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_FREEZE_LEVEL);
   return RB_ValidateSpec(sp) == 0;
  }

string RB_SpecText(const RBSymbolSpec &sp)
  {
   return StringFormat("digits=%d point=%s tick_size=%s tick_value_loss=%s vol[min=%s max=%s step=%s] stops_level=%d freeze_level=%d",
                       sp.digits, DoubleToString(sp.point, 8), DoubleToString(sp.tick_size, 8),
                       DoubleToString(sp.tick_value_loss, 4), DoubleToString(sp.vol_min, 2),
                       DoubleToString(sp.vol_max, 2), DoubleToString(sp.vol_step, 2),
                       sp.stops_level, sp.freeze_level);
  }

//+------------------------------------------------------------------+
//| Global-variable namespace: "RB." + 8-hex FNV-1a of               |
//| login|symbol|magic. Short enough that every key stays <= 63      |
//| chars, unique per account + symbol + magic.                      |
//+------------------------------------------------------------------+
string RB_KeyPrefix(long login, const string sym, long magic)
  {
   string src = IntegerToString(login) + "|" + sym + "|" + IntegerToString(magic);
   uchar  b[];
   int    n = StringToCharArray(src, b, 0, WHOLE_ARRAY, CP_UTF8);
   const uint prime = 16777619;
   uint   h = (uint)2166136261;
   for(int i = 0; i < n; i++)
     {
      if(b[i] == 0)
         break;
      h ^= (uint)b[i];
      h *= prime;
     }
   return "RB." + StringFormat("%08X", h);
  }

//+------------------------------------------------------------------+
//| Order metadata in terminal global variables (survive restarts).  |
//| Key: <prefix>.<order ticket>.<field>                             |
//| POSITION_IDENTIFIER equals the opening order ticket, so the same |
//| record serves the resulting position.                            |
//+------------------------------------------------------------------+
class CRBMeta
  {
private:
   string            m_prefix;
   string            Key(ulong ticket, const string field) const
     {
      return m_prefix + "." + IntegerToString((long)ticket) + "." + field;
     }
public:
   void              Init(const string prefix)             { m_prefix = prefix; }
   string            Prefix(void) const                    { return m_prefix; }
   void              Set(ulong ticket, const string f, double v) { GlobalVariableSet(Key(ticket, f), v); }
   bool              Has(ulong ticket)                     { return GlobalVariableCheck(Key(ticket, "dir")); }
   double            Get(ulong ticket, const string f)
     {
      string k = Key(ticket, f);
      if(!GlobalVariableCheck(k))
         return 0.0;
      return GlobalVariableGet(k);
     }
   void              Delete(ulong ticket)
     {
      GlobalVariablesDeleteAll(m_prefix + "." + IntegerToString((long)ticket) + ".");
      GlobalVariablesFlush();
     }
   void              Flush(void)                           { GlobalVariablesFlush(); }
   //--- every ticket with stored metadata (keys <prefix>.<digits>.dir)
   int               Tickets(ulong &out[])
     {
      ArrayResize(out, 0);
      string head = m_prefix + ".";
      int hl = StringLen(head);
      for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
        {
         string name = GlobalVariableName(i);
         int l = StringLen(name);
         if(l <= hl + 4 || StringSubstr(name, 0, hl) != head || StringSubstr(name, l - 4) != ".dir")
            continue;
         string mid = StringSubstr(name, hl, l - 4 - hl);
         bool digits = StringLen(mid) > 0;
         for(int c = 0; c < StringLen(mid) && digits; c++)
           {
            ushort ch = StringGetCharacter(mid, c);
            digits = (ch >= '0' && ch <= '9');
           }
         if(!digits)
            continue;
         ulong t = (ulong)StringToInteger(mid);
         if(t == 0)
            continue;
         int k = ArraySize(out);
         ArrayResize(out, k + 1);
         out[k] = t;
        }
      return ArraySize(out);
     }
   //--- processed-signal markers (duplicate guard)
   string            SigKey(const string signal_id) const
     {
      string k = signal_id;
      StringReplace(k, "|", ".");
      return m_prefix + ".sig." + k;
     }
   bool              Processed(const string signal_id)     { return GlobalVariableCheck(SigKey(signal_id)); }
   void              MarkProcessed(const string signal_id)
     {
      GlobalVariableSet(SigKey(signal_id), (double)TimeCurrent());
      GlobalVariablesFlush();
     }
   //--- atomic claim: only one EA instance (same account/symbol/magic) wins a signal.
   //--- The temporary variable starts at 0; SetOnCondition flips it to 1 exactly once.
   bool              Claim(const string signal_id)
     {
      string k = signal_id;
      StringReplace(k, "|", ".");
      k = m_prefix + ".clm." + k;
      if(!GlobalVariableCheck(k) && !GlobalVariableTemp(k))
         return false;
      return GlobalVariableSetOnCondition(k, 1.0, 0.0);
     }
  };

//--- is there already an order, position or historical order with this signal id?
bool RB_SignalExistsAtBroker(const string sym, long magic, const string signal_id, int history_days)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) == magic && OrderGetString(ORDER_SYMBOL) == sym &&
         OrderGetString(ORDER_COMMENT) == signal_id)
         return true;
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == magic && PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetString(POSITION_COMMENT) == signal_id)
         return true;
     }
   if(HistorySelect(TimeCurrent() - history_days * 86400, TimeCurrent() + 86400))
     {
      for(int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = HistoryOrderGetTicket(i);
         if(t == 0)
            continue;
         if(HistoryOrderGetInteger(t, ORDER_MAGIC) == magic &&
            HistoryOrderGetString(t, ORDER_SYMBOL) == sym &&
            HistoryOrderGetString(t, ORDER_COMMENT) == signal_id)
            return true;
        }
     }
   return false;
  }

//--- DTBS signal id (order comment, <= 31 chars): DTBS|B|<break bar open time> / DTBS|S|<...>
string RB_DtbsSignalId(int dir, datetime break_time)
  {
   return (string)"DTBS|" + (dir == RB_DIR_BULL ? "B" : "S") + "|" + IntegerToString((long)break_time);
  }

//+------------------------------------------------------------------+
//| No hedging (Upcomers rule): is there an open position or pending |
//| order on `sym` (ANY magic, also manual) in the direction opposite|
//| to `dir`? `what` names the first one found.                      |
//+------------------------------------------------------------------+
bool RB_OppositeExposure(const string sym, int dir, string &what)
  {
   what = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != sym)
         continue;
      bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if((dir == RB_DIR_BULL && !buy) || (dir == RB_DIR_BEAR && buy))
        {
         what = StringFormat("position %I64u %s magic=%I64d", t, buy ? "BUY" : "SELL", PositionGetInteger(POSITION_MAGIC));
         return true;
        }
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != sym)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool buy  = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP ||
                   type == ORDER_TYPE_BUY_STOP_LIMIT);
      bool sell = (type == ORDER_TYPE_SELL || type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP ||
                   type == ORDER_TYPE_SELL_STOP_LIMIT);
      if((dir == RB_DIR_BULL && sell) || (dir == RB_DIR_BEAR && buy))
        {
         what = StringFormat("order %I64u %s magic=%I64d", t, EnumToString(type), OrderGetInteger(ORDER_MAGIC));
         return true;
        }
     }
   return false;
  }

//--- loss in account currency if a trade of `volume` goes from `from` to `to` (>= 0)
double RB_LossBetween(const string sym, ENUM_ORDER_TYPE type, double volume, double from, double to)
  {
   double p = 0.0;
   if(!OrderCalcProfit(type, sym, volume, from, to, p))
      return -1.0;
   return p < 0.0 ? -p : 0.0;
  }

//--- server time of the last 00:00 UTC (Upcomers resets the daily drawdown at 00:00 UTC).
//--- offset_sec = server time - UTC.
datetime RB_DayStart(datetime server_t, int offset_sec)
  {
   long utc = (long)server_t - offset_sec;
   long utc0 = utc - (utc % 86400);
   return (datetime)(utc0 + offset_sec);
  }

//--- slippage allowance in account currency for `volume` lots of `sym`
double RB_SlippageMoney(const string sym, double volume, double slippage_ticks)
  {
   if(!(slippage_ticks > 0.0))
      return 0.0;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(!(tv > 0.0))
      tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   return slippage_ticks * MathMax(tv, 0.0) * volume;
  }

//+------------------------------------------------------------------+
//| Account-wide risk snapshot. ALL positions and pending orders on  |
//| the account are included (any magic, any symbol) and treated as |
//| fully correlated. Every risk includes commission and the         |
//| slippage allowance (slippage_ticks x tick value per lot).        |
//+------------------------------------------------------------------+
bool RB_BuildSnapshot(long magic, double commission_rt_per_lot, double slippage_ticks, double day_start_ref,
                      int offset_sec, RBRiskSnapshot &s, string &err)
  {
   s.balance              = AccountInfoDouble(ACCOUNT_BALANCE);
   s.equity               = AccountInfoDouble(ACCOUNT_EQUITY);
   s.day_start_ref        = day_start_ref;
   s.realized_today       = 0.0;
   s.open_risk            = 0.0;
   s.open_risk_now        = 0.0;
   s.pending_risk         = 0.0;
   s.trades_today         = 0;
   s.positions            = 0;
   s.pending              = 0;
   s.unprotected_position = false;
   err = "";

   datetime day0 = RB_DayStart(TimeCurrent(), offset_sec);
   if(!HistorySelect(day0, TimeCurrent() + 60))
     {
      err = "HistorySelect failed";
      return false;
     }
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      s.realized_today += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
                          HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) == magic && HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         s.trades_today++;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;
      string sym  = PositionGetString(POSITION_SYMBOL);
      double sl   = PositionGetDouble(POSITION_SL);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      bool   buy  = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      ENUM_ORDER_TYPE ot = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(PositionGetInteger(POSITION_MAGIC) == magic)
         s.positions++;
      if(sl <= 0.0)
        {
         s.unprotected_position = true;
         continue;
        }
      double costs = commission_rt_per_lot * vol + RB_SlippageMoney(sym, vol, slippage_ticks);
      // open_risk: loss from OPEN price to SL (exposure / total DD caps)
      double loss = RB_LossBetween(sym, ot, vol, open, sl);
      if(loss < 0.0)
        {
         err = "OrderCalcProfit failed for position " + IntegerToString((long)t);
         return false;
        }
      s.open_risk += loss + costs;
      // open_risk_now: loss from the CURRENT close price to SL (daily check against equity,
      // which already contains the floating P/L)
      MqlTick tk;
      if(!SymbolInfoTick(sym, tk) || tk.bid <= 0.0 || tk.ask <= 0.0)
        {
         err = "no quote for position " + IntegerToString((long)t);
         return false;
        }
      double now_loss = RB_LossBetween(sym, ot, vol, buy ? tk.bid : tk.ask, sl);
      if(now_loss < 0.0)
        {
         err = "OrderCalcProfit failed (current) for position " + IntegerToString((long)t);
         return false;
        }
      s.open_risk_now += now_loss + costs;
     }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ENUM_ORDER_TYPE ot;
      if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT)
         ot = ORDER_TYPE_BUY;
      else if(type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_STOP_LIMIT)
         ot = ORDER_TYPE_SELL;
      else
         continue;
      if(OrderGetInteger(ORDER_MAGIC) == magic)
         s.pending++;
      string sym   = OrderGetString(ORDER_SYMBOL);
      double sl    = OrderGetDouble(ORDER_SL);
      double vol   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      if(sl <= 0.0)
        {
         s.unprotected_position = true;   // a pending order without SL is unbounded risk too
         continue;
        }
      double loss = RB_LossBetween(sym, ot, vol, price, sl);
      if(loss < 0.0)
        {
         err = "OrderCalcProfit failed for order " + IntegerToString((long)t);
         return false;
        }
      s.pending_risk += loss + commission_rt_per_lot * vol + RB_SlippageMoney(sym, vol, slippage_ticks);
     }
   return true;
  }

//--- realized P/L since day start, used to reconstruct the day-start balance after a restart
double RB_RealizedSince(datetime from)
  {
   double sum = 0.0;
   if(!HistorySelect(from, TimeCurrent() + 60))
      return 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      sum += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_COMMISSION) +
             HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_FEE);
     }
   return sum;
  }

//--- high-impact news window check (economic calendar; not available in the Strategy Tester).
//--- CalendarValueHistory returns bool; the event count is ArraySize(values). When the
//--- calendar cannot be read the check fails safe: blocked with what = "CALENDAR_UNAVAILABLE".
bool RB_NewsBlocked(const string currency, int minutes_before, int minutes_after, string &what)
  {
   what = "";
   datetime now = TimeTradeServer();
   MqlCalendarValue values[];
   ResetLastError();
   if(!CalendarValueHistory(values, now - minutes_after * 60, now + minutes_before * 60, NULL, currency))
     {
      what = "CALENDAR_UNAVAILABLE err=" + IntegerToString(GetLastError());
      return true;
     }
   int n = ArraySize(values);
   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
        {
         what = ev.name + " @ " + TimeToString(values[i].time, TIME_DATE | TIME_MINUTES);
         return true;
        }
     }
   return false;
  }

#endif
//==== end MQL5/Include/RBOTE/MT5Bridge.mqh ====
//==== begin MQL5/Include/RBOTE/Journal.mqh ====
//+------------------------------------------------------------------+
//| Journal.mqh - timestamped decision log + closed-trade CSV (MQL5) |
//+------------------------------------------------------------------+
#ifndef RBOTE_JOURNAL_MQH
#define RBOTE_JOURNAL_MQH

//==== begin MQL5/Include/RBOTE/Adaptive.mqh ====
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

//==== begin MQL5/Include/RBOTE/Regime.mqh ====
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
//==== end MQL5/Include/RBOTE/Regime.mqh ====

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
//==== end MQL5/Include/RBOTE/Adaptive.mqh ====

//--- strategy tags (spec 02 section 5): RBOTE = 1, DTBS = 2. Metadata field "sid".
#define RB_SID_RBOTE 1
#define RB_SID_DTBS  2

string RB_StrategyText(int sid)
  {
   if(sid == RB_SID_DTBS)
      return "DTBS";
   return "RBOTE";
  }

//--- strategy from a signal id prefix ("RBOTE|...", "DTBS|..."); "" for account-level events
string RB_StrategyFromSignalId(const string signal_id)
  {
   if(StringFind(signal_id, "DTBS|") == 0)
      return "DTBS";
   if(StringFind(signal_id, "RBOTE|") == 0)
      return "RBOTE";
   return "";
  }

//--- everything known about a closed trade: setup, conditions, sizing, outcome
struct RBTradeRow
  {
   datetime open_time;
   datetime close_time;
   datetime signal_time;
   int      dir;
   double   planned_entry;
   double   fill_price;
   double   sl;
   double   tp;
   double   volume;
   double   risk_money;
   double   net;
   double   r;
   string   signal_id;
   double   atr;
   int      zone_type;
   double   rr;
   int      stop_mode;
   double   exit_price;
   int      vol_class;
   bool     ranging;
   double   vol_ratio;
   double   er;
   double   risk_mult;
   string   exit_reason;
   double   mfe_r;
   double   mae_r;
   int      zones_hit;
   double   wick_ratio;
   double   rb_range_atr;
   double   stop_atr;
   int      fill_delay_bars;
   double   risk_pct;
   double   edge_mult;
   string   scale_reason;
   string   strategy;        // "RBOTE" / "DTBS" (last CSV column)
  };

string RB_JournalHeader(void) { return "server_time;gmt_time;event;signal_id;details;reason;strategy"; }

string RB_TradesHeader(void)
  {
   return (string)"open_time;close_time;dir;planned_entry;fill_price;sl;tp;volume;risk_money;net;r;signal_id;" +
          "atr;zone_type;rr;stop_mode;exit_price;regime;vol_ratio;er;risk_mult;" +
          "exit_reason;mfe_r;mae_r;session;hour;weekday;zones_hit;wick_ratio;rb_range_atr;stop_atr;" +
          "fill_delay_bars;risk_pct;edge_mult;scale_reason;strategy";
  }

class CRBJournal
  {
private:
   string            m_journal_file;
   string            m_trades_file;
   int               m_flags;
   bool              m_enabled;
   ulong             m_uid;

   int               OpenAppend(const string name, const string header)
     {
      int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | m_flags, ';');
      if(h == INVALID_HANDLE)
         return INVALID_HANDLE;
      if(FileSize(h) == 0)
         FileWrite(h, header);
      FileSeek(h, 0, SEEK_END);
      return h;
     }

   //--- an existing file written with another header (older EA version) is not appended to:
   //--- the new rows go to <name without .csv>_v2.csv (then _v3 ...) so every file has one schema
   string            Resolve(const string name, const string header)
     {
      string cur = name;
      for(int v = 2; v < 20; v++)
        {
         if(!FileIsExist(cur, m_flags))
            return cur;
         int h = FileOpen(cur, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE | m_flags);
         if(h == INVALID_HANDLE)
            return cur;
         string first = (FileSize(h) > 0) ? FileReadString(h) : header;
         FileClose(h);
         if(first == header)
            return cur;
         string stem = StringSubstr(name, 0, StringLen(name) - 4);
         cur = stem + "_v" + IntegerToString(v) + ".csv";
        }
      return cur;
     }

public:
                     CRBJournal(void) { m_enabled = false; m_flags = 0; m_uid = 0; }

   //--- tester runs write to the COMMON folder so results survive the agent sandbox; every tester
   //--- run gets a unique file suffix (parallel agents / repeated runs never share a file).
   //--- Optimization passes do not write files at all.
   void              Init(bool enabled, long magic)
     {
      bool tester = (bool)MQLInfoInteger(MQL_TESTER);
      m_enabled = enabled && !(bool)MQLInfoInteger(MQL_OPTIMIZATION);
      m_flags = tester ? FILE_COMMON : 0;
      if(m_uid == 0)
         m_uid = GetMicrosecondCount();   // fixed per EA instance, so a re-Init keeps the same files
      string base = "RBOTE\\" + (tester ? "tester_" : "") + _Symbol + "_" + IntegerToString(magic);
      if(tester)
        {
         MqlDateTime dt;
         TimeToStruct(TimeLocal(), dt);
         base += StringFormat("_%04d%02d%02d_%02d%02d%02d_%I64u", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec, m_uid);
        }
      else
         base += "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
      m_journal_file = m_enabled ? Resolve(base + "_journal.csv", RB_JournalHeader()) : base + "_journal.csv";
      m_trades_file  = m_enabled ? Resolve(base + "_trades.csv", RB_TradesHeader()) : base + "_trades.csv";
     }

   string            TradesFile(void) const { return m_trades_file; }

   //--- every decision: server time, GMT, event, signal id, details, reason, strategy.
   //--- strategy "" = taken from the signal id prefix (empty for account-level events)
   void              Log(const string event, const string signal_id, const string details, const string reason,
                         const string strategy = "")
     {
      string strat = (strategy != "") ? strategy : RB_StrategyFromSignalId(signal_id);
      PrintFormat("[RBOTE]%s %s %s | %s | %s", strat != "" ? "[" + strat + "]" : "", event, signal_id, details, reason);
      if(!m_enabled)
         return;
      int h = OpenAppend(m_journal_file, RB_JournalHeader());
      if(h == INVALID_HANDLE)
        {
         PrintFormat("[RBOTE] journal open failed: %d", GetLastError());
         return;
        }
      FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS), event, signal_id, details, reason, strat);
      FileClose(h);
     }

   //--- one row per closed position (input for tools/analyze_trades.py)
   void              Trade(const RBTradeRow &t)
     {
      if(!m_enabled)
         return;
      int h = OpenAppend(m_trades_file, RB_TradesHeader());
      if(h == INVALID_HANDLE)
         return;
      MqlDateTime dt;
      TimeToStruct(t.signal_time, dt);
      FileWrite(h, TimeToString(t.open_time, TIME_DATE | TIME_MINUTES),
                TimeToString(t.close_time, TIME_DATE | TIME_MINUTES),
                t.dir, DoubleToString(t.planned_entry, _Digits), DoubleToString(t.fill_price, _Digits),
                DoubleToString(t.sl, _Digits), DoubleToString(t.tp, _Digits), DoubleToString(t.volume, 2),
                DoubleToString(t.risk_money, 2), DoubleToString(t.net, 2), DoubleToString(t.r, 4),
                t.signal_id, DoubleToString(t.atr, _Digits), t.zone_type, DoubleToString(t.rr, 2), t.stop_mode,
                DoubleToString(t.exit_price, _Digits),
                (t.vol_class < 0 ? (string)"UNKNOWN" : RB_VolText(t.vol_class)) + (t.ranging ? "+RANGE" : ""),
                DoubleToString(t.vol_ratio, 3), DoubleToString(t.er, 3), DoubleToString(t.risk_mult, 2),
                t.exit_reason, DoubleToString(t.mfe_r, 2), DoubleToString(t.mae_r, 2),
                RB_SessionText(RB_SessionBucket(dt.hour)), dt.hour, dt.day_of_week, t.zones_hit,
                DoubleToString(t.wick_ratio, 3), DoubleToString(t.rb_range_atr, 3), DoubleToString(t.stop_atr, 3),
                t.fill_delay_bars, DoubleToString(t.risk_pct * 100.0, 3), DoubleToString(t.edge_mult, 3),
                t.scale_reason, t.strategy != "" ? t.strategy : RB_StrategyFromSignalId(t.signal_id));
      FileClose(h);
     }
  };

#endif
//==== end MQL5/Include/RBOTE/Journal.mqh ====
//==== begin MQL5/Include/RBOTE/DTBS.mqh ====
//+------------------------------------------------------------------+
//| DTBS.mqh - Dynamic Trend Break System (second strategy), pure    |
//| logic. Spec: docs/02_DTBS_SPESIFIKASYONU.md                      |
//|                                                                  |
//| Main trend BEAR (BULL is the mirror):                            |
//|   A  = confirmed swing low that starts the counter (up) move     |
//|   B  = highest confirmed swing high after A                      |
//|   leg  pB - pA >= min_leg_atr * ATR(B)                           |
//|   counter break: some close in (A, B] above the last swing high  |
//|        that was confirmed at A                                   |
//|   C  = (B + ext_bars, pB)                                        |
//|   line(t) = pA + (pB - pA) * (t - iA) / (iC - iA)                |
//|   active from B + swing_n (B confirmed) to iC inclusive          |
//| Signal at bar t (first break only, one per triangle):            |
//|   with trend: close[t] < line(t) and close[t-1] >= line(t-1)     |
//|   counter   : close[t] > pB                                      |
//|                                                                  |
//| Every structure carries the bar index at which it becomes known; |
//| nothing reads a bar after the bar it is evaluated on.            |
//+------------------------------------------------------------------+
#ifndef RBOTE_DTBS_MQH
#define RBOTE_DTBS_MQH


//--- trend states (BULL / BEAR reuse RB_DIR_*)
#define RB_TREND_NONE  0
#define RB_TREND_BULL  1
#define RB_TREND_BEAR -1

//--- triangle status
#define RB_DTBS_TRI_ACTIVE     0
#define RB_DTBS_TRI_USED       1  // produced its (single) signal
#define RB_DTBS_TRI_EXPIRED    2  // no break until iC
#define RB_DTBS_TRI_REPLACED   3  // newer structure (new triangle or new swing beyond B)
#define RB_DTBS_TRI_INVALID    4  // main trend changed
#define RB_DTBS_TRI_SUPPRESSED 5  // first break suppressed (WITH_TREND_ONLY counter break, ambiguous wick bar)

//--- DTBS-specific plan reject codes (others reuse RB_ReasonText codes)
#define RB_DTBS_ERR_BAD_SIGNAL      100
#define RB_DTBS_ERR_BAD_ENTRY       101
#define RB_DTBS_ERR_STOP_TOO_WIDE   102
#define RB_DTBS_ERR_STOP_BELOW_TICK 103
#define RB_DTBS_ERR_NO_ATR          104
#define RB_DTBS_ERR_BAD_SL_MODE     105
#define RB_DTBS_ERR_NO_BREAK_START  106
#define RB_DTBS_ERR_NO_ADAPTIVE_FIT 107
#define RB_DTBS_ERR_BAD_BUFFER      108

enum ENUM_RB_DTBS_BREAK_DIRS
  {
   RB_DTBS_BOTH            = 0, // with-trend and counter breaks both signal
   RB_DTBS_WITH_TREND_ONLY = 1
  };

enum ENUM_RB_DTBS_CONFIRM
  {
   RB_DTBS_CONFIRM_CLOSE = 0, // break needs the close beyond the level (default)
   RB_DTBS_CONFIRM_WICK  = 1  // high/low beyond the level is enough
  };

enum ENUM_RB_DTBS_SL_MODE
  {
   RB_DTBS_SL_BREAK_CANDLE = 0, // sell: high of break bar + buffer / buy: low - buffer
   RB_DTBS_SL_EXTREME      = 1, // sell: pB + buffer / buy: pB - buffer
   RB_DTBS_SL_ATR          = 2, // entry +/- sl_atr_mult * ATR
   RB_DTBS_SL_BREAK_START  = 3, // sell: highest high of bars (B, break) + buffer / buy: lowest low - buffer
   RB_DTBS_SL_ADAPTIVE     = 4  // first of BREAK_START, BREAK_CANDLE, EXTREME within [min,max] x ATR
  };

enum ENUM_RB_DTBS_HTF_AGREE
  {
   RB_DTBS_HTF_ALL      = 0, // every HTF must show the same trend
   RB_DTBS_HTF_MAJORITY = 1  // strictly more than half of the HTFs
  };

string RB_DtbsTrendText(int tr)
  {
   if(tr == RB_TREND_BULL) return "BULL";
   if(tr == RB_TREND_BEAR) return "BEAR";
   return "NONE";
  }

string RB_DtbsSlModeText(int m)
  {
   switch(m)
     {
      case RB_DTBS_SL_BREAK_CANDLE: return "BREAK_CANDLE";
      case RB_DTBS_SL_EXTREME:      return "EXTREME";
      case RB_DTBS_SL_ATR:          return "ATR";
      case RB_DTBS_SL_BREAK_START:  return "BREAK_START";
      case RB_DTBS_SL_ADAPTIVE:     return "ADAPTIVE";
     }
   return "UNKNOWN";
  }

string RB_DtbsStatusText(int st)
  {
   switch(st)
     {
      case RB_DTBS_TRI_ACTIVE:     return "ACTIVE";
      case RB_DTBS_TRI_USED:       return "USED";
      case RB_DTBS_TRI_EXPIRED:    return "EXPIRED";
      case RB_DTBS_TRI_REPLACED:   return "REPLACED";
      case RB_DTBS_TRI_INVALID:    return "INVALID";
      case RB_DTBS_TRI_SUPPRESSED: return "SUPPRESSED";
     }
   return "UNKNOWN";
  }

string RB_DtbsReasonText(int code)
  {
   switch(code)
     {
      case RB_DTBS_ERR_BAD_SIGNAL:      return "DTBS_BAD_SIGNAL";
      case RB_DTBS_ERR_BAD_ENTRY:       return "DTBS_BAD_ENTRY";
      case RB_DTBS_ERR_STOP_TOO_WIDE:   return "DTBS_STOP_TOO_WIDE_ATR";
      case RB_DTBS_ERR_STOP_BELOW_TICK: return "DTBS_STOP_BELOW_ONE_TICK";
      case RB_DTBS_ERR_NO_ATR:          return "DTBS_NO_ATR";
      case RB_DTBS_ERR_BAD_SL_MODE:     return "DTBS_BAD_SL_MODE";
      case RB_DTBS_ERR_NO_BREAK_START:  return "DTBS_NO_BREAK_START";
      case RB_DTBS_ERR_NO_ADAPTIVE_FIT: return "DTBS_NO_ADAPTIVE_LEVEL_FITS";
      case RB_DTBS_ERR_BAD_BUFFER:      return "DTBS_BAD_BUFFER";
     }
   return RB_ReasonText(code);
  }

struct RBDtbsConfig
  {
   int    swing_n;          // LTF fractal strength (ASSUMPTION 2)
   int    htf_swing_n;      // HTF fractal strength for the main trend
   int    atr_period;       // ATR14
   double min_leg_atr;      // pB - pA >= min_leg_atr * ATR(B)
   int    ext_bars;         // C = B + ext_bars (confirmed: 20 bars)
   int    max_leg_bars;     // ASSUMPTION: A is searched at most this many bars before B
   int    break_dirs;       // ENUM_RB_DTBS_BREAK_DIRS
   int    confirm;          // ENUM_RB_DTBS_CONFIRM
   int    sl_mode;          // ENUM_RB_DTBS_SL_MODE
   double sl_buffer_price;  // buffer = max(sl_buffer_price, spread)
   double sl_atr_mult;      // ATR mode
   double rr;               // TP = entry +/- rr * risk
   double min_stop_atr;     // ADAPTIVE: lower bound of the stop distance in ATR
   double max_stop_atr;     // reject when stop distance > max_stop_atr * ATR (0 = off)
   int    htf_agreement;    // ENUM_RB_DTBS_HTF_AGREE

   void              Defaults(void)
     {
      swing_n         = 2;
      htf_swing_n     = 2;
      atr_period      = 14;
      min_leg_atr     = 1.0;
      ext_bars        = 20;
      max_leg_bars    = 200;
      break_dirs      = RB_DTBS_BOTH;
      confirm         = RB_DTBS_CONFIRM_CLOSE;
      sl_mode         = RB_DTBS_SL_ADAPTIVE;
      sl_buffer_price = 0.30;
      sl_atr_mult     = 1.5;
      rr              = 1.5;
      min_stop_atr    = 0.5;
      max_stop_atr    = 3.0;
      htf_agreement   = RB_DTBS_HTF_ALL;
     }
  };

struct RBDtbsTriangle
  {
   int      id;          // sequential inside one scan
   int      trend;       // main trend the triangle belongs to (RB_TREND_BULL / BEAR)
   int      a_idx;
   double   a_price;
   int      b_idx;
   double   b_price;
   int      c_idx;       // b_idx + ext_bars
   double   c_price;     // = b_price
   int      ref_idx;     // swing that the counter move closed beyond (confirmed at A)
   int      cbreak_idx;  // first bar in (A, B] that closed beyond ref_idx
   int      known_idx;   // b_idx + swing_n: bar whose close makes the triangle known
   datetime known_time;
   double   atr;         // ATR at B
   int      status;      // RB_DTBS_TRI_*
   int      status_idx;  // bar where status last changed (-1 while active)
  };

struct RBDtbsSignal
  {
   int      tri_id;
   int      dir;              // RB_DIR_BULL = buy, RB_DIR_BEAR = sell
   int      main_trend;       // trend of the triangle
   bool     with_trend;       // true: diagonal break, false: counter break beyond pB
   int      break_idx;        // signal known after the close of this bar
   datetime break_time;       // open time of break_idx
   int      a_idx;
   double   a_price;
   int      b_idx;
   double   b_price;
   int      c_idx;
   double   c_price;
   int      known_idx;        // triangle known (B confirmed)
   double   line_at_break;    // line(break_idx)
   bool     close_confirmed;  // the close (not only the wick) broke the level
   double   atr;              // ATR at the break bar
   double   break_high;       // high / low of the break bar (BREAK_CANDLE stop)
   double   break_low;
   bool     start_valid;      // BREAK_START level exists (at least one bar in (B, break))
   int      start_idx;        // bar of that level
   double   start_price;      // sell: highest high in (B, break); buy: lowest low
  };

//+------------------------------------------------------------------+
//| HTF main trend                                                   |
//+------------------------------------------------------------------+
//--- Trend state after the close of every bar 0..last (inclusive) into out.
//--- State at k only reads bars <= k (swing j is used once j + n <= k).
void RB_DtbsTrendScan(const CRBSeries &s, int swing_n, int last, CRBVec<int> &out)
  {
   out.Clear();
   int state = RB_TREND_NONE;
   int sh = -1, sl = -1;
   if(last >= s.Size())
      last = s.Size() - 1;
   for(int k = 0; k <= last; k++)
     {
      int j = k - swing_n;
      if(j >= 0)
        {
         if(RB_IsSwingHigh(s, j, swing_n))
            sh = j;
         if(RB_IsSwingLow(s, j, swing_n))
            sl = j;
        }
      bool up = (sh >= 0 && s.C(k) > s.H(sh));
      bool dn = (sl >= 0 && s.C(k) < s.L(sl));
      if(up && !dn)
         state = RB_TREND_BULL;
      else if(dn && !up)
         state = RB_TREND_BEAR;
      out.Push(state);
     }
  }

void RB_DtbsTrendSeries(const CRBSeries &s, int swing_n, CRBVec<int> &out)
  {
   RB_DtbsTrendScan(s, swing_n, s.Size() - 1, out);
  }

int RB_DtbsTrendAt(const CRBSeries &s, int idx, int swing_n)
  {
   if(idx < 0 || idx >= s.Size())
      return RB_TREND_NONE;
   CRBVec<int> v;
   RB_DtbsTrendScan(s, swing_n, idx, v);
   int st = RB_TREND_NONE;
   v.Get(idx, st);
   return st;
  }

//--- Combine several HTF states. ALL: all equal and not NONE. MAJORITY: strictly > half.
int RB_DtbsCombine(const CRBVec<int> &states, int mode)
  {
   int n = states.Size();
   if(n == 0)
      return RB_TREND_NONE;
   int bull = 0, bear = 0, v = 0;
   for(int i = 0; i < n; i++)
     {
      states.Get(i, v);
      if(v == RB_TREND_BULL) bull++;
      if(v == RB_TREND_BEAR) bear++;
     }
   if(mode == RB_DTBS_HTF_MAJORITY)
     {
      if(bull * 2 > n) return RB_TREND_BULL;
      if(bear * 2 > n) return RB_TREND_BEAR;
      return RB_TREND_NONE;
     }
   if(bull == n) return RB_TREND_BULL;
   if(bear == n) return RB_TREND_BEAR;
   return RB_TREND_NONE;
  }

int RB_DtbsCombine2(int a, int b, int mode)
  {
   CRBVec<int> v;
   v.Push(a);
   v.Push(b);
   return RB_DtbsCombine(v, mode);
  }

//--- Index of the last HTF bar whose close time (open + htf_period_sec) is <= the close time
//--- of the LTF bar opening at ltf_open. -1 if none. HTF series must be chronological.
int RB_DtbsHtfIndexAt(const CRBSeries &htf, int htf_period_sec, datetime ltf_open, int ltf_period_sec)
  {
   long ltf_close = (long)ltf_open + (long)ltf_period_sec;
   int lo = 0, hi = htf.Size() - 1, ans = -1;
   while(lo <= hi)
     {
      int mid = (lo + hi) / 2;
      long c = (long)htf.Time(mid) + (long)htf_period_sec;
      if(c <= ltf_close)
        {
         ans = mid;
         lo = mid + 1;
        }
      else
         hi = mid - 1;
     }
   return ans;
  }

//--- out[k] = HTF trend of the last HTF bar closed at the close of LTF bar k (NONE if none).
void RB_DtbsAlignTrend(const CRBSeries &ltf, int ltf_period_sec, const CRBSeries &htf, int htf_period_sec,
                       const CRBVec<int> &htf_trend, CRBVec<int> &out)
  {
   out.Clear();
   for(int k = 0; k < ltf.Size(); k++)
     {
      int j = RB_DtbsHtfIndexAt(htf, htf_period_sec, ltf.Time(k), ltf_period_sec);
      int v = RB_TREND_NONE;
      if(j >= 0 && j < htf_trend.Size())
         htf_trend.Get(j, v);
      out.Push(v);
     }
  }

//--- Per-bar combination of two aligned trend vectors.
void RB_DtbsCombineSeries(const CRBVec<int> &a, const CRBVec<int> &b, int mode, CRBVec<int> &out)
  {
   out.Clear();
   int n = MathMin(a.Size(), b.Size());
   int x = 0, y = 0;
   for(int k = 0; k < n; k++)
     {
      a.Get(k, x);
      b.Get(k, y);
      int c = RB_DtbsCombine2(x, y, mode);   // MQL5: a reference parameter needs a variable
      out.Push(c);
     }
  }

//+------------------------------------------------------------------+
//| Triangle geometry                                                |
//+------------------------------------------------------------------+
double RB_DtbsLine(const RBDtbsTriangle &tr, int t)
  {
   return tr.a_price + (tr.b_price - tr.a_price) * (double)(t - tr.a_idx) / (double)(tr.c_idx - tr.a_idx);
  }

// "B-type" swing: swing high for a BEAR triangle (counter move up), swing low for BULL.
bool RB_DtbsIsBSwing(const CRBSeries &s, int j, int n, int trend)
  {
   return (trend == RB_TREND_BEAR) ? RB_IsSwingHigh(s, j, n) : RB_IsSwingLow(s, j, n);
  }

bool RB_DtbsIsASwing(const CRBSeries &s, int j, int n, int trend)
  {
   return (trend == RB_TREND_BEAR) ? RB_IsSwingLow(s, j, n) : RB_IsSwingHigh(s, j, n);
  }

double RB_DtbsBPrice(const CRBSeries &s, int j, int trend) { return (trend == RB_TREND_BEAR) ? s.H(j) : s.L(j); }
double RB_DtbsAPrice(const CRBSeries &s, int j, int trend) { return (trend == RB_TREND_BEAR) ? s.L(j) : s.H(j); }

//+------------------------------------------------------------------+
//| Triangle with B at b_idx (a B-type swing confirmed at            |
//| b_idx + swing_n) for main trend `trend`. Reads bars <= b+n only. |
//|  P = most recent B-type swing before B beyond pB (older structure)|
//|  A = most extreme A-type swing in (P, B) (earliest on ties)      |
//|  ref = last B-type swing confirmed at A; some close in (A, B]    |
//|        beyond it = counter break                                 |
//+------------------------------------------------------------------+
bool RB_DtbsBuildTriangle(const CRBSeries &s, const RBDtbsConfig &cfg, int trend, int b_idx, RBDtbsTriangle &tr)
  {
   int n = cfg.swing_n;
   if(trend != RB_TREND_BEAR && trend != RB_TREND_BULL)
      return false;
   if(cfg.ext_bars < 1 || n < 1 || b_idx + n >= s.Size())
      return false;
   if(!RB_DtbsIsBSwing(s, b_idx, n, trend))
      return false;
   double sg = (trend == RB_TREND_BEAR) ? 1.0 : -1.0;
   double pb = RB_DtbsBPrice(s, b_idx, trend);
   int lo = MathMax(0, b_idx - cfg.max_leg_bars);
   int start = lo;
   for(int j = b_idx - 1; j >= lo; j--)
     {
      if(RB_DtbsIsBSwing(s, j, n, trend) && sg * RB_DtbsBPrice(s, j, trend) > sg * pb)
        {
         start = j + 1;
         break;
        }
     }
   int a = -1;
   double pa = 0.0;
   for(int j = start; j < b_idx; j++)
     {
      if(!RB_DtbsIsASwing(s, j, n, trend))
         continue;
      double v = RB_DtbsAPrice(s, j, trend);
      if(a < 0 || sg * v < sg * pa)
        {
         a = j;
         pa = v;
        }
     }
   if(a < 0)
      return false;
   double leg = sg * (pb - pa);
   if(!(leg > 0.0))
      return false;
   double atr = s.ATR(b_idx);
   if(cfg.min_leg_atr > 0.0 && (atr <= 0.0 || leg < cfg.min_leg_atr * atr))
      return false;
   int ref = RB_LastConfirmedSwing(s, a, n, trend == RB_TREND_BEAR, cfg.max_leg_bars);
   if(ref < 0)
      return false;
   double rp = RB_DtbsBPrice(s, ref, trend);
   int cb = -1;
   for(int k = a + 1; k <= b_idx; k++)
     {
      if(sg * s.C(k) > sg * rp)
        {
         cb = k;
         break;
        }
     }
   if(cb < 0)
      return false;
   tr.id         = -1;
   tr.trend      = trend;
   tr.a_idx      = a;
   tr.a_price    = pa;
   tr.b_idx      = b_idx;
   tr.b_price    = pb;
   tr.c_idx      = b_idx + cfg.ext_bars;
   tr.c_price    = pb;
   tr.ref_idx    = ref;
   tr.cbreak_idx = cb;
   tr.known_idx  = b_idx + n;
   tr.known_time = s.Time(b_idx + n);
   tr.atr        = atr;
   tr.status     = RB_DTBS_TRI_ACTIVE;
   tr.status_idx = -1;
   return true;
  }

//--- Break of an active triangle at bar t. Returns 0 none, 1 with trend, 2 counter, 3 both (ambiguous).
int RB_DtbsBreakAt(const CRBSeries &s, const RBDtbsConfig &cfg, const RBDtbsTriangle &tr, int t,
                   bool &close_with, bool &close_counter)
  {
   close_with = false;
   close_counter = false;
   if(t < 1)
      return 0;
   bool bear = (tr.trend == RB_TREND_BEAR);
   double sg = bear ? 1.0 : -1.0;
   double lt = RB_DtbsLine(tr, t);
   double lp = RB_DtbsLine(tr, t - 1);
   bool wick = (cfg.confirm == RB_DTBS_CONFIRM_WICK);
   double xw = wick ? (bear ? s.L(t) : s.H(t)) : s.C(t);  // with-trend probe
   double xc = wick ? (bear ? s.H(t) : s.L(t)) : s.C(t);  // counter probe
   close_with    = sg * s.C(t) < sg * lt;
   close_counter = sg * s.C(t) > sg * tr.b_price;
   bool w = (sg * xw < sg * lt) && (sg * s.C(t - 1) >= sg * lp);
   bool c = (sg * xc > sg * tr.b_price);
   int r = 0;
   if(w) r += 1;
   if(c) r += 2;
   return r;
  }

void RB_DtbsSetStatus(CRBVec<RBDtbsTriangle> &tris, int i, int status, int k)
  {
   RBDtbsTriangle tr;
   tris.Get(i, tr);
   tr.status     = status;
   tr.status_idx = k;
   tris.Set(i, tr);
  }

void RB_DtbsFillSignal(const CRBSeries &s, const RBDtbsTriangle &tr, int t, bool with_trend,
                       bool close_confirmed, RBDtbsSignal &sig)
  {
   sig.tri_id          = tr.id;
   sig.main_trend      = tr.trend;
   sig.with_trend      = with_trend;
   sig.dir             = with_trend ? tr.trend : -tr.trend;
   sig.break_idx       = t;
   sig.break_time      = s.Time(t);
   sig.a_idx           = tr.a_idx;
   sig.a_price         = tr.a_price;
   sig.b_idx           = tr.b_idx;
   sig.b_price         = tr.b_price;
   sig.c_idx           = tr.c_idx;
   sig.c_price         = tr.c_price;
   sig.known_idx       = tr.known_idx;
   sig.line_at_break   = RB_DtbsLine(tr, t);
   sig.close_confirmed = close_confirmed;
   sig.atr             = s.ATR(t);
   sig.break_high      = s.H(t);
   sig.break_low       = s.L(t);
   // BREAK_START: sell -> highest high, buy -> lowest low of the bars strictly between B and the break bar
   sig.start_valid = false;
   sig.start_idx   = -1;
   sig.start_price = 0.0;
   for(int k = tr.b_idx + 1; k < t; k++)
     {
      double v = (sig.dir == RB_DIR_BEAR) ? s.H(k) : s.L(k);
      bool better = (sig.dir == RB_DIR_BEAR) ? (v >= sig.start_price) : (v <= sig.start_price);
      if(!sig.start_valid || better)
        {
         sig.start_valid = true;
         sig.start_idx   = k;
         sig.start_price = v;
        }
     }
  }

//+------------------------------------------------------------------+
//| Full deterministic scan over a closed-bar LTF window.            |
//|  main_trend[k] = combined HTF trend known at the close of bar k  |
//|  (caller aligns, see RB_DtbsAlignTrend). Missing -> NONE.        |
//| Per bar t: 1. expiry (t > iC)  2. trend change -> INVALID        |
//|  3. B-type swing confirmed at t: newer valid triangle replaces   |
//|     the active one (a swing beyond the active B also retires it) |
//|  4. break test of the active triangle at t -> at most 1 signal.  |
//| The EA acts only on a signal whose break_idx is the last bar.    |
//+------------------------------------------------------------------+
void RB_DtbsScanEx(CRBSeries &ltf, const CRBVec<int> &main_trend, const RBDtbsConfig &cfg,
                   CRBVec<RBDtbsTriangle> &tris, CRBVec<RBDtbsSignal> &signals)
  {
   tris.Clear();
   signals.Clear();
   RB_ComputeATR(ltf, cfg.atr_period);
   int n = ltf.Size();
   int act = -1;  // index into tris of the active triangle
   RBDtbsTriangle tr;
   for(int t = 1; t < n; t++)
     {
      int mt = RB_TREND_NONE;
      if(t < main_trend.Size())
         main_trend.Get(t, mt);
      //--- 1-2. expiry / trend change
      if(act >= 0)
        {
         tris.Get(act, tr);
         if(t > tr.c_idx)
           {
            RB_DtbsSetStatus(tris, act, RB_DTBS_TRI_EXPIRED, tr.c_idx);
            act = -1;
           }
         else if(tr.trend != mt)
           {
            RB_DtbsSetStatus(tris, act, RB_DTBS_TRI_INVALID, t);
            act = -1;
           }
        }
      //--- 3. new structure
      int j = t - cfg.swing_n;
      if(mt != RB_TREND_NONE && j >= 0 && RB_DtbsIsBSwing(ltf, j, cfg.swing_n, mt))
        {
         if(act >= 0)
           {
            tris.Get(act, tr);
            double sg = (tr.trend == RB_TREND_BEAR) ? 1.0 : -1.0;
            if(sg * RB_DtbsBPrice(ltf, j, mt) > sg * tr.b_price)
              {
               RB_DtbsSetStatus(tris, act, RB_DTBS_TRI_REPLACED, t);
               act = -1;
              }
           }
         RBDtbsTriangle nt;
         if(RB_DtbsBuildTriangle(ltf, cfg, mt, j, nt))
           {
            if(act >= 0)
               RB_DtbsSetStatus(tris, act, RB_DTBS_TRI_REPLACED, t);
            nt.id = tris.Size();
            tris.Push(nt);
            act = nt.id;
           }
        }
      //--- 4. break
      if(act < 0)
         continue;
      tris.Get(act, tr);
      if(t < tr.known_idx || t > tr.c_idx)
         continue;
      bool cw = false, cc = false;
      int r = RB_DtbsBreakAt(ltf, cfg, tr, t, cw, cc);
      if(r == 0)
         continue;
      if(r == 3 || (r == 2 && cfg.break_dirs == RB_DTBS_WITH_TREND_ONLY))
        {
         RB_DtbsSetStatus(tris, act, RB_DTBS_TRI_SUPPRESSED, t);
         act = -1;
         continue;
        }
      RBDtbsSignal sig;
      bool wt = (r == 1);
      RB_DtbsFillSignal(ltf, tr, t, wt, wt ? cw : cc, sig);
      signals.Push(sig);
      RB_DtbsSetStatus(tris, act, RB_DTBS_TRI_USED, t);
      act = -1;
     }
  }

void RB_DtbsScan(CRBSeries &ltf, const CRBVec<int> &main_trend, const RBDtbsConfig &cfg,
                 CRBVec<RBDtbsSignal> &signals)
  {
   CRBVec<RBDtbsTriangle> tris;
   RB_DtbsScanEx(ltf, main_trend, cfg, tris, signals);
  }

//+------------------------------------------------------------------+
//| Plan (market entry)                                              |
//+------------------------------------------------------------------+
//--- Raw (unrounded, unbuffered) structural level of a fixed SL mode; false if unavailable.
bool RB_DtbsRawLevel(const RBDtbsSignal &sig, int mode, double &level)
  {
   bool sell = (sig.dir == RB_DIR_BEAR);
   if(mode == RB_DTBS_SL_BREAK_CANDLE)
     {
      level = sell ? sig.break_high : sig.break_low;
      return true;
     }
   if(mode == RB_DTBS_SL_EXTREME)
     {
      level = sig.b_price;
      return true;
     }
   if(mode == RB_DTBS_SL_BREAK_START)
     {
      if(!sig.start_valid)
         return false;
      level = sig.start_price;
      return true;
     }
   return false;
  }

//--- SL for one fixed mode, rounded away from the entry. Returns 0 or a reason code.
int RB_DtbsStopFor(const RBDtbsSignal &sig, const RBDtbsConfig &cfg, const RBSymbolSpec &sp,
                   double entry, double buffer, int mode, double &sl)
  {
   bool sell = (sig.dir == RB_DIR_BEAR);
   double raw;
   if(mode == RB_DTBS_SL_ATR)
     {
      if(!(sig.atr > 0.0))
         return RB_DTBS_ERR_NO_ATR;
      if(!(cfg.sl_atr_mult > 0.0))
         return 5;
      raw = sell ? entry + cfg.sl_atr_mult * sig.atr : entry - cfg.sl_atr_mult * sig.atr;
     }
   else
     {
      double level = 0.0;
      if(!RB_DtbsRawLevel(sig, mode, level))
         return (mode == RB_DTBS_SL_BREAK_START) ? RB_DTBS_ERR_NO_BREAK_START : RB_DTBS_ERR_BAD_SL_MODE;
      raw = sell ? level + buffer : level - buffer;
     }
   if(sell && !(raw > entry))
      return 6;
   if(!sell && !(raw < entry))
      return 6;
   if(MathAbs(raw - entry) < sp.tick_size - RB_EPS)
      return RB_DTBS_ERR_STOP_BELOW_TICK;
   sl = sell ? RB_RoundUpToTick(raw, sp.tick_size) : RB_RoundDownToTick(raw, sp.tick_size);
   return 0;
  }

//+------------------------------------------------------------------+
//| Entry/SL/TP for a market entry at `entry`. spread = ask - bid    |
//| (buffer = max(sl_buffer_price, spread)). used_mode = the fixed   |
//| SL mode actually used (ADAPTIVE resolves to one of its levels).  |
//| Fixed modes: reject stop > max_stop_atr x ATR (0 = off).         |
//| ADAPTIVE: BREAK_START, BREAK_CANDLE, EXTREME in that order; the  |
//| first whose distance lies in [min_stop_atr, max_stop_atr] x ATR. |
//+------------------------------------------------------------------+
int RB_DtbsBuildPlanEx(const RBDtbsSignal &sig, const RBDtbsConfig &cfg, const RBSymbolSpec &sp,
                       double entry, double spread, RBPlan &plan, int &used_mode)
  {
   used_mode = -1;
   if(RB_ValidateSpec(sp) != 0)
      return 9;
   if(sig.dir != RB_DIR_BULL && sig.dir != RB_DIR_BEAR)
      return RB_DTBS_ERR_BAD_SIGNAL;
   if(!(entry > 0.0) || !MathIsValidNumber(entry))
      return RB_DTBS_ERR_BAD_ENTRY;
   if(!(cfg.rr > 0.0))
      return 18;
   if(cfg.sl_buffer_price < 0.0)
      return RB_DTBS_ERR_BAD_BUFFER;
   bool sell = (sig.dir == RB_DIR_BEAR);
   double buffer = MathMax(cfg.sl_buffer_price, MathMax(spread, 0.0));
   double e = RB_RoundToTick(entry, sp.tick_size);
   bool need_atr = (cfg.sl_mode == RB_DTBS_SL_ATR || cfg.sl_mode == RB_DTBS_SL_ADAPTIVE || cfg.max_stop_atr > 0.0);
   if(need_atr && !(sig.atr > 0.0))
      return RB_DTBS_ERR_NO_ATR;

   double sl = 0.0;
   int rc;
   if(cfg.sl_mode == RB_DTBS_SL_ADAPTIVE)
     {
      int order[3] = {RB_DTBS_SL_BREAK_START, RB_DTBS_SL_BREAK_CANDLE, RB_DTBS_SL_EXTREME};
      double lo = cfg.min_stop_atr * sig.atr;
      double hi = (cfg.max_stop_atr > 0.0) ? cfg.max_stop_atr * sig.atr : 0.0;
      for(int i = 0; i < 3; i++)
        {
         double cand = 0.0;
         if(RB_DtbsStopFor(sig, cfg, sp, e, buffer, order[i], cand) != 0)
            continue;
         double d = MathAbs(cand - e);
         if(d + RB_EPS < lo)
            continue;
         if(hi > 0.0 && d > hi + RB_EPS)
            continue;
         sl = cand;
         used_mode = order[i];
         break;
        }
      if(used_mode < 0)
         return RB_DTBS_ERR_NO_ADAPTIVE_FIT;
     }
   else
     {
      if(cfg.sl_mode != RB_DTBS_SL_BREAK_CANDLE && cfg.sl_mode != RB_DTBS_SL_EXTREME &&
         cfg.sl_mode != RB_DTBS_SL_ATR && cfg.sl_mode != RB_DTBS_SL_BREAK_START)
         return RB_DTBS_ERR_BAD_SL_MODE;
      rc = RB_DtbsStopFor(sig, cfg, sp, e, buffer, cfg.sl_mode, sl);
      if(rc != 0)
         return rc;
      if(cfg.max_stop_atr > 0.0 && MathAbs(sl - e) > cfg.max_stop_atr * sig.atr + RB_EPS)
         return RB_DTBS_ERR_STOP_TOO_WIDE;
      used_mode = cfg.sl_mode;
     }
   if(sell && !(sl > e))
      return 6;
   if(!sell && !(sl < e))
      return 6;
   double risk = MathAbs(e - sl);
   if(risk < sp.tick_size - RB_EPS)
      return RB_DTBS_ERR_STOP_BELOW_TICK;
   double tp = sell ? e - cfg.rr * risk : e + cfg.rr * risk;
   tp = RB_RoundToTick(tp, sp.tick_size);
   if(sell && !(tp < e))
      return 8;
   if(!sell && !(tp > e))
      return 8;
   plan.dir       = sig.dir;
   plan.entry     = e;
   plan.sl        = sl;
   plan.tp        = tp;
   plan.risk_dist = risk;
   plan.fib_level = 0.0;
   return 0;
  }

int RB_DtbsBuildPlan(const RBDtbsSignal &sig, const RBDtbsConfig &cfg, const RBSymbolSpec &sp,
                     double entry, RBPlan &plan, double spread = 0.0)
  {
   int used = -1;
   return RB_DtbsBuildPlanEx(sig, cfg, sp, entry, spread, plan, used);
  }

//--- Broker checks before a market order: stops/freeze level (11), stop >= mult * spread (12).
int RB_DtbsCheckMarket(const RBPlan &plan, const RBSymbolSpec &sp, double bid, double ask,
                       double min_stop_spread_mult)
  {
   double spread    = ask - bid;
   double min_level = (sp.stops_level + sp.freeze_level) * sp.point;
   if(plan.risk_dist + RB_EPS < min_level)
      return 11;
   if(MathAbs(plan.tp - plan.entry) + RB_EPS < min_level)
      return 11;
   if(plan.risk_dist + RB_EPS < min_stop_spread_mult * spread)
      return 12;
   return 0;
  }

#endif
//==== end MQL5/Include/RBOTE/DTBS.mqh ====

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
