`timescale 1ns/1ps
//=============================================================================
// uart_tx.v
// UART transmitter: FSM-based framing  (idle=1, start=0, DATA_BITS LSB-first,
// STOP_BITS stop bits = 1).  Default frame format is 8N1.
//
// Handshake:
//   - Pulse `tx_start` for one clock while `tx_busy` is low, with `tx_data`
//     valid. Data is latched on that clock edge.
//   - `tx_busy` stays high for the whole frame; `tx_done` pulses for one
//     clock when the last stop bit has been fully sent.
//
// Timing: every bit lasts exactly 16 `tick` pulses. The frame is aligned to a
// tick so the start bit is exactly 16 ticks long.
//=============================================================================
module uart_tx #(
    parameter DATA_BITS = 8,
    parameter STOP_BITS = 1            // 1 or 2
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 tick,      // 16x baud tick
    input  wire                 tx_start,
    input  wire [DATA_BITS-1:0] tx_data,
    output reg                  tx,        // serial line (idle high)
    output wire                 tx_busy,
    output reg                  tx_done
);
    localparam [2:0] S_IDLE  = 3'd0,
                     S_SYNC  = 3'd1,   // wait for tick so start bit is 16 full ticks
                     S_START = 3'd2,
                     S_DATA  = 3'd3,
                     S_STOP  = 3'd4;

    reg [2:0]               state;
    reg [5:0]               tick_cnt;  // ticks within a bit (0..15, or 0..31 for 2 stop bits)
    reg [$clog2(DATA_BITS)-1:0] bit_idx;
    reg [DATA_BITS-1:0]     shreg;

    assign tx_busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            tx       <= 1'b1;
            tx_done  <= 1'b0;
            tick_cnt <= 6'd0;
            bit_idx  <= 0;
            shreg    <= {DATA_BITS{1'b0}};
        end else begin
            tx_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (tx_start) begin
                        shreg <= tx_data;
                        state <= S_SYNC;
                    end
                end

                S_SYNC: begin
                    if (tick) begin
                        tx       <= 1'b0;          // start bit begins
                        tick_cnt <= 6'd0;
                        state    <= S_START;
                    end
                end

                S_START: begin
                    if (tick) begin
                        if (tick_cnt == 6'd15) begin
                            tx       <= shreg[0];  // first data bit (LSB)
                            tick_cnt <= 6'd0;
                            bit_idx  <= 0;
                            state    <= S_DATA;
                        end else
                            tick_cnt <= tick_cnt + 6'd1;
                    end
                end

                S_DATA: begin
                    if (tick) begin
                        if (tick_cnt == 6'd15) begin
                            tick_cnt <= 6'd0;
                            if (bit_idx == DATA_BITS-1) begin
                                tx    <= 1'b1;     // stop bit begins
                                state <= S_STOP;
                            end else begin
                                tx      <= shreg[1];
                                shreg   <= {1'b0, shreg[DATA_BITS-1:1]};
                                bit_idx <= bit_idx + 1'b1;
                            end
                        end else
                            tick_cnt <= tick_cnt + 6'd1;
                    end
                end

                S_STOP: begin
                    if (tick) begin
                        if (tick_cnt == (16*STOP_BITS - 1)) begin
                            tick_cnt <= 6'd0;
                            tx_done  <= 1'b1;
                            state    <= S_IDLE;
                        end else
                            tick_cnt <= tick_cnt + 6'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
