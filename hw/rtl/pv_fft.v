`timescale 1ns / 1ps
`default_nettype none

module pv_fft #(
    parameter LOGN   = 11,
    parameter DW     = 24,
    parameter TWINIT = "twiddle.mem"
)(
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    input  wire               inverse,
    input  wire               scale,
    output wire               busy,
    output reg                done,

    input  wire [LOGN-1:0]    ea_addr,
    input  wire               ea_we,
    input  wire [2*DW-1:0]    ea_din,
    output wire [2*DW-1:0]    ea_dout,
    input  wire [LOGN-1:0]    eb_addr,
    input  wire               eb_we,
    input  wire [2*DW-1:0]    eb_din,
    output wire [2*DW-1:0]    eb_dout
);
    localparam NB  = LOGN - 1;            // butterfly index width
    localparam TW  = 18;                  // twiddle width, 1.0 = 2^16
    localparam AW  = DW + 4;              // butterfly sum width

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2;
    reg [1:0]       state = S_IDLE;
    reg [3:0]       stage;
    reg [NB-1:0]    bfly;
    reg             par;
    reg [3:0]       drain;
    reg             inv_r, scale_r;

    assign busy = (state != S_IDLE);

    wire [NB-1:0]   mask  = (({{(NB-1){1'b0}}, 1'b1}) << stage) - 1'b1;
    wire [LOGN-1:0] i0    = {(bfly & ~mask), 1'b0} | {1'b0, (bfly & mask)};
    wire [LOGN-1:0] i1    = i0 | ({{(LOGN-1){1'b0}}, 1'b1} << stage);
    wire [NB-1:0]   tw_a  = (bfly & mask) << (NB - stage);
    wire            rd_now = (state == S_RUN) && !par;

    initial done = 1'b0;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    state   <= S_RUN;
                    stage   <= 4'd0;
                    bfly    <= {NB{1'b0}};
                    par     <= 1'b0;
                    inv_r   <= inverse;
                    scale_r <= scale;
                end
                S_RUN: begin
                    par <= ~par;
                    if (!par) begin
                        bfly <= bfly + 1'b1;
                        if (&bfly) begin
                            state <= S_DRAIN;
                            drain <= 4'd0;
                        end
                    end
                end
                S_DRAIN: begin
                    drain <= drain + 4'd1;
                    if (drain == 4'd7) begin
                        if (stage == LOGN - 1) begin
                            state <= S_IDLE;
                            done  <= 1'b1;
                        end else begin
                            state <= S_RUN;
                            stage <= stage + 4'd1;
                            bfly  <= {NB{1'b0}};
                            par   <= 1'b0;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    
    wire [2*TW-1:0] tw_q;
    pv_rom #(.AW(NB), .DW(2*TW), .INIT(TWINIT)) u_tw (.clk(clk), .addr(tw_a), .dout(tw_q));

    
    reg  [LOGN-1:0] wa0, wa1, wa2, wa3, wa4;   // i0 pipeline
    reg  [LOGN-1:0] wb0, wb1, wb2, wb3, wb4;   // i1 pipeline
    reg  [4:0]      vp = 5'd0;                 // valid pipeline
    reg  [2*DW-1:0] y0_q, y1_q;
    wire            wr_now = vp[4];

    wire [LOGN-1:0] pa_addr = wr_now ? wa4 : rd_now ? i0 : ea_addr;
    wire [LOGN-1:0] pb_addr = wr_now ? wb4 : rd_now ? i1 : eb_addr;
    wire            pa_we   = wr_now | (!busy & ea_we);
    wire            pb_we   = wr_now | (!busy & eb_we);
    wire [2*DW-1:0] pa_din  = wr_now ? y0_q : ea_din;
    wire [2*DW-1:0] pb_din  = wr_now ? y1_q : eb_din;
    wire [2*DW-1:0] qa, qb;

    pv_tdp_ram #(.AW(LOGN), .DW(2*DW)) u_mem (
        .clk(clk),
        .addr_a(pa_addr), .we_a(pa_we), .din_a(pa_din), .dout_a(qa),
        .addr_b(pb_addr), .we_b(pb_we), .din_b(pb_din), .dout_b(qb)
    );
    assign ea_dout = qa;
    assign eb_dout = qb;

    
    reg signed [DW-1:0]   a_re1, a_im1, b_re1, b_im1;
    reg signed [TW-1:0]   w_re1, w_im1;
    reg signed [DW-1:0]   a_re2, a_im2, a_re3, a_im3;
    reg signed [DW+TW-1:0] m_rr, m_ii, m_ri, m_ir;
    reg signed [AW-1:0]   t_re, t_im;

    wire signed [TW-1:0]  tw_cos = tw_q[2*TW-1:TW];
    wire signed [TW-1:0]  tw_sin = tw_q[TW-1:0];
    wire signed [DW+TW:0] s_re = m_rr - m_ii + (1 <<< 15);
    wire signed [DW+TW:0] s_im = m_ri + m_ir + (1 <<< 15);

    wire signed [AW-1:0]  sum0 = {{4{a_re3[DW-1]}}, a_re3} + t_re;
    wire signed [AW-1:0]  sum1 = {{4{a_im3[DW-1]}}, a_im3} + t_im;
    wire signed [AW-1:0]  dif0 = {{4{a_re3[DW-1]}}, a_re3} - t_re;
    wire signed [AW-1:0]  dif1 = {{4{a_im3[DW-1]}}, a_im3} - t_im;

    function [DW-1:0] fin;          // optional halving + saturation
        input signed [AW-1:0] v;
        input                 sc;
        reg   signed [AW-1:0] s;
        begin
            s = sc ? ((v + 1) >>> 1) : v;
            if (s > $signed({{(AW-DW+1){1'b0}}, {(DW-1){1'b1}}}))
                fin = {1'b0, {(DW-1){1'b1}}};
            else if (s < $signed({{(AW-DW+1){1'b1}}, {(DW-1){1'b0}}}))
                fin = {1'b1, {(DW-1){1'b0}}};
            else
                fin = s[DW-1:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) vp <= 5'd0;
        else     vp <= {vp[3:0], rd_now};

        wa0 <= i0;  wa1 <= wa0; wa2 <= wa1; wa3 <= wa2; wa4 <= wa3;
        wb0 <= i1;  wb1 <= wb0; wb2 <= wb1; wb3 <= wb2; wb4 <= wb3;

    
        a_re1 <= qa[2*DW-1:DW];  a_im1 <= qa[DW-1:0];
        b_re1 <= qb[2*DW-1:DW];  b_im1 <= qb[DW-1:0];
        w_re1 <= tw_cos;
        w_im1 <= inv_r ? tw_sin : -tw_sin;

    
        m_rr  <= b_re1 * w_re1;
        m_ii  <= b_im1 * w_im1;
        m_ri  <= b_re1 * w_im1;
        m_ir  <= b_im1 * w_re1;
        a_re2 <= a_re1;  a_im2 <= a_im1;

    
        t_re  <= s_re >>> 16;
        t_im  <= s_im >>> 16;
        a_re3 <= a_re2;  a_im3 <= a_im2;

    
        y0_q  <= {fin(sum0, scale_r), fin(sum1, scale_r)};
        y1_q  <= {fin(dif0, scale_r), fin(dif1, scale_r)};
    
    
    end

endmodule
`default_nettype wire
