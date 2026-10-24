//+------------------------------------------------------------------+
//| RBOTE_Tests.mq5 - runs the shared unit tests inside MetaTrader 5 |
//| (same test cases as tests/cpp/run_tests.cpp).                    |
//| Drag onto any chart; results are printed to the Experts tab.     |
//+------------------------------------------------------------------+
#property script_show_inputs
#property version "1.00"

#include <RBOTE/Tests/TestCases.mqh>

void OnStart(void)
  {
   CRBTest t;
   RB_RunAllTests(t);
   if(t.failed == 0)
      Print("RBOTE tests: ALL PASSED");
   else
      Alert("RBOTE tests: ", t.failed, " FAILED - see Experts log");
  }
