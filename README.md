# UART Transmitter & Receiver — Serial Communication Core (Verilog)

A synthesizable UART core written in Verilog, verified with a self-checking SystemVerilog testbench.
It implements FSM-based data framing, start/stop bit handling, and a run-time configurable baud-rate generator
with 16x oversampling on the receive side.

**Tools:** Verilog, SystemVerilog, Icarus Verilog / Synopsys VCS, EDA Playground

---

## Features

- **8N1 framing** by default (`DATA_BITS` and `STOP_BITS` are parameters)
- **Configurable baud rate** through a 16-bit run-time divisor (no re-synthesis needed)
- **FSM-based transmitter** — frames are aligned to the baud tick, so every bit is exactly `16 × divisor` clocks wide
- **16x oversampling receiver** — 2-FF input synchroniser, mid-bit sampling, start-bit glitch rejection
- **Framing-error detection** (stop bit low) with automatic recovery once the line returns to idle
- **Simple valid/busy handshakes** — `tx_start` / `tx_busy` / `tx_done` and `rx_valid` / `frame_error`

## Architecture

```
                     +--------------------------------------------+
                     |                 uart_top                   |
   baud_div[15:0] -->|  +---------------+                         |
                     |  | uart_baud_gen |--tick (16x baud)--+     |
                     |  +---------------+                   |     |
                     |                                      v     |
   tx_start  ------->|  +---------------------+  tick  +----------+|
   tx_data[7:0] ---->|  |      uart_tx        |<-------|          ||
   tx_busy  <--------|  | IDLE>SYNC>START>    |        |          ||---> tx
   tx_done  <--------|  |     DATA>STOP       |        |          ||
                     |  +---------------------+        |          ||
                     |  +---------------------+  tick  |          ||
   rx  ------------->|  |      uart_rx        |<-------+          ||
   rx_data[7:0] <----|  | IDLE>START>DATA>    |                   ||
   rx_valid <--------|  |   STOP (>WAIT)      |                   ||
   frame_error <-----|  +---------------------+                   ||
                     +--------------------------------------------+
```

### Frame format (8N1)

```
idle  start  D0  D1  D2  D3  D4  D5  D6  D7  stop  idle
  1     0    LSB ...                     MSB   1      1
        |<----------- 10 bit periods ---------->|
```

### Receiver timing (16x oversampling)

1. Falling edge on the synchronised `rx` → enter `START`
2. After 8 ticks (mid start bit) the line is re-checked; if it is high again the pulse was a glitch and is ignored
3. Every 16 ticks after that, one data bit is sampled at its centre (LSB first)
4. The stop bit is sampled at its centre; `frame_error` pulses together with `rx_valid` if it is low

## Baud-rate configuration

`baud_div` sets the number of system-clock cycles between 16x ticks:

```
baud_div = round( CLK_FREQ / (16 × BAUD_RATE) )
```

| System clock | Target baud | `baud_div` | Actual baud | Error  |
|--------------|-------------|-----------:|------------:|-------:|
| 50 MHz       | 9600        | 326        | 9586        | −0.15% |
| 50 MHz       | 57600       | 54         | 57870       | +0.47% |
| 50 MHz       | 115200      | 27         | 115741      | +0.47% |

Keep the baud error below roughly ±2% for reliable communication.

## Interface

| Port          | Dir | Width | Description |
|---------------|-----|-------|-------------|
| `clk`         | in  | 1     | System clock |
| `rst_n`       | in  | 1     | Active-low asynchronous reset |
| `baud_div`    | in  | 16    | Clock cycles per 16x baud tick |
| `tx_start`    | in  | 1     | One-clock pulse to start sending `tx_data` (only when `tx_busy` = 0) |
| `tx_data`     | in  | 8     | Byte to transmit (latched when `tx_start` is sampled) |
| `tx_busy`     | out | 1     | High for the whole frame |
| `tx_done`     | out | 1     | One-clock pulse after the stop bit completes |
| `tx`          | out | 1     | Serial output (idle high) |
| `rx`          | in  | 1     | Serial input (idle high, asynchronous) |
| `rx_data`     | out | 8     | Last received byte |
| `rx_valid`    | out | 1     | One-clock pulse: new byte in `rx_data` |
| `frame_error` | out | 1     | One-clock pulse with `rx_valid`: stop bit was 0 |

## Repository layout

```
.
├── rtl/
│   ├── uart_baud_gen.v   # 16x tick generator, run-time divisor
│   ├── uart_tx.v         # transmitter FSM
│   ├── uart_rx.v         # oversampling receiver FSM
│   └── uart_top.v        # top level (baud gen + TX + RX)
├── tb/
│   └── tb_uart.sv        # self-checking testbench
├── Makefile              # Icarus / VCS / Xcelium targets
├── LICENSE
└── README.md
```

## Verification

`tb/tb_uart.sv` is self-checking and ends with `TEST PASSED` or `TEST FAILED`.

| # | Check | How |
|---|-------|-----|
| 1 | Loopback data integrity | TX wired to RX; directed corner cases (`00`, `FF`, `55`, `AA`, `01`, `80`, `A5`, `5A`) plus 24 random bytes per baud setting, sent back-to-back, compared against a scoreboard |
| 2 | Serial-line correctness | Independent testbench receiver samples the `tx` pin at mid-bit and checks start bit, 8 data bits (LSB first) and stop bit — so TX is not only tested through the DUT's own RX |
| 3 | Baud timing accuracy | Start-bit width measured in simulation time and compared with exactly `16 × divisor × T_clk` |
| 4 | Varying baud rates | Divisors 1, 2, 3, 5, 8 and 13 are all swept |
| 5 | Framing error | Frame with stop bit = 0 must raise `frame_error`; the next good frame must still be received correctly |
| 6 | Glitch rejection | A low pulse shorter than half a bit on an idle line must not produce a frame |

Sample output (Icarus Verilog 12):

```
[175000] Testing divisor = 1
[52145000] Testing divisor = 2
[155325000] Testing divisor = 3
[310015000] Testing divisor = 5
[567755000] Testing divisor = 8
[980015000] Testing divisor = 13
Bit period check OK: 800000 ns (16 x 5 clk)
Framing error detected correctly
Receiver recovered after framing error
Glitch correctly rejected
--------------------------------------------------
Loopback bytes checked : 193
TX-line bytes checked  : 193
Errors                 : 0
TEST PASSED
--------------------------------------------------
```

## How to run

### Icarus Verilog (open source)

```bash
make sim          # compile + run
make wave         # open uart_tb.vcd in GTKWave
```

or manually:

```bash
iverilog -g2012 -Wall -o sim.out rtl/*.v tb/tb_uart.sv
vvp sim.out
```

### Synopsys VCS

```bash
make vcs
# = vcs -full64 -sverilog -debug_access+all rtl/*.v tb/tb_uart.sv -top tb_uart -o simv && ./simv
```

### Cadence Xcelium

```bash
make xcelium
```

### EDA Playground

1. Open <https://edaplayground.com> and choose **SystemVerilog/Verilog** as the language.
2. Paste `tb/tb_uart.sv` in the **testbench** pane and the four files from `rtl/` in the **design** pane.
3. Select a simulator (Icarus Verilog, Synopsys VCS or Cadence Xcelium) and tick **Open EPWave after run**.
4. Run.

## Waveforms

<!-- Add a screenshot of a transmitted byte here, e.g.:
![UART waveform](docs/waveform.png)
-->

## Possible extensions

- Parity bit (even/odd) with parity-error flag
- TX/RX FIFOs with `full` / `empty` flags
- Overrun-error detection on the receiver
- AXI-Stream or APB wrapper
- FPGA demo (UART echo / loopback on a development board)

## License

Released under the MIT License — see [LICENSE](LICENSE).

## Author

**Satyajit Patra** — B.Tech, Electrical Engineering, Odisha University of Technology and Research
[GitHub](https://github.com/SatyajitPatra06) · [LinkedIn](https://linkedin.com/in/satyajit-patra-460541212/)
