// tb_input_ctrl.v - bouncing button -> one press; short press -> tap; long hold -> back (no tap); switch edges
`timescale 1ns / 1ps
module tb_input_ctrl;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    reg [4:0] btn = 0; reg [15:0] swr = 0; reg ft = 0;
    wire [4:0] lvl, ev_press, btn_now; wire ev_tap, ev_back; wire [15:0] sw, sw_rise, sw_fall, sw_now;
    input_ctrl #(.DEBOUNCE(20), .LONG(2000)) dut (.clk(clk), .rst(rst), .frame_tick(ft), .btn_raw(btn), .sw_raw(swr),
        .lvl(lvl), .ev_press(ev_press), .ev_tap(ev_tap), .ev_back(ev_back), .sw(sw), .sw_rise(sw_rise), .sw_fall(sw_fall),
        .btn_now(btn_now), .sw_now(sw_now));
    // a "frame" every 100 cycles
    integer c = 0;
    always @(posedge clk) begin c = c + 1; ft <= (c % 100 == 0); end
    integer presses = 0, taps = 0, backs = 0, rises = 0, falls = 0, err = 0;
    always @(posedge clk) if (ft) begin
        presses = presses + ev_press[0]; taps = taps + ev_tap; backs = backs + ev_back;
        rises = rises + sw_rise[3]; falls = falls + sw_fall[3];
    end
    integer k;
    initial begin
        #200 rst = 0;
        // bouncing BTNU press
        for (k = 0; k < 6; k = k + 1) begin btn[0] = ~btn[0]; #37; end
        btn[0] = 1; #3000; btn[0] = 0; #3000;
        if (presses != 1) begin err = err + 1; $display("bouncing press counted %0d times", presses); end
        // short BTNC press -> tap
        btn[4] = 1; #3000; btn[4] = 0; #3000;
        if (taps != 1 || backs != 0) begin err = err + 1; $display("short press: taps %0d backs %0d", taps, backs); end
        // long BTNC hold -> back, no tap
        btn[4] = 1; #40000; btn[4] = 0; #3000;
        if (taps != 1 || backs != 1) begin err = err + 1; $display("long hold: taps %0d backs %0d", taps, backs); end
        // switch 3 up and down
        swr[3] = 1; #3000; swr[3] = 0; #3000;
        if (rises != 1 || falls != 1) begin err = err + 1; $display("switch edges rise %0d fall %0d", rises, falls); end
        if (err == 0) $display("PASS tb_input_ctrl (debounce, tap, hold-back, switch edges)");
        else $display("FAIL tb_input_ctrl: %0d errors", err);
        $finish;
    end
endmodule
