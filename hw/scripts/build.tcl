# =============================================================================
# Builds the PYNQ-Z2 phase-vocoder overlay from scratch.
#
#   cd hw
#   vivado -mode batch -source scripts/build.tcl            (all stages, about 15-25 minutes)
#   vivado -mode batch -source scripts/build.tcl -tclargs core|bd|synth|impl   (one stage at a time)
#
# Stages: core  = synthesise pv_audio_top on its own -> vivado_build_core/pv_audio_top.dcp
#         bd    = create project + block design (uses that checkpoint for the core)
#         synth = synthesise the block design and top level
#         impl  = place, route, bitstream, copy .bit/.hwh to sw/overlay
# Why the core is pre-synthesised: Vivado 2023.2 on the development PC crashed
# (EXCEPTION_ACCESS_VIOLATION) whenever this RTL was synthesised with a clock
# constraint applied. Synthesising it unconstrained and placing/routing it with
# constraints works and meets timing.
#
# Output: sw/overlay/pv_autotune.bit + pv_autotune.hwh (copy that folder to the board)
#
# Block design:
#   PS7 (FCLK0 = 100 MHz, M_AXI_GP0, S_AXI_HP0)
#    +-- GP0 -> SmartConnect -> pv_audio_top (0x43C0_0000, control + tables)
#    |                       -> axi_iic       (0x4160_0000, ADAU1761 I2C on U9/T9)
#    |                       -> axi_dma       (0x4040_0000, file playback / capture)
#    +-- HP0 <- SmartConnect <- axi_dma MM2S + S2MM
# =============================================================================
set script_dir [file dirname [file normalize [info script]]]
set hw_dir     [file normalize "$script_dir/.."]
set root_dir   [file normalize "$hw_dir/.."]
set proj_dir   "$hw_dir/vivado_build"
set out_dir    "$root_dir/sw/overlay"
set bd_name    pv_autotune
set part       xc7z020clg400-1
set jobs       [expr {[info exists ::env(JOBS)] ? $::env(JOBS) : 6}]

set stage [expr {$argc > 0 ? [lindex $argv 0] : "all"}]
set_param general.maxThreads 1

proc harden_project {} {
    # Vivado 2023.2 crashed in the IP-cache thread pool and in multithreaded
    # synthesis on this host: no IP cache, single-threaded steps.
    config_ip_cache -disable_cache
    set hook [file normalize [file join $::script_dir single_thread.tcl]]
    foreach r [get_runs] {
        if {[get_property IS_SYNTHESIS $r]} {
            set_property STEPS.SYNTH_DESIGN.TCL.PRE $hook $r
        } else {
            foreach st {OPT_DESIGN PLACE_DESIGN ROUTE_DESIGN WRITE_BITSTREAM} {
                set_property STEPS.$st.TCL.PRE $hook $r
            }
        }
    }
}

proc run_synth {} {
    reset_run synth_1
    launch_runs synth_1 -jobs 1
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { error "synthesis failed" }
}

proc run_impl {} {
    global proj_dir out_dir bd_name
    launch_runs impl_1 -to_step write_bitstream -jobs 1
    wait_on_run impl_1
    if {[get_property PROGRESS [get_runs impl_1]] != "100%"} { error "implementation failed" }
    open_run impl_1
    report_utilization -file $proj_dir/utilization.rpt
    report_timing_summary -file $proj_dir/timing.rpt
    puts "WNS = [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] ns"
    file mkdir $out_dir
    file copy -force [glob $proj_dir/pv_autotune.runs/impl_1/pv_system_top.bit] $out_dir/pv_autotune.bit
    file copy -force [glob $proj_dir/pv_autotune.gen/sources_1/bd/$bd_name/hw_handoff/$bd_name.hwh] $out_dir/pv_autotune.hwh
    puts "Overlay written to $out_dir (pv_autotune.bit / pv_autotune.hwh)"
}

proc run_core {} {
    global hw_dir
    set d $hw_dir/vivado_build_core
    file mkdir $d
    read_verilog [list $hw_dir/rtl/pv_atan.vh]
    set_property file_type {Verilog Header} [get_files pv_atan.vh]
    read_mem [glob $hw_dir/mem/*.mem]
    read_verilog [glob $hw_dir/rtl/*.v]
    synth_design -top pv_audio_top -part $::part -mode out_of_context -include_dirs [list $hw_dir/rtl]
    write_checkpoint -force $d/pv_audio_top.dcp
    report_utilization -file $d/utilization.rpt
    close_design
    puts "core checkpoint written to $d/pv_audio_top.dcp"
}

if {$stage eq "core" || $stage eq "all"} {
    run_core
    if {$stage eq "core"} { return }
}

if {$stage eq "synth" || $stage eq "impl"} {
    open_project $proj_dir/pv_autotune.xpr
    harden_project
    if {$stage eq "synth"} { run_synth } else { run_impl }
    return
}

file delete -force $proj_dir
create_project pv_autotune $proj_dir -part $part
set_property target_language Verilog [current_project]

# ---------------------------------------------------------------- sources
add_files [list $hw_dir/vivado_build_core/pv_audio_top.dcp]
add_files -fileset constrs_1 [list $hw_dir/constraints/pynq_z2_audio.xdc]
# pin/false-path constraints are only needed for implementation
set_property used_in_synthesis false [get_files pynq_z2_audio.xdc]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------- block design
# Vivado 2023.2 on this host sometimes fails to read its own rule scripts the first
# time the block-design engine initialises; retrying succeeds once they are cached.
set bd_ok 0
for {set attempt 1} {$attempt <= 6 && !$bd_ok} {incr attempt} {
    if {[catch {create_bd_design $bd_name} err]} {
        puts "create_bd_design attempt $attempt failed: $err"
        catch {close_bd_design [get_bd_designs $bd_name]}
        catch {remove_files [get_files -quiet $bd_name.bd]}
        file delete -force $proj_dir/pv_autotune.srcs/sources_1/bd/$bd_name
        after 2000
    } else {
        set bd_ok 1
    }
}
if {!$bd_ok} { error "could not create the block design" }

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
] $ps
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "0"} $ps

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_100m]

# The phase-vocoder core (pv_audio_top) sits outside the block design in
# hw/top/pv_system_top.v. (Vivado 2023.2 crashed synthesising it as a BD module
# reference; as plain RTL it synthesises fine.) The BD exports its AXI-Lite
# control port and both DMA streams.
set pv_axi [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 PV_AXI]
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32}     CONFIG.FREQ_HZ {100000000} CONFIG.HAS_PROT {1}] $pv_axi
set mm2s [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 MM2S_AXIS]
set_property -dict [list CONFIG.FREQ_HZ {100000000}] $mm2s
set s2mm [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 S2MM_AXIS]
set_property -dict [list CONFIG.FREQ_HZ {100000000} CONFIG.TDATA_NUM_BYTES {4} CONFIG.HAS_TLAST {1}     CONFIG.HAS_TKEEP {1} CONFIG.HAS_TREADY {1}] $s2mm
create_bd_port -dir O -type clk pv_clk
set_property CONFIG.ASSOCIATED_BUSIF {PV_AXI:MM2S_AXIS:S2MM_AXIS} [get_bd_ports pv_clk]
set_property CONFIG.FREQ_HZ {100000000} [get_bd_ports pv_clk]
create_bd_port -dir O -type rst pv_aresetn

set iic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_0]
set_property -dict [list CONFIG.IIC_FREQ_KHZ {100}] $iic

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_sg_length_width {26} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_m_axi_mm2s_data_width {32} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_mm2s_burst_size {16} \
    CONFIG.c_m_axi_s2mm_data_width {32} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
    CONFIG.c_s2mm_burst_size {16} \
    CONFIG.c_addr_width {32} \
] $dma

set sc_gp [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_gp0]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {3}] $sc_gp
set sc_hp [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 sc_hp0]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $sc_hp

# clocks and resets
set clk [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net $clk \
    [get_bd_pins ps7/M_AXI_GP0_ACLK] [get_bd_pins ps7/S_AXI_HP0_ACLK] \
    [get_bd_pins rst_100m/slowest_sync_clk] \
    [get_bd_ports pv_clk] \
    [get_bd_pins axi_iic_0/s_axi_aclk] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins sc_gp0/aclk] [get_bd_pins sc_hp0/aclk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_100m/ext_reset_in]
connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] \
    [get_bd_ports pv_aresetn] [get_bd_pins axi_iic_0/s_axi_aresetn] [get_bd_pins axi_dma_0/axi_resetn]
connect_bd_net [get_bd_pins rst_100m/interconnect_aresetn] [get_bd_pins sc_gp0/aresetn] [get_bd_pins sc_hp0/aresetn]

# AXI control path
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins sc_gp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_gp0/M00_AXI] [get_bd_intf_ports PV_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_gp0/M01_AXI] [get_bd_intf_pins axi_iic_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_gp0/M02_AXI] [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# DMA memory path
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins sc_hp0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins sc_hp0/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins sc_hp0/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]

# audio streams
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_ports MM2S_AXIS]
connect_bd_intf_net [get_bd_intf_ports S2MM_AXIS] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# external pins
make_bd_intf_pins_external [get_bd_intf_pins axi_iic_0/IIC]
set_property name iic [get_bd_intf_ports IIC_0]

# address map
assign_bd_address
set pv_seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data] -filter {NAME =~ *PV_AXI*}]
set_property offset 0x43C00000 $pv_seg
set_property range  16K        $pv_seg
set_property offset 0x41600000 [get_bd_addr_segs {ps7/Data/SEG_axi_iic_0_Reg}]
set_property offset 0x40400000 [get_bd_addr_segs {ps7/Data/SEG_axi_dma_0_Reg}]

validate_bd_design
regenerate_bd_layout
save_bd_design

# IPs are synthesised out-of-context (Vivado default); the .mem files are project
# sources, so $readmemh in the module reference resolves in either flow.
set bd_file [get_files $bd_name.bd]
generate_target all $bd_file
create_ip_run $bd_file
harden_project
make_wrapper -files $bd_file -top
add_files -norecurse [glob $proj_dir/pv_autotune.gen/sources_1/bd/$bd_name/hdl/${bd_name}_wrapper.v]
add_files -norecurse [list $hw_dir/top/pv_system_top.v]
set_property top pv_system_top [current_fileset]
update_compile_order -fileset sources_1

# ---------------------------------------------------------------- implementation
if {$stage eq "all"} {
    run_synth
    run_impl
}
