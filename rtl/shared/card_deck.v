// card_deck.v - FEATURE 3: one round of the random card picker (3 face-down cards).
//
// The arrangement is chosen ONCE when a round opens: `perm` (0..5) indexes the 6
// permutations of the round's 3 items (itertools.permutations order), picked by the stage
// with LFSR rejection sampling (accept lfsr&7 < 6) exactly like card_start() in Pygame.
// Every item therefore appears exactly once; nothing is re-randomised while the cards
// are on screen. The player moves the cursor (BTNL/BTNR) and reveals one card (BTNC);
// a second BTNC closes the round. `pick` pulses with the chosen screen position and the
// item index behind it; the stage grants the item.
`timescale 1ns / 1ps
module card_deck (
    input  wire       clk,
    input  wire       rst,
    input  wire       clear,
    input  wire       open,               // start a round
    input  wire [1:0] open_round,         // 1, 2, 3
    input  wire [2:0] open_perm,          // 0..5
    input  wire       upd,                // frame update with these events:
    input  wire       ev_left,
    input  wire       ev_right,
    input  wire       ev_tap,
    input  wire       ev_back,
    input  wire       allow_skip,         // Stage 2 optional 4th card: hold BTNC skips
    output reg        active,
    output reg  [1:0] round,
    output reg  [1:0] cursor,
    output reg        face,               // a card has been revealed
    output reg  [1:0] face_pos,
    output reg  [2:0] perm,
    output reg        pick,               // 1-cycle: card revealed
    output wire [1:0] pick_pos,
    output wire [1:0] pick_idx,           // item index = perm[pos]
    output reg        done,               // 1-cycle: round closed (tap after reveal)
    output reg        skipped             // 1-cycle: round closed with hold-BTNC (no item)
);
    // itertools.permutations([0,1,2]): (0,1,2) (0,2,1) (1,0,2) (1,2,0) (2,0,1) (2,1,0)
    function [1:0] perm_at;
        input [2:0] p; input [1:0] pos;
        reg [5:0] t;
        begin
            case (p)
                3'd0: t = {2'd2, 2'd1, 2'd0};
                3'd1: t = {2'd1, 2'd2, 2'd0};
                3'd2: t = {2'd2, 2'd0, 2'd1};
                3'd3: t = {2'd0, 2'd2, 2'd1};
                3'd4: t = {2'd1, 2'd0, 2'd2};
                default: t = {2'd0, 2'd1, 2'd2};
            endcase
            perm_at = t[2*pos +: 2];
        end
    endfunction
    assign pick_pos = face_pos;
    assign pick_idx = perm_at(perm, face_pos);

    always @(posedge clk) begin
        if (rst || clear) begin
            active <= 1'b0; round <= 2'd1; cursor <= 2'd1; face <= 1'b0; face_pos <= 2'd0; perm <= 3'd0;
            pick <= 1'b0; done <= 1'b0; skipped <= 1'b0;
        end else begin
            pick <= 1'b0; done <= 1'b0; skipped <= 1'b0;
            if (open) begin
                active <= 1'b1; round <= open_round; perm <= open_perm; cursor <= 2'd1; face <= 1'b0;
            end else if (upd && active) begin
                if (!face) begin
                    if (ev_left)       cursor <= (cursor == 2'd0) ? 2'd2 : cursor - 2'd1;
                    else if (ev_right) cursor <= (cursor == 2'd2) ? 2'd0 : cursor + 2'd1;
                    else if (ev_tap) begin face <= 1'b1; face_pos <= cursor; pick <= 1'b1; end
                    else if (ev_back && allow_skip) begin active <= 1'b0; skipped <= 1'b1; end
                end else if (ev_tap) begin
                    active <= 1'b0; done <= 1'b1;
                end
            end
        end
    end
endmodule
