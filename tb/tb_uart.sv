//=============================================================================
// tb_uart.sv  --  Self-checking testbench for the UART core
//
// Checks performed
//   1. Loopback (TX -> RX) data integrity for directed + random bytes at
//      several baud divisors, including back-to-back transmission
//   2. Independent bit-banged TX monitor: re-samples the serial line at
//      mid-bit and verifies start bit, 8 data bits (LSB first) and stop bit
//   3. Exact bit-period check (start bit lasts 16 * divisor clocks)
//   4. Receiver framing-error detection (stop bit = 0) and recovery
//   5. Receiver glitch rejection (short low pulse on idle line)
//
// Prints "TEST PASSED" or "TEST FAILED" and an error count at the end.
//=============================================================================
`timescale 1ns/1ps

module tb_uart;

    localparam CLK_PERIOD = 10;

    // ------------------------------------------------------------------
    // Clock / reset
    // ------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    reg [15:0] baud_div = 16'd4;

    // ------------------------------------------------------------------
    // DUT A : full core in loopback (tx -> rx)
    // ------------------------------------------------------------------
    reg        tx_start = 1'b0;
    reg  [7:0] tx_data  = 8'h00;
    wire       tx_busy, tx_done, tx_line;
    wire [7:0] rx_data;
    wire       rx_valid, frame_error;

    uart_top #(.DATA_BITS(8), .STOP_BITS(1)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .baud_div    (baud_div),
        .tx_start    (tx_start),
        .tx_data     (tx_data),
        .tx_busy     (tx_busy),
        .tx_done     (tx_done),
        .tx          (tx_line),
        .rx          (tx_line),      // loopback
        .rx_data     (rx_data),
        .rx_valid    (rx_valid),
        .frame_error (frame_error)
    );

    // ------------------------------------------------------------------
    // DUT B : stand-alone receiver driven by the testbench
    // ------------------------------------------------------------------
    reg        rx_line2 = 1'b1;
    wire       tick2;
    wire [7:0] rx2_data;
    wire       rx2_valid, rx2_ferr;

    uart_baud_gen bg2 (.clk(clk), .rst_n(rst_n), .divisor(baud_div), .tick(tick2));
    uart_rx #(.DATA_BITS(8)) rx2 (
        .clk(clk), .rst_n(rst_n), .tick(tick2), .rx(rx_line2),
        .rx_data(rx2_data), .rx_valid(rx2_valid), .frame_error(rx2_ferr)
    );

    // ------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------
    integer errors     = 0;
    integer rx_checked = 0;
    integer mon_checked = 0;

    reg [7:0] exp_q [0:4095];
    integer   wr_ptr  = 0;     // bytes pushed by send_byte
    integer   rx_ptr  = 0;     // bytes seen by receiver
    integer   mon_ptr = 0;     // bytes seen by independent monitor

    task automatic fail(input [8*64-1:0] msg);
        begin
            errors = errors + 1;
            $display("[%0t] ERROR: %0s", $time, msg);
        end
    endtask

    // Receiver-side checker (loopback)
    always @(posedge clk) begin
        if (rx_valid) begin
            if (rx_ptr >= wr_ptr) begin
                fail("unexpected rx_valid");
            end else begin
                if (rx_data !== exp_q[rx_ptr]) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: RX data mismatch exp=%02h got=%02h",
                             $time, exp_q[rx_ptr], rx_data);
                end
                if (frame_error) fail("frame_error on a good frame");
                rx_ptr     = rx_ptr + 1;
                rx_checked = rx_checked + 1;
            end
        end
    end

    // Independent TX monitor: samples serial line at mid-bit
    reg [7:0] mon_byte;
    integer   mon_i;
    initial begin : tx_monitor
        wait (rst_n === 1'b1);
        forever begin
            @(negedge tx_line);                              // start bit edge
            repeat (8 * baud_div) @(posedge clk);            // half a bit
            if (tx_line !== 1'b0) fail("start bit not low at mid-bit");
            for (mon_i = 0; mon_i < 8; mon_i = mon_i + 1) begin
                repeat (16 * baud_div) @(posedge clk);
                mon_byte[mon_i] = tx_line;
            end
            repeat (16 * baud_div) @(posedge clk);
            if (tx_line !== 1'b1) fail("stop bit not high at mid-bit");
            if (mon_ptr >= wr_ptr) begin
                fail("monitor saw unexpected frame");
            end else begin
                if (mon_byte !== exp_q[mon_ptr]) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: TX line mismatch exp=%02h got=%02h",
                             $time, exp_q[mon_ptr], mon_byte);
                end
                mon_ptr     = mon_ptr + 1;
                mon_checked = mon_checked + 1;
            end
        end
    end

    // Latch results from the stand-alone receiver
    reg       got2_valid = 1'b0;
    reg [7:0] got2_data  = 8'h00;
    reg       got2_ferr  = 1'b0;
    always @(posedge clk) begin
        if (rx2_valid) begin
            got2_valid <= 1'b1;
            got2_data  <= rx2_data;
            got2_ferr  <= rx2_ferr;
        end
    end

    // ------------------------------------------------------------------
    // Helper tasks
    // ------------------------------------------------------------------
    // Queue a byte for transmission (blocks only while the TX is busy)
    task automatic send_byte(input [7:0] d);
        begin
            @(negedge clk);
            while (tx_busy) @(negedge clk);
            exp_q[wr_ptr] = d;
            wr_ptr   = wr_ptr + 1;
            tx_data  = d;
            tx_start = 1'b1;
            @(negedge clk);
            tx_start = 1'b0;
        end
    endtask

    // Wait until every queued byte was received and monitored
    task automatic wait_all_done;
        integer guard;
        begin
            guard = 0;
            while ((rx_ptr < wr_ptr || mon_ptr < wr_ptr || tx_busy) && guard < 2000000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 2000000) fail("timeout waiting for completion");
            repeat (4) @(posedge clk);
        end
    endtask

    task automatic set_baud(input [15:0] d);
        begin
            wait_all_done;
            baud_div = d;
            repeat (4) @(posedge clk);
        end
    endtask

    // Drive one frame onto rx_line2 (stop_level=0 creates a framing error)
    task automatic drive_frame(input [7:0] d, input stop_level);
        integer i;
        begin
            rx_line2 = 1'b0;                                  // start
            repeat (16 * baud_div) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                rx_line2 = d[i];
                repeat (16 * baud_div) @(posedge clk);
            end
            rx_line2 = stop_level;                            // stop
            repeat (16 * baud_div) @(posedge clk);
            rx_line2 = 1'b1;
            repeat (4 * baud_div) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    integer seed = 32'h0BAD_CAFE;
    integer k, n;
    reg [15:0] div_k;
    time t0, t1;

    function [15:0] div_list(input integer idx);
        begin
            case (idx)
                0: div_list = 16'd1;
                1: div_list = 16'd2;
                2: div_list = 16'd3;
                3: div_list = 16'd5;
                4: div_list = 16'd8;
                default: div_list = 16'd13;
            endcase
        end
    endfunction

    initial begin
        $dumpfile("uart_tb.vcd");
        $dumpvars(0, tb_uart);

        // ---- reset ------------------------------------------------------
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // ---- 1/2. loopback + line monitor over several baud divisors -----
        for (k = 0; k < 6; k = k + 1) begin
            div_k = div_list(k);
            set_baud(div_k);
            $display("[%0t] Testing divisor = %0d", $time, div_k);

            // directed corner cases (all queued back-to-back)
            send_byte(8'h00);
            send_byte(8'hFF);
            send_byte(8'h55);
            send_byte(8'hAA);
            send_byte(8'h01);
            send_byte(8'h80);
            send_byte(8'hA5);
            send_byte(8'h5A);

            // random data, back-to-back
            for (n = 0; n < 24; n = n + 1)
                send_byte($random(seed) & 8'hFF);

            wait_all_done;
        end

        // ---- 3. exact bit period ----------------------------------------
        set_baud(16'd5);
        send_byte(8'h01);               // start=0 then LSB=1 -> rising edge after 1 bit
        @(negedge tx_line);  t0 = $time;
        @(posedge tx_line);  t1 = $time;
        if ((t1 - t0) !== (16 * 5 * CLK_PERIOD)) begin
            errors = errors + 1;
            $display("ERROR: start-bit width = %0t ns, expected %0d ns",
                     t1 - t0, 16 * 5 * CLK_PERIOD);
        end else
            $display("Bit period check OK: %0t ns (16 x 5 clk)", t1 - t0);
        wait_all_done;

        // ---- 4. framing error + recovery ---------------------------------
        set_baud(16'd3);
        got2_valid = 1'b0;
        drive_frame(8'h3C, 1'b0);       // bad stop bit
        repeat (4 * 16 * baud_div) @(posedge clk);
        if (!got2_valid)            fail("no rx_valid on framing-error frame");
        else if (!got2_ferr)        fail("framing error not flagged");
        else                        $display("Framing error detected correctly");

        got2_valid = 1'b0;
        got2_ferr  = 1'b0;
        drive_frame(8'hC3, 1'b1);       // good frame afterwards
        repeat (2 * 16 * baud_div) @(posedge clk);
        if (!got2_valid || got2_data !== 8'hC3 || got2_ferr)
            fail("receiver did not recover after framing error");
        else
            $display("Receiver recovered after framing error");

        // ---- 5. glitch rejection -----------------------------------------
        got2_valid = 1'b0;
        rx_line2 = 1'b0;
        repeat (3 * baud_div) @(posedge clk);   // << half a bit
        rx_line2 = 1'b1;
        repeat (3 * 16 * baud_div) @(posedge clk);
        if (got2_valid) fail("glitch was accepted as a frame");
        else            $display("Glitch correctly rejected");

        // ---- summary -----------------------------------------------------
        repeat (20) @(posedge clk);
        $display("--------------------------------------------------");
        $display("Loopback bytes checked : %0d", rx_checked);
        $display("TX-line bytes checked  : %0d", mon_checked);
        $display("Errors                 : %0d", errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $display("--------------------------------------------------");
        $finish;
    end

    // global watchdog
    initial begin
        #200_000_000;
        $display("TEST FAILED: global watchdog timeout");
        $finish;
    end
endmodule
