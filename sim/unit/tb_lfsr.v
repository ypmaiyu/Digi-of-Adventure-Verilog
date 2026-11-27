// tb_lfsr.v - lfsr_next / lfsr_next7 against 1000 steps of the Python lfsr_step() (gen_vectors.py)
`timescale 1ns / 1ps
module tb_lfsr;
`include "lfsr.vh"
    reg [15:0] ref_v [0:999];
    reg [15:0] q, q7;
    integer i, err;
    initial begin
        $readmemh("lfsr_vectors.mem", ref_v);
        q = 16'hACE1; err = 0;
        for (i = 0; i < 1000; i = i + 1) begin
            q = lfsr_next(q);
            if (q !== ref_v[i]) begin err = err + 1; if (err < 5) $display("step %0d: got %h expected %h", i, q, ref_v[i]); end
        end
        q7 = lfsr_next7(16'hACE1);
        if (q7 !== ref_v[6]) begin err = err + 1; $display("lfsr_next7: got %h expected %h", q7, ref_v[6]); end
        if (lfsr_next(16'h0000) !== 16'hACE1 && lfsr_next(16'h0000) !== {15'd0, 1'b0}) ;
        if (err == 0) $display("PASS tb_lfsr (1000 steps + 7-step)"); else $display("FAIL tb_lfsr: %0d errors", err);
        $finish;
    end
endmodule
