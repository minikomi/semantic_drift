CXX ?= c++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -pedantic
LDFLAGS ?=
LDLIBS ?= -lcurl

.PHONY: all clean

all: todo_report

todo_report: main.cpp
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ main.cpp $(LDLIBS)

clean:
	rm -f todo_report
