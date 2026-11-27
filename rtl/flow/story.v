// story.v - the picture scenes between the stages:
//   SC_OPEN : title + opening slides 1..6 (open.py)
//   SC_C12  : cutscene 1->2, one slowly zooming picture with captions (cutscene_1_2.py)
//   SC_C23  : cutscene 2->3, three slides (cutscene_2_3.py)
//   SC_END  : graduation summary + career ending picture (cutscene_ending.py)
// Times are counted in video frames (60 per second) exactly like Pygame's dt sums.
// Buttons: BTNC tap / BTNR = next, BTNL = back, BTND or BTNC hold = skip (Pygame Esc).
`timescale 1ns / 1ps
module story (
    input  wire         clk,
    input  wire         rst,
    input  wire         active,
    input  wire         start,
    input  wire [2:0]   scene,            // 0 OPEN, 2 C12, 4 C23, 6 END (game_flow numbering)
    input  wire         frame,
    input  wire [4:0]   ev_press,
    input  wire         ev_tap,
    input  wire         ev_back,
    // hand-off data the ending needs
    input  wire [1:0]   hearts,
    input  wire [1:0]   form,
    input  wire [1:0]   career,
    input  wire [7:0]   backs,            // up to 4 picked card positions, [1:0] first
    input  wire [2:0]   n_backs,
    // demo hooks (cutscene_ending do_action / jump_to)
    input  wire         dbg_end,
    input  wire [3:0]   dbg_end_num,
    input  wire         dbg_end_step,
    input  wire         dbg_end_step_val,
    output reg          done,             // finished (go to the next scene / new game)
    // video
    input  wire [7:0]   obj_idx,
    output reg  [127:0] obj_desc,
    output reg  [95:0]  prog_list,
    input  wire [7:0]   fld_id,
    input  wire [6:0]   fld_idx,
    output reg  [7:0]   fld_char,
    output reg  [15:0]  fld_val,
    input  wire [7:0]   cond_id,
    output reg          cond_val,
    output reg  [63:0]  seg_text
);
`include "asset_ids.vh"
`include "ui_ids.vh"
`include "sprite_place.vh"
`include "desc.vh"
`include "confetti.vh"
`include "strutil.vh"
    localparam SC_OPEN = 3'd0, SC_C12 = 3'd2, SC_C23 = 3'd4, SC_END = 3'd6;
    localparam B_U = 0, B_D = 1, B_L = 2, B_R = 3, B_C = 4;
    wire ev_next = ev_tap | ev_press[B_R];
    wire ev_prev = ev_press[B_L];
    wire ev_skip = ev_press[B_D] | ev_back;

    reg [2:0]  idx, prev;                  // current / previous page
    reg        has_prev;
    reg [5:0]  fade;                       // frames since the page changed
    reg [15:0] t;                          // frames since start
    reg        step;                       // ending: 0 summary, 1 reveal
    reg [7:0]  step_t;                     // ending: frames on this step
    reg        confirm, choice;
    reg [3:0]  end_num;
    reg [1:0]  e_car, most;
    reg [2:0]  cnt0, cnt1, cnt2;

    // ---------------- resolve_ending(): most picked card position (ties -> picked last) ----------------
    reg [2:0] c0, c1, c2; reg [2:0] l0, l1, l2; reg [1:0] mp; integer k;
    always @(*) begin
        c0 = 0; c1 = 0; c2 = 0; l0 = 0; l1 = 0; l2 = 0;
        for (k = 0; k < 4; k = k + 1)
            if (k < n_backs) begin
                case (backs[2*k +: 2])
                    2'd0: begin c0 = c0 + 1; l0 = k + 1; end
                    2'd1: begin c1 = c1 + 1; l1 = k + 1; end
                    default: begin c2 = c2 + 1; l2 = k + 1; end
                endcase
            end
        mp = 2'd0;
        if (c1 > c0 || (c1 == c0 && l1 > l0)) mp = 2'd1;
        if ((c2 > ((mp == 1) ? c1 : c0)) || (c2 == ((mp == 1) ? c1 : c0) && l2 > ((mp == 1) ? l1 : l0))) mp = 2'd2;
        if (n_backs == 0) mp = 2'd1;
    end
    // ENDING_MAP: green (3,1,2), yellow (4,5,6), red (7,8,9)
    function [3:0] ending_of; input [1:0] car; input [1:0] pos;
        case ({car, pos})
            4'b0000: ending_of = 3; 4'b0001: ending_of = 1; 4'b0010: ending_of = 2;
            4'b0100: ending_of = 4; 4'b0101: ending_of = 5; 4'b0110: ending_of = 6;
            4'b1000: ending_of = 7; 4'b1001: ending_of = 8; default: ending_of = 9;
        endcase
    endfunction

    // ---------------- confetti positions (updated once per frame) ----------------
    reg [15:0] cy_acc [0:41];              // UI px, 10.6 fixed, kept in 0..560
    reg signed [11:0] cx_r [0:41], cy_r [0:41];
    reg [15:0] gphase;                     // sin phase, 8.8 fixed (256 = 2 pi)
    reg [5:0]  ci;
    reg        cbusy, cinit;
    reg [1:0]  c_ph;
    reg [15:0] cy_tmp;
    reg [16:0] cf_step_r;
    reg [49:0] cf_r;
    integer    kk;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            idx <= 0; prev <= 0; has_prev <= 0; fade <= 6'd63; t <= 0; step <= 0; step_t <= 0;
            confirm <= 0; choice <= 0; end_num <= 4'd5; e_car <= 0; most <= 1; cbusy <= 0; c_ph <= 0; cinit <= 0; gphase <= 0;
        end else if (start) begin
            idx <= 0; prev <= 0; has_prev <= 0; t <= 0; step <= 0; step_t <= 0; confirm <= 0; choice <= 0;
            fade <= (scene == SC_C12) ? 6'd0 : 6'd63;           // C12 fades in; others start opaque
            if (scene == SC_END) fade <= 6'd0;
            e_car <= career; most <= mp; end_num <= ending_of(career, mp);
            cnt0 <= c0; cnt1 <= c1; cnt2 <= c2;
            gphase <= 0; ci <= 6'd0; cbusy <= 1'b1; c_ph <= 2'd0; cinit <= 1'b1;
            for (kk = 0; kk < 42; kk = kk + 1) cy_acc[kk] <= {(confetti(kk) >> 30) & 50'h3FF, 6'd0};   // y0
        end else if (dbg_end) begin                              // do_action("end_N")
            end_num <= dbg_end_num;
            e_car <= (dbg_end_num <= 3) ? 2'd0 : (dbg_end_num <= 6) ? 2'd1 : 2'd2;
            most  <= (dbg_end_num == 3 || dbg_end_num == 4 || dbg_end_num == 7) ? 2'd0 :
                     (dbg_end_num == 1 || dbg_end_num == 5 || dbg_end_num == 8) ? 2'd1 : 2'd2;
            step <= 1'b1; step_t <= 8'd72; fade <= 6'd0; confirm <= 1'b0; choice <= 1'b0;
        end else if (dbg_end_step) begin                         // jump_to("grad" / "reveal")
            step <= dbg_end_step_val; step_t <= dbg_end_step_val ? 8'd72 : 8'd0; fade <= 6'd0; confirm <= 1'b0; choice <= 1'b0;
        end else if (active && frame) begin
            t <= t + 16'd1;
            if (fade != 6'd63) fade <= fade + 6'd1;
            if (step_t != 8'hFF) step_t <= step_t + 8'd1;
            gphase <= gphase + 16'd348;                          // 2 rad/s
            ci <= 6'd0; cbusy <= 1'b1; c_ph <= 2'd0; cinit <= 1'b0;
            case (scene)
            SC_OPEN: begin                                       // open.py update()
                if (ev_skip) done <= 1'b1;
                else if (ev_prev) begin
                    if (idx != 0) begin prev <= idx; has_prev <= 1'b1; idx <= idx - 3'd1; fade <= 6'd0; end
                end else if (ev_next) begin
                    if (idx == 3'd6 && fade >= 6'd27) done <= 1'b1;            // on_last -> enter()
                    else if (fade < 6'd27) fade <= 6'd63;                       // FADE_S 0.45 s
                    else if (idx != 3'd6) begin prev <= idx; has_prev <= 1'b1; idx <= idx + 3'd1; fade <= 6'd0; end
                end
            end
            SC_C12: begin                                        // cutscene_1_2 update()
                if (ev_skip) done <= 1'b1;
                else if (ev_next) begin
                    if (t < 16'd36) t <= 16'd36;                                // FADE_S 0.6 s
                    else if (idx != 3'd2) idx <= idx + 3'd1;
                    else done <= 1'b1;
                end
            end
            SC_C23: begin                                        // cutscene_2_3 update()
                if (ev_skip) done <= 1'b1;
                else if (ev_prev && idx != 0) begin prev <= idx; has_prev <= 1'b1; idx <= idx - 3'd1; fade <= 6'd0; end
                else if (ev_next) begin
                    if (fade < 6'd24) fade <= 6'd63;                            // FADE_S 0.4 s
                    else if (idx != 3'd2) begin prev <= idx; has_prev <= 1'b1; idx <= idx + 3'd1; fade <= 6'd0; end
                    else done <= 1'b1;
                end
            end
            default: begin                                       // cutscene_ending update()
                if (!step) begin
                    if (ev_press[B_D]) begin step <= 1'b1; step_t <= 0; fade <= 0; confirm <= 0; choice <= 0; end
                    else if (ev_tap || ev_press[B_R]) begin
                        if (fade < 6'd27) fade <= 6'd63;
                        else begin step <= 1'b1; step_t <= 0; fade <= 0; confirm <= 0; choice <= 0; end
                    end
                end else if (confirm) begin
                    if (ev_press[B_L] || ev_press[B_R]) choice <= !choice;
                    else if (ev_back || ev_press[B_D]) begin confirm <= 0; choice <= 0; end
                    else if (ev_tap) begin
                        if (choice) done <= 1'b1;                                // Play Again
                        else begin confirm <= 0; choice <= 0; end
                    end
                end else if (ev_back || ev_press[B_L]) begin
                    step <= 1'b0; step_t <= 0; fade <= 0; confirm <= 0;
                end else if (step_t >= 8'd72 && (ev_tap || ev_press[B_D])) begin  // REVEAL_LOCK_S 1.2 s
                    confirm <= 1'b1; choice <= 1'b0;
                end
            end
            endcase
        end else if (cbusy) begin : blk_cf                      // advance confetti in 3-stage pipeline (meets 74.25 MHz)
            reg [16:0] cf_sum;
            reg signed [11:0] cx_w;
            if (c_ph == 2'd0) begin
                cy_tmp    <= cy_acc[ci];
                cf_r      <= confetti(ci);
                cf_step_r <= cinit ? 17'd0 : ((((confetti(ci) >> 23) & 17'h7F) * 17'd69905) >> 16);
                c_ph      <= 2'd1;
            end else if (c_ph == 2'd1) begin
                cf_sum = {1'b0, cy_tmp} + cf_step_r;
                if (!cinit) cy_acc[ci] <= (cf_sum >= 17'd35840) ? (cf_sum - 17'd35840) : cf_sum[15:0];
                cy_tmp <= (cf_sum >= 17'd35840) ? (cf_sum - 17'd35840) : cf_sum[15:0];
                cx_w = $signed({2'b0, cf_r[49:40]}) + sin_tab(cf_r[7:0] + gphase[15:8]);
                cx_r[ci] <= (cx_w < 0) ? cx_w + 12'sd640 : (cx_w >= 12'sd640) ? cx_w - 12'sd640 : cx_w;
                c_ph <= 2'd2;
            end else begin
                cy_r[ci] <= $signed({1'b0, (cy_tmp[15:6] * 12'd1366) >> 11}) - 12'sd7;
                c_ph <= 2'd0;
                if (ci == 6'd41) begin cbusy <= 1'b0; cinit <= 1'b0; end
                ci <= ci + 6'd1;
            end
        end
    end

    // ------------------------------------------------------------------ pictures
    function [7:0] open_page; input [2:0] i;
        case (i) 0: open_page = A_ST_TITLE; 1: open_page = A_ST_1; 2: open_page = A_ST_2; 3: open_page = A_ST_3;
                 4: open_page = A_ST_4; 5: open_page = A_ST_5; default: open_page = A_ST_6; endcase
    endfunction
    function [7:0] c23_page; input [2:0] i;
        case (i) 0: c23_page = A_ST_CUT23_1; 1: c23_page = A_ST_CUT23_2; default: c23_page = A_ST_CUT23_3; endcase
    endfunction
    function [7:0] end_char_pic; input [3:0] e;
        case (e) 1: end_char_pic = A_ST_END_CHAR1; 2: end_char_pic = A_ST_END_CHAR2; 3: end_char_pic = A_ST_END_CHAR3;
                 4: end_char_pic = A_ST_END_CHAR4; 5: end_char_pic = A_ST_END_CHAR5; 6: end_char_pic = A_ST_END_CHAR6;
                 7: end_char_pic = A_ST_END_CHAR7; 8: end_char_pic = A_ST_END_CHAR8; default: end_char_pic = A_ST_END_CHAR9; endcase
    endfunction
    function [7:0] end_text_pic; input [3:0] e;
        case (e) 1: end_text_pic = A_ST_END_TEXT1; 2: end_text_pic = A_ST_END_TEXT2; 3: end_text_pic = A_ST_END_TEXT3;
                 4: end_text_pic = A_ST_END_TEXT4; 5: end_text_pic = A_ST_END_TEXT5; 6: end_text_pic = A_ST_END_TEXT6;
                 7: end_text_pic = A_ST_END_TEXT7; 8: end_text_pic = A_ST_END_TEXT8; default: end_text_pic = A_ST_END_TEXT9; endcase
    endfunction
    function [127:0] full_pic; input [7:0] a; input dith;
        begin
            full_pic = obj_img(0, 0, 640, 360, a, 19'd0, 18'd0, 10'd128, 10'd128, 1'b0);
            full_pic[126] = dith;
        end
    endfunction
    // cross fade: previous picture, then the new one dithered in the middle third
    wire [5:0] fade_len = (scene == SC_C23) ? 6'd24 : 6'd27;
    wire       fading   = has_prev && fade < fade_len;
    wire       show_new = !fading || (fade * 3 >= fade_len);
    wire       dith_new = fading && (fade * 3 < fade_len * 2);

    function [9:0] zst_of; input [5:0] off;
        case (off)
            6'd0: zst_of = 10'd128;
            6'd1, 6'd2, 6'd3, 6'd4, 6'd5: zst_of = 10'd127;
            6'd6, 6'd7, 6'd8, 6'd9, 6'd10: zst_of = 10'd126;
            6'd11, 6'd12, 6'd13, 6'd14, 6'd15: zst_of = 10'd125;
            6'd16, 6'd17, 6'd18, 6'd19, 6'd20: zst_of = 10'd124;
            6'd21, 6'd22, 6'd23, 6'd24, 6'd25, 6'd26: zst_of = 10'd123;
            6'd27, 6'd28, 6'd29, 6'd30, 6'd31: zst_of = 10'd122;
            6'd32, 6'd33, 6'd34, 6'd35, 6'd36, 6'd37: zst_of = 10'd121;
            6'd38, 6'd39, 6'd40, 6'd41, 6'd42: zst_of = 10'd120;
            6'd43, 6'd44, 6'd45, 6'd46, 6'd47, 6'd48: zst_of = 10'd119;
            default: zst_of = 10'd118;
        endcase
    endfunction

    // slow zoom + fade + blink signals, registered one cycle after t/fade update (eliminates combinational dividers)
    wire [15:0] zt      = (t > 16'd720) ? 16'd720 : t;
    wire [5:0]  zw_off  = (zt * 16'd4643) >> 16;          // 0..51
    wire [5:0]  zh_off  = (zt * 16'd2640) >> 16;          // 0..29
    reg  [9:0]  zw_r, zh_r, zst_r;
    reg  signed [10:0] c12_dx_r;
    reg  signed [9:0]  c12_dy_r;
    reg  [3:0]  c12_fade_r, fade_alpha_r;
    reg  signed [4:0]  bob_r;
    reg  [10:0] t_div30_r, t_open_r;
    reg  [7:0]  bob_ph_r;

    always @(posedge clk) begin
        if (rst || start) begin
            zw_r         <= 10'd640;
            zh_r         <= 10'd360;
            zst_r        <= 10'd128;
            c12_dx_r     <= 11'sd0;
            c12_dy_r     <= 10'sd0;
            c12_fade_r   <= 4'd15;
            fade_alpha_r <= (scene == SC_END || (start && scene == SC_C12)) ? 4'd15 : 4'd0;
            bob_ph_r     <= 8'd0;
            bob_r        <= 5'sd0;
            t_div30_r    <= 11'd0;
            t_open_r     <= 11'd0;
        end else begin
            zw_r         <= 10'd640 + {4'd0, zw_off};
            zh_r         <= 10'd360 + {4'd0, zh_off};
            zst_r        <= zst_of(zw_off);
            c12_dx_r     <= (11'sd640 - $signed({1'b0, 10'd640 + {4'd0, zw_off}})) >>> 1;
            c12_dy_r     <= (10'sd360 - $signed({1'b0, 10'd360 + {4'd0, zh_off}})) >>> 1;
            c12_fade_r   <= (t >= 16'd36) ? 4'd0 : (4'd15 - ((t[5:0] * 12'd1707) >> 12));
            fade_alpha_r <= (fade >= 6'd27) ? 4'd0 : (4'd15 - ((fade * 12'd2276) >> 12));
            bob_ph_r     <= (t[7:0] << 1) + ((t * 17'd2427) >> 16);
            bob_r        <= sin_tab(bob_ph_r) >>> 2;
            t_div30_r    <= (t * 19'd8739) >> 18;
            t_open_r     <= (t * 18'd3495) >> 17;
        end
    end

    wire [3:0]  fade_alpha = fade_alpha_r;
    wire [7:0]  grad_asset = A_PL_F2_FRONT_STAND;
    wire [49:0] gp = place_grad(grad_asset);
    wire signed [4:0] bob  = bob_r;
    function [7:0] back_of; input [1:0] car; input [1:0] pos;
        case ({car, pos})
            4'b0000: back_of = C_AIR_CARD1; 4'b0001: back_of = C_AIR_CARD2; 4'b0010: back_of = C_AIR_CARD3;
            4'b0100: back_of = C_EARTH_CARD1; 4'b0101: back_of = C_EARTH_CARD2; 4'b0110: back_of = C_EARTH_CARD3;
            4'b1000: back_of = C_WATER_CARD1; 4'b1001: back_of = C_WATER_CARD2; default: back_of = C_WATER_CARD3;
        endcase
    endfunction
    wire [1:0]  spos = obj_idx[1:0];
    wire [7:0]  sback = back_of(e_car, spos);
    wire [49:0] sp84 = place_card84(sback);
    // slot x (UI) = 342 + pos*158, width 138 -> centre 411 + pos*158 (scaled 2/3 -> 274, 379, 484)
    wire signed [11:0] s_cx = (spos == 2'd0) ? 12'sd274 : (spos == 2'd1) ? 12'sd379 : 12'sd484;
    wire signed [11:0] e_slot_x = (obj_idx[1:0] == 2'd1) ? 12'sd228 : (obj_idx[1:0] == 2'd2) ? 12'sd333 : 12'sd438;

    // confetti object k (pre-computed in cx_r/cy_r during cbusy)
    wire [5:0]  ck = obj_idx[5:0] - 6'd4;
    wire [49:0] cf = confetti(ck);
    wire signed [11:0] c_x = cx_r[ck];
    wire signed [11:0] c_y = cy_r[ck];
    wire [7:0]  ec_id = end_char_pic(end_num);
    wire [7:0]  et_id = end_text_pic(end_num);
    wire [49:0] ep_c  = place_end_char(end_num);
    wire [49:0] ep_t  = place_end_text(end_num);

    always @(*) begin
        obj_desc = OBJ_NONE;
        if (obj_idx[7:6] == 2'd0) case (scene)
        SC_OPEN: case (obj_idx[5:0])
            6'd0: obj_desc = obj_fill(0, 0, 640, 360, 12'h000, 1'b0);
            6'd1: if (fading) obj_desc = full_pic(open_page(prev), 1'b0);
            6'd2: if (show_new) obj_desc = full_pic(open_page(idx), dith_new);
            default: ;
        endcase
        SC_C12: case (obj_idx[5:0])
            6'd0: obj_desc = obj_fill(0, 0, 640, 360, 12'h112, 1'b0);
            6'd1: obj_desc = obj_img(c12_dx_r, c12_dy_r, zw_r, zh_r, A_ST_CUTSCENE1_2, 19'd0, 18'd0, zst_r, zst_r, 1'b0);
            6'd2: if (c12_fade_r != 0) obj_desc = obj_blend(0, 0, 640, 360, 12'h000, c12_fade_r);
            6'd3: obj_desc = obj_blend(27, 250, 587, 83, 12'h112, 4'd14);       // caption panel (alpha 220)
            default: ;
        endcase
        SC_C23: case (obj_idx[5:0])
            6'd0: obj_desc = obj_fill(0, 0, 640, 360, 12'h112, 1'b0);
            6'd1: if (fading) obj_desc = full_pic(c23_page(prev), 1'b0);
            6'd2: if (show_new) obj_desc = full_pic(c23_page(idx), dith_new);
            6'd3: obj_desc = obj_blend(0, 326, 640, 26, 12'h112, 4'd13);         // bottom bar (alpha 205)
            6'd4: obj_desc = obj_fill(0, 326, 640, 1, 12'h568, 1'b0);
            default: ;
        endcase
        default: if (!step) case (obj_idx[5:0])                       // graduation summary
            6'd0: obj_desc = obj_fill(0, 0, 640, 120, 12'h112, 1'b0);              // dark blue gradient
            6'd1: obj_desc = obj_fill(0, 120, 640, 120, 12'h123, 1'b0);
            6'd2: obj_desc = obj_fill(0, 240, 640, 120, 12'h224, 1'b0);
            6'd46: obj_desc = obj_blend(73, 95, 493, 200, 12'h112, 4'd14);         // box (alpha 225)
            6'd47: obj_desc = obj_fill(92, 117, 113, 140, 12'h223, 1'b0);          // portrait
            6'd48: obj_desc = obj_img(149 + $signed(gp[49:39]), 187 + bob + $signed(gp[38:29]), gp[28:19], gp[18:10],
                                      grad_asset, 19'd0, 18'd0, gp[9:0], gp[9:0], 1'b0);
            6'd49, 6'd50, 6'd51: obj_desc = obj_fill(e_slot_x, 163, 92, 93,
                                                     (most == obj_idx[1:0] - 2'd1) ? 12'h335 : 12'h123, 1'b0);
            6'd52, 6'd53, 6'd54: obj_desc = obj_img(s_cx + $signed(sp84[49:39]), 197 + $signed(sp84[38:29]),
                                                    sp84[28:19], sp84[18:10], sback, 19'd0, 18'd0, sp84[9:0], sp84[9:0], 1'b0);
            6'd55: if (fade_alpha != 0) obj_desc = obj_blend(0, 0, 640, 360, 12'h000, fade_alpha);
            default: if (obj_idx[5:0] >= 6'd4 && obj_idx[5:0] < 6'd46)
                         obj_desc = obj_fill(c_x, c_y, cf[22:20], cf[22:20], cf[19:8], 1'b0);
        endcase else case (obj_idx[5:0])                              // ending reveal
            6'd0: obj_desc = obj_img(11'sd0, 10'sd0, 10'd640, 9'd360, A_ST_END_BG, 19'd0, 18'd0, 10'd256, 10'd256, 1'b0);
            6'd1: obj_desc = obj_img($signed(ep_c[49:39]), $signed(ep_c[38:29]), ep_c[28:19], ep_c[18:10], ec_id, 19'd0, 18'd0, 10'd256, 10'd256, 1'b0);
            6'd2: obj_desc = obj_img($signed(ep_t[49:39]), $signed(ep_t[38:29]), ep_t[28:19], ep_t[18:10], et_id, 19'd0, 18'd0, 10'd256, 10'd256, 1'b0);
            6'd3: if (step_t >= 8'd72 && !confirm) obj_desc = obj_blend(197, 334, 247, 16, 12'h112, 4'd12);
            6'd4: if (confirm) obj_desc = obj_blend(0, 0, 640, 360, 12'h000, 4'd10);
            6'd5: if (fade_alpha != 0) obj_desc = obj_blend(0, 0, 640, 360, 12'h000, fade_alpha);
            default: ;
        endcase
        endcase
    end

    // ------------------------------------------------------------------ text
    reg [95:0] pl; integer np;
    task push_prog; input [7:0] id; begin pl = pl | ({88'd0, id} << (8 * np)); np = np + 1; end endtask
    always @(*) begin
        pl = 96'd0; np = 0;
        push_prog(P_BAR_TOP); push_prog(P_BAR_BOTTOM);
        case (scene)
            SC_OPEN: if (idx != 0) begin
                if (idx == 3'd6 && fade >= 6'd27) push_prog(P_OPEN_ENTER);
                else if (idx == 3'd6) push_prog(P_OPEN_PAGENO);
                else push_prog(P_OPEN_HINT);
            end
            SC_C12: push_prog(P_C12_BOX);
            SC_C23: push_prog(P_C23_BAR);
            default: begin
                push_prog(P_END_BAR);
                if (!step) push_prog(P_END_GRAD);
                else if (confirm) push_prog(P_END_CONFIRM);
                else if (step_t >= 8'd72) push_prog(P_END_PILL);
            end
        endcase
        prog_list = pl;
    end

    wire [2:0] cnt_of = (fld_id == F_END_SLOT0) ? cnt0 : (fld_id == F_END_SLOT1) ? cnt1 : cnt2;
    always @(*) begin
        fld_val = 16'd0; fld_char = 8'd0;
        case (fld_id)
            F_BAR_TITLE: fld_val = (scene == SC_OPEN) ? T_BAR_TITLE_OPEN : (scene == SC_C12) ? T_BAR_TITLE_C12 :
                                   (scene == SC_C23) ? T_BAR_TITLE_C23 : T_BAR_TITLE_END;
            F_BAR_HELP:  fld_val = (scene == SC_OPEN) ? T_BAR_HELP_OPEN : (scene == SC_END) ? T_BAR_HELP_END : T_BAR_HELP_CUT;
            F_FORM:      fld_val = form;
            F_OPEN_PAGE: fld_val = idx - 3'd1;
            F_C12_IDX:   fld_val = idx;
            F_C23_IDX:   fld_val = idx;
            F_END_CAREER: fld_val = e_car;
            F_END_SLOT0, F_END_SLOT1, F_END_SLOT2:
                fld_val = e_car * 15 + ((fld_id == F_END_SLOT0) ? 0 : (fld_id == F_END_SLOT1) ? 5 : 10) +
                          ((cnt_of > 4) ? 4 : cnt_of);
            F_END_MOST:  fld_val = e_car * 3 + most;
            F_END_NUM:   fld_val = end_num - 4'd1;
            default: ;
        endcase
    end
    always @(*) begin
        case (cond_id)
            C_OPEN_BLINK:  cond_val = !t_open_r[0];
            C_OPEN_HOVER:  cond_val = 1'b0;
            C_C12_PROMPT:  cond_val = !t_div30_r[0] || idx == 3'd2;
            C_C12_LAST:    cond_val = idx == 3'd2;
            C_C23_PROMPT:  cond_val = !t_div30_r[0] || idx == 3'd2;
            C_C23_LAST:    cond_val = idx == 3'd2;
            C_END_CAR0:    cond_val = e_car == 0;
            C_END_CAR1:    cond_val = e_car == 1;
            C_END_CAR2:    cond_val = e_car == 2;
            C_END_TOP0:    cond_val = most == 0;
            C_END_TOP1:    cond_val = most == 1;
            C_END_TOP2:    cond_val = most == 2;
            C_END_BLINK:   cond_val = !t_div30_r[0];
            C_END_CHOICE0: cond_val = !choice;
            C_END_CHOICE1: cond_val = choice;
            default:       cond_val = 1'b0;
        endcase
    end
    always @(*) begin
        case (scene)
            SC_OPEN: seg_text = {"H", "0" + hearts, "  OPEn"};
            SC_C12:  seg_text = {"H", "0" + hearts, " CUt12"};
            SC_C23:  seg_text = {"H", "0" + hearts, " CUt23"};
            default: seg_text = {"H", "0" + hearts, " End-", "0" + end_num};
        endcase
    end
endmodule
