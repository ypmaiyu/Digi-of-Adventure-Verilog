// s1_puzzles.v - Stage 1 answer checkers (pure combinational logic).
// Numbers are exactly those of stage1_demo.py:
//   P1  0x2A - 0b10011 - 0o21 = 42 - 19 - 17 = 6                 -> A = 6  (SW3..SW0 = 0110)
//   P2  F = AB + CD, truth table 0xF888 (minterm m = ABCD, bit m) -> B = popcount = 7
//   P3  NAND-only circuit must reproduce 0xF888
//   P4  -12 in 8-bit two's complement = 1111_0100 = 0xF4         -> C = popcount = 5
//   P5  "CPE" (Canva, Pinterest, Explorer from the projector clue table)
//   Door layer 1: last letter 'E' = ASCII 69 -> "69"
//   Door layer 2: S = A+B+C = 18; row = 6 7 5 1 8; order 4-2-5-1-3 -> 1 7 8 6 5
`timescale 1ns / 1ps
module s1_puzzles (
    // puzzle 2: three stored terms. used[3]=A .. used[0]=D, pol: 1 = plain, 0 = inverted
    input  wire [3:0] t0_used, t0_pol, t1_used, t1_pol, t2_used, t2_pol,
    output reg  [15:0] p2_table,
    output wire [3:0]  p2_lits,
    output wire        p2_ok,
    // puzzle 3: 9 fields (G1 in1/in2 ... G4 in1/in2, F) as 3-bit source indices
    input  wire [26:0] p3_fields,          // field f at [3f +: 3]
    output reg  [15:0] p3_table,
    output wire        p3_ok,
    output wire [4:0]  p3_ones
);
    localparam [15:0] P2_TRUTH = 16'hF888;
    integer m, k;
    reg [3:0] v;
    reg       f;
    reg [6:0] src;
    reg [3:0] g;

    function term_hit;
        input [3:0] used, pol, val;
        integer i;
        begin
            term_hit = (used != 4'd0);
            for (i = 0; i < 4; i = i + 1)
                if (used[i] && (val[i] != pol[i])) term_hit = 1'b0;
        end
    endfunction

    always @(*) begin
        for (m = 0; m < 16; m = m + 1) begin
            v = m[3:0];                          // v[3]=A v[2]=B v[1]=C v[0]=D
            p2_table[m] = term_hit(t0_used, t0_pol, v) | term_hit(t1_used, t1_pol, v) | term_hit(t2_used, t2_pol, v);
            // NAND circuit: sources 0..3 = A B C D, 4.. = G1..
            src = {3'b000, v[0], v[1], v[2], v[3]};
            for (k = 0; k < 4; k = k + 1) begin
                g[k] = ~(src[p3_fields[3*(2*k) +: 3]] & src[p3_fields[3*(2*k+1) +: 3]]);
                src[4 + k] = g[k];
            end
            p3_table[m] = g[p3_fields[3*8 +: 2]];
        end
    end
    function [2:0] pc4; input [3:0] x; pc4 = x[0] + x[1] + x[2] + x[3]; endfunction
    assign p2_lits = pc4(t0_used) + pc4(t1_used) + pc4(t2_used);
    assign p2_ok   = (p2_table == P2_TRUTH) && (p2_lits <= 4'd4);
    assign p3_ok   = (p3_table == P2_TRUTH);
    assign p3_ones = pc4(p3_table[3:0]) + pc4(p3_table[7:4]) + pc4(p3_table[11:8]) + pc4(p3_table[15:12]);
endmodule
