//+------------------------------------------------------------------+
//| Compat.mqh                                                       |
//| Lets the pure-logic headers compile both in MQL5 and in C++      |
//| (g++) so the same source can be unit-tested outside MetaTrader.  |
//| Under MQL5 this file is empty.                                   |
//+------------------------------------------------------------------+
#ifndef RBOTE_COMPAT_MQH
#define RBOTE_COMPAT_MQH

#ifndef __MQL5__
#include <cmath>
#include <cfloat>
#include <cstdio>
#include <string>
#include <vector>

typedef long long          datetime;
typedef unsigned long      ulong;   // 64-bit on LP64 (matches <sys/types.h>)
typedef unsigned int       uint;    // matches <sys/types.h>
typedef unsigned char      uchar;
typedef std::string        string;

inline double MathAbs(double x)             { return std::fabs(x); }
inline double MathMax(double a, double b)   { return a > b ? a : b; }
inline double MathMin(double a, double b)   { return a < b ? a : b; }
inline int    MathMax(int a, int b)         { return a > b ? a : b; }
inline int    MathMin(int a, int b)         { return a < b ? a : b; }
inline double MathFloor(double x)           { return std::floor(x); }
inline double MathCeil(double x)            { return std::ceil(x); }
inline double MathRound(double x)           { return std::round(x); }
inline double MathSqrt(double x)            { return std::sqrt(x); }
inline bool   MathIsValidNumber(double x)   { return std::isfinite(x); }

inline string IntegerToString(long long v)  { return std::to_string(v); }
inline int StringFind(const string &s, const string &sub, int start = 0)
  {
   std::string::size_type p = s.find(sub, (std::string::size_type)start);
   return p == std::string::npos ? -1 : (int)p;
  }
inline string DoubleToString(double v, int digits)
  {
   char buf[64];
   std::snprintf(buf, sizeof(buf), "%.*f", digits, v);
   return string(buf);
  }
#endif

#endif
