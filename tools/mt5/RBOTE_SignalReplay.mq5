//+------------------------------------------------------------------+
//| RBOTE_SignalReplay.mq5                                           |
//| Account-free cross-check: replays the EA's OnNewBar signal path  |
//| (CopyRates of the last InpLookback CLOSED M15 bars -> RB_Scan -> |
//| signals confirmed by the bar that just closed -> regime ->       |
//| RB_BuildPlan -> lot size at a fixed reference balance) over the  |
//| custom symbol's history, inside the MetaTrader 5 runtime.        |
//| Output: <Common>\Files\RBOTE_DATA\<InpOut>                       |
//+------------------------------------------------------------------+
#property script_show_inputs
#include <RBOTE/RejectionBlock.mqh>
#include <RBOTE/TradeMath.mqh>
#include <RBOTE/Regime.mqh>
#include <RBOTE/MT5Bridge.mqh>
#include <RBOTE/Safety.mqh>

input string   InpSymbol     = "XAUUSD.DK";
input datetime InpFrom       = D'2020.01.20 00:00';
input datetime InpTo         = D'2020.04.01 00:00';
input int      InpLookback   = 1200;      // EA InpLookbackBars
input double   InpRefBalance = 100000.0;  // lots are computed at this balance
input double   InpRiskPct    = 0.25;
input double   InpCommission = 6.0;
input double   InpSlipTicks  = 10.0;
input string   InpOut        = "mql_signals.csv";

void OnStart(void)
  {
   RBConfig cfg;
   cfg.Defaults();
   cfg.stop_mode   = RB_STOP_FIXED;
   cfg.stop_unit   = RB_UNIT_PRICE;
   cfg.stop_distance = 10.0;
   cfg.rr          = 6.0;
   cfg.fib_level   = 0.79;
   RBRegimeCfg reg;
   reg.Neutral();
   RBSymbolSpec sp;
   if(!RB_ReadSymbolSpec(InpSymbol, sp))
     {
      Print("bad spec ", RB_SpecText(sp));
      return;
     }
   Print("spec ", RB_SpecText(sp));

   MqlRates all[];
   ArraySetAsSeries(all, false);
   int na = CopyRates(InpSymbol, PERIOD_M15, D'1970.01.02', InpTo, all);
   if(na <= 0)
     {
      PrintFormat("CopyRates failed %d", GetLastError());
      return;
     }
   int h = FileOpen("RBOTE_DATA\\" + InpOut, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ';');
   FileWrite(h, "signal_id", "dir", "rb_time", "confirm_time", "rb_low", "rb_high", "zone_type", "zone_top", "zone_bottom",
             "zones_hit", "atr", "plan_rc", "entry", "sl", "tp", "risk_dist", "lots", "vol_ratio", "er", "vol_class",
             "ranging", "window_bars");
   int nsig = 0;
   for(int k = 0; k < na; k++)
     {
      if(all[k].time < InpFrom - 900 || all[k].time >= InpTo)
         continue;
      // bar k has just closed; the EA sees bars [k-lookback+1 .. k]
      int w0 = MathMax(0, k - InpLookback + 1);
      int n = k - w0 + 1;
      if(n < 192 + 20)
         continue;
      CRBSeries s;
      RBBar b;
      for(int i = w0; i <= k; i++)
        {
         b.time = all[i].time;
         b.open = all[i].open;
         b.high = all[i].high;
         b.low = all[i].low;
         b.close = all[i].close;
         s.Add(b);
        }
      CRBVec<RBZone> zones;
      CRBVec<RBSignal> sigs;
      RB_Scan(s, cfg, zones, sigs);
      RBSignal g;
      for(int i = 0; i < sigs.Size(); i++)
        {
         sigs.Get(i, g);
         if(g.confirm_idx != n - 1)
            continue;
         RBRegime rg;
         RB_ClassifyRegime(s, g.confirm_idx, reg, rg);
         RBPlan plan;
         ZeroMemory(plan);
         int rc = RB_BuildPlan(g, cfg, sp, plan);
         double lots = 0.0;
         if(rc == 0)
           {
            double lpl = RB_LossPerLot(plan.risk_dist, sp, InpCommission, InpSlipTicks);
            RB_CalcLots(InpRefBalance * InpRiskPct / 100.0, lpl, sp, 50.0, lots);
           }
         FileWrite(h, RB_SignalId(g.dir, g.rb_time), g.dir, (long)g.rb_time, (long)g.confirm_time,
                   DoubleToString(g.rb_low, 3), DoubleToString(g.rb_high, 3), g.zone_type,
                   DoubleToString(g.zone_top, 3), DoubleToString(g.zone_bottom, 3), g.zones_hit,
                   DoubleToString(g.atr, 4), rc, DoubleToString(plan.entry, 2), DoubleToString(plan.sl, 2),
                   DoubleToString(plan.tp, 2), DoubleToString(plan.risk_dist, 2), DoubleToString(lots, 2),
                   DoubleToString(rg.vol_ratio, 4), DoubleToString(rg.er, 4), rg.valid ? rg.vol_class : -1,
                   rg.ranging ? 1 : 0, n);
         nsig++;
        }
     }
   FileClose(h);
   PrintFormat("RBOTE replay done: M15 bars=%d signals=%d -> Common\\Files\\RBOTE_DATA\\%s", na, nsig, InpOut);
  }
