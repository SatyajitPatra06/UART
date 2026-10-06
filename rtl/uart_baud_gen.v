`timescale 1ns/1ps
//=============================================================================
// uart_baud_gen.v
// Configurable baud-rate generator.
//
// Produces a single-cycle `tick` pulse at 16x the baud rate (16x oversampling).
// The tick period (in clk cycles) is set by the run-time `divisor` input:
//
//     divisor = round( CLK_FREQ / (16 * BAUD_RATE) )
//
// Example: 50 MHz clock, 115200 baud -> divisor = 27 (actual 115740 baud, +0.5%)
//=============================================================================
module uart_baud_gen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [15:0] divisor,   // clk cycles per 16x tick (0 is treated as 1)
    output reg         tick       // 1-cycle pulse, 16x baud rate
);
    wire [15:0] div_eff = (divisor == 16'd0) ? 16'd1 : divisor;
    reg  [15:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= 16'd0;
            tick <= 1'b0;
        end else if (cnt >= div_eff - 16'd1) begin
            cnt  <= 16'd0;
            tick <= 1'b1;
        end else begin
            cnt  <= cnt + 16'd1;
            tick <= 1'b0;
        end
    end
endmodule
