// ============================================================================
// dense_layer.sv  --  serial fully-connected layer.
//   out[co] = requant( bias[co] + sum_ni weight[co,ni] * in[ni] )
// Weight ROM order: co -> ni (each output neuron's weight vector contiguous).
// Input activations are non-negative int8; weights signed int8.
// ============================================================================
module dense_layer #(
    parameter integer NIN   = 400,
    parameter integer NOUT  = 64,
    parameter integer SHIFT = 24,
    parameter integer RELU  = 1,
    parameter         WFILE = "",
    parameter         BFILE = "",
    parameter         MFILE = ""
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    output logic        done,
    output logic [15:0] in_addr,
    input  logic [7:0]  in_data,
    output logic [15:0] out_addr,
    output logic [7:0]  out_data,
    output logic        out_we
);
    localparam integer WD = NOUT*NIN;

    logic [15:0] w_addr;  logic [7:0]  w_data;
    logic [15:0] cb_addr; logic [31:0] b_data; logic [15:0] m0_data;
    sync_rom #(8,  WD,   WFILE) u_wrom (clk, w_addr,  w_data );
    sync_rom #(32, NOUT, BFILE) u_brom (clk, cb_addr, b_data );
    sync_rom #(16, NOUT, MFILE) u_mrom (clk, cb_addr, m0_data);

    logic [15:0] co, ni;
    logic signed [31:0] acc;

    assign cb_addr = co;
    assign in_addr = ni;
    assign w_addr  = co*NIN + ni;

    logic signed [7:0] q_out;
    requantize #(SHIFT, RELU) u_rq (.clk(clk), .acc(acc), .m0(m0_data), .q(q_out));

    typedef enum logic [2:0] {IDLE, BREQ, BLAT, READ, MAC, RQ, WRITE, FIN} state_t;
    state_t st;

    wire last_ni  = (ni == NIN-1);
    wire last_out = (co == NOUT-1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=IDLE; done<=0; out_we<=0; co<=0; ni<=0; acc<=0;
        end else begin
            out_we <= 1'b0;
            case (st)
            IDLE: if (start) begin done<=0; co<=0; st<=BREQ; end
            BREQ: st <= BLAT;
            BLAT: begin acc <= $signed(b_data); ni<=0; st<=READ; end
            READ: st <= MAC;
            MAC: begin
                acc <= acc + $signed(w_data) * $signed({1'b0, in_data});
                if (last_ni) st <= RQ;              // acc final next cycle
                else begin ni <= ni+1; st <= READ; end
            end
            RQ:    st <= WRITE;                     // let requant register the product
            WRITE: begin
                out_addr <= co;
                out_data <= q_out;
                out_we   <= 1'b1;
                if (last_out) begin done<=1; st<=FIN; end
                else begin co <= co+1; st <= BREQ; end
            end
            FIN: begin done<=1'b0; st<=IDLE; end
            default: st <= IDLE;
            endcase
        end
    end
endmodule
