`timescale 1ns / 1ps
// pv_core system test: streams core_in.hex through the core with a fast audio
// tick and records the OLA output stream, the played-out samples and the
// per-frame pitch telemetry. hw/sim/run_sim.py compares them with the golden
// model (model/pv_model.py).
//
// plusargs: +NS=<samples> +AUTOTUNE=<0|1> +RATIO=<Q16.16> +ALPHA=<Q0.16>
//           +EQ=<0|1> (loads eq.hex) +GATE=<0|1> +GATETHR=<n>
module tb_pv_core;
    localparam LOGN = 11, N = 1 << LOGN;
    localparam TICK = 128;            // clocks per audio sample in simulation

    reg clk = 0;
    always #5 clk = ~clk;

    reg               rst = 1;
    reg               tick = 0;
    reg signed [15:0] in_sample = 0;
    wire signed [15:0] out_sample;

    reg  [31:0] ratio = 32'd65536, alpha = 32'h6000, gate_thr = 48;
    reg         autotune = 1, eq_en = 0, gate_en = 0;
    reg         eq_we = 0;
    reg  [LOGN-1:0] eq_waddr = 0;
    reg  [15:0] eq_wdata = 0;

    wire [31:0] frame_cnt, det_f0, det_target, det_ratio, underflow_cnt, overrun_cnt;
    wire [23:0] det_level;
    wire        det_voiced, primed, busy, dbg_push;
    wire [LOGN-1:0] det_bin;
    wire signed [15:0] dbg_push_data;

    pv_core #(.LOGN(LOGN)) dut (
        .clk(clk), .rst(rst),
        .tick(tick), .in_sample(in_sample), .out_sample(out_sample),
        .autotune_en(autotune), .eq_en(eq_en), .gate_en(gate_en),
        .manual_ratio(ratio), .alpha(alpha[16:0]), .peak_thr(16'h3000), .voice_thr(24'd400),
        .gate_thr(gate_thr[23:0]), .kmin(11'd3), .kmax(11'd48), .note_cnt(8'd73),
        .note_we(1'b0), .note_waddr(8'd0), .note_wdata(32'd0),
        .eq_we(eq_we), .eq_waddr(eq_waddr), .eq_wdata(eq_wdata),
        .frame_cnt(frame_cnt), .det_f0(det_f0), .det_target(det_target), .det_ratio(det_ratio),
        .det_level(det_level), .det_voiced(det_voiced), .det_bin(det_bin),
        .underflow_cnt(underflow_cnt), .overrun_cnt(overrun_cnt), .primed(primed), .busy(busy),
        .dbg_push(dbg_push), .dbg_push_data(dbg_push_data)
    );

    reg [15:0] xin [0:(1<<20)-1];
    reg [15:0] eqv [0:N-1];
    integer ns, i, fp, fo, ft, maxbusy, busy_run;
    reg [31:0] last_frame;

    always @(posedge clk) if (dbg_push) $fwrite(fp, "%0d\n", dbg_push_data);

    always @(posedge clk) begin
        if (frame_cnt != last_frame) begin
            $fwrite(ft, "%0d %0d %0d %0d %0d %0d\n", det_f0, det_target, det_ratio, det_voiced, det_bin, det_level);
            last_frame = frame_cnt;
        end
        if (busy) busy_run = busy_run + 1;
        else begin
            if (busy_run > maxbusy) maxbusy = busy_run;
            busy_run = 0;
        end
    end

    initial begin
        if (!$value$plusargs("NS=%d", ns)) ns = 8192;
        if ($value$plusargs("AUTOTUNE=%d", i)) autotune = i;
        if ($value$plusargs("RATIO=%d", i)) ratio = i;
        if ($value$plusargs("ALPHA=%d", i)) alpha = i;
        if ($value$plusargs("GATE=%d", i)) gate_en = i;
        if ($value$plusargs("GATETHR=%d", i)) gate_thr = i;
        if ($value$plusargs("EQ=%d", i)) eq_en = i;
        $readmemh("core_in.hex", xin);
        fp = $fopen("core_push.txt", "w");
        fo = $fopen("core_out.txt", "w");
        ft = $fopen("core_tel.txt", "w");
        last_frame = 0; maxbusy = 0; busy_run = 0;

        repeat (5) @(negedge clk);
        rst = 0;
        if (eq_en) begin
            $readmemh("eq.hex", eqv);
            for (i = 0; i < N; i = i + 1) begin
                @(negedge clk); eq_we = 1; eq_waddr = i; eq_wdata = eqv[i];
            end
            @(negedge clk); eq_we = 0;
        end
        // let the RAM-clear pass finish
        repeat (N + 10) @(negedge clk);

        for (i = 0; i < ns; i = i + 1) begin
            @(negedge clk); tick = 1; in_sample = xin[i];
            @(negedge clk); tick = 0;
            $fwrite(fo, "%0d\n", out_sample);
            repeat (TICK - 2) @(negedge clk);
        end
        repeat (4 * TICK) @(negedge clk);
        $display("frames=%0d underflows=%0d overruns=%0d longest_busy=%0d cycles",
                 frame_cnt, underflow_cnt, overrun_cnt, maxbusy);
        $fclose(fp); $fclose(fo); $fclose(ft);
        $finish;
    end
endmodule
