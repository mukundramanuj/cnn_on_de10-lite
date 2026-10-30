// ============================================================================
// cnn_core.sv  --  shared building blocks for the MNIST CNN accelerator
//   * sync_rom     : synchronous ROM (1-cycle read latency), $readmemh init
//   * sync_ram     : synchronous simple-dual-port RAM (activation buffer)
//   * requantize   : int32 accumulator -> int8, fixed-point multiply-then-shift
//
// Style: SystemVerilog-2005 synthesizable subset (Quartus Prime Lite).
// All memory address ports are a uniform 16 bits for easy wiring; unused upper
// bits are trimmed by synthesis.
// ============================================================================

// ---------------------------------------------------------------------------
// Synchronous ROM. Initialised from a $readmemh hex file (one value per line).
// 1-cycle read latency, matching on-chip M9K behaviour.
// ---------------------------------------------------------------------------
module sync_rom #(
    parameter integer WIDTH = 8,
    parameter integer DEPTH = 72,
    parameter         FILE  = ""
)(
    input  logic              clk,
    input  logic       [15:0] addr,
    output logic [WIDTH-1:0]  dout
);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    initial if (FILE != "") $readmemh(FILE, mem);
    always_ff @(posedge clk) dout <= mem[addr[$clog2(DEPTH)-1:0]];
endmodule


// ---------------------------------------------------------------------------
// Synchronous RAM used as an activation buffer. One write port + one read
// port (simple dual-port -> infers an M9K). 1-cycle read latency.
// ---------------------------------------------------------------------------
module sync_ram #(
    parameter integer WIDTH = 8,
    parameter integer DEPTH = 8192
)(
    input  logic              clk,
    input  logic       [15:0] rd_addr,
    output logic [WIDTH-1:0]  rd_data,
    input  logic       [15:0] wr_addr,
    input  logic [WIDTH-1:0]  wr_data,
    input  logic              wr_en
);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_addr[$clog2(DEPTH)-1:0]] <= wr_data;
        rd_data <= mem[rd_addr[$clog2(DEPTH)-1:0]];
    end
endmodule


// ---------------------------------------------------------------------------
// Requantiser (combinational).  Reproduces the Python golden model exactly:
//     out = saturate( (acc * M0 + (1 << (SHIFT-1))) >>> SHIFT )
// with ReLU clamping the low end to 0 (all layers except the final logits).
// The >>> is an arithmetic shift so negative accumulators floor like Python's.
// ---------------------------------------------------------------------------
// PIPELINED: the acc*M0 product is registered (prod_r) to break the long
// multiply->shift->clamp path so the design closes timing at 50 MHz. The
// arithmetic is IDENTICAL to the combinational version, so results stay
// bit-exact with the golden model; q is simply valid ONE cycle after acc/m0
// are presented (the layer FSMs allow for this with an extra requant state).
module requantize #(
    parameter integer SHIFT = 25,
    parameter integer RELU  = 1
)(
    input  logic               clk,
    input  logic signed [31:0] acc,
    input  logic        [15:0] m0,
    output logic signed [7:0]  q
);
    logic signed [63:0] prod_r, rnd, shr;
    // stage 1: register the wide product (packs into the DSP output register)
    always_ff @(posedge clk) prod_r <= $signed(acc) * $signed({1'b0, m0});
    // stage 2: round -> arithmetic shift -> clamp (combinational)
    always_comb begin
        rnd = prod_r + (64'sd1 <<< (SHIFT-1));         // round-to-nearest
        shr = rnd >>> SHIFT;                           // arithmetic shift
        if (shr > 64'sd127)                q = 8'sd127;
        else if (shr < (RELU ? 64'sd0 : -64'sd128))
                                           q = RELU ? 8'sd0 : 8'sh80; // 0x80 = -128
        else                               q = shr[7:0];
    end
endmodule
