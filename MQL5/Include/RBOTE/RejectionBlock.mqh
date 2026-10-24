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

#include "PDArray.mqh"

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
