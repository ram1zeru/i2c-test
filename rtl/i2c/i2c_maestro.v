// ============================================================================
// i2c_maestro.v  -  I2C master (single-master, 7-bit address, 1 data byte)
//
// Reproduces the structure of the "maestro" module from:
//   T. Leal-del Rio, G. Juarez-Gracia, L. N. Oliva-Moreno,
//   "Implementation of the Communication Protocols SPI and I2C Using a FPGA
//    by the HDL-Verilog Language", Research in Computing Science 75 (2014).
//
//   - contador_div : clock divider counter (from clk_50)
//   - contador_32  : 5-bit "bit slot" counter that sequences the frame
//                    slot 0      : START
//                    slot 1..7   : address A6..A0
//                    slot 8      : R/W
//                    slot 9      : ACK/NACK from slave (address)
//                    slot 10..17 : data D7..D0
//                    slot 18     : ACK/NACK (from slave on write, from master on read)
//                    slot 19     : STOP
//   - SDA/SCL driven open-drain through tri-state (1'bz = released)
//
// Differences from the paper (fixes):
//   * Everything runs synchronously on clk_50 with clock-enable ticks instead
//     of clocking logic on a divided clock -> no derived clocks, easier timing.
//   * Each bit slot is split into 4 quarter phases so START/STOP are generated
//     correctly (SDA only changes while SCL is low, except in START/STOP).
//   * SCL frequency is a parameter: f_SCL = CLK_HZ / (4*QDIV), e.g. 50 MHz/(4*31) = 403 kHz.
//
// Not implemented (same as the paper): multi-master arbitration,
// clock stretching, multi-byte transfers, 10-bit addressing.
// ============================================================================
`timescale 1ns / 1ps

module i2c_maestro #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCL_HZ = 400_000
)(
    input  wire       clk_50,
    input  wire       rst_n,
    input  wire       start,        // 1-cycle pulse: begin a transaction
    input  wire       rw,           // 0 = write, 1 = read
    input  wire [6:0] addr,         // 7-bit slave address
    input  wire [7:0] data_in,      // byte to write
    output reg  [7:0] data_out,     // byte read
    output reg        busy,
    output reg        done,         // 1-cycle pulse at end of transaction
    output reg        ack_error,    // 1 = address or data was NACKed
    inout  wire       sda,
    inout  wire       scl
);
    // ------------------------------------------------------------------ divider
    localparam integer QDIV = (CLK_HZ + 2 * SCL_HZ) / (4 * SCL_HZ); // clk cycles per quarter (rounded)
    localparam integer DW   = (QDIV > 1) ? $clog2(QDIV) : 1;

    reg [DW-1:0] contador_div;
    wire tick = (contador_div == QDIV - 1);

    always @(posedge clk_50 or negedge rst_n)
        if (!rst_n)              contador_div <= 0;
        else if (!busy || tick)  contador_div <= 0;
        else                     contador_div <= contador_div + 1'b1;

    // ------------------------------------------------------------- slot/phase
    localparam [4:0] S_START = 5'd0,  S_RW   = 5'd8,  S_ACK1 = 5'd9,
                     S_D7    = 5'd10, S_D0   = 5'd17, S_ACK2 = 5'd18,
                     S_STOP  = 5'd19;

    reg [4:0] contador_32;   // bit slot counter
    reg [1:0] q;             // quarter phase inside a slot
    reg       sda_oe;        // 1 = pull SDA low
    reg       scl_oe;        // 1 = pull SCL low
    reg [7:0] addr_rw;       // {addr, rw}
    reg [7:0] tx_byte;
    reg       rw_l;

    // open-drain outputs (tri-state buffer of the paper)
    assign sda = sda_oe ? 1'b0 : 1'bz;
    assign scl = scl_oe ? 1'b0 : 1'bz;

    // bit the master must put on SDA in the current slot (1 = release)
    reg bit_out;
    always @* begin
        bit_out = 1'b1;
        if (contador_32 >= 5'd1 && contador_32 <= S_RW)
            bit_out = addr_rw[S_RW - contador_32];
        else if (contador_32 >= S_D7 && contador_32 <= S_D0)
            bit_out = rw_l ? 1'b1 : tx_byte[S_D0 - contador_32];
        else if (contador_32 == S_ACK2)
            bit_out = 1'b1;          // read: master NACKs the single byte
    end

    always @(posedge clk_50 or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; done <= 1'b0; ack_error <= 1'b0;
            contador_32 <= S_START; q <= 2'd0;
            sda_oe <= 1'b0; scl_oe <= 1'b0;          // idle: high impedance
            addr_rw <= 8'h00; tx_byte <= 8'h00; rw_l <= 1'b0;
            data_out <= 8'h00;
        end else begin
            done <= 1'b0;
            if (!busy) begin
                sda_oe <= 1'b0; scl_oe <= 1'b0;
                if (start) begin
                    busy      <= 1'b1;
                    ack_error <= 1'b0;
                    addr_rw   <= {addr, rw};
                    tx_byte   <= data_in;
                    rw_l      <= rw;
                    contador_32 <= S_START;
                    q         <= 2'd0;
                end
            end else if (tick) begin
                q <= q + 1'b1;
                case (contador_32)
                // ---------------------------------------------- START
                S_START: case (q)
                    2'd0: begin sda_oe <= 1'b0; scl_oe <= 1'b0; end // both high
                    2'd1: ;
                    2'd2: sda_oe <= 1'b1;                           // SDA falls, SCL high
                    2'd3: begin scl_oe <= 1'b1; contador_32 <= 5'd1; end
                endcase
                // ---------------------------------------------- STOP
                S_STOP: case (q)
                    2'd0: begin scl_oe <= 1'b1; sda_oe <= 1'b1; end // both low
                    2'd1: scl_oe <= 1'b0;                           // SCL rises
                    2'd2: sda_oe <= 1'b0;                           // SDA rises -> STOP
                    2'd3: begin busy <= 1'b0; done <= 1'b1; contador_32 <= S_START; end
                endcase
                // ---------------------------------------------- ACK from slave
                S_ACK1, S_ACK2: case (q)
                    2'd0: sda_oe <= (contador_32 == S_ACK2 && rw_l) ? ~bit_out : 1'b0;
                    2'd1: scl_oe <= 1'b0;
                    2'd2: if (!(contador_32 == S_ACK2 && rw_l) && sda)
                              ack_error <= 1'b1;                    // NACK seen
                    2'd3: begin
                        scl_oe <= 1'b1;
                        // like Fig. 2 / Fig. 4 of the paper: on NACK go to STOP
                        if (contador_32 == S_ACK1 && ack_error) contador_32 <= S_STOP;
                        else                                    contador_32 <= contador_32 + 1'b1;
                    end
                endcase
                // ---------------------------------------------- address / data bits
                default: case (q)
                    2'd0: sda_oe <= ~bit_out;     // change SDA while SCL low
                    2'd1: scl_oe <= 1'b0;         // SCL rising edge
                    2'd2: if (rw_l && contador_32 >= S_D7 && contador_32 <= S_D0)
                              data_out[S_D0 - contador_32] <= sda;
                    2'd3: begin scl_oe <= 1'b1; contador_32 <= contador_32 + 1'b1; end
                endcase
                endcase
            end
        end
    end
endmodule
