// game_flow.v - scene sequencer, hand-off between stages, and runtime SW[12] Demo Tool
// (demo_hub.py REGISTRY order: 0 Open -> 1 Stage 1 -> 2 Cutscene 1-2 -> 3 Stage 2 ->
// 4 Cutscene 2-3 -> 5 Stage 3 -> 6 Ending -> 0).
`timescale 1ns / 1ps
module game_flow (
    input  wire         clk,
    input  wire         rst,
    input  wire         frame,
    input  wire [4:0]   lvl,
    input  wire [4:0]   ev_press,
    input  wire         ev_tap,
    input  wire         ev_back,
    input  wire [15:0]  sw,
    input  wire [15:0]  sw_rise,
    input  wire [15:0]  sw_fall,
    input  wire [15:0]  sw_now,
    // video
    input  wire [7:0]   obj_idx,
    output reg  [127:0] obj_desc,
    output reg          vmap_en,
    output reg  [95:0]  prog_list,
    input  wire [7:0]   fld_id,
    input  wire [6:0]   fld_idx,
    output reg  [7:0]   fld_char,
    output reg  [15:0]  fld_val,
    input  wire [7:0]   cond_id,
    output reg          cond_val,
    output reg  [63:0]  seg_text,
    output reg  [15:0]  leds,
    output wire [2:0]   rgb16,            // career colour
    output wire [2:0]   rgb17,            // form colour
    output reg  [2:0]   scene
);
`include "ui_ids.vh"
    localparam SC_OPEN = 3'd0, SC_S1 = 3'd1, SC_C12 = 3'd2, SC_S2 = 3'd3, SC_C23 = 3'd4, SC_S3 = 3'd5, SC_END = 3'd6;
    localparam B_U = 0, B_D = 1, B_L = 2, B_R = 3;

    // ---------------- hand-off record ----------------
    reg [1:0] h_hearts, h_armor, h_form, h_career;
    reg       h_shard, h_boost;
    reg [7:0] h_backs;  reg [2:0] h_nbacks;

    // ---------------- scene start & SW[12] Demo Tool ----------------
    reg        start_p;                      // 1-cycle start pulse for the current scene
    reg        boot;                         // 0: startup -> wait 1 frame settle, 1: running
    wire       story_done, done_s1, done_s2, done_s3;
    reg        demo_open;
    always @(posedge clk) demo_open <= rst ? 1'b0 : sw[12];
    reg  [2:0] d_row, d_stg, d_ckpt, d_note;
    reg  [3:0] d_act;
    reg  [1:0] d_hearts, d_form;
    reg        d_flow;
    reg        d_s1_jump, d_s1_armor, d_s1_wrong; reg [2:0] d_s1_key;
    reg        d_s2_jump, d_s2_act;               reg [2:0] d_s2_key, d_s2_act_key;
    reg        d_s3_win, d_s3_jump, d_s3_part, d_s3_setf;
    reg        d_st_end, d_st_step, d_st_step_val; reg [3:0] d_st_end_num;
    reg        d_seth, d_setf;

    // Stage 1 / 2 outputs
    wire [1:0] s1_hearts, s1_armor, s1_form, s1_career; wire s1_shard, s1_boost; wire [3:0] s1_backs;
    wire [1:0] s2_hearts, s2_armor, s2_form, s2_career; wire s2_shard, s2_boost; wire [7:0] s2_backs; wire [2:0] s2_nb;

    wire [1:0] cur_hearts = (scene == SC_S1) ? s1_hearts : (scene == SC_S2) ? s2_hearts : h_hearts;
    wire [1:0] cur_form   = (scene == SC_S1) ? s1_form   : (scene == SC_S2) ? s2_form   : h_form;

    wire [2:0] ckpt_max = (scene == SC_S1 || scene == SC_S2) ? 3'd4 : (scene == SC_S3 || scene == SC_END) ? 3'd1 : 3'd0;
    wire [3:0] act_max  = (scene == SC_S1) ? 4'd1 : (scene == SC_S2) ? 4'd4 : (scene == SC_S3) ? 4'd0 : (scene == SC_END) ? 4'd8 : 4'd0;

    task set_scene_handoff; input [2:0] sc; begin
        h_hearts <= 2'd3; h_armor <= 2'd0; h_shard <= 1'b0; h_boost <= 1'b0; h_career <= 2'd0;
        case (sc)
            SC_C12, SC_S2:         begin h_form <= 2'd1; h_backs <= 8'd0;          h_nbacks <= 3'd2; end
            SC_C23, SC_S3, SC_END: begin h_form <= 2'd2; h_backs <= 8'b01_10_00_01; h_nbacks <= 3'd3; end
            default:               begin h_form <= 2'd0; h_backs <= 8'd0;          h_nbacks <= 3'd0; end
        endcase
    end endtask

    always @(posedge clk) begin
        start_p <= 1'b0;
        d_s1_jump <= 1'b0; d_s1_armor <= 1'b0; d_s1_wrong <= 1'b0;
        d_s2_jump <= 1'b0; d_s2_act   <= 1'b0;
        d_s3_win  <= 1'b0; d_s3_jump  <= 1'b0; d_s3_setf  <= 1'b0;
        d_st_end  <= 1'b0; d_st_step  <= 1'b0;
        d_seth    <= 1'b0; d_setf     <= 1'b0;
        if (rst) begin
            scene <= SC_OPEN; boot <= 1'b0;
            h_hearts <= 2'd3; h_armor <= 2'd0; h_form <= 2'd0; h_career <= 2'd0; h_shard <= 1'b0; h_boost <= 1'b0;
            h_backs <= 8'd0; h_nbacks <= 3'd0;
            d_row <= 3'd0; d_stg <= SC_OPEN; d_ckpt <= 3'd0; d_act <= 4'd0; d_hearts <= 2'd3; d_form <= 2'd0; d_flow <= 1'b0; d_note <= 3'd0;
            d_s1_key <= 3'd0; d_s2_key <= 3'd0; d_s2_act_key <= 3'd0; d_s3_part <= 1'b0; d_st_end_num <= 4'd5; d_st_step_val <= 1'b0;
        end else if (!boot) begin
            boot <= 1'b1;
            scene <= SC_OPEN;
            set_scene_handoff(SC_OPEN);
            start_p <= 1'b1;
        end else begin
            // Sync Demo Tool defaults when opened
            if (frame && sw_rise[12]) begin
                d_row <= 3'd0; d_stg <= scene; d_ckpt <= 3'd0; d_act <= 4'd0;
                d_hearts <= (cur_hearts == 2'd0) ? 2'd1 : cur_hearts;
                d_form <= cur_form;
                d_note <= T_DEMO_NOTE_NONE[2:0];
            end

            if (demo_open && frame) begin
                if (ev_press[B_U]) d_row <= (d_row == 3'd0) ? 3'd5 : d_row - 3'd1;
                else if (ev_press[B_D]) d_row <= (d_row == 3'd5) ? 3'd0 : d_row + 3'd1;
                else if (ev_press[B_L]) begin
                    case (d_row)
                        3'd0: d_stg    <= (d_stg == 3'd0) ? 3'd6 : d_stg - 3'd1;
                        3'd1: d_ckpt   <= (d_ckpt == 3'd0) ? ckpt_max : d_ckpt - 3'd1;
                        3'd2: d_act    <= (d_act == 4'd0) ? act_max : d_act - 4'd1;
                        3'd3: d_hearts <= (d_hearts <= 2'd1) ? 2'd3 : d_hearts - 2'd1;
                        3'd4: d_form   <= d_form - 2'd1;
                        default: d_flow <= !d_flow;
                    endcase
                end else if (ev_press[B_R]) begin
                    case (d_row)
                        3'd0: d_stg    <= (d_stg == 3'd6) ? 3'd0 : d_stg + 3'd1;
                        3'd1: d_ckpt   <= (d_ckpt >= ckpt_max) ? 3'd0 : d_ckpt + 3'd1;
                        3'd2: d_act    <= (d_act >= act_max) ? 4'd0 : d_act + 4'd1;
                        3'd3: d_hearts <= (d_hearts >= 2'd3) ? 2'd1 : d_hearts + 2'd1;
                        3'd4: d_form   <= d_form + 2'd1;
                        default: d_flow <= !d_flow;
                    endcase
                end else if (ev_tap) begin
                    case (d_row)
                        3'd0: begin
                            scene <= d_stg; start_p <= 1'b1; set_scene_handoff(d_stg);
                            d_ckpt <= 3'd0; d_act <= 4'd0; d_note <= T_DEMO_NOTE_STG[2:0];
                        end
                        3'd1: begin
                            if (scene == SC_S1)       begin d_s1_jump <= 1'b1; d_s1_key <= d_ckpt; d_note <= T_DEMO_NOTE_DONE[2:0]; end
                            else if (scene == SC_S2)  begin d_s2_jump <= 1'b1; d_s2_key <= d_ckpt; d_note <= T_DEMO_NOTE_DONE[2:0]; end
                            else if (scene == SC_S3)  begin d_s3_jump <= 1'b1; d_s3_part <= d_ckpt[0]; d_note <= T_DEMO_NOTE_DONE[2:0]; end
                            else if (scene == SC_END) begin d_st_step <= 1'b1; d_st_step_val <= d_ckpt[0]; d_note <= T_DEMO_NOTE_DONE[2:0]; end
                            else d_note <= T_DEMO_NOTE_NOCKPT[2:0];
                        end
                        3'd2: begin
                            if (scene == SC_S1) begin
                                if (d_act == 4'd0) d_s1_wrong <= 1'b1; else d_s1_armor <= 1'b1;
                                d_note <= T_DEMO_NOTE_DONE[2:0];
                            end else if (scene == SC_S2) begin
                                d_s2_act <= 1'b1; d_s2_act_key <= d_act[2:0]; d_note <= T_DEMO_NOTE_DONE[2:0];
                            end else if (scene == SC_S3) begin
                                d_s3_win <= 1'b1; d_note <= T_DEMO_NOTE_DONE[2:0];
                            end else if (scene == SC_END) begin
                                d_st_end <= 1'b1; d_st_end_num <= d_act + 4'd1; d_note <= T_DEMO_NOTE_DONE[2:0];
                            end else d_note <= T_DEMO_NOTE_NOACT[2:0];
                        end
                        3'd3: begin
                            h_hearts <= d_hearts; d_seth <= 1'b1; d_note <= T_DEMO_NOTE_DONE[2:0];
                        end
                        3'd4: begin
                            h_form <= d_form; d_setf <= 1'b1; d_s3_setf <= 1'b1; d_note <= T_DEMO_NOTE_DONE[2:0];
                        end
                        default: begin
                            if (!d_flow) begin
                                start_p <= 1'b1; d_note <= T_DEMO_NOTE_DONE[2:0];
                            end else begin
                                d_ckpt <= 3'd0; d_act <= 4'd0; d_note <= T_DEMO_NOTE_STG[2:0];
                                case (scene)
                                    SC_OPEN: begin scene <= SC_S1; d_stg <= SC_S1; start_p <= 1'b1; h_form <= 2'd0; end
                                    SC_S1: begin
                                        h_hearts <= s1_hearts; h_armor <= s1_armor; h_form <= (s1_form == 2'd0) ? 2'd1 : s1_form;
                                        h_career <= s1_career; h_shard <= s1_shard; h_boost <= s1_boost;
                                        h_backs <= {4'd0, s1_backs}; h_nbacks <= 3'd2;
                                        scene <= SC_C12; d_stg <= SC_C12; start_p <= 1'b1;
                                    end
                                    SC_C12: begin if (h_form == 2'd0) h_form <= 2'd1; scene <= SC_S2; d_stg <= SC_S2; start_p <= 1'b1; end
                                    SC_S2: begin
                                        h_hearts <= s2_hearts; h_armor <= s2_armor; h_form <= 2'd2; h_career <= s2_career;
                                        h_shard <= s2_shard; h_boost <= s2_boost; h_backs <= s2_backs; h_nbacks <= s2_nb;
                                        scene <= SC_C23; d_stg <= SC_C23; start_p <= 1'b1;
                                    end
                                    SC_C23: begin scene <= SC_S3; d_stg <= SC_S3; start_p <= 1'b1; end
                                    SC_S3:  begin scene <= SC_END; d_stg <= SC_END; start_p <= 1'b1; end
                                    default: begin
                                        scene <= SC_OPEN; d_stg <= SC_OPEN; start_p <= 1'b1;
                                        set_scene_handoff(SC_OPEN);
                                    end
                                endcase
                            end
                        end
                    endcase
                end
            end

            if (!demo_open) begin
                case (scene)
                    SC_OPEN: if (story_done) begin scene <= SC_S1; start_p <= 1'b1; h_form <= 2'd0; end
                    SC_S1: if (done_s1) begin
                        h_hearts <= s1_hearts; h_armor <= s1_armor; h_form <= s1_form; h_career <= s1_career;
                        h_shard <= s1_shard; h_boost <= s1_boost; h_backs <= {4'd0, s1_backs}; h_nbacks <= 3'd2;
                        scene <= SC_C12; start_p <= 1'b1;
                    end
                    SC_C12: if (story_done) begin
                        if (h_form == 2'd0) h_form <= 2'd1;             // cutscene: form = max(1, form)
                        scene <= SC_S2; start_p <= 1'b1;
                    end
                    SC_S2: if (done_s2) begin
                        h_hearts <= s2_hearts; h_armor <= s2_armor; h_form <= s2_form; h_career <= s2_career;
                        h_shard <= s2_shard; h_boost <= s2_boost; h_backs <= s2_backs; h_nbacks <= s2_nb;
                        scene <= SC_C23; start_p <= 1'b1;
                    end
                    SC_C23: if (story_done) begin scene <= SC_S3; start_p <= 1'b1; end
                    SC_S3:  if (done_s3) begin scene <= SC_END; start_p <= 1'b1; end
                    default: if (story_done) begin                       // Play Again -> Open, fresh hand-off
                        scene <= SC_OPEN; start_p <= 1'b1; set_scene_handoff(SC_OPEN);
                    end
                endcase
            end
        end
    end

    // Suppress gameplay button/switch inputs while Demo Tool overlay is open
    wire [4:0]  lvl_g  = demo_open ? 5'd0  : lvl;
    wire [4:0]  evp_g  = demo_open ? 5'd0  : ev_press;
    wire        evt_g  = demo_open ? 1'b0  : ev_tap;
    wire        evb_g  = demo_open ? 1'b0  : ev_back;
    wire [15:0] swr_g  = demo_open ? 16'd0 : sw_rise;
    wire [15:0] swf_g  = demo_open ? 16'd0 : sw_fall;

    wire is_story = (scene == SC_OPEN) || (scene == SC_C12) || (scene == SC_C23) || (scene == SC_END);
    wire [7:0] oi_story = obj_idx, oi_s1 = obj_idx, oi_s2 = obj_idx, oi_s3 = obj_idx;
    wire [7:0] fi_story = fld_id,  fi_s1 = fld_id,  fi_s2 = fld_id,  fi_s3 = fld_id;
    wire [7:0] ci_story = cond_id, ci_s1 = cond_id, ci_s2 = cond_id, ci_s3 = cond_id;

    // ---------------- scene modules ----------------
    wire [127:0] d_story, d_s1, d_s2, d_s3;
    wire [95:0]  p_story, p_s1, p_s2, p_s3;
    wire [7:0]   c_story, c_s1, c_s2, c_s3;
    wire [15:0]  v_story, v_s1, v_s2, v_s3;
    wire         k_story, k_s1, k_s2, k_s3;
    wire [63:0]  t_story, t_s1, t_s2, t_s3;
    wire [15:0]  l_s1, l_s2, l_s3;
    wire         vm_s3;

    story u_story (.clk(clk), .rst(rst), .active(is_story), .start(start_p && is_story), .scene(scene), .frame(frame),
        .ev_press(evp_g), .ev_tap(evt_g), .ev_back(evb_g),
        .hearts(h_hearts), .form(h_form), .career(h_career), .backs(h_backs), .n_backs(h_nbacks),
        .dbg_end(d_st_end), .dbg_end_num(d_st_end_num),
        .dbg_end_step(d_st_step), .dbg_end_step_val(d_st_step_val), .done(story_done),
        .obj_idx(oi_story), .obj_desc(d_story), .prog_list(p_story), .fld_id(fi_story), .fld_idx(fld_idx),
        .fld_char(c_story), .fld_val(v_story), .cond_id(ci_story), .cond_val(k_story), .seg_text(t_story));

    stage1 u_s1 (.clk(clk), .rst(rst), .active(scene == SC_S1), .start(start_p && scene == SC_S1), .frame(frame),
        .lvl(lvl_g), .ev_press(evp_g), .ev_tap(evt_g), .ev_back(evb_g), .sw(sw), .sw_rise(swr_g), .sw_fall(swf_g),
        .dbg_jump(d_s1_jump), .dbg_key(d_s1_key), .dbg_armor(d_s1_armor), .dbg_door_wrong(d_s1_wrong),
        .dbg_set_hearts(d_seth && scene == SC_S1), .dbg_hearts(d_hearts), .dbg_set_form(d_setf && scene == SC_S1), .dbg_form(d_form),
        .done(done_s1), .ho_hearts(s1_hearts), .ho_armor(s1_armor), .ho_shard(s1_shard), .ho_boost(s1_boost),
        .ho_form(s1_form), .ho_career(s1_career), .ho_backs(s1_backs),
        .obj_idx(oi_s1), .obj_desc(d_s1), .prog_list(p_s1), .fld_id(fi_s1), .fld_idx(fld_idx),
        .fld_char(c_s1), .fld_val(v_s1), .cond_id(ci_s1), .cond_val(k_s1), .seg_text(t_s1), .leds(l_s1));

    stage2 u_s2 (.clk(clk), .rst(rst), .active(scene == SC_S2), .start(start_p && scene == SC_S2), .frame(frame),
        .lvl(lvl_g), .ev_press(evp_g), .ev_tap(evt_g), .ev_back(evb_g), .sw(sw), .sw_rise(swr_g), .sw_fall(swf_g),
        .hi_hearts(h_hearts), .hi_armor(h_armor), .hi_shard(h_shard), .hi_boost(h_boost), .hi_form(h_form),
        .hi_career(h_career), .hi_backs(h_backs), .hi_nbacks(h_nbacks),
        .dbg_jump(d_s2_jump), .dbg_key(d_s2_key), .dbg_act(d_s2_act), .dbg_act_key(d_s2_act_key),
        .dbg_set_hearts(d_seth && scene == SC_S2), .dbg_hearts(d_hearts), .dbg_set_form(d_setf && scene == SC_S2), .dbg_form(d_form),
        .done(done_s2), .ho_hearts(s2_hearts), .ho_armor(s2_armor), .ho_shard(s2_shard), .ho_boost(s2_boost),
        .ho_form(s2_form), .ho_career(s2_career), .ho_backs(s2_backs), .ho_nbacks(s2_nb),
        .obj_idx(oi_s2), .obj_desc(d_s2), .prog_list(p_s2), .fld_id(fi_s2), .fld_idx(fld_idx),
        .fld_char(c_s2), .fld_val(v_s2), .cond_id(ci_s2), .cond_val(k_s2), .seg_text(t_s2), .leds(l_s2));

    stage3 u_s3 (.clk(clk), .rst(rst), .active(scene == SC_S3), .start(start_p && scene == SC_S3), .frame(frame),
        .lvl(lvl_g), .ev_press(evp_g), .ev_tap(evt_g), .ev_back(evb_g), .hi_hearts(h_hearts), .hi_form(h_form),
        .dbg_win(d_s3_win), .dbg_jump(d_s3_jump), .dbg_part(d_s3_part), .dbg_set_form(d_s3_setf), .dbg_form(d_form),
        .done(done_s3), .obj_idx(oi_s3), .obj_desc(d_s3), .vmap_en(vm_s3), .prog_list(p_s3), .fld_id(fi_s3),
        .fld_idx(fld_idx), .fld_char(c_s3), .fld_val(v_s3), .cond_id(ci_s3), .cond_val(k_s3), .seg_text(t_s3), .leds(l_s3));

    reg [127:0] od_comb;
    reg [95:0]  base_pl;
    reg [7:0]   base_fc, fc_comb;
    reg [15:0]  base_fv, fv_comb;
    reg         base_cv, cv_comb;
    always @(*) begin
        case (scene)
            SC_S1: begin od_comb = d_s1; base_pl = p_s1; base_fc = c_s1; base_fv = v_s1; base_cv = k_s1; seg_text = t_s1; leds = l_s1; vmap_en = 1'b0; end
            SC_S2: begin od_comb = d_s2; base_pl = p_s2; base_fc = c_s2; base_fv = v_s2; base_cv = k_s2; seg_text = t_s2; leds = l_s2; vmap_en = 1'b0; end
            SC_S3: begin od_comb = d_s3; base_pl = p_s3; base_fc = c_s3; base_fv = v_s3; base_cv = k_s3; seg_text = t_s3; leds = l_s3; vmap_en = vm_s3; end
            default: begin
                od_comb = d_story; base_pl = p_story; base_fc = c_story; base_fv = v_story; base_cv = k_story;
                seg_text = t_story; leds = {13'd0, h_hearts > 2, h_hearts > 1, h_hearts > 0}; vmap_en = 1'b0;
            end
        endcase
        prog_list = demo_open ? {P_DEMO_MENU, base_pl[87:0]} : base_pl;

        fc_comb = base_fc;
        fv_comb = base_fv;
        if (demo_open) begin
            case (fld_id)
                F_DEMO_CUR_STG: fv_comb = {13'd0, scene};
                F_DEMO_CUR_H:   fc_comb = (fld_idx == 7'd0) ? (8'h30 + {6'd0, cur_hearts}) : 8'd0;
                F_DEMO_CUR_F:   fv_comb = {14'd0, cur_form};
                F_DEMO_STG:     fv_comb = {13'd0, d_stg};
                F_DEMO_CKPT:    fv_comb = (scene == SC_S1) ? (T_DEMO_CKPT_S1_0 + d_ckpt) :
                                          (scene == SC_S2) ? (T_DEMO_CKPT_S2_0 + d_ckpt) :
                                          (scene == SC_S3) ? (T_DEMO_CKPT_S3_0 + d_ckpt) :
                                          (scene == SC_END) ? (T_DEMO_CKPT_E_0 + d_ckpt) : T_DEMO_CKPT_NONE;
                F_DEMO_ACT:     fv_comb = (scene == SC_S1) ? (T_DEMO_ACT_S1_0 + d_act) :
                                          (scene == SC_S2) ? (T_DEMO_ACT_S2_0 + d_act) :
                                          (scene == SC_S3) ? T_DEMO_ACT_S3_0 :
                                          (scene == SC_END) ? (T_DEMO_ACT_E1 + d_act) : T_DEMO_ACT_NONE;
                F_DEMO_H:       fc_comb = (fld_idx == 7'd0) ? (8'h30 + {6'd0, d_hearts}) :
                                          (fld_idx == 7'd1) ? " " : (fld_idx == 7'd2) ? "H" :
                                          (fld_idx == 7'd3) ? "e" : (fld_idx == 7'd4) ? "a" :
                                          (fld_idx == 7'd5) ? "r" : (fld_idx == 7'd6) ? "t" :
                                          (fld_idx == 7'd7) ? ((d_hearts == 2'd1) ? 8'd0 : "s") : 8'd0;
                F_DEMO_F:       fv_comb = {14'd0, d_form};
                F_DEMO_FL:      fv_comb = d_flow ? T_DEMO_FL_SKIP : T_DEMO_FL_RESTART;
                F_DEMO_NOTE:    fv_comb = {13'd0, d_note};
                default: ;
            endcase
        end

        cv_comb = base_cv;
        if (demo_open) begin
            case (cond_id)
                C_DEMO_R0: cv_comb = (d_row == 3'd0);
                C_DEMO_R1: cv_comb = (d_row == 3'd1);
                C_DEMO_R2: cv_comb = (d_row == 3'd2);
                C_DEMO_R3: cv_comb = (d_row == 3'd3);
                C_DEMO_R4: cv_comb = (d_row == 3'd4);
                C_DEMO_R5: cv_comb = (d_row == 3'd5);
                default: ;
            endcase
        end
    end
    always @(posedge clk) begin
        if (rst) begin obj_desc <= 128'd0; fld_char <= 8'd0; fld_val <= 16'd0; cond_val <= 1'b0; end
        else begin obj_desc <= od_comb; fld_char <= fc_comb; fld_val <= fv_comb; cond_val <= cv_comb; end
    end

    // RGB LEDs at 1/8 brightness: LED16 = career colour (green / yellow / red), LED17 = form
    reg [2:0] pwm; always @(posedge clk) pwm <= pwm + 3'd1;
    wire dim = (pwm == 3'd0);
    wire [1:0] car_now = (scene == SC_S1) ? s1_career : (scene == SC_S2) ? s2_career : h_career;
    assign rgb16 = (!dim || scene == SC_OPEN) ? 3'b000 :
                   (car_now == 2'd0) ? 3'b010 : (car_now == 2'd1) ? 3'b110 : 3'b100;
    assign rgb17 = !dim ? 3'b000 : (cur_form == 2'd0) ? 3'b001 : (cur_form == 2'd1) ? 3'b111 : (cur_form == 2'd2) ? 3'b101 : 3'b110;
endmodule
