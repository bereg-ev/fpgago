# 6502 core conformance test — see opcode_test.py.
#
#   make            run the test (720 cases, ~15 s)
#   make verbose    ... and print every case
#
# Also reachable as `make check-cpu` from c64/sim-desktop.

OSS := $(abspath ../../../../oss-cad-suite/bin)
export PATH := $(OSS):$(PATH)

.PHONY: check verbose clean
check:
	python3 opcode_test.py

verbose:
	python3 opcode_test.py -v

clean:
	rm -rf build
