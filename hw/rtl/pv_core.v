`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// pv_core: real-time phase-vocoder autotune (PS.pdf steps 2-11 in hardware)
//
// Every H = N/4 input samples (75 % overlap) one frame is processed:
//
//   LOAD    last N samples x Hann window -> FFT memory (bit-reversed)     [2]
//   FFT     forward, scaled 1/N                                           [3]
//   ANA     CORDIC rect->polar, phase unwrapping -> instantaneous freq    [4,8]
//   PITCH   lowest strong spectral peak -> f0, tuning-table lookup,
//           ratio S = target/f0, retune smoothing, x manual shift         [5,6]
//   SYNTH   target bin j <- source j/S: linear magnitude interpolation,
//           synthesis phase += S*omega, spectral gate, freq-sampling EQ,
//           CORDIC polar->rect, Hermitian mirror                          [7,8,9]
//   IFFT    inverse, unscaled                                             [10]
//   OLA     synthesis window, overlap-add, H finished samples -> FIFO     [11]
//
// A frame takes about 55k clocks at 100 MHz (0.55 ms), much less than the
// 10.7 ms hop. Output samples leave the FIFO one per audio tick.
// Fixed-point formats are documented in model/pv_params.py; model/pv_model.py
// is the golden reference.
// ============================================================================
module pv_core #(
    parameter LOGN        = 11,
    parameter WIN_A       = "win_analysis.mem",
    parameter WIN_S       = "win_synthesis.mem",
    parameter TWINIT      = "twiddle.mem",
    parameter NOTE_F      = "note_freq.mem",
    parameter NOTE_U      = "note_upper.mem",
    parameter EQ_INIT     = "eq_unity.mem",
    parameter PRIME_DELAY = 32
)(
    input  wire               clk,
    input  wire               rst,            // sync, active high (also soft reset)

    // audio stream, one sample per tick
    input  wire               tick,
    input  wire signed [15:0] in_sample,
    output reg  signed [15:0] out_sample,

    // configuration
    input  wire               autotune_en,
    input  wire               eq_en,
    input  wire               gate_en,
    input  wire [31:0]        manual_ratio,   // Q16.16
    input  wire [16:0]        alpha,          // Q0.16, 65536 = instant retune
    input  wire [15:0]        peak_thr,       // Q0.16 fraction of the strongest peak
    input  wire [23:0]        voice_thr,      // minimum peak magnitude for "voiced"
    input  wire [23:0]        gate_thr,       // spectral gate threshold
    input  wire [LOGN-1:0]    kmin,
    input  wire [LOGN-1:0]    kmax,
    input  wire [7:0]         note_cnt,

    // table write ports (from AXI)
    input  wire               note_we,
    input  wire [7:0]         note_waddr,     // {entry[6:0], 0=freq / 1=upper}
    input  wire [31:0]        note_wdata,
    input  wire               eq_we,
    input  wire [LOGN-1:0]    eq_waddr,
    input  wire [15:0]        eq_wdata,

    // telemetry
    output reg  [31:0]        frame_cnt,
    output reg  [31:0]        det_f0,         // Q.14 bins (0 when unvoiced)
    output reg  [31:0]        det_target,     // Q.14 bins
    output reg  [31:0]        det_ratio,      // Q16.16 total pitch ratio applied
    output reg  [23:0]        det_level,      // strongest peak magnitude
    output reg                det_voiced,
    output reg  [LOGN-1:0]    det_bin,
    output reg  [31:0]        underflow_cnt,
    output reg  [31:0]        overrun_cnt,
    output wire               primed,
    output wire               busy,
    output reg  [31:0]        in_idx,         // index of the sample accepted at the current tick
    output reg  [31:0]        out_idx,        // stream index of out_sample (input index + N - H)

    // FIFO push stream (for the testbench)
    output reg                dbg_push,
    output reg  signed [15:0] dbg_push_data
);
    localparam N     = 1 << LOGN;
    localparam H     = N / 4;
    localparam HALF  = N / 2;
    localparam DW    = 24;
    localparam OMW   = 27;              // omega width (signed, Q.14 bins)
    localparam OLW   = 28;              // overlap-add accumulator width
    localparam [31:0] ONE  = 32'd65536;
    localparam [31:0] RMIN = 32'd32768;
    localparam [31:0] RMAX = 32'd131071;

    function [LOGN-1:0] brev;
        input [LOGN-1:0] a;
        integer b;
        begin
            for (b = 0; b < LOGN; b = b + 1) brev[b] = a[LOGN-1-b];
        end
    endfunction

    // ===================================================================
    // FSM
    // ===================================================================
    localparam S_CLEAR  = 5'd0,  S_IDLE   = 5'd1,  S_LOAD   = 5'd2,  S_FFT    = 5'd3,
               S_ANA    = 5'd4,  S_PTHR   = 5'd5,  S_PSCAN  = 5'd6,  S_PF0    = 5'd7,
               S_PF0W   = 5'd8,  S_NRD    = 5'd9,  S_NCMP   = 5'd10, S_DIV1   = 5'd11,
               S_SM1    = 5'd12, S_SM2    = 5'd13, S_MAN1   = 5'd14, S_MAN2   = 5'd15,
               S_DIV2   = 5'd16, S_SYNTH  = 5'd17, S_IFFT   = 5'd18, S_OLA    = 5'd19,
               S_FFTW   = 5'd20, S_IFFTW  = 5'd21;
    reg [4:0] st = S_CLEAR;

    assign busy = (st != S_IDLE);

    // ===================================================================
    // Input ring buffer and hop scheduler
    // ===================================================================
    reg  [LOGN-1:0] wp;
    reg  [LOGN-3:0] hop_cnt;
    reg             hop_pending;
    reg  [LOGN-1:0] hop_base, base;
    wire            take_hop = (st == S_IDLE) && hop_pending;

    always @(posedge clk) begin
        if (rst) begin
            wp          <= {LOGN{1'b0}};
            hop_cnt     <= {(LOGN-2){1'b0}};
            hop_pending <= 1'b0;
            hop_base    <= {LOGN{1'b0}};
            overrun_cnt <= 32'd0;
            in_idx      <= 32'd0;
        end else begin
            if (take_hop) hop_pending <= 1'b0;
            if (tick) begin
                in_idx  <= in_idx + 1'b1;
                wp      <= wp + 1'b1;
                hop_cnt <= hop_cnt + 1'b1;
                if (&hop_cnt) begin
                    if (hop_pending && !take_hop) overrun_cnt <= overrun_cnt + 1'b1;
                    hop_pending <= 1'b1;
                    hop_base    <= wp + 1'b1;     // oldest of the last N samples
                end
            end
        end
    end

    wire [15:0] inbuf_q;
    reg  [LOGN-1:0] ld_n;
    pv_tdp_ram #(.AW(LOGN), .DW(16)) u_inbuf (
        .clk(clk),
        .addr_a(wp), .we_a(tick), .din_a(in_sample), .dout_a(),
        .addr_b(base + ld_n), .we_b(1'b0), .din_b(16'd0), .dout_b(inbuf_q)
    );

    // ===================================================================
    // Memories
    // ===================================================================
    // FFT engine ports (driven per phase below)
    reg  [LOGN-1:0] fa_addr, fb_addr;
    reg             fa_we, fb_we;
    reg  [2*DW-1:0] fa_din, fb_din;
    wire [2*DW-1:0] fa_q, fb_q;
    reg             fft_start, fft_inv;
    wire            fft_busy, fft_done;

    pv_fft #(.LOGN(LOGN), .DW(DW), .TWINIT(TWINIT)) u_fft (
        .clk(clk), .rst(rst), .start(fft_start), .inverse(fft_inv), .scale(~fft_inv),
        .busy(fft_busy), .done(fft_done),
        .ea_addr(fa_addr), .ea_we(fa_we), .ea_din(fa_din), .ea_dout(fa_q),
        .eb_addr(fb_addr), .eb_we(fb_we), .eb_din(fb_din), .eb_dout(fb_q)
    );

    reg  [LOGN-1:0] win_addr;
    wire [15:0]     wa_q, ws_q;
    pv_rom #(.AW(LOGN), .DW(16), .INIT(WIN_A)) u_wa (.clk(clk), .addr(win_addr), .dout(wa_q));
    pv_rom #(.AW(LOGN), .DW(16), .INIT(WIN_S)) u_ws (.clk(clk), .addr(win_addr), .dout(ws_q));

    reg  [LOGN-1:0] mag_aa, mag_ab;   reg mag_wa;  reg [DW-1:0] mag_din;
    wire [DW-1:0]   mag_qa, mag_qb;
    pv_tdp_ram #(.AW(LOGN), .DW(DW)) u_mag (
        .clk(clk),
        .addr_a(mag_aa), .we_a(mag_wa), .din_a(mag_din), .dout_a(mag_qa),
        .addr_b(mag_ab), .we_b(1'b0), .din_b({DW{1'b0}}), .dout_b(mag_qb)
    );

    reg  [LOGN-1:0] om_a;  reg om_we;  reg [OMW-1:0] om_din;
    wire [OMW-1:0]  om_q;
    pv_tdp_ram #(.AW(LOGN), .DW(OMW)) u_omega (
        .clk(clk),
        .addr_a(om_a), .we_a(om_we), .din_a(om_din), .dout_a(om_q),
        .addr_b({LOGN{1'b0}}), .we_b(1'b0), .din_b({OMW{1'b0}}), .dout_b()
    );

    reg  [LOGN-1:0] ph_aa, ph_ab;  reg ph_wb;  reg [15:0] ph_din;
    wire [15:0]     ph_qa;
    pv_tdp_ram #(.AW(LOGN), .DW(16)) u_phase (
        .clk(clk),
        .addr_a(ph_aa), .we_a(1'b0), .din_a(16'd0), .dout_a(ph_qa),
        .addr_b(ph_ab), .we_b(ph_wb), .din_b(ph_din), .dout_b()
    );

    reg  [LOGN-1:0] sy_aa, sy_ab;  reg sy_wb;  reg [15:0] sy_din;
    wire [15:0]     sy_qa;
    pv_tdp_ram #(.AW(LOGN), .DW(16)) u_synth (
        .clk(clk),
        .addr_a(sy_aa), .we_a(1'b0), .din_a(16'd0), .dout_a(sy_qa),
        .addr_b(sy_ab), .we_b(sy_wb), .din_b(sy_din), .dout_b()
    );

    reg  [LOGN-1:0] eq_ab;
    wire [15:0]     eq_q;
    pv_tdp_ram #(.AW(LOGN), .DW(16), .INIT(EQ_INIT)) u_eq (
        .clk(clk),
        .addr_a(eq_waddr), .we_a(eq_we), .din_a(eq_wdata), .dout_a(),
        .addr_b(eq_ab), .we_b(1'b0), .din_b(16'd0), .dout_b(eq_q)
    );

    reg  [6:0]  nt_i;
    wire [31:0] nf_q, nu_q;
    pv_tdp_ram #(.AW(7), .DW(32), .INIT(NOTE_F)) u_note_f (
        .clk(clk),
        .addr_a(note_waddr[7:1]), .we_a(note_we & ~note_waddr[0]), .din_a(note_wdata), .dout_a(),
        .addr_b(nt_i), .we_b(1'b0), .din_b(32'd0), .dout_b(nf_q)
    );
    pv_tdp_ram #(.AW(7), .DW(32), .INIT(NOTE_U)) u_note_u (
        .clk(clk),
        .addr_a(note_waddr[7:1]), .we_a(note_we & note_waddr[0]), .din_a(note_wdata), .dout_a(),
        .addr_b(nt_i), .we_b(1'b0), .din_b(32'd0), .dout_b(nu_q)
    );

    reg  [LOGN-1:0] ol_aa, ol_ab;  reg ol_wb;  reg [OLW-1:0] ol_din;
    wire [OLW-1:0]  ol_qa;
    pv_tdp_ram #(.AW(LOGN), .DW(OLW)) u_ola (
        .clk(clk),
        .addr_a(ol_aa), .we_a(1'b0), .din_a({OLW{1'b0}}), .dout_a(ol_qa),
        .addr_b(ol_ab), .we_b(ol_wb), .din_b(ol_din), .dout_b()
    );

    // ===================================================================
    // CORDICs
    // ===================================================================
    reg              an_v1 = 1'b0;     // analysis read pipeline (FFT RAM -> CORDIC)
    reg  [LOGN-1:0]  an_k1;
    wire             cv_v;
    wire [DW-1:0]    cv_mag;
    wire [15:0]      cv_ph;
    wire [LOGN-1:0]  cv_t;
    pv_cordic_vec #(.IW(DW), .TAGW(LOGN)) u_cvec (
        .clk(clk), .in_valid(an_v1), .in_x(fa_q[2*DW-1:DW]), .in_y(fa_q[DW-1:0]), .in_tag(an_k1),
        .out_valid(cv_v), .out_mag(cv_mag), .out_phase(cv_ph), .out_tag(cv_t)
    );

    reg              cr_in_v;
    reg  [DW-1:0]    cr_in_mag;
    reg  [15:0]      cr_in_ph;
    reg  [LOGN-1:0]  cr_in_t;
    wire             cr_v;
    wire signed [DW-1:0] cr_re, cr_im;
    wire [LOGN-1:0]  cr_t;
    pv_cordic_rot #(.MW(DW), .OW(DW), .TAGW(LOGN)) u_crot (
        .clk(clk), .in_valid(cr_in_v), .in_mag(cr_in_mag), .in_phase(cr_in_ph), .in_tag(cr_in_t),
        .out_valid(cr_v), .out_re(cr_re), .out_im(cr_im), .out_tag(cr_t)
    );

    // ===================================================================
    // Divider (ratio and its reciprocal)
    // ===================================================================
    reg         div_start;
    reg  [47:0] div_num;
    reg  [31:0] div_den;
    wire        div_done;
    wire [47:0] div_q;
    pv_udiv #(.NW(48), .DW(32)) u_div (
        .clk(clk), .rst(rst), .start(div_start), .num(div_num), .den(div_den),
        .done(div_done), .quot(div_q)
    );

    // ===================================================================
    // Datapath registers
    // ===================================================================
    reg  [LOGN:0]   cnt;                // generic issue counter (needs N)
    reg  [LOGN-1:0] obase;

    // load pipeline
    reg  [1:0]      ld_v;
    reg  [LOGN-1:0] ld_i1, ld_i2;
    reg  signed [32:0] ld_prod;

    // analysis pipeline
    reg             c_v;
    reg  [DW-1:0]   c_mag;
    reg  [15:0]     c_ph;
    reg  [LOGN-1:0] c_k;
    reg  [DW-1:0]   gmax;

    // pitch
    reg  [DW-1:0]   thr;
    reg  [39:0]     thr_prod;
    reg             sc_v1;
    reg  [LOGN:0]   sc_a1;
    reg  [DW-1:0]   p1, p2;
    reg             found;
    reg  [LOGN-1:0] fund;
    reg  signed [OMW-1:0] f0;
    reg             voiced;
    reg  [31:0]     target;
    reg  [31:0]     s_auto, ratio_s, s_tot;
    reg  signed [50:0] sm_prod;
    reg  [49:0]     man_prod;
    reg  [17:0]     inv;
    reg             unity;

    // synthesis pipeline
    reg  [6:0]      sv;
    reg  [28:0]     s0_p;
    reg  [LOGN-1:0] s0_j, s1_j, s2_j, s3_j, s4_j, s5_j;
    reg             s1_in, s2_in, s3_in;
    reg  [15:0]     s1_F, s2_F;
    reg  [DW-1:0]   s2_m0, s2_m1, s3_m0;
    reg  signed [OMW-1:0] s2_om;
    reg  [15:0]     s2_ph, s2_sy, s3_ph, s3_sy, s4_ph, s5_ph;
    reg  [15:0]     s2_eq, s3_eq, s4_eq;
    reg  signed [42:0] s3_pf;
    reg  signed [45:0] s3_pw;
    reg  [DW-1:0]   s4_mag, s5_g;
    reg  [39:0]     s5_pe;

    // OLA pipeline
    reg  [2:0]      ov;
    reg  [LOGN-1:0] o1_n, o2_n, o3_n, o1_a, o2_a, o3_a;
    reg  signed [DW-1:0]  o1_re;
    reg  [15:0]     o1_w;
    reg  signed [OLW-1:0] o1_o, o2_o;
    reg  signed [41:0] o2_prod;

    // synthesis-stage combinational helpers
    wire [11:0]     s1_i    = s0_p[27:16];
    wire            s1_inside = (s1_i < HALF);
    wire [LOGN-1:0] s1_ic   = s1_inside ? s1_i[LOGN-1:0] : {LOGN{1'b0}};
    wire signed [DW:0] s2_diff = $signed({1'b0, s2_m1}) - $signed({1'b0, s2_m0});
    wire signed [DW+1:0] s4_mt = $signed({2'b0, s3_m0}) + (s3_pf >>> 16);
    wire [15:0]     s4_newph = unity ? s3_ph : (s3_sy + s3_pw[31:16]);
    wire [DW-1:0]   s5_gated = (gate_en && (s4_mag < gate_thr)) ? {DW{1'b0}} : s4_mag;
    wire [25:0]     s6_eq   = s5_pe[39:14];
    wire [DW-1:0]   s6_mag  = !eq_en ? s5_g : (|s6_eq[25:DW]) ? {DW{1'b1}} : s6_eq[DW-1:0];

    // OLA combinational helpers
    wire signed [OLW-1:0] o3_y   = o2_prod >>> 16;
    wire signed [OLW-1:0] o3_sum = o2_o + o3_y;
    wire signed [OLW-1:0] o3_r   = (o3_sum + 8) >>> 4;
    wire signed [15:0]    o3_out = (o3_r > 32767) ? 16'sd32767 : (o3_r < -32768) ? -16'sd32768 : o3_r[15:0];

    // analysis combinational helpers
    wire [15:0]     a_dev = c_ph - ph_qa - {c_k[1:0], 14'd0};
    wire signed [OMW-1:0] a_omega = $signed({{(OMW-LOGN-14){1'b0}}, c_k, 14'd0}) +
                                    $signed({{(OMW-16){a_dev[15]}}, a_dev});

    // ===================================================================
    // Memory port steering (combinational, per state)
    // ===================================================================
    always @(*) begin
        fa_addr = {LOGN{1'b0}}; fa_we = 1'b0; fa_din = {2*DW{1'b0}};
        fb_addr = {LOGN{1'b0}}; fb_we = 1'b0; fb_din = {2*DW{1'b0}};
        mag_aa = {LOGN{1'b0}};  mag_wa = 1'b0; mag_din = c_mag; mag_ab = {LOGN{1'b0}};
        om_a = {LOGN{1'b0}};    om_we = 1'b0;  om_din = a_omega;
        ph_aa = {LOGN{1'b0}};   ph_ab = {LOGN{1'b0}}; ph_wb = 1'b0; ph_din = c_ph;
        sy_aa = {LOGN{1'b0}};   sy_ab = s4_j; sy_wb = 1'b0; sy_din = s4_newph;
        eq_ab = s0_j;
        ol_aa = {LOGN{1'b0}};   ol_ab = o3_a; ol_wb = 1'b0;
        ol_din = (o3_n < H) ? {OLW{1'b0}} : o3_sum;
        win_addr = cnt[LOGN-1:0];
        ld_n = cnt[LOGN-1:0];

        case (st)
            S_CLEAR: begin
                ph_ab = cnt[LOGN-1:0]; ph_wb = 1'b1; ph_din = 16'd0;
                sy_ab = cnt[LOGN-1:0]; sy_wb = 1'b1; sy_din = 16'd0;
                ol_ab = cnt[LOGN-1:0]; ol_wb = 1'b1; ol_din = {OLW{1'b0}};
            end
            S_LOAD: begin
                fa_addr = brev(ld_i2); fa_we = ld_v[1];
                fa_din  = {{(DW-21){ld_prod[32]}}, ld_prod[32:12], {DW{1'b0}}};
            end
            S_ANA: begin
                fa_addr = cnt[LOGN-1:0];
                ph_aa   = cv_t;
                mag_aa  = c_k; mag_wa = c_v;
                om_a    = c_k; om_we  = c_v;
                ph_ab   = c_k; ph_wb  = c_v;
            end
            S_PSCAN: mag_aa = cnt[LOGN-1:0];
            S_PF0, S_PF0W: om_a = fund;
            S_SYNTH: begin
                mag_aa = s1_ic;
                mag_ab = s1_ic + 1'b1;
                om_a   = s1_ic + s0_p[15];
                ph_aa  = s0_j;
                sy_aa  = s0_j;
                sy_ab  = s3_j;
                sy_wb  = sv[3];
                eq_ab  = s0_j;
                if (cr_v) begin
                    fa_addr = brev(cr_t); fa_we = 1'b1;
                    fa_din  = {cr_re, ((cr_t == 0) || (cr_t == HALF)) ? {DW{1'b0}} : cr_im};
                    fb_addr = brev(N - cr_t);
                    fb_we   = (cr_t != 0) && (cr_t != HALF);
                    fb_din  = {cr_re, -cr_im};
                end
            end
            S_OLA: begin
                fa_addr = cnt[LOGN-1:0];
                ol_aa   = obase + cnt[LOGN-1:0];
                ol_wb   = ov[2];
            end
            default: ;
        endcase
    end

    // ===================================================================
    // Main sequencer
    // ===================================================================
    always @(posedge clk) begin
        fft_start <= 1'b0;
        div_start <= 1'b0;
        dbg_push  <= 1'b0;
        cr_in_v   <= 1'b0;

        if (rst) begin
            st         <= S_CLEAR;
            cnt        <= 0;
            obase      <= {LOGN{1'b0}};
            ratio_s    <= ONE;
            frame_cnt  <= 32'd0;
            det_f0     <= 32'd0;
            det_target <= 32'd0;
            det_ratio  <= ONE;
            det_level  <= {DW{1'b0}};
            det_voiced <= 1'b0;
            det_bin    <= {LOGN{1'b0}};
            ld_v       <= 2'b0;
            an_v1      <= 1'b0;
            c_v        <= 1'b0;
            sc_v1      <= 1'b0;
            sv         <= 7'd0;
            ov         <= 3'd0;
            fft_inv    <= 1'b0;
        end else begin
            case (st)
                // ------------------------------------------------ clear state
                S_CLEAR: begin
                    cnt <= cnt + 1'b1;
                    if (cnt == N - 1) st <= S_IDLE;
                end

                S_IDLE: begin
                    cnt <= 0;
                    if (take_hop) begin
                        base <= hop_base;
                        st   <= S_LOAD;
                    end
                end

                // ----------------------------------- window and load into FFT
                S_LOAD: begin
                    if (cnt < N) cnt <= cnt + 1'b1;
                    ld_v    <= {ld_v[0], (cnt < N)};
                    ld_i1   <= cnt[LOGN-1:0];
                    ld_i2   <= ld_i1;
                    ld_prod <= $signed(inbuf_q) * $signed({1'b0, wa_q});
                    if (ld_v[1] && ld_i2 == N - 1) begin
                        ld_v      <= 2'b0;
                        fft_start <= 1'b1;
                        fft_inv   <= 1'b0;
                        st        <= S_FFT;
                    end
                end

                S_FFT:  st <= S_FFTW;      // fft_busy rises the cycle after start
                S_FFTW: if (fft_done) begin
                    cnt  <= 0;
                    gmax <= {DW{1'b0}};
                    st   <= S_ANA;
                end

                // ------------------------- analysis: polar form + inst. freq.
                S_ANA: begin
                    if (cnt <= HALF) cnt <= cnt + 1'b1;
                    an_v1   <= (cnt <= HALF);
                    an_k1   <= cnt[LOGN-1:0];

                    c_v   <= cv_v;
                    c_mag <= cv_mag;
                    c_ph  <= cv_ph;
                    c_k   <= cv_t;

                    if (c_v && c_k >= kmin && c_k <= kmax && c_mag > gmax) gmax <= c_mag;
                    if (c_v && c_k == HALF) begin
                        c_v <= 1'b0;
                        st  <= S_PTHR;
                    end
                end

                // ------------------------------------------- pitch detection
                S_PTHR: begin
                    thr_prod <= gmax * peak_thr;
                    cnt      <= kmin - 1'b1;
                    found    <= 1'b0;
                    fund     <= {LOGN{1'b0}};
                    sc_v1    <= 1'b0;
                    st       <= S_PSCAN;
                end

                S_PSCAN: begin
                    thr   <= thr_prod[39:16];
                    sc_v1 <= (cnt <= kmax + 1'b1);
                    sc_a1 <= cnt;
                    if (cnt <= kmax + 1'b1) cnt <= cnt + 1'b1;
                    if (sc_v1) begin
                        p2 <= p1;
                        p1 <= mag_qa;
                        if (sc_a1 >= kmin + 1'b1 && !found && p1 > p2 && p1 >= mag_qa && p1 >= thr) begin
                            found <= 1'b1;
                            fund  <= sc_a1 - 1'b1;
                        end
                        if (sc_a1 == kmax + 1'b1) begin
                            sc_v1 <= 1'b0;
                            st    <= S_PF0;
                        end
                    end
                end

                S_PF0:  st <= S_PF0W;          // omega[fund] read in flight
                S_PF0W: begin
                    f0     <= $signed(om_q);
                    voiced <= found && (gmax >= voice_thr) && !om_q[OMW-1] && (om_q != 0) && (note_cnt != 0);
                    nt_i   <= 7'd0;
                    st     <= S_NRD;
                end

                // --------------------------------------- tuning table lookup
                S_NRD: begin
                    if (!voiced) begin
                        target <= 32'd0;
                        s_auto <= ONE;
                        st     <= S_SM1;
                    end else begin
                        st <= S_NCMP;
                    end
                end

                S_NCMP: begin
                    if ($signed({1'b0, f0}) < $signed({1'b0, nu_q}) || nt_i == note_cnt - 1'b1) begin
                        target <= nf_q;
                        if (autotune_en) begin
                            div_num   <= {nf_q, 16'd0};
                            div_den   <= f0;
                            div_start <= 1'b1;
                            st        <= S_DIV1;
                        end else begin
                            s_auto <= ONE;
                            st     <= S_SM1;
                        end
                    end else begin
                        nt_i <= nt_i + 1'b1;
                        st   <= S_NRD;
                    end
                end

                S_DIV1: if (div_done) begin
                    s_auto <= (div_q < RMIN) ? RMIN : (div_q > 48'd131072) ? 32'd131072 : div_q[31:0];
                    st     <= S_SM1;
                end

                // ------------------------- retune smoothing and manual shift
                S_SM1: begin
                    sm_prod <= ($signed({1'b0, s_auto}) - $signed({1'b0, ratio_s})) * $signed({1'b0, alpha});
                    st      <= S_SM2;
                end
                S_SM2: begin
                    // snap once the step rounds to zero so the ratio can settle exactly
                    ratio_s <= (sm_prod[50:16] == 0 || sm_prod[50:16] == {35{1'b1}}) ? s_auto
                                                                                : ratio_s + sm_prod[47:16];
                    st      <= S_MAN1;
                end
                S_MAN1: begin
                    man_prod <= ratio_s[17:0] * manual_ratio;
                    st       <= S_MAN2;
                end
                S_MAN2: begin
                    s_tot     <= (man_prod[49:16] < RMIN) ? RMIN : (man_prod[49:16] > RMAX) ? RMAX : man_prod[47:16];
                    div_num   <= 48'h0001_0000_0000;
                    div_den   <= (man_prod[49:16] < RMIN) ? RMIN : (man_prod[49:16] > RMAX) ? RMAX : man_prod[47:16];
                    div_start <= 1'b1;
                    st        <= S_DIV2;
                end
                S_DIV2: if (div_done) begin
                    inv        <= div_q[17:0];
                    unity      <= (s_tot == ONE);
                    det_f0     <= voiced ? f0 : 32'd0;
                    det_target <= target;
                    det_ratio  <= s_tot;
                    det_level  <= gmax;
                    det_voiced <= voiced;
                    det_bin    <= fund;
                    cnt        <= 0;
                    sv         <= 7'd0;
                    st         <= S_SYNTH;
                end

                // ------------------------------------- spectral resynthesis
                S_SYNTH: begin
                    // s0: issue bin j and form its source position p = j / S
                    sv[0] <= (cnt <= HALF);
                    if (cnt <= HALF) cnt <= cnt + 1'b1;
                    s0_p  <= cnt[LOGN-1:0] * inv;
                    s0_j  <= cnt[LOGN-1:0];
                    sv[6:1] <= sv[5:0];
                    // s1: RAM reads (addresses steered combinationally)
                    s1_j  <= s0_j;  s1_in <= s1_inside;  s1_F <= s0_p[15:0];
                    // s2: capture RAM outputs
                    s2_j  <= s1_j;  s2_in <= s1_in;  s2_F <= s1_F;
                    s2_m0 <= mag_qa;  s2_m1 <= mag_qb;  s2_om <= om_q;
                    s2_ph <= ph_qa;   s2_sy <= sy_qa;   s2_eq <= eq_q;
                    // s3: interpolation and frequency-scaling products
                    s3_j  <= s2_j;  s3_in <= s2_in;  s3_m0 <= s2_m0;
                    s3_ph <= s2_ph; s3_sy <= s2_sy;  s3_eq <= s2_eq;
                    s3_pf <= s2_diff * $signed({1'b0, s2_F});
                    s3_pw <= s2_om * $signed({1'b0, s_tot[17:0]});
                    // s4: interpolated magnitude, accumulated phase (written back)
                    s4_j   <= s3_j;
                    s4_mag <= s3_in ? s4_mt[DW-1:0] : {DW{1'b0}};
                    s4_ph  <= s4_newph;
                    s4_eq  <= s3_eq;
                    // s5: noise gate, EQ product
                    s5_j  <= s4_j;  s5_ph <= s4_ph;
                    s5_g  <= s5_gated;
                    s5_pe <= s5_gated * s4_eq;
                    // s6 -> CORDIC rotation
                    cr_in_v   <= sv[5];
                    cr_in_mag <= s6_mag;
                    cr_in_ph  <= s5_ph;
                    cr_in_t   <= s5_j;

                    if (cr_v && cr_t == HALF) begin
                        fft_start <= 1'b1;
                        fft_inv   <= 1'b1;
                        st        <= S_IFFT;
                    end
                end

                S_IFFT:  st <= S_IFFTW;
                S_IFFTW: if (fft_done) begin
                    cnt <= 0;
                    ov  <= 3'd0;
                    st  <= S_OLA;
                end

                // ----------------------------- synthesis window + overlap-add
                S_OLA: begin
                    ov[0] <= (cnt < N);
                    if (cnt < N) cnt <= cnt + 1'b1;
                    ov[2:1] <= ov[1:0];
                    o1_n  <= cnt[LOGN-1:0];  o1_a <= obase + cnt[LOGN-1:0];
                    o2_n  <= o1_n;  o2_a <= o1_a;  o3_n <= o2_n;  o3_a <= o2_a;
                    o1_re <= fa_q[2*DW-1:DW];
                    o1_w  <= ws_q;
                    o1_o  <= ol_qa;
                    o2_o  <= o1_o;
                    o2_prod <= o1_re * $signed({1'b0, o1_w});
                    if (ov[2] && o3_n < H) begin
                        dbg_push      <= 1'b1;
                        dbg_push_data <= o3_out;
                    end
                    if (ov[2] && o3_n == N - 1) begin
                        obase     <= obase + H;
                        frame_cnt <= frame_cnt + 1'b1;
                        ov        <= 3'd0;
                        st        <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // ===================================================================
    // Output FIFO and sample-rate playback
    // ===================================================================
    reg  [LOGN-1:0] f_wp, f_rp;
    reg  [LOGN:0]   f_cnt;
    reg  [1:0]      ost;
    reg  [5:0]      odly;
    reg             pop_d;
    reg  [31:0]     pop_cnt, pop_idx;
    wire [15:0]     fifo_q;
    wire            f_push = dbg_push && (f_cnt < N);
    wire            f_pop  = tick && (ost == 2'd2) && (f_cnt != 0);

    pv_tdp_ram #(.AW(LOGN), .DW(16)) u_fifo (
        .clk(clk),
        .addr_a(f_wp), .we_a(f_push), .din_a(dbg_push_data), .dout_a(),
        .addr_b(f_rp), .we_b(1'b0), .din_b(16'd0), .dout_b(fifo_q)
    );

    assign primed = (ost == 2'd2);

    always @(posedge clk) begin
        if (rst) begin
            f_wp <= 0; f_rp <= 0; f_cnt <= 0;
            ost <= 2'd0; odly <= 6'd0; pop_d <= 1'b0;
            pop_cnt <= 32'd0; pop_idx <= 32'd0; out_idx <= 32'hFFFF_FFFF;
            out_sample <= 16'sd0;
            underflow_cnt <= 32'd0;
        end else begin
            if (f_push) f_wp <= f_wp + 1'b1;
            if (f_pop)  f_rp <= f_rp + 1'b1;
            f_cnt <= f_cnt + f_push - f_pop;

            pop_d <= f_pop;
            if (f_pop) begin
                pop_idx <= pop_cnt;
                pop_cnt <= pop_cnt + 1'b1;
            end
            if (pop_d) begin
                out_sample <= fifo_q;
                out_idx    <= pop_idx;
            end

            if (tick) begin
                case (ost)
                    2'd0: begin                          // wait for a full hop
                        out_sample <= 16'sd0;
                        out_idx    <= 32'hFFFF_FFFF;
                        if (f_cnt >= H) begin ost <= 2'd1; odly <= PRIME_DELAY - 1; end
                    end
                    2'd1: begin                          // small safety margin
                        out_sample <= 16'sd0;
                        out_idx    <= 32'hFFFF_FFFF;
                        odly <= odly - 1'b1;
                        if (odly == 0) ost <= 2'd2;
                    end
                    default: if (f_cnt == 0) begin       // underflow: re-prime
                        out_sample    <= 16'sd0;
                        out_idx       <= 32'hFFFF_FFFF;
                        underflow_cnt <= underflow_cnt + 1'b1;
                        ost           <= 2'd0;
                    end
                endcase
            end
        end
    end
endmodule
`default_nettype wire
