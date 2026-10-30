// ============================================================================
// maxpool_layer.sv  --  serial 2x2 / stride-2 "valid" max-pool.
//   out[oh,ow,c] = max( in[2oh+dy, 2ow+dx, c] )  for dy,dx in {0,1}
// Output dims floor(HIN/2) x floor(WIN/2) (drops a trailing odd row/col, e.g.
// 11 -> 5), matching the golden model. Activations are non-negative int8.
// ============================================================================
module maxpool_layer #(
    parameter integer C   = 8,
    parameter integer HIN = 26,
    parameter integer WIN = 26
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
    localparam integer HOUT = HIN/2;
    localparam integer WOUT = WIN/2;

    logic [15:0] c, oh, ow;
    logic [1:0]  t;                       // tap 0..3 -> dy=t[1], dx=t[0]
    logic [7:0]  maxv;
    wire   [15:0] dy = {15'd0, t[1]};
    wire   [15:0] dx = {15'd0, t[0]};

    assign in_addr = ((oh*2 + dy)*WIN + (ow*2 + dx))*C + c;

    typedef enum logic [2:0] {IDLE, READ, CMP, WRITE, FIN} state_t;
    state_t st;

    wire last_out = (c==C-1) && (oh==HOUT-1) && (ow==WOUT-1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=IDLE; done<=0; out_we<=0; c<=0; oh<=0; ow<=0; t<=0; maxv<=0;
        end else begin
            out_we <= 1'b0;
            case (st)
            IDLE: if (start) begin done<=0; c<=0; oh<=0; ow<=0; t<=0; st<=READ; end
            READ: st <= CMP;                          // present in_addr, wait 1 cycle
            CMP: begin
                maxv <= (t==2'd0) ? in_data : ((in_data > maxv) ? in_data : maxv);
                if (t==2'd3) st <= WRITE;
                else begin t <= t+2'd1; st <= READ; end
            end
            WRITE: begin
                out_addr <= (oh*WOUT + ow)*C + c;
                out_data <= maxv;                     // maxv already includes tap 3
                out_we   <= 1'b1;
                t <= 2'd0;
                if (last_out) begin done<=1; st<=FIN; end
                else begin
                    if (ow != WOUT-1)     ow <= ow+1;
                    else begin ow<=0;
                        if (oh != HOUT-1) oh <= oh+1;
                        else begin oh<=0; c <= c+1; end
                    end
                    st <= READ;
                end
            end
            FIN: begin done<=1'b0; st<=IDLE; end
            default: st <= IDLE;
            endcase
        end
    end
endmodule
