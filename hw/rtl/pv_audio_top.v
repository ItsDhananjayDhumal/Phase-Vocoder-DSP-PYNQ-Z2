`timescale 1ns / 1ps
`default_nettype none

module pv_audio_top #(
    parameter LOGN = 11
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:s_axis_mm2s:m_axis_s2mm, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    input  wire        aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        aresetn,

    // AXI4-Lite slave
    input  wire [13:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [13:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // AXI4-Stream from DMA MM2S
    input  wire [31:0] s_axis_mm2s_tdata,
    input  wire [3:0]  s_axis_mm2s_tkeep,
    input  wire        s_axis_mm2s_tlast,
    input  wire        s_axis_mm2s_tvalid,
    output wire        s_axis_mm2s_tready,

    // AXI4-Stream to DMA S2MM 
    output reg  [31:0] m_axis_s2mm_tdata,
    output wire [3:0]  m_axis_s2mm_tkeep,
    output reg         m_axis_s2mm_tlast,
    output reg         m_axis_s2mm_tvalid,
    input  wire        m_axis_s2mm_tready,

    // ADAU1761 codec pins
    output wire        au_mclk,
    input  wire        au_bclk,
    input  wire        au_lrclk,
    input  wire        au_sdata_i,
    output wire        au_sdata_o,
    output wire [1:0]  au_addr
);
    localparam N = 1 << LOGN;
    localparam [31:0] VERSION = 32'h5056_0100;

    wire rst = ~aresetn;
    assign au_addr = 2'b11; 

    reg        dsp_en, autotune_en, src_dma, eq_en, gate_en, mute, cap_wait_dma;
    reg [1:0]  in_ch;
    reg        soft_rst, cap_arm;
    reg [31:0] manual_ratio, alpha, peak_thr, voice_thr, gate_thr, out_gain, capture_len;
    reg [10:0] kmin, kmax;
    reg [7:0]  note_cnt;

    reg        note_we, eq_we;
    reg [7:0]  note_waddr;
    reg [LOGN-1:0] eq_waddr;
    reg [31:0] tbl_wdata;

    wire wr_go = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = wr_go;
    assign s_axi_wready  = wr_go;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    wire [31:0] wd = s_axi_wdata;

    always @(posedge aclk) begin
        soft_rst <= 1'b0;
        cap_arm  <= 1'b0;
        note_we  <= 1'b0;
        eq_we    <= 1'b0;
        if (rst) begin
            s_axi_bvalid <= 1'b0;
            dsp_en <= 1'b1; autotune_en <= 1'b1; src_dma <= 1'b0; eq_en <= 1'b0;
            gate_en <= 1'b0; mute <= 1'b0; in_ch <= 2'd0; cap_wait_dma <= 1'b0;
            manual_ratio <= 32'd65536;
            alpha        <= 32'h6000;
            peak_thr     <= 32'h3000;
            voice_thr    <= 32'd400;
            gate_thr     <= 32'd48;
            out_gain     <= 32'd16384;
            capture_len  <= 32'd0;
            kmin         <= 11'd3;
            kmax         <= 11'd48;
            note_cnt     <= 8'd73;
        end else begin
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
            if (wr_go) begin
                s_axi_bvalid <= 1'b1;
                tbl_wdata    <= wd;
                if (s_axi_awaddr[13]) begin
                    eq_we    <= 1'b1;
                    eq_waddr <= s_axi_awaddr[LOGN+1:2];
                end else if (s_axi_awaddr[12]) begin
                    note_we    <= 1'b1;
                    note_waddr <= s_axi_awaddr[9:2];
                end else begin
                    case (s_axi_awaddr[7:2])
                        6'h00: begin
                            dsp_en <= wd[0]; autotune_en <= wd[1]; src_dma <= wd[2];
                            eq_en <= wd[3]; gate_en <= wd[4]; mute <= wd[5];
                            in_ch <= wd[7:6]; soft_rst <= wd[8]; cap_arm <= wd[9];
                            cap_wait_dma <= wd[10];
                        end
                        6'h04: manual_ratio <= wd;
                        6'h05: alpha        <= (wd > 32'd65536) ? 32'd65536 : wd;
                        6'h06: peak_thr     <= {16'd0, wd[15:0]};
                        6'h07: voice_thr    <= {8'd0, wd[23:0]};
                        6'h08: gate_thr     <= {8'd0, wd[23:0]};
                        6'h09: out_gain     <= {16'd0, wd[15:0]};
                        6'h0A: begin
                            kmin <= (wd[10:0] < 11'd1) ? 11'd1 : wd[10:0];
                            kmax <= (wd[26:16] > 11'd1000) ? 11'd1000 :
                                    (wd[26:16] <= wd[10:0]) ? wd[10:0] + 11'd2 : wd[26:16];
                        end
                        6'h0B: note_cnt     <= (wd[7:0] == 8'd0) ? 8'd1 : (wd[8:0] > 9'd128) ? 8'd128 : wd[7:0];
                        6'h10: capture_len  <= wd;
                        default: ;
                    endcase
                end
            end
        end
    end



    wire [23:0] rx_l, rx_r;
    wire        tick;
    reg  [23:0] tx_word;

    pv_i2s u_i2s (
        .clk(aclk), .rst(rst),
        .mclk(au_mclk), .bclk(au_bclk), .lrclk(au_lrclk),
        .sdata_in(au_sdata_i), .sdata_out(au_sdata_o),
        .rx_left(rx_l), .rx_right(rx_r), .rx_valid(tick),
        .tx_left(tx_word), .tx_right(tx_word)
    );


    wire signed [24:0] lr_sum = $signed(rx_l) + $signed(rx_r);
    wire signed [15:0] codec_in = (in_ch == 2'd1) ? rx_l[23:8] :
                                  (in_ch == 2'd2) ? rx_r[23:8] : lr_sum[24:9];

    assign s_axis_mm2s_tready = tick && src_dma;
    wire signed [15:0] dma_in = s_axis_mm2s_tvalid ? s_axis_mm2s_tdata[15:0] : 16'sd0;
    wire signed [15:0] in_sample = src_dma ? dma_in : codec_in;


    wire signed [15:0] core_out;
    wire [31:0] frame_cnt, det_f0, det_target, det_ratio, underflow_cnt, overrun_cnt;
    wire [23:0] det_level;
    wire        det_voiced, primed, core_busy;
    wire [LOGN-1:0] det_bin;
    wire [31:0] core_in_idx, core_out_idx;

    pv_core #(.LOGN(LOGN)) u_core (
        .clk(aclk), .rst(rst | soft_rst),
        .tick(tick), .in_sample(in_sample), .out_sample(core_out),
        .autotune_en(autotune_en), .eq_en(eq_en), .gate_en(gate_en),
        .manual_ratio(manual_ratio), .alpha(alpha[16:0]), .peak_thr(peak_thr[15:0]),
        .voice_thr(voice_thr[23:0]), .gate_thr(gate_thr[23:0]),
        .kmin(kmin[LOGN-1:0]), .kmax(kmax[LOGN-1:0]), .note_cnt(note_cnt),
        .note_we(note_we), .note_waddr(note_waddr), .note_wdata(tbl_wdata),
        .eq_we(eq_we), .eq_waddr(eq_waddr), .eq_wdata(tbl_wdata[15:0]),
        .frame_cnt(frame_cnt), .det_f0(det_f0), .det_target(det_target), .det_ratio(det_ratio),
        .det_level(det_level), .det_voiced(det_voiced), .det_bin(det_bin),
        .underflow_cnt(underflow_cnt), .overrun_cnt(overrun_cnt), .primed(primed), .busy(core_busy),
        .in_idx(core_in_idx), .out_idx(core_out_idx),
        .dbg_push(), .dbg_push_data()
    );


    reg  signed [15:0] y0;
    reg  signed [32:0] y_prod;
    reg  [1:0]         yv;
    wire signed [32:0] y_sh = y_prod >>> 14;
    wire signed [15:0] y_sat = (y_sh > 32767) ? 16'sd32767 : (y_sh < -32768) ? -16'sd32768 : y_sh[15:0];
    reg  signed [15:0] y_final;
    reg                y_valid;
    reg  [31:0]        y0_idx, y1_idx, y_idx;   // stream index of the sample (for capture alignment)

    always @(posedge aclk) begin
        yv      <= {yv[0], tick};
        y_valid <= 1'b0;
        if (tick) begin
            y0     <= dsp_en ? core_out : in_sample;
            y0_idx <= dsp_en ? core_out_idx : core_in_idx + (N - N / 4);
        end
        if (yv[0]) begin
            y_prod <= y0 * $signed({1'b0, out_gain[15:0]});
            y1_idx <= y0_idx;
        end
        if (yv[1]) begin
            y_idx   <= y1_idx;
            y_final <= mute ? 16'sd0 : y_sat;
            tx_word <= mute ? 24'd0 : {y_sat, 8'd0};
            y_valid <= 1'b1;
        end
        if (rst) begin
            tx_word <= 24'd0;
            yv      <= 2'b0;
        end
    end


    reg [31:0] sample_cnt, dma_in_cnt, dma_starve_cnt;
    reg [15:0] in_pk, out_pk, in_pk_l, out_pk_l;
    reg [11:0] pk_cnt;
    reg [16:0] alive_cnt;
    wire [15:0] in_abs  = in_sample[15] ? (in_sample == -16'sd32768 ? 16'd32767 : -in_sample) : in_sample;
    wire [15:0] out_abs = y_final[15]   ? (y_final   == -16'sd32768 ? 16'd32767 : -y_final)   : y_final;

    always @(posedge aclk) begin
        if (rst) begin
            sample_cnt <= 0; dma_in_cnt <= 0; dma_starve_cnt <= 0;
            in_pk <= 0; out_pk <= 0; in_pk_l <= 0; out_pk_l <= 0; pk_cnt <= 0;
            alive_cnt <= 17'h1FFFF;
        end else begin
            if (tick) begin
                alive_cnt  <= 17'd0;
                sample_cnt <= sample_cnt + 1'b1;
                if (src_dma) begin
                    if (s_axis_mm2s_tvalid) dma_in_cnt <= dma_in_cnt + 1'b1;
                    else                    dma_starve_cnt <= dma_starve_cnt + 1'b1;
                end
                pk_cnt <= pk_cnt + 1'b1;
                if (&pk_cnt) begin
                    in_pk_l <= in_pk;  out_pk_l <= out_pk;
                    in_pk   <= in_abs; out_pk   <= 16'd0;
                end else if (in_abs > in_pk) begin
                    in_pk <= in_abs;
                end
            end else if (alive_cnt != 17'h1FFFF) begin
                alive_cnt <= alive_cnt + 1'b1;
            end
            if (y_valid && out_abs > out_pk) out_pk <= out_abs;
        end
    end
    wire codec_alive = (alive_cnt != 17'h1FFFF);



    localparam C_IDLE = 2'd0, C_WAIT = 2'd1, C_RUN = 2'd2, C_ALIGN = 2'd3;
    reg [1:0]  cst;
    reg [31:0] cap_left, cap_cnt, cap_drop, cap_mark;
    wire       cap_take = (cst == C_RUN) || (cst == C_ALIGN && y_idx == cap_mark);
    assign m_axis_s2mm_tkeep = 4'hF;

    always @(posedge aclk) begin
        if (rst) begin
            cst <= C_IDLE;
            m_axis_s2mm_tvalid <= 1'b0;
            m_axis_s2mm_tlast  <= 1'b0;
            cap_left <= 0; cap_cnt <= 0; cap_drop <= 0;
        end else begin
            if (m_axis_s2mm_tvalid && m_axis_s2mm_tready) m_axis_s2mm_tvalid <= 1'b0;
            case (cst)
                C_IDLE: if (cap_arm && capture_len != 0) begin
                    cap_left <= capture_len;
                    cap_cnt  <= 0;
                    cap_drop <= 0;
                    cst      <= cap_wait_dma ? C_WAIT : C_RUN;
                end
                C_WAIT: if (tick && src_dma && s_axis_mm2s_tvalid) begin
                    cap_mark <= core_in_idx + (N - N / 4);
                    cst      <= C_ALIGN;
                end
                C_RUN, C_ALIGN: if (y_valid && cap_take) begin
                    cst <= C_RUN;
                    if (m_axis_s2mm_tvalid && !m_axis_s2mm_tready) cap_drop <= cap_drop + 1'b1;
                    m_axis_s2mm_tdata  <= {{16{y_final[15]}}, y_final};
                    m_axis_s2mm_tlast  <= (cap_left == 32'd1);
                    m_axis_s2mm_tvalid <= 1'b1;
                    cap_left <= cap_left - 1'b1;
                    cap_cnt  <= cap_cnt + 1'b1;
                    if (cap_left == 32'd1) cst <= C_IDLE;
                end
                default: cst <= C_IDLE;
            endcase
            if (cap_arm && cst != C_IDLE && capture_len == 0) cst <= C_IDLE;   // abort
        end
    end
    wire cap_busy = (cst != C_IDLE) || m_axis_s2mm_tvalid;


    assign s_axi_arready = s_axi_arvalid && !s_axi_rvalid;

    always @(posedge aclk) begin
        if (rst) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= 32'd0;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
            if (s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                if (s_axi_araddr[13:12] != 2'b00) begin
                    s_axi_rdata <= 32'd0;            // tables are write-only
                end else begin
                    case (s_axi_araddr[7:2])
                        6'h00: s_axi_rdata <= {21'd0, cap_wait_dma, 2'b00, in_ch, mute, gate_en, eq_en,
                                               src_dma, autotune_en, dsp_en};
                        6'h01: s_axi_rdata <= {26'd0, s_axis_mm2s_tvalid, primed, core_busy, cap_busy,
                                               det_voiced, codec_alive};
                        6'h02: s_axi_rdata <= sample_cnt;
                        6'h03: s_axi_rdata <= frame_cnt;
                        6'h04: s_axi_rdata <= manual_ratio;
                        6'h05: s_axi_rdata <= alpha;
                        6'h06: s_axi_rdata <= peak_thr;
                        6'h07: s_axi_rdata <= voice_thr;
                        6'h08: s_axi_rdata <= gate_thr;
                        6'h09: s_axi_rdata <= out_gain;
                        6'h0A: s_axi_rdata <= {5'd0, kmax, 5'd0, kmin};
                        6'h0B: s_axi_rdata <= {24'd0, note_cnt};
                        6'h0C: s_axi_rdata <= det_f0;
                        6'h0D: s_axi_rdata <= det_target;
                        6'h0E: s_axi_rdata <= det_ratio;
                        6'h0F: s_axi_rdata <= {out_pk_l, in_pk_l};
                        6'h10: s_axi_rdata <= capture_len;
                        6'h11: s_axi_rdata <= underflow_cnt;
                        6'h12: s_axi_rdata <= dma_in_cnt;
                        6'h13: s_axi_rdata <= dma_starve_cnt;
                        6'h14: s_axi_rdata <= cap_cnt;
                        6'h15: s_axi_rdata <= {8'd0, det_level};
                        6'h16: s_axi_rdata <= {{(32-LOGN){1'b0}}, det_bin};
                        6'h17: s_axi_rdata <= overrun_cnt;
                        6'h18: s_axi_rdata <= {{8{rx_l[23]}}, rx_l};
                        6'h19: s_axi_rdata <= {{8{rx_r[23]}}, rx_r};
                        6'h1A: s_axi_rdata <= cap_drop;
                        6'h1F: s_axi_rdata <= VERSION;
                        default: s_axi_rdata <= 32'd0;
                    endcase
                end
            end
        end
    end
endmodule
`default_nettype wire
