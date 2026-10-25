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

#include "PDArray.mqh"
#include "TradeMath.mqh"

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
