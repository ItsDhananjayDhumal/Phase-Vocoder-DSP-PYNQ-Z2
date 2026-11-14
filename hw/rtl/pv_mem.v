`timescale 1ns / 1ps
`default_nettype none
// ============================================================================
// Block-RAM primitives for the phase-vocoder core (Vivado inference templates).
// All reads are synchronous with one cycle of latency.
// ============================================================================

// True dual-port RAM: two independent read/write ports.
module pv_tdp_ram #(
    parameter AW   = 11,
    parameter DW   = 16,
    parameter INIT = ""
)(
    input  wire          clk,
    input  wire [AW-1:0] addr_a,
    input  wire          we_a,
    input  wire [DW-1:0] din_a,
    output reg  [DW-1:0] dout_a,
    input  wire [AW-1:0] addr_b,
    input  wire          we_b,
    input  wire [DW-1:0] din_b,
    output reg  [DW-1:0] dout_b
);
    (* ram_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
        if (INIT != "") $readmemh(INIT, mem);
        dout_a = {DW{1'b0}};
        dout_b = {DW{1'b0}};
    end

    always @(posedge clk) begin
        if (we_a) mem[addr_a] <= din_a;
        dout_a <= mem[addr_a];
    end

    always @(posedge clk) begin
        if (we_b) mem[addr_b] <= din_b;
        dout_b <= mem[addr_b];
    end
endmodule

// Single-port ROM initialised from a hex file.
module pv_rom #(
    parameter AW   = 11,
    parameter DW   = 16,
    parameter INIT = ""
)(
    input  wire          clk,
    input  wire [AW-1:0] addr,
    output reg  [DW-1:0] dout
);
    (* rom_style = "block" *) reg [DW-1:0] mem [0:(1<<AW)-1];

    initial begin
        $readmemh(INIT, mem);
        dout = {DW{1'b0}};
    end

    always @(posedge clk) dout <= mem[addr];
endmodule
`default_nettype wire
