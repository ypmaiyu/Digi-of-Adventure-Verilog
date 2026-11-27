// heart_armor.v - FEATURE 3 / Heart system: hearts, armor and armor shards.
//   damage   : one wrong door code (Stage 1) or failed QA test (Stage 2).
//              Armor absorbs it (armor-1, `blocked` pulse), otherwise hearts-1 (`hit`).
//              `zero` pulses when the last heart is lost -> the stage restarts.
//   add_armor: +1 armor (max 3);  add_shard: 2 shards forge 1 armor automatically.
// Only the stage's door / QA controller may drive `damage`; puzzle mistakes never do.
`timescale 1ns / 1ps
module heart_armor (
    input  wire       clk,
    input  wire       rst,
    input  wire       load,               // stage start / restart
    input  wire [1:0] load_hearts,
    input  wire [1:0] load_armor,
    input  wire       load_shard,
    input  wire       damage,
    input  wire       add_armor,
    input  wire       add_shard,
    output reg  [1:0] hearts,
    output reg  [1:0] armor,
    output reg        shard,              // holding one shard
    output reg        blocked,            // 1-cycle
    output reg        hit,                // 1-cycle
    output reg        zero,               // 1-cycle
    output reg        forged              // 1-cycle: 2 shards became armor
);
    always @(posedge clk) begin
        if (rst) begin
            hearts <= 2'd3; armor <= 2'd0; shard <= 1'b0;
            blocked <= 1'b0; hit <= 1'b0; zero <= 1'b0; forged <= 1'b0;
        end else begin
            blocked <= 1'b0; hit <= 1'b0; zero <= 1'b0; forged <= 1'b0;
            if (load) begin
                hearts <= load_hearts; armor <= load_armor; shard <= load_shard;
            end else begin
                if (damage) begin
                    if (armor != 2'd0) begin armor <= armor - 2'd1; blocked <= 1'b1; end
                    else if (hearts != 2'd0) begin
                        hearts <= hearts - 2'd1; hit <= 1'b1;
                        if (hearts == 2'd1) zero <= 1'b1;
                    end
                end else if (add_armor) begin
                    if (armor != 2'd3) armor <= armor + 2'd1;
                end else if (add_shard) begin
                    if (shard) begin
                        shard <= 1'b0; forged <= 1'b1;
                        if (armor != 2'd3) armor <= armor + 2'd1;
                    end else shard <= 1'b1;
                end
            end
        end
    end
endmodule
