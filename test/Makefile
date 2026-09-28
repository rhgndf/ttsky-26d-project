# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = rv32i_core.v qspi_psram.v uart.v timer.v serial.v tt_um_rhgndf_rv32i_soc.v

# Firmware image loaded into the PSRAM model; HEX paths are relative to test/
HEX ?= fw/hello.hex
PLUSARGS += +HEX=$(HEX)
# SPI loopback (MOSI->MISO) opt-in: make SPI_LOOP=1
ifdef SPI_LOOP
PLUSARGS += +SPI_LOOP=1
endif

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v $(PWD)/psram_model.v $(PWD)/i2c_slave_model.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim

# Run every firmware image through its own sim (each test self-selects by +HEX)
FW_HEXS := $(sort $(wildcard fw/*.hex))
test-progs:
	@set -e; for h in $(FW_HEXS); do \
	  echo "=== HEX=$$h ==="; \
	  rm -f results.xml; \
	  $(MAKE) HEX=$$h results.xml >/dev/null 2>&1 && \
	    grep -q 'failures="0"' results.xml && echo "PASS $$h" || { echo "FAIL $$h"; exit 1; }; \
	done
