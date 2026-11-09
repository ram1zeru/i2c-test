// ============================================================================
// i2c_slave_regs.v  -  I2C slave with a 16 x 8-bit register file
//
// Behaves like a typical I2C sensor / EEPROM:
//   Write : S | ADDR+W | A | reg | A | data0 | A | data1 | A ... | P
//   Read  : S | ADDR+W | A | reg | A | Sr | ADDR+R | A | data0 | A ... | dataN | NACK | P
//   - the register pointer auto-increments after every byte
//   - the master ACKs each byte it wants more of, NACKs the last one
//   - START / repeated START / STOP are detected at any time
//   - optional clock stretching: after the ACK clock of every byte the slave
//     holds SCL low for STRETCH_CYC clk cycles ("wait, I'm busy")
// ============================================================================
`timescale 1ns / 1ps

module i2c_slave_regs #(
    parameter [6:0]   ADDR        = 7'h1B,
    parameter integer STRETCH_CYC = 0          // 0 = no clock stretching
)(
    input  wire clk,
    input  wire rst_n,
    inout  wire sda,
    inout  wire scl
);
    // ------------------------------------------------- open-drain drivers
    reg sda_oe, scl_oe;
    assign sda = sda_oe ? 1'b0 : 1'bz;
    assign scl = scl_oe ? 1'b0 : 1'bz;

    // ------------------------------------------------- synchronizers + edges
    reg [2:0] sda_s, scl_s;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin sda_s <= 3'b111; scl_s <= 3'b111; end
        else begin
            sda_s <= {sda_s[1:0], (sda === 1'b0) ? 1'b0 : 1'b1};
            scl_s <= {scl_s[1:0], (scl === 1'b0) ? 1'b0 : 1'b1};
        end
    wire scl_rise = (scl_s[2:1] == 2'b01);
    wire scl_fall = (scl_s[2:1] == 2'b10);
    wire scl_hi   = scl_s[2] & scl_s[1];
    wire start_c  = scl_hi && (sda_s[2:1] == 2'b10);
    wire stop_c   = scl_hi && (sda_s[2:1] == 2'b01);
    wire sda_in   = sda_s[1];

    // ------------------------------------------------- register file
    reg [7:0] regs [0:15];
    reg [3:0] ptr;
    integer i;

    // ------------------------------------------------- protocol FSM
    localparam [2:0] ST_IDLE   = 3'd0,   // wait for START
                     ST_ADDR   = 3'd1,   // receiving address byte
                     ST_PTR    = 3'd2,   // receiving register number
                     ST_WDATA  = 3'd3,   // receiving data bytes
                     ST_TXLOAD = 3'd4,   // address ACKed for a read
                     ST_TX     = 3'd5;   // sending data bytes

    reg [2:0]  st;
    reg [3:0]  bitc;        // SCL rising edges inside the current byte (1..9)
    reg [7:0]  rsh;         // receive shift register
    reg [7:0]  tsh;         // transmit byte
    reg        m_ack;       // ACK bit from master during a read
    reg [15:0] str_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= ST_IDLE; bitc <= 4'd0; rsh <= 8'h00; tsh <= 8'h00; m_ack <= 1'b1;
            ptr <= 4'd0; sda_oe <= 1'b0; scl_oe <= 1'b0; str_cnt <= 16'd0;
            for (i = 0; i < 16; i = i + 1) regs[i] <= 8'hA0 + i[7:0];
        end else begin
            // ---------------- clock stretching timer
            if (scl_oe) begin
                if (str_cnt == 16'd0) scl_oe <= 1'b0;
                else                  str_cnt <= str_cnt - 1'b1;
            end

            if (start_c) begin                                   // START or Sr
                st <= ST_ADDR; bitc <= 4'd0; sda_oe <= 1'b0;
            end else if (stop_c) begin                           // STOP
                st <= ST_IDLE; bitc <= 4'd0; sda_oe <= 1'b0;
            end else if (st != ST_IDLE) begin
                // ============ SCL rising edge: read SDA
                if (scl_rise) begin
                    bitc <= bitc + 1'b1;
                    if (bitc < 4'd8 && st != ST_TX && st != ST_TXLOAD)
                        rsh <= {rsh[6:0], sda_in};
                    if (bitc == 4'd8 && st == ST_TX)
                        m_ack <= sda_in;                         // 0 = master wants more
                end
                // ============ SCL falling edge: drive SDA
                if (scl_fall) begin
                    if (bitc == 4'd8) begin
                        // ---- a byte has just been shifted: ACK it (or release)
                        case (st)
                        ST_ADDR: if (rsh[7:1] == ADDR) begin
                                     sda_oe <= 1'b1;             // address ACK
                                     st <= rsh[0] ? ST_TXLOAD : ST_PTR;
                                 end else begin
                                     st <= ST_IDLE;              // not for us
                                 end
                        ST_PTR:   begin ptr <= rsh[3:0]; sda_oe <= 1'b1; st <= ST_WDATA; end
                        ST_WDATA: begin regs[ptr] <= rsh; ptr <= ptr + 1'b1; sda_oe <= 1'b1; end
                        ST_TX:    sda_oe <= 1'b0;                // let master ACK/NACK
                        default:  ;
                        endcase
                    end else if (bitc == 4'd9) begin
                        // ---- end of the ACK clock
                        bitc <= 4'd0;
                        case (st)
                        ST_TXLOAD: begin
                            tsh <= regs[ptr]; sda_oe <= ~regs[ptr][7]; st <= ST_TX;
                        end
                        ST_TX: if (!m_ack) begin                 // ACK: send next byte
                                   tsh <= regs[ptr + 1'b1];
                                   sda_oe <= ~regs[ptr + 1'b1][7];
                                   ptr <= ptr + 1'b1;
                               end else begin                    // NACK: done, wait P/Sr
                                   ptr <= ptr + 1'b1;
                                   sda_oe <= 1'b0;
                                   st <= ST_IDLE;
                               end
                        default: sda_oe <= 1'b0;                 // release after our ACK
                        endcase
                        if (STRETCH_CYC > 0) begin               // "wait, I'm busy"
                            scl_oe  <= 1'b1;
                            str_cnt <= STRETCH_CYC;
                        end
                    end else if (st == ST_TX) begin
                        sda_oe <= ~tsh[4'd7 - bitc];             // bits 6..0
                    end
                end
            end
        end
    end
endmodule
