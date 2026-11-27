// strutil.vh - small text helpers for UI fields and the 7-segment display.
// Strings are 20 characters, character 0 in bits [159:152], unused characters = 0.

function [11:0] bcd8;                        // 0..255 -> 3 BCD digits (double dabble)
    input [7:0] v;
    integer i;
    reg [19:0] s;
    begin
        s = {12'd0, v};
        for (i = 0; i < 8; i = i + 1) begin
            if (s[11:8]  >= 5) s[11:8]  = s[11:8]  + 3;
            if (s[15:12] >= 5) s[15:12] = s[15:12] + 3;
            if (s[19:16] >= 5) s[19:16] = s[19:16] + 3;
            s = s << 1;
        end
        bcd8 = s[19:8];
    end
endfunction

function [159:0] str_u8;                     // "%d" of 0..255
    input [7:0] v;
    reg [11:0] b;
    begin
        b = bcd8(v);
        if (v >= 100)     str_u8 = {"0" + b[11:8], "0" + b[7:4], "0" + b[3:0], 136'd0};
        else if (v >= 10) str_u8 = {"0" + b[7:4], "0" + b[3:0], 144'd0};
        else              str_u8 = {"0" + b[3:0], 152'd0};
    end
endfunction

function [159:0] str_s8;                     // "%d" of a signed byte
    input [7:0] v;
    reg [159:0] t;
    begin
        if (v[7]) begin
            t = str_u8(~v + 8'd1);
            str_s8 = {"-", t[159:8]};
        end else str_s8 = str_u8(v);
    end
endfunction

// seconds left of a frame counter, Python "%.0f" (round half to even) of frames/60
function [7:0] secs_round;
    input [10:0] n;
    reg [4:0] q;
    reg [10:0] r;
    integer i;
    begin
        q = 0;
        for (i = 1; i <= 20; i = i + 1) if (n >= i * 60) q = i;
        r = n - q * 60;
        if (r > 30 || (r == 30 && q[0])) secs_round = q + 1;
        else secs_round = q;
    end
endfunction

// select character `idx` of a 20-character string (0 past the end)
function [7:0] str_at;
    input [159:0] s;
    input [6:0] idx;
    begin
        str_at = (idx < 20) ? s[159 - 8 * idx -: 8] : 8'd0;
    end
endfunction

// append a 1-2 digit number on the right of a 6-character buffer (7-segment rjust)
function [47:0] push_num;
    input [47:0] buffer;
    input [7:0] v;
    reg [11:0] b;
    begin
        b = bcd8(v);
        if (v >= 10) push_num = {buffer[31:0], "0" + b[7:4], "0" + b[3:0]};
        else         push_num = {buffer[39:0], "0" + b[3:0]};
    end
endfunction
