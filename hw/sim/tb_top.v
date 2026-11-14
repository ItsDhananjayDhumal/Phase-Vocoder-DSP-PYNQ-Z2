`timescale 1ns / 1ps
// Top-level test of pv_audio_top with:
//   * an ADAU1761 bus-functional model acting as I2S master (BCLK/LRCLK out,
//     ADC data from top_in.hex on both channels, DAC data decoded to dac.txt)
//   * an AXI4-Lite master for register access
//   * DMA models: MM2S source streaming dma_in.hex, S2MM sink -> cap.txt
// plusargs: +TEST=bypass|dsp|dma  +NS=<samples>
module tb_top;
    localparam BCLK_HALF = 80;                 // faster than real (162 ns) to keep sims short

    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---------------------------------------------------------------- AXI-Lite
    reg  [13:0] awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    reg  [31:0] wdata = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    // -------------------------------------------------------------------- DMA
    reg  [31:0] mm2s_tdata = 0;
    reg         mm2s_tvalid = 0;
    wire        mm2s_tready;
    wire [31:0] s2mm_tdata;
    wire        s2mm_tvalid, s2mm_tlast;
    wire [3:0]  s2mm_tkeep;
    reg         s2mm_tready = 1;

    // ------------------------------------------------------------------ codec
    reg  bclk = 0, lrclk = 0, adc_sd = 0;
    wire mclk, dac_sd;
    wire [1:0] au_addr;

    pv_audio_top dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_mm2s_tdata(mm2s_tdata), .s_axis_mm2s_tkeep(4'hF), .s_axis_mm2s_tlast(1'b0),
        .s_axis_mm2s_tvalid(mm2s_tvalid), .s_axis_mm2s_tready(mm2s_tready),
        .m_axis_s2mm_tdata(s2mm_tdata), .m_axis_s2mm_tkeep(s2mm_tkeep), .m_axis_s2mm_tlast(s2mm_tlast),
        .m_axis_s2mm_tvalid(s2mm_tvalid), .m_axis_s2mm_tready(s2mm_tready),
        .au_mclk(mclk), .au_bclk(bclk), .au_lrclk(lrclk), .au_sdata_i(adc_sd), .au_sdata_o(dac_sd),
        .au_addr(au_addr)
    );

    task axi_write(input [13:0] a, input [31:0] d);
        begin
            @(negedge aclk); awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
            @(posedge aclk); while (!(awready && wready)) @(posedge aclk);
            @(negedge aclk); awvalid = 0; wvalid = 0;
            while (!bvalid) @(posedge aclk);
        end
    endtask

    task axi_read(input [13:0] a, output [31:0] d);
        begin
            @(negedge aclk); araddr = a; arvalid = 1;
            @(posedge aclk); while (!arready) @(posedge aclk);
            @(negedge aclk); arvalid = 0;
            while (!rvalid) @(posedge aclk);
            d = rdata;
        end
    endtask

    // ------------------------------------------------------- codec BFM (I2S master)
    reg [15:0] xin [0:(1<<16)-1];
    integer    adc_idx = 0, dac_cnt = 0, fdac, ns;
    reg [5:0]  fc = 6'd63;
    reg [23:0] adc_word = 0;
    reg [23:0] dac_sh = 0;
    reg [23:0] dac_l = 0;

    always #(BCLK_HALF) bclk = ~bclk;

    // falling edge: advance slot position, drive LRCLK and ADC data
    always @(negedge bclk) begin
        fc = fc + 1;
        lrclk <= fc[5];
        if (fc[4:0] == 0) adc_word = {xin[adc_idx], 8'h00};          // same sample on L and R
        if (fc == 6'd63) adc_idx = adc_idx + 1;
        adc_sd <= (fc[4:0] >= 1 && fc[4:0] <= 24) ? adc_word[24 - fc[4:0]] : 1'b0;
    end

    // rising edge: sample DAC data
    always @(posedge bclk) begin
        if (fc[4:0] >= 1 && fc[4:0] <= 24) begin
            dac_sh = {dac_sh[22:0], dac_sd};
            if (fc[4:0] == 24) begin
                if (!fc[5]) dac_l = dac_sh;
                else begin
                    $fwrite(fdac, "%0d %0d\n", $signed(dac_l[23:8]), $signed(dac_sh[23:8]));
                    dac_cnt = dac_cnt + 1;
                end
            end
        end
    end

    // ------------------------------------------------------------- DMA models
    reg [15:0] din [0:(1<<16)-1];
    integer    dma_idx = 0, dma_len = 0, fcap, cap_n = 0, cap_last_at = -1;

    always @(posedge aclk) begin
        if (mm2s_tvalid && mm2s_tready) begin
            dma_idx = dma_idx + 1;
            if (dma_idx >= dma_len) mm2s_tvalid <= 0;
            else mm2s_tdata <= {{16{din[dma_idx][15]}}, din[dma_idx]};
        end
        if (s2mm_tvalid && s2mm_tready) begin
            $fwrite(fcap, "%0d\n", $signed(s2mm_tdata));
            if (s2mm_tlast) cap_last_at = cap_n;
            cap_n = cap_n + 1;
        end
    end

    // core-internal OLA output stream (for debugging against the model)
    integer fpush;
    initial fpush = $fopen("top_push.txt", "w");
    always @(posedge aclk) if (dut.u_core.dbg_push) $fwrite(fpush, "%0d\n", dut.u_core.dbg_push_data);
    // core input stream as seen at each tick
    integer fin;
    initial fin = $fopen("top_coreinput.txt", "w");
    always @(posedge aclk) if (dut.tick) $fwrite(fin, "%0d\n", dut.in_sample);

    // ------------------------------------------------------------------ main
    reg [8*8-1:0] test;
    reg [31:0]    r;
    integer       errors = 0;

    initial begin
        if (!$value$plusargs("TEST=%s", test)) test = "bypass";
        if (!$value$plusargs("NS=%d", ns)) ns = 4096;
        $readmemh("top_in.hex", xin);
        $readmemh("dma_in.hex", din);
        fdac = $fopen("dac.txt", "w");
        fcap = $fopen("cap.txt", "w");

        repeat (10) @(negedge aclk);
        aresetn = 1;
        repeat (2100) @(negedge aclk);            // core RAM-clear pass

        axi_read(14'h7C, r);
        if (r !== 32'h5056_0100) begin $display("ERROR version %h", r); errors = errors + 1; end
        axi_read(14'h28, r);
        if (r !== {5'd0, 11'd48, 5'd0, 11'd3}) begin $display("ERROR krange %h", r); errors = errors + 1; end
        if (au_addr !== 2'b11) begin $display("ERROR codec address pins"); errors = errors + 1; end

        // exercise the table write ports (a chromatic table entry and flat EQ)
        axi_write(14'h1000, 32'd22859);           // note 0 = C1 (Q.14 bins)
        axi_write(14'h1004, 32'd23548);
        axi_write(14'h2000, 32'd16384);

        if (test == "bypass") begin
            axi_write(14'h00, 32'h0000_0000);     // dsp_en = 0 -> dry loopback
        end else if (test == "dsp") begin
            axi_write(14'h00, 32'h0000_0001);     // DSP on, autotune off
        end else begin
            // file playback: DMA source, capture what goes to the DAC
            dma_len = ns;
            mm2s_tdata = {{16{din[0][15]}}, din[0]};
            axi_write(14'h40, ns);                // CAPTURE_LEN
            axi_write(14'h00, 32'h0000_0605);     // dsp_en | src_dma | capture_arm | wait_for_dma
            mm2s_tvalid = 1;
        end

        while (dac_cnt < ns) @(posedge aclk);
        if (test == "dma") while (cap_last_at < 0 && dac_cnt < 2 * ns) @(posedge aclk);
        repeat (2000) @(posedge aclk);

        axi_read(14'h04, r);
        $display("TOP status=%h codec_alive=%0d", r, r[0]);
        if (!r[0]) begin $display("ERROR codec clock not detected"); errors = errors + 1; end
        axi_read(14'h0C, r);  $display("TOP frames=%0d", r);
        axi_read(14'h44, r);  $display("TOP underflows=%0d", r);
        axi_read(14'h3C, r);  $display("TOP levels in=%0d out=%0d", r[15:0], r[31:16]);
        if (test == "dma") begin
            axi_read(14'h48, r);  $display("TOP dma_in=%0d", r);
            axi_read(14'h50, r);  $display("TOP captured=%0d tlast_at=%0d", r, cap_last_at);
            if (cap_last_at != ns - 1) begin $display("ERROR tlast position"); errors = errors + 1; end
        end
        $fclose(fdac); $fclose(fcap);
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
