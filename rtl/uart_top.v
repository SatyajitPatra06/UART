`timescale 1ns/1ps
//=============================================================================
// uart_top.v
// Top-level UART core: shared baud generator + transmitter + receiver.
//=============================================================================
module uart_top #(
    parameter DATA_BITS = 8,
    parameter STOP_BITS = 1
) (
    input  wire                 clk,
    input  wire                 rst_n,        // active-low async reset
    input  wire [15:0]          baud_div,     // clk cycles per 16x tick

    // transmit side
    input  wire                 tx_start,
    input  wire [DATA_BITS-1:0] tx_data,
    output wire                 tx_busy,
    output wire                 tx_done,
    output wire                 tx,

    // receive side
    input  wire                 rx,
    output wire [DATA_BITS-1:0] rx_data,
    output wire                 rx_valid,
    output wire                 frame_error
);
    wire tick;

    uart_baud_gen u_baud (
        .clk     (clk),
        .rst_n   (rst_n),
        .divisor (baud_div),
        .tick    (tick)
    );

    uart_tx #(.DATA_BITS(DATA_BITS), .STOP_BITS(STOP_BITS)) u_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tick     (tick),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .tx       (tx),
        .tx_busy  (tx_busy),
        .tx_done  (tx_done)
    );

    uart_rx #(.DATA_BITS(DATA_BITS)) u_rx (
        .clk         (clk),
        .rst_n       (rst_n),
        .tick        (tick),
        .rx          (rx),
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .frame_error (frame_error)
    );
endmodule
