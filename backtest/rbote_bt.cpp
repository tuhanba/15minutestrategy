// rbote_bt.cpp - independent backtester for RBOTE and DTBS (--strategy rbote|dtbs).
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
// DTBS (spec docs/02): signal at the close of the break bar, MARKET entry at the open of the
//   next minute (buy at ask open, sell at bid open, no extra slippage, D-034); main trend from
//   H1 + H4 bars built from the same M1 data. H4 buckets follow the broker clock
//   (--htf-offset, default UTC+2) so they match the MT5 H4 bars the EA sees.
#include "../MQL5/Include/RBOTE/RejectionBlock.mqh"
#include "../MQL5/Include/RBOTE/TradeMath.mqh"
#include "../MQL5/Include/RBOTE/RiskGuard.mqh"
#include "../MQL5/Include/RBOTE/Safety.mqh"
#include "../MQL5/Include/RBOTE/Regime.mqh"
#include "../MQL5/Include/RBOTE/Adaptive.mqh"
#include "../MQL5/Include/RBOTE/TradeMgmt.mqh"
#include "../MQL5/Include/RBOTE/DTBS.mqh"

#include <algorithm>
#include <climits>
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
   int strategy = 1;             // RB_SID_RBOTE / RB_SID_DTBS (Journal.mqh ids)
   RBDtbsConfig dcfg;
   int htf_offset_h = 2;         // broker clock - UTC for H1/H4 bucketing (EET winter = 2)
   double min_stop_spread_mult = 2.0;
   std::string label_out = "";   // DTBS: write one independent outcome row per signal and exit
   int label_horizon_min = 14400; // label: max holding time (minutes) before the open trade is marked to market
   double swap_long = 0.0;       // $ per lot per night (negative = cost), charged at the rollover hour
   double swap_short = 0.0;      // triple on Wednesday night
   int swap_hour = 21;           // UTC rollover hour (manager D-026)
   bool end_close = true;        // close an open position at the end of the period (reason END)
   // firm rules, reported only (Upcomers Ash Turbo: daily 3% of initial, 6% equity-peak shield)
   double firm_daily_pct = 0.03;
   bool firm_daily_on_initial = true;
   double firm_max_dd_pct = 0.06;
   bool firm_dd_trailing = true;
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
   int sid = 1;           // 1 = RBOTE, 2 = DTBS
   RBDtbsSignal ds;       // DTBS only (indexes are GLOBAL M15 indexes)
   int used_mode = -1;    // DTBS stop mode actually used
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
   double swap = 0;     // accumulated swap, realized at the final close
   long long last_swap_day = -1;
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
   std::vector<RBDtbsSignal> dsigs;
   std::vector<RBRegime> dregs;
   long n_tri = 0;
   CRBSeries h1, h4, d1;                       // DTBS: HTF bars (broker clock buckets)
   std::vector<double> e_h1_200, e_h4_50, e_d1_50;   // label context: EMAs of HTF closes
   CRBVec<double> ctx_d1, ctx_h4;              // context filter EMAs (shared code, DTBS.mqh)

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
   double firm_peak_eq = 0;
   bool firm_dd_breached = false;
   long long firm_dd_breach_time = 0;

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

   static std::string dtbs_id(int dir, long long break_time)
     {
      return std::string("DTBS|") + (dir == RB_DIR_BULL ? "B" : "S") + "|" + std::to_string(break_time);
     }

   // HTF bars from M1 bid, bucketed on the broker clock (offset hours), times stored in UTC
   void build_htf(int period_sec, CRBSeries &out) const
     {
      out.Clear();
      long long off = (long long)o.htf_offset_h * 3600;
      long long cur = LLONG_MIN;
      RBBar b{};
      for(size_t i = 0; i < m1.size(); i++)
        {
         long long bucket = (m1[i].t + off) / period_sec * period_sec - off;
         if(bucket != cur)
           {
            if(cur != LLONG_MIN)
               out.Add(b);
            cur = bucket;
            b.time = bucket;
            b.open = m1[i].bo;
            b.high = m1[i].bh;
            b.low = m1[i].bl;
            b.close = m1[i].bc;
           }
         else
           {
            b.high = std::max(b.high, m1[i].bh);
            b.low = std::min(b.low, m1[i].bl);
            b.close = m1[i].bc;
           }
        }
      if(cur != LLONG_MIN)
         out.Add(b);
     }

   static void ema(const CRBSeries &s, int n, std::vector<double> &out)
     {
      out.assign(s.Size(), 0.0);
      double a = 2.0 / (n + 1), v = 0;
      for(int i = 0; i < s.Size(); i++)
        {
         v = i == 0 ? s.C(0) : v + a * (s.C(i) - v);
         out[i] = i + 1 >= n ? v : 0.0;   // 0 = not warmed up
        }
     }

   // +1 trade direction agrees, -1 disagrees, 0 unknown. slope: EMA(last closed) vs EMA(last-5)
   int htf_slope(const CRBSeries &h, int per, const std::vector<double> &e, int k, int dir) const
     {
      int j = RB_DtbsHtfIndexAt(h, per, m15.Time(k), 900);
      if(j < 5 || e[j] == 0.0 || e[j - 5] == 0.0)
         return 0;
      double d = e[j] - e[j - 5];
      return d * dir > 0 ? 1 : -1;
     }
   int htf_side(const CRBSeries &h, int per, const std::vector<double> &e, int k, int dir) const
     {
      int j = RB_DtbsHtfIndexAt(h, per, m15.Time(k), 900);
      if(j < 0 || e[j] == 0.0)
         return 0;
      return (h.C(j) - e[j]) * dir > 0 ? 1 : -1;
     }

   // One deterministic scan over the whole M15 history (the EA rescans its 1200-bar window every
   // bar; triangles need <= max_leg_bars + ext_bars bars, so the signals are the same once warm).
   // RB_DtbsHtfIndexAt only takes HTF bars whose close <= the M15 close: no lookahead.
   void scan_dtbs()
     {
      CRBSeries all;
      build_htf(3600, h1);
      build_htf(4 * 3600, h4);
      build_htf(86400, d1);
      ema(h1, 200, e_h1_200);
      ema(h4, 50, e_h4_50);
      ema(d1, 50, e_d1_50);
      RB_DtbsEmaSeries(d1, o.dcfg.ctx_ema_period, ctx_d1);
      RB_DtbsEmaSeries(h4, o.dcfg.ctx_ema_period, ctx_h4);
      RBBar b;
      for(int i = 0; i < m15.Size(); i++)
        {
         m15.Bar(i, b);
         all.Add(b);
        }
      CRBVec<int> t1, t4, a1, a4, mt;
      RB_DtbsTrendSeries(h1, o.dcfg.htf_swing_n, t1);
      RB_DtbsTrendSeries(h4, o.dcfg.htf_swing_n, t4);
      RB_DtbsAlignTrend(all, 900, h1, 3600, t1, a1);
      RB_DtbsAlignTrend(all, 900, h4, 4 * 3600, t4, a4);
      RB_DtbsCombineSeries(a1, a4, o.dcfg.htf_agreement, mt);
      CRBVec<RBDtbsTriangle> tris;
      CRBVec<RBDtbsSignal> ss;
      RB_DtbsScanEx(all, mt, o.dcfg, tris, ss);   // computes ATR on `all` (regime uses it)
      n_tri = tris.Size();
      for(int i = 0; i < ss.Size(); i++)
        {
         RBDtbsSignal g;
         ss.Get(i, g);
         RBRegime rg;
         RB_ClassifyRegime(all, g.break_idx, o.reg, rg);
         dsigs.push_back(g);
         dregs.push_back(rg);
        }
     }

   // ------------------------------------------------------------------
   double floating(const M1 &m, bool worst_case) const
     {
      if(!pos.active)
         return 0.0;
      int dir = pos.p.plan.dir;
      double px = dir == RB_DIR_BULL ? (worst_case ? m.bl : m.bc) : (worst_case ? m.ah : m.ac);
      return dir * (px - pos.fill) * pos.lots / spec.tick_size * spec.tick_value_loss + pos.swap;
     }

   // loss if the stop is hit, measured from `from` (+ commission + slippage allowance)
   double stop_loss_from(double from) const
     {
      int dir = pos.p.plan.dir;
      double loss = dir * (from - pos.sl) * pos.lots / spec.tick_size * spec.tick_value_loss;
      return std::max(0.0, loss) + (o.commission + o.slip_ticks * spec.tick_value_loss) * pos.lots;
     }

   double pos_open_risk() const { return pos.active ? stop_loss_from(pos.fill) : 0.0; }

   double pos_risk_now(const M1 &m) const
     {
      if(!pos.active)
         return 0.0;
      return stop_loss_from(pos.p.plan.dir == RB_DIR_BULL ? m.bc : m.ac) - std::min(0.0, pos.swap);
     }

   // overnight swap at the rollover hour (UTC), triple on Wednesday night
   void apply_swap(const M1 &m)
     {
      if(!pos.active)
         return;
      long long day = m.t / 86400;
      long long rollover = day * 86400 + (long long)o.swap_hour * 3600;
      if(m.t < rollover || pos.open_time >= rollover || pos.last_swap_day == day)
         return;
      pos.last_swap_day = day;
      double per_lot = pos.p.plan.dir == RB_DIR_BULL ? o.swap_long : o.swap_short;
      pos.swap += per_lot * pos.lots * (utc_wday(m.t) == 3 ? 3.0 : 1.0);
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
      if(min_pnl <= -o.firm_daily_pct * (o.firm_daily_on_initial ? o.balance : day_ref))
         n_firm_daily++;
      if(min_pnl <= -o.lim.daily_loss_pct * (o.lim.daily_on_initial ? o.balance : day_ref))
         n_personal_daily++;
     }

   void close_portion(double lots, double price, const std::string &reason, long long t)
     {
      int dir = pos.p.plan.dir;
      double pnl = dir * (price - pos.fill) * lots / spec.tick_size * spec.tick_value_loss - o.commission * lots;
      if(pos.lots - lots <= 1e-9)
        {
         pnl += pos.swap;   // swap is realized with the final close
         pos.swap = 0;
        }
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
      bool dt = pos.p.sid == 2;
      const RBDtbsSignal &d = pos.p.ds;
      long long sig_time = dt ? (long long)d.break_time + 900 : (long long)g.confirm_time + 900;
      int delay = (int)((pos.open_time - sig_time) / 900);
      double atr = dt ? d.atr : g.atr;
      double wick = (!dt && pos.p.s.candle_range > 0) ? (g.rb_high - g.rb_low) / pos.p.s.candle_range : 0.0;
      double rba = (!dt && g.atr > 0) ? (g.rb_high - g.rb_low) / g.atr : 0.0;
      double sta = atr > 0 ? risk0 / atr : 0.0;
      std::string sid_txt = dt ? dtbs_id(dir, d.break_time) : RB_SignalId(dir, g.rb_time);
      const RBRegime &rg = pos.p.s.reg;
      std::string regime = !rg.valid ? "UNKNOWN" : RB_VolText(rg.vol_class) + (rg.ranging ? "+RANGE" : "");
      std::fprintf(ft,
                   "%s;%s;%d;%.2f;%.3f;%.2f;%.2f;%.2f;%.2f;%.2f;%.4f;%s;%.3f;%d;%.2f;%d;%.3f;%s;%.3f;%.3f;%.2f;"
                   "%s;%.2f;%.2f;%s;%d;%d;%d;%.3f;%.3f;%.3f;%d;%.3f;%.3f;%s;%s;%s;%s\n",
                   fmt_time(pos.open_time).c_str(), fmt_time(t).c_str(), dir, pos.p.plan.entry, pos.fill,
                   pos.p.plan.sl, pos.p.plan.tp, pos.p.lots, pos.p.risk_money, net, r,
                   sid_txt.c_str(), atr, dt ? -1 : g.zone_type, pos.p.rr,
                   dt ? pos.p.used_mode : o.cfg.stop_mode, price, regime.c_str(), rg.vol_ratio, rg.er, pos.p.regime_mult, reason.c_str(),
                   mfe, mae, RB_SessionText(RB_SessionBucket(utc_hour(sig_time))).c_str(), utc_hour(sig_time),
                   utc_wday(sig_time), dt ? 0 : g.zones_hit, wick, rba, sta, delay, pos.p.pct * 100.0, pos.p.edge_mult,
                   pos.p.scale_why.c_str(), dt ? "DTBS" : "RBOTE",
                   dt ? (d.with_trend ? "WITH_TREND" : "COUNTER") : "",
                   dt ? RB_DtbsSlModeText(pos.p.used_mode).c_str() : "");
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
      // firm max-loss: static floor or equity-peak shield locked at the initial balance (reported only)
      firm_peak_eq = std::max(firm_peak_eq, balance + floating(m, false));
      double ffloor = o.balance * (1 - o.firm_max_dd_pct);
      if(o.firm_dd_trailing)
         ffloor = std::min(o.balance, std::max(ffloor, firm_peak_eq - o.firm_max_dd_pct * o.balance));
      if(!firm_dd_breached && eq_worst < ffloor)
        {
         firm_dd_breached = true;
         firm_dd_breach_time = m.t;
        }
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
      s.open_risk_now = pos_risk_now(m);
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
      // daily limit with existing exposure (equity vs the 00:00 UTC reference, same as the EA)
      if(!day_blocked && RB_DailyLimitBreached(o.lim, snapshot(last)))
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
      new_day_if_needed(m);   // the EA rolls the day before evaluating a signal at 00:00
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

   // DTBS research labels: every signal is simulated on its own (no position overlap, no daily
   // guard) so filters can be screened on a clean signal-level dataset. Exit rules = the engine's
   // (SL first inside a minute, slippage on SL, commission); TP is not placed: the row stores the
   // maximum favourable excursion BEFORE the stop (mfe_r), so any RR target can be evaluated later.
   void write_labels(long long from, long long to)
     {
      FILE *f = std::fopen(o.label_out.c_str(), "w");
      std::fprintf(f, "break_time;entry_time;dir;with_trend;main_trend;sl_mode;entry;sl;risk;atr;stop_atr;leg_atr;"
                      "body_atr;beyond_atr;b_to_break;a_to_b;hour;weekday;vol_ratio;er;vol_class;ranging;spread;"
                      "lots;risk_money;cost_r;sl_hit;minutes;mfe_r;end_r;d1_slope;h4_slope;h1_side;"
                      "rt_filled;rt_pre_mfe_r;rt_risk;rt_q;rt_cost_r;rt_mfe_r;rt_end_r\n");
      for(size_t i = 0; i < dsigs.size(); i++)
        {
         const RBDtbsSignal &g = dsigs[i];
         int k = g.break_idx;
         if((long long)m15.Time(k) < from || (long long)m15.Time(k) >= to)
            continue;
         if(k + 1 >= m15.Size() || (long long)m15.Time(k + 1) != (long long)m15.Time(k) + 900)
            continue;
         int i0 = m15_first[k + 1];
         const M1 &m = m1[i0];
         int wd = utc_wday(m.t), hr = utc_hour(m.t);
         if(o.friday_cutoff >= 0 && ((wd == 5 && hr >= o.friday_cutoff) || wd == 6 || wd == 0))
            continue;
         double spread = m.ao - m.bo;
         double live = g.dir == RB_DIR_BULL ? m.ao : m.bo;
         RBPlan plan;
         int used = -1;
         if(RB_DtbsBuildPlanEx(g, o.dcfg, spec, live, spread, plan, used) != 0)
            continue;
         if(RB_DtbsCheckMarket(plan, spec, m.bo, m.ao, o.min_stop_spread_mult) != 0)
            continue;
         double lpl = RB_LossPerLot(plan.risk_dist, spec, o.commission, o.slip_ticks);
         double lots = 0;
         if(RB_CalcLots(o.balance * o.lim.risk_pct, lpl, spec, o.max_lots, lots) != 0)
            continue;
         double rm = lots * lpl;
         double per_px = lots / spec.tick_size * spec.tick_value_loss;   // money per 1.0 price move
         int dir = plan.dir;
         double best = plan.entry, endpx = plan.entry;
         bool hit = false;
         int j = i0, last = std::min((int)m1.size() - 1, i0 + o.label_horizon_min);
         for(; j <= last; j++)
           {
            const M1 &x = m1[j];
            if((long long)x.t - (long long)m.t > (long long)o.label_horizon_min * 60)
               break;
            double lo = dir == RB_DIR_BULL ? x.bl : x.al, hi = dir == RB_DIR_BULL ? x.bh : x.ah;
            double op = dir == RB_DIR_BULL ? x.bo : x.ao;
            if(dir == RB_DIR_BULL ? lo <= plan.sl : hi >= plan.sl)
              {
               double base = dir == RB_DIR_BULL ? std::min(plan.sl, op) : std::max(plan.sl, op);
               endpx = base - dir * o.slip_ticks * spec.tick_size;
               hit = true;
               break;
              }
            best = dir == RB_DIR_BULL ? std::max(best, hi) : std::min(best, lo);
            endpx = dir == RB_DIR_BULL ? x.bc : x.ac;
           }
         int jj = std::min(j, (int)m1.size() - 1);
         double comm = o.commission * lots;
         double mfe_r = dir * (best - plan.entry) / plan.risk_dist;
         double end_r = (dir * (endpx - plan.entry) * per_px - comm) / rm;
         double cost_r = comm / rm;
         // ---- RETEST entry: limit at the broken level, 8 bars, same SL ----
         double lvl_raw = g.with_trend ? g.line_at_break : g.b_price;
         double lvl = dir == RB_DIR_BULL ? RB_RoundDownToTick(lvl_raw, spec.tick_size) : RB_RoundUpToTick(lvl_raw, spec.tick_size);
         int rt_filled = 0;
         double rt_pre = 0, rt_risk = dir * (lvl - plan.sl), rt_q = 0, rt_cost = 0, rt_mfe = 0, rt_end = 0;
         if(rt_risk > 2 * spread && rt_risk > spec.tick_size && dir * (live - lvl) > 0)
           {
            double rlpl = RB_LossPerLot(rt_risk, spec, o.commission, o.slip_ticks);
            double rlots = 0;
            if(RB_CalcLots(o.balance * o.lim.risk_pct, rlpl, spec, o.max_lots, rlots) == 0)
              {
               double rrm = rlots * rlpl;
               double rper = rlots / spec.tick_size * spec.tick_value_loss;
               rt_q = rt_risk * rper / rrm;
               rt_cost = o.commission * rlots / rrm;
               int jend = std::min((int)m15_first.size() - 1, k + 1 + o.expiry_bars);
               double pre = lvl;
               int jf = -1;
               for(int q = i0; q < m15_first[jend]; q++)
                 {
                  const M1 &x = m1[q];
                  bool fill = dir == RB_DIR_BULL ? x.al <= lvl : x.bh >= lvl;
                  if(fill) { jf = q; break; }
                  pre = dir == RB_DIR_BULL ? std::max(pre, x.bh) : std::min(pre, x.al);
                 }
               rt_pre = dir * (pre - lvl) / rt_risk;
               if(jf >= 0)
                 {
                  rt_filled = 1;
                  double bst = lvl, ep = lvl;
                  bool rh = false;
                  int lst = std::min((int)m1.size() - 1, jf + o.label_horizon_min);
                  for(int q = jf; q <= lst; q++)
                    {
                     const M1 &x = m1[q];
                     if((long long)x.t - (long long)m1[jf].t > (long long)o.label_horizon_min * 60)
                        break;
                     double lo2 = dir == RB_DIR_BULL ? x.bl : x.al, hi2 = dir == RB_DIR_BULL ? x.bh : x.ah;
                     double op2 = dir == RB_DIR_BULL ? x.bo : x.ao;
                     if(dir == RB_DIR_BULL ? lo2 <= plan.sl : hi2 >= plan.sl)
                       {
                        double base = q == jf ? plan.sl : (dir == RB_DIR_BULL ? std::min(plan.sl, op2) : std::max(plan.sl, op2));
                        ep = base - dir * o.slip_ticks * spec.tick_size;
                        rh = true;
                        break;
                       }
                     if(q > jf)   // the fill minute's extreme may have come before the fill
                        bst = dir == RB_DIR_BULL ? std::max(bst, hi2) : std::min(bst, lo2);
                     ep = dir == RB_DIR_BULL ? x.bc : x.ac;
                    }
                  (void)rh;
                  rt_mfe = dir * (bst - lvl) / rt_risk;
                  rt_end = (dir * (ep - lvl) * rper - o.commission * rlots) / rrm;
                 }
              }
           }
         int c_d1 = htf_slope(d1, 86400, e_d1_50, k, dir);
         int c_h4 = htf_slope(h4, 4 * 3600, e_h4_50, k, dir);
         int c_h1 = htf_side(h1, 3600, e_h1_200, k, dir);
         const RBRegime &rg = dregs[i];
         double body = std::fabs(m15.C(k) - m15.O(k));
         double level = g.with_trend ? g.line_at_break : g.b_price;
         double beyond = dir * (m15.C(k) - level);
         double atr = g.atr > 0 ? g.atr : 1e-9;
         std::fprintf(f, "%s;%s;%d;%d;%d;%s;%.2f;%.2f;%.2f;%.3f;%.3f;%.3f;%.3f;%.3f;%d;%d;%d;%d;%.3f;%.3f;%d;%d;%.2f;"
                         "%.2f;%.2f;%.4f;%d;%d;%.4f;%.4f;%d;%d;%d;%d;%.4f;%.3f;%.4f;%.4f;%.4f;%.4f\n",
                      fmt_time(m15.Time(k)).c_str(), fmt_time(m.t).c_str(), dir, g.with_trend ? 1 : 0, g.main_trend,
                      RB_DtbsSlModeText(used).c_str(), plan.entry, plan.sl, plan.risk_dist, g.atr, plan.risk_dist / atr,
                      std::fabs(g.b_price - g.a_price) / atr, body / atr, beyond / atr, k - g.b_idx, g.b_idx - g.a_idx,
                      hr, wd, rg.vol_ratio, rg.er, rg.valid ? rg.vol_class : -1, rg.ranging ? 1 : 0, spread,
                      lots, rm, cost_r, hit ? 1 : 0, (int)((m1[jj].t - m.t) / 60), mfe_r, end_r, c_d1, c_h4, c_h1,
                      rt_filled, rt_pre, rt_risk, rt_q, rt_cost, rt_mfe, rt_end);
        }
      std::fclose(f);
     }

   // DTBS: market order at the first minute of the bar after the break bar
   void on_dtbs_signal(size_t idx, int k)
     {
      const RBDtbsSignal &g = dsigs[idx];
      n_signals++;
      if(k + 1 >= m15.Size() || (long long)m15.Time(k + 1) != (long long)m15.Time(k) + 900)
        {
         reject("DATA_STALE");
         return;
        }
      const M1 &m = m1[m15_first[k + 1]];
      new_day_if_needed(m);
      RBRegimeDecision rd;
      RB_RegimeDecide(dregs[idx], o.reg, o.dcfg.rr, rd);
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
      if(o.dcfg.ctx_filter &&
         (RB_DtbsSlopeAgree(d1, 86400, ctx_d1, m15.Time(k), 900, o.dcfg.ctx_slope_bars, g.dir) != 1 ||
          RB_DtbsSlopeAgree(h4, 4 * 3600, ctx_h4, m15.Time(k), 900, o.dcfg.ctx_slope_bars, g.dir) != 1))
        {
         reject("CTX_FILTER");
         return;
        }
      double spread = m.ao - m.bo;
      double live = g.dir == RB_DIR_BULL ? m.ao : m.bo;
      RBPlan plan;
      int used = -1;
      int r = RB_DtbsBuildPlanEx(g, o.dcfg, spec, live, spread, plan, used);
      if(r != 0)
        {
         reject(RB_DtbsReasonText(r));
         return;
        }
      r = RB_DtbsCheckMarket(plan, spec, m.bo, m.ao, o.min_stop_spread_mult);
      if(r != 0)
        {
         reject(RB_DtbsReasonText(r));
         return;
        }
      const M1 &prev = m1[m15_first[k + 1] - 1];
      double eq = balance + floating(prev, false);
      double ref = std::min(balance, eq);
      std::string scale_why;
      double pct = RB_ProfitScaledPct(o.scale, start_balance, balance, hwm, ref, consec_losses, scale_why);
      double risk_money = RB_FinalRiskMoney(pct, ref, rd.risk_mult, 1.0, o.scale.max_pct);
      double lpl = RB_LossPerLot(plan.risk_dist, spec, o.commission, o.slip_ticks);
      double lots = 0;
      r = RB_CalcLots(risk_money, lpl, spec, o.max_lots, lots);
      if(r != 0)
        {
         reject(RB_ReasonText(r));
         return;
        }
      double trade_risk = lots * lpl;
      int gd = RB_CheckNewOrder(o.lim, snapshot(prev), trade_risk);
      if(gd != 0)
        {
         reject(std::string("GUARD_") + RB_GuardText(gd));
         return;
        }
      Pending p;
      p.sid = 2;
      p.ds = g;
      p.used_mode = used;
      p.plan = plan;
      p.lots = lots;
      p.risk_money = trade_risk;
      p.pct = pct;
      p.regime_mult = rd.risk_mult;
      p.rr = o.dcfg.rr;
      p.scale_why = scale_why;
      p.s.reg = dregs[idx];
      const RBRegime &rg = dregs[idx];
      RB_MakeFeatures(g.dir, -1, rg.valid ? rg.vol_class : RB_VOL_NORMAL, rg.ranging, hr, p.feat);   // as the EA
      p.placed = m.t;
      n_orders++;
      pos = Position();
      pos.active = true;
      pos.p = p;
      pos.lots = lots;
      pos.sl = plan.sl;
      pos.fill = plan.entry;
      pos.best = pos.worst = pos.fill;
      pos.open_time = m.t;
      trades_today++;
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
      if(o.strategy == 2)
         scan_dtbs();
      else
         scan_signals();
      if(o.strategy == 2 && !o.label_out.empty())
        {
         write_labels(from, to);
         std::printf("labels written: %s (%zu DTBS signals in the data)\n", o.label_out.c_str(), dsigs.size());
         return;
        }

      balance = start_balance = hwm = o.balance;
      min_equity_ever = balance;
      firm_peak_eq = balance;
      o.lim.initial_balance = o.balance;
      o.lim.peak_equity = o.balance;
      ft = std::fopen(o.out_trades.c_str(), "w");
      fd = std::fopen(o.out_daily.c_str(), "w");
      std::fprintf(ft, "open_time;close_time;dir;planned_entry;fill_price;sl;tp;volume;risk_money;net;r;signal_id;"
                       "atr;zone_type;rr;stop_mode;exit_price;regime;vol_ratio;er;risk_mult;"
                       "exit_reason;mfe_r;mae_r;session;hour;weekday;zones_hit;wick_ratio;rb_range_atr;stop_atr;"
                       "fill_delay_bars;risk_pct;edge_mult;scale_reason;strategy;dtbs_break;dtbs_sl_mode\n");
      std::fprintf(fd, "date;day_ref;start_balance;min_equity;end_balance;fills\n");

      size_t si = 0, di = 0;
      int nb = m15.Size();
      for(int k = 0; k < nb; k++)
        {
         for(int i = m15_first[k]; i < m15_first[k + 1]; i++)
           {
            const M1 &m = m1[i];
            if(m.t < from)
               continue;
            new_day_if_needed(m);
            apply_swap(m);
            process_minute(m);
            track_equity(m);
           }
         if((long long)m15.Time(k) < from)
           {
            while(si < sigs.size() && sigs[si].sig.confirm_idx <= k)
               si++;
            while(di < dsigs.size() && dsigs[di].break_idx <= k)
               di++;
            continue;
           }
         on_bar_close(k);
         while(di < dsigs.size() && dsigs[di].break_idx < k)
            di++;
         while(di < dsigs.size() && dsigs[di].break_idx == k)
           {
            on_dtbs_signal(di, k);
            di++;
           }
         while(si < sigs.size() && sigs[si].sig.confirm_idx < k)
            si++;
         while(si < sigs.size() && sigs[si].sig.confirm_idx == k)
           {
            on_signal(sigs[si], k);
            si++;
           }
        }
      if(pend.active)
        {
         pend.active = false;
         reject("PENDING_AT_END");
        }
      if(pos.active && o.end_close)
        {
         const M1 &e = m1.back();
         close_portion(pos.lots, pos.p.plan.dir == RB_DIR_BULL ? e.bc : e.ac, "END", e.t);
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
      s << "strategy " << (o.strategy == 2 ? "DTBS" : "RBOTE");
      if(o.strategy == 2)
         s << " | triangles " << n_tri << " | dtbs signals (whole data) " << dsigs.size();
      s << "\n";
      s << "signals " << n_signals << " | orders " << n_orders << " | closed trades " << n_trades << "\n";
      s << "final balance " << balance << " | net " << balance - o.balance << " | lowest equity " << min_equity_ever << "\n";
      s << "days breaching personal daily " << o.lim.daily_loss_pct * 100 << "%: " << n_personal_daily
        << " | firm daily " << o.firm_daily_pct * 100 << "%" << (o.firm_daily_on_initial ? " of initial" : " of day ref")
        << ": " << n_firm_daily << " | firm max loss " << o.firm_max_dd_pct * 100 << "% "
        << (o.firm_dd_trailing ? "(equity-peak shield)" : "(static)") << " breached: "
        << (firm_dd_breached ? "YES at " + fmt_time(firm_dd_breach_time) : std::string("no")) << "\n";
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
       "  --swap-long -40 --swap-short 15 ($/lot/night, x3 Wednesday) --end-close on|off --daily-on-initial on|off\n"
       "  --firm-daily 3 --firm-daily-initial on|off --firm-max 6 --firm-dd-trailing on|off   (reported only)\n"
       "  --rr 6 --fib 0.79 --stop fixed|structural|atr --stop-atr 2 --stop-dist 10 --stop-unit price|points|ticks --buffer 0.30 --max-stop-atr 3 --min-stop-atr 0\n"
       "  --wick 0.5 --close-rule body|close --confirm rb|next --zone-age 192\n"
       "  --regime neutral|policy|off   --adaptive on|off\n"
       "  --be-r X --be-offset-r Y --trail-start-r X --trail-r Y --partial-r X --partial-frac F\n"
       "  --strategy rbote|dtbs   DTBS: --dt-rr 1.5 --dt-ext 20 --dt-dirs both|with --dt-confirm close|wick\n"
       "     --dt-sl adaptive|break_start|break_candle|extreme|atr --dt-buffer 0.30 --dt-sl-atr 1.5\n"
       "     --dt-min-stop-atr 0.5 --dt-max-stop-atr 3 --dt-htf all|majority --dt-swing 2 --dt-htf-swing 2\n"
       "     --dt-leg-atr 1.0 --dt-max-leg 200 --htf-offset 2 --dt-ctx on|off\n"
       "     --label-out FILE [--label-horizon 14400]  one independent outcome row per DTBS signal, then exit");
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
   o.dcfg.Defaults();
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
      else if(a == "--risk")
        {
         o.lim.risk_pct = num() / 100.0;
         o.scale.base_pct = o.lim.risk_pct;
         o.scale.max_pct = std::max(o.scale.max_pct, o.lim.risk_pct);   // never silently cap the base risk
        }
      else if(a == "--swap-long") o.swap_long = num();
      else if(a == "--swap-short") o.swap_short = num();
      else if(a == "--swap-hour") o.swap_hour = (int)num();
      else if(a == "--end-close") o.end_close = next() == "on";
      else if(a == "--daily-on-initial") o.lim.daily_on_initial = next() == "on";
      else if(a == "--firm-daily") o.firm_daily_pct = num() / 100.0;
      else if(a == "--firm-daily-initial") o.firm_daily_on_initial = next() == "on";
      else if(a == "--firm-max") o.firm_max_dd_pct = num() / 100.0;
      else if(a == "--firm-dd-trailing") o.firm_dd_trailing = next() == "on";
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
      else if(a == "--stop")
        {
         std::string m = next();
         o.cfg.stop_mode = m == "structural" ? RB_STOP_STRUCTURAL : m == "atr" ? RB_STOP_ATR : RB_STOP_FIXED;
        }
      else if(a == "--stop-atr") o.cfg.stop_atr_mult = num();
      else if(a == "--stop-dist") o.cfg.stop_distance = num();
      else if(a == "--stop-unit")
        {
         std::string u = next();
         o.cfg.stop_unit = u == "points" ? RB_UNIT_POINTS : u == "ticks" ? RB_UNIT_TICKS : RB_UNIT_PRICE;
        }
      else if(a == "--buffer") o.cfg.structural_buffer = num();
      else if(a == "--max-stop-atr") o.cfg.max_stop_atr = num();
      else if(a == "--min-stop-atr") o.cfg.min_stop_atr = num();
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
      else if(a == "--strategy") o.strategy = next() == "dtbs" ? 2 : 1;
      else if(a == "--dt-rr") o.dcfg.rr = num();
      else if(a == "--dt-ext") o.dcfg.ext_bars = (int)num();
      else if(a == "--dt-dirs") o.dcfg.break_dirs = next() == "with" ? RB_DTBS_WITH_TREND_ONLY : RB_DTBS_BOTH;
      else if(a == "--dt-confirm") o.dcfg.confirm = next() == "wick" ? RB_DTBS_CONFIRM_WICK : RB_DTBS_CONFIRM_CLOSE;
      else if(a == "--dt-sl")
        {
         std::string v = next();
         o.dcfg.sl_mode = v == "break_candle" ? RB_DTBS_SL_BREAK_CANDLE : v == "extreme" ? RB_DTBS_SL_EXTREME :
                          v == "atr" ? RB_DTBS_SL_ATR : v == "break_start" ? RB_DTBS_SL_BREAK_START : RB_DTBS_SL_ADAPTIVE;
        }
      else if(a == "--dt-buffer") o.dcfg.sl_buffer_price = num();
      else if(a == "--dt-sl-atr") o.dcfg.sl_atr_mult = num();
      else if(a == "--dt-min-stop-atr") o.dcfg.min_stop_atr = num();
      else if(a == "--dt-max-stop-atr") o.dcfg.max_stop_atr = num();
      else if(a == "--dt-htf") o.dcfg.htf_agreement = next() == "majority" ? RB_DTBS_HTF_MAJORITY : RB_DTBS_HTF_ALL;
      else if(a == "--dt-swing") o.dcfg.swing_n = (int)num();
      else if(a == "--dt-htf-swing") o.dcfg.htf_swing_n = (int)num();
      else if(a == "--dt-leg-atr") o.dcfg.min_leg_atr = num();
      else if(a == "--dt-max-leg") o.dcfg.max_leg_bars = (int)num();
      else if(a == "--htf-offset") o.htf_offset_h = (int)num();
      else if(a == "--label-out") o.label_out = next();
      else if(a == "--dt-ctx") o.dcfg.ctx_filter = next() == "on";
      else if(a == "--label-horizon") o.label_horizon_min = (int)num();
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
