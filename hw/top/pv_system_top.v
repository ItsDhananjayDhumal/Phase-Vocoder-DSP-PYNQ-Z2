`timescale 1ns / 1ps
// ============================================================================
// pv_system_top: FPGA top level of the PYNQ-Z2 autotune overlay.
//
//   pv_autotune_wrapper (block design: PS7, AXI IIC, AXI DMA, interconnects)
//     PV_AXI     (AXI4-Lite @ 0x43C0_0000) --> pv_audio_top control registers
//     MM2S_AXIS  (DMA file stream)         --> pv_audio_top
//     S2MM_AXIS  (DMA capture)             <-- pv_audio_top
//   pv_audio_top <--> ADAU1761 I2S pins; AXI IIC <--> codec I2C pins
// ============================================================================
module pv_system_top (
    inout  wire [14:0] DDR_addr,
    inout  wire [2:0]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [3:0]  DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire [3:0]  DDR_dqs_n,
    inout  wire [3:0]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb,

    // ADAU1761
    output wire        au_mclk,
    input  wire        au_bclk,
    input  wire        au_lrclk,
    input  wire        au_sdata_i,
    output wire        au_sdata_o,
    output wire [1:0]  au_addr,
    inout  wire        iic_scl_io,
    inout  wire        iic_sda_io
);
    wire        clk, aresetn;

    wire [31:0] awaddr, araddr, wdata, rdata;
    wire [2:0]  awprot, arprot;
    wire [3:0]  wstrb;
    wire [1:0]  bresp, rresp;
    wire        awvalid, awready, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rvalid, rready;

    wire [31:0] mm2s_tdata, s2mm_tdata;
    wire [3:0]  mm2s_tkeep, s2mm_tkeep;
    wire        mm2s_tlast, mm2s_tvalid, mm2s_tready;
    wire        s2mm_tlast, s2mm_tvalid, s2mm_tready;

    pv_autotune_wrapper u_bd (
        .DDR_addr(DDR_addr), .DDR_ba(DDR_ba), .DDR_cas_n(DDR_cas_n), .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p), .DDR_cke(DDR_cke), .DDR_cs_n(DDR_cs_n), .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq), .DDR_dqs_n(DDR_dqs_n), .DDR_dqs_p(DDR_dqs_p), .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n), .DDR_reset_n(DDR_reset_n), .DDR_we_n(DDR_we_n),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn), .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio), .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb), .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),

        .PV_AXI_awaddr(awaddr), .PV_AXI_awprot(awprot), .PV_AXI_awvalid(awvalid), .PV_AXI_awready(awready),
        .PV_AXI_wdata(wdata), .PV_AXI_wstrb(wstrb), .PV_AXI_wvalid(wvalid), .PV_AXI_wready(wready),
        .PV_AXI_bresp(bresp), .PV_AXI_bvalid(bvalid), .PV_AXI_bready(bready),
        .PV_AXI_araddr(araddr), .PV_AXI_arprot(arprot), .PV_AXI_arvalid(arvalid), .PV_AXI_arready(arready),
        .PV_AXI_rdata(rdata), .PV_AXI_rresp(rresp), .PV_AXI_rvalid(rvalid), .PV_AXI_rready(rready),

        .MM2S_AXIS_tdata(mm2s_tdata), .MM2S_AXIS_tkeep(mm2s_tkeep), .MM2S_AXIS_tlast(mm2s_tlast),
        .MM2S_AXIS_tvalid(mm2s_tvalid), .MM2S_AXIS_tready(mm2s_tready),
        .S2MM_AXIS_tdata(s2mm_tdata), .S2MM_AXIS_tkeep(s2mm_tkeep), .S2MM_AXIS_tlast(s2mm_tlast),
        .S2MM_AXIS_tvalid(s2mm_tvalid), .S2MM_AXIS_tready(s2mm_tready),

        .iic_scl_io(iic_scl_io), .iic_sda_io(iic_sda_io),
        .pv_clk(clk), .pv_aresetn(aresetn)
    );

    pv_audio_top u_pv (
        .aclk(clk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr[13:0]), .s_axi_awprot(awprot), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr[13:0]), .s_axi_arprot(arprot), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_mm2s_tdata(mm2s_tdata), .s_axis_mm2s_tkeep(mm2s_tkeep), .s_axis_mm2s_tlast(mm2s_tlast),
        .s_axis_mm2s_tvalid(mm2s_tvalid), .s_axis_mm2s_tready(mm2s_tready),
        .m_axis_s2mm_tdata(s2mm_tdata), .m_axis_s2mm_tkeep(s2mm_tkeep), .m_axis_s2mm_tlast(s2mm_tlast),
        .m_axis_s2mm_tvalid(s2mm_tvalid), .m_axis_s2mm_tready(s2mm_tready),
        .au_mclk(au_mclk), .au_bclk(au_bclk), .au_lrclk(au_lrclk),
        .au_sdata_i(au_sdata_i), .au_sdata_o(au_sdata_o), .au_addr(au_addr)
    );
endmodule
