// seg7_ctrl.v - drives the 8-digit 7-segment display of the Nexys A7.
// text[63:0] = 8 ASCII characters, text[63:56] = LEFTMOST digit (AN7).
// Digits are lit one at a time for 1 ms each (8 ms refresh, no flicker).
// Segments / anodes are active LOW on the board. Character set: the SEG_MAP of the
// Pygame panels (0-9 H - E P C A F L O U d S t G n r b space).
`timescale 1ns / 1ps
module seg7_ctrl #(parameter REFRESH = 100_000) (
    input  wire        clk,
    input  wire        rst,
    input  wire [63:0] text,
    output reg  [7:0]  an,       // active low, an[0] = rightmost
    output reg  [6:0]  seg,      // active low, seg[0] = a ... seg[6] = g
    output wire        dp
);
    assign dp = 1'b1;
    reg [16:0] cnt;
    reg [2:0]  digit;
    // segment bits g f e d c b a  (1 = on)
    function [6:0] font7;
        input [7:0] c;
        begin
            case (c)
                "0": font7 = 7'b0111111; "1": font7 = 7'b0000110; "2": font7 = 7'b1011011; "3": font7 = 7'b1001111;
                "4": font7 = 7'b1100110; "5": font7 = 7'b1101101; "6": font7 = 7'b1111101; "7": font7 = 7'b0000111;
                "8": font7 = 7'b1111111; "9": font7 = 7'b1101111;
                "H": font7 = 7'b1110110; "-": font7 = 7'b1000000; "E": font7 = 7'b1111001; "P": font7 = 7'b1110011;
                "C": font7 = 7'b0111001; "A": font7 = 7'b1110111; "F": font7 = 7'b1110001; "L": font7 = 7'b0111000;
                "O": font7 = 7'b0111111; "U": font7 = 7'b0111110; "d": font7 = 7'b1011110; "S": font7 = 7'b1101101;
                "t": font7 = 7'b1111000; "G": font7 = 7'b0111101; "n": font7 = 7'b1010100; "r": font7 = 7'b1010000;
                "b": font7 = 7'b1111100; "o": font7 = 7'b1011100;
                default: font7 = 7'b0000000;
            endcase
        end
    endfunction
    wire [7:0] ch = text[8*(7 - digit) +: 8];
    always @(posedge clk) begin
        if (rst) begin cnt <= 17'd0; digit <= 3'd0; an <= 8'hFF; seg <= 7'h7F; end
        else begin
            if (cnt == REFRESH - 1) begin cnt <= 17'd0; digit <= digit + 3'd1; end
            else cnt <= cnt + 17'd1;
            an  <= ~(8'd1 << (7 - digit));
            seg <= ~font7(ch);
        end
    end
endmodule
