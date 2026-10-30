// Full-system self-checking testbench.
// For all 30 demo images: run inference, compare EVERY layer's output buffer
// against the Python golden vectors (first divergence reported), and check the
// final predicted label. Bit-exact === comparison throughout.
`timescale 1ns/1ps
module tb_top;
    logic clk=0, rst_n=0, start=0;
    logic [4:0] img_sel;
    logic busy, done, layer_valid; logic [2:0] layer_id; logic [3:0] pred; logic [6:0] hex0;
    always #5 clk=~clk;

    cnn_top #(.MEMDIR("sim/mem/")) dut
      (.clk(clk),.rst_n(rst_n),.start(start),.img_sel(img_sel),
       .busy(busy),.done(done),.pred(pred),.hex0(hex0),
       .layer_valid(layer_valid),.layer_id(layer_id));

    integer labels [0:29];
    integer cur_img, total_layer_err, label_ok, i, fd, v;
    integer g [0:5407];
    string names [0:5]; 

    // load golden layer vector for (img,lid) into g[], return size
    function integer load_gold(input integer img, input integer lid);
        integer k, f, x; string nm, path;
        begin
            case (lid) 0:nm="conv1"; 1:nm="pool1"; 2:nm="conv2";
                       3:nm="pool2"; 4:nm="dense1"; 5:nm="logits"; endcase
            case (lid) 0:load_gold=5408; 1:load_gold=1352; 2:load_gold=1936;
                       3:load_gold=400;  4:load_gold=64;   5:load_gold=10; endcase
            path = $sformatf("sim/golden/img%02d_%s.txt", img, nm);
            f = $fopen(path,"r");
            for (k=0;k<load_gold;k=k+1) begin $fscanf(f,"%d\n",x); g[k]=x; end
            $fclose(f);
        end
    endfunction

    // compare DUT buffer for layer lid against g[]
    task check_layer(input integer img, input integer lid);
        integer n, k, errs, first; logic [7:0] dv;
        begin
            n = load_gold(img, lid);
            errs=0; first=-1;
            for (k=0;k<n;k=k+1) begin
                case (lid)
                    0,2,4: dv = dut.bufA.mem[k];
                    1,3:   dv = dut.bufB.mem[k];
                    5:     dv = dut.logits[k];
                endcase
                if (dv !== g[k][7:0]) begin errs=errs+1; if(first<0) first=k; end
            end
            if (errs!=0) begin
                total_layer_err = total_layer_err + errs;
                $display("  img%0d layer %0d(%s): FAIL %0d errs, first idx %0d got %0d exp %0d",
                    img, lid, names[lid], errs, first, $signed(dut.bufA.mem[first]), g[first]);
            end
        end
    endtask

    // monitor: on each layer completion, check it
    always @(posedge clk) if (layer_valid) check_layer(cur_img, layer_id);

    initial begin
        names[0]="conv1"; names[1]="pool1"; names[2]="conv2";
        names[3]="pool2"; names[4]="dense1"; names[5]="logits";
        fd=$fopen("sim/golden/labels.txt","r");
        for (i=0;i<30;i=i+1) begin $fscanf(fd,"%d\n",v); labels[i]=v; end $fclose(fd);

        total_layer_err=0; label_ok=0;
        rst_n=0; repeat(4)@(posedge clk); rst_n=1; repeat(2)@(posedge clk);

        for (i=0;i<30;i=i+1) begin
            cur_img=i; img_sel=i[4:0];
            @(posedge clk); start=1; @(posedge clk); start=0;
            wait(done); @(posedge clk);
            if (pred==labels[i]) label_ok=label_ok+1;
            else $display("  img%0d LABEL MISMATCH: pred %0d exp %0d", i, pred, labels[i]);
            repeat(2)@(posedge clk);
        end

        $display("=====================================================");
        $display("PER-LAYER bit-exact errors (all layers, all imgs): %0d", total_layer_err);
        $display("FINAL LABEL correct: %0d / 30", label_ok);
        if (total_layer_err==0 && label_ok==30)
             $display("RESULT: PASS  -- hardware is bit-exact with the golden model");
        else $display("RESULT: FAIL");
        $display("=====================================================");
        $finish;
    end
    initial begin #2000000000 $display("TIMEOUT"); $finish; end
endmodule
