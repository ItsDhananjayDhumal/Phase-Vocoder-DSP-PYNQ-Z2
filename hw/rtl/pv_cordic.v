`timescale 1ns / 1ps
`default_nettype none

module pv_cordic_vec #(
    parameter IW   = 24,   
    parameter TAGW = 11,   
    parameter ITER = 18
)(
    input  wire                 clk,
    input  wire                 in_valid,
    input  wire signed [IW-1:0] in_x,
    input  wire signed [IW-1:0] in_y,
    input  wire [TAGW-1:0]      in_tag,
    output reg                  out_valid,
    output reg  [IW-1:0]        out_mag,
    output reg  [15:0]          out_phase,
    output reg  [TAGW-1:0]      out_tag
);
    localparam W   = 32;
    localparam PRE = 6;         
    localparam KQ  = 79594;     

    `include "pv_atan.vh"

    reg signed [W-1:0]  xs [0:ITER];
    reg signed [W-1:0]  ys [0:ITER];
    reg        [31:0]   zs [0:ITER];
    reg        [TAGW-1:0] ts [0:ITER];
    reg        [ITER:0] vs = 0;

    wire signed [W-1:0] x_ext = {{(W-IW){in_x[IW-1]}}, in_x} <<< PRE;
    wire signed [W-1:0] y_ext = {{(W-IW){in_y[IW-1]}}, in_y} <<< PRE;

    integer k;
    always @(posedge clk) begin
        
        vs[0] <= in_valid;
        ts[0] <= in_tag;
        if (in_x[IW-1]) begin
            xs[0] <= -x_ext;
            ys[0] <= -y_ext;
            zs[0] <= 32'h8000_0000;
        end else begin
            xs[0] <= x_ext;
            ys[0] <= y_ext;
            zs[0] <= 32'h0000_0000;
        end
        
        for (k = 0; k < ITER; k = k + 1) begin
            vs[k+1] <= vs[k];
            ts[k+1] <= ts[k];
            if (!ys[k][W-1]) begin
                xs[k+1] <= xs[k] + (ys[k] >>> k);
                ys[k+1] <= ys[k] - (xs[k] >>> k);
                zs[k+1] <= zs[k] + atan_bam(k);
            end else begin
                xs[k+1] <= xs[k] - (ys[k] >>> k);
                ys[k+1] <= ys[k] + (xs[k] >>> k);
                zs[k+1] <= zs[k] - atan_bam(k);
            end
        end
    end

    
    reg signed [W+17:0] prod;
    reg [31:0]          z_p;
    reg                 v_p = 1'b0;
    reg [TAGW-1:0]      t_p;
    wire signed [W+17:0] mag_r = (prod + (1 << (PRE + 16))) >>> (PRE + 17);

    initial out_valid = 1'b0;

    always @(posedge clk) begin
        prod <= xs[ITER] * $signed({1'b0, KQ[16:0]});
        z_p  <= zs[ITER];
        v_p  <= vs[ITER];
        t_p  <= ts[ITER];

        out_valid <= v_p;
        out_tag   <= t_p;
        out_mag   <= (mag_r > $signed({1'b0, {IW{1'b1}}})) ? {IW{1'b1}} : mag_r[IW-1:0];
        out_phase <= (z_p + 32'h0000_8000) >> 16;
    end
endmodule


module pv_cordic_rot #(
    parameter MW   = 24,   // unsigned magnitude width
    parameter OW   = 24,   // signed output width
    parameter TAGW = 11,
    parameter ITER = 18
)(
    input  wire                 clk,
    input  wire                 in_valid,
    input  wire [MW-1:0]        in_mag,
    input  wire [15:0]          in_phase,
    input  wire [TAGW-1:0]      in_tag,
    output reg                  out_valid,
    output reg  signed [OW-1:0] out_re,
    output reg  signed [OW-1:0] out_im,
    output reg  [TAGW-1:0]      out_tag
);
    localparam W     = 32;
    localparam SHIFT = 4;        // fractional guard bits inside the iterations
    localparam KQ    = 79594;    // K pre-applied, so the output has unit gain

    `include "pv_atan.vh"

    reg [MW+16:0]   pa_prod;
    reg [31:0]      pa_z;
    reg             pa_flip;
    reg             pa_v = 1'b0;
    reg [TAGW-1:0]  pa_t;

    reg signed [W-1:0]  xs [0:ITER];
    reg signed [W-1:0]  ys [0:ITER];
    reg        [31:0]   zs [0:ITER];
    reg        [TAGW-1:0] ts [0:ITER];
    reg        [ITER:0] vs = 0;

    wire [31:0]    z_in   = {in_phase, 16'h0000};
    wire [MW+16:0] x0_mag = (pa_prod + (1 << (16 - SHIFT))) >> (17 - SHIFT);

    integer k;
    always @(posedge clk) begin

        pa_v    <= in_valid;
        pa_t    <= in_tag;
        pa_prod <= in_mag * KQ[16:0];
        pa_flip <= z_in[31] ^ z_in[30];
        pa_z    <= (z_in[31] ^ z_in[30]) ? (z_in ^ 32'h8000_0000) : z_in;


        vs[0] <= pa_v;
        ts[0] <= pa_t;
        zs[0] <= pa_z;
        ys[0] <= 0;
        xs[0] <= pa_flip ? -$signed(x0_mag[W-1:0]) : $signed(x0_mag[W-1:0]);

        for (k = 0; k < ITER; k = k + 1) begin
            vs[k+1] <= vs[k];
            ts[k+1] <= ts[k];
            if (!zs[k][31]) begin
                xs[k+1] <= xs[k] - (ys[k] >>> k);
                ys[k+1] <= ys[k] + (xs[k] >>> k);
                zs[k+1] <= zs[k] - atan_bam(k);
            end else begin
                xs[k+1] <= xs[k] + (ys[k] >>> k);
                ys[k+1] <= ys[k] - (xs[k] >>> k);
                zs[k+1] <= zs[k] + atan_bam(k);
            end
        end
    end

    wire signed [W-1:0] xr = (xs[ITER] + (1 << (SHIFT - 1))) >>> SHIFT;
    wire signed [W-1:0] yr = (ys[ITER] + (1 << (SHIFT - 1))) >>> SHIFT;
    localparam signed [W-1:0] OMAX = (1 << (OW - 1)) - 1;
    localparam signed [W-1:0] OMIN = -(1 << (OW - 1));

    initial out_valid = 1'b0;

    always @(posedge clk) begin
        out_valid <= vs[ITER];
        out_tag   <= ts[ITER];
        out_re    <= (xr > OMAX) ? OMAX[OW-1:0] : (xr < OMIN) ? OMIN[OW-1:0] : xr[OW-1:0];
        out_im    <= (yr > OMAX) ? OMAX[OW-1:0] : (yr < OMIN) ? OMIN[OW-1:0] : yr[OW-1:0];
    end
endmodule


module pv_udiv #(
    parameter NW = 48,
    parameter DW = 32
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    input  wire [NW-1:0] num,
    input  wire [DW-1:0] den,
    output reg           done,
    output reg  [NW-1:0] quot
);
    reg [DW-1:0] rem;
    reg [NW-1:0] n;
    reg [7:0]    cnt;
    reg          busy = 1'b0;
    reg [DW:0]   r2;

    initial done = 1'b0;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
        end else if (start && !busy) begin
            busy <= 1'b1;
            rem  <= {DW{1'b0}};
            n    <= num;
            quot <= {NW{1'b0}};
            cnt  <= 8'd0;
        end else if (busy) begin
            r2 = {rem, n[NW-1]};
            if (r2 >= {1'b0, den}) begin
                rem  <= r2 - {1'b0, den};
                quot <= {quot[NW-2:0], 1'b1};
            end else begin
                rem  <= r2[DW-1:0];
                quot <= {quot[NW-2:0], 1'b0};
            end
            n <= {n[NW-2:0], 1'b0};
            if (cnt == NW - 1) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
            cnt <= cnt + 8'd1;
        end
    end
endmodule
`default_nettype wire
