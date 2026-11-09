// ============================================================================
// tb_i2c_full.v  -  I2C bus with one master and two register-file slaves
//
//   slave A : address 0x1B, no clock stretching
//   slave B : address 0x50, clock stretching (holds SCL low ~12 us per byte)
//
//   T1  write 3 bytes to slave A, registers 0x02..0x04
//   T2  read 4 bytes from slave A starting at 0x01 (uses repeated START)
//   T3  address nobody answers (0x2B) -> NACK -> STOP
//   T4  write + read slave B while it stretches the clock
//   T5  bus is released (SDA = SCL = 1) at the end
//
// A passive bus monitor decodes every transfer and prints it, e.g.
//   S 36(1B W) A 02 A 11 A 22 A 33 A P
// ============================================================================
`timescale 1ns / 1ps

module tb_i2c_full;
    reg clk = 0, rst_n = 0;
    always #10 clk = ~clk;                     // 50 MHz

    wire sda, scl;
    pullup (sda);                              // pull-up resistors
    pullup (scl);

    // ------------------------------------------------ master
    reg        cmd_valid = 0;
    reg  [1:0] cmd = 0;
    reg  [7:0] din = 0;
    reg        ack_in = 0;
    wire       busy, done, ack_out;
    wire [7:0] dout;

    localparam [1:0] CMD_START = 2'd0, CMD_STOP = 2'd1, CMD_WRITE = 2'd2, CMD_READ = 2'd3;

    i2c_master_byte #(.CLK_HZ(50_000_000), .SCL_HZ(100_000)) u_master (
        .clk(clk), .rst_n(rst_n), .cmd_valid(cmd_valid), .cmd(cmd), .din(din),
        .ack_in(ack_in), .busy(busy), .done(done), .dout(dout), .ack_out(ack_out),
        .sda(sda), .scl(scl));

    // ------------------------------------------------ slaves
    i2c_slave_regs #(.ADDR(7'h1B), .STRETCH_CYC(0))   u_slave_a (.clk(clk), .rst_n(rst_n), .sda(sda), .scl(scl));
    i2c_slave_regs #(.ADDR(7'h50), .STRETCH_CYC(600)) u_slave_b (.clk(clk), .rst_n(rst_n), .sda(sda), .scl(scl));

    // ------------------------------------------------ host-side tasks
    reg [3:0] test_no = 0;                     // shown in the waveform
    integer   errors  = 0;
    reg [7:0] rbuf [0:15];

    task do_cmd(input [1:0] c, input [7:0] d, input a);
        begin
            @(posedge clk); cmd <= c; din <= d; ack_in <= a; cmd_valid <= 1'b1;
            @(posedge clk); cmd_valid <= 1'b0;
            @(posedge done);
            @(posedge clk);
        end
    endtask

    // returns 1 if every byte was ACKed
    task write_regs(input [6:0] addr, input [7:0] reg_no, input integer n,
                    input [8*16-1:0] data, output ok);
        integer k;
        begin
            ok = 1;
            do_cmd(CMD_START, 0, 0);
            do_cmd(CMD_WRITE, {addr, 1'b0}, 0); if (ack_out) ok = 0;
            if (ok) begin
                do_cmd(CMD_WRITE, reg_no, 0);   if (ack_out) ok = 0;
                for (k = 0; k < n && ok; k = k + 1) begin
                    do_cmd(CMD_WRITE, data[8*(n-1-k) +: 8], 0);
                    if (ack_out) ok = 0;
                end
            end
            do_cmd(CMD_STOP, 0, 0);
        end
    endtask

    task read_regs(input [6:0] addr, input [7:0] reg_no, input integer n, output ok);
        integer k;
        begin
            ok = 1;
            do_cmd(CMD_START, 0, 0);
            do_cmd(CMD_WRITE, {addr, 1'b0}, 0); if (ack_out) ok = 0;
            if (ok) begin
                do_cmd(CMD_WRITE, reg_no, 0);   if (ack_out) ok = 0;
                do_cmd(CMD_START, 0, 0);                         // repeated START
                do_cmd(CMD_WRITE, {addr, 1'b1}, 0); if (ack_out) ok = 0;
                for (k = 0; k < n; k = k + 1) begin
                    do_cmd(CMD_READ, 0, (k == n - 1));           // NACK the last byte
                    rbuf[k] = dout;
                end
            end
            do_cmd(CMD_STOP, 0, 0);
        end
    endtask

    task check(input cond, input [8*56-1:0] msg);
        begin
            if (cond) $display("    PASS  %0s", msg);
            else begin $display("    FAIL  %0s", msg); errors = errors + 1; end
        end
    endtask

    // ------------------------------------------------ bus monitor (passive)
    integer   mon_bits = 0;
    reg [8:0] mon_sh   = 0;
    reg       mon_first = 0, mon_inframe = 0;

    always @(negedge sda) if (rst_n && scl === 1'b1) begin
        $write("\n      [%7.1f us] %0s", $realtime / 1000.0, mon_inframe ? "Sr" : "S");
        mon_bits = 0; mon_first = 1; mon_inframe = 1;
    end
    always @(posedge sda) if (scl === 1'b1 && mon_inframe) begin
        $write(" P"); mon_inframe = 0;
    end
    always @(posedge scl) if (mon_inframe) begin
        mon_sh   = {mon_sh[7:0], (sda === 1'b0) ? 1'b0 : 1'b1};
        mon_bits = mon_bits + 1;
        if (mon_bits == 9) begin
            if (mon_first) $write(" %02h(%02h %s)", mon_sh[8:1], mon_sh[8:2], mon_sh[1] ? "R" : "W");
            else           $write(" %02h", mon_sh[8:1]);
            $write(" %s", mon_sh[0] ? "N" : "A");
            mon_bits = 0; mon_first = 0;
        end
    end

    // ------------------------------------------------ SCL low-time meter
    realtime t_fall = 0, max_low = 0;
    always @(negedge scl) t_fall = $realtime;
    always @(posedge scl) if (t_fall > 0 && $realtime - t_fall > max_low) max_low = $realtime - t_fall;

    // ------------------------------------------------ test sequence
    reg ok;
    initial begin
        $dumpfile("build/tb_i2c_full.vcd");
        $dumpvars(0, tb_i2c_full);
        repeat (5) @(posedge clk); rst_n = 1;
        repeat (100) @(posedge clk);

        test_no = 1;
        $write("\n  T1: ghi 3 byte 11 22 33 vao slave 0x1B, thanh ghi 0x02");
        write_regs(7'h1B, 8'h02, 3, {8'h11, 8'h22, 8'h33}, ok);
        $display("");
        check(ok, "moi byte deu duoc ACK");
        check(u_slave_a.regs[2] == 8'h11 && u_slave_a.regs[3] == 8'h22 &&
              u_slave_a.regs[4] == 8'h33, "thanh ghi 0x02..0x04 = 11 22 33");
        check(u_slave_b.regs[2] == 8'hA2, "slave 0x50 khong bi anh huong");

        test_no = 2;
        $write("\n  T2: doc 4 byte tu slave 0x1B, bat dau tai 0x01 (co Sr)");
        read_regs(7'h1B, 8'h01, 4, ok);
        $display("");
        check(ok, "dia chi va so thanh ghi duoc ACK");
        check(rbuf[0] == 8'hA1 && rbuf[1] == 8'h11 && rbuf[2] == 8'h22 && rbuf[3] == 8'h33,
              "doc duoc A1 11 22 33");

        test_no = 3;
        $write("\n  T3: goi dia chi 0x2B (khong co ai)");
        write_regs(7'h2B, 8'h00, 1, {8'h55}, ok);
        $display("");
        check(!ok, "master thay NACK o byte dia chi");

        check(max_low < 6000.0, "chua co clock stretching: SCL thap < 6 us");
        max_low = 0;

        test_no = 4;
        $write("\n  T4: slave 0x50 keo dai clock (clock stretching)");
        write_regs(7'h50, 8'h0E, 2, {8'hC0, 8'hDE}, ok);
        read_regs(7'h50, 8'h0E, 2, ok);
        $display("");
        check(ok, "giao dich voi slave 0x50 thanh cong");
        check(rbuf[0] == 8'hC0 && rbuf[1] == 8'hDE, "doc lai duoc C0 DE");
        check(max_low > 10000.0, "SCL bi giu thap > 10 us (slave keo dai)");
        $display("    SCL thap lau nhat: %0.1f us", max_low / 1000.0);

        test_no = 5;
        repeat (200) @(posedge clk);
        check(sda === 1'b1 && scl === 1'b1, "bus ranh: SDA = SCL = 1");

        if (errors == 0) $display("\nI2C FULL TEST PASSED");
        else             $display("\nI2C FULL TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
