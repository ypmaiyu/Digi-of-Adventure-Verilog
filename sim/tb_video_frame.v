// tb_video_frame.v - renders frames of a fixed test scene and writes them to frame_N.hex
// (one RGB444 pixel per line, 640x480). tools/hex2png.py turns them into PNG pictures.
`timescale 1ns / 1ps
module tb_video_frame;
`include "asset_ids.vh"
`include "ui_ids.vh"
`include "desc.vh"
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    wire [5:0] obj_idx; reg [127:0] obj_desc;
    wire [7:0] fld_id, cond_id; wire [6:0] fld_idx; reg [7:0] fld_char; reg [15:0] fld_val; reg cond_val;
    wire [3:0] r, g, b; wire hs, vs; wire frame_tick, vblank;
    video_core dut (.clk(clk), .rst(rst), .frame_tick(frame_tick), .vblank(vblank), .obj_idx(obj_idx), .obj_desc(obj_desc),
        .vmap_en(1'b0), .prog_list({72'd0, P_S1_INTRO, P_S1_SEARCH, P_HUD}), .fld_id(fld_id), .fld_idx(fld_idx), .fld_char(fld_char),
        .fld_val(fld_val), .cond_id(cond_id), .cond_val(cond_val), .vga_r(r), .vga_g(g), .vga_b(b), .vga_hs(hs), .vga_vs(vs));
    // scene: room background (camera 300,100 view px), player, TA guide, test tint box
    always @(*) begin
        case (obj_idx)
            6'd0: obj_desc = obj_img(0, 0, 640, 360, A_BG_ROOM, 19'd300 * 128, 18'd100 * 128, 10'd128, 10'd128, 1'b0);
            6'd1: obj_desc = obj_img(300, 150, 35, 56, A_PL_F0_FRONT_STAND, 0, 0, 10'd134, 10'd134, 1'b0);
            6'd2: obj_desc = obj_img(360, 150, 31, 56, A_PL_F1_RIGHT_STEPL, 0, 0, 10'd134, 10'd134, 1'b1);
            6'd3: obj_desc = obj_img(420, 140, 34, 61, A_NPC_TA, 0, 0, 10'd128, 10'd128, 1'b0);
            6'd4: obj_desc = obj_blend(20, 20, 100, 60, 12'h00F, 4'd8);
            6'd5: obj_desc = obj_img(480, 40, 64, 64, A_CARD_AIR_R1, 0, 0, 10'd128, 10'd128, 1'b0);
            default: obj_desc = OBJ_NONE;
        endcase
    end
    always @(*) begin
        cond_val = (cond_id == C_HEART0) || (cond_id == C_HEART1) || (cond_id == C_ARMOR);
        fld_val = 16'd0;
        fld_char = (fld_id == F_ARMOR_N && fld_idx == 0) ? "2" : 8'd0;
    end
    integer f, frames = 0;
    reg dumping = 0;
    always @(posedge clk) begin
        if (frame_tick) begin
            frames = frames + 1;
            $display("frame_tick %0d at %0t", frames, $time);
        end
        if (dut.pix_ce && dut.hc == 799 && dut.vc == 524) begin
            if (dumping) begin $fclose(f); dumping = 0; if (frames >= 2) $finish; end
            if (frames >= 1) begin f = $fopen("frame.hex", "w"); dumping = 1; end
        end
        // the output register shows pixel (hc-1); log active pixels as they leave
        if (dumping && dut.pix_ce && dut.active) $fwrite(f, "%h%h%h\n", dut.px[11:8], dut.px[7:4], dut.px[3:0]);
    end
    initial begin
        #100 rst = 0;
        #60000000 $display("timeout"); $finish;
    end
endmodule
