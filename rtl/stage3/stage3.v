// stage3.v - STAGE 3: GRADUATION RUN, the obby (port of onlystage_3/game.py + render.py + hud.py).
//
// Three sub-levels (S6->S4, S4->CB2, N17->N16), each 250 x 11 tiles. Physics runs at the
// Pygame fixed tick of 1/120 s (two steps per 60 Hz video frame), in Q16.16 fixed point,
// units = tiles ("metres", y grows upwards like the Python code):
//   run 5 tiles/s, jump 2.5 tiles high in 0.7 s (gravity 8*2.5/0.7^2), coyote time 0.15 s,
//   jump buffer 0.15 s, double jump to 4.5 tiles inside the 1.2 s window (gravity and speed
//   solved with a square root and a division, exactly like try_jump()), 120 s per attempt.
// Collision uses per-column bit masks of the solid / water tiles (rtl/gen/s3_tables.vh,
// generated from the game's own level files), so it never reads picture data.
// Animals (patrol / walk / pop / fly, leaders + followers), the reporter (chase, interview,
// cloak, retreat), the skills (Cloak in levels 1-2, Phase in level 3), the ? block and milk
// tea (level 2) and the two lifts (level 3) are simulated here.
//
// Simplifications (listed in docs/PORTING_NOTES.md): the reporter keeps a fixed delay
// behind the player instead of searching for a free standing spot, its retreat walks straight
// away instead of replaying the trail, and snowfall / footprints / wind / sparkles are not drawn.
`timescale 1ns / 1ps
module stage3 (
    input  wire         clk,
    input  wire         rst,
    input  wire         active,
    input  wire         start,
    input  wire         frame,
    input  wire [4:0]   lvl,
    input  wire [4:0]   ev_press,
    input  wire         ev_tap,
    input  wire         ev_back,
    input  wire [1:0]   hi_hearts,
    input  wire [1:0]   hi_form,
    input  wire         dbg_win,
    input  wire         dbg_jump,
    input  wire         dbg_part,
    input  wire         dbg_set_form,
    input  wire [1:0]   dbg_form,
    output reg          done,
    input  wire [7:0]   obj_idx,
    output reg  [127:0] obj_desc,
    output wire         vmap_en,
    output reg  [95:0]  prog_list,
    input  wire [7:0]   fld_id,
    input  wire [6:0]   fld_idx,
    output reg  [7:0]   fld_char,
    output reg  [15:0]  fld_val,
    input  wire [7:0]   cond_id,
    output reg          cond_val,
    output reg  [63:0]  seg_text,
    output reg  [15:0]  leds
);
`include "asset_ids.vh"
`include "ui_ids.vh"
`include "desc.vh"
`include "lfsr.vh"
`include "strutil.vh"
`include "s3_tables.vh"
`include "sprite_place.vh"
    assign vmap_en = 1'b1;
    localparam B_U = 0, B_D = 1, B_L = 2, B_R = 3, B_C = 4;
    // ---------------------------------------------------------------- constants (Q16.16 tiles)
    localparam signed [31:0] ONE = 32'sd65536, HALF = 32'sd32768, NONE = 32'sh7FFFFFFF;
    localparam signed [31:0] PW2 = 32'sd20644;            // PLAYER_WIDTH / 2 = 0.315
    localparam signed [31:0] PH  = 32'sd98304;            // PLAYER_HEIGHT 1.5
    localparam signed [31:0] G   = 32'sd2674891;          // 8 * 2.5 / 0.7^2 = 40.816
    localparam signed [31:0] V0  = 32'sd936229;           // G * 0.7 / 2
    localparam signed [31:0] RUN = 32'sd327680;           // 5 tiles/s
    localparam signed [31:0] DT  = 32'sd546;              // 1/120 s
    localparam [31:0] DT24 = 32'd139810;                  // 1/120 in Q24
    localparam [31:0] HDT2_32 = 32'd149131;               // 0.5/120^2 in Q32
    localparam signed [31:0] T015 = 32'sd9830, T112 = 32'sd73400, T12 = 32'sd78643;
    localparam signed [31:0] DH = 32'sd294912, DRANGE = 32'sd360448, SQRT_DH = 32'sd139023, R002 = 32'sd1311;
    localparam signed [31:0] ESPD = 32'sd1092;            // animals 2 tiles/s
    localparam signed [31:0] AH  = 32'sd56174;            // ANIMAL_HEIGHT 1.5 / 1.75
    localparam signed [31:0] LIFT_L0 = 32'sd162 <<< 16, LIFT_L1 = 32'sd207 <<< 16;
    localparam signed [31:0] Y3 = 32'sd3 <<< 16, Y5 = 32'sd5 <<< 16;
    localparam [13:0] STEPS_120S = 14'd14400, STEPS_5S = 14'd600, STEPS_2S = 14'd240;
    localparam [2:0] M_PLAY = 3'd0, M_PAUSE = 3'd1, M_CLEAR = 3'd2, M_WIN = 3'd3;
    localparam [1:0] MO_PATROL = 2'd0, MO_WALK = 2'd1, MO_POP = 2'd2, MO_FLY = 2'd3;

    // ---------------------------------------------------------------- helpers
    function signed [31:0] mulq; input signed [31:0] a, b; reg signed [63:0] p; begin p = a * b; mulq = p[47:16]; end endfunction
    function signed [31:0] fl; input signed [31:0] a; fl = a >>> 16; endfunction
    function signed [31:0] clampq; input signed [31:0] v, lo, hi; clampq = (v < lo) ? lo : (v > hi) ? hi : v; endfunction
    function signed [31:0] tq; input integer r; tq = r <<< 16; endfunction
    function signed [31:0] adt; input signed [31:0] v;                   // v * (1/120 s)
        reg signed [63:0] p; begin p = v * $signed({32'd0, DT24}); adt = p[55:24]; end endfunction
    function [10:0] solid_col; input [1:0] s; input signed [31:0] c;
        reg [21:0] m; begin
            if (c < 0 || c > 249) solid_col = 11'd0;
            else begin
                m = s3_col(s, c[7:0]);
                solid_col = m[10:0] | ((s == 2'd2 && c == 240) ? 11'b00000100000 : 11'd0);   // ? block at row 5
            end
        end endfunction
    function [10:0] water_col; input [1:0] s; input signed [31:0] c;
        reg [21:0] m; begin
            if (c < 0 || c > 249) water_col = 11'd0;
            else begin m = s3_col(s, c[7:0]); water_col = m[21:11]; end
        end endfunction
    function [10:0] rowmask; input signed [31:0] y0, y1;                  // rows touched by the open interval
        integer r; reg [10:0] m; begin
            m = 11'd0;
            for (r = 0; r < 11; r = r + 1)
                if (tq(r) < y1 - 1 && tq(r + 1) > y0 + 1) m[r] = 1'b1;
            rowmask = m;
        end endfunction
    function touches; input signed [31:0] ax, ay, aw, ah, bx, by, bw, bh;
        touches = (ax < bx + bw - 1) && (ax + aw > bx + 1) && (ay < by + bh - 1) && (ay + ah > by + 1);
    endfunction
    function [10:0] tops; input [10:0] m; tops = m & ~(m >> 1); endfunction   // bit r: surface at r+1
    // nearest surface top: kind 0 = |h-y| <= 1 (patrol), kind 1 = 0 < h-y <= 1 (step up)
    // Split into 2 pipeline stages (near_ab -> pick_ab) across U_EN2D -> U_EN2E to meet 74.25 MHz.
    function [129:0] near_ab; input [10:0] t; input signed [31:0] y; input kind;
        reg signed [5:0] k;
        reg signed [5:0] r0, r1, r2, r3;
        reg        ok0, ok1, ok2, ok3, okA, okB;
        reg signed [31:0] h0, h1, h2, h3, d0, d1, d2, d3, hA, dA, hB, dB;
        begin
            k = (y < -tq(1)) ? -6'sd4 : (y >= tq(12)) ? 6'sd15 : $signed(y[21:16]);
            r0 = k - 6'sd2; r1 = k - 6'sd1; r2 = k; r3 = k + 6'sd1;
            h0 = tq(r0 + 6'sd1); d0 = (h0 > y) ? (h0 - y) : (y - h0);
            h1 = tq(r1 + 6'sd1); d1 = (h1 > y) ? (h1 - y) : (y - h1);
            h2 = tq(r2 + 6'sd1); d2 = (h2 > y) ? (h2 - y) : (y - h2);
            h3 = tq(r3 + 6'sd1); d3 = (h3 > y) ? (h3 - y) : (y - h3);
            ok0 = (r0 >= 0 && r0 <= 10 && t[r0[3:0]]) && ((kind == 1'b0) ? (d0 <= ONE + 1) : (h0 > y && h0 - y <= ONE + 1));
            ok1 = (r1 >= 0 && r1 <= 10 && t[r1[3:0]]) && ((kind == 1'b0) ? (d1 <= ONE + 1) : (h1 > y && h1 - y <= ONE + 1));
            ok2 = (r2 >= 0 && r2 <= 10 && t[r2[3:0]]) && ((kind == 1'b0) ? (d2 <= ONE + 1) : (h2 > y && h2 - y <= ONE + 1));
            ok3 = (r3 >= 0 && r3 <= 10 && t[r3[3:0]]) && ((kind == 1'b0) ? (d3 <= ONE + 1) : (h3 > y && h3 - y <= ONE + 1));
            okA = ok0 | ok1;
            if (ok0 && (!ok1 || d0 <= d1)) begin hA = h0; dA = d0; end else begin hA = h1; dA = d1; end
            okB = ok2 | ok3;
            if (ok2 && (!ok3 || d2 <= d3)) begin hB = h2; dB = d2; end else begin hB = h3; dB = d3; end
            near_ab = {okA, hA, dA, okB, hB, dB};
        end endfunction
    function signed [31:0] pick_ab; input [129:0] p;
        reg okA, okB; reg signed [31:0] hA, dA, hB, dB;
        begin
            {okA, hA, dA, okB, hB, dB} = p;
            if (!okA && !okB) pick_ab = NONE;
            else if (okA && (!okB || dA <= dB)) pick_ab = hA;
            else pick_ab = hB;
        end endfunction
    // ant exposure (hidden 2 s, rise 1 s, above 2 s, fall 1 s) of an age in [0, 6) -> Q8
    function [8:0] pop_expo; input signed [31:0] age;
        reg signed [31:0] t, b, m; begin
            t = age - tq(2); b = tq(4) - t; m = (t < b) ? t : b;
            pop_expo = (m <= 0) ? 9'd0 : (m >= ONE) ? 9'd256 : {1'b0, m[15:8]};
        end endfunction

    // ---------------------------------------------------------------- state
    reg [1:0]  stg;
    reg [2:0]  mode;
    reg signed [31:0] px, py, vy, elapsed, takeoff, grav, spd, grace, buffer, stride, cam;
    reg        dir_r, grounded, walking;
    reg [1:0]  jumps;
    reg [13:0] remaining, clear_left, skill_t, interview, protection, retreat_t, cloak_t, notice_t;
    reg [6:0]  flash_t;
    reg        skill_used, chase, near_seen, opened, gold, tea_on, rep_vis, rep_walk, rep_dir;
    reg signed [31:0] tea_x, tea_y, tea_vy, rep_x, rep_y;
    reg [15:0] tea_grow_until, tsteps;
    reg [4:0]  msg, restart_msg;
    reg [3:0]  q0, q1;
    reg [15:0] lfsr;
    reg signed [31:0] lift_top0, lift_top1;
    reg        lift_up0;
    reg [3:0]  jump_req;
    reg        skill_req;
    // route of the player for the reporter (34 steps = REPORTER_DELAY 0.28 s)
    reg signed [31:0] rt_x [0:63];
    reg signed [31:0] rt_y [0:63];
    reg        rt_w [0:63];
    reg [5:0]  rt_wp, rt_n;
    // animals
    reg signed [31:0] a_x [0:47];
    reg signed [31:0] a_y [0:47];
    reg signed [31:0] a_vy [0:47];
    reg signed [31:0] a_age [0:47];
    reg signed [31:0] a_wl [0:47];          // pop: base height; walk: water level
    reg        a_dir [0:47];                 // 1 = moving right
    reg        a_act [0:47];
    reg        a_alive [0:47];
    reg        a_wat [0:47];
    reg [8:0]  a_expo [0:47];
    reg [7:0]  a_skin [0:47];
    reg [2:0]  fl_slot [0:47];
    reg [47:0] contacts, new_contacts;
    // followers: ring buffers of the leader position (0.5 s = 60 steps)
    reg signed [31:0] fl_x [0:511];
    reg signed [31:0] fl_y [0:511];
    reg        fl_d [0:511];
    reg [5:0]  fl_wp [0:7];
    reg [6:0]  fl_n [0:7];
    reg [2:0]  k_fl;
    // visible animals of this frame
    reg [5:0]  vis [0:23];
    reg [4:0]  n_vis;

    wire [5:0] n_anim = (stg == 2'd1) ? S3_NANIMALS_1 : (stg == 2'd2) ? S3_NANIMALS_2 : S3_NANIMALS_3;
    wire       phase_ab = (stg == 2'd3);
    wire signed [31:0] door_x = (stg == 2'd1) ? tq(245) : (stg == 2'd3) ? tq(246) : 32'sd16200499;   // 247.2
    wire signed [31:0] door_w = (stg == 2'd1) ? tq(5) : (stg == 2'd3) ? tq(4) : 32'sd98304;
    localparam signed [31:0] DOOR_Y = 32'sd131072, DOOR_H = 32'sd150733;                              // 2, 2.3
    wire signed [31:0] spawn_x = (stg == 2'd2) ? tq(5) : tq(6);
    localparam signed [31:0] SPAWN_Y = 32'sd196608;

    // ---------------------------------------------------------------- sqrt / divide unit
    reg        dv_go, dv_div, dv_busy;
    reg [63:0] dv_a, dv_q, dv_rem, dv_root;
    reg [31:0] dv_b;
    reg [6:0]  dv_i;
    always @(posedge clk) begin
        if (rst) dv_busy <= 1'b0;
        else if (dv_go) begin
            dv_busy <= 1'b1; dv_i <= 7'd0; dv_q <= 64'd0; dv_rem = 64'd0; dv_root = 64'd0;
        end else if (dv_busy) begin
            if (dv_div) begin                                   // restoring division a / b
                dv_rem = {dv_rem[62:0], dv_a[7'd63 - dv_i]};
                if (dv_rem >= {32'd0, dv_b}) begin dv_rem = dv_rem - {32'd0, dv_b}; dv_q[7'd63 - dv_i] <= 1'b1; end
                if (dv_i == 7'd63) dv_busy <= 1'b0;
            end else begin                                      // floor(sqrt(a)), 2 bits per clock
                dv_rem = {dv_rem[61:0], dv_a[7'd63 - {dv_i[4:0], 1'b0}], dv_a[7'd62 - {dv_i[4:0], 1'b0}]};
                if (dv_rem >= {dv_root[61:0], 2'b01}) begin
                    dv_rem = dv_rem - {dv_root[61:0], 2'b01}; dv_root = {dv_root[62:0], 1'b1};
                end else dv_root = {dv_root[62:0], 1'b0};
                dv_q <= dv_root;
                if (dv_i == 7'd31) dv_busy <= 1'b0;
            end
            dv_i <= dv_i + 7'd1;
        end
    end
    wire dv_ready = !dv_go && !dv_busy;

    // ---------------------------------------------------------------- player geometry
    reg signed [31:0] old_x, old_y, dy;
    wire signed [31:0] pl_l = px - PW2, pl_r = px + PW2;
    wire signed [31:0] col_a = fl(pl_l + 1), col_b = fl(pl_r - 1);
    wire [10:0] s_a = solid_col(stg, col_a), s_b = solid_col(stg, col_b);
    wire [10:0] w_a = water_col(stg, col_a), w_b = water_col(stg, col_b);
    wire [10:0] body_rows = rowmask(py, py + PH);
    wire        on_lift0 = px + PW2 > LIFT_L0 && px - PW2 < LIFT_L0 + tq(2);
    wire        on_lift1 = px + PW2 > LIFT_L1 && px - PW2 < LIFT_L1 + tq(2);
    wire        lift_hit = phase_ab && ((on_lift0 && py < lift_top0 - 1 && py + PH > lift_top0 - ONE + 1) ||
                                        (on_lift1 && py < lift_top1 - 1 && py + PH > lift_top1 - ONE + 1));
    reg [10:0] s_ab_r, tops_ab_r, w_ab_r;
    reg        head_puz_col_r;
    wire       wall_hit = ((s_a | s_b) & body_rows) != 11'd0;
    wire       in_water = (w_ab_r & body_rows) != 11'd0;
    // landing / head bump over the two player columns (registered column ROMs + parallel priority masks)
    reg [10:0] land_m, head_m;
    reg land_ok, head_ok, head_puzzle, lift_land0, lift_land1;
    reg signed [31:0] land_top, head_row;
    integer r;
    always @(*) begin
        for (r = 0; r < 11; r = r + 1) begin
            land_m[r] = tops_ab_r[r] && (old_y >= tq(r + 1) - 1) && (py <= tq(r + 1) + 1);
            head_m[r] = s_ab_r[r]    && (old_y + PH <= tq(r) + 1) && (py + PH >= tq(r) - 1);
        end
        land_ok = (land_m != 11'd0);
        casez (land_m)
            11'b1??????????: land_top = tq(11);
            11'b01?????????: land_top = tq(10);
            11'b001????????: land_top = tq(9);
            11'b0001???????: land_top = tq(8);
            11'b00001??????: land_top = tq(7);
            11'b000001?????: land_top = tq(6);
            11'b0000001????: land_top = tq(5);
            11'b00000001???: land_top = tq(4);
            11'b000000001??: land_top = tq(3);
            11'b0000000001?: land_top = tq(2);
            11'b00000000001: land_top = tq(1);
            default:         land_top = 0;
        endcase
        head_ok     = (head_m != 11'd0);
        head_puzzle = 1'b0;
        casez (head_m)
            11'b??????????1: head_row = tq(0);
            11'b?????????10: head_row = tq(1);
            11'b????????100: head_row = tq(2);
            11'b???????1000: head_row = tq(3);
            11'b??????10000: head_row = tq(4);
            11'b?????100000: begin head_row = tq(5); head_puzzle = head_puz_col_r; end
            11'b????1000000: head_row = tq(6);
            11'b???10000000: head_row = tq(7);
            11'b??100000000: head_row = tq(8);
            11'b?1000000000: head_row = tq(9);
            11'b10000000000: head_row = tq(10);
            default:         head_row = NONE;
        endcase
        lift_land0 = phase_ab && on_lift0 && old_y >= lift_top0 - 1 && py <= lift_top0 + 1;
        lift_land1 = phase_ab && on_lift1 && old_y >= lift_top1 - 1 && py <= lift_top1 + 1;
    end
    // a landing within the buffered time keeps the press for the landing (3-cycle reach -> rowmask for 74.25 MHz)
    reg  signed [31:0] dj_gb, dj_vyb, reach_r;
    reg  [10:0]        s_ab_j;
    wire               land_soon = ((tops(s_ab_j) & rowmask(py - reach_r - 2, py + 2)) != 11'd0);

    // ---------------------------------------------------------------- animal under update (index ei, pipelined for timing)
    reg  [5:0]  ei;
    wire [62:0] arec = s3_animal(stg, ei);
    reg  [62:0] arec_r;
    wire [5:0]  a_lead_r = arec_r[62:57];
    wire [1:0]  a_mo_r   = arec_r[53:52];
    wire signed [31:0] a_lo_r = {7'd0, arec_r[29:20], 15'd0};
    wire signed [31:0] a_hi_r = {7'd0, arec_r[19:10], 15'd0};
    wire signed [31:0] a_tr_r = {7'd0, arec_r[9:0], 15'd0};
    wire [5:0]  a_lead = arec[62:57];
    wire        a_act0 = arec[56];
    wire [1:0]  a_sp   = arec[55:54];
    wire [1:0]  a_mo   = arec[53:52];
    wire signed [31:0] a_x0 = {7'd0, arec[51:42], 15'd0};          // x * 2  -> Q16
    wire signed [31:0] a_y0 = {12'd0, arec[41:36], 14'd0};         // y * 4  -> Q16
    wire signed [31:0] a_b0 = {12'd0, arec[35:30], 14'd0};
    wire signed [31:0] e_x = a_x[ei];                              // used by U_NEXT visibility check
    reg  signed [31:0] e_x_r, e_y_r, e_vy_r, e_wl_r, e_w_r, a_ynew_r, e_vy_dt_r;
    reg  [8:0]  e_expo_r;
    reg  [7:0]  e_skin_r;
    wire [25:0] e_ci_r = crop_info(e_skin_r);
    reg         e_dir_r, e_wat_r, e_touch_r;
    reg  [10:0] e_col_r, e_wcol_r;
    wire [10:0] e_tops = tops(e_col_r);
    reg  [129:0] pt_pair_r, st_pair_r;
    wire        e_inside = (e_y_r >= 0) && (e_y_r < tq(11)) && e_col_r[fl(e_y_r) & 32'sd15];
    reg  [10:0] fall_m;
    reg  signed [31:0] fall_land;
    reg  signed [31:0] patrol_top_r, step_top_r, fall_land_r;
    reg         e_inside_r;
    always @(*) begin
        for (r = 0; r < 11; r = r + 1)
            fall_m[r] = e_tops[r] && (e_y_r >= tq(r + 1) - 1) && (a_ynew_r <= tq(r + 1));
        fall_land = NONE;
        for (r = 0; r < 11; r = r + 1)
            if (fall_m[r]) fall_land = tq(r + 1);
    end
    wire [2:0]  fsl = fl_slot[ei];
    wire [8:0]  fl_wa = {fsl, fl_wp[fsl]};
    wire [8:0]  fl_ra = {fsl, fl_wp[fsl] - 6'd60};
    // milk tea falls onto the top under it (registered column ROM + parallel priority mask)
    reg  [10:0] tea_tops_r;
    reg  [10:0] tea_m;
    reg signed [31:0] tea_floor;
    always @(*) begin
        for (r = 0; r < 11; r = r + 1)
            tea_m[r] = tea_tops_r[r] && (tq(r + 1) <= tea_y + 1);
        casez (tea_m)
            11'b1??????????: tea_floor = tq(11);
            11'b01?????????: tea_floor = tq(10);
            11'b001????????: tea_floor = tq(9);
            11'b0001???????: tea_floor = tq(8);
            11'b00001??????: tea_floor = tq(7);
            11'b000001?????: tea_floor = tq(6);
            11'b0000001????: tea_floor = tq(5);
            11'b00000001???: tea_floor = tq(4);
            11'b000000001??: tea_floor = tq(3);
            11'b0000000001?: tea_floor = tq(2);
            11'b00000000001: tea_floor = tq(1);
            default:         tea_floor = -tq(5);
        endcase
    end

    // progress % = clamp(100 * (x - spawn) / (door.x - spawn), 0, 99): multiply by a reciprocal
    wire [31:0] prog_k = (stg == 2'd1) ? 32'd27421 : (stg == 2'd2) ? 32'd27059 : 32'd27307;
    wire signed [31:0] prog_d = px - spawn_x;
    wire [63:0] prog_p = (prog_d > 0) ? prog_d[31:0] * prog_k : 64'd0;
    wire [6:0] progress = (mode == M_CLEAR || mode == M_WIN) ? 7'd100 :
                          (prog_p[63:32] >= 64'd99) ? 7'd99 : prog_p[38:32];
    reg  [6:0] progress_r;
    wire [3:0] secs_left = (skill_t > 14'd480) ? 4'd5 : (skill_t > 14'd360) ? 4'd4 : (skill_t > 14'd240) ? 4'd3 :
                           (skill_t > 14'd120) ? 4'd2 : (skill_t != 0) ? 4'd1 : 4'd0;
    // random interview questions (0..14, two different ones)
    wire [3:0] rq0 = (lfsr[3:0] == 4'd15) ? 4'd0 : lfsr[3:0];
    wire [3:0] rd  = (lfsr[7:4] >= 4'd14) ? lfsr[7:4] - 4'd14 : lfsr[7:4];
    wire [4:0] rq1s = rq0 + rd + 5'd1;
    wire [3:0] rq1 = (rq1s >= 5'd15) ? rq1s - 5'd15 : rq1s[3:0];

    task notify; input [4:0] m; begin msg <= m; notice_t <= (m != 0) ? 14'd240 : 14'd0; end endtask

    // ---------------------------------------------------------------- update FSM
    localparam [5:0] U_IDLE = 0, U_FRAME = 1, U_STEP = 2, U_LIFT = 3, U_JUMP = 4, U_DJ0 = 5, U_DJ1 = 6,
                     U_DJ2 = 7, U_DJ3 = 8, U_DJ4 = 9, U_DJ5 = 10, U_DJ6 = 11, U_MX = 12, U_MXC = 13,
                     U_MY = 14, U_MYC = 15, U_GRND = 16, U_DEATH = 17, U_TEA = 18, U_ROUTE = 19,
                     U_REP = 20, U_EN = 21, U_EN2 = 22, U_EN3 = 23, U_FIN = 24, U_VIS = 25,
                     U_RESTART = 26, U_RS2 = 27, U_NEXT = 28,
                     U_EN0 = 29, U_EN2B = 30, U_EN2C = 31, U_NEXT2 = 32, U_EN2D = 33, U_JCHK = 34, U_EN2E = 35, U_JCHK2 = 36, U_TEA2 = 37;
    reg [5:0]  u;
    reg signed [31:0] tea_y_next_r;
    reg [127:0] vis_desc [0:23];
    reg signed [31:0] vn_x, vn_y, vn_wl;
    reg        vn_dir;
    reg [8:0]  vn_expo;
    reg [7:0]  vn_skin;
    reg [62:0] vn_rec;
    integer vii;
    initial for (vii = 0; vii < 24; vii = vii + 1) vis_desc[vii] = 128'd0;
    reg [1:0]  step_k;
    reg signed [1:0] axis;
    reg        jmp_in, skill_in;
    reg signed [31:0] dj_rise, dj_rem, dj_s;
    wire signed [31:0] dj_num = DRANGE - 32'sd5 * elapsed;
    reg signed [31:0] nx, ny, dyv;
    integer k;
    always @(posedge clk) begin
        dv_go <= 1'b0;
        done  <= 1'b0;
        if (rst) begin
            u <= U_IDLE; stg <= 2'd1; mode <= M_PLAY; lfsr <= 16'h1D2C; jump_req <= 4'd0; skill_req <= 1'b0;
            restart_msg <= 5'd0; msg <= 5'd0; notice_t <= 14'd0;
        end else if (start) begin
            stg <= 2'd1; restart_msg <= T_S3_MSG_NEW_GAME[4:0]; u <= U_RESTART; jump_req <= 4'd0; skill_req <= 1'b0;
        end else if (dbg_jump) begin
            stg <= dbg_part ? 2'd3 : 2'd2;
            restart_msg <= dbg_part ? T_S3_MSG_STAGE3[4:0] : T_S3_MSG_STAGE2[4:0];
            u <= U_RESTART; jump_req <= 4'd0; skill_req <= 1'b0;
        end else if (dbg_win) begin
            stg <= 2'd3; mode <= M_WIN; gold <= 1'b1; chase <= 1'b0; interview <= 14'd0; cloak_t <= 14'd0;
        end else begin
            lfsr <= lfsr_next(lfsr);
            if (dbg_set_form) gold <= (dbg_form == 2'd3);
            // ---- input collection (stage3_demo poll): BTNU jump, BTNC tap skill / long back, BTND pause
            if (active && frame) begin
                if (ev_press[B_U] && mode == M_PLAY && jump_req != 4'd15) jump_req <= jump_req + 4'd1;
                if (ev_tap && mode == M_PLAY) skill_req <= 1'b1;
                if (ev_press[B_D]) begin
                    if (mode == M_WIN) done <= 1'b1;
                    else if (mode == M_PLAY) begin mode <= M_PAUSE; jump_req <= 4'd0; skill_req <= 1'b0; end
                    else if (mode == M_PAUSE) mode <= M_PLAY;
                end
                if (ev_tap && mode == M_WIN) done <= 1'b1;
                if (ev_back && mode != M_WIN) begin
                    restart_msg <= T_S3_MSG_RETRY[4:0]; jump_req <= 4'd0; skill_req <= 1'b0; u <= U_RESTART;
                end
            end
            case (u)
            U_IDLE: if (active && frame && !ev_back) begin step_k <= 2'd0; u <= U_FRAME; end
            U_FRAME: begin
                if (step_k == 2'd2 || !(mode == M_PLAY || mode == M_CLEAR)) u <= U_VIS;
                else begin
                    axis   <= (lvl[B_R] ? 2'sd1 : 2'sd0) - (lvl[B_L] ? 2'sd1 : 2'sd0);
                    jmp_in <= (jump_req != 4'd0);
                    skill_in <= skill_req;
                    if (jump_req != 4'd0) jump_req <= jump_req - 4'd1;
                    skill_req <= 1'b0;
                    u <= U_STEP;
                end
            end
            // ------------------------------------------------ step(): timers, interview, cast
            U_STEP: begin
                step_k <= step_k + 2'd1;
                if (mode == M_CLEAR) begin
                    if (clear_left <= 14'd1) begin
                        restart_msg <= (stg == 2'd1) ? T_S3_MSG_STAGE2[4:0] : T_S3_MSG_STAGE3[4:0];
                        stg <= stg + 2'd1;
                        u <= U_RESTART;
                    end else begin clear_left <= clear_left - 14'd1; u <= U_FRAME; end
                end else begin
                    tsteps <= tsteps + 16'd1;
                    if (remaining <= 14'd1) begin restart_msg <= T_S3_MSG_TIME_UP[4:0]; u <= U_RESTART; end
                    else begin
                        remaining <= remaining - 14'd1;
                        if (notice_t != 0) notice_t <= notice_t - 14'd1;
                        if (phase_ab && skill_t == 14'd1) flash_t <= 7'd54;               // phase ends: .45 s flash
                        else if (flash_t != 0) flash_t <= flash_t - 7'd1;
                        if (skill_t != 0) skill_t <= skill_t - 14'd1;
                        if (protection != 0) protection <= protection - 14'd1;
                        if (interview != 0) begin                                         // frozen while interviewed
                            interview <= interview - 14'd1;
                            if (interview == 14'd1) begin protection <= 14'd120; retreat_t <= STEPS_2S; end
                            u <= U_FRAME;
                        end else begin
                            if (skill_in && !skill_used) begin                            // cast()
                                if (phase_ab) begin skill_used <= 1'b1; skill_t <= STEPS_5S; flash_t <= 7'd54; end
                                else if (!chase) notify(T_S3_MSG_USE_CLOAK[4:0]);
                                else begin chase <= 1'b0; cloak_t <= 14'd72; skill_used <= 1'b1; skill_t <= STEPS_5S; end
                            end
                            u <= U_LIFT;
                        end
                    end
                end
            end
            // ------------------------------------------------ lifts (level 3), carrying a rider
            U_LIFT: begin
                if (phase_ab) begin
                    // lift 0 bobs between 3 and 5 tiles at 0.8 tiles/s
                    ny = lift_up0 ? lift_top0 + 32'sd437 : lift_top0 - 32'sd437;
                    if (ny >= Y5) begin ny = Y5; lift_up0 <= 1'b0; end
                    if (ny <= Y3) begin ny = Y3; lift_up0 <= 1'b1; end
                    lift_top0 <= ny;
                    if (grounded && py == lift_top0 && on_lift0) py <= ny;
                    // lift 1 sinks while ridden, rises back otherwise (0.6 tiles/s)
                    if (grounded && py == lift_top1 && on_lift1) begin
                        lift_top1 <= clampq(lift_top1 - 32'sd328, Y3, Y5);
                        py <= clampq(lift_top1 - 32'sd328, Y3, Y5);
                    end else lift_top1 <= clampq(lift_top1 + 32'sd328, Y3, Y5);
                end
                if (jmp_in) buffer <= T015;
                u <= (jmp_in || buffer > 0) ? U_JUMP : U_MX;
            end
            // ------------------------------------------------ try_jump()
            U_JUMP: begin
                if (grounded || (jumps == 2'd0 && grace > 0)) begin
                    grounded <= 1'b0; grace <= 0; buffer <= 0; jumps <= 2'd1; takeoff <= py; elapsed <= 0;
                    grav <= G; vy <= V0; spd <= RUN;
                    u <= U_MX;
                end else if (jumps == 2'd1 && elapsed < T112) begin
                    dj_gb <= mulq(grav, buffer); dj_vyb <= mulq(-vy, buffer); s_ab_j <= s_a | s_b;
                    u <= U_JCHK;
                end else u <= U_MX;
            end
            U_JCHK: begin
                reach_r <= dj_vyb + (mulq(dj_gb, buffer) >>> 1);
                u <= U_JCHK2;
            end
            U_JCHK2: begin
                if (!(vy < 0 && land_soon)) u <= U_DJ0;
                else u <= U_MX;
            end
            U_DJ0: begin                                                    // rise = max(.02, takeoff + 4.5 - y)
                dj_rem  <= T12 - elapsed;
                dj_rise <= (takeoff + DH - py > R002) ? takeoff + DH - py : R002;
                u <= U_DJ1;
            end
            U_DJ1: begin dv_a <= {16'd0, dj_rise, 16'd0}; dv_div <= 1'b0; dv_go <= 1'b1; u <= U_DJ2; end
            U_DJ2: if (dv_ready) begin dj_s <= dv_q[31:0] + SQRT_DH; u <= U_DJ3; end
            U_DJ3: begin                                                    // gravity = 2 (sqrt(rise)+sqrt(4.5))^2 / rem^2
                dv_a <= {16'd0, mulq(dj_s, dj_s) <<< 1, 16'd0};
                dv_b <= mulq(dj_rem, dj_rem);
                dv_div <= 1'b1; dv_go <= 1'b1;
                u <= U_DJ4;
            end
            U_DJ4: if (dv_ready) begin                                      // vy = sqrt(2 g rise)
                grav <= dv_q[31:0];
                dv_a <= {16'd0, mulq(dv_q[31:0], dj_rise) <<< 1, 16'd0};
                dv_div <= 1'b0; dv_go <= 1'b1;
                u <= U_DJ5;
            end
            U_DJ5: if (dv_ready) begin                                      // speed = clamp((5.5 - 5 t) / rem, 0, 5)
                vy <= dv_q[31:0];
                jumps <= 2'd2; buffer <= 0;
                if (dj_num <= 0) begin spd <= 0; u <= U_MX; end
                else begin
                    dv_a <= {16'd0, dj_num, 16'd0}; dv_b <= dj_rem; dv_div <= 1'b1; dv_go <= 1'b1;
                    u <= U_DJ6;
                end
            end
            U_DJ6: if (dv_ready) begin spd <= (dv_q[31:0] > RUN) ? RUN : dv_q[31:0]; u <= U_MX; end
            // ------------------------------------------------ horizontal move + push out
            U_MX: begin
                old_x <= px; old_y <= py;
                if (axis != 0) dir_r <= (axis > 0);
                nx = (axis > 0) ? px + adt(spd) : (axis < 0) ? px - adt(spd) : px;
                px <= clampq(nx, PW2, tq(250) - PW2);
                u <= U_MXC;
            end
            U_MXC: begin
                if (axis > 0 && wall_hit) px <= tq(0) + (col_b <<< 16) - PW2;
                else if (axis < 0 && wall_hit) px <= ((col_a + 1) <<< 16) + PW2;
                else if (lift_hit) px <= old_x;
                u <= U_MY;
            end
            // ------------------------------------------------ vertical move + landing / head bump
            U_MY: begin
                dyv = adt(vy) - $signed({32'd0, grav} * {32'd0, HDT2_32} >> 32);
                dy <= dyv;
                vy <= vy - adt(grav);
                py <= py + dyv;
                grounded <= 1'b0;
                // px/col_a/col_b are settled here; register column ROMs before U_MYC & U_DEATH
                s_ab_r         <= s_a | s_b;
                tops_ab_r      <= tops(s_a) | tops(s_b);
                w_ab_r         <= w_a | w_b;
                head_puz_col_r <= (stg == 2'd2) && (col_a == 240 || col_b == 240);
                u <= U_MYC;
            end
            U_MYC: begin
                if (dy <= 0 && land_ok) begin py <= land_top; vy <= 0; grounded <= 1'b1; end
                else if (dy <= 0 && lift_land0) begin py <= lift_top0; vy <= 0; grounded <= 1'b1; end
                else if (dy <= 0 && lift_land1) begin py <= lift_top1; vy <= 0; grounded <= 1'b1; end
                else if (dy > 0 && head_ok) begin
                    py <= head_row - PH; vy <= 0;
                    if (head_puzzle && !opened) begin                       // hit the ? block from below
                        opened <= 1'b1; tea_on <= 1'b1; tea_x <= tq(240) + HALF; tea_y <= tq(6); tea_vy <= tq(6);
                        notify(T_S3_MSG_PICK_TEA[4:0]);
                    end
                end
                u <= U_GRND;
            end
            U_GRND: begin
                walking <= (px != old_x);
                stride  <= stride + ((px > old_x) ? px - old_x : old_x - px);
                cam     <= clampq(px - tq(7), 0, tq(230));
                if (grounded) begin
                    grace <= T015; jumps <= 2'd0; spd <= RUN; grav <= G;
                    if (buffer > 0) begin                                   // buffered press: jump on landing
                        grounded <= 1'b0; grace <= 0; buffer <= 0; jumps <= 2'd1; takeoff <= py; elapsed <= 0;
                        vy <= V0;
                    end
                end else begin
                    elapsed <= elapsed + DT;
                    grace <= (grace > DT) ? grace - DT : 0;
                    buffer <= (buffer > DT) ? buffer - DT : 0;
                end
                u <= U_DEATH;
            end
            U_DEATH: begin
                tea_tops_r <= tops(solid_col(stg, fl(tea_x)));
                if (py < -ONE || (!grounded && grace <= 0 && in_water)) begin
                    restart_msg <= (py < -ONE) ? T_S3_MSG_FELL[4:0] : T_S3_MSG_SPLASH[4:0]; u <= U_RESTART;
                end else u <= U_TEA;
            end
            // ------------------------------------------------ milk tea (level 2, 2-cycle pipelined for 74.25 MHz)
            U_TEA: begin
                if (tea_on) begin
                    tea_x        <= (tea_x + 32'sd1420 > tq(240) + 32'sd124518) ? tq(240) + 32'sd124518 : tea_x + 32'sd1420;
                    tea_vy       <= tea_vy - 32'sd13107;                          // gravity 24
                    tea_y_next_r <= tea_y + adt(tea_vy - 32'sd13107);
                    u <= U_TEA2;
                end else u <= U_ROUTE;
            end
            U_TEA2: begin
                if (tea_y_next_r <= tea_floor) begin tea_y <= tea_floor; tea_vy <= 0; end
                else tea_y <= tea_y_next_r;
                if (touches(pl_l, py, 2 * PW2, PH, tea_x - 32'sd40960, tea_y, 32'sd81920, 32'sd111411)) begin
                    gold <= 1'b1; tea_on <= 1'b0; tea_grow_until <= tsteps + 16'd360;
                    notify(T_S3_MSG_TEA[4:0]);
                end
                u <= U_ROUTE;
            end
            // ------------------------------------------------ record_route + reporter
            U_ROUTE: begin
                rt_x[rt_wp] <= px; rt_y[rt_wp] <= py; rt_w[rt_wp] <= (px != old_x) && grounded;
                rt_wp <= rt_wp + 6'd1;
                if (rt_n < 6'd34) rt_n <= rt_n + 6'd1;
                u <= U_REP;
            end
            U_REP: begin
                if (chase || cloak_t != 0) begin                            // follow 0.28 s behind
                    rep_vis <= 1'b1; rep_dir <= dir_r;
                    rep_y <= rt_y[rt_wp - rt_n];
                    rep_walk <= rt_w[rt_wp - rt_n];
                    if (dir_r ? (px - rt_x[rt_wp - rt_n] < 32'sd75366) : (rt_x[rt_wp - rt_n] - px < 32'sd75366))
                        rep_x <= dir_r ? px - 32'sd75366 : px + 32'sd75366;  // REPORTER_GAP 1.15
                    else rep_x <= rt_x[rt_wp - rt_n];
                    if (cloak_t != 0) begin
                        cloak_t <= cloak_t - 14'd1;
                        if (cloak_t == 14'd1) retreat_t <= STEPS_2S;
                    end
                end else if (retreat_t != 0) begin                          // walk away, then vanish
                    rep_x <= rep_dir ? rep_x - 32'sd1638 : rep_x + 32'sd1638;
                    rep_walk <= 1'b1;
                    retreat_t <= retreat_t - 14'd1;
                    if (retreat_t == 14'd1) rep_vis <= 1'b0;
                end
                ei <= 6'd0; new_contacts <= 48'd0;
                u <= U_EN0;
            end
            // ------------------------------------------------ animals (pipelined to meet 74.25 MHz timing)
            U_EN0: begin
                if (ei >= n_anim) begin contacts <= new_contacts; u <= U_FIN; end
                else if (!a_alive[ei]) ei <= ei + 6'd1;
                else begin
                    arec_r   <= arec;
                    e_x_r    <= a_x[ei]; e_y_r <= a_y[ei]; e_vy_r <= a_vy[ei]; e_wl_r <= a_wl[ei];
                    e_expo_r <= a_expo[ei]; e_skin_r <= a_skin[ei]; e_dir_r <= a_dir[ei]; e_wat_r <= a_wat[ei];
                    u <= U_EN;
                end
            end
            U_EN: begin
                if (!a_act[ei] && (cam + tq(20) + ((((stg == 2'd2) && (a_mo_r == MO_WALK || a_mo_r == MO_FLY)) ||
                                                 (stg == 2'd3 && a_mo_r == MO_FLY)) ? tq(5) : 0) >= a_tr_r))
                    a_act[ei] <= 1'b1;
                u <= U_EN2;
            end
            U_EN2: begin                                                    // movement
                if (a_act[ei]) begin
                    a_age[ei] <= (a_age[ei] + DT >= tq(6)) ? a_age[ei] + DT - tq(6) : a_age[ei] + DT;
                    if (a_lead_r != 6'd63) begin                              // follower: the leader 0.5 s ago
                        fl_x[fl_wa] <= a_x[a_lead_r]; fl_y[fl_wa] <= a_y[a_lead_r]; fl_d[fl_wa] <= a_dir[a_lead_r];
                        fl_wp[fsl] <= fl_wp[fsl] + 6'd1;
                        if (fl_n[fsl] < 7'd61) fl_n[fsl] <= fl_n[fsl] + 7'd1;
                        else begin a_x[ei] <= fl_x[fl_ra]; a_y[ei] <= fl_y[fl_ra]; a_dir[ei] <= fl_d[fl_ra]; end
                    end else case (a_mo_r)
                        MO_POP: a_expo[ei] <= pop_expo(a_age[ei]);
                        MO_FLY: a_x[ei] <= e_dir_r ? e_x_r + ESPD : e_x_r - ESPD;
                        MO_PATROL: begin
                            nx = e_dir_r ? e_x_r + ESPD : e_x_r - ESPD;
                            if (nx < a_lo_r) begin a_x[ei] <= (a_lo_r <<< 1) - nx; a_dir[ei] <= 1'b1; end
                            else if (nx > a_hi_r) begin a_x[ei] <= (a_hi_r <<< 1) - nx; a_dir[ei] <= 1'b0; end
                            else a_x[ei] <= nx;
                        end
                        default: begin                                      // walk
                            if (e_wat_r) begin
                                a_y[ei] <= e_y_r - 32'sd1529;                 // sinks 2.8 tiles/s
                                if (e_y_r - 32'sd1529 + AH <= e_wl_r) a_alive[ei] <= 1'b0;
                            end else a_x[ei] <= e_dir_r ? e_x_r + ESPD : e_x_r - ESPD;
                        end
                    endcase
                end
                e_vy_dt_r <= adt(e_vy_r - 32'sd16384);
                u <= U_EN2B;
            end
            U_EN2B: begin
                e_x_r    <= a_x[ei]; e_y_r <= a_y[ei]; e_dir_r <= a_dir[ei]; e_expo_r <= a_expo[ei];
                a_ynew_r <= a_y[ei] + e_vy_dt_r;
                e_w_r    <= {e_ci_r[13:7], 16'd0} >>> 5;
                u <= U_EN2C;
            end
            U_EN2C: begin
                e_col_r   <= solid_col(stg, fl(e_x_r));
                e_wcol_r  <= water_col(stg, fl(e_x_r));
                e_touch_r <= touches(pl_l, py, 2 * PW2, PH, e_x_r - (e_w_r >>> 1),
                                     (a_mo_r == MO_POP) ? e_wl_r : e_y_r, e_w_r,
                                     (a_mo_r == MO_POP) ? ((AH * $signed({23'd0, e_expo_r})) >>> 8) : AH);
                u <= U_EN2D;
            end
            U_EN2D: begin
                pt_pair_r   <= near_ab(e_tops, e_y_r, 1'b0);
                st_pair_r   <= near_ab(e_tops, e_y_r, 1'b1);
                fall_land_r <= fall_land;
                e_inside_r  <= e_inside;
                u <= U_EN2E;
            end
            U_EN2E: begin
                patrol_top_r <= pick_ab(pt_pair_r);
                step_top_r   <= pick_ab(st_pair_r);
                u <= U_EN3;
            end
            U_EN3: begin                                                    // surfaces / gravity / contact
                if (a_act[ei] && a_lead_r == 6'd63) begin
                    if (a_mo_r == MO_PATROL) begin
                        if (patrol_top_r != NONE) a_y[ei] <= patrol_top_r;
                        else begin a_x[ei] <= e_dir_r ? e_x_r - ESPD : e_x_r + ESPD; a_dir[ei] <= !e_dir_r; end
                    end else if (a_mo_r == MO_WALK && !e_wat_r) begin
                        if (e_vy_r == 0 && step_top_r != NONE) a_y[ei] <= step_top_r;
                        else if (e_inside_r) begin a_x[ei] <= e_dir_r ? e_x_r - ESPD : e_x_r + ESPD; a_dir[ei] <= !e_dir_r; end
                        else if (fall_land_r != NONE) begin a_y[ei] <= fall_land_r; a_vy[ei] <= 0; end
                        else begin a_y[ei] <= a_ynew_r; a_vy[ei] <= e_vy_r - 32'sd16384; end
                        if (e_y_r >= 0 && e_y_r < tq(11) && e_wcol_r[fl(e_y_r) & 32'sd15]) begin
                            a_wat[ei] <= 1'b1; a_wl[ei] <= (fl(e_y_r) + 1) <<< 16;
                        end
                    end
                    if (e_x_r < -tq(3) || e_y_r < -tq(2)) a_alive[ei] <= 1'b0;
                end
                if (a_act[ei] && !e_wat_r && (a_mo_r != MO_POP || e_expo_r != 0) && !(phase_ab && skill_t != 0) && e_touch_r) begin
                    new_contacts[ei] <= 1'b1;
                    if (!contacts[ei] && protection == 0 && interview == 0 && retreat_t == 0 && cloak_t == 0) begin   // hit()
                        protection <= 14'd78;
                        if (chase) begin
                            chase <= 1'b0; interview <= STEPS_5S; q0 <= rq0; q1 <= rq1;
                            rep_vis <= 1'b1; rep_x <= px + (dir_r ? 32'sd85197 : -32'sd85197); rep_y <= py; rep_dir <= !dir_r;
                            notify(5'd0);
                        end else begin
                            chase <= 1'b1; retreat_t <= 0; rt_n <= 6'd1;
                            notify(T_S3_MSG_REPORTER[4:0]);
                        end
                    end
                end
                ei <= ei + 6'd1;
                u <= U_EN0;
            end
            // ------------------------------------------------ near finish, door
            U_FIN: begin
                if (progress_r >= 7'd92 && !near_seen) begin
                    near_seen <= 1'b1;
                    notify(stg == 2'd1 ? T_S3_MSG_NEAR1[4:0] : stg == 2'd2 ? T_S3_MSG_NEAR2[4:0] : T_S3_MSG_NEAR3[4:0]);
                end
                if (mode == M_PLAY && door_x <= px && px <= door_x + door_w &&
                    touches(pl_l, py, 2 * PW2, PH, door_x, DOOR_Y, door_w, DOOR_H)) begin
                    if (stg != 2'd3 && (stg == 2'd1 || gold)) begin mode <= M_CLEAR; clear_left <= STEPS_2S; notify(5'd0); end
                    else if (stg == 2'd3) begin mode <= M_WIN; notify(5'd0); end
                    else if (notice_t == 0) notify(T_S3_MSG_HIT_BLOCK[4:0]);
                end
                u <= U_FRAME;
            end
            // ------------------------------------------------ visible animal list & pre-baked descriptors
            U_VIS: begin ei <= 6'd0; n_vis <= 5'd0; u <= U_NEXT; end
            U_NEXT: begin
                if (ei >= n_anim || n_vis == 5'd24) u <= U_IDLE;
                else if (a_act[ei] && a_alive[ei] && e_x >= cam - ONE && e_x <= cam + tq(21)) begin
                    vis[n_vis] <= ei;
                    vn_x <= e_x; vn_y <= a_y[ei]; vn_wl <= a_wl[ei]; vn_dir <= a_dir[ei];
                    vn_expo <= a_expo[ei]; vn_skin <= a_skin[ei]; vn_rec <= arec;
                    u <= U_NEXT2;
                end else ei <= ei + 6'd1;
            end
            U_NEXT2: begin : blk_next2
                reg        vn_fly, vn_pop, vn_flip;
                reg [25:0] vn_ci;
                reg [9:0]  vn_w;
                reg [8:0]  vn_h, vn_hv;
                reg [16:0] vn_hx;
                reg signed [11:0] vn_bob, vn_top;
                vn_fly  = (vn_rec[53:52] == MO_FLY);
                vn_pop  = (vn_rec[53:52] == MO_POP);
                vn_flip = vn_dir;
                vn_ci   = crop_info(vn_skin);
                vn_w    = {3'd0, vn_ci[13:7]};
                vn_h    = {2'd0, vn_ci[6:0]};
                vn_hx   = vn_h * vn_expo;
                vn_hv   = vn_pop ? vn_hx[16:8] : vn_h;
                vn_bob  = (vn_fly && tsteps[5]) ? 12'sd2 : 12'sd0;
                vn_top  = vn_pop ? ys(vn_wl) - $signed({3'd0, vn_hv}) : ys(vn_y) - $signed({3'd0, vn_h}) - vn_bob;
                vis_desc[n_vis] <= obj_img(xs(vn_x) - $signed({2'b0, vn_w[9:1]}), vn_top, vn_w, vn_hv,
                                           vn_skin, 19'd0, 18'd0, 10'd256, 10'd256, vn_flip);
                n_vis <= n_vis + 5'd1;
                ei    <= ei + 6'd1;
                u     <= U_NEXT;
            end
            // ------------------------------------------------ restart(): new attempt of this level
            U_RESTART: begin
                mode <= M_PLAY; px <= spawn_x; py <= SPAWN_Y; vy <= 0; dir_r <= 1'b1; grounded <= 1'b0; jumps <= 2'd0;
                elapsed <= 0; takeoff <= 0; grav <= G; spd <= RUN; stride <= 0; walking <= 1'b0; grace <= 0; buffer <= 0;
                clear_left <= 0; skill_used <= 1'b0; skill_t <= 0; interview <= 0; protection <= 0; retreat_t <= 0; cloak_t <= 0;
                chase <= 1'b0; near_seen <= 1'b0; rep_vis <= 1'b0; rep_walk <= 1'b0; rep_x <= 0; rep_y <= 0; rep_dir <= 1'b1;
                rt_wp <= 6'd0; rt_n <= 6'd0;
                remaining <= STEPS_120S; tsteps <= 0; contacts <= 48'd0; flash_t <= 7'd0;
                cam <= clampq(spawn_x - tq(7), 0, tq(230));
                opened <= 1'b0; gold <= (stg == 2'd3); tea_on <= 1'b0; tea_grow_until <= 16'd0;
                tea_x <= 0; tea_y <= 0; tea_vy <= 0;
                lift_top0 <= tq(4); lift_up0 <= 1'b1; lift_top1 <= Y5;
                notify(restart_msg);
                for (k = 0; k < 8; k = k + 1) begin fl_wp[k] <= 6'd0; fl_n[k] <= 7'd0; end
                ei <= 6'd0; k_fl <= 3'd0;
                u <= U_RS2;
            end
            U_RS2: begin                                                    // animals from the spawn table
                if (ei >= n_anim) begin u <= U_VIS; jump_req <= 4'd0; end
                else begin
                    a_x[ei] <= a_x0; a_y[ei] <= a_y0; a_vy[ei] <= 0; a_age[ei] <= 0; a_dir[ei] <= 1'b0;
                    a_act[ei] <= a_act0; a_alive[ei] <= 1'b1; a_wat[ei] <= 1'b0; a_wl[ei] <= a_b0;
                    a_expo[ei] <= (a_mo == MO_POP) ? 9'd0 : 9'd256;
                    a_skin[ei] <= s3_skin(stg, a_sp, {5'd0, lfsr[2:0] ^ ei[2:0]});
                    if (a_lead != 6'd63) begin fl_slot[ei] <= k_fl; k_fl <= k_fl + 3'd1; end
                    ei <= ei + 6'd1;
                end
            end
            default: u <= U_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- render (render.py draw_frame)
    // world -> frame pixels: x = round((pos - cam) * 32), y = round(352 - pos * 32)
    function signed [10:0] xs; input signed [31:0] w; reg signed [31:0] v; begin
        v = (((w - cam) <<< 5) + HALF) >>> 16; xs = (v < -1000) ? -11'sd1000 : (v > 1000) ? 11'sd1000 : v[10:0]; end endfunction
    function signed [9:0] ys; input signed [31:0] w; reg signed [31:0] v; begin
        v = (tq(352) - (w <<< 5) + HALF) >>> 16; ys = (v < -500) ? -10'sd500 : (v > 500) ? 10'sd500 : v[9:0]; end endfunction

    wire [63:0] sky_p = {32'd0, cam} * 64'd18236;                     // round(64 * cam / 230)
    wire [10:0] sky_off = sky_p[42:32] + {10'd0, sky_p[31]};
    wire [31:0] cam_px = ((cam <<< 5) + HALF) >>> 16;                  // round(cam * 32)

    // player: gown / cloak (skill, levels 1-2) / gold / phase (skill, level 3)
    wire [1:0]  form_k = (skill_t != 0) ? (phase_ab ? 2'd3 : 2'd1) : (gold ? 2'd2 : 2'd0);
    wire [63:0] strp = {32'd0, stride} * 64'd144179;                   // int(stride * 2.2) % 4
    reg  [1:0]  strp_r;
    wire [1:0]  pose = !grounded ? 2'd1 : !walking ? 2'd0 : (strp_r == 2'd1) ? 2'd1 :
                       (strp_r == 2'd3) ? 2'd2 : 2'd0;
    wire [7:0]  pl_asset = (form_k == 2'd0) ? A_PL_F2_RIGHT_STAND + pose : (form_k == 2'd1) ? A_PL_F2_RIGHT2_STAND + pose :
                           (form_k == 2'd2) ? A_PL_F3_RIGHT_STAND + pose : A_PL_F3_RIGHT2_STAND + pose;
    wire        enlarged = (tsteps < tea_grow_until) || (stg == 2'd3 && gold);
    // sprite box 1.12 x 1.5 tiles times the scale 1.00 / 1.08 / 1.50 / 1.62 (32x32 source frame)
    reg  [9:0]  pw, stx; reg [8:0] ph; reg [9:0] sty;
    always @(*) begin
        case ({form_k == 2'd3, enlarged})
            2'b00: begin pw = 10'd36; ph = 9'd48; stx = 10'd228; sty = 10'd171; end
            2'b01: begin pw = 10'd39; ph = 9'd52; stx = 10'd211; sty = 10'd158; end
            2'b10: begin pw = 10'd54; ph = 9'd72; stx = 10'd152; sty = 10'd114; end
            default: begin pw = 10'd58; ph = 9'd78; stx = 10'd140; sty = 10'd105; end
        endcase
    end
    // the stored frames are cropped: place the stored part inside the 32x32 frame window
    reg  [25:0] pci_r;
    wire [15:0] c_ox = pci_r[25:20] * pw, c_oy = pci_r[19:14] * ph, c_w = pci_r[13:7] * pw, c_h = pci_r[6:0] * ph;
    wire signed [11:0] pl_x = xs(px) - $signed({2'b0, pw[9:1]});
    wire signed [11:0] pl_y = ys(py) - $signed({3'b0, ph});
    wire [9:0]  cw = c_w[14:5], cox = c_ox[14:5];
    wire signed [11:0] pl_cx = dir_r ? pl_x + $signed({2'b0, cox}) : pl_x + $signed({2'b0, pw}) - $signed({2'b0, cox}) - $signed({2'b0, cw});
    wire signed [11:0] pl_cy = pl_y + $signed({3'b0, c_oy[13:5]});

    // Registered frame render coordinates (removes xs/ys/mul critical path from obj_desc -> d_reg)
    wire [4:0]  vslot = obj_idx[4:0] - 5'd7;
    wire [127:0] vslot_desc = ({1'b0, vslot} < {1'b0, n_vis}) ? vis_desc[vslot] : OBJ_NONE;

    // reporter
    wire        rep_pose = rep_walk && interview == 0 && tsteps[3];
    wire        rep_show = rep_vis && (chase || cloak_t != 0 || interview != 0 || retreat_t != 0);
    wire signed [11:0] rep_sx = xs(rep_x) - 12'sd18, rep_sy = ys(rep_y) - 12'sd48;

    wire [1:0]  aft = 2'd3 - obj_idx[1:0];                               // after-image 1..3 (idx 32..34)
    wire signed [11:0] aft_dx = dir_r ? -$signed({8'd0, aft, 2'd0}) - $signed({10'd0, aft}) : $signed({8'd0, aft, 2'd0}) + $signed({10'd0, aft});
    wire        used_now = skill_used && skill_t == 0;
    wire [4:0]  pip = obj_idx[4:0] - 5'd8;                               // 40..44 -> 0..4
    wire [16:0] prog_wp = progress_r * 10'd275;
    wire [32:0] prog_mul = {16'd0, prog_wp} * 33'd656;
    reg  [9:0]  prog_w_r;
    reg  [9:0]  sky_off_r, cw_r, stx_r, sty_r;
    reg  [8:0]  ch_r;
    reg  [12:0] cam_px_r;
    reg  signed [11:0] pl_cx_r, pl_cy_r, rep_sx_r, rep_sy_r, l0_x_r, l0_y_r, l1_x_r, l1_y_r, blk_x_r, blk_y_r, tea_x_r, tea_y_r;
    reg  [7:0]  pl_asset_r;
    reg         form3_r;
    always @(posedge clk) begin
        if (rst) begin
            progress_r <= 7'd0; prog_w_r <= 10'd0; sky_off_r <= 10'd0; cam_px_r <= 13'd0;
            strp_r <= 2'd0; pci_r <= 26'd0;
            pl_cx_r <= 12'sd0; pl_cy_r <= 12'sd0; cw_r <= 10'd0; ch_r <= 9'd0;
            stx_r <= 10'd228; sty_r <= 10'd171; pl_asset_r <= 8'd0; form3_r <= 1'b0;
            rep_sx_r <= 12'sd0; rep_sy_r <= 12'sd0;
            l0_x_r <= 12'sd0; l0_y_r <= 12'sd0; l1_x_r <= 12'sd0; l1_y_r <= 12'sd0;
            blk_x_r <= 12'sd0; blk_y_r <= 12'sd0; tea_x_r <= 12'sd0; tea_y_r <= 12'sd0;
        end else begin
            strp_r     <= strp[49:48];
            pci_r      <= crop_info(pl_asset);
            progress_r <= progress;
            prog_w_r   <= prog_mul[25:16];
            sky_off_r  <= sky_off[9:0];
            cam_px_r   <= cam_px[12:0];
            pl_cx_r    <= pl_cx; pl_cy_r <= pl_cy;
            cw_r       <= cw; ch_r <= c_h[13:5];
            stx_r      <= stx; sty_r <= sty;
            pl_asset_r <= pl_asset;
            form3_r    <= (form_k == 2'd3);
            rep_sx_r   <= rep_sx; rep_sy_r <= rep_sy;
            l0_x_r     <= xs(LIFT_L0); l0_y_r <= ys(lift_top0);
            l1_x_r     <= xs(LIFT_L1); l1_y_r <= ys(lift_top1);
            blk_x_r    <= xs(tq(240)); blk_y_r <= ys(tq(6));
            tea_x_r    <= xs(tea_x) - 12'sd18; tea_y_r <= ys(tea_y) - 12'sd54;
        end
    end
    reg  [127:0] od;
    always @(*) begin
        od = OBJ_NONE;
        if (obj_idx[7:6] == 2'd0) case (obj_idx[5:0])
            6'd0: od = obj_img(-$signed({1'b0, sky_off_r}), 10'sd0, 10'd704, 9'd352,
                               (stg == 2'd1) ? A_S3_SKY1 : (stg == 2'd2) ? A_S3_SKY2 : A_S3_SKY3,
                               19'd0, 18'd0, 10'd128, 10'd128, 1'b0);
            6'd1: od = obj_tilemap(10'sd0, 9'd352, {6'd0, stg}, cam_px_r[12:5], {6'd0, cam_px_r[4:0], 8'd0});
            6'd2: if (phase_ab) od = obj_img(l0_x_r, l0_y_r, 10'd64, 9'd16, A_S3_LIFT_MOVE, 19'd0, 18'd0, 10'd256, 10'd256, 1'b0);
            6'd3: if (phase_ab) od = obj_img(l1_x_r, l1_y_r, 10'd64, 9'd16, A_S3_LIFT_SINK, 19'd0, 18'd0, 10'd256, 10'd256, 1'b0);
            6'd4: if (stg == 2'd2) od = obj_img(blk_x_r, blk_y_r, 10'd32, 9'd32, A_S3_BLOCK, 19'd0, 18'd0, 10'd256, 10'd256, 1'b0);
            6'd5: if (stg == 2'd2 && opened) od = obj_fill(blk_x_r + 12'sd3, blk_y_r + 12'sd3, 10'd26, 9'd26, 12'h975, 1'b0);
            6'd6: if (tea_on) od = obj_img(tea_x_r, tea_y_r, 10'd36, 9'd54, A_S3_TEA, 19'd0, 18'd0, 10'd256, 10'd256, 1'b0);
            6'd31: if (rep_show) od = obj_img(rep_sx_r, rep_sy_r, 10'd36, 9'd48, rep_pose ? A_REP_STEP : A_REP_STAND,
                                               19'd0, 18'd0, 10'd228, 10'd171, !rep_dir);
            6'd32, 6'd33, 6'd34: if (form_k == 2'd1) begin                  // cloak after-images (dithered)
                    od = obj_img(pl_cx_r + aft_dx, pl_cy_r, cw_r, ch_r, pl_asset_r, 19'd0, 18'd0, stx_r, sty_r, !dir_r);
                    od[126] = 1'b1;
                end
            6'd35: begin
                    od = obj_img(pl_cx_r, pl_cy_r, cw_r, ch_r, pl_asset_r, 19'd0, 18'd0, stx_r, sty_r, !dir_r);
                    od[126] = form3_r;                                      // phase: see-through
                end
            // ---- HUD (hud.py), frame coordinates (shifted down +8 px below row-1 BAR_TOP)
            6'd36: od = obj_fill(11'sd20, 10'sd21, 10'd96, 9'd26, 12'h145, 1'b0);
            6'd37: od = obj_img(11'sd14, 10'sd18, 10'd32, 9'd31, A_S3_CLOCK, 19'd0, 18'd0, 10'd256, 10'd264, 1'b0);
            6'd38: od = obj_fill(11'sd492, 10'sd17, 10'd141, 9'd43, used_now ? 12'h456 : (skill_t != 0 ? 12'h079 : 12'h268), 1'b0);
            6'd39: od = obj_img(11'sd498, 10'sd21, 10'd35, 9'd34,
                                phase_ab ? (used_now ? A_S3_SKILL_PHASE_USED : A_S3_SKILL_PHASE)
                                         : (used_now ? A_S3_SKILL_CLOAK_USED : A_S3_SKILL_CLOAK),
                                19'd0, 18'd0, 10'd256, 10'd264, 1'b0);
            6'd40, 6'd41, 6'd42, 6'd43, 6'd44:
                od = obj_fill(11'sd540 + $signed({1'b0, pip, 4'd0}) - $signed({4'd0, pip, 1'b0}), 10'sd53, 10'd12, 9'd2,
                              (!used_now && (skill_t == 0 || {1'b0, pip} < {1'b0, secs_left})) ?
                              ((skill_t != 0) ? 12'hEFF : 12'h7DF) : 12'h678, 1'b0);
            6'd45: if (mode != M_WIN) od = obj_fill(11'sd134, 10'sd326, 10'd373, 9'd22, 12'h145, 1'b0);
            6'd46: if (mode != M_WIN) od = obj_fill(11'sd168, 10'sd332, 10'd275, 9'd9, 12'h234, 1'b0);
            6'd47: if (mode != M_WIN && prog_w_r != 10'd0) od = obj_fill(11'sd168, 10'sd332, prog_w_r, 9'd9, 12'h4BD, 1'b0);
            6'd48: if (mode != M_PLAY) od = obj_blend(11'sd0, 10'sd0, 10'd640, 9'd352, 12'h023, 4'd8);
            6'd49: if (flash_t != 0) od = obj_blend(11'sd0, 10'sd0, 10'd640, 9'd352, 12'hFEA, 4'd5);
            default: if (obj_idx[5:0] >= 6'd7 && obj_idx[5:0] < 6'd31) od = vslot_desc;
        endcase
        obj_desc = od;
    end

    // ---------------------------------------------------------------- UI programs and fields
    always @(*) begin
        prog_list = 96'd0;
        prog_list[7:0]   = P_BAR_TOP;
        prog_list[15:8]  = P_BAR_BOTTOM;
        prog_list[23:16] = P_S3_HUD;
        if (interview != 0) prog_list[31:24] = P_S3_INTERVIEW;
        else if (notice_t != 0 && msg != 0 && mode == M_PLAY) prog_list[31:24] = P_S3_NOTICE;
        if (mode != M_PLAY) prog_list[39:32] = P_S3_MODAL;
        if (cloak_t != 0 && rep_show) prog_list[47:40] = P_S3_QMARK;
    end
    reg  [13:0] tsec14_r;
    wire [31:0] tsec_mul = ({18'd0, remaining} - 32'd1) * 32'd139811;
    always @(posedge clk) begin
        if (rst) tsec14_r <= 14'd120;
        else tsec14_r <= (remaining == 14'd0) ? 14'd0 : ({6'd0, tsec_mul[31:24]} + 14'd1);
    end
    wire [13:0] tsec14 = tsec14_r;               // ceil(remaining)
    wire [2:0]  st_idx = used_now ? 3'd1 : (skill_t != 0) ? 3'd1 + secs_left[2:0] : 3'd0;
    wire signed [11:0] q_col = (xs(rep_x) + 12'sd4) >>> 3;
    wire signed [11:0] rep_qv = ys(rep_y + 32'sd127795);
    wire signed [11:0] q_row = (rep_qv < 12'sd0) ? 12'sd0 : (rep_qv >>> 3);
    reg [159:0] fs;
    always @(*) begin
        fs = 160'd0; fld_val = 16'd0;
        case (fld_id)
            F_BAR_TITLE:  fld_val = T_BAR_TITLE_S3;
            F_BAR_HELP:   fld_val = T_BAR_HELP_S3;
            F_FORM:       fld_val = gold ? 16'd3 : {14'd0, hi_form};
            F_S3_TIME:    fs = str_u8(tsec14[7:0]);
            F_S3_ABILITY: fld_val = {15'd0, phase_ab};
            F_S3_STATUS:  fld_val = {13'd0, st_idx};
            F_S3_STAGE:   fld_val = {14'd0, stg - 2'd1};
            F_S3_PCT:     fs = str_u8({1'b0, progress_r}) | ({8'h25, 152'd0} >> ((progress_r >= 7'd100) ? 24 : (progress_r >= 7'd10) ? 16 : 8));
            F_S3_MSG:     fld_val = {11'd0, msg};
            F_S3_QL0:     fld_val = {11'd0, ((interview > 14'd300) ? q0 : q1), 1'b0};
            F_S3_QL1:     fld_val = {11'd0, ((interview > 14'd300) ? q0 : q1), 1'b1};
            F_S3_Q_COL:   fld_val = {{4{q_col[11]}}, q_col};
            F_S3_Q_ROW:   fld_val = {{4{q_row[11]}}, q_row};
            default: ;
        endcase
        fld_char = str_at(fs, fld_idx);
    end
    always @(*) begin
        case (cond_id)
            C_S3_USED:      cond_val = used_now;
            C_S3_READY:     cond_val = !skill_used && skill_t == 0;
            C_S3_ACTIVE:    cond_val = skill_t != 0;
            C_S3_PAUSE:     cond_val = mode == M_PAUSE;
            C_S3_CLEARMODE: cond_val = mode == M_CLEAR;
            C_S3_WIN:       cond_val = mode == M_WIN;
            C_S3_CLEAR1:    cond_val = mode == M_CLEAR && stg == 2'd1;
            C_S3_CLEAR2:    cond_val = mode == M_CLEAR && stg == 2'd2;
            default:        cond_val = 1'b0;
        endcase
    end
    always @(*) begin
        // stage3_demo panel: "H<hearts> StG3-<skill seconds>"
        seg_text = {"H", 6'd12, hi_hearts, "StG3-", 4'd3, (mode == M_PLAY || mode == M_PAUSE) ? secs_left : 4'd0};
        leds = {6'd0, chase, interview != 0, skill_t != 0, skill_used, gold, mode == M_CLEAR, stg == 2'd3, stg == 2'd2, stg == 2'd1, mode == M_WIN};
    end
endmodule
