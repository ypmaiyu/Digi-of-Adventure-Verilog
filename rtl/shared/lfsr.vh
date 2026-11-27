// lfsr.vh - the 16-bit LFSR used by every stage (same taps and zero guard as the Pygame
// lfsr_step(): fb = q15 ^ q14 ^ q12 ^ q3, shift left, all-zero state replaced by 0xACE1).
function [15:0] lfsr_next;
    input [15:0] q;
    reg [15:0] n;
    begin
        n = {q[14:0], q[15] ^ q[14] ^ q[12] ^ q[3]};
        lfsr_next = (n == 16'd0) ? 16'hACE1 : n;
    end
endfunction

function [15:0] lfsr_next7;             // Pygame update(): "for _ in range(7): self.lfsr_step()"
    input [15:0] q;
    begin
        lfsr_next7 = lfsr_next(lfsr_next(lfsr_next(lfsr_next(lfsr_next(lfsr_next(lfsr_next(q)))))));
    end
endfunction
