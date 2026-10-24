CXX ?= g++
CXXFLAGS ?= -std=c++17 -Wall -Wextra -Werror -O1 -x c++

.PHONY: test analyze-test clean

test: build/run_tests
	./build/run_tests

build/run_tests: tests/cpp/run_tests.cpp $(wildcard MQL5/Include/RBOTE/*.mqh MQL5/Include/RBOTE/Tests/*.mqh)
	mkdir -p build
	$(CXX) $(CXXFLAGS) tests/cpp/run_tests.cpp -o $@

analyze-test:
	python3 -m pytest -q tools/tests

clean:
	rm -rf build
