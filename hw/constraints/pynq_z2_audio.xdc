## ============================================================================
## PYNQ-Z2 (xc7z020clg400-1): ADAU1761 audio codec pins
## Same pinout as the PYNQ-Z2 base overlay. The system clock and reset come
## from the Zynq PS (FCLK_CLK0 / FCLK_RESET0_N), so no clock pins are used.
## ============================================================================

## I2S (codec is the master: BCLK and LRCLK are inputs to the FPGA)
set_property -dict { PACKAGE_PIN U5  IOSTANDARD LVCMOS33 } [get_ports au_mclk];     # AU_MCLK  10 MHz to codec
set_property -dict { PACKAGE_PIN R18 IOSTANDARD LVCMOS33 } [get_ports au_bclk];     # AU_BCLK  from codec
set_property -dict { PACKAGE_PIN T17 IOSTANDARD LVCMOS33 } [get_ports au_lrclk];    # AU_WCLK  from codec
set_property -dict { PACKAGE_PIN F17 IOSTANDARD LVCMOS33 } [get_ports au_sdata_i];  # ADC data from codec
set_property -dict { PACKAGE_PIN G18 IOSTANDARD LVCMOS33 } [get_ports au_sdata_o];  # DAC data to codec

## Codec I2C control port (driven by the AXI IIC controller in the PL)
set_property -dict { PACKAGE_PIN U9  IOSTANDARD LVCMOS33 PULLUP true } [get_ports iic_scl_io];
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 PULLUP true } [get_ports iic_sda_io];

## Codec I2C address select pins: both high -> address 0x3B
set_property -dict { PACKAGE_PIN M17 IOSTANDARD LVCMOS33 } [get_ports {au_addr[0]}];
set_property -dict { PACKAGE_PIN M18 IOSTANDARD LVCMOS33 } [get_ports {au_addr[1]}];

## The I2S signals are asynchronous to FCLK_CLK0 and oversampled through
## synchronisers; the outputs are slow (<= 10 MHz).
set_false_path -from [get_ports {au_bclk au_lrclk au_sdata_i}]
set_false_path -to   [get_ports {au_sdata_o au_mclk au_addr[*]}]
