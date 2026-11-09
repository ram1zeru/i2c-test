IVERILOG ?= iverilog
VVP      ?= vvp
FLAGS    := -g2012 -Wall

I2C_SRC := rtl/i2c/i2c_maestro.v rtl/i2c/i2c_esclavo.v tb/tb_i2c.v
SPI_SRC := rtl/spi/spi_maestro.v rtl/spi/spi_esclavo.v tb/tb_spi.v
I2CF_SRC := rtl/i2c_full/i2c_master_byte.v rtl/i2c_full/i2c_slave_regs.v tb/tb_i2c_full.v

.PHONY: all test i2c spi i2c_full waves clean

all: test

test: i2c spi i2c_full

build:
	mkdir -p build

i2c: build
	$(IVERILOG) $(FLAGS) -o build/tb_i2c.vvp $(I2C_SRC)
	$(VVP) -n build/tb_i2c.vvp | tee build/i2c.log
	@grep -q "I2C TEST PASSED" build/i2c.log

spi: build
	$(IVERILOG) $(FLAGS) -o build/tb_spi.vvp $(SPI_SRC)
	$(VVP) -n build/tb_spi.vvp | tee build/spi.log
	@grep -q "SPI TEST PASSED" build/spi.log

i2c_full: build
	$(IVERILOG) $(FLAGS) -o build/tb_i2c_full.vvp $(I2CF_SRC)
	$(VVP) -n build/tb_i2c_full.vvp | tee build/i2c_full.log
	@grep -q "I2C FULL TEST PASSED" build/i2c_full.log

# Render waveform PNGs (like the figures in the paper) from the VCD files
waves: test
	python3 scripts/plot_waves.py

clean:
	rm -rf build
