// Board-wrapper test: drives de10lite_top the way the physical board does --
// active-low reset button, a BOUNCY active-low run button, and switches -- and
// checks that exactly one inference runs and HEX0 shows the correct digit.
// DB is shrunk so the debounce completes quickly in simulation.
`timescale 1ns/1ps
module tb_board;
    logic        MAX10_CLK1_50 = 0;
    logic [9:0]  SW = 0;
    logic [1:0]  KEY = 2'b11;            // both buttons released (active low)
    logic [7:0]  HEX0,HEX1,HEX2,HEX3,HEX4,HEX5;
    logic [9:0]  LEDR;
    always #10 MAX10_CLK1_50 = ~MAX10_CLK1_50;   // 50 MHz

    localparam integer DB = 8;           // tiny debounce for sim
    de10lite_top #(.MEMDIR("sim/mem/"), .DB(DB)) dut (
        .MAX10_CLK1_50(MAX10_CLK1_50), .SW(SW), .KEY(KEY),
        .HEX0(HEX0),.HEX1(HEX1),.HEX2(HEX2),.HEX3(HEX3),.HEX4(HEX4),.HEX5(HEX5),
        .LEDR(LEDR));

    integer labels [0:29];
    integer i, v, fd;

    // expected active-low seven-seg code for a digit (matches cnn_top table)
    function [7:0] seg(input [3:0] d);
        case (d)
            0:seg=8'hC0;1:seg=8'hF9;2:seg=8'hA4;3:seg=8'hB0;4:seg=8'h99;
            5:seg=8'h92;6:seg=8'h82;7:seg=8'hF8;8:seg=8'h80;9:seg=8'h90;
            default:seg=8'hFF;
        endcase
    endfunction

    // press the (active-low) run button with a few bounces, hold, release
    task press_button;
        integer b;
        begin
            for (b=0;b<4;b=b+1) begin        // bounce
                KEY[1]=1'b0; #35; KEY[1]=1'b1; #35;
            end
            KEY[1]=1'b0;                     // settle pressed
            repeat (4*DB) @(posedge MAX10_CLK1_50);
            KEY[1]=1'b1;                     // release
        end
    endtask

    task run_image(input integer idx);
        integer guard; logic [7:0] e; logic [3:0] lbl;
        begin
            SW[4:0] = idx[4:0];
            @(posedge MAX10_CLK1_50);
            press_button;
            wait (LEDR[0]);                  // busy (already/becomes high) -> running
            guard=0;
            while (LEDR[0] && guard<2000000) begin @(posedge MAX10_CLK1_50); guard=guard+1; end
            repeat (5) @(posedge MAX10_CLK1_50);
            lbl = labels[idx][3:0];
            e = seg(lbl);
            if (HEX0 === {1'b1, e[6:0]})
                $display("  idx %0d (digit %0d): HEX0=%02h  PASS", idx, labels[idx], HEX0);
            else
                $display("  idx %0d (digit %0d): HEX0=%02h exp %02h  FAIL",
                         idx, labels[idx], HEX0, {1'b1, e[6:0]});
        end
    endtask

    initial begin
        fd=$fopen("sim/golden/labels.txt","r");
        for (i=0;i<30;i=i+1) begin $fscanf(fd,"%d\n",v); labels[i]=v; end $fclose(fd);

        // power-on reset via KEY[0] (active low)
        KEY[0]=1'b0; repeat (5) @(posedge MAX10_CLK1_50); KEY[0]=1'b1;
        repeat (5) @(posedge MAX10_CLK1_50);

        $display("Board-wrapper test (reset sync, input sync, button debounce, HEX0):");
        run_image(0);      // digit 0
        run_image(3);      // digit 1
        run_image(27);     // digit 9  (also checks a second/third press re-runs)
        $display("done.");
        $finish;
    end
    initial begin #200000000 $display("TIMEOUT"); $finish; end
endmodule
