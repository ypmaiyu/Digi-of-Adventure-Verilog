// s1_collision.v - Stage 1 "blocked(x, y)" (FEATURE 1, collision independent of the picture).
// Same geometry as stage1_demo.py, in world pixels of the 2000x1116 room:
//   feet box = Rect(int(x)-18, int(y)-22, 36, 22); its 4 corners must be on the floor
//   floor: 360 <= y <= 1085, left edge x >= 600 - 0.76*(y-355), right edge x <= 1440 + 0.714*(y-350)
//   (multiplied out to integers: 100x + 76y >= 86980  and  1000x - 714y <= 1190100)
//   and the box must not overlap any of the 8 furniture rectangles (pygame colliderect).
`timescale 1ns / 1ps
module s1_collision (
    input  wire signed [12:0] x,          // int(x)
    input  wire signed [12:0] y,          // int(y)
    output wire               blocked
);
    wire signed [13:0] l = x - 13'sd18, r = x + 13'sd18, t = y - 13'sd22, b = y;

    function off_floor;                   // one corner (shift-add avoids DSP48 cascade for 74.25 MHz)
        input signed [13:0] cx, cy;
        reg signed [31:0] x32, y32, a, c;
        begin
            x32 = {{18{cx[13]}}, cx};
            y32 = {{18{cy[13]}}, cy};
            a = ((x32 <<< 6) + (x32 <<< 5) + (x32 <<< 2)) + ((y32 <<< 6) + (y32 <<< 3) + (y32 <<< 2));
            c = ((x32 <<< 10) - (x32 <<< 4) - (x32 <<< 3)) - ((y32 <<< 9) + (y32 <<< 7) + (y32 <<< 6) + (y32 <<< 3) + (y32 <<< 1));
            off_floor = (cy < 360) || (cy > 1085) || (a < 86980) || (c > 1190100);
        end
    endfunction

    function hits;                        // colliderect with (bx, by, bw, bh)
        input signed [13:0] bx, by, bw, bh;
        hits = (l < bx + bw) && (r > bx) && (t < by + bh) && (b > by);
    endfunction

    assign blocked = off_floor(l, t) || off_floor(r, t) || off_floor(l, b) || off_floor(r, b) ||
                     hits(620, 300, 200, 70)  ||   // grey cabinet
                     hits(815, 250, 140, 120) ||   // shelf
                     hits(450, 440, 125, 120) ||   // lockers (left wall)
                     hits(100, 880, 160, 125) ||   // low cabinet (bottom-left)
                     hits(660, 420, 650, 120) ||   // table row 1 (back)
                     hits(520, 615, 850, 150) ||   // table row 2
                     hits(380, 860, 1080, 170) ||  // table row 3 (front)
                     hits(1490, 525, 225, 250);    // teacher desk
endmodule
