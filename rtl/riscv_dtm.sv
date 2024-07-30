
//!
//! **PROJECT:**             System_Verilog_Hardware_Common_Lib
//!
//! **LANGUAGE:**            SystemVerilog
//!
//! **FILE:**                riscv_dtm.sv
//!
//! **AUTHOR(S):**
//!
//!   - Alejandro Tafalla Quílez - atafalla@bsc.es
//!
//! **CONTRIBUTORS:**
//!
//!   -
//!
//! **REVISION:**
//!   * 0.0.1 - Initial release. 2024-05-30
//!
//!
//! *Library compliance:*
//!
//! | Doc | Schematic | TB | ASRT |Params. Val.| Sintesys test| Unify Interface| Functional Model |
//! |-----|-----------|----|------|------------|--------------|----------------|------------------|
//! |  x  |     x     |  x |   x  |     x      |       x      |        x       |         x        |
//!
//!

//! Module Functionality
//! --------------------
//! ## Data Path
//! Diagram of the Module
//! This combinational module simply forwards the input to the output
//! without doing anything else.
module riscv_dtm(
    input   logic tms_i,
    input   logic tck_i,
    input   logic trst_i,
    input   logic tdi_i,
    output  logic tdo_o,
    output  logic tdo_driven_o,
    input   logic [31:0] idcode_i,


    output  logic                       req_valid_o,
    input   logic                       req_ready_i,
    output  logic [riscv_dm_pkg::DMI_ADDR_WIDTH-1:0]  req_addr_o,
    output  logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]  req_data_o,
    output  logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]    req_op_o,

    input   logic                       resp_valid_i,
    output  logic                       resp_ready_o,
    input   logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]  resp_data_i,
    input   logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]    resp_op_i
);

// jtag signals
logic tdo;
logic shift_dr, pause_dr, update_dr, capture_dr;
logic dtmcs_select, dmi_select;



// dtm signals

riscv_dm_pkg::dmi_t dmi_in;

logic dmi_tdi, dtmcs_tdi;

logic dtmcs_clear_sticky, dtmcs_hard_reset;

logic [1:0]                 dmi_op_out, dmi_op_out_next;
logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]  dmi_data_out, dmi_data_out_next;


// TODO: Replace with our own JTAG tap implementation
jtag_tap jtag_tap_inst(
    .tms_pad_i(tms_i),
    .tck_pad_i(tck_i),
    .trst_pad_i(trst_i),
    .tdi_pad_i(tdi_i),
    .tdo_pad_o(tdo_o),
    .tdo_padoe_o(tdo_driven_o),

    .tdo_o(tdo),

    .shift_dr_o(shift_dr),
    .pause_dr_o(pause_dr),
    .update_dr_o(update_dr),
    .capture_dr_o(capture_dr),

    // Select signals for boundary scan or mbist
    .extest_select_o(),
    .sample_preload_select_o(),
    .mbist_select_o(),
    .debug_select_o(),
    .dtmcs_select_o(dtmcs_select),
    .dmi_select_o(dmi_select),

    .debug_tdi_i(1'b0),
    .bs_chain_tdi_i(1'b0),
    .mbist_tdi_i(1'b0),
    .dtmcs_tdi_i(dtmcs_tdi),
    .dmi_tdi_i(dmi_tdi),

    .idcode_i(idcode_i)
);

typedef enum logic [1:0] {
    DMI_IDLE,
    DMI_EXEC,
    DMI_EXEC_WAIT
} dmi_state_t;

dmi_state_t dmi_state, dmi_state_next;


// dmi JTAG reg handling
logic [riscv_dm_pkg::DMI_WIDTH-1:0]   dmi_reg;

logic shift_dmi, update_dmi, capture_dmi;

assign shift_dmi = dmi_select & shift_dr;
assign update_dmi = dmi_select & update_dr;
assign capture_dmi = dmi_select & capture_dr;

assign dmi_tdi = dmi_reg[0];
always_ff @( posedge tck_i or posedge trst_i) begin
    if (trst_i) begin
        dmi_reg <= 0;
    end else begin
        if (shift_dmi) begin
            dmi_reg <= {tdo, dmi_reg[riscv_dm_pkg::DMI_WIDTH-1:1]};
        end else if (capture_dmi) begin             // latching occurs in falling edge
            if (dmi_state != DMI_IDLE) begin
                dmi_reg[riscv_dm_pkg::DMI_OP_WIDTH-1:0]                              <= riscv_dm_pkg::RD_OP_BUSY;
            end else begin
                dmi_reg[riscv_dm_pkg::DMI_OP_WIDTH-1:0]                              <= dmi_op_out;
                dmi_reg[riscv_dm_pkg::DMI_DATA_WIDTH+riscv_dm_pkg::DMI_OP_WIDTH-1:2] <= dmi_data_out;
            end
        end else begin
            dmi_reg <= dmi_reg;
        end
    end
end

always_ff @( negedge tck_i or posedge trst_i) begin
    if (trst_i) begin
        dmi_in <= 0;
    end else begin
        if (update_dmi) begin
            dmi_in <= dmi_reg;
        end
    end
end


// ===== DMI register management =====

always_ff @( posedge tck_i or posedge trst_i) begin
    if(trst_i) begin
        dmi_state <= DMI_IDLE;
        dmi_op_out <= 0;
        dmi_data_out <= 0;
    end else if (dtmcs_hard_reset) begin
        dmi_state <= DMI_IDLE;
        dmi_op_out <= 0;
        dmi_data_out <= 0;
    end else begin
        dmi_state <= dmi_state_next;
        dmi_data_out <= dmi_data_out_next;

        if (dtmcs_clear_sticky) begin
            dmi_op_out <= riscv_dm_pkg::RD_OP_SUCCESS;
        end else begin
            dmi_op_out <= dmi_op_out_next;
        end
    end
end

assign req_addr_o = dmi_in.addr;
assign req_data_o = dmi_in.data;
assign req_op_o   = dmi_in.op;

// DMI state machine
always_comb begin
    req_valid_o = 1'b0;
    resp_ready_o = 1;


    dmi_state_next = dmi_state;
    dmi_op_out_next = dmi_op_out;
    dmi_data_out_next = dmi_data_out;

    case (dmi_state)
        DMI_IDLE: begin
            if (update_dmi & ~dmi_op_out[1]) begin
                dmi_state_next = DMI_EXEC;
            end
        end
        DMI_EXEC: begin
            req_valid_o = 1'b1;
            resp_ready_o = 0;

            if (capture_dmi) begin
                dmi_op_out_next = riscv_dm_pkg::RD_OP_BUSY;
            end

            if (req_ready_i) begin
                dmi_state_next = DMI_EXEC_WAIT;
            end
        end
        DMI_EXEC_WAIT: begin
            resp_ready_o = 1;
            // wait readback from JTAG
            if (resp_valid_i) begin
                dmi_data_out_next = resp_data_i;
                if (~dmi_op_out[1]) // only update op if previous value is not sticky
                    dmi_op_out_next = resp_op_i;
                dmi_state_next = DMI_IDLE;
            end

            if (~dmi_op_out[1] & capture_dmi) begin
                dmi_op_out_next = riscv_dm_pkg::RD_OP_BUSY;
            end
        end
        default: ;
    endcase
end



// ===== DTMCS register management =====
riscv_dm_pkg::dtmcs_t dtmcs_read, dtmcs_write;
logic [riscv_dm_pkg::DTMCS_WIDTH-1:0] dtmcs_reg;

logic shift_dtmcs, update_dtmcs, capture_dtmcs;
assign shift_dtmcs = dtmcs_select & shift_dr;
assign update_dtmcs = dtmcs_select & update_dr;
assign capture_dtmcs = dtmcs_select & capture_dr;

assign dtmcs_tdi = dtmcs_reg[0];
always_ff @( posedge tck_i or posedge trst_i) begin
    if (trst_i) begin
        dtmcs_reg <= 32'd0;
    end else begin
        if (shift_dtmcs) begin
            dtmcs_reg <= {tdo, dtmcs_reg[riscv_dm_pkg::DTMCS_WIDTH-1:1]};
        end else if (capture_dtmcs) begin
            dtmcs_reg <= dtmcs_read;
        end
    end
end

assign dtmcs_write = dtmcs_reg;

always_comb begin
    dtmcs_clear_sticky = 0;
    dtmcs_hard_reset = 0;

    if (update_dtmcs) begin
        if (dtmcs_write.dmireset) begin
            dtmcs_clear_sticky = 1;     // clear sticky bit with reset
        end

        if (dtmcs_write.dtmhardreset) begin
            dtmcs_hard_reset = 1;
        end
    end
end

always_comb begin
    dtmcs_read.errinfo = 0;
    dtmcs_read._pad1 = 0;
    dtmcs_read._pad2 = 0;
    dtmcs_read.dtmhardreset = 0;
    dtmcs_read.dmireset = 0;
    dtmcs_read.idle = riscv_dm_pkg::DTM_IDLE_CYCLES;
    dtmcs_read.dmistat = dmi_op_out;
    dtmcs_read.abits = riscv_dm_pkg::DTM_ADDR_BITS;
    dtmcs_read.version = riscv_dm_pkg::DTM_VERSION;
end

endmodule
