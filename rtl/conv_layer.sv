// ============================================================================
// conv_layer.sv  --  serial 2-D convolution engine (valid, stride 1).
//
// Computes, for every output channel co and position (oh,ow):
//     acc = bias[co] + sum_{ci,ky,kx} weight[co,ci,ky,kx] * in[oh+ky, ow+kx, ci]
//     out[oh,ow,co] = requant(acc, M0[co], SHIFT, RELU)
//
// One MAC, reused over time (correctness-first serial baseline). Activations
// are unsigned (image 0..255, or post-ReLU 0..127); weights are signed int8.
// Data is stored HWC-linear:  addr = (h*W + w)*C + c   (matches the golden model).
//
// Weight/bias/M0 ROMs are instantiated internally, one per tensor.
// ============================================================================
module conv_layer #(
    parameter integer CIN   = 1,
    parameter integer COUT  = 8,
    parameter integer K     = 3,
    parameter integer HIN   = 28,
    parameter integer WIN   = 28,
    parameter integer SHIFT = 25,
    parameter integer RELU  = 1,
    parameter         WFILE = "",
    parameter         BFILE = "",
    parameter         MFILE = ""
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    output logic        done,
    // input activation buffer (read port)
    output logic [15:0] in_addr,
    input  logic [7:0]  in_data,
    // output activation buffer (write port)
    output logic [15:0] out_addr,
    output logic [7:0]  out_data,
    output logic        out_we
);
    localparam integer HOUT = HIN - K + 1;
    localparam integer WOUT = WIN - K + 1;
    localparam integer WD   = COUT*CIN*K*K;

    // --- weight / bias / M0 ROMs -------------------------------------------
    logic [15:0] w_addr;
    logic [7:0]  w_data;
    logic [15:0] cb_addr;                 // addresses bias & M0 by output channel
    logic [31:0] b_data;
    logic [15:0] m0_data;

    sync_rom #(8,  WD,   WFILE) u_wrom (clk, w_addr,  w_data );
    sync_rom #(32, COUT, BFILE) u_brom (clk, cb_addr, b_data );
    sync_rom #(16, COUT, MFILE) u_mrom (clk, cb_addr, m0_data);

    // --- loop counters ------------------------------------------------------
    logic [15:0] co, oh, ow;              // output channel / row / col
    logic [15:0] ci, ky, kx;              // input channel / kernel row / col
    logic signed [31:0] acc;

    assign cb_addr  = co;
    assign in_addr  = ((oh + ky)*WIN + (ow + kx))*CIN + ci;
    assign w_addr   = ((co*CIN + ci)*K + ky)*K + kx;
    // out_addr is REGISTERED (set in WRITE from the current indices) so it stays
    // aligned with out_data/out_we even as the loop counters advance.

    // --- requantiser (pipelined: q valid one cycle after acc/m0) -----------
    logic signed [7:0] q_out;
    requantize #(SHIFT, RELU) u_rq (.clk(clk), .acc(acc), .m0(m0_data), .q(q_out));

    // --- FSM ----------------------------------------------------------------
    typedef enum logic [2:0] {IDLE, BREQ, BLAT, READ, MAC, RQ, WRITE, FIN} state_t;
    state_t st;

    wire last_tap = (ci==CIN-1) && (ky==K-1) && (kx==K-1);
    wire last_out = (co==COUT-1) && (oh==HOUT-1) && (ow==WOUT-1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; done <= 1'b0; out_we <= 1'b0;
            co<=0; oh<=0; ow<=0; ci<=0; ky<=0; kx<=0; acc<=0;
        end else begin
            out_we <= 1'b0;
            case (st)
            IDLE: begin
                if (start) begin
                    done <= 1'b0;
                    co<=0; oh<=0; ow<=0;
                    st <= BREQ;                     // present bias/M0 addr (co=0)
                end
            end
            BREQ:  st <= BLAT;                      // wait 1 cycle for ROM
            BLAT: begin
                acc <= $signed(b_data);             // seed accumulator with bias
                ci<=0; ky<=0; kx<=0;
                st <= READ;
            end
            READ:  st <= MAC;                       // present in/w addr, wait 1 cycle
            MAC: begin
                acc <= acc + $signed(w_data) * $signed({1'b0, in_data});
                if (last_tap) st <= RQ;             // acc final next cycle
                else begin                          // advance kx -> ky -> ci
                    if (kx != K-1)      kx <= kx+1;
                    else begin kx<=0;
                        if (ky != K-1)  ky <= ky+1;
                        else begin ky<=0; ci <= ci+1; end
                    end
                    st <= READ;
                end
            end
            RQ:    st <= WRITE;                     // let requant register the product
            WRITE: begin
                out_addr <= (oh*WOUT + ow)*COUT + co; // address of THIS output
                out_data <= q_out;                  // requantised int8
                out_we   <= 1'b1;
                if (last_out) begin
                    done <= 1'b1; st <= FIN;
                end else begin                      // advance ow -> oh -> co
                    if (ow != WOUT-1)      ow <= ow+1;
                    else begin ow<=0;
                        if (oh != HOUT-1)  oh <= oh+1;
                        else begin oh<=0; co <= co+1; end
                    end
                    st <= BREQ;
                end
            end
            FIN:   begin done<=1'b0; st<=IDLE; end
            default: st <= IDLE;
            endcase
        end
    end
endmodule
