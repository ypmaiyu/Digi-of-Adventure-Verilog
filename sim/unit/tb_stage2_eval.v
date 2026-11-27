// tb_stage2_eval.v - the Stage 2 breadboard simulator: the Pygame reference build (REF) must light
// exactly the GOLD segments for all six input codes; a chip without power must break it.
`timescale 1ns / 1ps
module tb_stage2_eval;
`include "s2_tables.vh"
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg start = 0, frame = 0; reg [15:0] sw = 0;
    wire done; wire [1:0] h, a, f, c; wire s, b; wire [7:0] bk; wire [2:0] nb;
    wire [127:0] od; wire [95:0] pl; wire [7:0] fc; wire [15:0] fv; wire cv; wire [63:0] seg; wire [15:0] leds;
    stage2 dut (.clk(clk), .rst(rst), .active(1'b1), .start(start), .frame(frame), .lvl(5'd0), .ev_press(5'd0), .ev_tap(1'b0),
                .ev_back(1'b0), .sw(sw), .sw_rise(16'd0), .sw_fall(16'd0), .hi_hearts(2'd3), .hi_armor(2'd0), .hi_shard(1'b0),
                .hi_boost(1'b0), .hi_form(2'd1), .hi_career(2'd0), .hi_backs(8'd0), .hi_nbacks(3'd2),
                .dbg_jump(1'b0), .dbg_key(3'd0), .dbg_act(1'b0), .dbg_act_key(3'd0),
                .dbg_set_hearts(1'b0), .dbg_hearts(2'd3), .dbg_set_form(1'b0), .dbg_form(2'd1), .done(done),
                .ho_hearts(h), .ho_armor(a), .ho_shard(s), .ho_boost(b), .ho_form(f), .ho_career(c), .ho_backs(bk), .ho_nbacks(nb),
                .obj_idx(6'd0), .obj_desc(od), .prog_list(pl), .fld_id(8'd0), .fld_idx(7'd0), .fld_char(fc), .fld_val(fv),
                .cond_id(8'd0), .cond_val(cv), .seg_text(seg), .leds(leds));
    task tick; begin repeat (4000) @(posedge clk); @(posedge clk) frame <= 1; @(posedge clk) frame <= 0; end endtask
    integer i, k, err = 0, bad = 0;
    reg [10:0] rf;
    initial begin
        #100 rst = 0;
        @(posedge clk) start <= 1; @(posedge clk) start <= 0;
        tick; tick;
        for (i = 0; i < S2_NREF; i = i + 1) begin rf = s2_ref(i); dut.w[rf[10:5]] = rf[4:0]; end
        for (k = 1; k <= 6; k = k + 1) begin
            dut.code0 = k; dut.code1 = (k % 6) + 1; sw[2:0] = k;
            tick; tick;
            if (dut.seg_q0 !== s2_gold(k) || dut.seg_live !== s2_gold(k)) begin
                err = err + 1; $display("code %0d: q0 %b live %b gold %b", k, dut.seg_q0, dut.seg_live, s2_gold(k));
            end
        end
        $display("reference build: %0d / 6 codes show the right character", 6 - err);
        dut.w[S2_U2_VCC] = 5'd0;                                  // unplug +5V of the AND chip
        for (k = 1; k <= 6; k = k + 1) begin
            dut.code0 = k; tick; tick;
            if (dut.seg_q0 !== s2_gold(k)) bad = bad + 1;
        end
        $display("AND chip unpowered: %0d / 6 codes now wrong", bad);
        if (bad == 0) err = err + 1;
        if (err == 0) $display("PASS tb_stage2_eval"); else $display("FAIL tb_stage2_eval: %0d errors", err);
        $finish;
    end
endmodule
