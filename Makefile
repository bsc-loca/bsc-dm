PROJECT_DIR = $(abspath .)

FILELIST = ${PROJECT_DIR}/filelist.f

VERILATOR = verilator

TOP_MODULE = tb_top

SIMULATOR = $(PROJECT_DIR)/sim

FLAGS ?=

VERI_FLAGS = \
	$(foreach flag, $(FLAGS), -D$(flag)) \
	-DVERILATOR_GCC \
	-F $(FILELIST) \
	--top-module $(TOP_MODULE) \
	--unroll-count 256 \
	-Wno-lint -Wno-style -Wno-STMTDLY -Wno-fatal \
	--binary --timing \
	--trace \
	--trace-max-array 512 \
	--trace-max-width 256 \
	--trace-structs \
	--trace-params \
	--trace-underscore \
	--assert \
	--unroll-stmts 100000 \
	--Mdir build

VERI_OPTI_FLAGS = -O2 -CFLAGS "-O2"

SIM_CPP_SRCS = $(wildcard ./SimJTAG/*.cc)
SIM_VERILOG_SRCS = $(shell cat $(FILELIST) | grep *.sv) $(wildcard ./rtl/*.sv)

$(SIMULATOR): $(SIM_CPP_SRCS) $(SIM_VERILOG_SRCS)
	mkdir -p build
	$(VERILATOR) --cc $(VERI_FLAGS) $(VERI_OPTI_FLAGS) -o $(SIMULATOR)

clean-simulator:
	rm -rf ./build $(SIMULATOR)

clean:: clean-simulator
