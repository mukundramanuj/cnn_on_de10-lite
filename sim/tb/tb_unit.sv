// Generic per-layer bit-exact unit test. Select the layer with a +define:
//   POOL1 | CONV2 | POOL2 | DENSE1 | DENSE2
// Feeds the layer its golden INPUT vector and checks its output against the
// golden OUTPUT vector for image IMG (default 0).
`timescale 1ns/1ps
module tb_unit;
`ifdef POOL1
  localparam NIN=5408, NOUT=1352; localparam INF="conv1", EXF="pool1", NAME="POOL1";
`elsif CONV2
  localparam NIN=1352, NOUT=1936; localparam INF="pool1", EXF="conv2", NAME="CONV2";
`elsif POOL2
  localparam NIN=1936, NOUT=400;  localparam INF="conv2", EXF="pool2", NAME="POOL2";
`elsif DENSE1
  localparam NIN=400,  NOUT=64;   localparam INF="pool2", EXF="dense1", NAME="DENSE1";
`elsif DENSE2
  localparam NIN=64,   NOUT=10;   localparam INF="dense1", EXF="logits", NAME="DENSE2";
`endif

    logic clk=0, rst_n=0, start=0, done;
    always #5 clk=~clk;
    logic [15:0] in_addr, out_addr; logic [7:0] in_data, out_data; logic out_we;

    sync_ram #(8,8192) u_in(.clk(clk),.rd_addr(in_addr),.rd_data(in_data),
                            .wr_addr(16'd0),.wr_data(8'd0),.wr_en(1'b0));

`ifdef POOL1
    maxpool_layer #(.C(8),.HIN(26),.WIN(26)) dut(.*);
`elsif CONV2
    conv_layer #(.CIN(8),.COUT(16),.K(3),.HIN(13),.WIN(13),.SHIFT(24),.RELU(1),
      .WFILE("sim/mem/conv2_w.hex"),.BFILE("sim/mem/conv2_b.hex"),.MFILE("sim/mem/conv2_m0.hex")) dut(.*);
`elsif POOL2
    maxpool_layer #(.C(16),.HIN(11),.WIN(11)) dut(.*);
`elsif DENSE1
    dense_layer #(.NIN(400),.NOUT(64),.SHIFT(24),.RELU(1),
      .WFILE("sim/mem/dense1_w.hex"),.BFILE("sim/mem/dense1_b.hex"),.MFILE("sim/mem/dense1_m0.hex")) dut(.*);
`elsif DENSE2
    dense_layer #(.NIN(64),.NOUT(10),.SHIFT(23),.RELU(0),
      .WFILE("sim/mem/dense2_w.hex"),.BFILE("sim/mem/dense2_b.hex"),.MFILE("sim/mem/dense2_m0.hex")) dut(.*);
`endif

    logic [7:0] cap [0:NOUT-1];
    always_ff @(posedge clk) if (out_we) cap[out_addr] <= out_data;

    integer fd,i,v,errors,first_bad, IMG;
    logic [7:0] gold [0:NOUT-1];
    string s;

    initial begin
        if (!$value$plusargs("IMG=%d", IMG)) IMG=0;
        s = $sformatf("sim/golden/img%02d_%s.txt", IMG, INF);
        fd=$fopen(s,"r"); for(i=0;i<NIN;i=i+1) begin $fscanf(fd,"%d\n",v); u_in.mem[i]=v[7:0]; end $fclose(fd);
        s = $sformatf("sim/golden/img%02d_%s.txt", IMG, EXF);
        fd=$fopen(s,"r"); for(i=0;i<NOUT;i=i+1) begin $fscanf(fd,"%d\n",v); gold[i]=v[7:0]; end $fclose(fd);

        rst_n=0; repeat(4)@(posedge clk); rst_n=1; @(posedge clk);
        start=1; @(posedge clk); start=0;
        wait(done); repeat(3)@(posedge clk);

        errors=0; first_bad=-1;
        for(i=0;i<NOUT;i=i+1) if (cap[i]!==gold[i]) begin errors=errors+1; if(first_bad<0) first_bad=i; end
        if (errors==0) $display("%s img%0d: PASS  (%0d/%0d bit-exact)", NAME, IMG, NOUT, NOUT);
        else $display("%s img%0d: FAIL  %0d mismatches; first idx %0d got %0d exp %0d",
                      NAME, IMG, errors, first_bad, $signed(cap[first_bad]), $signed(gold[first_bad]));
        $finish;
    end
    initial begin #50000000 $display("%s TIMEOUT",NAME); $finish; end
endmodule
