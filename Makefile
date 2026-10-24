CXX ?= g++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -O1 -x c++

.PHONY: test analyze-test bt data research clean

test: build/run_tests
	./build/run_tests

build/run_tests: tests/cpp/run_tests.cpp $(wildcard MQL5/Include/RBOTE/*.mqh MQL5/Include/RBOTE/Tests/*.mqh)
	mkdir -p build
	$(CXX) $(CXXFLAGS) tests/cpp/run_tests.cpp -o $@

analyze-test: bt
	python3 -m pytest -q tools/tests

bt: build/rbote_bt

build/rbote_bt: backtest/rbote_bt.cpp $(wildcard MQL5/Include/RBOTE/*.mqh)
	mkdir -p build
	$(CXX) -std=c++17 -O2 -Wall -Wextra -Werror -x c++ backtest/rbote_bt.cpp -o $@

data:
	python3 tools/fetch_dukascopy.py --symbol XAUUSD --start 2020-01-01 --end $$(date -u -d yesterday +%F) --out data --cache data/cache --workers 16

research: bt
	python3 tools/run_research.py

clean:
	rm -rf build
