`timescale 1ns / 1ps
`default_nettype none

module pv_i2s (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    output reg         mclk,           // 10 MHz to codec MCLK (U5)
    input  wire        bclk,           // from codec (R18)
    input  wire        lrclk,          // from codec (T17)
    input  wire        sdata_in,       // ADC data from codec (F17)
    output reg         sdata_out,      // DAC data to codec (G18)

    output reg  [23:0] rx_left,
    output reg  [23:0] rx_right,
    output reg         rx_valid,       // sample tick
    input  wire [23:0] tx_left,
    input  wire [23:0] tx_right
);
    reg [2:0] mdiv;
    always @(posedge clk) begin
        if (rst) begin
            mdiv <= 3'd0;
            mclk <= 1'b0;
        end else if (mdiv == 3'd4) begin
            mdiv <= 3'd0;
            mclk <= ~mclk;
        end else begin
            mdiv <= mdiv + 3'd1;
        end
    end

 
    (* ASYNC_REG = "TRUE" *) reg [2:0] bclk_s;
    (* ASYNC_REG = "TRUE" *) reg [1:0] lr_s, sd_s;
    always @(posedge clk) begin
        bclk_s <= {bclk_s[1:0], bclk};
        lr_s   <= {lr_s[0], lrclk};
        sd_s   <= {sd_s[0], sdata_in};
    end
    wire rise = bclk_s[1] & ~bclk_s[2];
    wire fall = ~bclk_s[1] & bclk_s[2];
    wire lr   = lr_s[1];
    wire sd   = sd_s[1];

    
    reg        lr_prev;
    reg [5:0]  bitcnt;
    reg [23:0] rx_sh;
    reg [23:0] tx_sh;

    always @(posedge clk) begin
        rx_valid <= 1'b0;
        if (rst) begin
            lr_prev   <= 1'b0;
            bitcnt    <= 6'd63;
            rx_left   <= 24'd0;
            rx_right  <= 24'd0;
            tx_sh     <= 24'd0;
            sdata_out <= 1'b0;
        end else begin
            if (rise) begin
                lr_prev <= lr;
                if (lr != lr_prev) begin
    
                    bitcnt <= 6'd0;
                    tx_sh  <= lr ? tx_right : tx_left;
                end else if (bitcnt != 6'd63) begin
                    bitcnt <= bitcnt + 6'd1;
                    if (bitcnt < 6'd24) begin
                        rx_sh <= {rx_sh[22:0], sd};
                        if (bitcnt == 6'd23) begin
                            if (lr) begin
                                rx_right <= {rx_sh[22:0], sd};
                                rx_valid <= 1'b1;
                            end else begin
                                rx_left  <= {rx_sh[22:0], sd};
                            end
                        end
                    end
                end
            end
            
            if (fall) begin
                sdata_out <= tx_sh[23];
                tx_sh     <= {tx_sh[22:0], 1'b0};
            end
        end
    end
endmodule
`default_nettype wire
