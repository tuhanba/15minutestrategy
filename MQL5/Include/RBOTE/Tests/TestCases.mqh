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
   s.equity = 99400.0;
   s.day_start_ref = 100000.0;
   s.realized_today = -500.0;
   s.open_risk = 250.0;
   s.pending_risk = 250.0;
   s.trades_today = 1;
   s.positions = 1;
   s.pending = 1;
   s.unprotected_position = false;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 2, "-500 -250 -250 -250 < -1000 -> denied");
   t.Check(RB_CheckNewOrder(lim, s, 0.0) == 0, "exactly at -1000 is still allowed");
   s.pending_risk = 0.0;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 0, "-1000 allowed when pending is gone");
   s.realized_today = 300.0;
   s.pending_risk = 250.0;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 0, "realized profit offsets");
   s.unprotected_position = true;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 1, "position without SL blocks new orders");
   s.unprotected_position = false;
   lim.max_open_risk_pct = 0.005;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 3, "open+pending+new 750 > 0.5% of equity");
   lim.max_open_risk_pct = 0.0;
   lim.max_trades_per_day = 1;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 5, "max trades per day");
   lim.max_trades_per_day = 0;
   lim.max_total_dd_pct = 0.05;
   lim.initial_balance = 100000.0;
   s.equity = 95400.0;
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
   s.pending_risk = 0.0;
   s.realized_today = 0.0;
   t.Check(RB_CheckNewOrder(lim, s, 250.0) == 0, "99600 - 250 above trailing floor 99000");
   t.Check(RB_CheckNewOrder(lim, s, 700.0) == 4, "99600 - 700 below trailing floor 99000");
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
   t.Check(RB_TradingPermission(false, RB_ACC_REAL, false, 0, 12345, false) == 2, "real account refused by default");
   t.Check(RB_TradingPermission(false, RB_ACC_REAL, true, 999, 12345, true) == 3, "login confirmation mismatch");
   t.Check(RB_TradingPermission(false, RB_ACC_REAL, true, 12345, 12345, false) == 4, "prop rules unverified");
   t.Check(RB_TradingPermission(false, RB_ACC_REAL, true, 12345, 12345, true) == 0, "all three gates -> live");
   t.Check(RB_TradingPermission(false, RB_ACC_DEMO, false, 0, 12345, false) == 0, "demo allowed");
   t.Check(RB_TradingPermission(true, RB_ACC_REAL, false, 0, 12345, false) == 0, "tester allowed");
   t.Check(RB_TradingPermission(false, RB_ACC_CONTEST, true, 12345, 12345, true) == 1, "contest refused");
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
   RB_TestPrint("RBOTE tests: passed=" + IntegerToString(t.passed) + " failed=" + IntegerToString(t.failed));
  }

#endif
