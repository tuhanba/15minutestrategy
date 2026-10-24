// Runs the shared MQL5 unit tests (MQL5/Include/RBOTE/Tests/TestCases.mqh) with g++.
// The pure-logic headers compile unchanged in C++ through Compat.mqh.
#include "../../MQL5/Include/RBOTE/Tests/TestCases.mqh"

int main()
{
   CRBTest t;
   RB_RunAllTests(t);
   return t.failed == 0 ? 0 : 1;
}
