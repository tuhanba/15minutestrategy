// Dumps the C++ backtester's signal list (same chunked scan as backtest/rbote_bt.cpp) for comparison
// with RBOTE_SignalReplay.mq5. Build: g++ -std=c++17 -O2 -I<src>/MQL5/Include cpp_signals.cpp
#include "../../MQL5/Include/RBOTE/RejectionBlock.mqh"
#include "../../MQL5/Include/RBOTE/TradeMath.mqh"
#include "../../MQL5/Include/RBOTE/Regime.mqh"
#include "../../MQL5/Include/RBOTE/Safety.mqh"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
struct M1 { long long t; double bo, bh, bl, bc; };
static long long pt(const char *s){ struct tm a; memset(&a,0,sizeof a); sscanf(s,"%d-%d-%d %d:%d",&a.tm_year,&a.tm_mon,&a.tm_mday,&a.tm_hour,&a.tm_min); a.tm_year-=1900; a.tm_mon-=1; return timegm(&a); }
int main(int argc, char **argv)
{
   if(argc < 5) { puts("cpp_signals <csv> <from YYYY-MM-DD> <to YYYY-MM-DD> <out>"); return 1; }
   long long from = pt((std::string(argv[2]) + " 00:00").c_str()), to = pt((std::string(argv[3]) + " 00:00").c_str());
   std::vector<M1> m1;
   FILE *f = fopen(argv[1], "r"); char line[512]; fgets(line, sizeof line, f);
   while(fgets(line, sizeof line, f)) { M1 m; char ts[32]; if(sscanf(line, "%16[^;];%lf;%lf;%lf;%lf", ts, &m.bo, &m.bh, &m.bl, &m.bc) != 5) continue;
      m.t = pt(ts); if(m.t < from - 40LL * 86400 || m.t >= to) continue; m1.push_back(m); }
   fclose(f);
   CRBSeries m15; long long cur = -1; RBBar b{};
   for(auto &m : m1) { long long bk = m.t / 900 * 900;
      if(bk != cur) { if(cur >= 0) m15.Add(b); cur = bk; b.time = bk; b.open = m.bo; b.high = m.bh; b.low = m.bl; b.close = m.bc; }
      else { b.high = std::max(b.high, m.bh); b.low = std::min(b.low, m.bl); b.close = m.bc; } }
   if(cur >= 0) m15.Add(b);
   RBConfig cfg; cfg.Defaults(); cfg.stop_unit = RB_UNIT_PRICE;
   RBRegimeCfg reg; reg.Neutral();
   RBSymbolSpec sp{}; sp.digits = 2; sp.point = 0.01; sp.tick_size = 0.01; sp.tick_value_loss = 1.0; sp.vol_min = 0.01; sp.vol_max = 100; sp.vol_step = 0.01;
   FILE *o = fopen(argv[4], "w");
   fprintf(o, "signal_id;dir;rb_time;confirm_time;rb_low;rb_high;zone_type;zone_top;zone_bottom;zones_hit;atr;plan_rc;entry;sl;tp;risk_dist;lots;vol_ratio;er;vol_class;ranging\n");
   const int STEP = 2000, WARM = std::max(1300, reg.atr_lookback + reg.er_period + 200);
   int n = m15.Size();
   for(int s0 = 0; s0 < n; s0 += STEP) {
      int w0 = std::max(0, s0 - WARM), w1 = std::min(n, s0 + STEP);
      CRBSeries win; for(int i = w0; i < w1; i++) { m15.Bar(i, b); win.Add(b); }
      CRBVec<RBZone> zones; CRBVec<RBSignal> ss; RB_Scan(win, cfg, zones, ss);
      for(int i = 0; i < ss.Size(); i++) { RBSignal g; ss.Get(i, g); int gc = g.confirm_idx + w0;
         if(gc < s0 || gc >= w1) continue;
         if((long long)m15.Time(gc) < from) continue;
         RBRegime rg; RB_ClassifyRegime(win, g.confirm_idx, reg, rg);
         RBPlan p{}; int rc = RB_BuildPlan(g, cfg, sp, p); double lots = 0;
         if(rc == 0) { double lpl = RB_LossPerLot(p.risk_dist, sp, 6.0, 10.0); RB_CalcLots(250.0, lpl, sp, 50.0, lots); }
         fprintf(o, "%s;%d;%lld;%lld;%.3f;%.3f;%d;%.3f;%.3f;%d;%.4f;%d;%.2f;%.2f;%.2f;%.2f;%.2f;%.4f;%.4f;%d;%d\n",
                 RB_SignalId(g.dir, g.rb_time).c_str(), g.dir, (long long)g.rb_time, (long long)g.confirm_time, g.rb_low, g.rb_high,
                 g.zone_type, g.zone_top, g.zone_bottom, g.zones_hit, g.atr, rc, p.entry, p.sl, p.tp, p.risk_dist, lots,
                 rg.vol_ratio, rg.er, rg.valid ? rg.vol_class : -1, rg.ranging ? 1 : 0); } }
   fclose(o);
   return 0;
}
