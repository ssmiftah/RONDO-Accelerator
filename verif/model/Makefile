# gcc builds: libfpm.so (ctypes cross-check) and dpi.so (xsim DPI; xsc's linker fails on this host, see TOOLCHAIN.md)
HERE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
OUT ?= $(HERE)/../../build/verif/model
XSIM_INC ?= /home/CAD/2025.2/Vivado/data/xsim/include
all: $(OUT)/libfpm.so $(OUT)/dpi.so
$(OUT)/libfpm.so: rondo_fpmodel.c rondo_fpmodel.h
	mkdir -p $(OUT); gcc -O2 -shared -fPIC -o $@ rondo_fpmodel.c
$(OUT)/dpi.so: rondo_fpmodel.c rondo_fpmodel.h
	mkdir -p $(OUT); gcc -O2 -shared -fPIC -I$(XSIM_INC) -o $@ rondo_fpmodel.c
