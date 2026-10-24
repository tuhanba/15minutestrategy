//+------------------------------------------------------------------+
//| Journal.mqh - timestamped decision log + closed-trade CSV (MQL5) |
//+------------------------------------------------------------------+
#ifndef RBOTE_JOURNAL_MQH
#define RBOTE_JOURNAL_MQH

#include "Adaptive.mqh"

//--- everything known about a closed trade: setup, conditions, sizing, outcome
struct RBTradeRow
  {
   datetime open_time;
   datetime close_time;
   datetime signal_time;
   int      dir;
   double   planned_entry;
   double   fill_price;
   double   sl;
   double   tp;
   double   volume;
   double   risk_money;
   double   net;
   double   r;
   string   signal_id;
   double   atr;
   int      zone_type;
   double   rr;
   int      stop_mode;
   double   exit_price;
   int      vol_class;
   bool     ranging;
   double   vol_ratio;
   double   er;
   double   risk_mult;
   string   exit_reason;
   double   mfe_r;
   double   mae_r;
   int      zones_hit;
   double   wick_ratio;
   double   rb_range_atr;
   double   stop_atr;
   int      fill_delay_bars;
   double   risk_pct;
   double   edge_mult;
   string   scale_reason;
  };

class CRBJournal
  {
private:
   string            m_journal_file;
   string            m_trades_file;
   int               m_flags;
   bool              m_enabled;

   int               OpenAppend(const string name, const string header)
     {
      int h = FileOpen(name, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | m_flags, ';');
      if(h == INVALID_HANDLE)
         return INVALID_HANDLE;
      if(FileSize(h) == 0)
         FileWrite(h, header);
      FileSeek(h, 0, SEEK_END);
      return h;
     }

public:
                     CRBJournal(void) { m_enabled = false; m_flags = 0; }

   //--- tester runs write to the COMMON folder so results survive the agent sandbox
   void              Init(bool enabled, long magic)
     {
      m_enabled = enabled;
      bool tester = (bool)MQLInfoInteger(MQL_TESTER);
      m_flags = tester ? FILE_COMMON : 0;
      string base = "RBOTE\\" + (tester ? "tester_" : "") + _Symbol + "_" + IntegerToString(magic);
      if(tester)
        {
         MqlDateTime dt;
         TimeToStruct(TimeLocal(), dt);
         base += StringFormat("_%04d%02d%02d_%02d%02d%02d", dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
        }
      else
         base += "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
      m_journal_file = base + "_journal.csv";
      m_trades_file  = base + "_trades.csv";
     }

   string            TradesFile(void) const { return m_trades_file; }

   //--- every decision: server time, GMT, event, signal id, details, reason
   void              Log(const string event, const string signal_id, const string details, const string reason)
     {
      PrintFormat("[RBOTE] %s %s | %s | %s", event, signal_id, details, reason);
      if(!m_enabled)
         return;
      int h = OpenAppend(m_journal_file, "server_time;gmt_time;event;signal_id;details;reason");
      if(h == INVALID_HANDLE)
        {
         PrintFormat("[RBOTE] journal open failed: %d", GetLastError());
         return;
        }
      FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                TimeToString(TimeGMT(), TIME_DATE | TIME_SECONDS), event, signal_id, details, reason);
      FileClose(h);
     }

   //--- one row per closed position (input for tools/analyze_trades.py)
   void              Trade(const RBTradeRow &t)
     {
      if(!m_enabled)
         return;
      int h = OpenAppend(m_trades_file,
                         (string)"open_time;close_time;dir;planned_entry;fill_price;sl;tp;volume;risk_money;net;r;signal_id;" +
                         "atr;zone_type;rr;stop_mode;exit_price;regime;vol_ratio;er;risk_mult;" +
                         "exit_reason;mfe_r;mae_r;session;hour;weekday;zones_hit;wick_ratio;rb_range_atr;stop_atr;" +
                         "fill_delay_bars;risk_pct;edge_mult;scale_reason");
      if(h == INVALID_HANDLE)
         return;
      MqlDateTime dt;
      TimeToStruct(t.signal_time, dt);
      FileWrite(h, TimeToString(t.open_time, TIME_DATE | TIME_MINUTES),
                TimeToString(t.close_time, TIME_DATE | TIME_MINUTES),
                t.dir, DoubleToString(t.planned_entry, _Digits), DoubleToString(t.fill_price, _Digits),
                DoubleToString(t.sl, _Digits), DoubleToString(t.tp, _Digits), DoubleToString(t.volume, 2),
                DoubleToString(t.risk_money, 2), DoubleToString(t.net, 2), DoubleToString(t.r, 4),
                t.signal_id, DoubleToString(t.atr, _Digits), t.zone_type, DoubleToString(t.rr, 2), t.stop_mode,
                DoubleToString(t.exit_price, _Digits),
                (t.vol_class < 0 ? (string)"UNKNOWN" : RB_VolText(t.vol_class)) + (t.ranging ? "+RANGE" : ""),
                DoubleToString(t.vol_ratio, 3), DoubleToString(t.er, 3), DoubleToString(t.risk_mult, 2),
                t.exit_reason, DoubleToString(t.mfe_r, 2), DoubleToString(t.mae_r, 2),
                RB_SessionText(RB_SessionBucket(dt.hour)), dt.hour, dt.day_of_week, t.zones_hit,
                DoubleToString(t.wick_ratio, 3), DoubleToString(t.rb_range_atr, 3), DoubleToString(t.stop_atr, 3),
                t.fill_delay_bars, DoubleToString(t.risk_pct * 100.0, 3), DoubleToString(t.edge_mult, 3),
                t.scale_reason);
      FileClose(h);
     }
  };

#endif
