// Per-layer bit-exact unit test: conv1 (image -> 26x26x8) vs golden vector.
`timescale 1ns/1ps
module tb_conv1;
    localparam N_OUT = 26*26*8;   // 5408
    logic clk=0, rst_n=0, start=0, done;
    always #5 clk = ~clk;

    // input activation buffer (holds the raw image)
    logic [15:0] in_addr;  logic [7:0] in_data;
    logic [15:0] out_addr; logic [7:0] out_data; logic out_we;
    sync_ram #(8, 8192) u_in (.clk(clk), .rd_addr(in_addr), .rd_data(in_data),
                              .wr_addr(16'd0), .wr_data(8'd0), .wr_en(1'b0));

    conv_layer #(.CIN(1),.COUT(8),.K(3),.HIN(28),.WIN(28),.SHIFT(25),.RELU(1),
                 .WFILE("sim/mem/conv1_w.hex"),
                 .BFILE("sim/mem/conv1_b.hex"),
                 .MFILE("sim/mem/conv1_m0.hex"))
      dut (.clk(clk),.rst_n(rst_n),.start(start),.done(done),
           .in_addr(in_addr),.in_data(in_data),
           .out_addr(out_addr),.out_data(out_data),.out_we(out_we));

    // capture DUT output
    logic [7:0] cap [0:N_OUT-1];
    always_ff @(posedge clk) if (out_we) cap[out_addr] <= out_data;

    integer fd, i, v, errors, first_bad;
    logic [7:0] gold [0:N_OUT-1];

    initial begin
        // load image into input buffer (decimal, one per line)
        fd = $fopen("sim/golden/img00_input.txt","r");
        for (i=0;i<784;i=i+1) begin $fscanf(fd,"%d\n",v); u_in.mem[i]=v[7:0]; end
        $fclose(fd);
        // load golden conv1
        fd = $fopen("sim/golden/img00_conv1.txt","r");
        for (i=0;i<N_OUT;i=i+1) begin $fscanf(fd,"%d\n",v); gold[i]=v[7:0]; end
        $fclose(fd);

        rst_n=0; repeat(4) @(posedge clk); rst_n=1; @(posedge clk);
        start=1; @(posedge clk); start=0;
        wait(done); repeat(3) @(posedge clk);

        errors=0; first_bad=-1;
        for (i=0;i<N_OUT;i=i+1) if (cap[i] !== gold[i]) begin
            errors=errors+1;
            if (first_bad<0) first_bad=i;
        end
        if (errors==0) $display("CONV1: PASS  (%0d/%0d bit-exact)", N_OUT, N_OUT);
        else $display("CONV1: FAIL  %0d mismatches; first at idx %0d got %0d exp %0d",
                       errors, first_bad, cap[first_bad], gold[first_bad]);
        $finish;
    end

    initial begin #20000000 $display("TIMEOUT"); $finish; end
endmodule
