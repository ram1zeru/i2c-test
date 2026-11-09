// ============================================================================
// i2c_esclavo.v  -  I2C slave (7-bit address, 1 data byte)
//
// Reproduces the "esclavo" module of Leal-del Rio et al. (RCS 75, 2014):
//   - reads SDA on the RISING edge of SCL, drives SDA on the FALLING edge
//   - compares the received address with its own 7-bit address
//   - contador_32 counts SCL rising edges after START:
//        1..8   : address A6..A0 + R/W
//        9      : ACK (driven by slave if address matches)
//        10..17 : data D7..D0 (received on write, sent on read)
//        18     : ACK (slave on write, master on read)
//   - SDA driven open-drain through a tri-state buffer
//
// Fix vs. paper: SDA/SCL are sampled with a 2-FF synchronizer on clk_50 and
// edges are detected in the clk_50 domain (no logic clocked by SCL), START
// and STOP conditions are detected explicitly.
// ============================================================================
`timescale 1ns / 1ps

module i2c_esclavo #(
    parameter [6:0] MY_ADDR = 7'b0011011      // default address used in the paper
)(
    input  wire       clk_50,
    input  wire       rst_n,
    input  wire [7:0] tx_data,      // byte returned on a read
    input  wire       ack_data_en,  // 1 = ACK received data, 0 = NACK (Fig. 4 test)
    output reg  [7:0] rx_data,      // byte received on a write
    output reg        rx_valid,     // 1-cycle pulse when rx_data is updated
    output reg        addr_match,   // high while this slave is addressed
    inout  wire       sda,
    input  wire       scl
);
    // ------------------------------------------------- synchronizer + edges
    reg [2:0] sda_s, scl_s;
    always @(posedge clk_50 or negedge rst_n)
        if (!rst_n) begin sda_s <= 3'b111; scl_s <= 3'b111; end
        else begin
            sda_s <= {sda_s[1:0], (sda === 1'b0) ? 1'b0 : 1'b1};
            scl_s <= {scl_s[1:0], (scl === 1'b0) ? 1'b0 : 1'b1};
        end

    wire scl_rise = (scl_s[2:1] == 2'b01);
    wire scl_fall = (scl_s[2:1] == 2'b10);
    wire scl_hi   = scl_s[1] & scl_s[2];
    wire start_c  = scl_hi && (sda_s[2:1] == 2'b10);   // SDA falls, SCL high
    wire stop_c   = scl_hi && (sda_s[2:1] == 2'b01);   // SDA rises, SCL high
    wire sda_in   = sda_s[1];

    // ------------------------------------------------------------- core
    reg [4:0] contador_32;
    reg [7:0] sh;            // shift register (address or data)
    reg       rw_l;
    reg       active;        // inside a frame (after START)
    reg       sda_oe;        // 1 = pull SDA low
    reg [7:0] tx_l;

    assign sda = sda_oe ? 1'b0 : 1'bz;

    always @(posedge clk_50 or negedge rst_n) begin
        if (!rst_n) begin
            contador_32 <= 5'd0; sh <= 8'h00; rw_l <= 1'b0;
            active <= 1'b0; sda_oe <= 1'b0; addr_match <= 1'b0;
            rx_data <= 8'h00; rx_valid <= 1'b0; tx_l <= 8'h00;
        end else begin
            rx_valid <= 1'b0;

            if (start_c) begin                       // START / repeated START
                active <= 1'b1; addr_match <= 1'b0;
                contador_32 <= 5'd0; sda_oe <= 1'b0;
            end else if (stop_c) begin               // STOP
                active <= 1'b0; addr_match <= 1'b0; sda_oe <= 1'b0;
            end else if (active) begin
                // ---------------- read SDA on SCL rising edge
                if (scl_rise) begin
                    contador_32 <= contador_32 + 1'b1;
                    if (contador_32 + 1'b1 <= 5'd8)
                        sh <= {sh[6:0], sda_in};                       // addr + R/W
                    else if (!rw_l && addr_match &&
                             contador_32 + 1'b1 >= 5'd10 && contador_32 + 1'b1 <= 5'd17)
                        sh <= {sh[6:0], sda_in};                       // data
                end
                // ---------------- drive SDA on SCL falling edge
                if (scl_fall) begin
                    case (contador_32)
                    5'd8: begin
                        if (sh[7:1] == MY_ADDR) begin
                            addr_match <= 1'b1; rw_l <= sh[0];
                            sda_oe <= 1'b1;                            // address ACK
                            tx_l   <= tx_data;
                        end else begin
                            active <= 1'b0;                            // not for us
                        end
                    end
                    5'd9: if (addr_match)
                              sda_oe <= rw_l ? ~tx_l[7] : 1'b0;        // read: D7 / write: release
                    5'd10, 5'd11, 5'd12, 5'd13, 5'd14, 5'd15, 5'd16:
                          if (addr_match && rw_l)
                              sda_oe <= ~tx_l[5'd16 - contador_32];    // D6..D0
                    5'd17: if (addr_match) begin
                              if (rw_l) sda_oe <= 1'b0;                // release for master ACK
                              else begin
                                  sda_oe   <= ack_data_en;             // data ACK / NACK
                                  rx_data  <= sh;
                                  rx_valid <= 1'b1;
                              end
                          end
                    5'd18: sda_oe <= 1'b0;                             // release, wait STOP
                    default: ;
                    endcase
                end
            end
        end
    end
endmodule
