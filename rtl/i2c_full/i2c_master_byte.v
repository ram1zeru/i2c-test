// ============================================================================
// i2c_master_byte.v  -  I2C master, byte-level command engine
//
// A higher-level host (FSM, CPU, or testbench) issues one command at a time:
//     CMD_START : START, or repeated START (Sr) if the bus is already owned
//     CMD_STOP  : STOP
//     CMD_WRITE : send din[7:0], then read the slave's ACK into ack_out
//     CMD_READ  : read a byte into dout, then send ack_in (0 = ACK, 1 = NACK)
//
// Every bit takes 4 quarter phases of SCL:
//     q0 : SCL low,  SDA set to the new bit
//     q1 : SCL released (high)  -> at its end, wait while a slave stretches SCL
//     q2 : SCL high, SDA was sampled at the start of this phase (mid-high)
//     q3 : SCL pulled low
//
// Features: repeated START, multi-byte read/write, clock stretching
// (master checks that SCL really went high before continuing).
// Not implemented: multi-master arbitration.
// ============================================================================
`timescale 1ns / 1ps

module i2c_master_byte #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer SCL_HZ = 100_000
)(
    input  wire       clk,
    input  wire       rst_n,
    // command interface
    input  wire       cmd_valid,     // 1-cycle pulse, accepted when !busy
    input  wire [1:0] cmd,
    input  wire [7:0] din,
    input  wire       ack_in,        // ACK bit to send after CMD_READ
    output reg        busy,
    output reg        done,          // 1-cycle pulse when a command finishes
    output reg  [7:0] dout,
    output reg        ack_out,       // ACK bit received after CMD_WRITE (0 = ACK)
    // I2C bus (open-drain)
    inout  wire       sda,
    inout  wire       scl
);
    localparam [1:0] CMD_START = 2'd0, CMD_STOP = 2'd1,
                     CMD_WRITE = 2'd2, CMD_READ = 2'd3;

    localparam integer QDIV = (CLK_HZ + 2 * SCL_HZ) / (4 * SCL_HZ);

    // ------------------------------------------------- open-drain drivers
    reg sda_oe, scl_oe;                         // 1 = pull line low
    assign sda = sda_oe ? 1'b0 : 1'bz;
    assign scl = scl_oe ? 1'b0 : 1'bz;

    // ------------------------------------------------- input synchronizers
    reg [1:0] sda_s, scl_s;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin sda_s <= 2'b11; scl_s <= 2'b11; end
        else begin
            sda_s <= {sda_s[0], (sda === 1'b0) ? 1'b0 : 1'b1};
            scl_s <= {scl_s[0], (scl === 1'b0) ? 1'b0 : 1'b1};
        end
    wire sda_in = sda_s[1];
    wire scl_in = scl_s[1];

    // ------------------------------------------------- engine
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_STOP = 2'd2, S_BITS = 2'd3;

    reg [1:0]  st;
    reg [1:0]  q;
    reg [15:0] cnt;
    reg [3:0]  bitn;          // 0..8 inside a byte (8 = ACK bit)
    reg [8:0]  sh;            // bits to send, then bits received
    wire tick = (cnt == QDIV - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; q <= 2'd0; cnt <= 16'd0; bitn <= 4'd0; sh <= 9'h1FF;
            busy <= 1'b0; done <= 1'b0; dout <= 8'h00; ack_out <= 1'b1;
            sda_oe <= 1'b0; scl_oe <= 1'b0;
        end else begin
            done <= 1'b0;

            if (st == S_IDLE) begin
                cnt <= 16'd0;
                q   <= 2'd0;
                if (cmd_valid && !busy) begin
                    busy <= 1'b1;
                    case (cmd)
                    CMD_START: begin st <= S_START; sda_oe <= 1'b0; end   // SDA high first
                    CMD_STOP:  begin st <= S_STOP;  sda_oe <= 1'b1; end   // SDA low first
                    CMD_WRITE: begin st <= S_BITS; bitn <= 4'd0;
                                     sh <= {din, 1'b1};                   // release for ACK
                                     sda_oe <= ~din[7]; end
                    CMD_READ:  begin st <= S_BITS; bitn <= 4'd0;
                                     sh <= {8'hFF, ack_in};               // release for data
                                     sda_oe <= 1'b0; end
                    endcase
                end
            end else if (!tick) begin
                cnt <= cnt + 1'b1;
            end else begin
                cnt <= 16'd0;
                // end of q1: SCL must really be high, otherwise a slave is
                // stretching the clock -> stay in q1 and check again
                if (q == 2'd1 && !scl_in) begin
                    q <= 2'd1;
                end else begin
                    q <= q + 1'b1;
                    case (st)
                    // -------------------------------------------- (repeated) START
                    S_START: case (q)
                        2'd0: scl_oe <= 1'b0;                     // SCL up
                        2'd1: sda_oe <= 1'b1;                     // SDA down while SCL high
                        2'd2: scl_oe <= 1'b1;                     // SCL down
                        2'd3: begin st <= S_IDLE; busy <= 1'b0; done <= 1'b1; end
                    endcase
                    // -------------------------------------------- STOP
                    S_STOP: case (q)
                        2'd0: scl_oe <= 1'b0;                     // SCL up
                        2'd1: sda_oe <= 1'b0;                     // SDA up while SCL high
                        2'd2: ;
                        2'd3: begin st <= S_IDLE; busy <= 1'b0; done <= 1'b1; end
                    endcase
                    // -------------------------------------------- 8 data bits + ACK
                    S_BITS: case (q)
                        2'd0: scl_oe <= 1'b0;                     // SCL up
                        2'd1: sh <= {sh[7:0], sda_in};            // sample in mid-high
                        2'd2: scl_oe <= 1'b1;                     // SCL down
                        2'd3: if (bitn == 4'd8) begin
                                  dout    <= sh[8:1];
                                  ack_out <= sh[0];
                                  st <= S_IDLE; busy <= 1'b0; done <= 1'b1;
                              end else begin
                                  bitn   <= bitn + 1'b1;
                                  sda_oe <= ~sh[8];               // next bit, SCL low
                              end
                    endcase
                    default: st <= S_IDLE;
                    endcase
                end
            end
        end
    end
endmodule
