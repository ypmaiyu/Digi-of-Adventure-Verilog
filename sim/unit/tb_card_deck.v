// tb_card_deck.v - every permutation: the picked slot gives item perm[pos]; round 3 can be skipped
`timescale 1ns / 1ps
module tb_card_deck;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg clear = 0, open = 0, upd = 0, l = 0, r = 0, tap = 0, back = 0, skip_ok = 0;
    reg [1:0] rnd = 2; reg [2:0] perm = 0;
    wire active, face, pick, done, skipped; wire [1:0] round, cursor, face_pos, pick_pos, pick_idx; wire [2:0] perm_q;
    card_deck dut (.clk(clk), .rst(rst), .clear(clear), .open(open), .open_round(rnd), .open_perm(perm), .upd(upd),
                   .ev_left(l), .ev_right(r), .ev_tap(tap), .ev_back(back), .allow_skip(skip_ok), .active(active),
                   .round(round), .cursor(cursor), .face(face), .face_pos(face_pos), .perm(perm_q), .pick(pick),
                   .pick_pos(pick_pos), .pick_idx(pick_idx), .done(done), .skipped(skipped));
    // itertools.permutations([0, 1, 2]) order
    function [1:0] pyperm; input [2:0] p; input [1:0] pos;
        reg [5:0] t; begin
            case (p) 0: t = {2'd2, 2'd1, 2'd0}; 1: t = {2'd1, 2'd2, 2'd0}; 2: t = {2'd2, 2'd0, 2'd1};
                     3: t = {2'd0, 2'd2, 2'd1}; 4: t = {2'd1, 2'd0, 2'd2}; default: t = {2'd0, 2'd1, 2'd2}; endcase
            pyperm = t[2*pos +: 2];
        end endfunction
    task frame_upd; begin @(posedge clk) upd <= 1; @(posedge clk) upd <= 0; l <= 0; r <= 0; tap <= 0; back <= 0; end endtask
    reg got; reg [1:0] gp, gi; integer p, mv, err = 0, ok = 0;
    always @(posedge clk) if (pick) begin got <= 1; gp <= pick_pos; gi <= pick_idx; end
    initial begin
        #50 rst = 0;
        for (p = 0; p < 6; p = p + 1) for (mv = 0; mv < 3; mv = mv + 1) begin
            got = 0;
            @(posedge clk) begin perm <= p; rnd <= 2; open <= 1; end
            @(posedge clk) open <= 0;
            // cursor starts at 1: move to slot mv
            if (mv == 0) begin l <= 1; frame_upd; end
            if (mv == 2) begin r <= 1; frame_upd; end
            tap <= 1; frame_upd;
            repeat (3) @(posedge clk);
            if (!got || gp != mv || gi != pyperm(p, mv)) begin err = err + 1; $display("perm %0d slot %0d: pick %b pos %0d idx %0d", p, mv, got, gp, gi); end
            else ok = ok + 1;
            tap <= 1; frame_upd;                                   // close the round
            repeat (3) @(posedge clk);
            if (active) begin err = err + 1; $display("round did not close"); end
        end
        // optional 4th card: hold BTNC skips
        skip_ok = 1;
        @(posedge clk) begin rnd <= 3; open <= 1; end
        @(posedge clk) open <= 0;
        back <= 1; frame_upd; repeat (3) @(posedge clk);
        if (active) begin err = err + 1; $display("skip did not close the round"); end
        if (err == 0) $display("PASS tb_card_deck (%0d picks over all 6 permutations, skip)", ok);
        else $display("FAIL tb_card_deck: %0d errors", err);
        $finish;
    end
endmodule
