// ============================================================================
// tb_spi.v  -  self-checking testbench for spi_maestro + spi_esclavo
//
// Runs a full-duplex 8-bit transfer in all four SPI modes (CPOL, CPHA).
// Mode 3 (CPOL=1, CPHA=1) is the configuration stated in the paper (Fig. 1).
// ============================================================================
`timescale 1ns / 1ps

module tb_spi;
    reg clk_50 = 0;
    reg rst_n  = 0;
    always #10 clk_50 = ~clk_50;           // 50 MHz

    reg        start = 0;
    reg  [7:0] m_tx = 8'b01011010;         // master -> slave
    reg  [7:0] s_tx = 8'b11011110;         // slave  -> master

    wire [7:0] m_rx  [0:3];
    wire [7:0] s_rx  [0:3];
    wire [3:0] done, s_valid, sck, mosi, miso, cs_n;

    genvar m;
    generate for (m = 0; m < 4; m = m + 1) begin : g_mode
        spi_maestro #(.SCK_HZ(3_600_000), .CPOL(m[1]), .CPHA(m[0])) u_m (
            .clk_50(clk_50), .rst_n(rst_n), .start(start), .tx_data(m_tx),
            .rx_data(m_rx[m]), .busy(), .done(done[m]), .sck(sck[m]),
            .mosi(mosi[m]), .miso(miso[m]), .cs_n(cs_n[m]));
        spi_esclavo #(.CPOL(m[1]), .CPHA(m[0])) u_s (
            .clk_50(clk_50), .rst_n(rst_n), .tx_data(s_tx), .rx_data(s_rx[m]),
            .rx_valid(s_valid[m]), .sck(sck[m]), .mosi(mosi[m]),
            .miso(miso[m]), .cs_n(cs_n[m]));
    end endgenerate

    // convenient names for the waveform of the paper's mode (mode 3)
    wire CLK_3 = sck[3], MOSI = mosi[3], MISO = miso[3], CS = cs_n[3];

    integer errors = 0, i, k;

    initial begin
        $dumpfile("build/tb_spi.vcd");
        $dumpvars(0, tb_spi);
        repeat (5) @(posedge clk_50); rst_n = 1;
        repeat (20) @(posedge clk_50);

        for (k = 0; k < 3; k = k + 1) begin
            if (k == 1) begin m_tx = 8'hA5; s_tx = 8'h3C; end
            if (k == 2) begin m_tx = 8'hFF; s_tx = 8'h00; end
            @(posedge clk_50) start <= 1'b1;
            @(posedge clk_50) start <= 1'b0;
            wait (&done == 1'b0); @(posedge done[3]);
            repeat (20) @(posedge clk_50);
            for (i = 0; i < 4; i = i + 1) begin
                if (m_rx[i] === s_tx && s_rx[i] === m_tx)
                    $display("  PASS  mode %0d: M->S 0x%02h, S->M 0x%02h", i, s_rx[i], m_rx[i]);
                else begin
                    $display("  FAIL  mode %0d: slave got 0x%02h (exp 0x%02h), master got 0x%02h (exp 0x%02h)",
                             i, s_rx[i], m_tx, m_rx[i], s_tx);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0) $display("SPI TEST PASSED");
        else             $display("SPI TEST FAILED: %0d error(s)", errors);
        $finish;
    end

    realtime t0, t1;
    initial begin
        @(negedge cs_n[0]); @(posedge sck[0]); t0 = $realtime;
        @(posedge sck[0]); t1 = $realtime;
        $display("Measured f_SCK = %0.3f MHz", 1.0e3 / (t1 - t0));
    end

    initial begin #2_000_000; $display("TIMEOUT"); $finish; end
endmodule
