// ============================================================================
// de10lite_top.sv  --  board wrapper for the DE10-Lite (MAX10 10M50DAF484C7G).
//
//   SW[4:0]  -> image index (0..29)     [2-FF synchronised]
//   KEY[0]   -> reset (active low)       [reset synchroniser]
//   KEY[1]   -> run inference (press)    [debounced, edge -> 1-cycle pulse]
//   HEX0     -> predicted digit
//   LEDR[0]  -> busy,  LEDR[1] -> done
//
// The CNN core is fully synchronous @ 50 MHz. Everything the core sees is in the
// clk domain; all asynchronous board inputs are synchronised here (and declared
// false paths in the SDC).  Memory .hex files must be reachable by $readmemh:
// set MEMDIR to where they live (default "" = the Quartus project directory).
// ============================================================================
module de10lite_top #(
    parameter MEMDIR = "sim/mem/",
    parameter integer DB = 500_000              // debounce cycles (~10 ms @ 50 MHz); tb_board shrinks it
)(
    input  logic        MAX10_CLK1_50,
    input  logic [9:0]  SW,
    input  logic [1:0]  KEY,
    output logic [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    output logic [9:0]  LEDR
);
    logic clk;
    assign clk = MAX10_CLK1_50;

    // ---- reset synchroniser: async assert, synchronous deassert ------------
    logic [1:0] rst_sync;
    always_ff @(posedge clk or negedge KEY[0])
        if (!KEY[0]) rst_sync <= 2'b00;
        else         rst_sync <= {rst_sync[0], 1'b1};
    logic rst_n;
    assign rst_n = rst_sync[1];

    // ---- 2-FF synchronisers for asynchronous inputs ------------------------
    logic [4:0] sw_s1, sw_s2;
    logic       k1_s1, k1_s2;
    always_ff @(posedge clk) begin
        sw_s1 <= SW[4:0]; sw_s2 <= sw_s1;
        k1_s1 <= KEY[1];  k1_s2 <= k1_s1;
    end

    // ---- debounce KEY[1] and turn a press into a single-cycle start pulse ---
    logic [$clog2(DB)-1:0] dbcnt;
    logic key_stable, key_stable_d, start;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dbcnt<=0; key_stable<=1'b1; key_stable_d<=1'b1;
        end else begin
            if (k1_s2 == key_stable) dbcnt <= 0;         // input matches -> reset timer
            else if (dbcnt == DB-1) begin key_stable <= k1_s2; dbcnt <= 0; end
            else dbcnt <= dbcnt + 1;
            key_stable_d <= key_stable;
        end
    end
    assign start = key_stable_d & ~key_stable;  // 1->0 (press, active low) => pulse

    // ---- CNN core ----------------------------------------------------------
    logic busy, done; logic [3:0] pred; logic [6:0] seg;
    logic lv; logic [2:0] lid;
    cnn_top #(.MEMDIR(MEMDIR)) u_cnn (
        .clk(clk), .rst_n(rst_n), .start(start), .img_sel(sw_s2),
        .busy(busy), .done(done), .pred(pred), .hex0(seg),
        .layer_valid(lv), .layer_id(lid)
    );

    // ---- displays / LEDs (HEX active low, bit7 = decimal point) ------------
    assign HEX0 = {1'b1, seg};
    assign HEX1 = 8'hFF; assign HEX2 = 8'hFF; assign HEX3 = 8'hFF;
    assign HEX4 = 8'hFF; assign HEX5 = 8'hFF;
    assign LEDR = {8'b0, done, busy};
endmodule
