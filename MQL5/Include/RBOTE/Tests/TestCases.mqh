//+------------------------------------------------------------------+
//| TestCases.mqh - unit tests shared by                             |
//|   MQL5/Scripts/RBOTE/RBOTE_Tests.mq5  (inside MetaTrader 5)      |
//|   tests/cpp/run_tests.cpp             (g++, CI / Linux)          |
//+------------------------------------------------------------------+
#ifndef RBOTE_TESTCASES_MQH
#define RBOTE_TESTCASES_MQH

#include "../RejectionBlock.mqh"
#include "../TradeMath.mqh"
#include "../RiskGuard.mqh"
#include "../Safety.mqh"
#include "../Regime.mqh"
#include "../Adaptive.mqh"
#include "../TradeMgmt.mqh"
#include "../DTBS.mqh"

#ifndef __MQL5__
#include <cstdio>
inline void RB_TestPrint(string s) { std::printf("%s\n", s.c_str()); }
#else
void RB_TestPrint(string s) { Print(s); }
#endif

class CRBTest
  {
public:
   int               passed;
   int               failed;
                     CRBTest(void) { passed = 0; failed = 0; }
   void              Check(bool cond, string name)
     {
      if(cond)
         passed++;
      else
        {
         failed++;
         RB_TestPrint("FAIL: " + name);
        }
     }
   void              Near(double a, double b, double tol, string name)
     {
      bool ok = MathAbs(a - b) <= tol;
      if(!ok)
         RB_TestPrint("FAIL: " + name + " got " + DoubleToString(a, 6) + " expected " + DoubleToString(b, 6));
      if(ok)
         passed++;
      else
         failed++;
     }
  };

//--- helpers ---------------------------------------------------------
void T_Add(CRBSeries &s, double o, double h, double l, double c)
  {
   RBBar b;
   b.time  = (datetime)(1700000000 + 900 * s.Size());
   b.open  = o;
   b.high  = h;
   b.low   = l;
   b.close = c;
   s.Add(b);
  }

// Mirror price around 100 so a bullish fixture becomes the bearish one.
void T_AddMirror(CRBSeries &s, double o, double h, double l, double c)
  {
   T_Add(s, 200.0 - o, 200.0 - l, 200.0 - h, 200.0 - c);
  }

// Bullish fixture: swing high @2 (103), OB candle @5 [99, 100.6],
// displacement @6 closes 104.2 > 103 (BOS), bull FVG [100.6, 101.2] formed @7.
void T_BullBase(CRBSeries &s, bool mirror)
  {
   double b[8][4] =
     {
        {100.0, 101.0,  99.0, 100.0},
        {100.0, 102.0,  99.5, 101.5},
        {101.5, 103.0, 101.0, 102.5},
        {102.5, 102.8, 100.5, 101.0},
        {101.0, 101.5,  99.8, 100.2},
        {100.2, 100.6,  99.0,  99.5},
        { 99.5, 104.5,  99.4, 104.2},
        {104.2, 105.5, 101.2, 105.0}
     };
   for(int i = 0; i < 8; i++)
     {
      if(mirror)
         T_AddMirror(s, b[i][0], b[i][1], b[i][2], b[i][3]);
      else
         T_Add(s, b[i][0], b[i][1], b[i][2], b[i][3]);
     }
  }

// Pull-back and rejection candle @10: wick to 100.9 into the FVG, body low 102.0.
void T_BullRejection(CRBSeries &s, bool mirror)
  {
   double b[3][4] =
     {
        {105.0, 106.0, 104.5, 105.5},
        {105.5, 105.8, 103.0, 103.5},
        {102.3, 102.6, 100.9, 102.0}
     };
   for(int i = 0; i < 3; i++)
     {
      if(mirror)
         T_AddMirror(s, b[i][0], b[i][1], b[i][2], b[i][3]);
      else
         T_Add(s, b[i][0], b[i][1], b[i][2], b[i][3]);
     }
  }

void T_Cfg(RBConfig &cfg)
  {
   cfg.Defaults();
   cfg.stop_unit     = RB_UNIT_PRICE;
   cfg.stop_distance = 0.5;
  }

void T_Spec(RBSymbolSpec &sp)
  {
   sp.digits          = 2;
   sp.point           = 0.01;
   sp.tick_size       = 0.01;
   sp.tick_value_loss = 1.0;   // XAUUSD, 100 oz contract, USD account (typical, verify on broker)
   sp.vol_min         = 0.01;
   sp.vol_max         = 100.0;
   sp.vol_step        = 0.01;
   sp.stops_level     = 0;
   sp.freeze_level    = 0;
  }

int T_FindZone(CRBVec<RBZone> &zones, int type, int dir, RBZone &out)
  {
   RBZone z;
   for(int i = 0; i < zones.Size(); i++)
     {
      zones.Get(i, z);
      if(z.type == type && z.dir == dir)
        {
         out = z;
         return i;
        }
     }
   return -1;
  }

//--- 1-2. FVG ---------------------------------------------------------
void Test_FvgBull(CRBTest &t)
  {
   CRBSeries s;
   RBConfig cfg;
   T_Cfg(cfg);
   T_Add(s, 100.0, 101.0, 99.0, 100.5);
   T_Add(s, 100.5, 104.0, 100.4, 103.8);
   T_Add(s, 103.8, 105.0, 102.0, 104.5);
   CRBVec<RBZone> zones;
   RB_ComputeATR(s, cfg.atr_period);
   RB_DetectZones(s, cfg, zones);
   RBZone z;
   t.Check(T_FindZone(zones, RB_ZONE_FVG, RB_DIR_BULL, z) >= 0, "fvg bull found");
   t.Near(z.bottom, 101.0, 1e-9, "fvg bull bottom = high[i-2]");
   t.Near(z.top, 102.0, 1e-9, "fvg bull top = low[i]");
   t.Check(z.formed_idx == 2, "fvg bull formed on third candle");
   t.Check(T_FindZone(zones, RB_ZONE_FVG, RB_DIR_BEAR, z) < 0, "no bear fvg");
  }

void Test_FvgBear(CRBTest &t)
  {
   CRBSeries s;
   RBConfig cfg;
   T_Cfg(cfg);
   T_Add(s, 104.5, 105.0, 103.0, 104.0);
   T_Add(s, 104.0, 104.1, 100.0, 100.2);
   T_Add(s, 100.2, 102.0,  99.0,  99.5);
   CRBVec<RBZone> zones;
   RB_ComputeATR(s, cfg.atr_period);
   RB_DetectZones(s, cfg, zones);
   RBZone z;
   t.Check(T_FindZone(zones, RB_ZONE_FVG, RB_DIR_BEAR, z) >= 0, "fvg bear found");
   t.Near(z.top, 103.0, 1e-9, "fvg bear top = low[i-2]");
   t.Near(z.bottom, 102.0, 1e-9, "fvg bear bottom = high[i]");
  }

//--- 3. Order blocks ---------------------------------------------------
void Test_OrderBlocks(CRBTest &t)
  {
   RBConfig cfg;
   T_Cfg(cfg);
   for(int m = 0; m < 2; m++)
     {
      bool mirror = (m == 1);
      CRBSeries s;
      T_BullBase(s, mirror);
      CRBVec<RBZone> zones;
      RB_ComputeATR(s, cfg.atr_period);
      RB_DetectZones(s, cfg, zones);
      RBZone z;
      int dir = mirror ? RB_DIR_BEAR : RB_DIR_BULL;
      string tag = mirror ? "bear " : "bull ";
      t.Check(T_FindZone(zones, RB_ZONE_OB, dir, z) >= 0, tag + "ob found");
      t.Check(z.src_idx == 5, tag + "ob candle is last opposite candle before displacement");
      t.Check(z.formed_idx == 7, tag + "ob known only when FVG + BOS exist");
      if(!mirror)
        {
         t.Near(z.bottom, 99.0, 1e-9, "bull ob bottom = low[j]");
         t.Near(z.top, 100.6, 1e-9, "bull ob top = high[j]");
        }
      else
        {
         t.Near(z.bottom, 99.4, 1e-9, "bear ob bottom = low[j]");
         t.Near(z.top, 101.0, 1e-9, "bear ob top = high[j]");
        }
     }
   // swing confirmation: swing high @2 needs bars 3 and 4; not confirmed as of bar 3
   {
      CRBSeries sw;
      T_BullBase(sw, false);
      t.Check(RB_IsSwingHigh(sw, 2, 2), "fractal swing high @2");
      t.Check(RB_LastConfirmedSwing(sw, 3, 2, true, 100) == -1, "swing not confirmed before its right bars close");
      t.Check(RB_LastConfirmedSwing(sw, 4, 2, true, 100) == 2, "swing confirmed after 2 right bars");
   }
   // no BOS -> no OB: displacement closes below the swing high (103)
   CRBSeries s2;
   T_Add(s2, 100.0, 101.0,  99.0, 100.0);
   T_Add(s2, 100.0, 102.0,  99.5, 101.5);
   T_Add(s2, 101.5, 103.0, 101.0, 102.5);
   T_Add(s2, 102.5, 102.8, 100.5, 101.0);
   T_Add(s2, 101.0, 101.5,  99.8, 100.2);
   T_Add(s2, 100.2, 100.6,  99.0,  99.5);
   T_Add(s2,  99.5, 102.9,  99.4, 102.8);
   T_Add(s2, 102.8, 102.95, 101.2, 102.9);
   CRBVec<RBZone> z2;
   RB_ComputeATR(s2, cfg.atr_period);
   RB_DetectZones(s2, cfg, z2);
   RBZone zz;
   t.Check(T_FindZone(z2, RB_ZONE_FVG, RB_DIR_BULL, zz) >= 0, "fvg without bos still found");
   t.Check(T_FindZone(z2, RB_ZONE_OB, RB_DIR_BULL, zz) < 0, "no ob without break of structure");
  }

//--- 4-6. wick into PD array, RB confirmation, RB boundaries ----------
void Test_RejectionBlock(CRBTest &t)
  {
   RBConfig cfg;
   T_Cfg(cfg);
   for(int m = 0; m < 2; m++)
     {
      bool mirror = (m == 1);
      string tag = mirror ? "bear " : "bull ";
      CRBSeries s;
      T_BullBase(s, mirror);
      T_BullRejection(s, mirror);
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, cfg, zones, sigs);
      t.Check(sigs.Size() == 1, tag + "one RB signal");
      if(sigs.Size() < 1)
         continue;
      RBSignal g;
      sigs.Get(0, g);
      t.Check(g.rb_idx == 10 && g.confirm_idx == 10, tag + "rb on candle 10, confirmed at its close");
      t.Check(g.zone_type == RB_ZONE_FVG, tag + "primary zone is the FVG");
      if(!mirror)
        {
         t.Check(g.dir == RB_DIR_BULL, "bull dir");
         t.Near(g.rb_low, 100.9, 1e-9, "bull rb low = wick low");
         t.Near(g.rb_high, 102.0, 1e-9, "bull rb high = body low");
        }
      else
        {
         t.Check(g.dir == RB_DIR_BEAR, "bear dir");
         t.Near(g.rb_low, 98.0, 1e-9, "bear rb low = body high");
         t.Near(g.rb_high, 99.1, 1e-9, "bear rb high = wick high");
        }
     }

   // touch alone is not a signal: candle wicks into the FVG but its body closes inside the zone
   {
      CRBSeries s;
      T_BullBase(s, false);
      T_Add(s, 105.0, 106.0, 104.5, 105.5);
      T_Add(s, 105.5, 105.8, 103.0, 103.5);
      T_Add(s, 101.5, 101.6, 100.8, 101.1);
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, cfg, zones, sigs);
      t.Check(sigs.Size() == 0, "touch without rejection -> no signal");
      RBZone z;
      T_FindZone(zones, RB_ZONE_FVG, RB_DIR_BULL, z);
      t.Check(z.status == RB_ZONE_ACTIVE, "zone stays active after a touch");
   }

   // good wick but body closes inside the zone: rejected by BODY_OUTSIDE, accepted by NOT_THROUGH
   {
      CRBSeries s;
      T_BullBase(s, false);
      T_Add(s, 105.0, 106.0, 104.5, 105.5);
      T_Add(s, 105.5, 105.8, 103.0, 103.5);
      T_Add(s, 101.15, 101.25, 100.65, 101.18);
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, cfg, zones, sigs);
      t.Check(sigs.Size() == 0, "body inside zone -> no RB (BODY_OUTSIDE)");
      RBConfig c2;
      T_Cfg(c2);
      c2.rb_close_rule = RB_CLOSE_NOT_THROUGH;
      RB_Scan(s, c2, zones, sigs);
      t.Check(sigs.Size() == 1, "same candle is an RB under NOT_THROUGH");
   }

   // previous close already inside the zone: no approach -> no RB (unless disabled)
   {
      CRBSeries s;
      T_BullBase(s, false);
      T_Add(s, 105.0, 106.0, 104.5, 105.5);
      T_Add(s, 103.5, 103.6, 100.8, 101.0);    // closes inside the FVG, not a rejection
      T_Add(s, 101.9, 102.1, 100.9, 102.0);
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, cfg, zones, sigs);
      t.Check(sigs.Size() == 0, "no approach from outside -> no RB");
      RBConfig c2;
      T_Cfg(c2);
      c2.rb_require_approach = false;
      RB_Scan(s, c2, zones, sigs);
      t.Check(sigs.Size() == 1, "approach rule disabled -> RB");
   }

   // weak wick -> no RB
   {
      CRBSeries s;
      T_BullBase(s, false);
      T_Add(s, 105.0, 106.0, 104.5, 105.5);
      T_Add(s, 105.5, 105.8, 103.0, 103.5);
      T_Add(s, 103.4, 103.6, 100.9, 102.0);   // wick 1.1 / range 2.7 = 0.41 < 0.5
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, cfg, zones, sigs);
      t.Check(sigs.Size() == 0, "wick ratio below threshold -> no RB");
   }

   // NEXT_CLOSE confirmation: no signal on the RB candle itself
   {
      RBConfig c2;
      T_Cfg(c2);
      c2.rb_confirm = RB_CONFIRM_NEXT_CLOSE;
      CRBSeries s;
      T_BullBase(s, false);
      T_BullRejection(s, false);
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, c2, zones, sigs);
      t.Check(sigs.Size() == 0, "unconfirmed RB -> no signal / no order");
      T_Add(s, 102.0, 103.0, 101.5, 102.9);    // closes above RB candle high 102.6
      RB_Scan(s, c2, zones, sigs);
      t.Check(sigs.Size() == 1, "RB confirmed by next close");
      RBSignal g;
      if(sigs.Size() == 1)
        {
         sigs.Get(0, g);
         t.Check(g.confirm_idx == 11 && g.rb_idx == 10, "confirm index is the confirming candle");
        }
   }

   // NEXT_CLOSE: RB low swept before confirmation -> cancelled
   {
      RBConfig c2;
      T_Cfg(c2);
      c2.rb_confirm = RB_CONFIRM_NEXT_CLOSE;
      CRBSeries s;
      T_BullBase(s, false);
      T_BullRejection(s, false);
      T_Add(s, 102.0, 103.0, 100.7, 102.9);    // low 100.7 < RB low 100.9
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, c2, zones, sigs);
      t.Check(sigs.Size() == 0, "swept RB is cancelled");
   }
  }

//--- 16 / 18. zone used once, invalidation --------------------------
void Test_ZoneLifecycle(CRBTest &t)
  {
   RBConfig cfg;
   T_Cfg(cfg);
   // second rejection of the same zone -> no second signal
   {
      CRBSeries s;
      T_BullBase(s, false);
      T_BullRejection(s, false);
      T_Add(s, 102.0, 103.5, 101.8, 103.3);
      T_Add(s, 102.3, 102.6, 100.9, 102.0);    // same shape again
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, cfg, zones, sigs);
      t.Check(sigs.Size() == 1, "used zone does not signal twice");
      RBZone z;
      T_FindZone(zones, RB_ZONE_FVG, RB_DIR_BULL, z);
      t.Check(z.status == RB_ZONE_USED && z.status_idx == 10, "zone marked USED at the RB candle");
   }
   // close through the zone -> INVALID, later rejection ignored
   {
      CRBSeries s;
      T_BullBase(s, false);
      T_Add(s, 105.0, 106.0, 104.5, 105.5);
      T_Add(s, 105.5, 105.8,  98.0,  98.5);    // closes below FVG bottom and OB bottom
      T_Add(s,  98.5, 103.0,  98.4, 102.9);
      T_Add(s, 102.3, 102.6, 100.9, 102.0);
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, cfg, zones, sigs);
      RBZone z;
      T_FindZone(zones, RB_ZONE_FVG, RB_DIR_BULL, z);
      t.Check(z.status == RB_ZONE_INVALID && z.status_idx == 9, "close-through invalidates zone");
      bool bull_signal = false;
      RBSignal g;
      for(int i = 0; i < sigs.Size(); i++)
        {
         sigs.Get(i, g);
         if(g.dir == RB_DIR_BULL)
            bull_signal = true;
        }
      t.Check(!bull_signal, "invalid zone produces no signal");
   }
   // expiry
   {
      RBConfig c2;
      T_Cfg(c2);
      c2.zone_max_age_bars = 2;
      CRBSeries s;
      T_BullBase(s, false);
      T_BullRejection(s, false);
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, c2, zones, sigs);
      RBZone z;
      T_FindZone(zones, RB_ZONE_FVG, RB_DIR_BULL, z);
      t.Check(z.status == RB_ZONE_EXPIRED, "old zone expires");
      t.Check(sigs.Size() == 0, "expired zone produces no signal");
   }
   // duplicate guard: signal id is deterministic per RB candle and direction
   t.Check(RB_SignalId(RB_DIR_BULL, 1700009000) == RB_SignalId(RB_DIR_BULL, 1700009000), "signal id stable");
   t.Check(RB_SignalId(RB_DIR_BULL, 1700009000) != RB_SignalId(RB_DIR_BEAR, 1700009000), "signal id has direction");
   t.Check(RB_SignalId(RB_DIR_BULL, 1700009000) == "RBOTE|B|1700009000", "signal id format");
  }

//--- 7-11. Fibonacci, limit direction, SL side, 5R/6R ---------------
void Test_FibAndPlan(CRBTest &t)
  {
   RBConfig cfg;
   T_Cfg(cfg);
   RBSymbolSpec sp;
   T_Spec(sp);

   t.Near(RB_FibEntry(RB_DIR_BULL, 100.0, 110.0, 0.79), 102.1, 1e-9, "bull fib: H - 0.79(H-L)");
   t.Near(RB_FibEntry(RB_DIR_BEAR, 100.0, 110.0, 0.79), 107.9, 1e-9, "bear fib: L + 0.79(H-L)");
   t.Near(RB_FibEntry(RB_DIR_BULL, 100.0, 110.0, 0.0), 110.0, 1e-9, "bull fib 0 = RB high");
   t.Near(RB_FibEntry(RB_DIR_BULL, 100.0, 110.0, 1.0), 100.0, 1e-9, "bull fib 1 = RB low");

   RBSignal g;
   g.dir = RB_DIR_BULL;
   g.atr = 0.0;                    // ATR cap tested separately below
   g.rb_low = 2650.00;
   g.rb_high = 2660.00;
   RBPlan p;
   RBConfig c10;
   T_Cfg(c10);
   c10.stop_distance = 10.0;        // "Stop: 10.00" read as PRICE units (explicit choice)
   int r = RB_BuildPlan(g, c10, sp, p);
   t.Check(r == 0, "bull plan ok");
   t.Near(p.entry, 2652.10, 1e-6, "bull entry 0.79");
   t.Near(p.sl, 2642.10, 1e-6, "bull SL = entry - 10");
   t.Near(p.tp, 2712.10, 1e-6, "bull TP 6R = entry + 60");
   t.Check(p.sl < p.entry && p.tp > p.entry, "bull: SL below, TP above");
   c10.rr = 5.0;
   RB_BuildPlan(g, c10, sp, p);
   t.Near(p.tp, 2702.10, 1e-6, "bull TP 5R = entry + 50");

   g.dir = RB_DIR_BEAR;
   c10.rr = 6.0;
   r = RB_BuildPlan(g, c10, sp, p);
   t.Check(r == 0, "bear plan ok");
   t.Near(p.entry, 2657.90, 1e-6, "bear entry 0.79");
   t.Near(p.sl, 2667.90, 1e-6, "bear SL = entry + 10");
   t.Near(p.tp, 2597.90, 1e-6, "bear TP 6R = entry - 60");
   t.Check(p.sl > p.entry && p.tp < p.entry, "bear: SL above, TP below");

   // tick rounding direction: buy limit down, sell limit up
   g.dir = RB_DIR_BULL;
   g.rb_low = 100.9;
   g.rb_high = 102.0;
   RB_BuildPlan(g, cfg, sp, p);
   t.Near(p.entry, 101.13, 1e-9, "bull entry 101.131 -> 101.13 (floor)");
   t.Near(p.sl, 100.63, 1e-9, "bull SL entry - 0.5");
   t.Near(p.tp, 104.13, 1e-9, "bull TP 6R");
   g.dir = RB_DIR_BEAR;
   g.rb_low = 98.0;
   g.rb_high = 99.1;
   RB_BuildPlan(g, cfg, sp, p);
   t.Near(p.entry, 98.87, 1e-9, "bear entry 98.869 -> 98.87 (ceil)");

   // fixed stop inside the RB -> rejected, never silently widened
   g.dir = RB_DIR_BULL;
   g.rb_low = 2600.00;
   g.rb_high = 2700.00;            // entry 2621, entry-10 = 2611 > RB low 2600
   r = RB_BuildPlan(g, c10, sp, p);
   t.Check(r == 7, "fixed SL inside RB rejected (SL_INSIDE_RB)");

   // structural variant
   RBConfig cs;
   T_Cfg(cs);
   cs.stop_mode = RB_STOP_STRUCTURAL;
   cs.structural_buffer = 0.30;
   g.rb_low = 2650.00;
   g.rb_high = 2660.00;
   r = RB_BuildPlan(g, cs, sp, p);
   t.Check(r == 0, "structural plan ok");
   t.Near(p.sl, 2649.70, 1e-6, "structural SL = RB low - buffer");

   // structural stop vs ATR cap: entry 2652.10, SL 2649.70 -> risk 2.40
   g.atr = 1.00;                   // cap 3 x 1.00 = 3.00 >= 2.40
   t.Check(RB_BuildPlan(g, cs, sp, p) == 0, "structural stop within 3xATR ok");
   g.atr = 0.70;                   // cap 2.10 < 2.40
   r = RB_BuildPlan(g, cs, sp, p);
   t.Check(r == 19, "structural stop wider than 3xATR rejected");
   t.Check(RB_ReasonText(19) == "STOP_TOO_WIDE_ATR", "reason text 19");
   cs.max_stop_atr = 0.0;          // 0 = cap off
   t.Check(RB_BuildPlan(g, cs, sp, p) == 0, "ATR cap off -> structural ok");
   cs.max_stop_atr = 3.0;
   g.atr = 0.0;                    // unknown ATR never blocks
   t.Check(RB_BuildPlan(g, cs, sp, p) == 0, "ATR unknown -> cap skipped");
   cs.min_stop_atr = 3.0;          // stop 2.40 < 3 x 1.00 -> too tight
   g.atr = 1.00;
   t.Check(RB_BuildPlan(g, cs, sp, p) == 20, "structural stop tighter than min x ATR rejected");
   t.Check(RB_ReasonText(20) == "STOP_TOO_TIGHT_ATR", "reason text 20");
   cs.min_stop_atr = 0.0;

   // ATR stop: entry 2652.10, k = 2, ATR 2 -> SL 2648.10 (farther than RB low - buffer 2649.70)
   RBConfig ca;
   T_Cfg(ca);
   ca.stop_mode = RB_STOP_ATR;
   ca.structural_buffer = 0.30;
   ca.stop_atr_mult = 2.0;
   g.atr = 2.00;
   t.Check(RB_BuildPlan(g, ca, sp, p) == 0, "ATR stop plan ok");
   t.Near(p.sl, 2648.10, 1e-6, "ATR stop = entry - 2 x ATR");
   ca.max_stop_atr = 0.0;          // cap off: isolate the "farther of the two" rule
   g.atr = 0.50;                   // 2 x 0.5 = 1.00 would sit inside the RB -> RB low - buffer wins
   t.Check(RB_BuildPlan(g, ca, sp, p) == 0, "ATR stop small ATR plan ok");
   t.Near(p.sl, 2649.70, 1e-6, "ATR stop never inside RB extreme - buffer");
   ca.max_stop_atr = 3.0;
   g.dir = RB_DIR_BEAR;            // bear: entry 2657.90, SL 2657.90 + 4.00
   g.atr = 2.00;
   RB_BuildPlan(g, ca, sp, p);
   t.Near(p.sl, 2661.90, 1e-6, "bear ATR stop = entry + 2 x ATR");
   g.dir = RB_DIR_BULL;
   g.atr = 0.0;
   t.Check(RB_BuildPlan(g, ca, sp, p) == 5, "ATR stop without ATR rejected");

   c10.max_stop_atr = 3.0;
   g.atr = 0.70;                   // fixed mode: cap not applied (fixed stop is the user's choice)
   t.Check(RB_BuildPlan(g, c10, sp, p) != 19, "ATR cap ignored in fixed mode");
   g.atr = 0.0;

   // invalid RB range
   g.rb_low = 2660.00;
   g.rb_high = 2660.00;
   t.Check(RB_BuildPlan(g, c10, sp, p) == 1, "zero RB range rejected");

   // 9. limit direction vs market
   g.dir = RB_DIR_BULL;
   g.rb_low = 2650.00;
   g.rb_high = 2660.00;
   RB_BuildPlan(g, c10, sp, p);
   t.Check(RB_CheckMarket(p, c10, sp, 2659.80, 2660.00) == 0, "buy limit below ask ok");
   t.Check(RB_CheckMarket(p, c10, sp, 2651.80, 2652.00) == 10, "buy limit above ask rejected");
   g.dir = RB_DIR_BEAR;
   RB_BuildPlan(g, c10, sp, p);
   t.Check(RB_CheckMarket(p, c10, sp, 2650.00, 2650.20) == 0, "sell limit above bid ok");
   t.Check(RB_CheckMarket(p, c10, sp, 2658.00, 2658.20) == 10, "sell limit below bid rejected");
  }

//--- 12-14, 21, 23. units, spread/min stop, lots, costs, bad spec ---
void Test_UnitsLotsCosts(CRBTest &t)
  {
   RBSymbolSpec sp;
   T_Spec(sp);
   t.Near(RB_DistanceToPrice(10, RB_UNIT_POINTS, sp), 0.10, 1e-12, "10 points (digits 2) = 0.10");
   t.Near(RB_DistanceToPrice(10, RB_UNIT_TICKS, sp), 0.10, 1e-12, "10 ticks = 0.10");
   t.Near(RB_DistanceToPrice(10, RB_UNIT_PRICE, sp), 10.0, 1e-12, "10 price = 10.00");
   RBSymbolSpec sp3 = sp;
   sp3.digits = 3;
   sp3.point = 0.001;
   sp3.tick_size = 0.001;
   sp3.tick_value_loss = 0.1;
   t.Near(RB_DistanceToPrice(10, RB_UNIT_POINTS, sp3), 0.01, 1e-12, "10 points (digits 3) = 0.01");
   t.Check(RB_DistanceToPrice(10, -1, sp) < 0, "unknown unit");

   RBConfig cfg;
   T_Cfg(cfg);
   cfg.stop_unit = -1;
   RBSignal g;
   g.dir = RB_DIR_BULL;
   g.rb_low = 2650.0;
   g.rb_high = 2660.0;
   RBPlan p;
   t.Check(RB_BuildPlan(g, cfg, sp, p) == 4, "stop unit not set -> no trade");

   // 13. spread and broker minimum
   T_Cfg(cfg);
   cfg.stop_distance = 0.50;
   cfg.require_sl_beyond_rb = false;
   RB_BuildPlan(g, cfg, sp, p);
   RBSymbolSpec spm = sp;
   spm.stops_level = 60;           // 0.60 > 0.50 stop
   t.Check(RB_CheckMarket(p, cfg, spm, 2659.0, 2659.2) == 11, "stop below broker minimum rejected");
   t.Check(RB_CheckMarket(p, cfg, sp, 2659.0, 2659.3) == 12, "stop < 2x spread rejected");
   t.Check(RB_CheckMarket(p, cfg, sp, 2659.0, 2659.2) == 0, "stop >= 2x spread ok");
   cfg.stop_unit = RB_UNIT_POINTS;
   cfg.stop_distance = 10;          // 0.10 on digits=2
   RB_BuildPlan(g, cfg, sp, p);
   t.Check(RB_CheckMarket(p, cfg, sp, 2659.0, 2659.2) == 12, "10 MT5 points (0.10) < spread rule");

   // 14/21. lots, commission, slippage
   t.Near(RB_LossPerLot(1.00, sp, 7.0, 0.0), 107.0, 1e-9, "loss/lot 1.00 stop + 7 commission");
   t.Near(RB_LossPerLot(1.00, sp, 7.0, 5.0), 112.0, 1e-9, "loss/lot incl. 5 ticks slippage");
   double lots = 0;
   t.Check(RB_CalcLots(250.0, 107.0, sp, 0.0, lots) == 0, "lots ok");
   t.Near(lots, 2.33, 1e-9, "250 / 107 -> 2.33");
   t.Check(lots * 107.0 <= 250.0, "risk after rounding within budget");
   RB_CalcLots(250.0, 1007.0, sp, 0.0, lots);
   t.Near(lots, 0.24, 1e-9, "250 / 1007 -> 0.24");
   RB_CalcLots(245.0, 129.0, sp, 0.0, lots);
   t.Near(lots, 1.89, 1e-9, "245 / 129 -> 1.89");
   t.Check(RB_CalcLots(5.0, 1007.0, sp, 0.0, lots) == 14, "below volume min rejected (no round-up)");
   RB_CalcLots(250.0, 10.0, sp, 5.0, lots);
   t.Near(lots, 5.0, 1e-9, "capped by max lots");
   RBSymbolSpec sps = sp;
   sps.vol_step = 0.1;
   sps.vol_min = 0.1;
   RB_CalcLots(250.0, 107.0, sps, 0.0, lots);
   t.Near(lots, 2.3, 1e-9, "step 0.1 -> 2.3");
   t.Check(RB_CalcLots(0.0, 107.0, sp, 0.0, lots) == 17, "zero risk money rejected");
   t.Check(RB_CalcLots(250.0, 0.0, sp, 0.0, lots) == 16, "zero loss/lot rejected");

   RBRiskLimits lim;
   lim.Defaults();
   t.Near(RB_RiskMoney(lim, 100000.0, 100000.0), 250.0, 1e-9, "0.25% of 100k");
   t.Near(RB_RiskMoney(lim, 100000.0, 98000.0), 245.0, 1e-9, "uses min(balance, equity)");

   // 23. bad / missing symbol spec
   RBSymbolSpec bad = sp;
   bad.tick_value_loss = 0.0;
   t.Check(RB_ValidateSpec(bad) == 9, "tick value 0 rejected");
   bad = sp;
   bad.tick_size = 0.0;
   t.Check(RB_ValidateSpec(bad) == 9, "tick size 0 rejected");
   bad = sp;
   bad.vol_step = 0.0;
   t.Check(RB_ValidateSpec(bad) == 9, "volume step 0 rejected");
   bad = sp;
   bad.vol_max = 0.001;
   t.Check(RB_ValidateSpec(bad) == 9, "vol max < vol min rejected");
   t.Check(RB_ValidateSpec(sp) == 0, "valid spec");
   T_Cfg(cfg);
   bad = sp;
   bad.point = 0.0;
   t.Check(RB_BuildPlan(g, cfg, bad, p) == 9, "plan refused on bad spec");
  }

//--- 15. daily loss limit, open risk ---------------------------------
void Test_RiskGuard(CRBTest &t)
  {
   RBRiskLimits lim;
   lim.Defaults();
   lim.max_open_risk_pct = 0.0;
   lim.max_positions = 0;
   lim.max_pending = 0;
   RBRiskSnapshot s;
   s.balance = 99500.0;
   s.equity = 99500.0;
   s.day_start_ref = 100000.0;
   s.realized_today = -500.0;
   s.open_risk = 250.0;
   s.open_risk_now = 250.0;
   s.pending_risk = 250.0;
   s.trades_today = 1;
   s.positions = 1;
   s.pending = 1;
   s.unprotected_position = false;
   // limit 1% of 100k = 1000; worst equity = 99500 - 250 - 250 - new
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 2, "99500-250-250-250 = 98750 < 99000 -> denied");
   t.Check(RB_CheckNewOrder(lim, s, 0.0) == 0, "exactly 99000 is still allowed");
   s.pending_risk = 0.0;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 0, "99000 allowed when pending is gone");
   // overnight profit: day ref 101000 (equity at 00:00), position gave back 600 -> equity 100400
   RBRiskSnapshot o = s;
   o.balance = 100000.0;
   o.equity = 100400.0;
   o.day_start_ref = 101000.0;
   o.realized_today = 0.0;
   o.open_risk_now = 300.0;
   o.pending_risk = 0.0;
   t.Check(RB_CheckNewOrder(lim, o, 200.0) == 2, "overnight give-back counted: 100400-300-200 = 99900 < 100000");
   t.Check(RB_CheckNewOrder(lim, o, 50.0) == 0, "100400-300-50 = 100050 >= 100000");
   t.Check(!RB_DailyLimitBreached(lim, o), "equity 100400 vs ref 101000: -600 > -1010");
   o.equity = 99990.0;
   t.Check(RB_DailyLimitBreached(lim, o), "equity 99990 vs ref 101000: -1010 breached");
   // fixed daily amount on the initial balance (Ash Turbo style)
   RBRiskLimits fx = lim;
   fx.daily_on_initial = true;
   fx.initial_balance = 100000.0;
   t.Near(RB_DailyLimitMoney(fx, o), 1000.0, 1e-9, "daily limit on initial balance");
   t.Near(RB_DailyLimitMoney(lim, o), 1010.0, 1e-9, "daily limit on day reference");
   s.pending_risk = 250.0;
   s.equity = 100300.0;
   s.balance = 100300.0;
   s.day_start_ref = 100000.0;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 0, "realized profit offsets");
   s.unprotected_position = true;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 1, "position without SL blocks new orders");
   s.unprotected_position = false;
   s.equity = 99400.0;
   s.day_start_ref = 99400.0;   // isolate the exposure cap from the daily check
   lim.max_open_risk_pct = 0.005;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 3, "open+pending+new 750 > 0.5% of equity");
   lim.max_open_risk_pct = 0.0;
   s.equity = 100300.0;
   lim.max_trades_per_day = 1;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 5, "max trades per day");
   lim.max_trades_per_day = 0;
   lim.max_total_dd_pct = 0.05;
   lim.initial_balance = 100000.0;
   s.equity = 95400.0;
   s.day_start_ref = 95400.0;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 4, "total DD floor 95000");
   // trailing floor (Ash): peak 103000 -> floor 99000; locked at 100000 once the peak reaches 104000
   lim.trailing_dd = true;
   lim.max_total_dd_pct = 0.04;
   lim.peak_equity = 103000.0;
   t.Near(RB_TotalDDFloor(lim), 99000.0, 1e-9, "trailing floor = peak - 4% of initial");
   lim.peak_equity = 110000.0;
   t.Near(RB_TotalDDFloor(lim), 100000.0, 1e-9, "trailing floor locks at the initial balance");
   lim.peak_equity = 99000.0;
   t.Near(RB_TotalDDFloor(lim), 96000.0, 1e-9, "trailing floor never below the static floor");
   lim.peak_equity = 103000.0;
   s.equity = 99600.0;
   s.open_risk = 0.0;
   s.open_risk_now = 0.0;
   s.pending_risk = 0.0;
   s.realized_today = 0.0;
   s.day_start_ref = 99600.0;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 0, "99600 - 250 above trailing floor 99000");
   t.Check(RB_CheckNewOrder(lim, s, 700.0) == 4, "99600 - 700 below trailing floor 99000");
   // challenge state (Ash Turbo)
   t.Check(RB_ChallengeState(102000.0, 100000.0, 0.02, 3, false, 7, 1000, 5000) == RB_CH_TARGET, "2% reached");
   t.Check(RB_ChallengeState(101999.0, 100000.0, 0.02, 3, false, 7, 1000, 5000) == RB_CH_CONTINUE, "below target");
   t.Check(RB_ChallengeState(101000.0, 100000.0, 0.02, 7, true, 7, 1000, 5000) == RB_CH_CONTINUE, "day 7 in progress");
   t.Check(RB_ChallengeState(101000.0, 100000.0, 0.02, 7, false, 7, 1000, 5000) == RB_CH_DAYS_USED, "7 trading days used");
   t.Check(RB_ChallengeState(101000.0, 100000.0, 0.02, 2, false, 7, 5000, 5000) == RB_CH_EXPIRED, "30-day limit");
   t.Check(RB_ChallengeState(101000.0, 100000.0, 0.0, 9, false, 0, 1000, 0) == RB_CH_CONTINUE, "challenge rules off");
   lim.trailing_dd = false;
   s.equity = -1.0;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 8, "bad account state");
  }

//--- 17, 19, 22, 24. order life cycle and safety ---------------------
void Test_Safety(CRBTest &t)
  {
   // pending order invalidation (bull: tp 104.13, rb 100.9-102.0, zone 100.6-101.2)
   t.Check(RB_PendingCancelOnBar(RB_DIR_BULL, 104.13, 100.9, 102.0, 101.2, 100.6,
                                 103.0, 101.5, 102.5, 3, 8) == RB_CANCEL_NONE, "keep");
   t.Check(RB_PendingCancelOnBar(RB_DIR_BULL, 104.13, 100.9, 102.0, 101.2, 100.6,
                                 103.0, 101.5, 102.5, 8, 8) == RB_CANCEL_EXPIRED, "expired");
   t.Check(RB_PendingCancelOnBar(RB_DIR_BULL, 104.13, 100.9, 102.0, 101.2, 100.6,
                                 104.20, 101.5, 104.0, 1, 8) == RB_CANCEL_TP_REACHED, "tp before fill");
   t.Check(RB_PendingCancelOnBar(RB_DIR_BULL, 104.13, 100.9, 102.0, 101.2, 100.6,
                                 102.0, 100.7, 100.8, 1, 8) == RB_CANCEL_STRUCTURE, "close below RB low");
   t.Check(RB_PendingCancelOnBar(RB_DIR_BEAR, 95.0, 98.0, 99.1, 99.4, 98.8,
                                 99.3, 98.5, 99.2, 1, 8) == RB_CANCEL_STRUCTURE, "bear close above RB high");
   t.Check(RB_PendingTpReachedOnTick(RB_DIR_BULL, 104.13, 104.13, 104.33), "tick tp bull");
   t.Check(!RB_PendingTpReachedOnTick(RB_DIR_BEAR, 95.0, 95.1, 95.3), "tick tp bear not yet");

   // 19. reconciliation decisions
   t.Check(RB_ReconcileOrder(true) == RB_REC_KEEP, "known order kept");
   t.Check(RB_ReconcileOrder(false) == RB_REC_CANCEL, "unknown order cancelled");
   t.Check(RB_ReconcilePosition(true, false) == RB_REC_KEEP, "protected position kept");
   t.Check(RB_ReconcilePosition(false, true) == RB_REC_SET_SL, "missing SL restored");
   t.Check(RB_ReconcilePosition(false, false) == RB_REC_CLOSE, "unprotected unknown position closed");

   // SL never widened
   t.Check(RB_SlChangeAllowed(RB_DIR_BULL, 100.0, 100.5), "bull SL tighten ok");
   t.Check(!RB_SlChangeAllowed(RB_DIR_BULL, 100.0, 99.5), "bull SL widen refused");
   t.Check(!RB_SlChangeAllowed(RB_DIR_BEAR, 100.0, 100.5), "bear SL widen refused");

   // 22. disconnect / stale data
   t.Check(!RB_DataFresh(false, 1700000000, 1700000900 + 10, 900, 2), "disconnected -> not fresh");
   t.Check(RB_DataFresh(true, 1700000000, 1700000900 + 10, 900, 2), "connected, just closed -> fresh");
   t.Check(!RB_DataFresh(true, 1700000000, 1700000900 + 1800, 900, 2), "two bars missing -> stale");

   // 24. live trading disabled by default
   t.Check(RB_TradingPermission(false, RB_ACC_REAL, false, 12345, 12345, false, true) == 2, "real account refused by default");
   t.Check(RB_TradingPermission(false, RB_ACC_REAL, true, 999, 12345, true, true) == 3, "login confirmation mismatch");
   t.Check(RB_TradingPermission(false, RB_ACC_REAL, true, 12345, 12345, false, true) == 4, "prop rules unverified");
   t.Check(RB_TradingPermission(false, RB_ACC_REAL, true, 12345, 12345, true, true) == 0, "all gates -> live");
   t.Check(RB_TradingPermission(false, RB_ACC_DEMO, false, 12345, 12345, false, true) == 0, "confirmed demo allowed");
   t.Check(RB_TradingPermission(false, RB_ACC_DEMO, false, 0, 12345, false, true) == 3, "demo / prop evaluation needs login confirmation");
   t.Check(RB_TradingPermission(false, RB_ACC_DEMO, false, 0, 0, false, false) == 5, "not logged in -> refused (no silent demo)");
   t.Check(RB_TradingPermission(false, RB_ACC_DEMO, false, 12345, 12345, false, false) == 5, "not connected -> refused");
   t.Check(RB_TradingPermission(true, RB_ACC_REAL, false, 0, 12345, false, false) == 0, "tester allowed");
   t.Check(RB_TradingPermission(false, RB_ACC_CONTEST, true, 12345, 12345, true, true) == 1, "contest refused");
  }

//--- 20. lookahead: signals known at bar t never change when future bars are added
uint T_Rand(uint &state)
  {
   state = state * 1664525 + 1013904223;
   return state >> 8;
  }

void T_RandomSeries(CRBSeries &s, int n, uint seed)
  {
   uint st = seed;
   double price = 2000.0;
   for(int i = 0; i < n; i++)
     {
      double o = price;
      double move = ((double)(T_Rand(st) % 2001) - 1000.0) / 100.0;  // +-10
      double c = o + move;
      double up = ((double)(T_Rand(st) % 801)) / 100.0;
      double dn = ((double)(T_Rand(st) % 801)) / 100.0;
      double h = MathMax(o, c) + up;
      double l = MathMin(o, c) - dn;
      T_Add(s, MathRound(o * 100) / 100, MathRound(h * 100) / 100, MathRound(l * 100) / 100, MathRound(c * 100) / 100);
      price = c;
     }
  }

bool T_SameSignal(const RBSignal &a, const RBSignal &b)
  {
   return a.dir == b.dir && a.rb_idx == b.rb_idx && a.confirm_idx == b.confirm_idx &&
          a.rb_low == b.rb_low && a.rb_high == b.rb_high && a.zone_id == b.zone_id;
  }

void Test_Lookahead(CRBTest &t)
  {
   for(int mode = 0; mode < 2; mode++)
     {
      RBConfig cfg;
      T_Cfg(cfg);
      cfg.rb_close_rule = RB_CLOSE_NOT_THROUGH;
      cfg.rb_min_wick_ratio = 0.3;
      cfg.rb_confirm = (mode == 0) ? RB_CONFIRM_RB_CLOSE : RB_CONFIRM_NEXT_CLOSE;
      CRBSeries full;
      T_RandomSeries(full, 400, 12345 + mode);
      CRBVec<RBZone> zf;
      CRBVec<RBSignal> sf;
      RB_Scan(full, cfg, zf, sf);
      t.Check(sf.Size() > 5, "random series produces signals (mode " + IntegerToString(mode) + ")");
      bool ok = true;
      for(int cut = 50; cut < full.Size(); cut += 7)
        {
         CRBSeries part;
         RBBar b;
         for(int i = 0; i < cut; i++)
           {
            full.Bar(i, b);
            part.Add(b);
           }
         CRBVec<RBZone> zp;
         CRBVec<RBSignal> sp;
         RB_Scan(part, cfg, zp, sp);
         // every signal known in the truncated series must exist identically in the full one, and vice versa
         int expected = 0;
         RBSignal a, c;
         for(int i = 0; i < sf.Size(); i++)
           {
            sf.Get(i, a);
            if(a.confirm_idx < cut)
               expected++;
           }
         if(expected != sp.Size())
            ok = false;
         for(int i = 0; i < sp.Size() && ok; i++)
           {
            sp.Get(i, c);
            sf.Get(i, a);
            if(!T_SameSignal(a, c))
               ok = false;
           }
         // zones formed before the cut are identical
         RBZone x, y;
         int zc = 0;
         for(int i = 0; i < zf.Size(); i++)
           {
            zf.Get(i, x);
            if(x.formed_idx < cut)
               zc++;
           }
         if(zc != zp.Size())
            ok = false;
         for(int i = 0; i < zp.Size() && ok; i++)
           {
            zp.Get(i, y);
            zf.Get(i, x);
            if(x.top != y.top || x.bottom != y.bottom || x.formed_idx != y.formed_idx || x.type != y.type)
               ok = false;
           }
        }
      t.Check(ok, "no lookahead: truncated == full up to cut (mode " + IntegerToString(mode) + ")");
     }
  }

//--- volatility / range regime ---------------------------------------
// n bars with range 1.0; the last `tail` bars get range tail_range; closes move by `step`.
void T_RegSeries(CRBSeries &s, int n, int tail, double tail_range, double step)
  {
   for(int i = 0; i < n; i++)
     {
      double r = (i >= n - tail) ? tail_range : 1.0;
      double c = 100.0 + step * i;
      T_Add(s, c, c + r / 2.0, c - r / 2.0, c);
     }
  }

void Test_Regime(CRBTest &t)
  {
   RBRegimeCfg rc;
   rc.Defaults();
   RBRegime r;
   RBRegimeDecision d;

   {
      CRBSeries s;
      T_RegSeries(s, 1100, 0, 1.0, 0.1);
      RB_ComputeATR(s, 14);
      t.Check(RB_ClassifyRegime(s, 1099, rc, r), "regime classified");
      t.Near(r.vol_ratio, 1.0, 1e-6, "flat volatility -> VR 1");
      t.Check(r.vol_class == RB_VOL_NORMAL, "normal volatility");
      t.Near(r.er, 1.0, 1e-9, "steady trend -> ER 1");
      t.Check(!r.ranging, "trend is not ranging");
      RB_RegimeDecide(r, rc, 6.0, d);
      t.Check(d.allow && d.risk_mult == 1.0 && d.rr == 6.0, "normal trend -> full risk, 6R");
   }
   {
      CRBSeries s;
      T_RegSeries(s, 1100, 14, 3.0, 0.1);
      RB_ComputeATR(s, 14);
      RB_ClassifyRegime(s, 1099, rc, r);
      t.Check(r.vol_class == RB_VOL_HIGH, "range x3 for 14 bars -> HIGH");
      RB_RegimeDecide(r, rc, 6.0, d);
      t.Check(d.allow && d.risk_mult == 0.5, "high volatility -> half risk (default)");
   }
   {
      CRBSeries s;
      T_RegSeries(s, 1100, 14, 6.0, 0.1);
      RB_ComputeATR(s, 14);
      RB_ClassifyRegime(s, 1099, rc, r);
      t.Check(r.vol_class == RB_VOL_EXTREME, "range x6 -> EXTREME");
      RB_RegimeDecide(r, rc, 6.0, d);
      t.Check(!d.allow && d.reason == "EXTREME", "extreme volatility -> no trade (default)");
   }
   {
      CRBSeries s;
      T_RegSeries(s, 1100, 40, 0.3, 0.0);
      RB_ComputeATR(s, 14);
      RB_ClassifyRegime(s, 1099, rc, r);
      t.Check(r.vol_class == RB_VOL_LOW, "quiet tail -> LOW");
      t.Check(r.ranging && r.er == 0.0, "flat closes -> ranging");
      RB_RegimeDecide(r, rc, 6.0, d);
      t.Check(d.allow && d.risk_mult == 0.5 && d.reason == "LOW+RANGE", "low + range -> half risk");
      RBRegimeCfg skip = rc;
      skip.trade_range = false;
      RB_RegimeDecide(r, skip, 6.0, d);
      t.Check(!d.allow, "range policy skip wins");
      RBRegimeCfg rr = rc;
      rr.rr_low = 4.0;
      rr.rr_range = 3.0;
      RB_RegimeDecide(r, rr, 6.0, d);
      t.Near(d.rr, 3.0, 1e-12, "range RR override has priority");
      rr.risk_mult_low = 0.25;
      RB_RegimeDecide(r, rr, 6.0, d);
      t.Near(d.risk_mult, 0.25, 1e-12, "most conservative multiplier wins");
   }
   {
      CRBSeries s;
      T_RegSeries(s, 1100, 0, 1.0, 0.0);
      RB_ComputeATR(s, 14);
      RB_ClassifyRegime(s, 1099, rc, r);
      t.Check(r.vol_class == RB_VOL_NORMAL && r.ranging, "normal volatility, sideways");
      RBRegimeCfg rg = rc;
      rg.risk_mult_range = 0.3;
      RB_RegimeDecide(r, rg, 6.0, d);
      t.Check(d.allow && d.reason == "NORMAL+RANGE", "normal + range tag");
      t.Near(d.risk_mult, 0.3, 1e-12, "range multiplier applied in normal volatility");
   }
   {
      // too little history -> unknown -> skip; disabled -> always allowed
      CRBSeries s;
      T_RegSeries(s, 100, 0, 1.0, 0.1);
      RB_ComputeATR(s, 14);
      t.Check(!RB_ClassifyRegime(s, 99, rc, r), "short history -> invalid");
      RB_RegimeDecide(r, rc, 6.0, d);
      t.Check(!d.allow && d.reason == "REGIME_UNKNOWN", "unknown regime -> skip");
      RBRegimeCfg off = rc;
      off.enabled = false;
      RB_RegimeDecide(r, off, 6.0, d);
      t.Check(d.allow && d.risk_mult == 1.0 && d.rr == 6.0, "regime filter off -> unchanged");
      RBRegimeCfg neu;
      neu.Neutral();
      RBRegime ex;
      ex.valid = true;
      ex.vol_class = RB_VOL_EXTREME;
      ex.ranging = true;
      ex.vol_ratio = 3.0;
      ex.er = 0.1;
      RB_RegimeDecide(ex, neu, 6.0, d);
      t.Check(d.allow && d.risk_mult == 1.0, "neutral baseline trades every regime at full risk");
   }
   {
      // no lookahead: regime at k ignores bars after k
      CRBSeries a, b;
      T_RegSeries(a, 1100, 0, 1.0, 0.1);
      T_RegSeries(b, 1100, 0, 1.0, 0.1);
      T_Add(b, 300.0, 400.0, 200.0, 350.0);
      RB_ComputeATR(a, 14);
      RB_ComputeATR(b, 14);
      RBRegime ra, rb2;
      RB_ClassifyRegime(a, 1099, rc, ra);
      RB_ClassifyRegime(b, 1099, rc, rb2);
      t.Check(ra.vol_ratio == rb2.vol_ratio && ra.er == rb2.er, "regime uses closed bars up to k only");
   }
  }

//--- profit-funded scaling, edge weighting, features ----------------
void Test_Adaptive(CRBTest &t)
  {
   RBScaleCfg sc;
   sc.Defaults();
   string why;
   // no profit -> base
   t.Near(RB_ProfitScaledPct(sc, 100000, 100000, 100000, 100000, 0, why), 0.0025, 1e-12, "no profit -> base 0.25%");
   t.Near(RB_ProfitScaledPct(sc, 100000, 97000, 100000, 97000, 0, why), 0.0025, 1e-12, "in loss -> base, never below");
   t.Near(RB_ProfitScaledPct(sc, 100000, 99000, 100000, 99000, 0, why), 0.0025, 1e-12, "small loss, no brake -> still base, never below");
   t.Check(why == "BASE", "small loss reason");
   // +5000 profit, 2% share -> +100 -> 0.25% + 100/105000
   double p = RB_ProfitScaledPct(sc, 100000, 105000, 105000, 105000, 0, why);
   t.Near(p, 0.0025 + 100.0 / 105000.0, 1e-12, "+5000 profit -> extra 100 risk");
   t.Check(why == "SCALED", "scaled reason");
   t.Check(p * 105000 - 0.0025 * 105000 <= 0.02 * 5000 + 1e-9, "extra risk funded only from profit share");
   // cap
   t.Near(RB_ProfitScaledPct(sc, 100000, 200000, 200000, 200000, 0, why), 0.005, 1e-12, "capped at max 0.5%");
   t.Check(why == "SCALED_CAPPED", "capped reason");
   // brakes
   t.Near(RB_ProfitScaledPct(sc, 100000, 105000, 108000, 105000, 0, why), 0.0025, 1e-12, "2.8% below HWM -> base");
   t.Check(why == "BASE_DRAWDOWN_BRAKE", "drawdown brake reason");
   t.Near(RB_ProfitScaledPct(sc, 100000, 105000, 105000, 105000, 3, why), 0.0025, 1e-12, "3 losses in a row -> base");
   t.Check(why == "BASE_LOSS_STREAK", "loss streak reason");
   RBScaleCfg off = sc;
   off.enabled = false;
   t.Near(RB_ProfitScaledPct(off, 100000, 150000, 150000, 150000, 0, why), 0.0025, 1e-12, "scaling off -> base");

   // final risk money cap
   t.Near(RB_FinalRiskMoney(0.0025, 100000, 1.0, 1.0, 0.005), 250.0, 1e-9, "base risk 250");
   t.Near(RB_FinalRiskMoney(0.0045, 100000, 1.0, 1.5, 0.005), 500.0, 1e-9, "edge x1.5 capped at 0.5%");
   t.Near(RB_FinalRiskMoney(0.0025, 100000, 0.5, 1.2, 0.005), 150.0, 1e-9, "regime x edge multipliers");

   // features
   RBFeatures f;
   RB_MakeFeatures(RB_DIR_BEAR, RB_ZONE_OB, RB_VOL_HIGH, true, 14, f);
   t.Check(f.b[RB_DIM_DIR] == 1 && f.b[RB_DIM_ZONE] == 1 && f.b[RB_DIM_VOL] == RB_VOL_HIGH &&
           f.b[RB_DIM_RANGE] == 1 && f.b[RB_DIM_SESSION] == 2, "feature buckets");
   t.Check(RB_SessionBucket(0) == 0 && RB_SessionBucket(6) == 1 && RB_SessionBucket(23) == 3, "session buckets");

   // edge weighting
   RBEdgeCfg ec;
   ec.Defaults();
   CRBEdgeStats st;
   RBFeatures win, lose;
   RB_MakeFeatures(RB_DIR_BULL, RB_ZONE_FVG, RB_VOL_NORMAL, false, 9, win);   // longs, FVG, London-ish
   RB_MakeFeatures(RB_DIR_BEAR, RB_ZONE_OB, RB_VOL_HIGH, true, 20, lose);     // all buckets differ
   for(int i = 0; i < 20; i++)
      st.Add(win, 2.0);
   t.Near(st.Mult(win, ec, why), 1.0, 1e-12, "warm-up: no weighting before min_total");
   t.Check(why == "EDGE_WARMUP", "warm-up reason");
   for(int i = 0; i < 20; i++)
      st.Add(lose, -1.0);
   double mw = st.Mult(win, ec, why);
   double ml = st.Mult(lose, ec, why);
   t.Near(mw, 1.5, 1e-12, "winning bucket -> more risk (capped 1.5)");          // 1 + 0.15 * 5 * (40/40)
   t.Near(ml, 1.0 + 0.15 * 5 * (-20.0 / 40.0), 1e-12, "losing bucket -> less risk"); // 0.625
   t.Check(ml >= ec.min_mult && ml < 1.0, "losing bucket within floor");
   t.Near(st.Shrunk(RB_DIM_DIR, 0, ec.prior), 40.0 / 40.0, 1e-12, "shrinkage: 20 trades x 2R / (20 + 20)");
   // explanation: 20 longs at +2R -> shrunk 40/40 = 1.0 -> contrib 0.15 per matching dimension
   string ex = RB_EdgeExplain(st, win, ec);
   t.Check(StringFind(ex, "dir=LONG n=20 avgR=2.00 contrib=0.150") >= 0, "edge explanation names bucket, n, avgR, contribution");
   t.Check(StringFind(ex, "session=H06-11") >= 0, "edge explanation includes session");
   RBEdgeCfg eoff = ec;
   eoff.enabled = false;
   t.Near(st.Mult(win, eoff, why), 1.0, 1e-12, "edge off -> 1");

   // excursions
   t.Near(RB_ExcursionR(RB_DIR_BULL, 2652.10, 2664.10, 10.0), 1.2, 1e-9, "long MFE in R");
   t.Near(RB_ExcursionR(RB_DIR_BEAR, 2657.90, 2662.90, 10.0), -0.5, 1e-9, "short adverse excursion in R");
  }

//--- trade management (breakeven / trailing / partial) -------------
void Test_TradeMgmt(CRBTest &t)
  {
   RBMgmtCfg c;
   c.Defaults();
   // all off -> stop unchanged
   t.Near(RB_MgmtStop(RB_DIR_BULL, 2652.10, 2642.10, 10.0, 2700.0, c, 0.01), 2642.10, 1e-9, "management off -> SL unchanged");
   c.be_at_r = 2.0;
   c.be_offset_r = 0.1;
   t.Near(RB_MgmtStop(RB_DIR_BULL, 2652.10, 2642.10, 10.0, 2671.0, c, 0.01), 2642.10, 1e-9, "+1.89R < 2R -> no BE");
   t.Near(RB_MgmtStop(RB_DIR_BULL, 2652.10, 2642.10, 10.0, 2672.10, c, 0.01), 2653.10, 1e-9, "+2R -> SL entry+0.1R");
   t.Near(RB_MgmtStop(RB_DIR_BEAR, 2657.90, 2667.90, 10.0, 2637.90, c, 0.01), 2656.90, 1e-9, "bear +2R -> SL entry-0.1R");
   // trailing
   RBMgmtCfg tc;
   tc.Defaults();
   tc.trail_start_r = 3.0;
   tc.trail_dist_r = 1.5;
   t.Near(RB_MgmtStop(RB_DIR_BULL, 2652.10, 2642.10, 10.0, 2685.00, tc, 0.01), 2670.00, 1e-9, "+3.29R -> trail 1.5R below best");
   // never widen: current SL already better than the trail level
   t.Near(RB_MgmtStop(RB_DIR_BULL, 2652.10, 2675.00, 10.0, 2685.00, tc, 0.01), 2675.00, 1e-9, "trail never loosens");
   // partial volume
   RBMgmtCfg pc;
   pc.Defaults();
   pc.partial_at_r = 3.0;
   pc.partial_frac = 0.5;
   t.Near(RB_MgmtPartialVolume(2.33, pc, 0.01, 0.01), 1.16, 1e-9, "half of 2.33 -> 1.16");
   t.Near(RB_MgmtPartialVolume(0.01, pc, 0.01, 0.01), 0.0, 1e-12, "too small to split -> no partial");
   t.Near(RB_MgmtPartialPrice(RB_DIR_BEAR, 2657.90, 10.0, pc), 2627.90, 1e-9, "bear partial price at 3R");
   t.Near(RB_MgmtExcursionR(RB_DIR_BEAR, 2657.90, 2627.90, 10.0), 3.0, 1e-9, "bear excursion R");
  }

//--- DTBS (second strategy) ------------------------------------------
// BEAR fixture resembling the source chart (swing_n = 2):
//   swing high P @2 (122), lower swing high Q @9 (117.5), swing low A @14 (110),
//   rally closes above Q @19 (counter break), swing high B @21 (120), confirmed @23,
//   C = (41, 120); bar 24 wicks through the diagonal, bar 25 closes below it.
void T_DtRows(CRBSeries &s, bool mirror, int from, int to, bool q_high)
  {
   double b[26][4] =
     {
        {120.0, 120.5, 119.5, 120.0},
        {120.0, 121.0, 120.0, 120.8},
        {120.8, 122.0, 120.5, 121.5},
        {121.5, 121.5, 120.0, 120.2},
        {120.2, 120.5, 119.0, 119.2},
        {119.2, 119.5, 118.0, 118.3},
        {118.3, 118.5, 117.0, 117.2},
        {117.2, 117.3, 116.0, 116.3},
        {116.3, 116.8, 115.5, 116.5},
        {116.5, 117.5, 116.0, 117.0},
        {117.0, 117.0, 115.0, 115.3},
        {115.3, 115.5, 113.5, 113.8},
        {113.8, 114.0, 112.0, 112.4},
        {112.4, 112.8, 111.0, 111.3},
        {111.3, 111.5, 110.0, 110.3},
        {110.3, 112.0, 110.2, 111.8},
        {111.8, 113.5, 111.5, 113.2},
        {113.2, 115.0, 113.0, 114.8},
        {114.8, 117.0, 114.5, 116.8},
        {116.8, 118.2, 116.5, 118.0},
        {118.0, 119.5, 117.5, 119.2},
        {119.2, 120.0, 118.5, 119.0},
        {119.0, 119.2, 117.0, 117.3},
        {117.3, 117.5, 115.5, 115.8},
        {115.8, 116.0, 113.5, 114.5},
        {114.5, 114.8, 112.8, 113.0}
     };
   for(int i = from; i <= to; i++)
     {
      double h = b[i][1];
      if(q_high && i == 9)
         h = 119.9;  // Q above every close of the rally -> no counter break
      if(mirror)
         T_AddMirror(s, b[i][0], h, b[i][2], b[i][3]);
      else
         T_Add(s, b[i][0], h, b[i][2], b[i][3]);
     }
  }

void T_DtBar(CRBSeries &s, bool mirror, double o, double h, double l, double c)
  {
   if(mirror)
      T_AddMirror(s, o, h, l, c);
   else
      T_Add(s, o, h, l, c);
  }

void T_DtFill(CRBVec<int> &v, int n, int val)
  {
   for(int i = 0; i < n; i++)
      v.Push(val);
  }

void T_DtScan(CRBSeries &s, int trend, const RBDtbsConfig &cfg,
              CRBVec<RBDtbsTriangle> &tris, CRBVec<RBDtbsSignal> &sigs)
  {
   CRBVec<int> tv;
   T_DtFill(tv, s.Size(), trend);
   RB_DtbsScanEx(s, tv, cfg, tris, sigs);
  }

void Test_DTBS_Geometry(CRBTest &t)
  {
   for(int m = 0; m < 2; m++)
     {
      bool mirror = (m == 1);
      string tag = mirror ? "dtbs bull " : "dtbs bear ";
      int trend = mirror ? RB_TREND_BULL : RB_TREND_BEAR;
      double base = mirror ? 200.0 : 0.0;
      double sg = mirror ? -1.0 : 1.0;
      RBDtbsConfig cfg;
      cfg.Defaults();
      CRBSeries s;
      T_DtRows(s, mirror, 0, 25, false);
      CRBVec<RBDtbsTriangle> tris;
      CRBVec<RBDtbsSignal> sigs;
      T_DtScan(s, trend, cfg, tris, sigs);
      t.Check(tris.Size() == 1, tag + "one triangle");
      if(tris.Size() < 1)
         continue;
      RBDtbsTriangle tr;
      tris.Get(0, tr);
      t.Check(tr.trend == trend, tag + "triangle trend");
      t.Check(tr.a_idx == 14, tag + "A index");
      t.Near(tr.a_price, base + sg * 110.0, 1e-9, tag + "A price");
      t.Check(tr.b_idx == 21, tag + "B index");
      t.Near(tr.b_price, base + sg * 120.0, 1e-9, tag + "B price");
      t.Check(tr.c_idx == 41, tag + "C index = B + 20");
      t.Near(tr.c_price, tr.b_price, 1e-12, tag + "C price = pB");
      t.Check(tr.known_idx == 23, tag + "known when B confirmed (B + swing_n)");
      t.Check(tr.ref_idx == 9, tag + "counter-break reference swing Q");
      t.Check(tr.cbreak_idx == 19, tag + "counter break bar");
      t.Near(RB_DtbsLine(tr, 14), base + sg * 110.0, 1e-9, tag + "line(A) = pA");
      t.Near(RB_DtbsLine(tr, 41), base + sg * 120.0, 1e-9, tag + "line(C) = pB");
      t.Near(RB_DtbsLine(tr, 25), base + sg * (110.0 + 10.0 * 11.0 / 27.0), 1e-9, tag + "line(25)");
      t.Near(RB_DtbsLine(tr, 21), base + sg * (110.0 + 10.0 * 7.0 / 27.0), 1e-9, tag + "line(B) below pB");
      t.Check(tr.status == RB_DTBS_TRI_USED && tr.status_idx == 25, tag + "triangle used at 25");
      t.Check(sigs.Size() == 1, tag + "one signal");
      if(sigs.Size() < 1)
         continue;
      RBDtbsSignal sg0;
      sigs.Get(0, sg0);
      t.Check(sg0.dir == trend && sg0.with_trend, tag + "with-trend signal direction");
      t.Check(sg0.main_trend == trend, tag + "signal main trend");
      t.Check(sg0.break_idx == 25 && sg0.break_time == s.Time(25), tag + "break bar 25");
      t.Check(sg0.close_confirmed, tag + "close confirmed");
      t.Near(sg0.line_at_break, base + sg * (110.0 + 10.0 * 11.0 / 27.0), 1e-9, tag + "line at break");
      t.Check(sg0.a_idx == 14 && sg0.b_idx == 21 && sg0.c_idx == 41, tag + "signal carries A/B/C");
      t.Near(sg0.break_high, s.H(25), 1e-12, tag + "break high");
      t.Near(sg0.break_low, s.L(25), 1e-12, tag + "break low");
      t.Near(sg0.atr, s.ATR(25), 1e-12, tag + "atr at break");
      t.Check(sg0.atr > 0.0, tag + "atr available");
      t.Check(sg0.start_valid && sg0.start_idx == 22, tag + "break start bar = highest high in (B, break)");
      t.Near(sg0.start_price, base + sg * 119.2, 1e-9, tag + "break start price");
     }
  }

void Test_DTBS_Breaks(CRBTest &t)
  {
   for(int m = 0; m < 2; m++)
     {
      bool mirror = (m == 1);
      string tag = mirror ? "dtbs bull " : "dtbs bear ";
      int trend = mirror ? RB_TREND_BULL : RB_TREND_BEAR;
      RBDtbsConfig cfg;
      cfg.Defaults();
      CRBVec<RBDtbsTriangle> tris;
      CRBVec<RBDtbsSignal> sigs;
      RBDtbsSignal sg0;
      RBDtbsTriangle tr;

      //--- wick confirmation fires one bar earlier, not close confirmed
      CRBSeries s1;
      T_DtRows(s1, mirror, 0, 25, false);
      cfg.confirm = RB_DTBS_CONFIRM_WICK;
      T_DtScan(s1, trend, cfg, tris, sigs);
      t.Check(sigs.Size() == 1, tag + "wick: one signal");
      if(sigs.Size() == 1)
        {
         sigs.Get(0, sg0);
         t.Check(sg0.break_idx == 24, tag + "wick: break at 24");
         t.Check(!sg0.close_confirmed, tag + "wick: not close confirmed");
         t.Check(sg0.with_trend && sg0.dir == trend, tag + "wick: with trend");
        }
      cfg.confirm = RB_DTBS_CONFIRM_CLOSE;

      //--- single signal per triangle: later re-cross and close beyond pB give nothing
      CRBSeries s2;
      T_DtRows(s2, mirror, 0, 25, false);
      T_DtBar(s2, mirror, 113.0, 116.2, 112.9, 116.0);
      T_DtBar(s2, mirror, 116.0, 116.1, 112.5, 113.0);
      T_DtBar(s2, mirror, 113.0, 121.0, 112.8, 120.8);
      T_DtScan(s2, trend, cfg, tris, sigs);
      t.Check(sigs.Size() == 1, tag + "single signal per triangle");

      //--- expiry: price below the line without a cross, then beyond pB after C -> nothing
      CRBSeries s3;
      T_DtRows(s3, mirror, 0, 21, false);
      T_DtBar(s3, mirror, 119.0, 119.2, 111.8, 112.0);
      T_DtBar(s3, mirror, 112.0, 112.3, 110.6, 111.0);
      for(int i = 24; i <= 41; i++)
         T_DtBar(s3, mirror, 110.5, 111.0, 110.2, 110.5);
      T_DtBar(s3, mirror, 110.5, 121.5, 110.4, 121.0);
      T_DtScan(s3, trend, cfg, tris, sigs);
      t.Check(sigs.Size() == 0, tag + "expired triangle: no signal");
      t.Check(tris.Size() == 1, tag + "expiry: triangle existed");
      if(tris.Size() == 1)
        {
         tris.Get(0, tr);
         t.Check(tr.status == RB_DTBS_TRI_EXPIRED && tr.status_idx == 41, tag + "expired at C");
        }

      //--- counter break beyond pB -> opposite signal; WITH_TREND_ONLY suppresses it
      CRBSeries s4;
      T_DtRows(s4, mirror, 0, 23, false);
      T_DtBar(s4, mirror, 115.8, 120.6, 115.5, 120.3);
      T_DtBar(s4, mirror, 120.3, 120.4, 112.0, 112.5);
      T_DtScan(s4, trend, cfg, tris, sigs);
      t.Check(sigs.Size() == 1, tag + "counter: one signal");
      if(sigs.Size() == 1)
        {
         sigs.Get(0, sg0);
         t.Check(sg0.dir == -trend && !sg0.with_trend, tag + "counter: opposite direction");
         t.Check(sg0.break_idx == 24 && sg0.close_confirmed, tag + "counter: close beyond pB at 24");
         t.Check(sg0.start_valid && sg0.start_idx == 23, tag + "counter: break start = extreme low in (B, break)");
         t.Near(sg0.start_price, mirror ? 200.0 - 115.5 : 115.5, 1e-9, tag + "counter: break start price");
        }
      cfg.break_dirs = RB_DTBS_WITH_TREND_ONLY;
      T_DtScan(s4, trend, cfg, tris, sigs);
      t.Check(sigs.Size() == 0, tag + "WITH_TREND_ONLY: counter break suppressed, no later signal");
      if(tris.Size() == 1)
        {
         tris.Get(0, tr);
         t.Check(tr.status == RB_DTBS_TRI_SUPPRESSED, tag + "WITH_TREND_ONLY: triangle suppressed");
        }
      cfg.break_dirs = RB_DTBS_BOTH;

      //--- min_leg_atr filter
      CRBSeries s5;
      T_DtRows(s5, mirror, 0, 25, false);
      cfg.min_leg_atr = 50.0;
      T_DtScan(s5, trend, cfg, tris, sigs);
      t.Check(tris.Size() == 0 && sigs.Size() == 0, tag + "leg below min_leg_atr: no triangle");
      cfg.min_leg_atr = 1.0;

      //--- no counter break -> no triangle
      CRBSeries s6;
      T_DtRows(s6, mirror, 0, 25, true);
      T_DtScan(s6, trend, cfg, tris, sigs);
      t.Check(tris.Size() == 0 && sigs.Size() == 0, tag + "no counter break: no triangle");

      //--- wrong main trend -> no triangle; trend change -> invalid
      CRBSeries s7;
      T_DtRows(s7, mirror, 0, 25, false);
      T_DtScan(s7, -trend, cfg, tris, sigs);
      t.Check(sigs.Size() == 0, tag + "opposite main trend: no signal");
      CRBVec<int> tv;
      T_DtFill(tv, 24, trend);
      T_DtFill(tv, 2, RB_TREND_NONE);
      RB_DtbsScanEx(s7, tv, cfg, tris, sigs);
      t.Check(sigs.Size() == 0, tag + "trend change before break: no signal");
      if(tris.Size() == 1)
        {
         tris.Get(0, tr);
         t.Check(tr.status == RB_DTBS_TRI_INVALID && tr.status_idx == 24, tag + "trend change invalidates");
        }
     }
  }

// HTF fixture: swing high @2 (12), swing low @5 (9) confirmed @7, close 12.5 > 12 @8 -> BULL,
// close 8.7 < 9 @11 -> BEAR.
void T_DtTrendRows(CRBSeries &s)
  {
   double b[12][4] =
     {
        { 9.5, 10.0,  9.0,  9.5},
        { 9.5, 11.0, 10.0, 10.5},
        {10.5, 12.0, 11.0, 11.5},
        {11.5, 11.5, 10.5, 10.8},
        {10.8, 11.0,  9.5,  9.8},
        { 9.8, 10.5,  9.0,  9.2},
        { 9.2, 10.8,  9.6, 10.6},
        {10.6, 11.8, 10.4, 11.6},
        {11.6, 12.6, 11.4, 12.5},
        {12.5, 12.8, 11.8, 12.0},
        {12.0, 12.2, 10.5, 10.7},
        {10.7, 11.0,  8.5,  8.7}
     };
   for(int i = 0; i < 12; i++)
      T_Add(s, b[i][0], b[i][1], b[i][2], b[i][3]);
  }

void Test_DTBS_Trend(CRBTest &t)
  {
   CRBSeries s;
   T_DtTrendRows(s);
   CRBVec<int> tv;
   RB_DtbsTrendSeries(s, 2, tv);
   t.Check(tv.Size() == 12, "dtbs trend series size");
   int v = 0;
   bool ok = true;
   for(int i = 0; i < 12; i++)
     {
      tv.Get(i, v);
      int exp = RB_TREND_NONE;
      if(i >= 8 && i <= 10) exp = RB_TREND_BULL;
      if(i == 11)           exp = RB_TREND_BEAR;
      if(v != exp)
        {
         ok = false;
         RB_TestPrint("dtbs trend bar " + IntegerToString(i) + " = " + RB_DtbsTrendText(v));
        }
      if(RB_DtbsTrendAt(s, i, 2) != v)
         ok = false;
     }
   t.Check(ok, "dtbs trend: NONE until break of swing high, BULL, then BEAR below swing low");
   // truncated series gives the same state (no lookahead)
   CRBSeries part;
   RBBar b;
   for(int i = 0; i < 9; i++)
     {
      s.Bar(i, b);
      part.Add(b);
     }
   t.Check(RB_DtbsTrendAt(part, 8, 2) == RB_TREND_BULL, "dtbs trend truncated == full");

   // combiner
   CRBVec<int> st;
   int bu = RB_TREND_BULL, be = RB_TREND_BEAR, no = RB_TREND_NONE;
   t.Check(RB_DtbsCombine(st, RB_DTBS_HTF_ALL) == RB_TREND_NONE, "combine: empty -> NONE");
   st.Push(bu); st.Push(bu);
   t.Check(RB_DtbsCombine(st, RB_DTBS_HTF_ALL) == RB_TREND_BULL, "ALL: bull+bull -> BULL");
   st.Push(be);
   t.Check(RB_DtbsCombine(st, RB_DTBS_HTF_ALL) == RB_TREND_NONE, "ALL: bull+bull+bear -> NONE");
   t.Check(RB_DtbsCombine(st, RB_DTBS_HTF_MAJORITY) == RB_TREND_BULL, "MAJORITY: 2 of 3 bull -> BULL");
   st.Clear();
   st.Push(bu); st.Push(no); st.Push(be);
   t.Check(RB_DtbsCombine(st, RB_DTBS_HTF_MAJORITY) == RB_TREND_NONE, "MAJORITY: bull+none+bear -> NONE");
   t.Check(RB_DtbsCombine2(be, be, RB_DTBS_HTF_ALL) == RB_TREND_BEAR, "ALL2: bear+bear -> BEAR");
   t.Check(RB_DtbsCombine2(be, no, RB_DTBS_HTF_ALL) == RB_TREND_NONE, "ALL2: bear+none -> NONE");
   t.Check(RB_DtbsCombine2(be, no, RB_DTBS_HTF_MAJORITY) == RB_TREND_NONE, "MAJORITY2: 1 of 2 is not a majority");
   t.Check(RB_DtbsCombine2(bu, be, RB_DTBS_HTF_MAJORITY) == RB_TREND_NONE, "MAJORITY2: bull+bear -> NONE");

   // HTF alignment (H1 over M15): never a bar that is not closed at the LTF bar close
   datetime t0 = (datetime)1699999200; // hour aligned
   CRBSeries htf;
   for(int i = 0; i < 6; i++)
     {
      RBBar hb;
      hb.time = (datetime)((long)t0 + 3600 * i);
      hb.open = 100.0; hb.high = 101.0; hb.low = 99.0; hb.close = 100.0;
      htf.Add(hb);
     }
   t.Check(RB_DtbsHtfIndexAt(htf, 3600, (datetime)((long)t0 + 1800), 900) == -1, "align: 00:30 M15 bar -> no H1 closed yet");
   t.Check(RB_DtbsHtfIndexAt(htf, 3600, (datetime)((long)t0 + 2700), 900) == 0, "align: 00:45 M15 bar closes with the 00:00 H1 bar");
   t.Check(RB_DtbsHtfIndexAt(htf, 3600, (datetime)((long)t0 + 3600), 900) == 0, "align: 01:00 M15 bar -> H1 00:00 (01:00 still open)");
   t.Check(RB_DtbsHtfIndexAt(htf, 3600, (datetime)((long)t0 + 5 * 3600 + 2700), 900) == 5, "align: last H1 bar");
   t.Check(RB_DtbsHtfIndexAt(htf, 3600, (datetime)((long)t0 + 99 * 3600), 900) == 5, "align: beyond the series -> last");
   bool aok = true;
   for(int k = 0; k < 40; k++)
     {
      datetime lo = (datetime)((long)t0 + 900 * k - 450); // also unaligned LTF times
      long lc = (long)lo + 900;
      int j = RB_DtbsHtfIndexAt(htf, 3600, lo, 900);
      if(j >= 0 && (long)htf.Time(j) + 3600 > lc)
         aok = false;
      if(j + 1 < htf.Size() && (long)htf.Time(j + 1) + 3600 <= lc)
         aok = false;
     }
   t.Check(aok, "align: returned bar closed, next bar not closed");
   // aligned trend vector
   CRBVec<int> ht, al;
   T_DtFill(ht, 6, bu);
   ht.Set(0, be);
   CRBSeries ltf;
   for(int k = 0; k < 8; k++)
     {
      RBBar lb;
      lb.time = (datetime)((long)t0 + 900 * k);
      lb.open = 100.0; lb.high = 101.0; lb.low = 99.0; lb.close = 100.0;
      ltf.Add(lb);
     }
   RB_DtbsAlignTrend(ltf, 900, htf, 3600, ht, al);
   int a2 = 0, a3 = 0, a7 = 0;
   al.Get(2, a2);
   al.Get(3, a3);
   al.Get(7, a7);
   t.Check(al.Size() == 8 && a2 == RB_TREND_NONE && a3 == RB_TREND_BEAR && a7 == RB_TREND_BULL,
           "aligned trend: NONE before first H1 close, then the closed H1 state");
   CRBVec<int> cmb;
   RB_DtbsCombineSeries(al, al, RB_DTBS_HTF_ALL, cmb);
   int c3 = 0;
   cmb.Get(3, c3);
   t.Check(cmb.Size() == 8 && c3 == RB_TREND_BEAR, "combine series");
  }

//--- aggregate bars [0, cut) of an LTF series into period buckets (last bucket may be partial)
void T_DtAggregate(const CRBSeries &s, int cut, int sec, CRBSeries &out)
  {
   out.Clear();
   RBBar cur;
   bool has = false;
   cur.time = 0; cur.open = 0.0; cur.high = 0.0; cur.low = 0.0; cur.close = 0.0;
   for(int i = 0; i < cut; i++)
     {
      RBBar b;
      s.Bar(i, b);
      datetime bt = (datetime)(((long)b.time / sec) * sec);
      if(has && bt != cur.time)
        {
         out.Add(cur);
         has = false;
        }
      if(!has)
        {
         cur = b;
         cur.time = bt;
         has = true;
        }
      else
        {
         cur.high  = MathMax(cur.high, b.high);
         cur.low   = MathMin(cur.low, b.low);
         cur.close = b.close;
        }
     }
   if(has)
      out.Add(cur);
  }

void T_DtMainTrend(const CRBSeries &s, int cut, int mode, const RBDtbsConfig &cfg, CRBVec<int> &tv)
  {
   tv.Clear();
   if(mode < 2)
     {
      T_DtFill(tv, cut, mode == 0 ? RB_TREND_BEAR : RB_TREND_BULL);
      return;
     }
   CRBSeries h1, h4;
   T_DtAggregate(s, cut, 3600, h1);
   T_DtAggregate(s, cut, 14400, h4);
   CRBVec<int> t1, t4, a1, a4;
   RB_DtbsTrendSeries(h1, cfg.htf_swing_n, t1);
   RB_DtbsTrendSeries(h4, cfg.htf_swing_n, t4);
   CRBSeries part;
   RBBar b;
   for(int i = 0; i < cut; i++)
     {
      s.Bar(i, b);
      part.Add(b);
     }
   RB_DtbsAlignTrend(part, 900, h1, 3600, t1, a1);
   RB_DtbsAlignTrend(part, 900, h4, 14400, t4, a4);
   RB_DtbsCombineSeries(a1, a4, mode == 2 ? RB_DTBS_HTF_ALL : RB_DTBS_HTF_MAJORITY, tv);
  }

bool T_SameDtbs(const RBDtbsSignal &a, const RBDtbsSignal &b)
  {
   return a.dir == b.dir && a.break_idx == b.break_idx && a.with_trend == b.with_trend &&
          a.a_idx == b.a_idx && a.b_idx == b.b_idx && a.c_idx == b.c_idx &&
          a.a_price == b.a_price && a.b_price == b.b_price && a.line_at_break == b.line_at_break &&
          a.close_confirmed == b.close_confirmed && a.main_trend == b.main_trend &&
          a.atr == b.atr && a.start_idx == b.start_idx && a.start_price == b.start_price;
  }

void Test_DTBS_Lookahead(CRBTest &t)
  {
   int total = 0, nwith = 0, counter = 0, replaced = 0;
   for(int mode = 0; mode < 4; mode++)
     {
      RBDtbsConfig cfg;
      cfg.Defaults();
      if(mode == 3)
         cfg.confirm = RB_DTBS_CONFIRM_WICK;
      CRBSeries full;
      T_RandomSeries(full, 1200, 777 + mode);
      CRBVec<int> tvf;
      T_DtMainTrend(full, full.Size(), mode, cfg, tvf);
      CRBVec<RBDtbsTriangle> tf;
      CRBVec<RBDtbsSignal> sf;
      RB_DtbsScanEx(full, tvf, cfg, tf, sf);
      RBDtbsSignal a, c;
      for(int i = 0; i < sf.Size(); i++)
        {
         sf.Get(i, a);
         total++;
         if(a.with_trend) nwith++; else counter++;
        }
      RBDtbsTriangle x, y;
      for(int i = 0; i < tf.Size(); i++)
        {
         tf.Get(i, x);
         if(x.status == RB_DTBS_TRI_REPLACED) replaced++;
        }
      t.Check(sf.Size() > 3, "dtbs random series produces signals (mode " + IntegerToString(mode) + ")");
      bool ok = true;
      for(int cut = 60; cut < full.Size(); cut += 13)
        {
         CRBSeries part;
         RBBar b;
         for(int i = 0; i < cut; i++)
           {
            full.Bar(i, b);
            part.Add(b);
           }
         CRBVec<int> tvp;
         T_DtMainTrend(full, cut, mode, cfg, tvp);
         // the main trend known at bar k is the same with or without future bars
         int u = 0, w = 0;
         for(int k = 0; k < cut && ok; k++)
           {
            tvp.Get(k, u);
            tvf.Get(k, w);
            if(u != w)
               ok = false;
           }
         CRBVec<RBDtbsTriangle> tp;
         CRBVec<RBDtbsSignal> sp;
         RB_DtbsScanEx(part, tvp, cfg, tp, sp);
         int expected = 0;
         for(int i = 0; i < sf.Size(); i++)
           {
            sf.Get(i, a);
            if(a.break_idx < cut)
               expected++;
           }
         if(expected != sp.Size())
            ok = false;
         for(int i = 0; i < sp.Size() && ok; i++)
           {
            sp.Get(i, c);
            sf.Get(i, a);
            if(!T_SameDtbs(a, c))
               ok = false;
           }
         int tc = 0;
         for(int i = 0; i < tf.Size(); i++)
           {
            tf.Get(i, x);
            if(x.known_idx < cut)
               tc++;
           }
         if(tc != tp.Size())
            ok = false;
         for(int i = 0; i < tp.Size() && ok; i++)
           {
            tp.Get(i, y);
            tf.Get(i, x);
            if(x.a_idx != y.a_idx || x.b_idx != y.b_idx || x.known_idx != y.known_idx || x.trend != y.trend)
               ok = false;
           }
        }
      t.Check(ok, "dtbs no lookahead: truncated == full up to cut (mode " + IntegerToString(mode) + ")");
     }
   t.Check(nwith > 0 && counter > 0, "dtbs random: both with-trend and counter breaks occur");
   t.Check(replaced > 0, "dtbs random: newer triangles replace unbroken ones");
   RB_TestPrint("DTBS random: signals=" + IntegerToString(total) + " with=" + IntegerToString(nwith) +
                " counter=" + IntegerToString(counter) + " replaced=" + IntegerToString(replaced));
  }

void T_DtSig(RBDtbsSignal &s, int dir)
  {
   s.tri_id = 0;
   s.dir = dir;
   s.main_trend = dir;
   s.with_trend = true;
   s.break_idx = 25;
   s.break_time = (datetime)0;
   s.a_idx = 14;
   s.a_price = 110.0;
   s.b_idx = 21;
   s.b_price = 120.0;
   s.c_idx = 41;
   s.c_price = 120.0;
   s.known_idx = 23;
   s.line_at_break = 114.07;
   s.close_confirmed = true;
   s.atr = 1.5;
   s.break_high = 114.8;
   s.break_low = 112.8;
   s.start_valid = true;
   s.start_idx = 24;
   s.start_price = 114.5;
  }

//--- D-041 context filter: EMA of HTF closes and slope agreement (closed HTF bars only)
void Test_DTBS_Context(CRBTest &t)
  {
   CRBSeries h;
   RBBar b;
   for(int i = 0; i < 20; i++)   // H4 bars from 2024-01-01 00:00, rising closes 100, 101, ...
     {
      b.time = (datetime)(1704067200 + i * 14400);
      b.open = 100.0 + i;
      b.high = 101.0 + i;
      b.low = 99.0 + i;
      b.close = 100.0 + i;
      h.Add(b);
     }
   CRBVec<double> e;
   RB_DtbsEmaSeries(h, 3, e);
   double v0 = -1, v1 = -1, v2 = -1, v3 = -1;
   e.Get(0, v0);
   e.Get(1, v1);
   e.Get(2, v2);
   e.Get(3, v3);
   t.Check(v0 == 0.0 && v1 == 0.0, "ema: 0 before warm-up");
   t.Near(v2, 101.25, 1e-9, "ema(3) after 3 closes (seeded with the first close)");
   t.Near(v3, 102.125, 1e-9, "ema(3) next value");
   // M15 bar opening 2024-01-02 15:45 closes 16:00 = close of H4 bar #9 (12:00-16:00)
   datetime m15 = (datetime)(1704067200 + 9 * 14400 + 3 * 3600 + 2700);
   t.Check(RB_DtbsSlopeAgree(h, 14400, e, m15, 900, 5, RB_DIR_BULL) == 1, "rising EMA agrees with a buy");
   t.Check(RB_DtbsSlopeAgree(h, 14400, e, m15, 900, 5, RB_DIR_BEAR) == -1, "rising EMA is against a sell");
   // M15 bar that closes 15:45: H4 bar #9 still forming -> last closed is #8 (no lookahead)
   datetime early = m15 - 900;
   CRBVec<double> e2;
   RB_DtbsEmaSeries(h, 3, e2);
   t.Check(RB_DtbsHtfIndexAt(h, 14400, early, 900) == 8, "context uses the last CLOSED H4 bar");
   // not enough history for the slope -> unknown
   datetime first = (datetime)(1704067200 + 3 * 14400 - 900);
   t.Check(RB_DtbsSlopeAgree(h, 14400, e, first, 900, 5, RB_DIR_BULL) == 0, "slope unknown without history");
   RBDtbsConfig c;
   c.Defaults();
   t.Check(!c.ctx_filter && c.ctx_ema_period == 50 && c.ctx_slope_bars == 5, "ctx defaults: off in the library, 50 / 5");
  }

void Test_DTBS_Plan(CRBTest &t)
  {
   RBSymbolSpec sp;
   T_Spec(sp);
   RBDtbsConfig cfg;
   cfg.Defaults();
   t.Check(cfg.sl_mode == RB_DTBS_SL_ADAPTIVE && cfg.ext_bars == 20, "dtbs defaults: ADAPTIVE stop, 20 bars");
   t.Near(cfg.rr, 1.5, 1e-12, "dtbs defaults: rr 1.5");
   RBDtbsSignal s;
   RBPlan p;
   int used = -1;

   //--- fixed modes, sell at 113.00, ATR 1.5 (max stop 4.5), buffer 0.30
   T_DtSig(s, RB_DIR_BEAR);
   cfg.sl_mode = RB_DTBS_SL_BREAK_CANDLE;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == 0, "break candle sell ok");
   t.Near(p.sl, 115.10, 1e-9, "break candle sell sl = high + buffer");
   t.Near(p.risk_dist, 2.10, 1e-9, "break candle sell risk");
   t.Near(p.tp, 109.85, 1e-9, "sell tp = entry - 1.5R");
   t.Check(p.dir == RB_DIR_BEAR, "plan dir");
   cfg.rr = 2.0;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == 0, "rr 2 ok");
   t.Near(p.tp, 108.80, 1e-9, "sell tp = entry - 2R");
   cfg.rr = 1.5;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p, 0.5) == 0, "spread buffer ok");
   t.Near(p.sl, 115.30, 1e-9, "buffer = max(buffer, spread)");
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 115.5, p) == 6, "entry above break-candle stop -> SL_WRONG_SIDE");
   t.Check(RB_DtbsReasonText(6) == "SL_WRONG_SIDE", "reason text reuses RB codes");

   cfg.sl_mode = RB_DTBS_SL_EXTREME;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == RB_DTBS_ERR_STOP_TOO_WIDE, "extreme 7.30 > 3 ATR -> rejected");
   t.Check(RB_DtbsReasonText(RB_DTBS_ERR_STOP_TOO_WIDE) == "DTBS_STOP_TOO_WIDE_ATR", "dtbs reason text");
   cfg.max_stop_atr = 0.0;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == 0, "extreme with max_stop off ok");
   t.Near(p.sl, 120.30, 1e-9, "extreme sell sl = pB + buffer");
   cfg.max_stop_atr = 3.0;

   cfg.sl_mode = RB_DTBS_SL_ATR;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == 0, "atr sell ok");
   t.Near(p.sl, 115.25, 1e-9, "atr sell sl = entry + 1.5 ATR");
   s.atr = 0.004;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == RB_DTBS_ERR_STOP_BELOW_TICK, "stop below one tick rejected");
   s.atr = 0.0;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == RB_DTBS_ERR_NO_ATR, "no ATR rejected");
   s.atr = 1.5;

   cfg.sl_mode = RB_DTBS_SL_BREAK_START;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == 0, "break start sell ok");
   t.Near(p.sl, 114.80, 1e-9, "break start sell sl = local high + buffer");
   s.start_valid = false;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == RB_DTBS_ERR_NO_BREAK_START, "break start missing -> rejected");
   s.start_valid = true;

   //--- buy (counter break or BULL trend)
   RBDtbsSignal b;
   T_DtSig(b, RB_DIR_BULL);
   b.break_low = 119.6;
   b.break_high = 120.6;
   b.start_price = 118.0;
   cfg.sl_mode = RB_DTBS_SL_BREAK_CANDLE;
   t.Check(RB_DtbsBuildPlan(b, cfg, sp, 120.3, p) == 0, "break candle buy ok");
   t.Near(p.sl, 119.30, 1e-9, "buy sl = low - buffer");
   t.Near(p.tp, 121.80, 1e-9, "buy tp = entry + 1.5R");
   cfg.sl_mode = RB_DTBS_SL_EXTREME;
   t.Check(RB_DtbsBuildPlan(b, cfg, sp, 120.3, p) == 0, "extreme buy ok");
   t.Near(p.sl, 119.70, 1e-9, "extreme buy sl = pB - buffer");
   cfg.sl_mode = RB_DTBS_SL_BREAK_START;
   t.Check(RB_DtbsBuildPlan(b, cfg, sp, 120.3, p) == 0, "break start buy ok");
   t.Near(p.sl, 117.70, 1e-9, "break start buy sl = local low - buffer");
   cfg.sl_mode = RB_DTBS_SL_ATR;
   t.Check(RB_DtbsBuildPlan(b, cfg, sp, 120.3, p) == 0, "atr buy ok");
   t.Near(p.sl, 118.05, 1e-9, "atr buy sl = entry - 1.5 ATR");
   cfg.sl_mode = RB_DTBS_SL_BREAK_CANDLE;
   t.Check(RB_DtbsBuildPlan(b, cfg, sp, 119.2, p) == 6, "buy entry below break-candle stop -> wrong side");

   //--- ADAPTIVE: window [0.75, 4.50]
   cfg.sl_mode = RB_DTBS_SL_ADAPTIVE;
   T_DtSig(s, RB_DIR_BEAR);
   t.Check(RB_DtbsBuildPlanEx(s, cfg, sp, 113.0, 0.0, p, used) == 0, "adaptive: first level fits");
   t.Check(used == RB_DTBS_SL_BREAK_START, "adaptive: uses BREAK_START");
   t.Near(p.sl, 114.80, 1e-9, "adaptive: break start sl");
   s.start_price = 113.2; // 0.50 < 0.75
   t.Check(RB_DtbsBuildPlanEx(s, cfg, sp, 113.0, 0.0, p, used) == 0 && used == RB_DTBS_SL_BREAK_CANDLE,
           "adaptive: break start too tight -> BREAK_CANDLE");
   t.Near(p.sl, 115.10, 1e-9, "adaptive: break candle sl");
   s.start_price = 112.5; // wrong side
   t.Check(RB_DtbsBuildPlanEx(s, cfg, sp, 113.0, 0.0, p, used) == 0 && used == RB_DTBS_SL_BREAK_CANDLE,
           "adaptive: break start on the wrong side -> BREAK_CANDLE");
   s.start_valid = false;
   t.Check(RB_DtbsBuildPlanEx(s, cfg, sp, 113.0, 0.0, p, used) == 0 && used == RB_DTBS_SL_BREAK_CANDLE,
           "adaptive: no break start -> BREAK_CANDLE");
   s.start_valid = true;
   s.start_price = 113.2;
   s.break_high = 113.3;  // 0.60 < 0.75
   s.b_price = 116.0;     // 3.30 fits
   t.Check(RB_DtbsBuildPlanEx(s, cfg, sp, 113.0, 0.0, p, used) == 0 && used == RB_DTBS_SL_EXTREME,
           "adaptive: first two too tight -> EXTREME");
   t.Near(p.sl, 116.30, 1e-9, "adaptive: extreme sl");
   s.start_price = 118.0; // 5.30 too wide
   s.break_high = 113.3;
   t.Check(RB_DtbsBuildPlanEx(s, cfg, sp, 113.0, 0.0, p, used) == 0 && used == RB_DTBS_SL_EXTREME,
           "adaptive: first too wide, second too tight -> EXTREME");
   s.start_price = 113.2;
   s.b_price = 120.0;     // 7.30 too wide
   t.Check(RB_DtbsBuildPlanEx(s, cfg, sp, 113.0, 0.0, p, used) == RB_DTBS_ERR_NO_ADAPTIVE_FIT,
           "adaptive: no level fits -> rejected");
   t.Check(RB_DtbsReasonText(RB_DTBS_ERR_NO_ADAPTIVE_FIT) == "DTBS_NO_ADAPTIVE_LEVEL_FITS", "adaptive reason text");
   T_DtSig(b, RB_DIR_BULL);
   b.start_price = 119.0;
   b.break_low = 119.6;
   t.Check(RB_DtbsBuildPlanEx(b, cfg, sp, 120.3, 0.0, p, used) == 0 && used == RB_DTBS_SL_BREAK_START,
           "adaptive buy: break start fits");
   t.Near(p.sl, 118.70, 1e-9, "adaptive buy sl");

   //--- generic rejections
   T_DtSig(s, RB_DIR_BEAR);
   cfg.rr = 0.0;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == 18, "rr 0 rejected");
   cfg.rr = 1.5;
   s.dir = 0;
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == RB_DTBS_ERR_BAD_SIGNAL, "bad direction rejected");
   s.dir = RB_DIR_BEAR;
   RBSymbolSpec bad = sp;
   bad.tick_size = 0.0;
   t.Check(RB_DtbsBuildPlan(s, cfg, bad, 113.0, p) == 9, "bad symbol spec rejected");

   //--- digits 3 symbol
   RBSymbolSpec s3 = sp;
   s3.digits = 3;
   s3.point = 0.001;
   s3.tick_size = 0.001;
   RBDtbsConfig c3;
   c3.Defaults();
   c3.sl_mode = RB_DTBS_SL_BREAK_CANDLE;
   c3.sl_buffer_price = 0.030;
   c3.rr = 2.0;
   RBDtbsSignal j;
   T_DtSig(j, RB_DIR_BEAR);
   j.atr = 0.2;
   j.break_high = 150.250;
   t.Check(RB_DtbsBuildPlan(j, c3, s3, 150.100, p) == 0, "digits3 sell ok");
   t.Near(p.sl, 150.280, 1e-9, "digits3 sl");
   t.Near(p.risk_dist, 0.180, 1e-9, "digits3 risk");
   t.Near(p.tp, 149.740, 1e-9, "digits3 tp");
   j.break_high = 150.2504;
   t.Check(RB_DtbsBuildPlan(j, c3, s3, 150.100, p) == 0, "digits3 rounding ok");
   t.Near(p.sl, 150.281, 1e-9, "digits3 sell sl rounded away from entry");
   j.break_high = 150.900; // 0.83 > 3 x 0.2
   t.Check(RB_DtbsBuildPlan(j, c3, s3, 150.100, p) == RB_DTBS_ERR_STOP_TOO_WIDE, "digits3 too wide in ATR");
   c3.sl_mode = RB_DTBS_SL_ATR;
   j.atr = 0.0004;  // 1.5 x = 0.0006 < 1 tick (0.001)
   c3.max_stop_atr = 0.0;
   t.Check(RB_DtbsBuildPlan(j, c3, s3, 150.100, p) == RB_DTBS_ERR_STOP_BELOW_TICK, "digits3 below one tick");
   j.atr = 0.001;   // 0.0015 >= 1 tick -> rounded up to 0.002
   t.Check(RB_DtbsBuildPlan(j, c3, s3, 150.100, p) == 0, "digits3 one-and-a-half ticks ok");
   t.Near(p.sl, 150.102, 1e-9, "digits3 atr sl rounded away");

   //--- market checks
   cfg.sl_mode = RB_DTBS_SL_BREAK_CANDLE;
   T_DtSig(s, RB_DIR_BEAR);
   t.Check(RB_DtbsBuildPlan(s, cfg, sp, 113.0, p) == 0, "market check plan");
   t.Check(RB_DtbsCheckMarket(p, sp, 112.9, 113.0, 2.0) == 0, "market ok");
   t.Check(RB_DtbsCheckMarket(p, sp, 111.9, 113.0, 2.0) == 12, "stop < 2 x spread rejected");
   RBSymbolSpec sl3 = sp;
   sl3.stops_level = 300;
   t.Check(RB_DtbsCheckMarket(p, sl3, 112.9, 113.0, 2.0) == 11, "stop below broker minimum rejected");
  }

//--- entry point ----------------------------------------------------
void RB_RunAllTests(CRBTest &t)
  {
   Test_FvgBull(t);
   Test_FvgBear(t);
   Test_OrderBlocks(t);
   Test_RejectionBlock(t);
   Test_ZoneLifecycle(t);
   Test_FibAndPlan(t);
   Test_UnitsLotsCosts(t);
   Test_RiskGuard(t);
   Test_Safety(t);
   Test_Lookahead(t);
   Test_Regime(t);
   Test_Adaptive(t);
   Test_TradeMgmt(t);
   Test_DTBS_Geometry(t);
   Test_DTBS_Breaks(t);
   Test_DTBS_Trend(t);
   Test_DTBS_Lookahead(t);
   Test_DTBS_Plan(t);
   Test_DTBS_Context(t);
   RB_TestPrint("RBOTE tests: passed=" + IntegerToString(t.passed) + " failed=" + IntegerToString(t.failed));
  }

#endif
