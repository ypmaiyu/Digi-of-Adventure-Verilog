// input_ctrl.v - push buttons and slide switches -> clean per-frame game events.
//
// Every input goes through: 2-flip-flop synchroniser -> debounce (stable for DEBOUNCE
// clocks) -> edge detection. The game logic runs once per video frame (60 Hz), so short
// pulses are COLLECTED between two frame_ticks and handed over as one "event word" that
// stays valid for the whole next frame - exactly like Pygame's event list per loop.
//
//   btn order: [0]=BTNU [1]=BTND [2]=BTNL [3]=BTNR [4]=BTNC
//   lvl        : debounced button levels (held = walking), sampled at frame_tick
//   ev_press   : a button went down during the last frame (KEYDOWN events)
//   ev_tap     : BTNC released before LONG_CYCLES (Pygame "tap" = confirm / interact)
//   ev_back    : BTNC held for LONG_CYCLES (0.8 s) - fires once while held ("back")
//   sw         : debounced switches; sw_rise / sw_fall: edges seen during the last frame
`timescale 1ns / 1ps
module input_ctrl #(
    parameter DEBOUNCE = 1_000_000,          // 10 ms at 100 MHz
    parameter LONG     = 80_000_000          // 0.8 s at 100 MHz (stage1_demo LONG_PRESS_S)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        frame_tick,
    input  wire [4:0]  btn_raw,
    input  wire [15:0] sw_raw,
    output reg  [4:0]  lvl,
    output reg  [4:0]  ev_press,
    output reg         ev_tap,
    output reg         ev_back,
    output reg  [15:0] sw,
    output reg  [15:0] sw_rise,
    output reg  [15:0] sw_fall,
    output wire [4:0]  btn_now,               // debounced level right now (not frame aligned)
    output wire [15:0] sw_now                 // debounced switches right now
);
    localparam DW = $clog2(DEBOUNCE + 1);
    localparam LW = $clog2(LONG + 1);

    // ---------------- 21 debounced inputs ----------------
    wire [20:0] raw = {sw_raw, btn_raw};
    reg  [20:0] s1, s2, deb;
    reg  [DW-1:0] cnt [0:20];
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            s1 <= 21'd0; s2 <= 21'd0; deb <= 21'd0;
            for (i = 0; i < 21; i = i + 1) cnt[i] <= {DW{1'b0}};
        end else begin
            s1 <= raw; s2 <= s1;
            for (i = 0; i < 21; i = i + 1) begin
                if (s2[i] == deb[i]) cnt[i] <= {DW{1'b0}};
                else if (cnt[i] == DEBOUNCE - 1) begin deb[i] <= s2[i]; cnt[i] <= {DW{1'b0}}; end
                else cnt[i] <= cnt[i] + 1'b1;
            end
        end
    end
    assign btn_now = deb[4:0];
    assign sw_now  = deb[20:5];

    // ---------------- edges + BTNC tap / long press ----------------
    reg [20:0] deb_d;
    reg [LW-1:0] hold;
    reg long_fired;
    reg [4:0]  acc_press;
    reg        acc_tap, acc_back;
    reg [15:0] acc_rise, acc_fall;
    wire [20:0] rise = deb & ~deb_d;
    wire [20:0] fall = ~deb & deb_d;
    always @(posedge clk) begin
        if (rst) begin
            deb_d <= 21'd0; hold <= {LW{1'b0}}; long_fired <= 1'b0;
            acc_press <= 5'd0; acc_tap <= 1'b0; acc_back <= 1'b0; acc_rise <= 16'd0; acc_fall <= 16'd0;
            lvl <= 5'd0; ev_press <= 5'd0; ev_tap <= 1'b0; ev_back <= 1'b0;
            sw <= 16'd0; sw_rise <= 16'd0; sw_fall <= 16'd0;
        end else begin
            deb_d <= deb;
            // BTNC hold timer
            if (deb[4]) begin
                if (!long_fired) begin
                    if (hold == LONG - 1) long_fired <= 1'b1;
                    else hold <= hold + 1'b1;
                end
            end else begin
                hold <= {LW{1'b0}};
                long_fired <= 1'b0;
            end
            // collect events between frames
            if (frame_tick) begin
                lvl      <= deb[4:0];
                sw       <= deb[20:5];
                ev_press <= acc_press | rise[4:0];
                ev_tap   <= acc_tap | (fall[4] & ~long_fired);
                ev_back  <= acc_back | (deb[4] && !long_fired && hold == LONG - 1);
                sw_rise  <= acc_rise | rise[20:5];
                sw_fall  <= acc_fall | fall[20:5];
                acc_press <= 5'd0; acc_tap <= 1'b0; acc_back <= 1'b0; acc_rise <= 16'd0; acc_fall <= 16'd0;
            end else begin
                acc_press <= acc_press | rise[4:0];
                if (fall[4] && !long_fired) acc_tap <= 1'b1;
                if (deb[4] && !long_fired && hold == LONG - 1) acc_back <= 1'b1;
                acc_rise <= acc_rise | rise[20:5];
                acc_fall <= acc_fall | fall[20:5];
            end
        end
    end
endmodule
