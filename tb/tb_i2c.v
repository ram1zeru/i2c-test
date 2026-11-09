// ============================================================================
// tb_i2c.v  -  self-checking testbench for i2c_maestro + i2c_esclavo
//
// Reproduces the scenarios of the paper's figures:
//   T1 (Fig. 3) : correct write, slave ACKs address and data
//   T2          : read one byte from the slave
//   T3 (Fig. 2) : wrong address -> no ACK -> master issues STOP
//   T4 (Fig. 4) : slave NACKs the data byte -> STOP, lines released
// ============================================================================
`timescale 1ns / 1ps

module tb_i2c;
    reg        clk_50 = 0;
    reg        rst_n  = 0;
    always #10 clk_50 = ~clk_50;          // 50 MHz

    wire sda, scl;
    pullup (sda);                          // external pull-up resistors
    pullup (scl);

    reg        start = 0, rw = 0;
    reg  [6:0] addr  = 7'b0011011;         // slave address used in the paper
    reg  [7:0] data_in = 8'b01011010;      // test data used in the paper
    wire [7:0] data_out;
    wire       busy, done, ack_error;

    reg  [7:0] slv_tx = 8'b11011110;       // test pattern used in the paper
    reg        slv_ack_data = 1'b1;
    wire [7:0] slv_rx;
    wire       slv_rx_valid, slv_match;

    i2c_maestro #(.CLK_HZ(50_000_000), .SCL_HZ(400_000)) u_maestro (
        .clk_50(clk_50), .rst_n(rst_n), .start(start), .rw(rw), .addr(addr),
        .data_in(data_in), .data_out(data_out), .busy(busy), .done(done),
        .ack_error(ack_error), .sda(sda), .scl(scl));

    i2c_esclavo #(.MY_ADDR(7'b0011011)) u_esclavo (
        .clk_50(clk_50), .rst_n(rst_n), .tx_data(slv_tx), .ack_data_en(slv_ack_data),
        .rx_data(slv_rx), .rx_valid(slv_rx_valid), .addr_match(slv_match),
        .sda(sda), .scl(scl));

    integer errors = 0;
    reg     got_rx;
    always @(posedge clk_50) if (slv_rx_valid) got_rx <= 1'b1;

    task run(input r, input [6:0] a, input [7:0] d);
        begin
            got_rx = 1'b0;
            @(posedge clk_50); rw <= r; addr <= a; data_in <= d; start <= 1'b1;
            @(posedge clk_50); start <= 1'b0;
            @(posedge done);
            repeat (200) @(posedge clk_50);
        end
    endtask

    task check(input cond, input [8*48-1:0] msg);
        if (cond) $display("  PASS  %0s", msg);
        else begin $display("  FAIL  %0s", msg); errors = errors + 1; end
    endtask

    initial begin
        $dumpfile("build/tb_i2c.vcd");
        $dumpvars(0, tb_i2c);
        repeat (5) @(posedge clk_50); rst_n = 1;
        repeat (50) @(posedge clk_50);

        $display("T1: write 0x5A to address 0x1B (Fig. 3)");
        run(1'b0, 7'b0011011, 8'b01011010);
        check(!ack_error,             "address and data ACKed");
        check(got_rx && slv_rx == 8'h5A, "slave received 0x5A");

        $display("T2: read from address 0x1B");
        run(1'b1, 7'b0011011, 8'h00);
        check(!ack_error,             "address ACKed");
        check(data_out == 8'hDE,      "master read 0xDE");

        $display("T3: wrong address 0x2B (Fig. 2)");
        run(1'b0, 7'b0101011, 8'hA5);
        check(ack_error,              "address NACK detected");
        check(!got_rx,                "slave did not receive data");

        $display("T4: slave NACKs data (Fig. 4)");
        slv_ack_data = 1'b0;
        run(1'b0, 7'b0011011, 8'h3C);
        check(ack_error,              "data NACK detected");
        check(sda === 1'b1 && scl === 1'b1, "SDA/SCL released (high-Z, pulled up)");
        slv_ack_data = 1'b1;

        if (errors == 0) $display("I2C TEST PASSED");
        else             $display("I2C TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    // measure SCL frequency once
    realtime t0, t1;
    initial begin
        @(posedge rst_n);
        @(posedge scl); @(posedge scl); t0 = $realtime;
        @(posedge scl); t1 = $realtime;
        $display("Measured f_SCL = %0.1f kHz", 1.0e6 / (t1 - t0));
    end

    initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
