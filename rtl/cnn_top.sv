// ============================================================================
// cnn_top.sv  --  full serial MNIST CNN accelerator.
//
//   image ROM ─► conv1 ─► pool1 ─► conv2 ─► pool2 ─► dense1 ─► dense2 ─► argmax
//
// Layers run one at a time (serial baseline). Two activation buffers (bufA/bufB)
// ping-pong between layers; only the active layer drives a buffer, so the ports
// are muxed by the current layer id. A small controller pulses each layer's
// start, waits its done, and advances. On completion `pred` holds the digit and
// `hex0` shows it on a seven-segment display.
//
// Per-layer output buffer (for verification / ping-pong):
//   conv1->bufA  pool1->bufB  conv2->bufA  pool2->bufB  dense1->bufA  dense2->logits
// ============================================================================
module cnn_top #(
    parameter MEMDIR = "sim/mem/"                 // dir holding all *.hex (sim or Quartus)
)(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,                    // pulse to run one inference
    input  logic [4:0]  img_sel,                  // which of 30 images (0..29)
    output logic        busy,
    output logic        done,
    output logic [3:0]  pred,                     // predicted digit
    output logic [6:0]  hex0,                     // seven-seg (active low)
    // verification taps
    output logic        layer_valid,              // pulses when a layer finishes
    output logic [2:0]  layer_id                  // 0..5 = c1,p1,c2,p2,d1,d2
);
    // ---- layer ids --------------------------------------------------------
    localparam [2:0] C1=0, P1=1, C2=2, P2=3, D1=4, D2=5;

    // ---- per-layer nets ---------------------------------------------------
    logic [15:0] c1_ia,c1_oa, p1_ia,p1_oa, c2_ia,c2_oa, p2_ia,p2_oa, d1_ia,d1_oa, d2_ia,d2_oa;
    logic [7:0]  c1_id,c1_od, p1_id,p1_od, c2_id,c2_od, p2_id,p2_od, d1_id,d1_od, d2_id,d2_od;
    logic        c1_we,p1_we,c2_we,p2_we,d1_we,d2_we;
    logic        c1_st,p1_st,c2_st,p2_st,d1_st,d2_st;
    logic        c1_dn,p1_dn,c2_dn,p2_dn,d1_dn,d2_dn;

    // ---- image ROM (conv1 input) ------------------------------------------
    logic [15:0] img_addr; logic [7:0] img_dout;
    sync_rom #(8, 23520, {MEMDIR,"images.hex"}) u_img (clk, img_addr, img_dout);
    assign img_addr = {11'd0, img_sel} * 16'd784 + c1_ia;   // base + pixel
    assign c1_id    = img_dout;

    // ---- activation buffers (ping-pong) -----------------------------------
    logic [15:0] a_ra,a_wa,b_ra,b_wa; logic [7:0] a_rd,a_wd,b_rd,b_wd; logic a_we,b_we;
    sync_ram #(8,8192) bufA (.clk(clk),.rd_addr(a_ra),.rd_data(a_rd),.wr_addr(a_wa),.wr_data(a_wd),.wr_en(a_we));
    sync_ram #(8,8192) bufB (.clk(clk),.rd_addr(b_ra),.rd_data(b_rd),.wr_addr(b_wa),.wr_data(b_wd),.wr_en(b_we));

    // ---- current layer ----------------------------------------------------
    logic [2:0] cur;

    // bufA: written by C1/C2/D1, read by P1/P2/D2
    always_comb begin
        a_wa = 16'd0; a_wd = 8'd0; a_we = 1'b0; a_ra = 16'd0;
        case (cur)
            C1: begin a_wa=c1_oa; a_wd=c1_od; a_we=c1_we; end
            C2: begin a_wa=c2_oa; a_wd=c2_od; a_we=c2_we; end
            D1: begin a_wa=d1_oa; a_wd=d1_od; a_we=d1_we; end
            P1: a_ra=p1_ia;
            P2: a_ra=p2_ia;
            D2: a_ra=d2_ia;
            default: ;
        endcase
    end
    assign p1_id=a_rd; assign p2_id=a_rd; assign d2_id=a_rd;

    // bufB: written by P1/P2, read by C2/D1
    always_comb begin
        b_wa = 16'd0; b_wd = 8'd0; b_we = 1'b0; b_ra = 16'd0;
        case (cur)
            P1: begin b_wa=p1_oa; b_wd=p1_od; b_we=p1_we; end
            P2: begin b_wa=p2_oa; b_wd=p2_od; b_we=p2_we; end
            C2: b_ra=c2_ia;
            D1: b_ra=d1_ia;
            default: ;
        endcase
    end
    assign c2_id=b_rd; assign d1_id=b_rd;

    // ---- layer instances --------------------------------------------------
    conv_layer #(.CIN(1),.COUT(8),.K(3),.HIN(28),.WIN(28),.SHIFT(25),.RELU(1),
      .WFILE({MEMDIR,"conv1_w.hex"}),.BFILE({MEMDIR,"conv1_b.hex"}),.MFILE({MEMDIR,"conv1_m0.hex"}))
      u_c1(.clk,.rst_n,.start(c1_st),.done(c1_dn),.in_addr(c1_ia),.in_data(c1_id),.out_addr(c1_oa),.out_data(c1_od),.out_we(c1_we));
    maxpool_layer #(.C(8),.HIN(26),.WIN(26))
      u_p1(.clk,.rst_n,.start(p1_st),.done(p1_dn),.in_addr(p1_ia),.in_data(p1_id),.out_addr(p1_oa),.out_data(p1_od),.out_we(p1_we));
    conv_layer #(.CIN(8),.COUT(16),.K(3),.HIN(13),.WIN(13),.SHIFT(24),.RELU(1),
      .WFILE({MEMDIR,"conv2_w.hex"}),.BFILE({MEMDIR,"conv2_b.hex"}),.MFILE({MEMDIR,"conv2_m0.hex"}))
      u_c2(.clk,.rst_n,.start(c2_st),.done(c2_dn),.in_addr(c2_ia),.in_data(c2_id),.out_addr(c2_oa),.out_data(c2_od),.out_we(c2_we));
    maxpool_layer #(.C(16),.HIN(11),.WIN(11))
      u_p2(.clk,.rst_n,.start(p2_st),.done(p2_dn),.in_addr(p2_ia),.in_data(p2_id),.out_addr(p2_oa),.out_data(p2_od),.out_we(p2_we));
    dense_layer #(.NIN(400),.NOUT(64),.SHIFT(24),.RELU(1),
      .WFILE({MEMDIR,"dense1_w.hex"}),.BFILE({MEMDIR,"dense1_b.hex"}),.MFILE({MEMDIR,"dense1_m0.hex"}))
      u_d1(.clk,.rst_n,.start(d1_st),.done(d1_dn),.in_addr(d1_ia),.in_data(d1_id),.out_addr(d1_oa),.out_data(d1_od),.out_we(d1_we));
    dense_layer #(.NIN(64),.NOUT(10),.SHIFT(23),.RELU(0),
      .WFILE({MEMDIR,"dense2_w.hex"}),.BFILE({MEMDIR,"dense2_b.hex"}),.MFILE({MEMDIR,"dense2_m0.hex"}))
      u_d2(.clk,.rst_n,.start(d2_st),.done(d2_dn),.in_addr(d2_ia),.in_data(d2_id),.out_addr(d2_oa),.out_data(d2_od),.out_we(d2_we));

    // start/done muxes
    logic launch;
    assign c1_st=(cur==C1)&launch; assign p1_st=(cur==P1)&launch; assign c2_st=(cur==C2)&launch;
    assign p2_st=(cur==P2)&launch; assign d1_st=(cur==D1)&launch; assign d2_st=(cur==D2)&launch;
    logic cur_done;
    always_comb case (cur)
        C1: cur_done=c1_dn; P1: cur_done=p1_dn; C2: cur_done=c2_dn;
        P2: cur_done=p2_dn; D1: cur_done=d1_dn; D2: cur_done=d2_dn; default: cur_done=1'b0;
    endcase

    // ---- capture logits + argmax ------------------------------------------
    logic signed [7:0] logits [0:9];
    always_ff @(posedge clk) if ((cur==D2) && d2_we) logits[d2_oa[3:0]] <= $signed(d2_od);

    // sequential argmax over the 10 logits: one compare per cycle, so the path
    // is a single comparator (not a 9-deep ripple). Runs once at end of inference.
    logic signed [7:0] best_val;
    logic [3:0]        best_idx, ai;

    // ---- controller -------------------------------------------------------
    typedef enum logic [2:0] {IDLE, LAUNCH, RUN, ARGMAX, FINISH} cst_t;
    cst_t cs;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs<=IDLE; cur<=C1; launch<=0; busy<=0; done<=0; layer_valid<=0; pred<=0;
        end else begin
            launch<=0; layer_valid<=0; done<=0;
            case (cs)
                IDLE:   if (start) begin busy<=1; cur<=C1; cs<=LAUNCH; end
                LAUNCH: begin launch<=1; cs<=RUN; end
                RUN:    if (cur_done) begin
                            layer_valid<=1; layer_id<=cur;   // announce this layer done
                            if (cur==D2) begin               // start sequential argmax
                                best_val<=logits[0]; best_idx<=4'd0; ai<=4'd1;
                                cs<=ARGMAX;
                            end else begin cur<=cur+3'd1; cs<=LAUNCH; end
                        end
                ARGMAX: if (ai < 4'd10) begin                // one compare per cycle
                            if ($signed(logits[ai]) > best_val) begin
                                best_val <= logits[ai]; best_idx <= ai;
                            end
                            ai <= ai + 4'd1;
                        end else cs<=FINISH;
                FINISH: begin pred<=best_idx; busy<=0; done<=1; cs<=IDLE; end
            endcase
        end
    end

    // ---- seven-segment (active low, DE10-Lite HEX0[6:0]) ------------------
    always_comb case (pred)
        4'd0: hex0=7'h40; 4'd1: hex0=7'h79; 4'd2: hex0=7'h24; 4'd3: hex0=7'h30;
        4'd4: hex0=7'h19; 4'd5: hex0=7'h12; 4'd6: hex0=7'h02; 4'd7: hex0=7'h78;
        4'd8: hex0=7'h00; 4'd9: hex0=7'h10; default: hex0=7'h7f;
    endcase
endmodule
