// rbote_bt.cpp - independent backtester for RBOTE.
//
// Uses the SAME pure-logic headers as the MQL5 EA (MQL5/Include/RBOTE/*.mqh):
// zone detection, rejection block, Fibonacci plan, lot sizing, risk guard,
// regime, adaptive risk and trade management. Only the market simulation
// below is specific to this program.
//
// Data: M1 BID/ASK candles (tools/fetch_dukascopy.py), times in UTC.
// All time rules (day boundary, Friday cutoff, sessions) use UTC.
//
// Conservative fill model (per M1 bar, see docs/BACKTEST.md):
//   buy limit fills when ask_low <= entry (at entry), sell limit when bid_high >= entry
//   fill and SL inside the same minute -> loss
//   SL and TP inside the same minute -> SL
//   SL exit price = SL (or the worse open on a gap) minus slippage ticks
//   TP-before-fill cancel is checked when the minute did not fill
//   management stop changes take effect from the next minute
#include "../MQL5/Include/RBOTE/RejectionBlock.mqh"
#include "../MQL5/Include/RBOTE/TradeMath.mqh"
#include "../MQL5/Include/RBOTE/RiskGuard.mqh"
#include "../MQL5/Include/RBOTE/Safety.mqh"
#include "../MQL5/Include/RBOTE/Regime.mqh"
#include "../MQL5/Include/RBOTE/Adaptive.mqh"
#include "../MQL5/Include/RBOTE/TradeMgmt.mqh"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

struct M1
{
   long long t;
   double bo, bh, bl, bc, ao, ah, al, ac;
};

struct Options
{
   std::vector<std::string> files;
   std::string from = "2020-01-01", to = "2100-01-01";
   std::string out_trades = "trades.csv", out_daily = "daily.csv", out_summary = "";
   double balance = 100000.0;
   double commission = 6.0;     // per lot round turn
   double slip_ticks = 10.0;    // adverse slippage on stop exits
   int friday_cutoff = 20;      // UTC hour, -1 = off
   int expiry_bars = 8;
   double max_lots = 50.0;
   RBConfig cfg;
   RBRiskLimits lim;
   RBRegimeCfg reg;
   RBScaleCfg scale;
   RBEdgeCfg edge;
   RBMgmtCfg mgmt;
   double firm_daily_pct = 0.04; // reported only
   double firm_max_dd_pct = 0.06;
};

static long long parse_time(const char *s)
{
   // "YYYY-MM-DD HH:MM" UTC
   struct tm tmv;
   std::memset(&tmv, 0, sizeof(tmv));
   if(std::sscanf(s, "%d-%d-%d %d:%d", &tmv.tm_year, &tmv.tm_mon, &tmv.tm_mday, &tmv.tm_hour, &tmv.tm_min) < 3)
      return -1;
   tmv.tm_year -= 1900;
   tmv.tm_mon -= 1;
   return (long long)timegm(&tmv);
}

static std::string fmt_time(long long t)
{
   time_t tt = (time_t)t;
   struct tm tmv;
   gmtime_r(&tt, &tmv);
   char buf[32];
   std::strftime(buf, sizeof(buf), "%Y.%m.%d %H:%M", &tmv);
   return buf;
}

static std::string fmt_date(long long t)
{
   time_t tt = (time_t)t;
   struct tm tmv;
   gmtime_r(&tt, &tmv);
   char buf[16];
   std::strftime(buf, sizeof(buf), "%Y-%m-%d", &tmv);
   return buf;
}

static void load_csv(const std::string &path, long long from, long long to, std::vector<M1> &out)
{
   FILE *f = std::fopen(path.c_str(), "r");
   if(!f)
     {
      std::fprintf(stderr, "cannot open %s\n", path.c_str());
      std::exit(2);
     }
   char line[512];
   if(!std::fgets(line, sizeof(line), f)) // header
     {
      std::fclose(f);
      return;
     }
   while(std::fgets(line, sizeof(line), f))
     {
      M1 m;
      char ts[32];
      double vol;
      if(std::sscanf(line, "%16[^;];%lf;%lf;%lf;%lf;%lf;%lf;%lf;%lf;%lf", ts, &m.bo, &m.bh, &m.bl, &m.bc,
                     &m.ao, &m.ah, &m.al, &m.ac, &vol) != 10)
         continue;
      m.t = parse_time(ts);
      if(m.t < from || m.t >= to)
         continue;
      out.push_back(m);
     }
   std::fclose(f);
}

static int utc_hour(long long t) { return (int)((t % 86400) / 3600); }
static int utc_wday(long long t) { return (int)(((t / 86400) + 4) % 7); } // 1970-01-01 was Thursday (4)

// ----------------------------------------------------------------------------
struct SigEx
{
   RBSignal sig;    // indexes are GLOBAL M15 indexes
   RBRegime reg;
   double candle_range;
};

struct Pending
{
   bool active = false;
   SigEx s;
   RBPlan plan;
   double lots = 0, risk_money = 0, pct = 0, edge_mult = 1, regime_mult = 1, rr = 0;
   std::string scale_why;
   RBFeatures feat;
   int bars_alive = 0;
   long long placed = 0;
};

struct Position
{
   bool active = false;
   Pending p;          // everything from the order
   double lots = 0;    // remaining volume
   double sl = 0;
   double best = 0, worst = 0;
   bool partial_done = false;
   double realized = 0; // net money realized so far (partials, commission)
   long long open_time = 0;
   double fill = 0;
};

struct Engine
{
   Options o;
   RBSymbolSpec spec;
   std::vector<M1> m1;
   CRBSeries m15;
   std::vector<int> m15_first;  // first M1 index of each M15 bar
   std::vector<SigEx> sigs;

   double balance = 0, start_balance = 0, hwm = 0;
   int consec_losses = 0;
   CRBEdgeStats stats;
   long long cur_day = -1;
   double day_ref = 0, realized_today = 0, day_min_eq = 0, day_start_bal = 0;
   int trades_today = 0;
   bool day_blocked = false;
   Pending pend;
   Position pos;
   FILE *ft = nullptr, *fd = nullptr;
   std::map<std::string, long> rejects;
   long n_signals = 0, n_orders = 0, n_trades = 0, n_firm_daily = 0, n_personal_daily = 0;
   double min_equity_ever = 0;

   void reject(const std::string &why) { rejects[why]++; }

   // ------------------------------------------------------------------
   void build_m15()
     {
      m15.Clear();
      m15_first.clear();
      long long cur = -1;
      RBBar b{};
      for(size_t i = 0; i < m1.size(); i++)
        {
         long long bucket = m1[i].t / 900 * 900;
         if(bucket != cur)
           {
            if(cur >= 0)
               m15.Add(b);
            cur = bucket;
            b.time = bucket;
            b.open = m1[i].bo;
            b.high = m1[i].bh;
            b.low = m1[i].bl;
            b.close = m1[i].bc;
            m15_first.push_back((int)i);
           }
         else
           {
            b.high = std::max(b.high, m1[i].bh);
            b.low = std::min(b.low, m1[i].bl);
            b.close = m1[i].bc;
           }
        }
      if(cur >= 0)
         m15.Add(b);
      m15_first.push_back((int)m1.size());
     }

   // Chunked scan: same result as the EA's rolling window (zones expire after
   // zone_max_age_bars, swings are searched <= swing_search bars, regime uses
   // atr_lookback bars; the warm-up below covers all of them).
   void scan_signals()
     {
      const int STEP = 2000;
      const int WARM = std::max(1300, o.reg.atr_lookback + o.reg.er_period + 200);
      int n = m15.Size();
      for(int s0 = 0; s0 < n; s0 += STEP)
        {
         int w0 = std::max(0, s0 - WARM);
         int w1 = std::min(n, s0 + STEP);
         CRBSeries win;
         RBBar b;
         for(int i = w0; i < w1; i++)
           {
            m15.Bar(i, b);
            win.Add(b);
           }
         CRBVec<RBZone> zones;
         CRBVec<RBSignal> ss;
         RB_Scan(win, o.cfg, zones, ss);
         for(int i = 0; i < ss.Size(); i++)
           {
            RBSignal g;
            ss.Get(i, g);
            int gc = g.confirm_idx + w0;
            if(gc < s0 || gc >= w1)
               continue;
            SigEx e;
            RB_ClassifyRegime(win, g.confirm_idx, o.reg, e.reg);
            e.candle_range = win.H(g.rb_idx) - win.L(g.rb_idx);
            g.rb_idx += w0;
            g.confirm_idx = gc;
            e.sig = g;
            sigs.push_back(e);
           }
        }
     }

   // ------------------------------------------------------------------
   double floating(const M1 &m, bool worst_case) const
     {
      if(!pos.active)
         return 0.0;
      int dir = pos.p.plan.dir;
      double px = dir == RB_DIR_BULL ? (worst_case ? m.bl : m.bc) : (worst_case ? m.ah : m.ac);
      return dir * (px - pos.fill) * pos.lots / spec.tick_size * spec.tick_value_loss;
     }

   double pos_open_risk() const
     {
      if(!pos.active)
         return 0.0;
      int dir = pos.p.plan.dir;
      double loss = dir * (pos.fill - pos.sl) * pos.lots / spec.tick_size * spec.tick_value_loss;
      return std::max(0.0, loss) + o.commission * pos.lots;
     }

   void new_day_if_needed(const M1 &m)
     {
      long long d = m.t / 86400;
      if(d == cur_day)
         return;
      if(cur_day >= 0)
         write_day(m);
      cur_day = d;
      double eq = balance + floating(m, false);
      day_ref = std::max(balance, eq);
      day_start_bal = balance;
      realized_today = 0;
      trades_today = 0;
      day_blocked = false;
      day_min_eq = eq;
     }

   void write_day(const M1 &m)
     {
      (void)m;
      std::fprintf(fd, "%s;%.2f;%.2f;%.2f;%.2f;%d\n", fmt_date(cur_day * 86400).c_str(), day_ref,
                   day_start_bal, day_min_eq, balance, trades_today);
      double min_pnl = day_min_eq - day_ref;
      if(min_pnl <= -o.firm_daily_pct * day_ref)
         n_firm_daily++;
      if(min_pnl <= -o.lim.daily_loss_pct * day_ref)
         n_personal_daily++;
     }

   void close_portion(double lots, double price, const std::string &reason, long long t)
     {
      int dir = pos.p.plan.dir;
      double pnl = dir * (price - pos.fill) * lots / spec.tick_size * spec.tick_value_loss - o.commission * lots;
      pos.realized += pnl;
      balance += pnl;
      realized_today += pnl;
      pos.lots -= lots;
      if(pos.lots > 1e-9)
         return;
      // fully closed
      double net = pos.realized;
      double r = pos.p.risk_money > 0 ? net / pos.p.risk_money : 0.0;
      double risk0 = pos.p.plan.risk_dist;
      double mfe = risk0 > 0 ? dir * (pos.best - pos.fill) / risk0 : 0.0;
      double mae = risk0 > 0 ? dir * (pos.worst - pos.fill) / risk0 : 0.0;
      const RBSignal &g = pos.p.s.sig;
      long long sig_time = (long long)g.confirm_time + 900;
      int delay = (int)((pos.open_time - sig_time) / 900);
      double wick = pos.p.s.candle_range > 0 ? (g.rb_high - g.rb_low) / pos.p.s.candle_range : 0.0;
      double rba = g.atr > 0 ? (g.rb_high - g.rb_low) / g.atr : 0.0;
      double sta = g.atr > 0 ? risk0 / g.atr : 0.0;
      const RBRegime &rg = pos.p.s.reg;
      std::string regime = !rg.valid ? "UNKNOWN" : RB_VolText(rg.vol_class) + (rg.ranging ? "+RANGE" : "");
      std::fprintf(ft,
                   "%s;%s;%d;%.2f;%.3f;%.2f;%.2f;%.2f;%.2f;%.2f;%.4f;%s;%.3f;%d;%.2f;%d;%.3f;%s;%.3f;%.3f;%.2f;"
                   "%s;%.2f;%.2f;%s;%d;%d;%d;%.3f;%.3f;%.3f;%d;%.3f;%.3f;%s\n",
                   fmt_time(pos.open_time).c_str(), fmt_time(t).c_str(), dir, pos.p.plan.entry, pos.fill,
                   pos.p.plan.sl, pos.p.plan.tp, pos.p.lots, pos.p.risk_money, net, r,
                   RB_SignalId(dir, g.rb_time).c_str(), g.atr, g.zone_type, pos.p.rr,
                   o.cfg.stop_mode, price, regime.c_str(), rg.vol_ratio, rg.er, pos.p.regime_mult, reason.c_str(),
                   mfe, mae, RB_SessionText(RB_SessionBucket(utc_hour(sig_time))).c_str(), utc_hour(sig_time),
                   utc_wday(sig_time), g.zones_hit, wick, rba, sta, delay, pos.p.pct * 100.0, pos.p.edge_mult,
                   pos.p.scale_why.c_str());
      n_trades++;
      stats.Add(pos.p.feat, r);
      consec_losses = net < 0 ? consec_losses + 1 : 0;
      hwm = std::max(hwm, balance);
      pos.active = false;
     }

   // ------------------------------------------------------------------
   void process_minute(const M1 &m)
     {
      // 1. pending order: fill or target-before-fill
      if(pend.active && m.t >= pend.placed)
        {
         int dir = pend.plan.dir;
         bool filled = dir == RB_DIR_BULL ? (m.al <= pend.plan.entry) : (m.bh >= pend.plan.entry);
         if(filled)
           {
            pos = Position();
            pos.active = true;
            pos.p = pend;
            pos.lots = pend.lots;
            pos.sl = pend.plan.sl;
            pos.fill = pend.plan.entry;
            pos.best = pos.worst = pos.fill;
            pos.open_time = m.t;
            pend.active = false;
            trades_today++;
            // same minute stop -> loss (conservative)
            bool sl_hit = dir == RB_DIR_BULL ? (m.bl <= pos.sl) : (m.ah >= pos.sl);
            if(sl_hit)
              {
               pos.worst = pos.sl;
               double px = pos.sl - dir * o.slip_ticks * spec.tick_size;
               close_portion(pos.lots, px, "SL", m.t);
              }
            else
               pos.worst = dir == RB_DIR_BULL ? std::min(pos.worst, m.bl) : std::max(pos.worst, m.ah);
            return;
           }
         bool tp_seen = dir == RB_DIR_BULL ? (m.bh >= pend.plan.tp) : (m.al <= pend.plan.tp);
         if(tp_seen)
           {
            pend.active = false;
            reject("CANCEL_TARGET_REACHED_BEFORE_FILL");
           }
        }
      // 2. open position
      if(pos.active)
        {
         int dir = pos.p.plan.dir;
         double lo = dir == RB_DIR_BULL ? m.bl : m.al;
         double hi = dir == RB_DIR_BULL ? m.bh : m.ah;
         double open = dir == RB_DIR_BULL ? m.bo : m.ao;
         bool sl_hit = dir == RB_DIR_BULL ? (lo <= pos.sl) : (hi >= pos.sl);
         if(sl_hit)
           {
            double base = dir == RB_DIR_BULL ? std::min(pos.sl, open) : std::max(pos.sl, open);
            pos.worst = dir == RB_DIR_BULL ? std::min(pos.worst, lo) : std::max(pos.worst, hi);
            close_portion(pos.lots, base - dir * o.slip_ticks * spec.tick_size,
                          pos.sl == pos.p.plan.sl ? "SL" : "MGMT_SL", m.t);
            return;
           }
         double risk0 = pos.p.plan.risk_dist;
         if(!pos.partial_done && o.mgmt.partial_at_r > 0)
           {
            double ppx = RB_MgmtPartialPrice(dir, pos.fill, risk0, o.mgmt);
            bool reached = dir == RB_DIR_BULL ? (hi >= ppx) : (lo <= ppx);
            if(reached)
              {
               double v = RB_MgmtPartialVolume(pos.lots, o.mgmt, spec.vol_min, spec.vol_step);
               pos.partial_done = true;
               if(v > 0)
                  close_portion(v, ppx, "PARTIAL", m.t);
              }
           }
         bool tp_hit = dir == RB_DIR_BULL ? (hi >= pos.p.plan.tp) : (lo <= pos.p.plan.tp);
         pos.best = dir == RB_DIR_BULL ? std::max(pos.best, hi) : std::min(pos.best, lo);
         pos.worst = dir == RB_DIR_BULL ? std::min(pos.worst, lo) : std::max(pos.worst, hi);
         if(tp_hit)
           {
            double px = dir == RB_DIR_BULL ? std::max(pos.p.plan.tp, open) : std::min(pos.p.plan.tp, open);
            close_portion(pos.lots, px, "TP", m.t);
            return;
           }
         pos.sl = RB_MgmtStop(dir, pos.fill, pos.sl, risk0, pos.best, o.mgmt, spec.tick_size);
        }
     }

   void track_equity(const M1 &m)
     {
      double eq_worst = balance + floating(m, true);
      day_min_eq = std::min(day_min_eq, eq_worst);
      min_equity_ever = std::min(min_equity_ever, eq_worst);
      hwm = std::max(hwm, balance);
      o.lim.peak_equity = std::max(o.lim.peak_equity, balance + floating(m, false));
     }

   // ------------------------------------------------------------------
   RBRiskSnapshot snapshot(const M1 &m) const
     {
      RBRiskSnapshot s;
      s.balance = balance;
      s.equity = balance + floating(m, false);
      s.day_start_ref = day_ref;
      s.realized_today = realized_today;
      s.open_risk = pos_open_risk();
      s.pending_risk = pend.active ? pend.risk_money : 0.0;
      s.trades_today = trades_today;
      s.positions = pos.active ? 1 : 0;
      s.pending = pend.active ? 1 : 0;
      s.unprotected_position = false;
      return s;
     }

   void on_bar_close(int k)
     {
      const M1 &last = m1[m15_first[k + 1] - 1];
      // pending maintenance on the closed bar
      if(pend.active)
        {
         pend.bars_alive++;
         const SigEx &e = pend.s;
         int code = RB_PendingCancelOnBar(pend.plan.dir, pend.plan.tp, e.sig.rb_low, e.sig.rb_high,
                                          e.sig.zone_top, e.sig.zone_bottom, m15.H(k), m15.L(k), m15.C(k),
                                          pend.bars_alive, o.expiry_bars);
         if(code != RB_CANCEL_NONE)
           {
            pend.active = false;
            reject(std::string("CANCEL_") + RB_CancelText(code));
           }
        }
      // daily limit with existing exposure
      double day_pnl = realized_today + floating(last, false);
      if(!day_blocked && day_pnl <= -o.lim.daily_loss_pct * day_ref + 1e-6)
        {
         day_blocked = true;
         if(pend.active)
           {
            pend.active = false;
            reject("CANCEL_DAILY_LOSS_LIMIT");
           }
        }
      // Friday cutoff cancels pending
      if(o.friday_cutoff >= 0 && pend.active)
        {
         long long next = (long long)m15.Time(k) + 900;
         int wd = utc_wday(next);
         if((wd == 5 && utc_hour(next) >= o.friday_cutoff) || wd == 6 || wd == 0)
           {
            pend.active = false;
            reject("CANCEL_FRIDAY_CUTOFF");
           }
        }
     }

   void on_signal(const SigEx &e, int k)
     {
      n_signals++;
      // EA acts at the first tick of the next bar; a gap means stale data -> skipped
      if(k + 1 >= m15.Size() || (long long)m15.Time(k + 1) != (long long)m15.Time(k) + 900)
        {
         reject("DATA_STALE");
         return;
        }
      const M1 &m = m1[m15_first[k + 1]];
      RBRegimeDecision rd;
      RB_RegimeDecide(e.reg, o.reg, o.cfg.rr, rd);
      if(!rd.allow)
        {
         reject("REGIME_SKIP_" + rd.reason);
         return;
        }
      if(day_blocked)
        {
         reject("DAILY_BLOCK");
         return;
        }
      int wd = utc_wday(m.t), hr = utc_hour(m.t);
      if(o.friday_cutoff >= 0 && ((wd == 5 && hr >= o.friday_cutoff) || wd == 6 || wd == 0))
        {
         reject("FRIDAY_CUTOFF");
         return;
        }
      RBConfig cfg = o.cfg;
      cfg.rr = rd.rr;
      RBPlan plan;
      int r = RB_BuildPlan(e.sig, cfg, spec, plan);
      if(r != 0)
        {
         reject(RB_ReasonText(r));
         return;
        }
      r = RB_CheckMarket(plan, cfg, spec, m.bo, m.ao);
      if(r != 0)
        {
         reject(RB_ReasonText(r));
         return;
        }
      const M1 &prev = m1[m15_first[k + 1] - 1];   // last minute of the confirming bar
      double eq = balance + floating(prev, false);
      double ref = std::min(balance, eq);
      std::string scale_why;
      double pct = RB_ProfitScaledPct(o.scale, start_balance, balance, hwm, ref, consec_losses, scale_why);
      RBFeatures feat;
      RB_MakeFeatures(e.sig.dir, e.sig.zone_type, e.reg.valid ? e.reg.vol_class : RB_VOL_NORMAL, e.reg.ranging, hr, feat);
      std::string edge_why;
      double em = stats.Mult(feat, o.edge, edge_why);
      double risk_money = RB_FinalRiskMoney(pct, ref, rd.risk_mult, em, o.scale.max_pct);
      double lpl = RB_LossPerLot(plan.risk_dist, spec, o.commission, o.slip_ticks);
      double lots = 0;
      r = RB_CalcLots(risk_money, lpl, spec, o.max_lots, lots);
      if(r != 0)
        {
         reject(RB_ReasonText(r));
         return;
        }
      double trade_risk = lots * lpl;
      int g = RB_CheckNewOrder(o.lim, snapshot(prev), trade_risk);
      if(g != 0)
        {
         reject(std::string("GUARD_") + RB_GuardText(g));
         return;
        }
      pend = Pending();
      pend.active = true;
      pend.s = e;
      pend.plan = plan;
      pend.lots = lots;
      pend.risk_money = trade_risk;
      pend.pct = pct;
      pend.edge_mult = em;
      pend.regime_mult = rd.risk_mult;
      pend.rr = cfg.rr;
      pend.scale_why = scale_why;
      pend.feat = feat;
      pend.placed = m.t;
      n_orders++;
     }

   // ------------------------------------------------------------------
   void run()
     {
      spec.digits = 2;
      spec.point = 0.01;
      spec.tick_size = 0.01;
      spec.tick_value_loss = 1.0;   // 100 oz contract, USD account
      spec.vol_min = 0.01;
      spec.vol_max = 100.0;
      spec.vol_step = 0.01;
      spec.stops_level = 0;
      spec.freeze_level = 0;

      long long from = parse_time((o.from + " 00:00").c_str());
      long long to = parse_time((o.to + " 00:00").c_str());
      // load extra history before `from` for indicator warm-up (signals before `from` are ignored)
      long long load_from = from - 40LL * 86400;
      for(const auto &f : o.files)
         load_csv(f, load_from, to, m1);
      std::sort(m1.begin(), m1.end(), [](const M1 &a, const M1 &b) { return a.t < b.t; });
      if(m1.empty())
        {
         std::fprintf(stderr, "no data\n");
         std::exit(2);
        }
      build_m15();
      scan_signals();

      balance = start_balance = hwm = o.balance;
      min_equity_ever = balance;
      o.lim.initial_balance = o.balance;
      o.lim.peak_equity = o.balance;
      ft = std::fopen(o.out_trades.c_str(), "w");
      fd = std::fopen(o.out_daily.c_str(), "w");
      std::fprintf(ft, "open_time;close_time;dir;planned_entry;fill_price;sl;tp;volume;risk_money;net;r;signal_id;"
                       "atr;zone_type;rr;stop_mode;exit_price;regime;vol_ratio;er;risk_mult;"
                       "exit_reason;mfe_r;mae_r;session;hour;weekday;zones_hit;wick_ratio;rb_range_atr;stop_atr;"
                       "fill_delay_bars;risk_pct;edge_mult;scale_reason\n");
      std::fprintf(fd, "date;day_ref;start_balance;min_equity;end_balance;fills\n");

      size_t si = 0;
      int nb = m15.Size();
      for(int k = 0; k < nb; k++)
        {
         for(int i = m15_first[k]; i < m15_first[k + 1]; i++)
           {
            const M1 &m = m1[i];
            if(m.t < from)
               continue;
            new_day_if_needed(m);
            process_minute(m);
            track_equity(m);
           }
         if((long long)m15.Time(k) < from)
           {
            while(si < sigs.size() && sigs[si].sig.confirm_idx <= k)
               si++;
            continue;
           }
         on_bar_close(k);
         while(si < sigs.size() && sigs[si].sig.confirm_idx < k)
            si++;
         while(si < sigs.size() && sigs[si].sig.confirm_idx == k)
           {
            on_signal(sigs[si], k);
            si++;
           }
        }
      if(cur_day >= 0)
         write_day(m1.back());
      std::fclose(ft);
      std::fclose(fd);
      summary();
     }

   void summary()
     {
      std::ostringstream s;
      s << "period " << o.from << " -> " << o.to << " | M1 bars " << m1.size() << " | M15 bars " << m15.Size() << "\n";
      s << "signals " << n_signals << " | orders " << n_orders << " | closed trades " << n_trades << "\n";
      s << "final balance " << balance << " | net " << balance - o.balance << " | lowest equity " << min_equity_ever << "\n";
      s << "days breaching personal daily " << o.lim.daily_loss_pct * 100 << "%: " << n_personal_daily
        << " | firm daily " << o.firm_daily_pct * 100 << "%: " << n_firm_daily
        << " | firm static max DD " << o.firm_max_dd_pct * 100 << "% breached: "
        << (min_equity_ever <= o.balance * (1 - o.firm_max_dd_pct) ? "YES" : "no") << "\n";
      s << "rejects / cancels:\n";
      for(const auto &kv : rejects)
         s << "  " << kv.first << " " << kv.second << "\n";
      std::fputs(s.str().c_str(), stdout);
      if(!o.out_summary.empty())
        {
         std::ofstream f(o.out_summary);
         f << s.str();
        }
     }
};

// ----------------------------------------------------------------------------
static void usage()
{
   std::puts(
       "rbote_bt --data FILE [--data FILE...] [options]\n"
       "  --from YYYY-MM-DD --to YYYY-MM-DD   period (to exclusive)\n"
       "  --out-trades F --out-daily F --out-summary F\n"
       "  --balance 100000 --risk 0.25 --daily 1.0 --open-risk 0.5 --max-dd 4.0 --dd-trailing on|off\n"
       "  --commission 6 --slip-ticks 10 --friday-cutoff 20 --expiry 8\n"
       "  --rr 6 --fib 0.79 --stop fixed|structural --stop-dist 10 --stop-unit price|points|ticks --buffer 0.30\n"
       "  --wick 0.5 --close-rule body|close --confirm rb|next --zone-age 192\n"
       "  --regime neutral|policy|off   --adaptive on|off\n"
       "  --be-r X --be-offset-r Y --trail-start-r X --trail-r Y --partial-r X --partial-frac F");
}

int main(int argc, char **argv)
{
   Engine e;
   Options &o = e.o;
   o.cfg.Defaults();
   o.cfg.stop_unit = RB_UNIT_PRICE;
   o.lim.Defaults();
   o.lim.max_total_dd_pct = 0.04;
   o.reg.Neutral();
   o.scale.Defaults();
   o.scale.enabled = false;
   o.edge.Defaults();
   o.edge.enabled = false;
   o.mgmt.Defaults();
   for(int i = 1; i < argc; i++)
     {
      std::string a = argv[i];
      auto next = [&]() -> std::string {
         if(i + 1 >= argc)
           {
            usage();
            std::exit(1);
           }
         return argv[++i];
      };
      auto num = [&]() { return std::atof(next().c_str()); };
      if(a == "--data") o.files.push_back(next());
      else if(a == "--from") o.from = next();
      else if(a == "--to") o.to = next();
      else if(a == "--out-trades") o.out_trades = next();
      else if(a == "--out-daily") o.out_daily = next();
      else if(a == "--out-summary") o.out_summary = next();
      else if(a == "--balance") o.balance = num();
      else if(a == "--risk") { o.lim.risk_pct = num() / 100.0; o.scale.base_pct = o.lim.risk_pct; }
      else if(a == "--max-risk") o.scale.max_pct = num() / 100.0;
      else if(a == "--daily") o.lim.daily_loss_pct = num() / 100.0;
      else if(a == "--open-risk") o.lim.max_open_risk_pct = num() / 100.0;
      else if(a == "--max-dd") o.lim.max_total_dd_pct = num() / 100.0;
      else if(a == "--dd-trailing") o.lim.trailing_dd = next() == "on";
      else if(a == "--commission") o.commission = num();
      else if(a == "--slip-ticks") o.slip_ticks = num();
      else if(a == "--friday-cutoff") o.friday_cutoff = (int)num();
      else if(a == "--expiry") o.expiry_bars = (int)num();
      else if(a == "--rr") o.cfg.rr = num();
      else if(a == "--fib") o.cfg.fib_level = num();
      else if(a == "--stop") o.cfg.stop_mode = next() == "structural" ? RB_STOP_STRUCTURAL : RB_STOP_FIXED;
      else if(a == "--stop-dist") o.cfg.stop_distance = num();
      else if(a == "--stop-unit")
        {
         std::string u = next();
         o.cfg.stop_unit = u == "points" ? RB_UNIT_POINTS : u == "ticks" ? RB_UNIT_TICKS : RB_UNIT_PRICE;
        }
      else if(a == "--buffer") o.cfg.structural_buffer = num();
      else if(a == "--wick") o.cfg.rb_min_wick_ratio = num();
      else if(a == "--close-rule") o.cfg.rb_close_rule = next() == "close" ? RB_CLOSE_NOT_THROUGH : RB_CLOSE_BODY_OUTSIDE;
      else if(a == "--confirm") o.cfg.rb_confirm = next() == "next" ? RB_CONFIRM_NEXT_CLOSE : RB_CONFIRM_RB_CLOSE;
      else if(a == "--zone-age") o.cfg.zone_max_age_bars = (int)num();
      else if(a == "--regime")
        {
         std::string v = next();
         if(v == "policy") o.reg.Defaults();
         else if(v == "off") { o.reg.Defaults(); o.reg.enabled = false; }
         else o.reg.Neutral();
        }
      else if(a == "--adaptive")
        {
         bool on = next() == "on";
         o.scale.enabled = on;
         o.edge.enabled = on;
        }
      else if(a == "--be-r") o.mgmt.be_at_r = num();
      else if(a == "--be-offset-r") o.mgmt.be_offset_r = num();
      else if(a == "--trail-start-r") o.mgmt.trail_start_r = num();
      else if(a == "--trail-r") o.mgmt.trail_dist_r = num();
      else if(a == "--partial-r") o.mgmt.partial_at_r = num();
      else if(a == "--partial-frac") o.mgmt.partial_frac = num();
      else
        {
         usage();
         return 1;
        }
     }
   if(o.files.empty())
     {
      usage();
      return 1;
     }
   e.run();
   return 0;
}
