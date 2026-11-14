`timescale 1ns / 1ps
// FFT engine unit test: loads fft_in.hex (natural order), runs a forward
// (scaled) and an inverse (unscaled) transform, dumps both results.
// Checked by hw/sim/run_sim.py against numpy.
module tb_fft;
    localparam LOGN = 11, N = 1 << LOGN, DW = 24;

    reg clk = 0;
    always #5 clk = ~clk;

    reg              rst = 1, start = 0, inverse = 0;
    reg  [LOGN-1:0]  ea_addr = 0;
    reg              ea_we = 0;
    reg  [2*DW-1:0]  ea_din = 0;
    wire [2*DW-1:0]  ea_dout;
    wire             busy, done;

    pv_fft #(.LOGN(LOGN), .DW(DW), .TWINIT("twiddle.mem")) dut (
        .clk(clk), .rst(rst), .start(start), .inverse(inverse), .scale(~inverse),
        .busy(busy), .done(done),
        .ea_addr(ea_addr), .ea_we(ea_we), .ea_din(ea_din), .ea_dout(ea_dout),
        .eb_addr({LOGN{1'b0}}), .eb_we(1'b0), .eb_din({2*DW{1'b0}}), .eb_dout()
    );

    reg [2*DW-1:0] vec [0:N-1];
    integer n, b, f, cycles;
    reg [LOGN-1:0] r;

    task load;
        begin
            for (n = 0; n < N; n = n + 1) begin
                for (b = 0; b < LOGN; b = b + 1) r[b] = n[LOGN-1-b];
                @(negedge clk); ea_addr = r; ea_din = vec[n]; ea_we = 1;
            end
            @(negedge clk); ea_we = 0;
        end
    endtask

    task run_and_dump(input inv, input [8*16-1:0] fname);
        begin
            @(negedge clk); inverse = inv; start = 1;
            @(negedge clk); start = 0;
            cycles = 0;
            while (!done) begin @(posedge clk); cycles = cycles + 1; end
            $display("FFT inverse=%0d done in %0d cycles", inv, cycles);
            f = $fopen(fname, "w");
            for (n = 0; n < N; n = n + 1) begin
                @(negedge clk); ea_addr = n[LOGN-1:0];
                @(negedge clk);              // registered read: data is on ea_dout now
                $fwrite(f, "%0d %0d\n", $signed(ea_dout[2*DW-1:DW]), $signed(ea_dout[DW-1:0]));
            end
            $fclose(f);
        end
    endtask

    initial begin
        $readmemh("fft_in.hex", vec);
        repeat (4) @(negedge clk);
        rst = 0;
        load;
        run_and_dump(1'b0, "fft_out_fwd.txt");
        $readmemh("fft_in_inv.hex", vec);
        load;
        run_and_dump(1'b1, "fft_out_inv.txt");
        $finish;
    end
endmodule
