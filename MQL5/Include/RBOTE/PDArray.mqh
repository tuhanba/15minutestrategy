//+------------------------------------------------------------------+
//| PDArray.mqh - ATR, fractal swings, FVG and Order Block detection |
//| Pure logic. Every function only reads bars <= the index it is    |
//| asked about, so results never depend on future candles.         |
//+------------------------------------------------------------------+
#ifndef RBOTE_PDARRAY_MQH
#define RBOTE_PDARRAY_MQH

#include "Config.mqh"

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
