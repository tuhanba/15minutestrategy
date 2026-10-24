//+------------------------------------------------------------------+
//| Types.mqh - shared enums, structs and containers (pure logic)    |
//+------------------------------------------------------------------+
#ifndef RBOTE_TYPES_MQH
#define RBOTE_TYPES_MQH

#include "Compat.mqh"

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
   RB_STOP_STRUCTURAL = 1  // RB extreme -/+ buffer (comparison variant)
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
