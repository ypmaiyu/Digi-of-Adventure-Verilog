// stage2.v - STAGE 2: INTERNSHIP (port of demo_py/stage2_demo.py, class Game).
//
// The office part hunt (18 hidden parts, 9 hint notes, workshop-shirt skill), the Boss (walks in,
// explains, sits at his desk, runs the QA tests), the decoder bench (parts tray + breadboard wiring
// editor with undo / clear), the 7-segment decoder logic simulator, cards (round 2 at 8 parts and
// the optional 4th card at 18 parts), inventory (SW15), notebook (SW14), hearts / armor.
//
// Coordinates are the 960x540 Pygame room pixels; the view is 640x360, so drawing multiplies by 2/3.
// Movement uses the walk mask ROM (mem/s2_walk.mem, 2 px grid) with the same 8 foot points and the
// same "glide sideways up to 20 px" rule as move_axis(). Data tables: rtl/gen/s2_tables.vh.
//
// Differences from the Pygame version (see docs/PORTING_NOTES.md): wires are shown as labels next to
// each pin instead of curves, the circuit is evaluated by repeated passes (a wiring loop can oscillate
// instead of reading 0), the undo history holds 64 changes, mouse input does not exist.
`timescale 1ns / 1ps
module stage2 (
    input  wire         clk, input wire rst, input wire active, input wire start, input wire frame,
    input  wire [4:0]   lvl, input wire [4:0] ev_press, input wire ev_tap, input wire ev_back,
    input  wire [15:0]  sw, input wire [15:0] sw_rise, input wire [15:0] sw_fall,
    input  wire [1:0]   hi_hearts, input wire [1:0] hi_armor, input wire hi_shard, input wire hi_boost,
    input  wire [1:0]   hi_form, input wire [1:0] hi_career, input wire [7:0] hi_backs, input wire [2:0] hi_nbacks,
    input  wire         dbg_jump, input wire [2:0] dbg_key,
    input  wire         dbg_act, input wire [2:0] dbg_act_key,
    input  wire         dbg_set_hearts, input wire [1:0] dbg_hearts,
    input  wire         dbg_set_form, input wire [1:0] dbg_form,
    output reg          done,
    output wire [1:0]   ho_hearts, output wire [1:0] ho_armor, output wire ho_shard, output wire ho_boost,
    output wire [1:0]   ho_form, output wire [1:0] ho_career, output wire [7:0] ho_backs, output wire [2:0] ho_nbacks,
    input  wire [7:0]   obj_idx, output reg [127:0] obj_desc, output reg [95:0] prog_list,
    input  wire [7:0]   fld_id, input wire [6:0] fld_idx, output reg [7:0] fld_char, output reg [15:0] fld_val,
    input  wire [7:0]   cond_id, output reg cond_val, output reg [63:0] seg_text, output reg [15:0] leds
);
`include "asset_ids.vh"
`include "ui_ids.vh"
`include "desc.vh"
`include "lfsr.vh"
`include "strutil.vh"
`include "sprite_place.vh"
`include "s2_tables.vh"
    localparam B_U = 0, B_D = 1, B_L = 2, B_R = 3, B_C = 4;
    localparam [1:0] ST_PLAY = 2'd0, ST_OVER = 2'd1, ST_CLEAR = 2'd2;
    localparam [2:0] N_OFF = 3'd0, N_TOPL = 3'd1, N_TALK = 3'd2, N_TOSEAT = 3'd3, N_SIT = 3'd4;
    localparam [2:0] TG_INTRO = 3'd0, TG_INFO = 3'd1, TG_ASK = 3'd2, TG_VERDICT = 3'd3;
    localparam [11:0] SPD = 12'd1331, SPD_SLOW = 12'd666;        // 312 px/s (BASE_SPEED * 1.2) per frame, 8 frac bits
    localparam [11:0] NPC_STEP = 12'd640;                       // 150 px/s
    localparam [5:0]  NOTE_F0 = 6'd1, NOTE_H0 = 6'd19, NOTE_BOSS = 6'd28, NOTE_BENCH = 6'd29, NOTE_QA0 = 6'd30;

    // ---------------------------------------------------------------- walk mask ROM (1 cycle)
    (* rom_style = "block" *) reg [0:0] wm [0:129599];
    initial $readmemb("s2_walk.mem", wm);
    reg  [16:0] wm_a; reg wm_q;
    always @(posedge clk) wm_q <= wm[wm_a];

    // ---------------------------------------------------------------- state
    reg [1:0]  state;
    reg        mode_cu;                  // 0 map, 1 close-up
    reg [1:0]  cur;                      // 0 whiteboard, 1 door, 2 bench
    reg [1:0]  page;
    reg [2:0]  cmsg;
    reg [19:0] px, py;                   // room px, 8 fraction bits
    reg [1:0]  hearts, armor, form, career;
    reg        shard, boost;
    reg [1:0]  hh, hs, undo_n, freeze_n;
    reg [9:0]  slow_t, freeze_t, skill_t;
    reg [13:0] play_t;
    reg        skill_used;
    reg [5:0]  toast; reg [7:0] toast_t; reg [6:0] toast_cnt;   // count text "n/q" packed {n3, q3}
    reg        toast_c;
    reg [4:0]  flash_t; reg [7:0] over_t;
    reg [17:0] done_spots; reg [8:0] read_hints;
    reg [2:0]  found [0:8];
    reg [4:0]  parts;
    reg [1:0]  rnd;
    reg        codes_ok;                 // codes is not None
    reg [2:0]  qa_k [0:5];               // qa_pairs flattened
    reg        pairs_ok;
    reg [2:0]  code0, code1;
    reg [3:0]  r_run, r_done;
    reg [7:0]  backs; reg [2:0] nbacks;
    reg        intro_started, cutscene;
    // Boss
    reg [2:0]  npc_st; reg [19:0] nx, ny; reg [5:0] n_pi; reg n_path; reg n_walk; reg n_left;
    // talk
    reg        talk_on; reg [2:0] talk_tag; reg [5:0] talk_l [0:7]; reg [2:0] talk_n, talk_i; reg talk_ask, talk_pass;
    // hint popup
    reg        hint_on; reg [4:0] hint_txt; reg [3:0] hint_ttl; reg hint_wire; reg [5:0] hint_sink; reg [4:0] hint_src;
    // zoom
    reg        zoom_on; reg [7:0] zoom_t; reg [9:0] zoom_x, zoom_y;
    // inventory / notebook
    reg [1:0]  inv_cur;
    reg [5:0]  notes [0:7]; reg [2:0] note_wp; reg [3:0] note_n;
    // breadboard
    reg [4:0]  w [0:53];
    reg [6:0]  wcur; reg wsrc_on; reg [4:0] wsrc, wprev, msel;
    reg [10:0] hist [0:63]; reg [5:0] h_n;           // {kind, sink6 | slot, old5}
    reg [269:0] snap [0:1]; reg snap_wp;
    // evaluation results
    reg [6:0]  seg_live, seg_q0, seg_q1;
    reg [15:0] lfsr;

    // ---------------------------------------------------------------- helpers
    function [10:0] v23; input [10:0] x; reg [21:0] p; begin p = x * 11'd683; v23 = p[20:10]; end endfunction
    task say; input [5:0] id; begin toast <= id; toast_t <= 8'd150; toast_c <= 1'b0; end endtask
    task note; input [5:0] id; begin notes[note_wp] <= id; note_wp <= note_wp + 3'd1; if (note_n < 4'd8) note_n <= note_n + 4'd1; end endtask

    wire [9:0] pxi = px[17:8], pyi = py[17:8];
    wire       skill_ready = (play_t >= 14'd7200) && !skill_used && skill_t == 0;
    wire       qa_done = (rnd >= 2'd3);
    wire       on_board = mode_cu && cur == 2'd2 && page == 2'd1;
    wire       wiring_live = on_board && codes_ok;
    wire [5:0] cur_sink = wcur[5:0];
    wire       cur_is_sink = (wcur < 7'd54);
    wire [4:0] cur_src = s2_cur_src(wcur);

    // ---------------------------------------------------------------- card deck (shared module)
    reg        dk_clear, dk_open, dk_upd; reg [1:0] dk_round; reg [2:0] dk_perm;
    wire       dk_active, dk_face, dk_pick, dk_done, dk_skipped;
    wire [1:0] dk_cur, dk_rnd, dk_fpos, dk_ppos, dk_pidx;
    wire [2:0] dk_perm_q;
    card_deck u_deck (.clk(clk), .rst(rst), .clear(dk_clear), .open(dk_open), .open_round(dk_round), .open_perm(dk_perm),
                      .upd(dk_upd), .ev_left(ev_press[B_L]), .ev_right(ev_press[B_R]), .ev_tap(ev_tap), .ev_back(ev_back),
                      .allow_skip(dk_round == 2'd3), .active(dk_active), .round(dk_rnd), .cursor(dk_cur), .face(dk_face),
                      .face_pos(dk_fpos), .perm(dk_perm_q), .pick(dk_pick), .pick_pos(dk_ppos), .pick_idx(dk_pidx),
                      .done(dk_done), .skipped(dk_skipped));
    reg [3:0] card_name, card_desc;

    // ---------------------------------------------------------------- player sprite
    reg        sp_reset, sp_upd, sp_stop, sp_moved;
    reg signed [1:0] sp_dx, sp_dy;
    wire [1:0] sp_dir, sp_pose;
    sprite_anim #(.MODE(1)) u_anim (.clk(clk), .rst(rst), .reset_dir(sp_reset), .upd(sp_upd), .stop(sp_stop),
                                    .dx(sp_dx), .dy(sp_dy), .moved(sp_moved), .dir(sp_dir), .pose(sp_pose));

    // ---------------------------------------------------------------- blocked(x, y) checker (8 foot points)
    reg        bk_go, bk_busy, bk_res;
    reg signed [11:0] bk_x, bk_y;
    reg [3:0]  bk_i;
    reg signed [11:0] bpx, bpy;
    always @(*) begin
        case (bk_i[2:0])
            3'd0: begin bpx = bk_x - 12'sd8; bpy = bk_y - 12'sd8; end
            3'd1: begin bpx = bk_x + 12'sd8; bpy = bk_y - 12'sd8; end
            3'd2: begin bpx = bk_x - 12'sd8; bpy = bk_y; end
            3'd3: begin bpx = bk_x + 12'sd8; bpy = bk_y; end
            3'd4: begin bpx = bk_x;          bpy = bk_y - 12'sd8; end
            3'd5: begin bpx = bk_x;          bpy = bk_y; end
            3'd6: begin bpx = bk_x - 12'sd8; bpy = bk_y - 12'sd4; end
            default: begin bpx = bk_x + 12'sd8; bpy = bk_y - 12'sd4; end
        endcase
    end
    wire bp_out = (bpx < 0) || (bpy < 0) || (bpx >= 12'sd960) || (bpy >= 12'sd540);
    reg  bk_ph;                                    // 0: present the address, 1: test the ROM bit
    reg  bk_wait;
    always @(posedge clk) begin
        if (rst) begin bk_busy <= 1'b0; bk_wait <= 1'b1; end
        else if (bk_go) begin bk_busy <= 1'b1; bk_i <= 4'd0; bk_res <= 1'b0; bk_ph <= 1'b0; bk_wait <= 1'b1; end
        else if (bk_busy) begin
            if (!bk_ph) begin
                if (bk_i == 4'd8) bk_busy <= 1'b0;
                else if (bp_out) begin bk_res <= 1'b1; bk_busy <= 1'b0; end
                else begin wm_a <= bpy[9:1] * 17'd480 + {7'd0, bpx[10:1]}; bk_ph <= 1'b1; end
            end else if (bk_ph && bk_wait) bk_wait <= 1'b0;
            else begin
                bk_ph <= 1'b0; bk_wait <= 1'b1;
                if (!wm_q) begin bk_res <= 1'b1; bk_busy <= 1'b0; end
                else bk_i <= bk_i + 4'd1;
            end
        end
    end

    // ---------------------------------------------------------------- circuit evaluator (from circuit.txt)
    // Stack-based DFS evaluator bb_circuit_eval handles arbitrary nets + detects wiring loops as 0.
    // Runs on live sw[2:0] (segments + all 27 sources for wire visual feedback), then code0 & code1.
    reg        ev_go, ev_busy; reg [2:0] ev_code; reg [1:0] ev_which;
    reg        cv_start, cv_wait;
    reg  [4:0] cv_node;
    wire       cv_done, cv_val;
    reg  [5:0] ev_i;
    reg  [6:0] segs_acc;
    reg  [27:0] src_val;
    wire       dip_vcc = (w[S2_DIPVCC] == S2_SRC_1);
    wire       lv_c = (ev_code[2] && dip_vcc) ? 1'b1 : (w[S2_PDC] == S2_SRC_0) ? 1'b0 : 1'b1;
    wire       lv_b = (ev_code[1] && dip_vcc) ? 1'b1 : (w[S2_PDB] == S2_SRC_0) ? 1'b0 : 1'b1;
    wire       lv_a = (ev_code[0] && dip_vcc) ? 1'b1 : (w[S2_PDA] == S2_SRC_0) ? 1'b0 : 1'b1;
    reg [269:0] wflat;
    integer q;
    always @(*) for (q = 0; q < 54; q = q + 1) wflat[q * 5 +: 5] = w[q];
    bb_circuit_eval u_bb_eval (
        .clk(clk), .start(cv_start), .node(cv_node),
        .lc(lv_c), .lb(lv_b), .la(lv_a), .w(wflat),
        .done(cv_done), .val(cv_val)
    );
    // Auto-wire reference build from circuit.txt (SW8)
    function [4:0] ref_src; input [5:0] sink;
        case (sink)
            6'd0, 6'd2, 6'd4, 6'd6, 6'd8:           ref_src = 5'd1;  // +5V
            6'd1, 6'd3, 6'd5, 6'd7, 6'd9, 6'd10,
            6'd11, 6'd12:                           ref_src = 5'd2;  // GND
            6'd13: ref_src = 5'd3;  // N1.a = C
            6'd14: ref_src = 5'd5;  // N2.a = A
            6'd16: ref_src = 5'd4;  // A1.a = B
            6'd17: ref_src = 5'd7;  // A1.b = N2
            6'd18: ref_src = 5'd3;  // A2.a = C
            6'd19: ref_src = 5'd5;  // A2.b = A
            6'd20: ref_src = 5'd3;  // A3.a = C
            6'd21: ref_src = 5'd16; // A3.b = O4
            6'd22: ref_src = 5'd3;  // A4.a = C
            6'd23: ref_src = 5'd4;  // A4.b = B
            6'd24: ref_src = 5'd6;  // O1.a = N1
            6'd25: ref_src = 5'd4;  // O1.b = B
            6'd26: ref_src = 5'd13; // O2.a = O1
            6'd27: ref_src = 5'd5;  // O2.b = A
            6'd28: ref_src = 5'd9;  // O3.a = A1
            6'd29: ref_src = 5'd10; // O3.b = A2
            6'd30: ref_src = 5'd5;  // O4.a = A
            6'd31: ref_src = 5'd4;  // O4.b = B
            6'd32: ref_src = 5'd5;  // O5.a = A
            6'd33: ref_src = 5'd12; // O5.b = A4
            6'd34: ref_src = 5'd6;  // O6.a = N1
            6'd35: ref_src = 5'd4;  // O6.b = B
            6'd36: ref_src = 5'd3;  // O7.a = C
            6'd37: ref_src = 5'd4;  // O7.b = B
            6'd38: ref_src = 5'd19; // O8.a = O7
            6'd39: ref_src = 5'd7;  // O8.b = N2
            6'd40: ref_src = 5'd14; // sa = O2
            6'd41: ref_src = 5'd15; // sb = O3
            6'd42: ref_src = 5'd11; // sc = A3
            6'd43: ref_src = 5'd17; // sd = O5
            6'd44: ref_src = 5'd6;  // se = N1
            6'd45: ref_src = 5'd18; // sf = O6
            6'd46: ref_src = 5'd20; // sg = O8
            6'd47: ref_src = 5'd21; // da = Ra
            6'd48: ref_src = 5'd22; // db = Rb
            6'd49: ref_src = 5'd23; // dc = Rc
            6'd50: ref_src = 5'd24; // dd = Rd
            6'd51: ref_src = 5'd25; // de = Re
            6'd52: ref_src = 5'd26; // df = Rf
            6'd53: ref_src = 5'd27; // dg = Rg
            default: ref_src = 5'd0;
        endcase
    endfunction
    always @(posedge clk) begin
        cv_start <= 1'b0;
        if (rst) begin
            ev_busy <= 1'b0; cv_wait <= 1'b0; ev_i <= 6'd0; segs_acc <= 7'd0; src_val <= 28'd0;
            seg_live <= 7'd0; seg_q0 <= 7'd0; seg_q1 <= 7'd0;
        end else if (ev_go) begin
            ev_busy <= 1'b1; cv_wait <= 1'b0; ev_i <= 6'd0; segs_acc <= 7'd0;
        end else if (ev_busy) begin
            if (!cv_wait) begin
                cv_node  <= (ev_i < 6'd7) ? w[S2_SEG_D0 + ev_i[2:0]] : (ev_i[4:0] - 5'd6);
                cv_start <= 1'b1;
                cv_wait  <= 1'b1;
            end else if (cv_done) begin
                cv_wait <= 1'b0;
                if (ev_i < 6'd7) begin
                    segs_acc[6 - ev_i[2:0]] <= cv_val && (w[S2_SEGCOM] == S2_SRC_0) && (w[S2_SEG_D0 + ev_i[2:0]] != 0);
                end else begin
                    src_val[ev_i - 6'd6] <= cv_val;
                end
                if ((ev_which != 2'd0 && ev_i == 6'd6) || (ev_which == 2'd0 && ev_i == 6'd33)) begin
                    ev_busy <= 1'b0;
                    case (ev_which)
                        2'd0: seg_live <= segs_acc;
                        2'd1: seg_q0   <= {segs_acc[6:1], cv_val && (w[S2_SEGCOM] == S2_SRC_0) && (w[S2_SEG_D0 + 6] != 0)};
                        default: seg_q1 <= {segs_acc[6:1], cv_val && (w[S2_SEGCOM] == S2_SRC_0) && (w[S2_SEG_D0 + 6] != 0)};
                    endcase
                end else ev_i <= ev_i + 6'd1;
            end
        end
    end

    // ---------------------------------------------------------------- find_near() scoring
    reg  [5:0] fn_i;                                 // 0..2 objects, 3 npc, 4..21 spots, 22..30 hints
    reg  [9:0] fn_ax, fn_ay; reg fn_ok; reg fn_r70;
    always @(*) begin
        fn_ok = 1'b0; fn_ax = 0; fn_ay = 0; fn_r70 = 1'b0;
        if (fn_i < 6'd3) begin {fn_ax, fn_ay} = s2_obj(fn_i[1:0]); fn_ok = 1'b1; fn_r70 = 1'b1; end
        else if (fn_i == 6'd3) begin {fn_ax, fn_ay} = s2_obj(2'd3); fn_ok = (npc_st == N_SIT); fn_r70 = 1'b1; end
        else if (fn_i < 6'd22) begin fn_ax = s2_spot(fn_i - 6'd4) >> 10 & 10'h3FF; fn_ay = s2_spot(fn_i - 6'd4) & 10'h3FF;
                                     fn_ok = !done_spots[fn_i - 6'd4]; end
        else if (fn_i < 6'd31) begin fn_ax = s2_hint(fn_i - 6'd22) >> 10 & 10'h3FF; fn_ay = s2_hint(fn_i - 6'd22) & 10'h3FF;
                                     fn_ok = !read_hints[fn_i - 6'd22]; end
    end
    wire signed [11:0] fdx = $signed({2'b0, pxi}) - $signed({2'b0, fn_ax});
    wire signed [11:0] fdy = $signed({2'b0, pyi}) - $signed({2'b0, fn_ay});
    wire [23:0] fd2 = fdx * fdx + fdy * fdy;
    reg  [23:0] fd2_r; reg fn_ok_r, fn_r70_r;
    wire [31:0] fsc = fd2_r * (fn_r70_r ? 32'd25 : 32'd49);
    reg  [31:0] fn_best; reg [5:0] fn_bi;

    // ---------------------------------------------------------------- cursor_step() scoring (3-cycle pipelined for 74.25 MHz)
    reg  [6:0] cs_i, cs_best; reg [31:0] cs_bs; reg cs_has;
    reg signed [1:0] cs_dx, cs_dy;
    wire [19:0] cs_p0 = s2_cur(wcur);
    reg  [19:0] cs_p0_r, cs_p1_r;
    reg         cs_ok_r;
    reg  [31:0] cs_sc_r;
    wire signed [11:0] cdx = $signed({2'b0, cs_p1_r[19:10]}) - $signed({2'b0, cs_p0_r[19:10]});
    wire signed [11:0] cdy = $signed({2'b0, cs_p1_r[9:0]}) - $signed({2'b0, cs_p0_r[9:0]});
    wire signed [13:0] c_ax = (cs_dx > 0 ? cdx : cs_dx < 0 ? -cdx : 12'sd0) + (cs_dy > 0 ? cdy : cs_dy < 0 ? -cdy : 12'sd0);
    wire [12:0] c_ay = ((cs_dy != 0) ? (cdx[11] ? -cdx : cdx) : 12'd0) + ((cs_dx != 0) ? (cdy[11] ? -cdy : cdy) : 12'd0);
    wire [31:0] c_sc = c_ax + 3 * c_ay;

    // ---------------------------------------------------------------- wiring_hint(): first REF mismatch
    reg  [5:0] rf_i;
    wire [10:0] rf = s2_ref(rf_i);
    wire       segs_all_ok = codes_ok && (seg_q0 == s2_gold(code0)) && (seg_q1 == s2_gold(code1));
    // missing spots for the smart hint
    reg  [4:0] ms_i, ms_k, ms_n; reg [2:0] ms_r;

    // ---------------------------------------------------------------- wire geometry precompute (U_WP)
    function [19:0] nearest_src; input [4:0] sid; input [9:0] kx, ky;
        reg [9:0] rx;
        begin
            rx = (kx < 10'd254) ? 10'd214 : (kx < 10'd334) ? 10'd294 :
                 (kx < 10'd414) ? 10'd374 : (kx < 10'd494) ? 10'd454 : 10'd534;
            if (sid >= 5'd6)                 nearest_src = s2_cur(7'd48 + sid);
            else if (sid >= 5'd3)            nearest_src = s2_cur(7'd73 + sid);
            else if (sid == 5'd1)            nearest_src = (kx < 10'd175) ? {10'd130, 10'd160} : {rx, (ky < 10'd210) ? 10'd122 : 10'd298};
            else                             nearest_src = (kx < 10'd175) ? {10'd150, 10'd160} : {rx, (ky < 10'd360) ? 10'd246 : 10'd478};
        end
    endfunction
    function [11:0] wire_color; input [4:0] sid; input val;
        begin
            if (sid == 5'd1)                       wire_color = 12'hE44;
            else if (sid == 5'd2)                  wire_color = 12'h37E;
            else if (sid <= 5'd5 || sid >= 5'd21)  wire_color = val ? 12'hFA3 : 12'hB62;
            else if (sid <= 5'd8)                  wire_color = val ? 12'h9DF : 12'h58B;
            else if (sid <= 5'd12)                 wire_color = val ? 12'h4DF : 12'h38B;
            else                                   wire_color = val ? 12'h5F7 : 12'h394;
        end
    endfunction
    reg  [5:0]  wp_i;
    reg  [41:0] wh_mem [0:53];  // {en, hx[9:0], hy[8:0], hw[9:0], col[11:0]}
    reg  [40:0] wv_mem [0:53];  // {en, vx[9:0], vy[8:0], vh[8:0], col[11:0]}
    reg  [9:0]  mk_vx  [0:17];
    reg  [8:0]  mk_vy  [0:17];
    integer wi_init;
    initial begin
        for (wi_init = 0; wi_init < 54; wi_init = wi_init + 1) begin
            wh_mem[wi_init] = 42'd0;
            wv_mem[wi_init] = 41'd0;
        end
        for (wi_init = 0; wi_init < 18; wi_init = wi_init + 1) begin
            mk_vx[wi_init] = 10'd0;
            mk_vy[wi_init] = 9'd0;
        end
    end
    // Pipelined U_WP -> U_WP1 -> U_WP2 -> U_WP3 registers
    reg  [4:0]  wp_sid_r;
    reg  [19:0] wp_kp_r, wp_sp_r;
    reg  [43:0] mk_s_r;
    reg  [10:0] wp_kx_r, wp_ky_r, wp_sx_r, wp_sy_r;
    reg  [11:0] wp_col_r;

    // ---------------------------------------------------------------- update FSM
    localparam [5:0] U_IDLE = 0, U_MAIN = 1, U_CARD = 2, U_NPC = 3, U_PLAY = 4, U_MX = 5, U_MXW = 6, U_MY = 7, U_MYW = 8,
                     U_GL = 9, U_GLW = 10, U_GL2W = 11, U_NEAR = 12, U_NEARD = 13, U_CU = 14, U_CSTEP = 15, U_UNDO = 16,
                     U_EVAL = 17, U_EVW = 18, U_HREF = 19, U_HMISS = 20, U_HMISS2 = 21, U_PAIRS = 22, U_RESET = 23, U_RES2 = 24,
                     U_AXDONE = 25, U_MOVE_END = 26, U_MXB = 27, U_JUMP = 28, U_ACT = 29, U_NEAR2 = 30, U_WP = 31,
                     U_WP1 = 32, U_WP2 = 33, U_WP3 = 34, U_CSTEP2 = 35, U_CSTEP3 = 36, U_UNDO2 = 37, U_UNDO3 = 38;
    reg [5:0]  u, u_ret;
    reg [10:0] un_ent_r;
    reg        un_hi_r, un_snap_diff_r;
    reg        axis_y;                                     // 0: x axis, 1: y axis
    reg signed [1:0] in_dx, in_dy, a_dir;
    reg [19:0] tgt; reg [4:0] gl_off; reg gl_sg;
    reg [19:0] ox, oy;
    reg [2:0]  pr_i;                                       // make_pairs index
    reg        pending_round;
    reg [11:0] budget;
    reg        rs_start;
    reg        jmp_pend, jmp_run, act_pend;
    reg [2:0]  j_key, a_key;
    integer k;

    wire [11:0] spd = (freeze_t != 0) ? 12'd0 : (slow_t != 0) ? SPD_SLOW : SPD;
    wire [19:0] np_path = n_path ? s2_path2(n_pi) : s2_path1(n_pi);
    wire [5:0]  np_len  = n_path ? S2_PATH2_N[5:0] : S2_PATH1_N[5:0];

    reg hist_hi [0:63];
    wire [4:0] glstep = (spd[11:8] == 0) ? 5'd1 : (gl_off < {1'b0, spd[11:8]}) ? gl_off : {1'b0, spd[11:8]};
    task open_talk; input [2:0] tag; input [2:0] n; input [5:0] l0, l1, l2, l3; begin
        talk_on <= 1'b1; talk_tag <= tag; talk_n <= n; talk_i <= 3'd0; talk_ask <= (tag == TG_ASK);
        talk_l[0] <= l0; talk_l[1] <= l1; talk_l[2] <= l2; talk_l[3] <= l3;
    end endtask

    // hearts / armor helpers as "functions" executed in the FSM
    task do_damage; begin
        if (armor != 0) begin armor <= armor - 2'd1; say(T_TOAST_ARMOR_PROT[5:0]); end
        else begin
            hearts <= hearts - 2'd1; flash_t <= 5'd24;
            if (hearts <= 2'd1) begin state <= ST_OVER; over_t <= 8'd180; end
            else say(T_TOAST_QA_FAIL[5:0]);
        end
    end endtask

    always @(posedge clk) begin
        done <= 1'b0; bk_go <= 1'b0; ev_go <= 1'b0;
        dk_clear <= 1'b0; dk_open <= 1'b0; dk_upd <= 1'b0;
        sp_reset <= 1'b0; sp_upd <= 1'b0; sp_stop <= 1'b0;
        if (rst) begin
            u <= U_IDLE; lfsr <= 16'hACE1; state <= ST_PLAY;
            hearts <= 2'd3; armor <= 2'd0; shard <= 1'b0; boost <= 1'b0; form <= 2'd1; career <= 2'd0;
            backs <= 8'd0; nbacks <= 3'd0;
            pending_round <= 1'b0; jmp_pend <= 1'b0; jmp_run <= 1'b0; act_pend <= 1'b0; j_key <= 3'd0; a_key <= 3'd0;
        end else if (start) begin
            hearts <= (hi_hearts == 0) ? 2'd1 : hi_hearts; armor <= hi_armor; shard <= hi_shard; boost <= hi_boost;
            form <= hi_form; career <= hi_career; backs <= hi_backs; nbacks <= (hi_nbacks > 3'd2) ? 3'd2 : hi_nbacks;
            rs_start <= 1'b1; jmp_run <= 1'b0; u <= U_RESET;
        end else begin
            if (dbg_jump) begin jmp_pend <= 1'b1; j_key <= dbg_key; end
            if (dbg_act)  begin act_pend <= 1'b1; a_key <= dbg_act_key; end
            if (dbg_set_form) form <= dbg_form;
            if (dbg_set_hearts) begin hearts <= (dbg_hearts == 0) ? 2'd1 : dbg_hearts; if (state == ST_OVER) state <= ST_PLAY; end
            case (u)
            U_IDLE: begin
                if (jmp_pend) begin
                    jmp_pend <= 1'b0; jmp_run <= (j_key != 3'd0); rs_start <= 1'b1;
                    if (j_key <= 3'd1) nbacks <= (nbacks > 3'd2) ? 3'd2 : nbacks;
                    u <= U_RESET;
                end
                else if (act_pend) begin act_pend <= 1'b0; u <= U_ACT; end
                else if (active && frame) u <= U_MAIN;
            end
            // ------------------------------------------------ _update(): timers, state, cards, Boss, talk
            U_MAIN: begin
                lfsr <= lfsr_next7(lfsr);
                if (flash_t != 0) flash_t <= flash_t - 5'd1;
                if (toast_t != 0) toast_t <= toast_t - 8'd1;
                u <= U_EVAL;
                if (state == ST_CLEAR) begin
                    if (ev_tap) done <= 1'b1;
                    sp_stop <= 1'b1;
                end else if (state == ST_OVER) begin
                    sp_stop <= 1'b1;
                    if (over_t <= 8'd1) u <= U_RESET; else over_t <= over_t - 8'd1;
                end else begin
                    if (slow_t != 0) slow_t <= slow_t - 10'd1;
                    if (skill_t != 0) skill_t <= skill_t - 10'd1;
                    if (zoom_on) begin
                        zoom_t <= zoom_t + 8'd1;
                        if (zoom_t >= 8'd131) zoom_on <= 1'b0;
                    end
                    // card_trigger()
                    if (!dk_active && !zoom_on && r_done[1] && !r_run[2] && parts >= 5'd8) begin
                        dk_round <= 2'd2; u <= U_CARD; sp_stop <= 1'b1;
                    end else if (!dk_active && !zoom_on && r_done[2] && !r_run[3] && parts >= 5'd18 && nbacks == 3'd3 &&
                                 backs[1:0] != backs[3:2] && backs[1:0] != backs[5:4] && backs[3:2] != backs[5:4]) begin
                        dk_round <= 2'd3; u <= U_CARD; sp_stop <= 1'b1;
                    end else if (dk_active) begin
                        dk_upd <= 1'b1; sp_stop <= 1'b1;
                    end else begin
                        if (r_done[1] && !intro_started) begin                 // start_intro()
                            intro_started <= 1'b1; cutscene <= 1'b1;
                            npc_st <= N_TOPL; nx <= {10'd622, 8'd0}; ny <= {10'd186, 8'd0}; n_path <= 1'b0; n_pi <= 6'd0;
                        end
                        budget <= NPC_STEP;
                        u <= U_NPC;
                    end
                end
            end
            U_CARD: begin                                                     // card_start(): perm = PERMS[lfsr_pick(6)]
                lfsr <= lfsr_next(lfsr);
                if ((lfsr_next(lfsr) & 16'd7) < 16'd6) begin
                    dk_perm <= lfsr_next(lfsr) & 3'd7; dk_open <= 1'b1;
                    r_run[dk_round] <= 1'b1;
                    u <= U_EVAL;
                end
            end
            // ------------------------------------------------ npc_update(dt): walk the path at 150 px/s
            U_NPC: begin
                n_walk <= (npc_st == N_TOPL || npc_st == N_TOSEAT) && n_pi < np_len;
                if ((npc_st == N_TOPL || npc_st == N_TOSEAT) && n_pi < np_len && budget != 0) begin
                    if (nx[17:8] != np_path[19:10] || nx[7:0] != 0) begin           // x first
                        n_left <= (np_path[19:10] < nx[17:8]);
                        if ({np_path[19:10], 8'd0} > nx) begin
                            if ({np_path[19:10], 8'd0} - nx <= budget) begin budget <= budget - ({np_path[19:10], 8'd0} - nx); nx <= {np_path[19:10], 8'd0}; end
                            else begin nx <= nx + budget; budget <= 0; end
                        end else begin
                            if (nx - {np_path[19:10], 8'd0} <= budget) begin budget <= budget - (nx - {np_path[19:10], 8'd0}); nx <= {np_path[19:10], 8'd0}; end
                            else begin nx <= nx - budget; budget <= 0; end
                        end
                    end else if (ny[17:8] != np_path[9:0] || ny[7:0] != 0) begin
                        if ({np_path[9:0], 8'd0} > ny) begin
                            if ({np_path[9:0], 8'd0} - ny <= budget) begin budget <= budget - ({np_path[9:0], 8'd0} - ny); ny <= {np_path[9:0], 8'd0}; end
                            else begin ny <= ny + budget; budget <= 0; end
                        end else begin
                            if (ny - {np_path[9:0], 8'd0} <= budget) begin budget <= budget - (ny - {np_path[9:0], 8'd0}); ny <= {np_path[9:0], 8'd0}; end
                            else begin ny <= ny - budget; budget <= 0; end
                        end
                    end else n_pi <= n_pi + 6'd1;
                end else begin
                    if (npc_st == N_TOPL && n_pi >= np_len) begin
                        npc_st <= N_TALK;
                        open_talk(TG_INTRO, 3'd7, T_S2_TALK_I0[5:0], 6'd1, 6'd2, 6'd3);
                        talk_l[4] <= 6'd4; talk_l[5] <= 6'd5; talk_l[6] <= 6'd6; talk_l[7] <= 6'd7;
                    end else if (npc_st == N_TOSEAT && n_pi >= np_len) begin
                        npc_st <= N_SIT; cutscene <= 1'b0;
                    end
                    u <= U_PLAY;
                end
            end
            // ------------------------------------------------ talk, cutscene, zoom, skill, popups, map / close-up
            U_PLAY: begin
                u <= U_EVAL;
                if (talk_on) begin                                             // talk_input(ev)
                    sp_stop <= 1'b1;
                    if (ev_tap) begin
                        if (talk_i != talk_n) begin
                            talk_i <= talk_i + 3'd1;
                            if (talk_tag == TG_INTRO && talk_i == 3'd2) skill_t <= 10'd600;     // start_skill() at line 3
                        end else begin                                          // talk_done(True)
                            talk_on <= 1'b0;
                            case (talk_tag)
                                TG_INTRO: begin npc_st <= N_TOSEAT; n_path <= 1'b1; n_pi <= 6'd0; note(NOTE_BOSS); end
                                TG_ASK: begin                                   // judge()
                                    open_talk(TG_VERDICT, 3'd3, T_S2_TALK_TEST[5:0],
                                              T_S2_TALK_IN1_0[5:0] + {code0 - 3'd1, 1'b0} + (seg_q0 == s2_gold(code0)),
                                              T_S2_TALK_IN1_0[5:0] + {code1 - 3'd1, 1'b0} + (seg_q1 == s2_gold(code1)),
                                              (segs_all_ok) ? ((rnd == 2'd2) ? T_S2_TALK_ALLPASS[5:0] : T_S2_TALK_PASS0[5:0] + rnd)
                                                            : T_S2_TALK_FAIL[5:0]);
                                    talk_pass <= segs_all_ok;
                                    note(NOTE_QA0 + rnd * 3 + (seg_q0 == s2_gold(code0)) + (seg_q1 == s2_gold(code1)));
                                end
                                TG_VERDICT: begin
                                    if (!talk_pass) do_damage;
                                    else begin
                                        rnd <= rnd + 2'd1;
                                        if (rnd == 2'd2) say(T_TOAST_DOOR_OPEN[5:0]);
                                        else begin code0 <= qa_k[{rnd + 2'd1, 1'b0}]; code1 <= qa_k[{rnd + 2'd1, 1'b1}]; h_n <= 6'd0; end
                                    end
                                end
                                default: ;
                            endcase
                        end
                    end else if (ev_back && talk_ask && talk_i == talk_n) talk_on <= 1'b0;   // talk_done(False)
                end else if (cutscene) begin
                    sp_stop <= 1'b1;
                end else begin
                    if (play_t != 14'h3FFF) play_t <= play_t + 14'd1;
                    if (freeze_t != 0) freeze_t <= freeze_t - 10'd1;
                    if (zoom_on) begin
                        sp_stop <= 1'b1;
                        if (ev_tap && zoom_t > 8'd48) zoom_on <= 1'b0;
                    end else begin
                        if (sw_rise[13]) begin                                  // try_skill()
                            if (skill_t != 0) say(T_TOAST_SKILL_ON[5:0]);
                            else if (skill_used) say(T_TOAST_SKILL_USED[5:0]);
                            else begin skill_used <= 1'b1; skill_t <= 10'd600; say(T_TOAST_SKILL_GO[5:0]); end
                        end
                        if (hint_on) begin
                            sp_stop <= 1'b1;
                            if (ev_tap || ev_back) hint_on <= 1'b0;
                        end else if (sw[15]) begin                              // inventory_input(ev)
                            sp_stop <= 1'b1;
                            if (ev_press[B_L]) inv_cur <= inv_cur - 2'd1;
                            else if (ev_press[B_R]) inv_cur <= inv_cur + 2'd1;
                            else if (ev_tap) begin
                                case (inv_cur)
                                    2'd0: if (hh == 0) say(T_TOAST_NO_ITEM[5:0]);
                                          else begin hh <= hh - 2'd1; rf_i <= 6'd0; u <= U_HREF; end
                                    2'd1: if (hs == 0) say(T_TOAST_NO_ITEM[5:0]);
                                          else if (parts != 5'd18) begin ms_i <= 5'd0; ms_n <= 5'd0; u <= U_HMISS; end
                                          else if (qa_done) say(T_TOAST_NOTHING_HINT[5:0]);
                                          else if (!codes_ok) begin hs <= hs - 2'd1; hint_on <= 1'b1; hint_wire <= 1'b0;
                                                                     hint_txt <= T_S2_HINT_BENCH[4:0]; hint_ttl <= T_S2_HTITLE_HINT[3:0]; end
                                          else begin hs <= hs - 2'd1; rf_i <= 6'd0; u <= U_HREF; end
                                    2'd2: ;                                     // UNDO: use_item() has no branch for it
                                    default: say(T_TOAST_NO_ITEM[5:0]);         // FREEZE: the counter is never filled
                                endcase
                            end
                        end else if (sw[14]) begin
                            sp_stop <= 1'b1;
                        end else if (!mode_cu) begin                            // map_update()
                            in_dx <= (lvl[B_R] ? 2'sd1 : 2'sd0) - (lvl[B_L] ? 2'sd1 : 2'sd0);
                            in_dy <= (lvl[B_D] ? 2'sd1 : 2'sd0) - (lvl[B_U] ? 2'sd1 : 2'sd0);
                            ox <= px; oy <= py;
                            axis_y <= 1'b0;
                            u <= U_MX;
                        end else begin
                            sp_stop <= 1'b1;
                            u <= U_CU;
                        end
                    end
                end
            end
            // ------------------------------------------------ move_axis(dx, 0) then move_axis(0, dy)
            U_MX: begin
                a_dir <= axis_y ? in_dy : in_dx;
                if ((axis_y ? in_dy : in_dx) == 0 || spd == 0) u <= axis_y ? U_MOVE_END : U_AXDONE;
                else begin
                    tgt <= axis_y ? ((in_dy > 0) ? py + spd : py - spd) : ((in_dx > 0) ? px + spd : px - spd);
                    u <= U_MXB;
                end
            end
            U_MXB: begin
                bk_x <= axis_y ? $signed({2'b0, px[17:8]}) : $signed({2'b0, tgt[17:8]});
                bk_y <= axis_y ? $signed({2'b0, tgt[17:8]}) : $signed({2'b0, py[17:8]});
                bk_go <= 1'b1;
                u <= U_MXW;
            end
            U_MXW: if (!bk_go && !bk_busy) begin
                if (!bk_res) begin
                    if (axis_y) py <= tgt; else px <= tgt;
                    u <= axis_y ? U_MOVE_END : U_AXDONE;
                end else begin gl_off <= 5'd4; gl_sg <= 1'b0; u <= U_GL; end
            end
            U_GL: begin                                                     // glide: blocked(n + g*off)?
                if (gl_off > 5'd20) u <= axis_y ? U_MOVE_END : U_AXDONE;
                else begin
                    if (axis_y) begin bk_x <= $signed({2'b0, px[17:8]}) + (gl_sg ? -$signed({7'd0, gl_off}) : $signed({7'd0, gl_off})); bk_y <= $signed({2'b0, tgt[17:8]}); end
                    else begin bk_x <= $signed({2'b0, tgt[17:8]}); bk_y <= $signed({2'b0, py[17:8]}) + (gl_sg ? -$signed({7'd0, gl_off}) : $signed({7'd0, gl_off})); end
                    bk_go <= 1'b1;
                    u <= U_GLW;
                end
            end
            U_GLW: if (!bk_go && !bk_busy) begin
                if (bk_res) begin
                    if (gl_sg) begin gl_sg <= 1'b0; gl_off <= gl_off + 5'd4; end else gl_sg <= 1'b1;
                    u <= U_GL;
                end else begin                                              // step = min(off, max(1, sp)) sideways
                    if (axis_y) begin bk_x <= $signed({2'b0, px[17:8]}) + (gl_sg ? -$signed({7'd0, glstep}) : $signed({7'd0, glstep})); bk_y <= $signed({2'b0, py[17:8]}); end
                    else begin bk_x <= $signed({2'b0, px[17:8]}); bk_y <= $signed({2'b0, py[17:8]}) + (gl_sg ? -$signed({7'd0, glstep}) : $signed({7'd0, glstep})); end
                    bk_go <= 1'b1;
                    u <= U_GL2W;
                end
            end
            U_GL2W: if (!bk_go && !bk_busy) begin
                if (!bk_res) begin
                    if (axis_y) px <= gl_sg ? px - {glstep, 8'd0} : px + {glstep, 8'd0};
                    else py <= gl_sg ? py - {glstep, 8'd0} : py + {glstep, 8'd0};
                end
                u <= axis_y ? U_MOVE_END : U_AXDONE;
            end
            U_AXDONE: begin axis_y <= 1'b1; u <= U_MX; end
            U_MOVE_END: begin
                sp_upd <= 1'b1; sp_dx <= in_dx; sp_dy <= in_dy; sp_moved <= (px != ox) || (py != oy);
                if (ev_tap) begin fn_i <= 6'd0; fn_best <= 32'd122501; fn_bi <= 6'd63; u <= U_NEAR; end
                else u <= U_EVAL;
            end
            // ------------------------------------------------ find_near() + the action
            U_NEAR: begin
                if (fn_i == 6'd31) u <= U_NEARD;
                else begin
                    fn_ok_r <= fn_ok; fn_r70_r <= fn_r70; fd2_r <= fd2;
                    u <= U_NEAR2;
                end
            end
            U_NEAR2: begin
                if (fn_ok_r && fsc < fn_best) begin fn_best <= fsc; fn_bi <= fn_i; end
                fn_i <= fn_i + 6'd1;
                u <= U_NEAR;
            end
            U_NEARD: begin
                u <= U_EVAL;
                if (fn_bi < 6'd3) begin mode_cu <= 1'b1; cur <= fn_bi[1:0]; page <= 2'd0; cmsg <= 2'd0; end
                else if (fn_bi == 6'd3) begin                                 // npc_interact()
                    if (!codes_ok) open_talk(TG_INFO, 3'd1, T_S2_TALK_INFO0[5:0], T_S2_TALK_INFO0[5:0] + 6'd1, 6'd0, 6'd0);
                    else if (qa_done) open_talk(TG_INFO, 3'd0, T_S2_TALK_DONE[5:0], 6'd0, 6'd0, 6'd0);
                    else open_talk(TG_ASK, 3'd1, T_S2_TALK_ASK0[5:0], T_S2_TALK_ASK1_0[5:0] + rnd, 6'd0, 6'd0);
                end else if (fn_bi < 6'd22) begin                             // pickup(sp) - immediate toast, no zoom freeze
                    done_spots[fn_bi - 6'd4] <= 1'b1;
                    found[s2_spot(fn_bi - 6'd4) >> 40] <= found[s2_spot(fn_bi - 6'd4) >> 40] + 3'd1;
                    parts <= parts + 5'd1;
                    note(NOTE_F0 + fn_bi - 6'd4);
                    if (parts == 5'd17) begin toast <= T_TOAST_ALL_PARTS[5:0]; toast_t <= 8'd240; toast_c <= 1'b0; end
                    else begin
                        toast <= T_TOAST_FOUND_NOT[5:0] + (s2_spot(fn_bi - 6'd4) >> 40); toast_t <= 8'd150; toast_c <= 1'b1;
                        toast_cnt <= {found[s2_spot(fn_bi - 6'd4) >> 40] + 3'd1, s2_qty(s2_spot(fn_bi - 6'd4) >> 40)};
                    end
                end else if (fn_bi < 6'd31) begin                             // open_hint(h)
                    read_hints[fn_bi - 6'd22] <= 1'b1;
                    hint_on <= 1'b1; hint_wire <= 1'b0; hint_txt <= fn_bi - 6'd22; hint_ttl <= fn_bi - 6'd22;
                    note(NOTE_H0 + fn_bi - 6'd22);
                end
            end
            // ------------------------------------------------ closeup_input(ev)
            U_CU: begin
                u <= U_EVAL;
                if (ev_back) begin
                    if (wsrc_on) begin w[cur_sink] <= wprev; wsrc_on <= 1'b0; end
                    else if (msel != 0) msel <= 5'd0;
                    else if (page != 0 && cur != 2'd1) page <= page - 2'd1;
                    else mode_cu <= 1'b0;
                    cmsg <= 3'd0;
                end else case (cur)
                    2'd0: if (ev_tap) page <= (page == 2'd2) ? 2'd0 : page + 2'd1;       // in_whiteboard
                    2'd1: if (ev_tap) begin                                               // in_door
                              if (qa_done) begin state <= ST_CLEAR; form <= 2'd2; end
                              else cmsg <= T_S2_CMSG_LOCKED[2:0];
                          end
                    default: begin                                                        // in_bench
                        if (page == 2'd0) begin
                            if (ev_tap) begin
                                if (parts != 5'd18) cmsg <= T_S2_CMSG_MISSING[2:0];
                                else begin
                                    page <= 2'd1;
                                    if (!codes_ok && !qa_done) begin note(NOTE_BENCH); pr_i <= 3'd5; u <= U_PAIRS; end
                                end
                            end
                        end else if (!qa_done) begin
                            if (sw_rise[8]) begin                                         // SW8 Auto-Wire (circuit.txt)
                                msel <= 5'd0; wsrc_on <= 1'b0;
                                snap[snap_wp] <= wflat; hist[h_n] <= {1'b1, 5'd0, snap_wp, 4'd0}; snap_wp <= !snap_wp;
                                if (h_n != 6'd63) h_n <= h_n + 6'd1;
                                for (k = 0; k < 54; k = k + 1) w[k] <= ref_src(k[5:0]);
                                cmsg <= T_S2_CMSG_AUTOWIRE[2:0];
                            end else if (wsrc_on) begin
                                if (ev_press[B_U] || ev_press[B_D]) begin
                                    if (ev_press[B_U]) begin wsrc <= (wsrc == 0) ? 5'd27 : wsrc - 5'd1; w[cur_sink] <= (wsrc == 0) ? 5'd27 : wsrc - 5'd1; end
                                    else begin wsrc <= (wsrc == 5'd27) ? 5'd0 : wsrc + 5'd1; w[cur_sink] <= (wsrc == 5'd27) ? 5'd0 : wsrc + 5'd1; end
                                end else if (ev_tap) wsrc_on <= 1'b0;
                            end else if (ev_press[B_L] || ev_press[B_R] || ev_press[B_U] || ev_press[B_D]) begin
                                cs_dx <= (ev_press[B_R] ? 2'sd1 : 2'sd0) - (ev_press[B_L] ? 2'sd1 : 2'sd0);
                                cs_dy <= (ev_press[B_D] ? 2'sd1 : 2'sd0) - (ev_press[B_U] ? 2'sd1 : 2'sd0);
                                cs_i <= 7'd0; cs_has <= 1'b0; cs_best <= wcur;
                                u <= U_CSTEP;
                            end else if (ev_tap) begin
                                if (wcur == S2_CUR_CLEAR) begin                                   // clear all
                                    msel <= 5'd0;
                                    snap[snap_wp] <= wflat; hist[h_n] <= {1'b1, 5'd0, snap_wp, 4'd0}; snap_wp <= !snap_wp;
                                    if (h_n != 6'd63) h_n <= h_n + 6'd1;
                                    for (k = 0; k < 54; k = k + 1) w[k] <= 5'd0;
                                end else if (wcur == S2_CUR_UNDO) u <= U_UNDO;
                                else if (!cur_is_sink) msel <= (msel == cur_src) ? 5'd0 : cur_src;     // pick_source()
                                else if (msel != 0) begin
                                    hist[h_n] <= {1'b0, cur_sink, w[cur_sink][3:0]}; hist_hi[h_n] <= w[cur_sink][4];
                                    if (h_n != 6'd63) h_n <= h_n + 6'd1;
                                    w[cur_sink] <= msel; msel <= 5'd0; cmsg <= 3'd0;
                                end else begin
                                    hist[h_n] <= {1'b0, cur_sink, w[cur_sink][3:0]}; hist_hi[h_n] <= w[cur_sink][4];
                                    if (h_n != 6'd63) h_n <= h_n + 6'd1;
                                    wprev <= w[cur_sink]; wsrc <= w[cur_sink]; wsrc_on <= 1'b1; cmsg <= 3'd0;
                                end
                            end
                        end
                    end
                endcase
            end
            U_CSTEP: begin                                                  // cursor_step(): nearest stop that way (3-stage)
                if (cs_i == S2_NCUR[6:0]) begin wcur <= cs_best; u <= U_EVAL; end
                else begin cs_p0_r <= cs_p0; cs_p1_r <= s2_cur(cs_i); u <= U_CSTEP2; end
            end
            U_CSTEP2: begin
                cs_ok_r <= (cs_i != wcur && c_ax >= 14'sd4);
                cs_sc_r <= c_sc;
                u <= U_CSTEP3;
            end
            U_CSTEP3: begin
                if (cs_ok_r && (!cs_has || cs_sc_r < cs_bs)) begin cs_has <= 1'b1; cs_bs <= cs_sc_r; cs_best <= cs_i; end
                cs_i <= cs_i + 7'd1;
                u <= U_CSTEP;
            end
            U_UNDO: begin                                                   // undo_wire(): pop until something changes (3-stage)
                if (h_n == 0) begin cmsg <= T_S2_CMSG_UNDO0[1:0]; u <= U_EVAL; end
                else begin
                    h_n      <= h_n - 6'd1;
                    un_ent_r <= hist[h_n - 6'd1];
                    un_hi_r  <= hist_hi[h_n - 6'd1];
                    u        <= U_UNDO2;
                end
            end
            U_UNDO2: begin
                if (un_ent_r[10]) begin
                    un_snap_diff_r <= (snap[un_ent_r[4]] != wflat);
                    u <= U_UNDO3;
                end else if (w[un_ent_r[9:4]] != {un_hi_r, un_ent_r[3:0]}) begin
                    w[un_ent_r[9:4]] <= {un_hi_r, un_ent_r[3:0]};
                    msel <= 5'd0; wsrc_on <= 1'b0; cmsg <= 2'd0; u <= U_EVAL;
                end else u <= U_UNDO;
            end
            U_UNDO3: begin
                if (un_snap_diff_r) begin
                    for (k = 0; k < 54; k = k + 1) w[k] <= snap[un_ent_r[4]][k * 5 +: 5];
                    msel <= 5'd0; wsrc_on <= 1'b0; cmsg <= 2'd0; u <= U_EVAL;
                end else u <= U_UNDO;
            end
            // ------------------------------------------------ make_pairs() + new_round()
            U_PAIRS: begin
                if (pairs_ok || pr_i == 3'd0) begin
                    pairs_ok <= 1'b1; codes_ok <= 1'b1; h_n <= 6'd0;
                    code0 <= qa_k[{rnd, 1'b0}]; code1 <= qa_k[{rnd, 1'b1}];
                    u <= U_EVAL;
                end else begin                                              // j = lfsr_pick(i + 1); swap
                    lfsr <= lfsr_next(lfsr);
                    if ((lfsr_next(lfsr) & 16'd7) <= {13'd0, pr_i}) begin
                        qa_k[pr_i] <= qa_k[lfsr_next(lfsr) & 3'd7];
                        qa_k[lfsr_next(lfsr) & 3'd7] <= qa_k[pr_i];
                        pr_i <= pr_i - 3'd1;
                    end
                end
            end
            // ------------------------------------------------ hints
            U_HREF: begin                                                   // wiring_hint()
                hint_on <= 1'b1; hint_ttl <= T_S2_HTITLE_HINT[3:0];
                if (segs_all_ok) begin hint_wire <= 1'b0; hint_txt <= T_S2_HINT_MATCH[4:0]; u <= U_EVAL; end
                else if (rf_i == S2_NREF[5:0]) begin hint_wire <= 1'b0; hint_txt <= T_S2_HINT_MATCH[4:0]; u <= U_EVAL; end
                else if (w[rf[10:5]] != rf[4:0]) begin
                    hint_wire <= 1'b1; hint_txt <= T_S2_HINT_TRY[4:0]; hint_sink <= rf[10:5]; hint_src <= rf[4:0]; u <= U_EVAL;
                end else rf_i <= rf_i + 6'd1;
            end
            U_HMISS: begin                                                  // count the missing spots, pick lfsr_pick(8)
                if (ms_i == 5'd18) begin
                    lfsr <= lfsr_next(lfsr);
                    ms_r <= lfsr_next(lfsr) & 3'd7;
                    ms_k <= 5'd0; ms_i <= 5'd0;
                    u <= U_HMISS2;
                end else begin
                    if (!done_spots[ms_i]) ms_n <= ms_n + 5'd1;
                    ms_i <= ms_i + 5'd1;
                end
            end
            U_HMISS2: begin                                                 // index (r % n) among the missing ones
                if (ms_r >= ms_n) ms_r <= ms_r - ms_n[2:0];
                else if (done_spots[ms_i]) ms_i <= ms_i + 5'd1;
                else if (ms_k == ms_r) begin
                    hs <= hs - 2'd1; hint_on <= 1'b1; hint_wire <= 1'b0;
                    hint_txt <= T_S2_HINT_C0[4:0] + ms_i; hint_ttl <= T_S2_HTITLE_HINT[3:0];
                    u <= U_EVAL;
                end else begin ms_k <= ms_k + 5'd1; ms_i <= ms_i + 5'd1; end
            end
            // ------------------------------------------------ evaluate the circuit: live input, QA code 0, QA code 1
            U_EVAL: begin ev_which <= 2'd0; ev_code <= sw[2:0]; ev_go <= 1'b1; u <= U_EVW; end
            U_EVW: if (!ev_go && !ev_busy) begin
                if (ev_which == 2'd2) begin wp_i <= 6'd0; u <= U_WP; end
                else begin
                    ev_which <= ev_which + 2'd1; ev_code <= (ev_which == 2'd0) ? code0 : code1; ev_go <= 1'b1;
                end
            end
            // precompute all 54 placed Manhattan wire descriptors and 18 marker coords (4-stage pipeline for 74.25 MHz)
            U_WP: begin
                wp_sid_r <= w[wp_i];
                wp_kp_r  <= s2_cur({1'b0, wp_i});
                if (wp_i < 6'd18) mk_s_r <= s2_spot(wp_i[4:0]);
                u <= U_WP1;
            end
            U_WP1: begin
                wp_sp_r  <= nearest_src(wp_sid_r, wp_kp_r[19:10], wp_kp_r[9:0]);
                wp_kx_r  <= v23({1'b0, wp_kp_r[19:10]});
                wp_ky_r  <= v23({1'b0, wp_kp_r[9:0]});
                wp_col_r <= wire_color(wp_sid_r, src_val[wp_sid_r]);
                if (wp_i < 6'd18) begin
                    mk_vx[wp_i[4:0]] <= v23({1'b0, mk_s_r[39:30]});
                    mk_vy[wp_i[4:0]] <= v23({1'b0, mk_s_r[29:20]});
                end
                u <= U_WP2;
            end
            U_WP2: begin
                wp_sx_r <= v23({1'b0, wp_sp_r[19:10]});
                wp_sy_r <= v23({1'b0, wp_sp_r[9:0]});
                u <= U_WP3;
            end
            U_WP3: begin : blk_wp3
                reg [9:0] x0, x1; reg [8:0] y0, y1;
                x0 = (wp_kx_r[9:0] < wp_sx_r[9:0]) ? wp_kx_r[9:0] : wp_sx_r[9:0];
                x1 = (wp_kx_r[9:0] > wp_sx_r[9:0]) ? wp_kx_r[9:0] : wp_sx_r[9:0];
                y0 = (wp_ky_r[8:0] < wp_sy_r[8:0]) ? wp_ky_r[8:0] : wp_sy_r[8:0];
                y1 = (wp_ky_r[8:0] > wp_sy_r[8:0]) ? wp_ky_r[8:0] : wp_sy_r[8:0];
                wh_mem[wp_i] <= { (wp_sid_r != 5'd0), x0,
                                  (wp_ky_r > 11'd0) ? (wp_ky_r[8:0] - 9'd1) : 9'd0,
                                  (x1 - x0) + 10'd2, wp_col_r };
                wv_mem[wp_i] <= { (wp_sid_r != 5'd0),
                                  (wp_sx_r > 11'd0) ? (wp_sx_r[9:0] - 10'd1) : 10'd0,
                                  y0, (y1 - y0) + 9'd2, wp_col_r };
                if (wp_i == 6'd53) u <= U_IDLE;
                else begin wp_i <= wp_i + 6'd1; u <= U_WP; end
            end
            // ------------------------------------------------ reset_stage()
            U_RESET: begin
                state <= ST_PLAY; mode_cu <= 1'b0; cur <= 2'd0; page <= 2'd0; cmsg <= 3'd0;
                px <= {S2_SPAWN_X, 8'd0}; py <= {S2_SPAWN_Y, 8'd0};
                done_spots <= 18'd0; read_hints <= 9'd0; parts <= 5'd0;
                for (k = 0; k < 9; k = k + 1) found[k] <= 3'd0;
                rnd <= 2'd0; codes_ok <= 1'b0; pairs_ok <= 1'b0;
                for (k = 0; k < 6; k = k + 1) qa_k[k] <= k + 1;
                code0 <= 3'd1; code1 <= 3'd2;
                for (k = 0; k < 54; k = k + 1) w[k] <= 5'd0;
                wcur <= 7'd0; wsrc_on <= 1'b0; wsrc <= 5'd0; wprev <= 5'd0; msel <= 5'd0; h_n <= 6'd0; snap_wp <= 1'b0;
                note_wp <= 3'd0; note_n <= 4'd0;
                hh <= 2'd0; hs <= 2'd0; undo_n <= 2'd0; freeze_n <= 2'd0; slow_t <= 10'd0; freeze_t <= 10'd0;
                r_run <= 4'b0010; r_done <= 4'b0010;
                hint_on <= 1'b0; toast <= 6'd0; toast_t <= 8'd0; inv_cur <= 2'd0;
                flash_t <= 5'd0; over_t <= 8'd0; play_t <= 14'd0; skill_t <= 10'd0; skill_used <= 1'b0; zoom_on <= 1'b0;
                zoom_x <= 10'd0; zoom_y <= 10'd0; wp_i <= 6'd0;
                npc_st <= N_OFF; nx <= {10'd622, 8'd0}; ny <= {10'd186, 8'd0}; n_pi <= 6'd0; n_path <= 1'b0; n_walk <= 1'b0;
                talk_on <= 1'b0; intro_started <= 1'b0; cutscene <= 1'b0;
                dk_clear <= 1'b1; sp_reset <= 1'b1;
                if (!rs_start) begin hearts <= 2'd3; armor <= 2'd0; shard <= 1'b0; boost <= 1'b0; nbacks <= (nbacks > 3'd2) ? 3'd2 : nbacks; end
                rs_start <= 1'b0;
                if (jmp_run) begin jmp_run <= 1'b0; u <= U_JUMP; end
                else u <= U_EVAL;
            end
            // ------------------------------------------------ demo hub: jump_to / do_action
            U_JUMP: begin
                if (j_key == 3'd4) begin state <= ST_CLEAR; form <= 2'd2; u <= U_EVAL; end
                else begin
                    intro_started <= 1'b1; cutscene <= 1'b0; talk_on <= 1'b0;
                    npc_st <= N_SIT; nx <= {10'd818, 8'd0}; ny <= {10'd336, 8'd0};
                    if (j_key == 3'd1) begin
                        done_spots[7:0] <= 8'hFF;
                        found[0] <= 3'd1; found[1] <= 3'd1; found[2] <= 3'd1; found[5] <= 3'd2; found[6] <= 3'd3;
                        parts <= 5'd8;
                        dk_round <= 2'd2; u <= U_CARD;
                    end else begin
                        done_spots <= 18'h3FFFF; parts <= 5'd18;
                        found[0] <= 3'd1; found[1] <= 3'd1; found[2] <= 3'd2; found[3] <= 3'd1; found[4] <= 3'd1;
                        found[5] <= 3'd3; found[6] <= 3'd7; found[7] <= 3'd1; found[8] <= 3'd1;
                        r_run[2] <= 1'b1; r_done[2] <= 1'b1;
                        pr_i <= 3'd5;
                        if (j_key == 3'd2) begin
                            backs <= 8'b00_10_01_00; nbacks <= 3'd3;
                            rnd <= 2'd0; r_run[3] <= 1'b1; r_done[3] <= 1'b1;
                            mode_cu <= 1'b1; cur <= 2'd2; page <= 2'd1;
                            u <= U_PAIRS;
                        end else begin
                            rnd <= 2'd3; r_run[3] <= 1'b1; r_done[3] <= 1'b1;
                            codes_ok <= 1'b1; pairs_ok <= 1'b1;
                            for (k = 0; k < 54; k = k + 1) w[k] <= ref_src(k[5:0]);
                            say(T_TOAST_DOOR_OPEN[5:0]);
                            u <= U_EVAL;
                        end
                    end
                end
            end
            U_ACT: begin
                case (a_key)
                    3'd0, 3'd1, 3'd4: begin
                        done_spots <= 18'h3FFFF; parts <= 5'd18;
                        found[0] <= 3'd1; found[1] <= 3'd1; found[2] <= 3'd2; found[3] <= 3'd1; found[4] <= 3'd1;
                        found[5] <= 3'd3; found[6] <= 3'd7; found[7] <= 3'd1; found[8] <= 3'd1;
                        if (a_key == 3'd0) begin
                            say(T_TOAST_ALL_PARTS[5:0]);
                            u <= U_EVAL;
                        end else begin
                            intro_started <= 1'b1; cutscene <= 1'b0; talk_on <= 1'b0;
                            npc_st <= N_SIT; nx <= {10'd818, 8'd0}; ny <= {10'd336, 8'd0};
                            if (a_key == 3'd4) begin
                                mode_cu <= 1'b1; cur <= 2'd2; page <= 2'd1;
                                for (k = 0; k < 54; k = k + 1) w[k] <= ref_src(k[5:0]);
                                cmsg <= T_S2_CMSG_AUTOWIRE[2:0];
                            end
                            if (!codes_ok && !qa_done) begin pr_i <= 3'd5; u <= U_PAIRS; end
                            else u <= U_EVAL;
                        end
                    end
                    3'd2: begin
                        if (armor != 2'd3) armor <= armor + 2'd1;
                        say(T_TOAST_ARMOR_P1[5:0]);
                        u <= U_EVAL;
                    end
                    default: begin
                        do_damage;
                        u <= U_EVAL;
                    end
                endcase
            end
            default: u <= U_IDLE;
            endcase

            // ---- card deck results (same frame) ----
            if (dk_pick) begin
                if (nbacks < 3'd4) begin backs[{nbacks[1:0], 1'b0} +: 2] <= dk_ppos; nbacks <= nbacks + 3'd1; end
                card_name <= T_ITEM_NAME_NONE[3:0];
                case ({dk_rnd, dk_pidx})
                    {2'd2, 2'd0}: begin card_name <= T_ITEM_NAME_SHARD[3:0]; card_desc <= T_CARD_DESC_S2_SHARD[3:0];
                                        if (shard) begin shard <= 1'b0; if (armor != 2'd3) armor <= armor + 2'd1; end else shard <= 1'b1; end
                    {2'd2, 2'd1}, {2'd3, 2'd1}: begin card_name <= T_ITEM_NAME_HINT[3:0]; card_desc <= T_CARD_DESC_S2_HINT[3:0];
                                        if (hs != 2'd3) hs <= hs + 2'd1; end
                    {2'd2, 2'd2}: begin card_name <= T_ITEM_NAME_FREEZE[3:0]; card_desc <= T_CARD_DESC_S2_FREEZE[3:0]; freeze_t <= 10'd600; end
                    {2'd3, 2'd0}: begin card_name <= T_ITEM_NAME_HINT[3:0]; card_desc <= T_CARD_DESC_S2_HINT[3:0];
                                        if (hh != 2'd3) hh <= hh + 2'd1; end
                    default: begin card_name <= T_ITEM_NAME_HEART_LOSS[3:0];
                        if (armor != 0) begin armor <= armor - 2'd1; say(T_TOAST_ARMOR_PROT[5:0]); card_desc <= T_CARD_DESC_S2_HEART_ARMOR[3:0]; end
                        else begin
                            card_desc <= T_CARD_DESC_S2_HEART_LOSS[3:0];
                            hearts <= hearts - 2'd1; say(T_TOAST_HEART_LOSS[5:0]);
                            if (hearts <= 2'd1) begin state <= ST_OVER; over_t <= 8'd180; end
                        end
                    end
                endcase
            end
            if (dk_done) r_done[dk_rnd] <= 1'b1;
            if (dk_skipped) begin r_done[3] <= 1'b1; say(T_TOAST_SKIPPED4[5:0]); end
        end
    end

    // ---------------------------------------------------------------- hand-off
    assign ho_hearts = hearts; assign ho_armor = armor; assign ho_shard = shard; assign ho_boost = boost;
    assign ho_form = form; assign ho_career = career; assign ho_backs = backs; assign ho_nbacks = nbacks;

    // ---------------------------------------------------------------- drawing (draw_world / draw_closeup / draw_board)
    // player and Boss (view coordinates = room * 2/3)
    reg signed [11:0] pl_vx_r, pl_vy_r, np_vx_r, np_vy_r;
    always @(posedge clk) begin
        if (rst) begin
            pl_vx_r <= 12'sd0; pl_vy_r <= 12'sd0; np_vx_r <= 12'sd0; np_vy_r <= 12'sd0;
        end else begin
            pl_vx_r <= $signed({1'b0, v23({1'b0, pxi})});
            pl_vy_r <= $signed({1'b0, v23({1'b0, pyi})});
            np_vx_r <= $signed({1'b0, v23({1'b0, nx[17:8]})});
            np_vy_r <= $signed({1'b0, v23({1'b0, ny[17:8]})});
        end
    end
    wire [7:0]  pl_asset = 8'd12 + {sp_dir, 1'b0} + sp_dir + sp_pose;          // workshop shirt (form 1) frames
    wire [7:0]  pl_asset_f = pl_asset;                                        // Stage 2 always shows the workshop shirt
    wire [49:0] plp = place_pl_s2(pl_asset_f);
    wire [127:0] o_player = obj_img(pl_vx_r + $signed(plp[49:39]), pl_vy_r + $signed(plp[38:29]), plp[28:19], plp[18:10],
                                    pl_asset_f, 19'd0, 18'd0, plp[9:0], plp[9:0], 1'b0);
    wire        npc_vis = (npc_st != N_OFF);
    wire [49:0] bsp = (npc_st == N_SIT) ? place_boss_sit(A_NPC_BOSS) : place_boss_stand(A_NPC_BOSS);
    wire [127:0] o_boss = obj_img(np_vx_r + $signed(bsp[49:39]), np_vy_r + $signed(bsp[38:29]), bsp[28:19], bsp[18:10],
                                  A_NPC_BOSS, 19'd0, 18'd0, bsp[9:0], bsp[9:0], n_left);
    wire        boss_first = npc_vis && (ny < py);

    // background zoom placeholder (pickup zoom disabled for instant toast)
    wire [127:0] o_bg = obj_img(11'sd0, 10'sd0, 10'd640, 9'd360, A_BG_OFFICE, 19'd0, 18'd0, 10'd256, 10'd256, 1'b0);
    // workshop-shirt skill: glowing markers on the hidden parts (pre-scaled in U_WP)
    wire [4:0]  mk = obj_idx[4:0] - 5'd1;
    wire [127:0] o_mark = obj_blend($signed({1'b0, mk_vx[mk]}) - 11'sd8, $signed({1'b0, mk_vy[mk]}) - 10'sd8,
                                   10'd16, 9'd16, 12'hFE6, play_t[4] ? 4'd11 : 4'd7);

    // cards (draw_cards): same placement as Stage 1
    function [7:0] card_asset2;
        input [1:0] rnd_; input [1:0] car; input [1:0] pos; input [1:0] idx; input revealed;
        reg [7:0] bk;
        begin
            case (car)
                2'd0: bk = (pos == 0) ? C_AIR_CARD1 : (pos == 1) ? C_AIR_CARD2 : C_AIR_CARD3;
                2'd1: bk = (pos == 0) ? C_EARTH_CARD1 : (pos == 1) ? C_EARTH_CARD2 : C_EARTH_CARD3;
                default: bk = (pos == 0) ? C_WATER_CARD1 : (pos == 1) ? C_WATER_CARD2 : C_WATER_CARD3;
            endcase
            if (!revealed) card_asset2 = bk;
            else case ({rnd_, idx})
                {2'd2, 2'd0}: card_asset2 = (car == 0) ? C_AIR_SHARD : (car == 1) ? C_EARTH_SHARD : C_WATER_SHARD;
                {2'd2, 2'd1}, {2'd3, 2'd1}: card_asset2 = (car == 0) ? C_AIR_HINT_SMART : (car == 1) ? C_EARTH_HINT_SMART : C_WATER_HINT_SMART;
                {2'd2, 2'd2}: card_asset2 = (car == 0) ? C_AIR_FREEZE : (car == 1) ? C_EARTH_FREEZE : C_WATER_FREEZE;
                {2'd3, 2'd0}: card_asset2 = (car == 0) ? C_AIR_HINT_HARD : (car == 1) ? C_EARTH_HINT_HARD : C_WATER_HINT_HARD;
                default:      card_asset2 = (car == 0) ? C_AIR_HEART_LOSS : (car == 1) ? C_EARTH_HEART_LOSS : C_WATER_HEART_LOSS;
            endcase
        end
    endfunction
    function [1:0] perm_at;
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
    wire [1:0]  cpos = obj_idx[1:0] - 2'd3;                                 // objects 23..25
    wire [7:0]  c_asset = card_asset2(dk_rnd, career, cpos, perm_at(dk_perm_q, cpos), dk_face && dk_fpos == cpos);
    wire [49:0] cpl = place_card(c_asset);
    wire signed [11:0] c_cx = (cpos == 2'd0) ? 12'sd206 : (cpos == 2'd1) ? 12'sd326 : 12'sd446;
    wire [127:0] o_card = obj_img(c_cx + $signed(cpl[49:39]), 12'sd120 + $signed(cpl[38:29]), cpl[28:19], cpl[18:10],
                                  c_asset, 19'd0, 18'd0, cpl[9:0], cpl[9:0], 1'b0);

    // breadboard objects (UI rect -> view rect)
    function [127:0] fu; input [10:0] x, y, ww, hh_; input [11:0] col;
        fu = obj_fill($signed(v23(x)), $signed(v23(y)), v23(ww), v23(hh_), col, 1'b0);
    endfunction
    // draw_set() directly in 640x360 view coordinates (eliminates DSP multipliers on obj_idx)
    function [127:0] segobj_v; input [2:0] s; input [10:0] x, y, ww, hh_, t; input on; input [11:0] off;
        reg [10:0] h2; reg [11:0] c; begin
            h2 = hh_ >> 1; c = on ? 12'hF42 : off;
            case (s)
                3'd0: segobj_v = obj_fill(x + t, y, ww - 2 * t, t, c, 1'b0);
                3'd1: segobj_v = obj_fill(x + ww - t, y + t, t, h2 - t, c, 1'b0);
                3'd2: segobj_v = obj_fill(x + ww - t, y + h2, t, h2 - t, c, 1'b0);
                3'd3: segobj_v = obj_fill(x + t, y + hh_ - t, ww - 2 * t, t, c, 1'b0);
                3'd4: segobj_v = obj_fill(x, y + h2, t, h2 - t, c, 1'b0);
                3'd5: segobj_v = obj_fill(x, y + t, t, h2 - t, c, 1'b0);
                default: segobj_v = obj_fill(x + t, y + h2 - (t >> 1), ww - 2 * t, t, c, 1'b0);
            endcase
        end endfunction
    wire [3:0] bi = obj_idx[3:0];
    wire [19:0] cur_p = s2_cur(wcur);
    wire        hot_undo = (wcur == S2_CUR_UNDO) && !qa_done, hot_clear = (wcur == S2_CUR_CLEAR) && !qa_done;
    reg  [6:0]  msel_stop;
    wire [19:0] msel_p = s2_cur(msel_stop);
    always @(*) begin                                                       // first cursor stop of the selected source
        msel_stop = 7'd0;
        for (q = S2_NCUR - 3; q >= S2_NSINKS; q = q - 1) if (s2_cur_src(q) == msel) msel_stop = q;
    end
    wire        pw0 = (w[S2_U1_VCC] == S2_SRC_1) && (w[S2_U1_GND] == S2_SRC_0);
    wire        pw1 = (w[S2_U2_VCC] == S2_SRC_1) && (w[S2_U2_GND] == S2_SRC_0);
    wire        pw2 = (w[S2_U3_VCC] == S2_SRC_1) && (w[S2_U3_GND] == S2_SRC_0);
    wire        pw3 = (w[S2_U4_VCC] == S2_SRC_1) && (w[S2_U4_GND] == S2_SRC_0);
    // Registered board cursor / active-source view coordinates (removes v23 DSP multipliers from obj_desc)
    wire [4:0]  tr_src = cur_is_sink ? w[cur_sink] : 5'd0;
    wire        tr_on  = !qa_done && cur_is_sink && (tr_src != 5'd0);
    wire [19:0] tr_sp  = nearest_src(tr_src, cur_p[19:10], cur_p[9:0]);
    reg  [19:0] tr_sp_r;
    reg  [4:0]  tr_src_r;
    reg         tr_on_r1;
    reg  [9:0]  cur_vx_r, msel_vx_r, tr_sp_vx_r;
    reg  [8:0]  cur_vy_r, msel_vy_r, tr_sp_vy_r;
    reg  [11:0] tr_col_r;
    reg         tr_on_r;
    always @(posedge clk) begin
        if (rst) begin
            cur_vx_r <= 10'd0; cur_vy_r <= 9'd0;
            msel_vx_r <= 10'd0; msel_vy_r <= 9'd0;
            tr_sp_r <= 20'd0; tr_src_r <= 5'd0; tr_on_r1 <= 1'b0;
            tr_sp_vx_r <= 10'd0; tr_sp_vy_r <= 9'd0;
            tr_col_r <= 12'd0; tr_on_r <= 1'b0;
        end else begin
            cur_vx_r   <= v23({1'b0, cur_p[19:10]});
            cur_vy_r   <= v23({1'b0, cur_p[9:0]});
            msel_vx_r  <= v23({1'b0, msel_p[19:10]});
            msel_vy_r  <= v23({1'b0, msel_p[9:0]});
            tr_sp_r    <= tr_sp;
            tr_src_r   <= tr_src;
            tr_on_r1   <= tr_on;
            tr_sp_vx_r <= v23({1'b0, tr_sp_r[19:10]});
            tr_sp_vy_r <= v23({1'b0, tr_sp_r[9:0]});
            tr_col_r   <= wire_color(tr_src_r, src_val[tr_src_r]);
            tr_on_r    <= tr_on_r1;
        end
    end
    wire [41:0] wh_rd = (obj_idx >= 8'd57 && obj_idx <= 8'd110) ? wh_mem[obj_idx - 8'd57] : 42'd0;
    wire [40:0] wv_rd = (obj_idx >= 8'd111 && obj_idx <= 8'd164) ? wv_mem[obj_idx - 8'd111] : 41'd0;
    reg [127:0] o_board;
    always @(*) begin
        o_board = OBJ_NONE;
        case (obj_idx)
            8'd0:  o_board = obj_fill(11'sd0, 10'sd0, 10'd640, 9'd77, 12'h112, 1'b0);
            8'd1:  o_board = obj_fill(11'sd11, 10'sd77, 10'd619, 9'd256, 12'hEDD, 1'b0);
            8'd2:  o_board = fu(11'd184, 11'd120, 11'd376, 11'd4, 12'hD44);
            8'd3:  o_board = fu(11'd184, 11'd244, 11'd376, 11'd4, 12'h45D);
            8'd4:  o_board = fu(11'd184, 11'd296, 11'd376, 11'd4, 12'hD44);
            8'd5:  o_board = fu(11'd184, 11'd476, 11'd376, 11'd4, 12'h45D);
            8'd6:  o_board = fu(11'd190, 11'd150, 11'd168, 11'd64, 12'h333);
            8'd7:  o_board = fu(11'd400, 11'd150, 11'd168, 11'd64, 12'h333);
            8'd8:  o_board = fu(11'd190, 11'd330, 11'd168, 11'd64, 12'h333);
            8'd9:  o_board = fu(11'd400, 11'd330, 11'd168, 11'd64, 12'h333);
            8'd10: o_board = fu(11'd24, 11'd124, 11'd140, 11'd74, 12'h455);
            8'd11: o_board = fu(11'd34, 11'd144, 11'd80, 11'd26, 12'h131);
            8'd12: o_board = fu(11'd26, 11'd208, 11'd128, 11'd120, 12'h25B);
            8'd13, 8'd14, 8'd15: o_board = obj_fill(sw[2'd2 - (obj_idx[1:0] - 2'd1)] ? 11'sd53 : 11'sd34,
                                                    (obj_idx == 8'd13) ? 10'sd154 : (obj_idx == 8'd14) ? 10'sd176 : 10'sd197,
                                                    10'd14, 9'd8, sw[2'd2 - (obj_idx[1:0] - 2'd1)] ? 12'hFFF : 12'h9AB, 1'b0);
            8'd16, 8'd17, 8'd18: o_board = obj_fill((obj_idx == 8'd16) ? 11'sd26 : (obj_idx == 8'd17) ? 11'sd50 : 11'sd74,
                                                    10'sd226, 10'd9, 9'd25, 12'hDB7, 1'b0);
            8'd19, 8'd20, 8'd21, 8'd22, 8'd23, 8'd24, 8'd25:
                   o_board = obj_fill(11'sd430,
                                      (obj_idx == 8'd19) ? 10'sd95 : (obj_idx == 8'd20) ? 10'sd127 :
                                      (obj_idx == 8'd21) ? 10'sd159 : (obj_idx == 8'd22) ? 10'sd191 :
                                      (obj_idx == 8'd23) ? 10'sd223 : (obj_idx == 8'd24) ? 10'sd255 : 10'sd287,
                                      10'd26, 9'd9, 12'hDB7, 1'b0);
            8'd26: o_board = fu(11'd770, 11'd128, 11'd160, 11'd230, 12'h111);
            8'd27, 8'd28, 8'd29, 8'd30, 8'd31, 8'd32, 8'd33:
                   o_board = segobj_v(obj_idx - 8'd27, 11'd533, 11'd100, 11'd66, 11'd120, 11'd10, seg_live[6 - (obj_idx - 8'd27)], 12'h312);
            8'd34, 8'd35: o_board = fu(11'd16 + (obj_idx[0] ? 11'd262 : 11'd0), 11'd48, 11'd254, 11'd66, 12'h234);
            8'd36, 8'd37, 8'd38, 8'd39, 8'd40, 8'd41, 8'd42:
                   o_board = segobj_v(obj_idx - 8'd36, 11'd150, 11'd38, 11'd18, 11'd32, 11'd3, seg_q0[6 - (obj_idx - 8'd36)], 12'h235);
            8'd43, 8'd44, 8'd45, 8'd46, 8'd47, 8'd48, 8'd49:
                   o_board = segobj_v(obj_idx - 8'd43, 11'd325, 11'd38, 11'd18, 11'd32, 11'd3, seg_q1[6 - (obj_idx - 8'd43)], 12'h235);
            8'd50: o_board = fu(11'd548, 11'd48, 11'd84, 11'd66, 12'h123);
            8'd51: o_board = fu(11'd636, 11'd58, 11'd146, 11'd34, hot_undo ? 12'hFE7 : 12'h234);
            8'd52: o_board = fu(11'd790, 11'd58, 11'd154, 11'd34, hot_clear ? 12'hFE7 : 12'h234);
            8'd53: o_board = fu(11'd756, 11'd430, 11'd184, 11'd62, 12'h113);
            8'd165: if (tr_on_r) o_board = obj_fill($signed({1'b0, tr_sp_vx_r}) - 11'sd3, $signed({1'b0, tr_sp_vy_r}) - 10'sd3, 10'd7, 9'd7, tr_col_r, 1'b0);
            8'd166: if (!qa_done && wcur != S2_CUR_CLEAR && wcur != S2_CUR_UNDO)
                        o_board = obj_blend($signed({1'b0, cur_vx_r}) - 11'sd10, $signed({1'b0, cur_vy_r}) - 10'sd10, 10'd20, 9'd20, 12'hD50, 4'd9);
            8'd167: if (!qa_done && msel != 0)
                        o_board = obj_blend($signed({1'b0, msel_vx_r}) - 11'sd9, $signed({1'b0, msel_vy_r}) - 10'sd9, 10'd18, 9'd18, 12'h3BF, 4'd9);
            8'd169, 8'd170, 8'd171, 8'd172:
                    o_board = obj_fill((obj_idx == 8'd169) ? 11'sd520 : (obj_idx == 8'd170) ? 11'sd544 : (obj_idx == 8'd171) ? 11'sd568 : 11'sd592,
                                       10'sd296, 10'd8, 9'd7,
                                       ((obj_idx == 8'd169) ? pw0 : (obj_idx == 8'd170) ? pw1 : (obj_idx == 8'd171) ? pw2 : pw3) ? 12'h2C5 : 12'hA44, 1'b0);
            8'd173: if (flash_t != 0) o_board = obj_blend(11'sd0, 10'sd0, 10'd640, 9'd360, 12'hF00, 4'd5);
            default: begin
                if (wh_rd[41])      o_board = obj_fill($signed({1'b0, wh_rd[40:31]}), $signed({1'b0, wh_rd[30:22]}), wh_rd[21:12], 9'd2, wh_rd[11:0], 1'b0);
                else if (wv_rd[40]) o_board = obj_fill($signed({1'b0, wv_rd[39:30]}), $signed({1'b0, wv_rd[29:21]}), 10'd2, wv_rd[20:12], wv_rd[11:0], 1'b0);
            end
        endcase
    end

    always @(*) begin
        obj_desc = OBJ_NONE;
        if (on_board && state == ST_PLAY && !dk_active) obj_desc = o_board;
        else if (obj_idx[7:6] == 2'd0) begin
            if (mode_cu && state == ST_PLAY) begin
                if (obj_idx[5:0] == 6'd0) obj_desc = obj_fill(11'sd0, 10'sd0, 10'd640, 9'd360, 12'h000, 1'b0);
                else if (obj_idx[5:0] == 6'd1 && cur == 2'd1) obj_desc = obj_fill(11'sd200, 10'sd60, 10'd240, 9'd150, 12'h543, 1'b0);
                else if (obj_idx[5:0] == 6'd22 && (dk_active || sw[14] || sw[15])) obj_desc = obj_blend(11'sd0, 10'sd0, 10'd640, 9'd360, 12'h000, 4'd13);
                else if (obj_idx[5:0] >= 6'd23 && obj_idx[5:0] <= 6'd25 && dk_active) obj_desc = o_card;
            end else case (obj_idx[5:0])
                6'd0: obj_desc = o_bg;
                6'd1, 6'd2, 6'd3, 6'd4, 6'd5, 6'd6, 6'd7, 6'd8, 6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14, 6'd15, 6'd16, 6'd17, 6'd18:
                    if (skill_t != 0 && !zoom_on && !done_spots[mk]) obj_desc = o_mark;
                6'd19: if (!zoom_on) obj_desc = boss_first ? o_boss : o_player;
                6'd20: if (!zoom_on) obj_desc = boss_first ? o_player : (npc_vis ? o_boss : OBJ_NONE);
                6'd21: if (flash_t != 0) obj_desc = obj_blend(11'sd0, 10'sd0, 10'd640, 9'd360, 12'hF00, 4'd5);
                6'd22: if (dk_active || sw[14] || sw[15] || state == ST_OVER || state == ST_CLEAR)
                           obj_desc = obj_blend(11'sd0, 10'sd0, 10'd640, 9'd360, 12'h000, (state == ST_PLAY) ? 4'd12 : 4'd14);
                6'd23, 6'd24, 6'd25: if (dk_active && state == ST_PLAY) obj_desc = o_card;
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------- UI programs
    task push_prog; input [7:0] pid; begin prog_list = {prog_list[87:0], pid}; end endtask
    always @(*) begin
        prog_list = 96'd0;
        if (!on_board) begin push_prog(P_BAR_TOP); push_prog(P_BAR_BOTTOM); end
        if (state == ST_OVER) push_prog(P_S2_OVER);
        else if (state == ST_CLEAR) push_prog(P_S2_CLEAR);
        else begin
            if (on_board) push_prog(P_S2_BOARD);
            else if (mode_cu) begin
                push_prog(P_S2_CU_FRAME);
                push_prog((cur == 2'd0) ? P_S2_CU_WB : (cur == 2'd1) ? P_S2_CU_DOOR : P_S2_CU_BENCH);
            end
            if (!on_board) begin push_prog(P_HUD); push_prog(P_S2_HUD); end
            if (dk_active) push_prog(P_CARDS);
            else if (talk_on) push_prog(P_S2_TALK);
            else if (hint_on) push_prog(P_S2_HINTBOX);
            else if (sw[15]) push_prog(P_S2_INV);
            else if (sw[14]) push_prog(P_S2_NOTEBOOK);
            if (toast_t != 0 && toast != 0) push_prog(P_S2_TOAST);
        end
    end

    // ---------------------------------------------------------------- fields and conditions
    wire [13:0] rem_play = (play_t >= 14'd7200) ? 14'd0 : (14'd7259 - play_t);
    reg  [9:0]  skill_s;
    reg  [7:0]  wait_s_r, wait_m, wait_r;
    always @(posedge clk) begin
        if (rst) begin
            skill_s <= 10'd0; wait_s_r <= 8'd120; wait_m <= 8'd2; wait_r <= 8'd0;
        end else begin
            skill_s  <= ((skill_t + 10'd59) * 19'd8739) >> 19;
            wait_s_r <= (rem_play * 28'd8739) >> 19;
            wait_m   <= (wait_s_r >= 8'd120) ? 8'd2 : (wait_s_r >= 8'd60) ? 8'd1 : 8'd0;
            wait_r   <= (wait_s_r >= 8'd120) ? (wait_s_r - 8'd120) : (wait_s_r >= 8'd60) ? (wait_s_r - 8'd60) : wait_s_r;
        end
    end
    reg  [5:0] cnt_w;
    wire [5:0] nwires = cnt_w;
    always @(*) begin cnt_w = 6'd0; for (q = 0; q < 54; q = q + 1) if (w[q] != 0) cnt_w = cnt_w + 6'd1; end
    wire [5:0] pin = fld_id - F_S2_P00;
    wire [4:0] pin_src = w[pin];
    function [15:0] src_short; input [4:0] s;
        begin
            case (s)
                5'd0: src_short = "  ";
                5'd1: src_short = "+5";
                5'd2: src_short = "GN";
                5'd3: src_short = "C ";
                5'd4: src_short = "B ";
                5'd5: src_short = "A ";
                default: begin
                    if (s < 5'd9)       src_short = {"N", 8'h30 + (s - 5'd5)};
                    else if (s < 5'd13) src_short = {"A", 8'h30 + (s - 5'd8)};
                    else if (s < 5'd21) src_short = {"O", 8'h30 + (s - 5'd12)};
                    else                src_short = {"R", 8'h61 + (s - 5'd21)};
                end
            endcase
        end endfunction
    function [159:0] cba; input [2:0] k; cba = {8'h30 + k[2], 8'h30 + k[1], 8'h30 + k[0], 136'd0}; endfunction
    function [159:0] slash; input [7:0] a, b;                            // "a/b"
        reg [159:0] s; reg [11:0] ba; begin
            s = str_u8(a); ba = bcd8(a);
            if (a >= 10) s = s | ({8'h2F, 152'd0} >> 16) | (str_u8(b) >> 24);
            else s = s | ({8'h2F, 152'd0} >> 8) | (str_u8(b) >> 16);
            slash = s;
        end endfunction
    wire [3:0] kfi = (fld_id - F_S2_CHK0) >> 1;                         // F_S2_CHKn / F_S2_FOUNDn interleave
    wire [3:0] kok = (fld_id - F_S2_OK0) >> 1;
    reg [5:0]   slow_sec_r, freeze_sec_r;
    reg [159:0] slow_s_str, freeze_s_str;
    always @(posedge clk) begin
        slow_sec_r   <= secs_round({1'b0, slow_t});
        freeze_sec_r <= secs_round({1'b0, freeze_t});
        slow_s_str   <= str_u8(slow_sec_r);
        freeze_s_str <= str_u8(freeze_sec_r);
    end
    reg [159:0] fs;
    always @(*) begin
        fs = 160'd0; fld_val = 16'd0;
        if (fld_id >= F_S2_P00 && fld_id <= F_S2_P53) fs = {src_short(pin_src), 144'd0};
        else if (fld_id >= F_S2_CHK0 && fld_id <= F_S2_FOUND8) begin
            if (((fld_id - F_S2_CHK0) & 8'd1) == 0) fs = (found[kfi] >= s2_qty(kfi)) ? {"[x]", 136'd0} : {"[ ]", 136'd0};
            else fs = {"(", 152'd0} | (str_u8(found[kfi]) >> 8) | ({" found)", 104'd0} >> 16);
        end else if (fld_id >= F_S2_OK0 && fld_id <= F_S2_HAVE8) begin
            if (((fld_id - F_S2_OK0) & 8'd1) == 0) fs = (found[kok] >= s2_qty(kok)) ? {"[OK]", 128'd0} : {"[  ]", 128'd0};
            else fs = slash(found[kok], s2_qty(kok));
        end else if (fld_id >= F_S2_NOTE0 && fld_id <= F_S2_NOTE7)
            fld_val = ((fld_id - F_S2_NOTE0) < note_n) ? notes[note_wp - note_n + (fld_id - F_S2_NOTE0)] : 16'd0;
        else case (fld_id)
            F_BAR_TITLE: fld_val = T_BAR_TITLE_S2;
            F_BAR_HELP:  fld_val = T_BAR_HELP_S2;
            F_FORM:      fld_val = form;
            F_ARMOR_N:   fs = str_u8({6'd0, armor});
            F_SLOW_S:    begin fs = slow_s_str | ((slow_sec_r >= 10) ? {16'd0, "s", 136'd0} : {8'd0, "s", 144'd0}); end
            F_FREEZE_S:  begin fs = freeze_s_str | ((freeze_sec_r >= 10) ? {16'd0, "s", 136'd0} : {8'd0, "s", 144'd0}); end
            F_TOAST:     fld_val = toast;
            F_S2_TOAST_N: fs = {"(", 152'd0} | (slash(toast_cnt[5:3], toast_cnt[2:0]) >> 8) | ({")", 152'd0} >> 32);
            F_S2_PARTS:  fs = slash(parts, 8'd18);
            F_S2_QA:     fs = slash(rnd, 8'd3);
            F_S2_QA_OF:  fs = slash((rnd >= 2'd3) ? 8'd3 : rnd + 8'd1, 8'd3);
            F_S2_SKILL:  fld_val = (skill_t != 0) ? T_S2_SKILL_ON : skill_used ? T_S2_SKILL_USED : skill_ready ? T_S2_SKILL_READY : T_S2_SKILL_WAIT;
            F_S2_SKILL_T: if (skill_t != 0) fs = str_u8(skill_s[7:0]) | ((skill_s >= 10) ? {16'd0, "s", 136'd0} : {8'd0, "s", 144'd0});
                          else if (!skill_used && !skill_ready) fs = {8'h30 + wait_m[3:0], ":", 8'h30 + wait_r / 8'd10, 8'h30 + wait_r % 8'd10, 128'd0};
            F_S2_TALK:   fld_val = talk_l[talk_i];
            F_S2_HTITLE: fld_val = hint_ttl;
            F_S2_HINT:   fld_val = hint_txt;
            F_S2_HSINK:  fld_val = hint_sink;
            F_S2_HSRC:   fld_val = hint_src;
            F_S2_CMSG:   fld_val = cmsg;
            F_S2_CODE0:  fs = cba(code0);
            F_S2_CODE1:  fs = cba(code1);
            F_S2_CHAR0:  fs = {(code0 == 1) ? "C" : (code0 == 2) ? "P" : (code0 == 3) ? "E" : (code0 == 4) ? "-" : (code0 == 5) ? "3" : "9", 152'd0};
            F_S2_CHAR1:  fs = {(code1 == 1) ? "C" : (code1 == 2) ? "P" : (code1 == 3) ? "E" : (code1 == 4) ? "-" : (code1 == 5) ? "3" : "9", 152'd0};
            F_S2_TEST0, F_S2_TEST1, F_S2_TEST2: begin
                if (!pairs_ok) fs = 160'd0;
                else if ((fld_id - F_S2_TEST0) < rnd) fs = {"Test ", 8'h31 + (fld_id - F_S2_TEST0), ": passed", 48'd0};
                else fs = {"Test ", 8'h31 + (fld_id - F_S2_TEST0), ": not done yet"};
            end
            F_S2_WIRES:  fs = {"Wires ", 112'd0} | (slash(nwires, 8'd51) >> 48);
            F_S2_LIVE:   fs = cba(sw[2:0]);
            F_S2_SHOULD: fs = (sw[2:0] == 0 || sw[2:0] == 7) ? {"(never occurs)", 48'd0} :
                              {"should show ", (sw[2:0] == 1) ? "C" : (sw[2:0] == 2) ? "P" : (sw[2:0] == 3) ? "E" : (sw[2:0] == 4) ? "-" : (sw[2:0] == 5) ? "3" : "9", 56'd0};
            F_S2_PWRTXT: fs = {"D:", (w[S2_DIPVCC] == S2_SRC_1) ? "ok" : "--", " P",
                               8'h30 + (w[S2_PDC] == S2_SRC_0) + (w[S2_PDB] == S2_SRC_0) + (w[S2_PDA] == S2_SRC_0), "/3 C:",
                               (w[S2_SEGCOM] == S2_SRC_0) ? "ok" : "--", 48'd0};
            F_S2_ST_SINK: fld_val = cur_sink;
            F_S2_ST_SRC:  fld_val = cur_is_sink ? w[cur_sink] : cur_src;
            F_S2_MSEL:    fld_val = msel;
            F_S2_INVN0:   fs = {"x", 8'h30 + hh, 144'd0};
            F_S2_INVN1:   fs = {"x", 8'h30 + hs, 144'd0};
            F_S2_INVN2:   fs = {"x", 8'h30 + undo_n, 144'd0};
            F_S2_INVN3:   fs = {"x", 8'h30 + freeze_n, 144'd0};
            F_S2_SHARD:   fs = {8'h30 + shard, 152'd0};
            F_S2_BOOST:   fs = boost ? {"yes", 136'd0} : {"no", 144'd0};
            F_S2_SLOW:    fs = (slow_t != 0) ? (slow_s_str | ({" s left", 104'd0} >> ((slow_sec_r >= 10) ? 16 : 8)))
                                             : {"off", 136'd0};
            F_S2_CAREER:  fld_val = career;
            default: ;
        endcase
        fld_char = str_at(fs, fld_idx);
    end
    always @(*) begin
        cond_val = 1'b0;
        case (cond_id)
            C_HEART0: cond_val = hearts > 0;  C_HEART1: cond_val = hearts > 1;  C_HEART2: cond_val = hearts > 2;
            C_ARMOR:  cond_val = armor != 0;
            C_SLOW:   cond_val = slow_t != 0;
            C_FREEZE: cond_val = 1'b0;
            C_CARD_CUR0: cond_val = dk_active && !dk_face && dk_cur == 0;
            C_CARD_CUR1: cond_val = dk_active && !dk_face && dk_cur == 1;
            C_CARD_CUR2: cond_val = dk_active && !dk_face && dk_cur == 2;
            C_CARD_FACE: cond_val = dk_face;
            C_CARD_SKIP: cond_val = dk_active && dk_rnd == 2'd3;
            C_S2_COUNTERS: cond_val = 1'b1;
            C_S2_SKILLBTN: cond_val = intro_started && !mode_cu;
            C_S2_FREEZE_ON: cond_val = freeze_t != 0;
            C_S2_TOAST_CNT: cond_val = toast_c;
            C_S2_ASKLAST: cond_val = talk_ask && talk_i == talk_n;
            C_S2_HINT_WIRE: cond_val = hint_wire;
            C_S2_CMSG: cond_val = cmsg != 0;
            C_S2_PAGE0: cond_val = page == 2'd0;
            C_S2_PAGE1: cond_val = page == 2'd1;
            C_S2_PAGE2: cond_val = page == 2'd2;
            C_S2_QA_DONE: cond_val = qa_done;
            C_S2_NOCODES: cond_val = !qa_done && !codes_ok;
            C_S2_SHOWCODES: cond_val = !qa_done && codes_ok;
            C_S2_BENCH_READY: cond_val = !qa_done && parts == 5'd18;
            C_S2_BENCH_MISSING: cond_val = !qa_done && parts != 5'd18;
            C_S2_ST_CMSG: cond_val = cmsg != 0;
            C_S2_ST_DONE: cond_val = cmsg == 0 && qa_done;
            C_S2_ST_EDIT: cond_val = cmsg == 0 && !qa_done && wsrc_on;
            C_S2_ST_MSEL: cond_val = cmsg == 0 && !qa_done && !wsrc_on && msel != 0;
            C_S2_ST_UNDO: cond_val = cmsg == 0 && !qa_done && !wsrc_on && msel == 0 && wcur == S2_CUR_UNDO;
            C_S2_ST_SRC:  cond_val = cmsg == 0 && !qa_done && !wsrc_on && msel == 0 && !cur_is_sink && wcur < S2_CUR_CLEAR;
            C_S2_ST_SINK: cond_val = cmsg == 0 && !qa_done && !wsrc_on && msel == 0 && cur_is_sink;
            C_S2_ST_CLEAR: cond_val = cmsg == 0 && !qa_done && !wsrc_on && msel == 0 && wcur == S2_CUR_CLEAR;
            C_S2_INV0: cond_val = inv_cur == 2'd0;
            C_S2_INV1: cond_val = inv_cur == 2'd1;
            C_S2_INV2: cond_val = inv_cur == 2'd2;
            C_S2_INV3: cond_val = inv_cur == 2'd3;
            C_S2_HOT_UNDO:  cond_val = hot_undo;
            C_S2_HOT_CLEAR: cond_val = hot_clear;
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- 7-segment panel + LEDs (draw_panel)
    function [7:0] segchar; input [6:0] s;                                   // what the live output looks like
        case (s)
            7'b1001110: segchar = "C"; 7'b1100111: segchar = "P"; 7'b1001111: segchar = "E"; 7'b0000001: segchar = "-";
            7'b1111001: segchar = "3"; 7'b1111011: segchar = "9"; 7'b0000000: segchar = " "; default: segchar = "8";
        endcase
    endfunction
    always @(*) begin
        if (state == ST_CLEAR)      seg_text = {"H", 8'h30 + hearts, "  PA55"};
        else if (state == ST_OVER)  seg_text = {"H", 8'h30 + hearts, "  dEAd"};
        else if (wiring_live && !dk_active) seg_text = {"H", 8'h30 + hearts, " ", 8'h30 + sw[2], 8'h30 + sw[1], 8'h30 + sw[0], " ", segchar(seg_live)};
        else seg_text = {"H", 8'h30 + hearts, " P", 8'h30 + parts / 5'd10, 8'h30 + parts % 5'd10, " ", 8'h30 + rnd};
        leds = {seg_live, 1'b0, freeze_t != 0, skill_t != 0, qa_done, armor != 0, hearts > 2, hearts > 1, hearts > 0};
    end
endmodule

// Stack-based net evaluator (from circuit.txt)
module bb_circuit_eval (
    input  wire         clk,
    input  wire         start,
    input  wire [4:0]   node,
    input  wire         lc, lb, la,
    input  wire [269:0] w,
    output reg          done,
    output reg          val
);
    function [4:0] ws(input [5:0] i);
        ws = w[5 * i +: 5];
    endfunction

    function [5:0] gate_in_a(input [3:0] g);
        gate_in_a = (g <= 4'd2) ? (6'd13 + g) : (6'd16 + ((g - 4'd3) << 1));
    endfunction

    function [5:0] gate_in_b(input [3:0] g);
        gate_in_b = 6'd17 + ((g - 4'd3) << 1);
    endfunction

    reg  [4:0]  sn  [0:23];
    reg         sph [0:23];
    reg  [4:0]  sp;
    reg  [27:0] seen;
    reg  [4:0]  cn;
    reg         rv;
    reg  [1:0]  st;
    reg  [12:0] steps;

    wire [3:0] g     = cn - 5'd6;
    wire       u_ok  = (g <= 4'd2)  ? (ws(6'd0) == 5'd1 && ws(6'd1) == 5'd2) :
                       (g <= 4'd6)  ? (ws(6'd2) == 5'd1 && ws(6'd3) == 5'd2) :
                       (g <= 4'd10) ? (ws(6'd4) == 5'd1 && ws(6'd5) == 5'd2) :
                                      (ws(6'd6) == 5'd1 && ws(6'd7) == 5'd2);
    wire [4:0] in_a  = ws(gate_in_a(g));
    wire [4:0] in_b  = ws(gate_in_b(g));
    wire       two   = (g >= 4'd3);
    wire [4:0] r_in  = ws(6'd40 + (cn - 5'd21));

    wire [4:0] tn    = sn[sp - 5'd1];
    wire       tph   = sph[sp - 5'd1];
    wire [3:0] tg    = tn - 5'd6;
    wire [4:0] tin_b = ws(gate_in_b(tg));

    always @(posedge clk) begin
        done <= 1'b0;
        if (start) begin
            sp <= 5'd0; seen <= 28'd0; cn <= node; st <= 2'd1; steps <= 13'd0;
        end else if (st != 2'd0) begin
            steps <= steps + 13'd1;
            if (steps == 13'h1FFF) begin
                st <= 2'd0; done <= 1'b1; val <= 1'b0;
            end else if (st == 2'd1) begin
                if (cn == 5'd1)                    begin rv <= 1'b1; st <= 2'd2; end
                else if (cn == 5'd2 || cn == 5'd0) begin rv <= 1'b0; st <= 2'd2; end
                else if (cn == 5'd3)               begin rv <= lc;   st <= 2'd2; end
                else if (cn == 5'd4)               begin rv <= lb;   st <= 2'd2; end
                else if (cn == 5'd5)               begin rv <= la;   st <= 2'd2; end
                else if (seen[cn])                 begin rv <= 1'b0; st <= 2'd2; end
                else if (cn >= 5'd21) begin
                    if (r_in == 5'd0) begin rv <= 1'b0; st <= 2'd2; end
                    else begin
                        sn[sp] <= cn; sph[sp] <= 1'b0; sp <= sp + 5'd1;
                        seen[cn] <= 1'b1; cn <= r_in;
                    end
                end else begin
                    if (!u_ok || in_a == 5'd0 || (two && in_b == 5'd0)) begin
                        rv <= 1'b0; st <= 2'd2;
                    end else begin
                        sn[sp] <= cn; sph[sp] <= 1'b0; sp <= sp + 5'd1;
                        seen[cn] <= 1'b1; cn <= in_a;
                    end
                end
            end else begin
                if (sp == 5'd0) begin
                    st <= 2'd0; done <= 1'b1; val <= rv;
                end else if (tn >= 5'd21) begin
                    sp <= sp - 5'd1; seen[tn] <= 1'b0;
                end else if (tn <= 5'd8) begin
                    sp <= sp - 5'd1; seen[tn] <= 1'b0; rv <= !rv;
                end else if (!tph && (tn <= 5'd12 ? !rv : rv)) begin
                    sp <= sp - 5'd1; seen[tn] <= 1'b0;
                end else if (!tph) begin
                    sph[sp - 5'd1] <= 1'b1; cn <= tin_b; st <= 2'd1;
                end else begin
                    sp <= sp - 5'd1; seen[tn] <= 1'b0;
                end
            end
        end
    end
    initial st = 2'd0;
endmodule
