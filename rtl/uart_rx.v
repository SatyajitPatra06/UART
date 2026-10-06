`timescale 1ns/1ps
//=============================================================================
// uart_rx.v
// UART receiver with 16x oversampling.
//
//  - 2-FF synchroniser on the asynchronous `rx` input
//  - Start-bit detection on the falling edge, then re-checked at mid-bit
//    (8 ticks later) so glitches shorter than half a bit are rejected
//  - Each data bit sampled at its centre (every 16 ticks)
//  - Stop bit sampled at its centre; `frame_error` is raised if it is low
//
// Outputs `rx_valid` and `frame_error` are 1-cycle pulses; `rx_data` is held
// stable until the next frame completes.
//=============================================================================
module uart_rx #(
    parameter DATA_BITS = 8
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 tick,        // 16x baud tick
    input  wire                 rx,          // serial input (idle high)
    output reg  [DATA_BITS-1:0] rx_data,
    output reg                  rx_valid,    // 1-cycle pulse: byte received
    output reg                  frame_error  // 1-cycle pulse with rx_valid: stop bit was 0
);
    localparam [2:0] S_IDLE  = 3'd0,
                     S_START = 3'd1,
                     S_DATA  = 3'd2,
                     S_STOP  = 3'd3,
                     S_WAIT  = 3'd4;   // wait for line to return idle after a framing error

    // ---- input synchroniser ------------------------------------------------
    reg rx_meta, rx_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_s    <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_s    <= rx_meta;
        end
    end

    // ---- receive FSM -------------------------------------------------------
    reg [2:0]                   state;
    reg [3:0]                   tick_cnt;
    reg [$clog2(DATA_BITS)-1:0] bit_idx;
    reg [DATA_BITS-1:0]         shreg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            tick_cnt    <= 4'd0;
            bit_idx     <= 0;
            shreg       <= {DATA_BITS{1'b0}};
            rx_data     <= {DATA_BITS{1'b0}};
            rx_valid    <= 1'b0;
            frame_error <= 1'b0;
        end else begin
            rx_valid    <= 1'b0;
            frame_error <= 1'b0;

            case (state)
                S_IDLE: begin
                    tick_cnt <= 4'd0;
                    if (!rx_s)                       // falling edge -> possible start bit
                        state <= S_START;
                end

                S_START: begin
                    if (tick) begin
                        if (tick_cnt == 4'd7) begin  // middle of start bit
                            tick_cnt <= 4'd0;
                            if (!rx_s) begin         // still low -> genuine start bit
                                bit_idx <= 0;
                                state   <= S_DATA;
                            end else
                                state <= S_IDLE;     // glitch, ignore
                        end else
                            tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_DATA: begin
                    if (tick) begin
                        if (tick_cnt == 4'd15) begin // middle of data bit
                            tick_cnt <= 4'd0;
                            shreg    <= {rx_s, shreg[DATA_BITS-1:1]};  // LSB first
                            if (bit_idx == DATA_BITS-1)
                                state <= S_STOP;
                            else
                                bit_idx <= bit_idx + 1'b1;
                        end else
                            tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_STOP: begin
                    if (tick) begin
                        if (tick_cnt == 4'd15) begin // middle of stop bit
                            tick_cnt    <= 4'd0;
                            rx_data     <= shreg;
                            rx_valid    <= 1'b1;
                            frame_error <= ~rx_s;
                            // On a framing error the line is still low: do not
                            // mistake it for a new start bit, wait for idle.
                            state       <= rx_s ? S_IDLE : S_WAIT;
                        end else
                            tick_cnt <= tick_cnt + 4'd1;
                    end
                end

                S_WAIT: begin
                    if (rx_s) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
