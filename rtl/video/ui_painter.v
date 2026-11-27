// ui_painter.v - repaints the 80x60 text layer once per frame (during vertical blank).
//
// It is a tiny command processor. The commands (tools/ui_compiler.py, format in
// tools/uilib.py) say things like "box at col 12 row 8, 20x5, colour 3" or "write string
// #57 centred at row 20" or "write the value of field F_S1_P1VAL here". Values that change
// during play (digits, switch states, which message to show ...) come from the active
// stage through three small ports:
//     fld_id/fld_idx -> fld_char : i-th character of a field (0 = end)
//     fld_id         -> fld_val  : numeric value of a field (string selection, origin)
//     cond_id        -> cond_val : 1-bit condition (SKIPZ / SKIPNZ)
// The stage computes these combinationally from registers, so they are valid one clock
// after fld_id / fld_idx / cond_id change.
// prog_list holds up to 12 program ids (0 = none), run in order (later ones draw on top).
// Text cell = {glyph[6:0], fg[4:0], bg[4:0], big, qx, qy} (20 bits). bg 0 = transparent.
// Worst case a frame needs ~40k clocks; vertical blank lasts 144k clocks.
`timescale 1ns / 1ps
module ui_painter (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,            // frame_tick
    input  wire [95:0] prog_list,        // 12 x 8-bit program ids, [7:0] runs first
    output reg  [7:0]  fld_id,
    output reg  [6:0]  fld_idx,
    input  wire [7:0]  fld_char,
    input  wire [15:0] fld_val,
    output reg  [7:0]  cond_id,
    input  wire        cond_val,
    output reg  [12:0] t_addr,
    output reg         t_we,
    output reg  [19:0] t_wdata,
    input  wire [19:0] t_rdata,          // 1-cycle latency
    output wire        busy
);
    // ---------------- program / string ROMs (1-cycle latency) ----------------
    (* rom_style = "block" *) reg [31:0] prog [0:4095];
    (* rom_style = "block" *) reg [7:0]  strs [0:32767];
    initial $readmemh("ui_prog.mem", prog);
    initial $readmemh("ui_str.mem", strs);
    reg [11:0] p_addr;  reg [31:0] p_q;
    reg [14:0] s_addr;  reg [7:0]  s_q;
    always @(posedge clk) begin
        p_q <= prog[p_addr];
        s_q <= strs[s_addr];
    end

    localparam BG_KEEP = 5'd31;
    localparam OP_END = 4'd0, OP_RECT = 4'd1, OP_TEXT = 4'd2, OP_FIELD = 4'd3, OP_SKIPZ = 4'd4,
               OP_SKIPNZ = 4'd5, OP_ORG = 4'd6, OP_STRSEL = 4'd7, OP_CHAR = 4'd8, OP_SETCUR = 4'd9;

    localparam [5:0]
               S_IDLE = 6'd0,  S_CLEAR = 6'd1,  S_NEXTP = 6'd2,  S_PTAB = 6'd3,   S_PTABW = 6'd4,
               S_FETCH = 6'd5, S_FW1 = 6'd6,    S_FW2 = 6'd7,    S_W1A = 6'd8,    S_W1B = 6'd9,
               S_COND = 6'd10, S_ORG1 = 6'd11,  S_ORG2 = 6'd12,  S_SEL1 = 6'd13,  S_SEL2 = 6'd14,
               S_SEL3 = 6'd15, S_LINE = 6'd16,  S_MREQ = 6'd17,  S_MGOT = 6'd18,  S_DREQ = 6'd19,
               S_DGOT = 6'd20, S_CELL = 6'd21,  S_CELLW = 6'd22, S_CELLWR = 6'd23, S_RECT = 6'd24,
               S_SEL0 = 6'd25, S_MWAIT = 6'd26, S_DWAIT = 6'd27,
               S_CONDW = 6'd28, S_ORG0 = 6'd29, S_ORG1W = 6'd30, S_SEL0B = 6'd31, S_MWAIT2 = 6'd32, S_DWAIT2 = 6'd33;
    reg [5:0]  st, cell_ret;
    reg [3:0]  k;
    reg [95:0] plist;
    reg [11:0] pc;
    reg [31:0] w0, w1;
    reg signed [8:0] org_x, org_y;
    reg [5:0]  cur;

    wire [3:0] op     = w0[31:28];
    wire [4:0] w_fg   = w0[14:10];
    wire       w_big  = w0[9];
    wire       w_cent = w0[8];
    wire       w_flow = w0[7];
    wire [3:0] w_step = w0[9] ? {1'b0, w0[6:5], 1'b0} + 4'd2 : {2'b0, w0[6:5]} + 4'd1;  // rows per line
    wire [4:0] w_bg   = w0[4:0];

    // character source: 0 = string ROM, 1 = field, 2 = repeated glyph
    reg [1:0]  src;
    reg [14:0] sp, sp_line;
    reg [6:0]  fi, fi_line;
    reg [6:0]  rep_n, rep_line;
    reg [6:0]  maxlen;
    reg [7:0]  len;
    reg signed [8:0] c, r, c0;
    reg        any_char;
    // pending cell write
    reg [6:0]  wglyph;
    reg [4:0]  wfg, wbg;
    reg        wbig;
    reg [1:0]  quad;
    reg signed [8:0] wc, wr;
    // RECT
    reg signed [8:0] rc, rr, rc0, rr0, rc_end, rr_end;
    reg        rect_border, rect_dither;
    reg [12:0] clr;

    assign busy = (st != S_IDLE);

    wire [7:0] got_char = (src == 2'd0) ? s_q :
                          (src == 2'd1) ? ((fi >= maxlen) ? 8'd0 : fld_char) :
                          ((rep_n == 7'd0) ? 8'd0 : w1[7:0]);

    wire rt = (rr == rr0), rb = (rr == rr_end - 9'sd1), rl = (rc == rc0), rg = (rc == rc_end - 9'sd1);
    wire [6:0] rect_glyph = !rect_border ? (rect_dither ? 7'h07 : 7'h00) :
                            (rt && rl) ? 7'h08 : (rt && rg) ? 7'h09 : (rb && rl) ? 7'h0A : (rb && rg) ? 7'h0B :
                            rt ? 7'h0C : rb ? 7'h0D : rl ? 7'h0E : rg ? 7'h0F : (rect_dither ? 7'h07 : 7'h00);

    wire in_range = (wc >= 0) && (wc < 9'sd80) && (wr >= 0) && (wr < 9'sd45);
    wire [12:0] wcell = {wr[5:0], 6'd0} + {2'd0, wr[5:0], 4'd0} + {6'd0, wc[6:0]};

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; t_we <= 1'b0; fld_id <= 8'd0; fld_idx <= 7'd0; cond_id <= 8'd0;
            p_addr <= 12'd0; s_addr <= 15'd0; t_addr <= 13'd0; t_wdata <= 20'd0;
        end else begin
            t_we <= 1'b0;
            case (st)
                S_IDLE: if (start) begin plist <= prog_list; clr <= 13'd0; st <= S_CLEAR; end
                S_CLEAR: begin
                    t_addr <= clr; t_wdata <= 20'd0; t_we <= 1'b1;
                    clr <= clr + 13'd1;
                    if (clr == 13'd3599) begin k <= 4'd0; st <= S_NEXTP; end
                end
                S_NEXTP: begin
                    if (k == 4'd12) st <= S_IDLE;
                    else begin
                        k <= k + 4'd1;
                        plist <= plist >> 8;
                        if (plist[7:0] != 8'd0) begin p_addr <= {4'd0, plist[7:0]}; st <= S_PTAB; end
                    end
                end
                S_PTAB:  st <= S_PTABW;
                S_PTABW: begin pc <= p_q[11:0]; org_x <= 9'sd0; org_y <= 9'sd0; cur <= 6'd0; st <= S_FETCH; end
                // ---------------- instruction fetch ----------------
                S_FETCH: begin p_addr <= pc; st <= S_FW1; end
                S_FW1:   st <= S_FW2;
                S_FW2: begin
                    w0 <= p_q;
                    case (p_q[31:28])
                        OP_END: st <= S_NEXTP;
                        OP_SKIPZ, OP_SKIPNZ: begin cond_id <= p_q[27:20]; pc <= pc + 12'd1; st <= S_CONDW; end
                        OP_ORG: begin fld_id <= p_q[27:20]; pc <= pc + 12'd1; st <= S_ORG0; end
                        OP_SETCUR: begin cur <= p_q[20:15]; pc <= pc + 12'd1; st <= S_FETCH; end
                        default: begin p_addr <= pc + 12'd1; pc <= pc + 12'd2; st <= S_W1A; end
                    endcase
                end
                S_CONDW: st <= S_COND;
                S_COND: begin
                    if ((op == OP_SKIPZ && !cond_val) || (op == OP_SKIPNZ && cond_val))
                        pc <= pc + {1'b0, w0[10:0]};
                    st <= S_FETCH;
                end
                S_ORG0: st <= S_ORG1;
                S_ORG1: begin
                    org_x  <= (w0[27:20] == 8'hFF) ? 9'sd0 : {fld_val[7], fld_val[7:0]};
                    fld_id <= w0[19:12];
                    st <= S_ORG1W;
                end
                S_ORG1W: st <= S_ORG2;
                S_ORG2: begin
                    org_y <= (w0[19:12] == 8'hFF) ? 9'sd0 : {fld_val[7], fld_val[7:0]};
                    st <= S_FETCH;
                end
                S_W1A: st <= S_W1B;
                S_W1B: begin                                // p_q = word 1
                    w1 <= p_q;
                    c0 <= $signed({2'd0, w0[27:21]}) + org_x;
                    r  <= w0[7] ? $signed({3'd0, cur}) : ($signed({3'd0, w0[20:15]}) + org_y);
                    any_char <= 1'b0;
                    case (op)
                        OP_RECT: begin
                            rc0 <= $signed({2'd0, w0[27:21]}) + org_x;
                            rr0 <= $signed({3'd0, w0[20:15]}) + org_y;
                            rc  <= $signed({2'd0, w0[27:21]}) + org_x;
                            rr  <= $signed({3'd0, w0[20:15]}) + org_y;
                            rc_end <= $signed({2'd0, w0[27:21]}) + org_x + $signed({2'd0, p_q[6:0]});
                            rr_end <= $signed({3'd0, w0[20:15]}) + org_y + $signed({3'd0, p_q[13:8]});
                            rect_border <= w0[9]; rect_dither <= w0[8];
                            st <= S_RECT;
                        end
                        OP_TEXT:   begin src <= 2'd0; sp <= p_q[14:0]; maxlen <= 7'd127; st <= S_LINE; end
                        OP_FIELD:  begin src <= 2'd1; fld_id <= p_q[7:0]; fi <= 7'd0; maxlen <= p_q[14:8]; st <= S_LINE; end
                        OP_CHAR:   begin src <= 2'd2; rep_n <= p_q[14:8]; maxlen <= 7'd127; st <= S_LINE; end
                        OP_STRSEL: begin fld_id <= p_q[23:16]; st <= S_SEL0; end
                        default:   st <= S_FETCH;
                    endcase
                end
                S_SEL0:  st <= S_SEL0B;                      // fld_val settles (2 cycles through game_flow FF)
                S_SEL0B: st <= S_SEL1;
                S_SEL1: begin p_addr <= w1[11:0] + fld_val[11:0]; st <= S_SEL2; end
                S_SEL2: st <= S_SEL3;
                S_SEL3: begin src <= 2'd0; sp <= p_q[14:0]; maxlen <= 7'd127; st <= S_LINE; end
                // ---------------- text: one line = (measure) + draw ----------------
                S_LINE: begin
                    sp_line <= sp; fi_line <= fi; rep_line <= rep_n; len <= 8'd0;
                    if (w_cent) st <= S_MREQ;
                    else begin c <= c0; st <= S_DREQ; end
                end
                S_MREQ:   begin s_addr <= sp; fld_idx <= fi; st <= S_MWAIT; end
                S_MWAIT:  st <= S_MWAIT2;
                S_MWAIT2: st <= S_MGOT;                     // string ROM & registered fld_char valid
                S_MGOT: begin
                    if (got_char == 8'd0 || got_char == 8'd10) begin
                        sp <= sp_line; fi <= fi_line; rep_n <= rep_line;
                        c  <= c0 - (w_big ? $signed({1'b0, len}) : $signed({2'b0, len[7:1]}));
                        st <= S_DREQ;
                    end else begin
                        len <= len + 8'd1;
                        sp <= sp + 14'd1; fi <= fi + 7'd1; if (rep_n != 0) rep_n <= rep_n - 7'd1;
                        st <= S_MREQ;
                    end
                end
                S_DREQ:   begin s_addr <= sp; fld_idx <= fi; st <= S_DWAIT; end
                S_DWAIT:  st <= S_DWAIT2;
                S_DWAIT2: st <= S_DGOT;
                S_DGOT: begin
                    sp <= sp + 14'd1; fi <= fi + 7'd1; if (rep_n != 0) rep_n <= rep_n - 7'd1;
                    if (got_char == 8'd0) begin
                        if (w_flow && any_char) cur <= r[5:0] + w_step;
                        st <= S_FETCH;
                    end else if (got_char == 8'd10) begin
                        r <= r + $signed({5'd0, w_step});
                        any_char <= 1'b1;
                        st <= S_LINE;
                    end else begin
                        any_char <= 1'b1;
                        wglyph <= got_char[6:0]; wfg <= w_fg; wbg <= w_bg; wbig <= w_big; quad <= 2'd0;
                        wc <= c; wr <= r;
                        cell_ret <= S_DREQ;
                        st <= S_CELL;
                    end
                end
                // ---------------- one cell (read-modify-write so bg = KEEP works) ----------------
                S_CELL: begin
                    if (in_range) begin t_addr <= wcell; st <= S_CELLW; end
                    else st <= S_CELLWR;
                end
                S_CELLW: st <= S_CELLWR;
                S_CELLWR: begin
                    if (in_range) begin
                        t_we    <= 1'b1;
                        t_wdata <= {wglyph, wfg, (wbg == BG_KEEP) ? t_rdata[7:3] : wbg, wbig, quad[0], quad[1]};
                    end
                    if (wbig && quad != 2'd3) begin
                        quad <= quad + 2'd1;
                        wc <= (quad[0] == 1'b0) ? wc + 9'sd1 : wc - 9'sd1;
                        wr <= (quad == 2'd1) ? wr + 9'sd1 : wr;
                        st <= S_CELL;
                    end else begin
                        if (cell_ret == S_DREQ) c <= c + (wbig ? 9'sd2 : 9'sd1);
                        st <= cell_ret;
                    end
                end
                // ---------------- RECT: walk the cells row by row ----------------
                S_RECT: begin
                    if (rr >= rr_end) st <= S_FETCH;
                    else begin
                        if (rect_glyph != 7'h00 || w_bg != BG_KEEP) begin
                            wglyph <= rect_glyph; wfg <= w_fg; wbg <= w_bg; wbig <= 1'b0; quad <= 2'd0;
                            wc <= rc; wr <= rr;
                            cell_ret <= S_RECT;
                            st <= S_CELL;
                        end
                        if (rc + 9'sd1 >= rc_end) begin rc <= rc0; rr <= rr + 9'sd1; end
                        else rc <= rc + 9'sd1;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
