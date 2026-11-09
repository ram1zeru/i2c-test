// ============================================================================
// spi_esclavo.v  -  SPI slave, full duplex, N-bit frame, all 4 SPI modes
//
// SCK / MOSI / CS_n are synchronized to clk_50 (2-FF) and edges are detected
// in the clk_50 domain, so clk_50 must be >= ~8x f_SCK (50 MHz vs 3.57 MHz OK).
// MISO is tri-stated while CS_n is high so several slaves can share it.
// ============================================================================
`timescale 1ns / 1ps

module spi_esclavo #(
    parameter integer N    = 8,
    parameter         CPOL = 1'b1,
    parameter         CPHA = 1'b1
)(
    input  wire         clk_50,
    input  wire         rst_n,
    input  wire [N-1:0] tx_data,     // byte to send back to the master
    output reg  [N-1:0] rx_data,
    output reg          rx_valid,    // 1-cycle pulse at the end of a frame
    input  wire         sck,
    input  wire         mosi,
    output wire         miso,
    input  wire         cs_n
);
    reg [2:0] sck_s, cs_s;
    reg [1:0] mosi_s;
    always @(posedge clk_50 or negedge rst_n)
        if (!rst_n) begin sck_s <= {3{CPOL}}; cs_s <= 3'b111; mosi_s <= 2'b00; end
        else begin
            sck_s  <= {sck_s[1:0], sck};
            cs_s   <= {cs_s[1:0], cs_n};
            mosi_s <= {mosi_s[0], mosi};
        end

    wire sck_rise = (sck_s[2:1] == 2'b01);
    wire sck_fall = (sck_s[2:1] == 2'b10);
    wire leading  = CPOL ? sck_fall : sck_rise;
    wire trailing = CPOL ? sck_rise : sck_fall;
    wire smp_edge = CPHA ? trailing : leading;
    wire sh_edge  = CPHA ? leading  : trailing;
    wire cs_rise  = (cs_s[2:1] == 2'b01);
    wire selected = ~cs_s[1];

    reg [N-1:0] tx_sh, rx_sh;
    reg         first;               // first shift edge (skipped when CPHA=1)

    assign miso = cs_n ? 1'bz : tx_sh[N-1];

    always @(posedge clk_50 or negedge rst_n) begin
        if (!rst_n) begin
            tx_sh <= 0; rx_sh <= 0; rx_data <= 0; rx_valid <= 1'b0; first <= 1'b1;
        end else begin
            rx_valid <= 1'b0;
            if (!selected) begin
                // keep the shift register loaded while deselected, so MISO is
                // valid immediately when CS_n falls (needed for CPHA = 0)
                tx_sh <= tx_data; first <= 1'b1;
            end else begin
                if (smp_edge) rx_sh <= {rx_sh[N-2:0], mosi_s[1]};
                if (sh_edge) begin
                    first <= 1'b0;
                    if (!(CPHA && first)) tx_sh <= {tx_sh[N-2:0], 1'b0};
                end
            end
            if (cs_rise) begin
                rx_data  <= rx_sh;
                rx_valid <= 1'b1;
            end
        end
    end
endmodule
