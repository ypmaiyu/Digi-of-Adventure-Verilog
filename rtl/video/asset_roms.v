// asset_roms.v - the picture ROMs (Block RAM, initialised from fpga/mem/*.mem).
`timescale 1ns / 1ps
module rom_sp #(
    parameter WIDTH = 8,
    parameter DEPTH = 1024,
    parameter AW    = 10,
    parameter FILE  = "rom_map.mem"
) (
    input  wire             clk,
    input  wire [AW-1:0]    addr,
    output reg  [WIDTH-1:0] q
);
    (* rom_style = "block" *) reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [WIDTH-1:0] q1;
    initial $readmemh(FILE, mem);
    always @(posedge clk) begin
        q1 <= mem[addr];
        q  <= q1;
    end
endmodule

module asset_roms (
    input  wire        clk,
    input  wire [16:0] p4_addr,  output wire [3:0]  p4_q,
    input  wire [17:0] vqi_addr, output wire [8:0]  vqi_q,
    input  wire [16:0] cb_addr,  output wire [7:0]  cb_q,
    input  wire [12:0] pal_addr, output wire [11:0] pal_q,
    input  wire [13:0] map_addr, output wire [7:0]  map_q
);
`include "rom_sizes.vh"
    rom_sp #(.WIDTH(4),  .DEPTH(P4_DEPTH),  .AW(17), .FILE("rom_p4.mem"))  u_p4  (.clk(clk), .addr(p4_addr),  .q(p4_q));
    rom_sp #(.WIDTH(9),  .DEPTH(VQI_DEPTH), .AW(18), .FILE("rom_vqi.mem")) u_vqi (.clk(clk), .addr(vqi_addr), .q(vqi_q));
    rom_sp #(.WIDTH(8),  .DEPTH(CB_DEPTH),  .AW(17), .FILE("rom_cb.mem"))  u_cb  (.clk(clk), .addr(cb_addr),  .q(cb_q));
    rom_sp #(.WIDTH(12), .DEPTH(PAL_DEPTH), .AW(13), .FILE("rom_pal.mem")) u_pal (.clk(clk), .addr(pal_addr), .q(pal_q));
    rom_sp #(.WIDTH(8),  .DEPTH(MAP_DEPTH), .AW(14), .FILE("rom_map.mem")) u_map (.clk(clk), .addr(map_addr), .q(map_q));
endmodule