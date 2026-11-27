// stage1.v - STAGE 1: FINAL EXAM (port of demo_py/stage1_demo.py, the reference).
//
// Organisation (same order as the Pygame Game class):
//   1. state registers               (reset_stage)
//   2. per-frame update state machine (update / map_update / closeup_input / cards_input)
//   3. scene objects for line_engine  (draw_world / draw_closeup / draw_cards ...)
//   4. UI bindings for ui_painter     (fields + conditions + program list)
//   5. 7-segment text and LEDs        (draw_panel)
// The game logic runs once per video frame (frame_tick, 60 Hz) like Pygame's clock.tick(60).
// Positions are fixed point (8 fraction bits) world pixels of the 2000x1116 room.
`timescale 1ns / 1ps
module stage1 (
    input  wire         clk,
    input  wire         rst,
    input  wire         active,           // this scene is on screen
    input  wire         start,            // start(handoff): fresh stage
    input  wire         frame,            // frame_tick
    input  wire [4:0]   lvl,              // held buttons U D L R C
    input  wire [4:0]   ev_press,
    input  wire         ev_tap,
    input  wire         ev_back,
    input  wire [15:0]  sw,
    input  wire [15:0]  sw_rise,
    input  wire [15:0]  sw_fall,
    // demo-hub style test hooks (testbench / debug switches)
    input  wire         dbg_jump,
    input  wire [2:0]   dbg_key,          // 0 start 1 r2 2 r3 3 door 4 clear
    input  wire         dbg_armor,
    input  wire         dbg_door_wrong,
    input  wire         dbg_set_hearts,
    input  wire [1:0]   dbg_hearts,
    input  wire         dbg_set_form,
    input  wire [1:0]   dbg_form,
    // hand-off to the next stage (get_handoff)
    output reg          done,
    output wire [1:0]   ho_hearts,
    output wire [1:0]   ho_armor,
    output wire         ho_shard,
    output wire         ho_boost,
    output wire [1:0]   ho_form,
    output wire [1:0]   ho_career,
    output wire [3:0]   ho_backs,
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
    output reg  [63:0]  seg_text,
    output reg  [15:0]  leds
);
`include "asset_ids.vh"
`include "ui_ids.vh"
`include "sprite_place.vh"
`include "desc.vh"
`include "lfsr.vh"
`include "strutil.vh"

    // ------------------------------------------------------------------ constants
    localparam B_U = 0, B_D = 1, B_L = 2, B_R = 3, B_C = 4;
    // objects (OBJS order): whiteboard, paper, laptop3 (NAND), laptop4 (two's), projector, pc, light switch, door
    localparam O_WB = 3'd0, O_PAPER = 3'd1, O_NAND = 3'd2, O_TWOS = 3'd3, O_SCREEN = 3'd4, O_PC = 3'd5,
               O_LIGHT = 3'd6, O_DOOR = 3'd7;
    localparam [19:0] SPAWN_X = 20'd1300 << 8, SPAWN_Y = 20'd405 << 8;
    localparam ST_PLAY = 2'd0, ST_CLEAR = 2'd1, ST_OVER = 2'd2;
    localparam FB_NONE = 2'd0, FB_OK = 2'd1, FB_BAD = 2'd2;
    // note ids (T_S1_NOTE rows) and hint ids (T_S1_HINTSEEN rows: P1..P5 = 1..5)
    localparam N_P1 = 3'd1, N_P2A = 3'd2, N_P2B = 3'd3, N_P3 = 3'd4, N_P4 = 3'd5, N_P5 = 3'd6;

    function [10:0] obj_ax; input [2:0] o;
        case (o) 0: obj_ax = 300; 1: obj_ax = 700; 2: obj_ax = 1370; 3: obj_ax = 570; 4: obj_ax = 1560;
                 5: obj_ax = 1540; 6: obj_ax = 1150; default: obj_ax = 1340; endcase
    endfunction
    function [10:0] obj_ay; input [2:0] o;
        case (o) 0: obj_ay = 580; 1: obj_ay = 400; 2: obj_ay = 920; 3: obj_ay = 690; 4: obj_ay = 400;
                 5: obj_ay = 650; 6: obj_ay = 310; default: obj_ay = 300; endcase
    endfunction
    function [7:0] obj_r; input [2:0] o;
        case (o) 0: obj_r = 180; 1: obj_r = 130; 2: obj_r = 160; 3: obj_r = 150; 4: obj_r = 120;
                 5: obj_r = 120; 6: obj_r = 100; default: obj_r = 120; endcase
    endfunction

    // ------------------------------------------------------------------ 1. state
    reg [15:0] lfsr;
    reg [19:0] px, py;                     // 12.8 fixed
    reg [1:0]  form;
    reg [1:0]  state;
    reg        mode_cu;                    // 0 map, 1 close-up
    reg [2:0]  cur;
    reg [1:0]  page;
    reg        intro_on;  reg [1:0] intro_idx;
    reg        show_help;
    reg        nb_pending, nb_seen;
    reg        lights;
    reg [4:0]  pdone, pright;
    reg        ans_a, ans_b, ans_c;        // answers logged (values are fixed: 6, 7, 5)
    reg [3:0]  t_used [0:2];
    reg [3:0]  t_pol  [0:2];
    reg [1:0]  p2_cur;
    reg [3:0]  eq_used [0:2];              // snapshot shown as "LOGGED: F = ..."
    reg [3:0]  eq_pol  [0:2];
    reg [2:0]  p3 [0:8];
    reg [3:0]  p3_cur;
    reg [4:0]  p5 [0:2];
    reg [1:0]  p5_cur;
    reg        p5_seen;
    reg [2:0]  notes [0:5];  reg [2:0] n_notes;
    reg [2:0]  hints [0:4];  reg [2:0] n_hints;
    reg [9:0]  slow_t, freeze_t;           // frames
    reg        door_l2;
    reg [3:0]  dig [0:4];
    reg [2:0]  door_cur;
    reg [1:0]  career;  reg career_ok;
    reg [1:0]  back0, back1; reg [1:0] n_backs;
    reg [3:1]  r_run, r_done;
    reg [4:0]  toast;   reg [7:0] toast_t;
    reg [4:0]  flash_t;
    reg [7:0]  over_t;
    reg [4:0]  cmsg;    reg [1:0] feedback;
    reg [3:0]  card_name; reg [3:0] card_desc;
    reg        boost;

    // ---- shared modules ----
    reg        ha_load, ha_damage, ha_add_armor, ha_add_shard;
    wire [1:0] hearts, armor;
    wire       shard, ha_blocked, ha_hit, ha_zero, ha_forged;
    reg  [1:0] ld_hearts, ld_armor; reg ld_shard;
    heart_armor u_ha (.clk(clk), .rst(rst), .load(ha_load), .load_hearts(ld_hearts), .load_armor(ld_armor), .load_shard(ld_shard),
                      .damage(ha_damage), .add_armor(ha_add_armor), .add_shard(ha_add_shard),
                      .hearts(hearts), .armor(armor), .shard(shard), .blocked(ha_blocked), .hit(ha_hit),
                      .zero(ha_zero), .forged(ha_forged));

    reg        dk_clear, dk_open, dk_upd;
    reg [1:0]  dk_round;
    reg [2:0]  dk_perm;
    wire       dk_active, dk_face, dk_pick, dk_done, dk_skipped;
    wire [1:0] dk_cur, dk_rnd, dk_fpos, dk_ppos, dk_pidx;
    wire [2:0] dk_perm_q;
    card_deck u_deck (.clk(clk), .rst(rst), .clear(dk_clear), .open(dk_open), .open_round(dk_round), .open_perm(dk_perm),
                      .upd(dk_upd), .ev_left(ev_press[B_L]), .ev_right(ev_press[B_R]), .ev_tap(ev_tap), .ev_back(ev_back),
                      .allow_skip(1'b0), .active(dk_active), .round(dk_rnd), .cursor(dk_cur), .face(dk_face),
                      .face_pos(dk_fpos), .perm(dk_perm_q), .pick(dk_pick), .pick_pos(dk_ppos), .pick_idx(dk_pidx),
                      .done(dk_done), .skipped(dk_skipped));

    reg        sp_reset, sp_upd, sp_stop;
    reg signed [1:0] sp_dx, sp_dy;
    reg        sp_moved;
    wire [1:0] sp_dir, sp_pose;
    sprite_anim #(.MODE(1)) u_anim (.clk(clk), .rst(rst), .reset_dir(sp_reset), .upd(sp_upd), .stop(sp_stop),
                                    .dx(sp_dx), .dy(sp_dy), .moved(sp_moved), .dir(sp_dir), .pose(sp_pose));

    // ---- puzzle checkers ----
    wire [15:0] p2_table, p3_table;
    wire [3:0]  p2_lits;
    wire        p2_ok, p3_ok;
    wire [4:0]  p3_ones;
    s1_puzzles u_pz (.t0_used(t_used[0]), .t0_pol(t_pol[0]), .t1_used(t_used[1]), .t1_pol(t_pol[1]),
                     .t2_used(t_used[2]), .t2_pol(t_pol[2]), .p2_table(p2_table), .p2_lits(p2_lits), .p2_ok(p2_ok),
                     .p3_fields({p3[8], p3[7], p3[6], p3[5], p3[4], p3[3], p3[2], p3[1], p3[0]}),
                     .p3_table(p3_table), .p3_ok(p3_ok), .p3_ones(p3_ones));

    // ---- collision (one query port, registered response via U_MXW / U_MYW for 74.25 MHz) ----
    reg  signed [12:0] q_x, q_y;
    wire q_blocked;
    reg  q_blocked_r;
    s1_collision u_col (.x(q_x), .y(q_y), .blocked(q_blocked));

    // ------------------------------------------------------------------ helpers
    wire [2:0] n_done = pdone[0] + pdone[1] + pdone[2] + pdone[3] + pdone[4];
    wire [7:0] p1_val = {4'd0, sw[3:0]};
    wire [7:0] p4_val = sw[7:0];
    // speed(): 360 px/s (x1.2 from form 1), x0.1 when slowed, 0 when frozen -> per frame (1/256 px)
    wire [11:0] spd = (freeze_t != 0) ? 12'd0 :
                      (form >= 2'd1) ? ((slow_t != 0) ? 12'd184 : 12'd1843) :
                                       ((slow_t != 0) ? 12'd154 : 12'd1536);
    wire signed [1:0] in_dx = (lvl[B_R] ? 2'sd1 : 2'sd0) - (lvl[B_L] ? 2'sd1 : 2'sd0);
    wire signed [1:0] in_dy = (lvl[B_D] ? 2'sd1 : 2'sd0) - (lvl[B_U] ? 2'sd1 : 2'sd0);
    // smart hint (HINT_BY_TRUTH = True): P5 first, then P3 -> P2 -> P1 -> P4 not yet right
    wire [2:0] smart_key = !pdone[4] ? 3'd5 : !pright[2] ? 3'd3 : !pright[1] ? 3'd2 : !pright[0] ? 3'd1 :
                           !pright[3] ? 3'd4 : 3'd0;
    wire       any_sw_edge = (sw_rise | sw_fall) != 16'd0;
    wire       help_now = sw_rise[15] ? 1'b1 : sw_fall[15] ? 1'b0 : show_help;
    wire       paged = (cur == O_WB) || (cur == O_PAPER) || (cur == O_NAND) || (cur == O_TWOS) || (cur == O_PC);
    wire [2:0] door_n = door_l2 ? 3'd5 : 3'd2;
    wire       door_match = door_l2 ? (dig[0] == 1 && dig[1] == 7 && dig[2] == 8 && dig[3] == 6 && dig[4] == 5)
                                    : (dig[0] == 6 && dig[1] == 9);

    // P3 field option count: G1 fields 4 (A-D), G2 5, G3 6, G4 7; F selects G1..G4
    wire [2:0] p3_n = (p3_cur == 8) ? 3'd4 : 3'd4 + p3_cur[3:1];
    // P2 note text: which term comes first in the stored expression
    wire first_term_is_ab = (t_used[0] != 0) ? (t_used[0] == 4'b1100) : (t_used[1] != 0) ? (t_used[1] == 4'b1100)
                                                                                      : (t_used[2] == 4'b1100);

    // ------------------------------------------------------------------ 2. update FSM
    localparam U_IDLE = 4'd0, U_MAIN = 4'd1, U_CARD = 4'd2, U_CARDIN = 4'd3, U_MX = 4'd4, U_MXR = 4'd5,
               U_MYR = 4'd6, U_NEAR0 = 4'd7, U_NEAR = 4'd8, U_NEAR2 = 4'd12, U_JUMP = 4'd9, U_CLOSE = 4'd10, U_INTERACT = 4'd11,
               U_MXW = 4'd13, U_MYW = 4'd14;
    reg [3:0]  u;
    reg        map_frame;                  // map_update ran this frame (tap -> interact)
    reg [19:0] tx, ty;                     // trial coordinates
    reg        moved_x;
    wire [19:0] ty_w = py + ((in_dy > 0) ? {8'd0, spd} : (in_dy < 0) ? -{8'd0, spd} : 20'd0);
    reg [2:0]  ni, ni_r;                   // find_near loop
    reg        near_ok;  reg [2:0] near_id;
    reg        best_ok;  reg [2:0] best_id;  reg [31:0] best_d2; reg [15:0] best_r2;
    reg [31:0] nd2_r;    reg [17:0] nR2_r;
    reg [2:0]  jkey;
    reg        jump_pending;

    // find_near distance (1/16 px units) of object ni (stage 1: nd2 & nR2, stage 2: threshold + cross-multiply compare)
    wire signed [16:0] ndx = $signed({1'b0, px[19:4]}) - $signed({2'b0, obj_ax(ni), 4'd0});
    wire signed [16:0] ndy = $signed({1'b0, py[19:4]}) - $signed({2'b0, obj_ay(ni), 4'd0});
    wire [31:0] nd2 = ndx * ndx + ndy * ndy;
    wire [8:0]  nR  = obj_r(ni) + ((form >= 2'd1) ? 9'd30 : 9'd0);
    wire [17:0] nR2 = nR * nR;
    wire        n_in_r = nd2_r <= {nR2_r, 8'd0};                 // score <= 1.0
    wire [49:0] lhs = nd2_r * best_r2, rhs = best_d2 * nR2_r;    // score_i < score_best

    // note / hint list helpers
    function note_has; input [2:0] id; integer j; begin
        note_has = 1'b0;
        for (j = 0; j < 6; j = j + 1) if (j < n_notes && notes[j] == id) note_has = 1'b1;
    end endfunction
    function hint_has; input [2:0] id; integer j; begin
        hint_has = 1'b0;
        for (j = 0; j < 5; j = j + 1) if (j < n_hints && hints[j] == id) hint_has = 1'b1;
    end endfunction

    task add_note; input [2:0] id; begin
        if (!note_has(id) && n_notes < 6) begin notes[n_notes] <= id; n_notes <= n_notes + 3'd1; end
    end endtask
    task add_hint; input [2:0] id; begin
        if (!hint_has(id) && n_hints < 5) begin hints[n_hints] <= id; n_hints <= n_hints + 3'd1; end
    end endtask
    task remove_p4_note; integer j, o; begin       // notes = [n for n in notes if not n.startswith("P4 ")]
        o = 0;
        for (j = 0; j < 6; j = j + 1)
            if (j < n_notes && notes[j] != N_P4) begin notes[o] <= notes[j]; o = o + 1; end
        n_notes <= o;
    end endtask
    task say; input [4:0] id; begin toast <= id; toast_t <= 8'd150; end endtask   // 2.5 s
    task clear_feedback; begin feedback <= FB_NONE; cmsg <= 5'd0; end endtask
    task commit_bad; input [2:0] i; begin
        if (!pdone[i]) pright[i] <= 1'b0;
        feedback <= FB_BAD;
        cmsg <= T_S1_CMSG_BAD1 + {i, 1'b0};
        say(T_TOAST_INCORRECT);
    end endtask
    task commit_ok; input [2:0] i; input [2:0] note; begin
        pdone[i] <= 1'b1; pright[i] <= 1'b1;
        add_note(note);
        if ((i == 0 || i == 2 || i == 3) && !nb_seen) nb_pending <= 1'b1;
        feedback <= FB_OK;
        cmsg <= T_S1_CMSG_OK1 + {i, 1'b0};
        say(T_TOAST_P1_OK + i);
    end endtask

    task reset_stage; input full; integer j; begin
        if (full) form <= 2'd0;
        px <= SPAWN_X; py <= SPAWN_Y; sp_reset <= 1'b1;
        intro_on <= full; intro_idx <= 2'd0;
        mode_cu <= 1'b0; cur <= 3'd0; page <= 2'd0; cmsg <= 5'd0; feedback <= FB_NONE;
        nb_pending <= 1'b0; nb_seen <= 1'b0; state <= ST_PLAY; lights <= 1'b1;
        pdone <= 5'd0; pright <= 5'd0; ans_a <= 1'b0; ans_b <= 1'b0; ans_c <= 1'b0;
        for (j = 0; j < 3; j = j + 1) begin t_used[j] <= 4'd0; t_pol[j] <= 4'd0; eq_used[j] <= 4'd0; eq_pol[j] <= 4'd0; p5[j] <= 5'd0; end
        p2_cur <= 2'd0; p3_cur <= 4'd0; p5_cur <= 2'd0; p5_seen <= 1'b0;
        for (j = 0; j < 9; j = j + 1) p3[j] <= 3'd0;
        n_notes <= 3'd0; n_hints <= 3'd0;
        slow_t <= 10'd0; freeze_t <= 10'd0; boost <= 1'b0;
        ha_load <= 1'b1; ld_hearts <= 2'd3; ld_armor <= 2'd0; ld_shard <= 1'b0;
        door_l2 <= 1'b0; door_cur <= 3'd0;
        for (j = 0; j < 5; j = j + 1) dig[j] <= 4'd0;
        dk_clear <= 1'b1; career_ok <= 1'b0; n_backs <= 2'd0;
        r_run <= 3'd0; r_done <= 3'd0;
        toast_t <= 8'd0; flash_t <= 5'd0;
        card_name <= 4'd0; card_desc <= 4'd0;
    end endtask

    task auto_answer; input [2:0] i; begin           // demo hub helper (jump_to)
        case (i)
            3'd0: ans_a <= 1'b1;
            3'd1: begin
                t_used[0] <= 4'b1100; t_pol[0] <= 4'b1100; t_used[1] <= 4'b0011; t_pol[1] <= 4'b0011;
                t_used[2] <= 4'd0; t_pol[2] <= 4'd0;
                eq_used[0] <= 4'b1100; eq_pol[0] <= 4'b1100; eq_used[1] <= 4'b0011; eq_pol[1] <= 4'b0011;
                eq_used[2] <= 4'd0;
            end
            3'd2: begin
                p3[0] <= 0; p3[1] <= 1; p3[2] <= 2; p3[3] <= 3; p3[4] <= 4; p3[5] <= 5; p3[6] <= 0; p3[7] <= 0; p3[8] <= 2;
                ans_b <= 1'b1;
            end
            3'd3: ans_c <= 1'b1;
            default: begin p5[0] <= 5'd2; p5[1] <= 5'd15; p5[2] <= 5'd4; end
        endcase
        pdone[i] <= 1'b1; pright[i] <= 1'b1;
    end endtask

    // item grant (grant() of stage1_demo): returns name/desc indices and applies the effect
    task grant; input [1:0] rnd; input [1:0] idx; begin
        // CARD_ITEMS: 1: HINT_HARD HINT_HARD ARMOR  2: SHARD SLOW HINT_SMART  3: FREEZE UNDO SHARD
        if (rnd == 2'd1 && idx != 2'd2) begin                       // HINT_HARD -> P3 hint
            add_hint(3'd3); card_name <= T_ITEM_NAME_HINT; card_desc <= T_CARD_DESC_HINT_P3;
        end else if (rnd == 2'd1) begin                             // ARMOR
            ha_add_armor <= 1'b1; card_name <= T_ITEM_NAME_ARMOR; card_desc <= T_CARD_DESC_ARMOR;
        end else if ((rnd == 2'd2 && idx == 2'd0) || (rnd == 2'd3 && idx == 2'd2)) begin   // SHARD
            ha_add_shard <= 1'b1; card_name <= T_ITEM_NAME_SHARD;
            card_desc <= shard ? T_CARD_DESC_SHARD_FORGE : T_CARD_DESC_SHARD_HALF;
        end else if (rnd == 2'd2 && idx == 2'd1) begin              // SLOW
            slow_t <= 10'd600; card_name <= T_ITEM_NAME_SLOW; card_desc <= T_CARD_DESC_SLOW;
        end else if (rnd == 2'd2) begin                             // HINT_SMART
            card_name <= T_ITEM_NAME_HINT;
            if (smart_key == 3'd0) card_desc <= T_CARD_DESC_NO_HINT;
            else begin add_hint(smart_key); card_desc <= T_CARD_DESC_HINT_P1 + smart_key - 1; end
        end else if (idx == 2'd0) begin                             // FREEZE (round 3)
            freeze_t <= 10'd600; card_name <= T_ITEM_NAME_FREEZE; card_desc <= T_CARD_DESC_FREEZE;
        end else begin                                              // UNDO
            card_name <= T_ITEM_NAME_UNDO;
            if (!pdone[3]) card_desc <= T_CARD_DESC_UNDO_NONE;
            else begin
                ans_c <= 1'b0; pdone[3] <= 1'b0; pright[3] <= 1'b0; remove_p4_note;
                card_desc <= T_CARD_DESC_UNDO_P4;
            end
        end
    end endtask

    always @(posedge clk) begin
        sp_reset <= 1'b0; sp_upd <= 1'b0; sp_stop <= 1'b0;
        ha_load <= 1'b0; ha_damage <= 1'b0; ha_add_armor <= 1'b0; ha_add_shard <= 1'b0;
        dk_clear <= 1'b0; dk_open <= 1'b0; dk_upd <= 1'b0;
        done <= 1'b0;
        if (rst) begin
            u <= U_IDLE; lfsr <= 16'hACE1; show_help <= 1'b0; jump_pending <= 1'b0;
            toast <= 5'd0; over_t <= 8'd0; near_ok <= 1'b0; near_id <= 3'd0;
            reset_stage(1'b1);
        end else if (start) begin
            reset_stage(1'b1); show_help <= 1'b0; u <= U_IDLE;
        end else begin
            // ---- reactions of the heart system (door_damage) ----
            if (ha_blocked) say(T_TOAST_ARMOR_PROT);
            if (ha_hit) begin
                flash_t <= 5'd24;                                   // 0.4 s red flash
                if (ha_zero) begin state <= ST_OVER; over_t <= 8'd180; end
                else say(T_TOAST_WRONG_CODE);
            end
            if (dbg_jump) begin jump_pending <= 1'b1; jkey <= dbg_key; end
            if (dbg_door_wrong) begin jump_pending <= 1'b1; jkey <= 3'd5; end
            if (dbg_armor) begin ha_add_armor <= 1'b1; say(T_TOAST_ARMOR_P1); end
            if (dbg_set_form) form <= dbg_form;
            if (dbg_set_hearts) begin                       // set_hearts(n)
                ha_load <= 1'b1; ld_hearts <= dbg_hearts; ld_armor <= armor; ld_shard <= shard;
                if (state == ST_OVER) state <= ST_PLAY;
            end

            case (u)
            U_IDLE: begin
                if (jump_pending) begin jump_pending <= 1'b0; u <= U_JUMP; end
                else if (active && frame) begin
                    lfsr <= lfsr_next7(lfsr);
                    if (toast_t != 0) toast_t <= toast_t - 8'd1;
                    if (over_t != 0) over_t <= over_t - 8'd1;
                    u <= U_MAIN;
                end
            end
            // ------------------------------------------------ update()
            U_MAIN: begin
                u <= U_NEAR0;
                map_frame <= 1'b0;
                if (flash_t != 0) flash_t <= flash_t - 5'd1;
                // poll(): switch clicks while a switch-driven close-up is open clear the feedback
                if (any_sw_edge && mode_cu && (cur == O_WB || cur == O_PAPER || cur == O_TWOS)) clear_feedback;
                show_help <= help_now;
                if (help_now) begin
                    if (ev_tap || ev_back) show_help <= 1'b0;
                end else if (intro_on) begin
                    sp_stop <= 1'b1;
                    if (ev_back) intro_on <= 1'b0;
                    else if (ev_tap) begin
                        if (intro_idx < 2'd2) intro_idx <= intro_idx + 2'd1;
                        else intro_on <= 1'b0;
                    end
                end else if (nb_pending) begin
                    if (sw[14]) begin nb_pending <= 1'b0; nb_seen <= 1'b1; end
                    else sp_stop <= 1'b1;
                end else if (state == ST_CLEAR) begin
                    if (ev_tap) done <= 1'b1;                       // exit_requested
                end else if (state == ST_OVER) begin
                    if (over_t == 0) reset_stage(1'b0);
                end else begin
                    if (slow_t != 0) slow_t <= slow_t - 10'd1;
                    if (freeze_t != 0) freeze_t <= freeze_t - 10'd1;
                    // card_trigger()
                    if (!dk_active && ((!r_run[1]) || (r_done[1] && !r_run[2] && n_done >= 3) ||
                                       (r_done[2] && !r_run[3] && n_done == 5))) begin
                        dk_round <= !r_run[1] ? 2'd1 : !r_run[2] ? 2'd2 : 2'd3;
                        u <= U_CARD;
                    end else if (dk_active) begin
                        sp_stop <= 1'b1; u <= U_CARDIN;
                    end else if (sw[14]) begin
                        sp_stop <= 1'b1;
                    end else if (!mode_cu) begin
                        if (slow_t > 10'd1) slow_t <= slow_t - 10'd2;          // map mode counts down twice
                        else slow_t <= 10'd0;
                        if (freeze_t > 10'd1) freeze_t <= freeze_t - 10'd2;
                        else freeze_t <= 10'd0;
                        map_frame <= 1'b1;
                        tx <= px + ((in_dx > 0) ? {8'd0, spd} : (in_dx < 0) ? -{8'd0, spd} : 20'd0);
                        u <= U_MX;
                    end else begin
                        sp_stop <= 1'b1;
                        u <= U_CLOSE;
                    end
                end
            end
            // ------------------------------------------------ card_start(): LFSR rejection sampling
            U_CARD: begin
                lfsr <= lfsr_next(lfsr);
                if ((lfsr_next(lfsr) & 16'd7) < 16'd6) begin
                    dk_perm <= lfsr_next(lfsr) & 3'd7;
                    dk_open <= 1'b1;
                    r_run[dk_round] <= 1'b1;
                    sp_stop <= 1'b1;
                    u <= U_CARDIN;
                end
            end
            U_CARDIN: begin                         // cards_input(ev)
                dk_upd <= 1'b1;
                u <= U_NEAR0;
            end
            // ------------------------------------------------ map_update(): move x, then y (pipelined u_col lookup)
            U_MX: begin                                     // blocked(px + dx*sp, py) ?
                q_x <= tx[19:8]; q_y <= py[19:8];
                u <= U_MXW;
            end
            U_MXW: begin
                q_blocked_r <= q_blocked;
                u <= U_MXR;
            end
            U_MXR: begin
                moved_x <= !q_blocked_r && in_dx != 0 && spd != 0;
                if (!q_blocked_r && in_dx != 0) px <= tx;
                q_x <= (!q_blocked_r && in_dx != 0) ? tx[19:8] : px[19:8];     // y test uses the new x
                ty  <= ty_w;
                q_y <= ty_w[19:8];
                u <= U_MYW;
            end
            U_MYW: begin
                q_blocked_r <= q_blocked;
                u <= U_MYR;
            end
            U_MYR: begin
                if (!q_blocked_r && in_dy != 0) py <= ty;
                sp_dx <= in_dx; sp_dy <= in_dy;
                sp_moved <= moved_x || (!q_blocked_r && in_dy != 0 && spd != 0);
                sp_upd <= 1'b1;
                u <= U_NEAR0;
            end
            // ------------------------------------------------ find_near() (2-cycle pipelined to meet 74.25 MHz)
            U_NEAR0: begin
                ni <= 3'd0; best_ok <= 1'b0;
                u <= U_NEAR;
            end
            U_NEAR: begin
                nd2_r <= nd2; nR2_r <= nR2; ni_r <= ni;
                u <= U_NEAR2;
            end
            U_NEAR2: begin
                if (n_in_r && (!best_ok || lhs < rhs)) begin
                    best_ok <= 1'b1; best_id <= ni_r; best_d2 <= nd2_r; best_r2 <= nR2_r[15:0];
                end
                if (ni_r == 3'd7) begin
                    near_ok <= (n_in_r && (!best_ok || lhs < rhs)) ? 1'b1 : best_ok;
                    near_id <= (n_in_r && (!best_ok || lhs < rhs)) ? ni_r : best_id;
                    u <= map_frame ? U_INTERACT : U_IDLE;
                end else begin
                    ni <= ni_r + 3'd1;
                    u  <= U_NEAR;
                end
            end
            U_INTERACT: begin                               // map_update: "if ev['tap']: interact"
                u <= U_IDLE;
                if (ev_tap && near_ok) begin
                    mode_cu <= 1'b1; cur <= near_id; page <= 2'd0; cmsg <= 5'd0; feedback <= FB_NONE;
                    sp_stop <= 1'b1;
                    if (near_id == O_SCREEN && !lights) p5_seen <= 1'b1;
                end
            end
            // ------------------------------------------------ closeup_input()
            U_CLOSE: begin
                u <= U_NEAR0;
                if (ev_back) begin
                    if (page != 2'd0 && paged) page <= page - 2'd1;
                    else mode_cu <= 1'b0;
                    cmsg <= 5'd0;
                end else case (cur)
                    O_WB: begin
                        if (page == 0) begin if (ev_tap) page <= 2'd1; end
                        else if (ev_tap) begin
                            if (p1_val == 8'd6) begin ans_a <= 1'b1; commit_ok(3'd0, N_P1); end
                            else commit_bad(3'd0);
                        end
                    end
                    O_PAPER: begin
                        if (page == 0) begin if (ev_tap) page <= 2'd1; end
                        else if (ev_press[B_U]) begin clear_feedback; p2_cur <= (p2_cur == 0) ? 2'd2 : p2_cur - 2'd1; end
                        else if (ev_press[B_D]) begin clear_feedback; p2_cur <= (p2_cur == 2) ? 2'd0 : p2_cur + 2'd1; end
                        else if (ev_tap) begin
                            t_used[p2_cur] <= sw[7:4]; t_pol[p2_cur] <= sw[3:0];
                            feedback <= FB_NONE;
                            cmsg <= T_S1_CMSG_TERM1 + p2_cur;
                        end else if (ev_press[B_R]) begin
                            if (t_used[0] == 0 && t_used[1] == 0 && t_used[2] == 0) begin
                                feedback <= FB_BAD; cmsg <= T_S1_CMSG_NOTERMS;
                            end else begin
                                eq_used[0] <= t_used[0]; eq_pol[0] <= t_pol[0];
                                eq_used[1] <= t_used[1]; eq_pol[1] <= t_pol[1];
                                eq_used[2] <= t_used[2]; eq_pol[2] <= t_pol[2];
                                if (p2_ok) commit_ok(3'd1, (first_term_is_ab ? N_P2A : N_P2B));
                                else commit_bad(3'd1);
                            end
                        end
                    end
                    O_NAND: begin
                        if (page == 0) begin if (ev_tap) page <= 2'd1; end
                        else if (ev_press[B_L]) begin clear_feedback; p3_cur <= (p3_cur == 0) ? 4'd8 : p3_cur - 4'd1; end
                        else if (ev_press[B_R]) begin clear_feedback; p3_cur <= (p3_cur == 8) ? 4'd0 : p3_cur + 4'd1; end
                        else if (ev_press[B_U] || ev_press[B_D]) begin
                            clear_feedback;
                            if (ev_press[B_U]) p3[p3_cur] <= (p3[p3_cur] + 3'd1 >= p3_n) ? 3'd0 : p3[p3_cur] + 3'd1;
                            else               p3[p3_cur] <= (p3[p3_cur] == 0) ? p3_n - 3'd1 : p3[p3_cur] - 3'd1;
                        end else if (ev_tap) begin
                            if (p3_ok) begin ans_b <= 1'b1; commit_ok(3'd2, N_P3); end
                            else commit_bad(3'd2);
                        end
                    end
                    O_TWOS: begin
                        if (page == 0) begin if (ev_tap) page <= 2'd1; end
                        else if (ev_tap) begin
                            if (p4_val == 8'hF4) begin ans_c <= 1'b1; commit_ok(3'd3, N_P4); end
                            else commit_bad(3'd3);
                        end
                    end
                    O_LIGHT: if (ev_tap) begin
                        lights <= !lights;
                        say(lights ? T_TOAST_LIGHTS_OFF : T_TOAST_LIGHTS_ON);
                    end
                    O_PC: begin
                        if (pdone[4]) begin
                            if (ev_press[B_D] || ev_tap) page <= (page == 2) ? 2'd2 : page + 2'd1;
                            else if (ev_press[B_U]) page <= (page == 0) ? 2'd0 : page - 2'd1;
                        end
                        else if (ev_press[B_L]) begin clear_feedback; p5_cur <= (p5_cur == 0) ? 2'd2 : p5_cur - 2'd1; end
                        else if (ev_press[B_R]) begin clear_feedback; p5_cur <= (p5_cur == 2) ? 2'd0 : p5_cur + 2'd1; end
                        else if (ev_press[B_U]) begin clear_feedback; p5[p5_cur] <= (p5[p5_cur] == 0) ? 5'd25 : p5[p5_cur] - 5'd1; end
                        else if (ev_press[B_D]) begin clear_feedback; p5[p5_cur] <= (p5[p5_cur] == 25) ? 5'd0 : p5[p5_cur] + 5'd1; end
                        else if (ev_tap) begin
                            if (p5[0] == 5'd2 && p5[1] == 5'd15 && p5[2] == 5'd4) begin commit_ok(3'd4, N_P5); page <= 2'd0; end
                            else commit_bad(3'd4);
                        end
                    end
                    O_DOOR: begin
                        if (ev_press[B_L]) door_cur <= (door_cur == 0) ? door_n - 3'd1 : door_cur - 3'd1;
                        else if (ev_press[B_R]) door_cur <= (door_cur == door_n - 1) ? 3'd0 : door_cur + 3'd1;
                        else if (ev_press[B_U]) dig[door_cur] <= (dig[door_cur] == 9) ? 4'd0 : dig[door_cur] + 4'd1;
                        else if (ev_press[B_D]) dig[door_cur] <= (dig[door_cur] == 0) ? 4'd9 : dig[door_cur] - 4'd1;
                        else if (ev_tap) begin
                            if (door_match) begin
                                dig[0] <= 0; dig[1] <= 0; dig[2] <= 0; dig[3] <= 0; dig[4] <= 0; door_cur <= 3'd0;
                                if (!door_l2) begin door_l2 <= 1'b1; cmsg <= T_S1_CMSG_LOCK1; end
                                else begin state <= ST_CLEAR; form <= 2'd1; end
                            end else begin
                                cmsg <= T_S1_CMSG_WRONG;
                                ha_damage <= 1'b1;                 // door_damage(): ONLY source of damage
                            end
                        end
                    end
                    default: ;                                     // projector screen: look only
                endcase
            end
            // ------------------------------------------------ demo hub: jump_to / do_action
            U_JUMP: begin
                u <= U_IDLE;
                reset_stage(1'b1);
                show_help <= 1'b0;
                if (!career_ok) career <= 2'd1;
                career_ok <= 1'b1;
                if (jkey == 3'd2) n_backs <= (n_backs >= 2'd1) ? 2'd1 : n_backs;
                else if (jkey >= 3'd3) n_backs <= (n_backs > 2'd2) ? 2'd2 : n_backs;
                if (jkey != 3'd0) begin
                    intro_on <= 1'b0;
                    if (jkey == 3'd4) begin state <= ST_CLEAR; form <= 2'd1; end
                    else begin
                        auto_answer(3'd0); auto_answer(3'd1); auto_answer(3'd2);
                        if (jkey != 3'd1) begin auto_answer(3'd3); auto_answer(3'd4); end
                        hints[0] <= 3'd3; n_hints <= 3'd1;
                        r_run[1] <= 1'b1; r_done[1] <= 1'b1;
                        if (jkey >= 3'd2) begin r_run[2] <= 1'b1; r_done[2] <= 1'b1; end
                        if (jkey >= 3'd3) begin r_run[3] <= 1'b1; r_done[3] <= 1'b1; end
                        if (jkey == 3'd5) begin                     // door_wrong: at the door with 99999
                            dig[0] <= 9; dig[1] <= 9; dig[2] <= 9; dig[3] <= 9; dig[4] <= 9;
                        end
                    end
                end
            end
            default: u <= U_IDLE;
            endcase

            // ---- card deck results (same frame) ----
            if (dk_pick) begin
                if (dk_rnd == 2'd1) begin career <= dk_pidx; career_ok <= 1'b1; end
                else begin
                    if (n_backs == 0) back0 <= dk_ppos; else back1 <= dk_ppos;
                    if (n_backs < 2) n_backs <= n_backs + 2'd1;
                end
                grant(dk_rnd, dk_pidx);
            end
            if (dk_done) r_done[dk_rnd] <= 1'b1;
        end
    end


    // hand-off (get_handoff pads card_backs to 2 with LFSR picks < 3)
    assign ho_hearts = hearts;
    assign ho_armor  = armor;
    assign ho_shard  = shard;
    assign ho_boost  = boost;
    assign ho_form   = form;
    assign ho_career = career_ok ? career : 2'd1;
    assign ho_backs  = {(n_backs >= 2) ? back1 : ((lfsr[2:0] < 3) ? lfsr[1:0] : 2'd1),
                        (n_backs >= 1) ? back0 : ((lfsr[5:3] < 3) ? lfsr[4:3] : 2'd0)};

    // ------------------------------------------------------------------ 3. scene objects
    // camera(): cx = clamp(px - 500, 0, 1000), cy = clamp(py - 60 - 281.25, 0, 553.5)
    reg  [19:0] cam_x, cam_y;
    always @(posedge clk) begin
        cam_x <= (px < (20'd500 << 8)) ? 20'd0 : (px - (20'd500 << 8) > (20'd1000 << 8)) ? (20'd1000 << 8) : px - (20'd500 << 8);
        cam_y <= (py < 20'd87360) ? 20'd0 : (py - 20'd87360 > 20'd141696) ? 20'd141696 : py - 20'd87360;   // 341.25, 553.5
    end
    // world -> view: (w - cam) * 0.64  (0.64 = 10486 / 16384)
    function signed [11:0] w2v;
        input [19:0] w; input [19:0] cam;
        reg signed [21:0] d;
        reg signed [37:0] p;
        begin
            d = $signed({2'b0, w}) - $signed({2'b0, cam});
            p = d * 38'sd10486;
            w2v = p >>> 22;                              // >> 8 (fixed) + >> 14 (scale)
        end
    endfunction
    wire signed [11:0] pl_vx = w2v(px, cam_x);
    wire signed [11:0] pl_vy = w2v(py + (20'd4 << 8), cam_y);
    wire signed [11:0] ta_vx = w2v(20'd1210 << 8, cam_x);
    wire signed [11:0] ta_vy = w2v(20'd399 << 8, cam_y);
    wire [35:0] bgx = cam_x * 36'd20972;                   // stored room picture is half size: x 0.32
    wire [35:0] bgy = cam_y * 36'd20972;
    wire [18:0] bg_sx0f = bgx[34:16];
    wire [17:0] bg_sy0f = bgy[33:16];

    // player picture: Stage 1 fallbacks of player_sprite.py
    wire [7:0] pl_asset = (form == 2'd1) ? (8'd12 + {sp_dir, 1'b0} + sp_dir + sp_pose) :
                          (form == 2'd2 && sp_dir == 2'd0) ? (A_PL_F2_FRONT_STAND + sp_pose) :
                          (form == 2'd2 && sp_dir == 2'd3) ? (A_PL_F2_RIGHT_STAND + sp_pose) :
                          ({sp_dir, 1'b0} + sp_dir + sp_pose);
    wire [49:0] plp = place_pl_s1(pl_asset);
    wire [49:0] tap = place_ta(A_NPC_TA);
    wire [49:0] tpp = place_ta_portrait(A_NPC_TA);
    wire [127:0] o_player = obj_img(pl_vx + $signed(plp[49:39]), pl_vy + $signed(plp[38:29]), plp[28:19], plp[18:10],
                                    pl_asset, 19'd0, 18'd0, plp[9:0], plp[9:0], 1'b0);
    wire [127:0] o_guide  = obj_img(ta_vx + $signed(tap[49:39]), ta_vy + $signed(tap[38:29]), tap[28:19], tap[18:10],
                                    A_NPC_TA, 19'd0, 18'd0, tap[9:0], tap[9:0], 1'b0);
    wire guide_first = (py >= (20'd395 << 8));          // GUIDE_POS[1] <= py: guide behind the player

    // card pictures (card_assets.get_image)
    function [7:0] card_asset;
        input [1:0] rnd; input [1:0] car; input [1:0] pos; input [1:0] idx; input revealed;
        reg [7:0] backs;
        begin
            case (car)
                2'd0: backs = (pos == 0) ? C_AIR_CARD1 : (pos == 1) ? C_AIR_CARD2 : C_AIR_CARD3;
                2'd1: backs = (pos == 0) ? C_EARTH_CARD1 : (pos == 1) ? C_EARTH_CARD2 : C_EARTH_CARD3;
                default: backs = (pos == 0) ? C_WATER_CARD1 : (pos == 1) ? C_WATER_CARD2 : C_WATER_CARD3;
            endcase
            if (rnd == 2'd1)
                card_asset = !revealed ? ((idx == 0) ? C_AIR_BACK : (idx == 1) ? C_EARTH_BACK : C_WATER_BACK)
                                       : ((idx == 0) ? C_AIR_R1 : (idx == 1) ? C_EARTH_R1 : C_WATER_R1);
            else if (!revealed) card_asset = backs;
            else case ({rnd, idx})                       // "{cat}_{item}" picture, else the back
                {2'd2, 2'd0}, {2'd3, 2'd2}: card_asset = (car == 0) ? C_AIR_SHARD : (car == 1) ? C_EARTH_SHARD : C_WATER_SHARD;
                {2'd2, 2'd1}: card_asset = (car == 0) ? C_AIR_SLOW : (car == 1) ? C_EARTH_SLOW : C_WATER_SLOW;
                {2'd2, 2'd2}: card_asset = (car == 0) ? C_AIR_HINT_SMART : (car == 1) ? C_EARTH_HINT_SMART : C_WATER_HINT_SMART;
                {2'd3, 2'd0}: card_asset = (car == 0) ? C_AIR_FREEZE : (car == 1) ? C_EARTH_FREEZE : C_WATER_FREEZE;
                default:      card_asset = (car == 0) ? C_AIR_UNDO : (car == 1) ? C_EARTH_UNDO : C_WATER_UNDO;
            endcase
        end
    endfunction
    function [1:0] perm_at;                              // same table as card_deck
        input [2:0] p; input [1:0] pos;
        reg [5:0] t;
        begin
            case (p)
                3'd0: t = {2'd2, 2'd1, 2'd0}; 3'd1: t = {2'd1, 2'd2, 2'd0}; 3'd2: t = {2'd2, 2'd0, 2'd1};
                3'd3: t = {2'd0, 2'd2, 2'd1}; 3'd4: t = {2'd1, 2'd0, 2'd2}; default: t = {2'd0, 2'd1, 2'd2};
            endcase
            perm_at = t[2*pos +: 2];
        end
    endfunction
    wire [1:0] cpos = obj_idx - 6'd20;                    // objects 20..22 = card slots 0..2
    wire [7:0] c_asset = card_asset(dk_rnd, career, cpos, perm_at(dk_perm_q, cpos), dk_face && dk_fpos == cpos);
    wire [49:0] cpl = place_card(c_asset);
    // slot centre: UI (160 + 65 + pos*180 + 85, 95 + 85) -> view x 2/3
    wire signed [11:0] c_cx = (cpos == 2'd0) ? 12'sd206 : (cpos == 2'd1) ? 12'sd326 : 12'sd446;
    wire [127:0] o_card = obj_img(c_cx + $signed(cpl[49:39]), 12'sd120 + $signed(cpl[38:29]), cpl[28:19], cpl[18:10],
                                  c_asset, 19'd0, 18'd0, cpl[9:0], cpl[9:0], 1'b0);

    // projector clue letters are rendered directly by S1_CU_SCREEN in the UI layer
    wire [8:0] flash_x11 = {4'd0, flash_t} * 9'd11 + 9'd12;
    wire [3:0] flash_alpha = (flash_x11 * 12'd171) >> 12;   // 180*flash/0.4 of 255, in 1/16
    wire in_map    = (state != ST_CLEAR) && !mode_cu;
    wire in_cu     = (state != ST_CLEAR) && mode_cu;
    wire show_nbg  = nb_pending && !sw[14];
    always @(*) begin
        obj_desc = OBJ_NONE;
        if (obj_idx[7:6] == 2'd0) case (obj_idx[5:0])
            6'd0: obj_desc = (state == ST_CLEAR) ? obj_fill(0, 0, 640, 360, 12'h121, 1'b0) :
                             mode_cu ? obj_fill(0, 0, 640, 360, 12'h112, 1'b0) :
                             obj_img(0, 0, 640, 360, A_BG_ROOM, bg_sx0f, bg_sy0f, 10'd128, 10'd128, 1'b0);
            6'd1: if (in_map) obj_desc = guide_first ? o_guide : o_player;
            6'd2: if (in_map) obj_desc = guide_first ? o_player : o_guide;
            6'd3: if (in_map && !lights) obj_desc = obj_blend(0, 0, 640, 360, 12'h001, 4'd9);   // (0,0,25) a150
            6'd19: if (dk_active && state != ST_CLEAR) obj_desc = obj_blend(0, 0, 640, 360, 12'h000, 4'd13);
            6'd20, 6'd21, 6'd22: if (dk_active && state != ST_CLEAR) obj_desc = o_card;
            6'd23: if (intro_on && state != ST_CLEAR) obj_desc = obj_fill(27, 250, 587, 85, 12'h112, 1'b0);   // talk box
            6'd24: if (intro_on && state != ST_CLEAR) obj_desc = obj_fill(37, 260, 67, 67, 12'h223, 1'b0);    // portrait box
            6'd25: if (intro_on && state != ST_CLEAR)
                       obj_desc = obj_img(71 + $signed(tpp[49:39]), 293 + $signed(tpp[38:29]), tpp[28:19], tpp[18:10],
                                          A_NPC_TA, 19'd0, 18'd0, tpp[9:0], tpp[9:0], 1'b0);
            6'd26: if (show_nbg && state != ST_CLEAR) obj_desc = obj_blend(0, 0, 640, 360, 12'h000, 4'd13);
            6'd27: if (flash_t != 0) obj_desc = obj_blend(0, 0, 640, 360, 12'hF00, flash_alpha);
            6'd28: if (state == ST_OVER) obj_desc = obj_blend(0, 0, 640, 360, 12'h000, 4'd14);
            6'd29: if (show_help) obj_desc = obj_blend(0, 0, 640, 360, 12'h000, 4'd13);
            default: ;
        endcase
    end

    // ------------------------------------------------------------------ 4. UI bindings
    function [7:0] cu_prog; input [2:0] o;
        case (o)
            O_WB: cu_prog = P_S1_CU_WHITEBOARD; O_PAPER: cu_prog = P_S1_CU_PAPER; O_NAND: cu_prog = P_S1_CU_NAND;
            O_TWOS: cu_prog = P_S1_CU_TWOS; O_SCREEN: cu_prog = P_S1_CU_SCREEN; O_PC: cu_prog = P_S1_CU_PC;
            O_LIGHT: cu_prog = P_S1_CU_LIGHTSW; default: cu_prog = P_S1_CU_DOOR;
        endcase
    endfunction
    // program list in Pygame draw() order; text under a dark full-screen overlay is left out
    wire dark_over = show_help || show_nbg || (dk_active && state != ST_CLEAR) || state == ST_OVER;
    reg [95:0] pl;
    integer np;
    task push_prog; input [7:0] id; begin pl = pl | ({88'd0, id} << (8 * np)); np = np + 1; end endtask
    always @(*) begin
        pl = 96'd0; np = 0;
        push_prog(P_BAR_TOP); push_prog(P_BAR_BOTTOM);
        if (state == ST_CLEAR) begin
            push_prog(P_S1_CLEAR);
        end else begin
            if (!show_help && !(dk_active) && !show_nbg && state != ST_OVER) begin
                if (mode_cu) begin push_prog(P_S1_CU_FRAME); push_prog(cu_prog(cur)); end
                else if (!intro_on) push_prog(P_S1_SEARCH);
                push_prog(P_HUD);
                if (sw[14]) push_prog(P_S1_NOTEBOOK);
            end
            if (dk_active && !show_help) push_prog(P_CARDS);
            if (intro_on && !show_help) push_prog(P_S1_INTRO);
            if (show_nbg && !show_help) push_prog(P_S1_NBGUIDE);
            if (state == ST_OVER) push_prog(P_S1_OVER);
        end
        push_prog(P_TOAST);
        if (show_help) push_prog(P_S1_HELP);
        prog_list = pl;
    end

    // search label position: centre (player_x, player_y - 92 - 8) UI px -> text cell
    wire signed [11:0] lbl_vy = pl_vy - 12'sd67;
    wire [7:0] lbl_col = (pl_vx + 12'sd4) >>> 3;
    wire [7:0] lbl_row = (lbl_vy < 12'sd8) ? 8'd1 : (lbl_vy >>> 3);

    function [7:0] term_len;                              // characters of term_str()
        input [3:0] used, pol;
        integer i; reg [7:0] n;
        begin
            n = 0;
            for (i = 3; i >= 0; i = i - 1) if (used[i]) n = n + 1 + (pol[i] ? 0 : 1);
            term_len = n;
        end
    endfunction
    function [159:0] term_str;                            // "AB'C" style, left aligned
        input [3:0] used, pol;
        integer i; reg [159:0] s; reg [7:0] n;
        begin
            s = 160'd0; n = 0;
            for (i = 3; i >= 0; i = i - 1)
                if (used[i]) begin
                    s[159 - 8 * n -: 8] = "A" + (3 - i); n = n + 1;
                    if (!pol[i]) begin s[159 - 8 * n -: 8] = "'"; n = n + 1; end
                end
            term_str = s;
        end
    endfunction
    function [167:0] join_2_terms;                        // partial join of terms 0 and 1: {n01[7:0], s01[159:0]}
        input [159:0] t0; input [3:0] l0;
        input [159:0] t1; input [3:0] l1;
        reg [159:0] s; reg [7:0] n; integer j;
        begin
            s = 160'd0; n = 0;
            if (l0 != 0) begin
                for (j = 0; j < 8; j = j + 1)
                    if (j < l0) s[159 - 8 * j -: 8] = t0[159 - 8 * j -: 8];
                n = {4'd0, l0};
            end
            if (l1 != 0) begin
                if (n != 0) begin
                    s[159 - 8 * n -: 8] = " "; s[151 - 8 * n -: 8] = "+"; s[143 - 8 * n -: 8] = " "; n = n + 3;
                end
                for (j = 0; j < 8; j = j + 1)
                    if (j < l1 && n + j < 20) s[159 - 8 * (n + j) -: 8] = t1[159 - 8 * j -: 8];
                n = n + {4'd0, l1};
            end
            join_2_terms = {n, s};
        end
    endfunction
    function [159:0] append_term;                         // append term 2 to pre-joined {n01, s01}
        input [159:0] s01; input [7:0] n01;
        input [159:0] t2;  input [3:0] l2;
        reg [159:0] s; reg [7:0] n; integer j;
        begin
            s = s01; n = n01;
            if (l2 != 0) begin
                if (n != 0) begin
                    s[159 - 8 * n -: 8] = " "; s[151 - 8 * n -: 8] = "+"; s[143 - 8 * n -: 8] = " "; n = n + 3;
                end
                for (j = 0; j < 8; j = j + 1)
                    if (j < l2 && n + j < 20) s[159 - 8 * (n + j) -: 8] = t2[159 - 8 * j -: 8];
            end
            append_term = s;
        end
    endfunction
    function [159:0] src_name; input [2:0] v;
        case (v) 0: src_name = {"A", 152'd0}; 1: src_name = {"B", 152'd0}; 2: src_name = {"C", 152'd0};
                 3: src_name = {"D", 152'd0}; 4: src_name = {"G1", 144'd0}; 5: src_name = {"G2", 144'd0};
                 default: src_name = {"G3", 144'd0}; endcase
    endfunction
    function [159:0] bits16;                              // "abcd efgh ijkl mnop", bit (g*4+i) order
        input [15:0] t;
        integer g, i; reg [159:0] s;
        begin
            s = 160'd0;
            for (g = 0; g < 4; g = g + 1) begin
                for (i = 0; i < 4; i = i + 1) s[159 - 8 * (g * 5 + i) -: 8] = t[g * 4 + i] ? "1" : "0";
                if (g < 3) s[159 - 8 * (g * 5 + 4) -: 8] = " ";
            end
            bits16 = s;
        end
    endfunction

    reg [159:0] p2_eq_str, p2_eq_01_r, eq_t0_r, eq_t1_r, eq_t2_r;
    reg [7:0]   p2_eq_n01_r;
    reg [3:0]   eq_l0_r, eq_l1_r, eq_l2_r;
    reg [159:0] p1_val_str, p4_u_str, p4_s_str, slow_s_str, freeze_s_str, sw_term_str;
    reg [159:0] term0_str, term1_str, term2_str;
    reg [5:0]   slow_sec_r, freeze_sec_r;
    reg [7:0]   lbl_col_r, lbl_row_r;
    always @(posedge clk) begin : blk_s1_fmt
        reg [167:0] j01;
        eq_t0_r      <= term_str(eq_used[0], eq_pol[0]); eq_l0_r <= term_len(eq_used[0], eq_pol[0]);
        eq_t1_r      <= term_str(eq_used[1], eq_pol[1]); eq_l1_r <= term_len(eq_used[1], eq_pol[1]);
        eq_t2_r      <= term_str(eq_used[2], eq_pol[2]); eq_l2_r <= term_len(eq_used[2], eq_pol[2]);
        j01           = join_2_terms(eq_t0_r, eq_l0_r, eq_t1_r, eq_l1_r);
        p2_eq_n01_r  <= j01[167:160];
        p2_eq_01_r   <= j01[159:0];
        p2_eq_str    <= append_term(p2_eq_01_r, p2_eq_n01_r, eq_t2_r, eq_l2_r);
        p1_val_str   <= str_u8(p1_val);
        p4_u_str     <= str_u8(p4_val);
        p4_s_str     <= str_s8(p4_val);
        sw_term_str  <= (sw[7:4] != 0) ? term_str(sw[7:4], sw[3:0]) : {"(nothing)", 88'd0};
        term0_str    <= (t_used[0] != 0) ? term_str(t_used[0], t_pol[0]) : {"(empty)", 104'd0};
        term1_str    <= (t_used[1] != 0) ? term_str(t_used[1], t_pol[1]) : {"(empty)", 104'd0};
        term2_str    <= (t_used[2] != 0) ? term_str(t_used[2], t_pol[2]) : {"(empty)", 104'd0};
        lbl_col_r    <= lbl_col;
        lbl_row_r    <= lbl_row;
        slow_sec_r   <= secs_round({1'b0, slow_t});
        freeze_sec_r <= secs_round({1'b0, freeze_t});
        slow_s_str   <= str_u8(slow_sec_r);
        freeze_s_str <= str_u8(freeze_sec_r);
    end

    wire [2:0] hint_base = (n_hints > 3) ? n_hints - 3'd3 : 3'd0;
    reg [159:0] fs;
    always @(*) begin
        fs = 160'd0;
        fld_val = 16'd0;
        case (fld_id)
            F_ARMOR_N:   fs = str_u8({6'd0, armor});
            F_SLOW_S:    begin fs = slow_s_str | ((slow_sec_r >= 10) ? {16'd0, "s", 136'd0} : {8'd0, "s", 144'd0}); end
            F_FREEZE_S:  begin fs = freeze_s_str | ((freeze_sec_r >= 10) ? {16'd0, "s", 136'd0} : {8'd0, "s", 144'd0}); end
            F_TOAST:     fld_val = toast;
            F_CARD_NAME: fld_val = card_name;
            F_CARD_DESC: fld_val = card_desc;
            F_BAR_TITLE: fld_val = T_BAR_TITLE_S1;
            F_BAR_HELP:  fld_val = T_BAR_HELP_S1;
            F_FORM:      fld_val = form;
            F_S1_NEAR:   fld_val = near_id;
            F_S1_LBL_COL: fld_val = {8'd0, lbl_col_r};
            F_S1_LBL_ROW: fld_val = {8'd0, lbl_row_r};
            F_S1_INTRO:  fld_val = intro_idx;
            F_S1_OBJ:    fld_val = cur;
            F_S1_CMSG:   fld_val = cmsg;
            F_S1_P1VAL:  fs = p1_val_str;
            F_S1_TERM0:  fs = term0_str;
            F_S1_TERM1:  fs = term1_str;
            F_S1_TERM2:  fs = term2_str;
            F_S1_SWTERM: fs = sw_term_str;
            F_S1_P2EQ:   fs = p2_eq_str;
            F_S1_P3SRC0: fs = src_name(p3[0]); F_S1_P3SRC1: fs = src_name(p3[1]);
            F_S1_P3SRC2: fs = src_name(p3[2]); F_S1_P3SRC3: fs = src_name(p3[3]);
            F_S1_P3SRC4: fs = src_name(p3[4]); F_S1_P3SRC5: fs = src_name(p3[5]);
            F_S1_P3SRC6: fs = src_name(p3[6]); F_S1_P3SRC7: fs = src_name(p3[7]);
            F_S1_P3OUT:  fs = {"1" + p3[8], 152'd0};
            F_S1_P3BITS: fs = bits16(p3_table);
            F_S1_SW8BITS: fs = {sw[7] ? "1" : "0", sw[6] ? "1" : "0", sw[5] ? "1" : "0", sw[4] ? "1" : "0",
                                sw[3] ? "1" : "0", sw[2] ? "1" : "0", sw[1] ? "1" : "0", sw[0] ? "1" : "0", 96'd0};
            F_S1_P4U:    fs = p4_u_str;
            F_S1_P4S:    fs = p4_s_str;
            F_S1_DOORL:  fld_val = door_l2;
            F_S1_DIG0:   fs = {"0" + dig[0], 152'd0}; F_S1_DIG1: fs = {"0" + dig[1], 152'd0};
            F_S1_DIG2:   fs = {"0" + dig[2], 152'd0}; F_S1_DIG3: fs = {"0" + dig[3], 152'd0};
            F_S1_DIG4:   fs = {"0" + dig[4], 152'd0};
            F_S1_P5L0:   fs = {"A" + p5[0], 152'd0}; F_S1_P5L1: fs = {"A" + p5[1], 152'd0};
            F_S1_P5L2:   fs = {"A" + p5[2], 152'd0};
            F_S1_ANS_A:  fs = {ans_a ? "6" : "?", 152'd0};
            F_S1_ANS_B:  fs = {ans_b ? "7" : "?", 152'd0};
            F_S1_ANS_C:  fs = {ans_c ? "5" : "?", 152'd0};
            F_S1_NOTE0:  fld_val = (n_notes > 0) ? notes[0] : 3'd0;
            F_S1_NOTE1:  fld_val = (n_notes > 1) ? notes[1] : 3'd0;
            F_S1_NOTE2:  fld_val = (n_notes > 2) ? notes[2] : 3'd0;
            F_S1_NOTE3:  fld_val = (n_notes > 3) ? notes[3] : 3'd0;
            F_S1_NOTE4:  fld_val = (n_notes > 4) ? notes[4] : 3'd0;
            F_S1_NOTE5:  fld_val = (n_notes > 5) ? notes[5] : 3'd0;
            F_S1_HINTSEEN0: fld_val = (n_hints > hint_base) ? hints[hint_base] : 3'd0;
            F_S1_HINTSEEN1: fld_val = (n_hints > hint_base + 1) ? hints[hint_base + 1] : 3'd0;
            F_S1_HINTSEEN2: fld_val = (n_hints > hint_base + 2) ? hints[hint_base + 2] : 3'd0;
            F_HEARTS:    fs = str_u8({6'd0, hearts});
            default: ;
        endcase
        fld_char = str_at(fs, fld_idx);
    end

    always @(*) begin
        case (cond_id)
            C_HEART0: cond_val = hearts > 0;  C_HEART1: cond_val = hearts > 1;  C_HEART2: cond_val = hearts > 2;
            C_ARMOR:  cond_val = armor != 0;
            C_SLOW:   cond_val = slow_t != 0;
            C_FREEZE: cond_val = freeze_t != 0;
            C_TOAST:  cond_val = toast_t != 0 && toast != 0;
            C_CARD_CUR0: cond_val = dk_active && !dk_face && dk_cur == 0;
            C_CARD_CUR1: cond_val = dk_active && !dk_face && dk_cur == 1;
            C_CARD_CUR2: cond_val = dk_active && !dk_face && dk_cur == 2;
            C_CARD_FACE: cond_val = dk_face;
            C_CARD_SKIP: cond_val = 1'b0;
            C_S1_NEAR:   cond_val = near_ok && in_map && !intro_on;
            C_S1_INTRO_LAST: cond_val = intro_idx == 2;
            C_S1_FB_OK:  cond_val = feedback == FB_OK;
            C_S1_FB_BAD: cond_val = feedback == FB_BAD;
            C_S1_FB_NONE: cond_val = feedback == FB_NONE;
            C_S1_PAGE0:  cond_val = page == 0;
            C_S1_PAGE1:  cond_val = page == 1;
            C_S1_PAGE2:  cond_val = page == 2;
            C_SW0: cond_val = sw[0]; C_SW1: cond_val = sw[1]; C_SW2: cond_val = sw[2]; C_SW3: cond_val = sw[3];
            C_S1_DONE0: cond_val = pdone[0]; C_S1_DONE1: cond_val = pdone[1]; C_S1_DONE4: cond_val = pdone[4];
            C_S1_P2CUR0: cond_val = p2_cur == 0; C_S1_P2CUR1: cond_val = p2_cur == 1; C_S1_P2CUR2: cond_val = p2_cur == 2;
            C_S1_P3CUR0: cond_val = p3_cur == 0; C_S1_P3CUR1: cond_val = p3_cur == 1; C_S1_P3CUR2: cond_val = p3_cur == 2;
            C_S1_P3CUR3: cond_val = p3_cur == 3; C_S1_P3CUR4: cond_val = p3_cur == 4; C_S1_P3CUR5: cond_val = p3_cur == 5;
            C_S1_P3CUR6: cond_val = p3_cur == 6; C_S1_P3CUR7: cond_val = p3_cur == 7; C_S1_P3CUR8: cond_val = p3_cur == 8;
            C_S1_LIGHTS: cond_val = lights;
            C_S1_DOORL1: cond_val = !door_l2;
            C_S1_DOORL2: cond_val = door_l2;
            C_S1_DCUR0: cond_val = door_cur == 0; C_S1_DCUR1: cond_val = door_cur == 1; C_S1_DCUR2: cond_val = door_cur == 2;
            C_S1_DCUR3: cond_val = door_cur == 3; C_S1_DCUR4: cond_val = door_cur == 4;
            C_S1_P5CUR0: cond_val = p5_cur == 0; C_S1_P5CUR1: cond_val = p5_cur == 1; C_S1_P5CUR2: cond_val = p5_cur == 2;
            default: cond_val = 1'b0;
        endcase
    end

    // ------------------------------------------------------------------ 5. 7-segment + LEDs (draw_panel)
    reg [47:0] right6;
    always @(*) begin
        right6 = "      ";
        if (state == ST_CLEAR) right6 = "  PA55";
        else if (state == ST_OVER) right6 = "  dEAd";
        else if (mode_cu && !dk_active) begin
            if (cur == O_WB && page == 1) right6 = push_num("      ", p1_val);
            else if (cur == O_TWOS && page == 1) begin
                if (p4_val >= 100) right6 = {"   ", str_u8(p4_val) >> 136};
                else right6 = push_num("      ", p4_val);
            end
            else if (cur == O_DOOR) right6 = door_l2 ? {" ", "0" + dig[0], "0" + dig[1], "0" + dig[2], "0" + dig[3], "0" + dig[4]}
                                                     : {"    ", "0" + dig[0], "0" + dig[1]};
            else if (cur == O_PC && !pdone[4]) right6 = push_num(push_num(push_num("      ", p5[0]), p5[1]), p5[2]);
        end
        seg_text = {"H", "0" + hearts, right6};
        leds = 16'd0;
        leds[0] = hearts > 0; leds[1] = hearts > 1; leds[2] = hearts > 2;
        leds[3] = armor != 0;
        leds[8:4] = pdone;
        leds[9] = lights;
        leds[10] = freeze_t != 0;
        leds[11] = slow_t != 0;
    end
endmodule
