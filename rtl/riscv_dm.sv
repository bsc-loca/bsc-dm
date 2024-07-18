
//!
//! **PROJECT:**             System_Verilog_Hardware_Common_Lib
//!
//! **LANGUAGE:**            SystemVerilog
//!
//! **FILE:**                riscv_dm.sv
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
//!   * 0.0.1 - Initial release. 2024-06-11
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
//! The address space of the memory-mapped program and buffer is of 4B * (PROGRAM_SIZE+DATA_SIZE+1). The extra word is
//! needed for being able to send implicit ebreak instructions when the core reaches the end of the program, both as
//! a safeguard and as a way of not wasting one word with the ebrea instruction for getting out of debug mode

module riscv_dm #(
    parameter  integer unsigned NUM_HARTS        = 1,                //! Number of harts connected to the Debug Module
    parameter  integer unsigned PROGRAM_SIZE     = 4,                //! program buffer size, in words
    parameter  integer unsigned DATA_SIZE        = 4,                //! data buffer size, in words
    parameter  integer unsigned WORD_SIZE        = 4,                //! word size, in bytes
    parameter  integer unsigned NUM_PHYS_REGS    = 64,               //! Maximum number of physical registers for all the cores

    localparam integer unsigned XLEN             = 64,
    localparam integer unsigned PHYS_REG_BITS    = $clog2(NUM_PHYS_REGS),
    localparam integer unsigned NUM_LOGI_REGS    = 32,
    localparam integer unsigned LOGI_REG_BITS    = $clog2(NUM_LOGI_REGS),

    localparam integer unsigned BYTE_SEL_BITS    = $clog2(WORD_SIZE),
    localparam integer unsigned MEMORY_SEL_BITS  = $clog2(PROGRAM_SIZE + DATA_SIZE + 1),
    localparam integer unsigned BPW              = 8,
    localparam integer unsigned ADDR_WIDTH       = 64,
    localparam integer unsigned DATA_WIDTH       = 64 //! Size of the SRI data channel
) (
    input   logic                                       clk_i,      //! Clock signal
    input   logic                                       rstn_i,     //! Reset signal (active low)


    // DTM interface
    //! @virtualbus dmi @dir in
    input   logic                                       req_valid_i,
    output  logic                                       req_ready_o,
    input   logic [riscv_dm_pkg::DMI_ADDR_WIDTH-1:0]    req_addr_i,
    input   logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]    req_data_i,
    input   logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]      req_op_i,

    output  logic                                       resp_valid_o,
    input   logic                                       resp_ready_i,
    output  logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]    resp_data_o,
    output  logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]      resp_op_o,
    //! @end

    //TODO: replace all buses with structs/interfaces
    // Hart run control signals
    //! @virtualbus hartctl @dir in
    output logic [NUM_HARTS-1:0]   resume_request_o,
    input  logic [NUM_HARTS-1:0]   resume_ack_i,
    input  logic [NUM_HARTS-1:0]   running_i,

    output logic [NUM_HARTS-1:0]   halt_request_o,
    input  logic [NUM_HARTS-1:0]   halted_i,

    output logic [NUM_HARTS-1:0]   progbuf_run_req_o,
    input  logic [NUM_HARTS-1:0]   progbuf_run_ack_i,
    input  logic [NUM_HARTS-1:0]   progbuf_xcpt_i,
    input  logic [NUM_HARTS-1:0]   parked_i,

    output logic [NUM_HARTS-1:0]   halt_on_reset_o,
    output logic [NUM_HARTS-1:0]   hart_reset_o,
    input  logic [NUM_HARTS-1:0]   havereset_i,

    input  logic [NUM_HARTS-1:0]   unavail_i,
    //! @end

    // Register read abstract command signals
    //! @virtualbus regfilebus @dir in
    output logic  [NUM_HARTS-1:0]                      rnm_read_en_o   ,    //! Request reading the rename table
    output logic [NUM_HARTS-1:0][LOGI_REG_BITS-1:0]    rnm_read_reg_o  ,    //! Logical register for which the mapping is read
    input  logic [NUM_HARTS-1:0][PHYS_REG_BITS-1:0]    rnm_read_resp_i ,    //! Physical register mapped to the requested logical register

    output logic  [NUM_HARTS-1:0]                      rf_en_o         ,    //! Read enable for the register file
    output logic [NUM_HARTS-1:0][PHYS_REG_BITS-1:0]    rf_preg_o       ,    //! Target physical register in the register file
    input  logic [NUM_HARTS-1:0][XLEN-1:0]             rf_rdata_i      ,    //! Data read from the register file

    output logic  [NUM_HARTS-1:0]                      rf_we_o         ,    //! Write enable for the register file
    output logic [NUM_HARTS-1:0][XLEN-1:0]             rf_wdata_o      ,    //! Data to write to the register file
    //! @end


    // SRI interface for program buffer
    //! @virtualbus sri @dir in
    input  logic [ADDR_WIDTH-1:0]                       sri_addr_i,     //! register interface address
    input  logic                                        sri_en_i,       //! register interface enable
    input  logic [DATA_WIDTH-1:0]                       sri_wdata_i,    //! register interface data to write
    input  logic                                        sri_we_i,       //! register interface write enable
    input  logic [BPW-1:0]                              sri_be_i,       //! register interface byte enable
    output logic [DATA_WIDTH-1:0]                       sri_rdata_o,    //! register interface read data
    output logic                                        sri_error_o     //! register interface error
    //! @end
);

logic rnm_read_en;
logic [LOGI_REG_BITS-1:0] rnm_read_reg;
logic [PHYS_REG_BITS-1:0] rnm_read_resp;
logic rf_en;
logic [PHYS_REG_BITS-1:0] rf_preg;
logic [XLEN-1:0] rf_rdata;
logic rf_we;
logic [XLEN-1:0] rf_wdata;

localparam integer unsigned NUM_HART_BITS = $clog2(NUM_HARTS);
localparam integer unsigned PROGBUF_BEGIN = 0;
localparam integer unsigned PROGBUF_END = PROGRAM_SIZE - 1;
localparam integer unsigned DATABUF_BEGIN = PROGRAM_SIZE;
localparam integer unsigned DATABUF_END =  DATABUF_BEGIN + DATA_SIZE - 1;


typedef enum logic [3:0] {
    IDLE,
    NOP,
    READ,
    WRITE,
    ABSTRACT_CMD_REG_READ_RENAME,
    ABSTRACT_CMD_REG_READ_DATA,
    EXEC_PROGBUF_WAIT_START,
    EXEC_PROGBUF_WAIT_EBREAK
} dm_state_t;

dm_state_t  dm_state,
            dm_state_next,
            dm_state_op_next;

logic [NUM_HARTS-1:0]   resumereqs, resumereqs_next,
                        haltreqs, haltreqs_next,
                        resethaltreqs, resethaltreqs_next,
                        hartresets, hartresets_next;

logic [19:0] hartsel, hartsel_next;

assign halt_request_o = haltreqs;
assign resume_request_o = resumereqs;
assign hart_reset_o = {NUM_HARTS{dmcontrol.ndmreset}} | hartresets;
assign halt_on_reset_o = resethaltreqs;

// ===== hartinfo register =====

riscv_dm_pkg::hartinfo_t    hartinfo;

assign hartinfo._pad1 = '0;
assign hartinfo._pad2 = '0;
assign hartinfo.nscratch = 4'd0;
assign hartinfo.dataaccess = 1'b1;  // memory-mapped data regs
assign hartinfo.datasize = 4'(DATA_SIZE);
assign hartinfo.dataaddr = 12'h0;


// ===== dmstatus register =====
riscv_dm_pkg::dmstatus_t dmstatus;


logic [NUM_HARTS-1:0]   sticky_resume_ack,  sticky_resume_ack_next,
                        sticky_unavail,     sticky_unavail_next,
                        sticky_havereset,   sticky_havereset_next;

// TODO: parametrize
assign dmstatus._pad1 = '0;
assign dmstatus._pad2 = '0;

assign dmstatus.ndmresetpending = 0;
assign dmstatus.stickyunavail   = 1'b1;
assign dmstatus.impebreak       = 1'b0;

assign dmstatus.allhavereset    = sticky_havereset[hartsel];
assign dmstatus.anyhavereset    = sticky_havereset[hartsel];

assign dmstatus.allresumeack    = sticky_resume_ack[hartsel];
assign dmstatus.anyresumeack    = sticky_resume_ack[hartsel];

assign dmstatus.anynonexistent   = hartsel >= NUM_HARTS;
assign dmstatus.allnonexistent  = hartsel >= NUM_HARTS;

assign dmstatus.allunavail      = sticky_unavail[hartsel];
assign dmstatus.anyunavail      = sticky_unavail[hartsel];

assign dmstatus.allrunning      = running_i[hartsel];
assign dmstatus.anyrunning      = running_i[hartsel];

assign dmstatus.allhalted       = halted_i[hartsel];
assign dmstatus.anyhalted       = halted_i[hartsel];

assign dmstatus.authenticated   = 1;
assign dmstatus.authbusy        = 1'b0;

assign dmstatus.hasresethaltreq = 1'b1;
assign dmstatus.confstrptrvalid = 0;
assign dmstatus.version         = 4'd3;



// ===== DM registers =====
riscv_dm_pkg::dmcontrol_t   dmcontrol_i,
                            dmcontrol,
                            dmcontrol_next;

riscv_dm_pkg::abstractcs_t  abstractcs_i,
                            abstractcs,
                            abstractcs_next;

riscv_dm_pkg::command_t     command_i,
                            command,
                            command_next;

riscv_dm_pkg::abstractauto_t    abstractauto_i,
                                abstractauto,
                                abstractauto_next;

// Req data casting
assign abstractcs_i     = req_data_i;
assign command_i        = req_data_i;
assign dmcontrol_i      = req_data_i;
assign abstractauto_i   = req_data_i;

// Abstractcs read only regs
assign abstractcs_next._pad1 = 0;
assign abstractcs_next._pad2 = 0;
assign abstractcs_next._pad3 = 0;
assign abstractcs_next.progbufsize = 5'(PROGRAM_SIZE);
assign abstractcs_next.busy = 0;
assign abstractcs_next.relaxedpriv = 1;
assign abstractcs_next.datacount = 4'(DATA_SIZE);

assign rnm_read_reg = command.control.regno[LOGI_REG_BITS-1:0]; //extract register bits

// ===== program buffer register =====
logic prog_data_buf_we;
logic [PROGRAM_SIZE+DATA_SIZE-1:0][WORD_SIZE*8-1:0] prog_data_buf, prog_data_buf_next;

logic abstract_cmd;

logic [3:0] autodata_idx;
logic autodata_exec;


assign autodata_idx = req_addr_i[3:0] - 4'd4;
assign autodata_exec = abstractauto.autoexecdata[autodata_idx];

always_comb begin
    hartsel_next = hartsel;
    dm_state_next = dm_state;
    dmcontrol_next = dmcontrol;
    dmcontrol_next.hasel = 0;   // TODO: 0 only allowed for now
    dmcontrol_next.resumereq = 0;
    dmcontrol_next.ackhavereset = 0;
    dmcontrol_next.ackunavail = 0;
    dmcontrol_next.hartselhi = 0;
    dmcontrol_next.hartsello = 0;
    dmcontrol_next.setkeepalive = 0;
    dmcontrol_next.clrkeepalive = 0;
    dmcontrol_next.ndmreset = dmcontrol.ndmreset;
    abstractcs_next.cmderr = abstractcs.cmderr;
    abstractauto_next = abstractauto;
    req_ready_o = 0;
    resp_valid_o = 0;
    resp_op_o = 0; // err
    prog_data_buf_we = 0;
    dm_state_op_next = IDLE;
    command_next = command;
    prog_data_buf_next = prog_data_buf;
    abstract_cmd = 0;
    progbuf_run_req_o = 'b0;
    resumereqs_next = resumereqs & ~resume_ack_i; // Clear ack'd requests
    haltreqs_next = haltreqs;
    hartresets_next = hartresets;
    resethaltreqs_next = resethaltreqs;

    // sticky bits
    sticky_resume_ack_next = sticky_resume_ack | resume_ack_i;
    sticky_havereset_next = sticky_havereset | havereset_i;
    sticky_unavail_next = sticky_unavail | unavail_i;

    // rnm defaults
    rnm_read_en = 'b0;

    // rf defaults
    rf_en = 'b0;
    rf_we = 'b0;
    rf_preg = 'b0;
    rf_wdata = 'b0;

    // DMI signals
    resp_data_o = 32'd0;

    case (dm_state)
        IDLE: begin
            req_ready_o = 1;
            if (req_valid_i) begin
                case (req_op_i)
                    riscv_dm_pkg::WR_OP_NOP: dm_state_next = NOP;
                    riscv_dm_pkg::WR_OP_WR: dm_state_next = WRITE;
                    riscv_dm_pkg::WR_OP_RD: dm_state_next = READ;
                    default:;
                endcase
            end
        end
        NOP: begin
            resp_op_o = 0;
            resp_valid_o = 1;
            if (resp_ready_i)
                dm_state_next = IDLE;
        end
        READ: begin
            case (req_addr_i[5:0]) inside
                riscv_dm_pkg::DMCONTROL: begin
                    resp_data_o = dmcontrol;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::DMCS2: begin
                    resp_data_o = 32'd0;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::DMSTATUS: begin
                    resp_data_o = dmstatus;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::HARTINFO: begin
                    resp_data_o = 32'd0;    // TODO: not implemented
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::COMMAND: begin // (WARZ)
                    resp_data_o = 32'd0;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::ABSTRACTCS: begin
                    resp_data_o = abstractcs;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::ABSTRACTAUTO: begin
                    resp_data_o = abstractauto;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::HAWINDOWSEL: begin // TODO: not implemented (WARL)
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::HAWINDOW: begin // TODO: not implemented (WARL)
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                [riscv_dm_pkg::DATA0:riscv_dm_pkg::DATA0+DATA_SIZE-1]: begin
                    resp_data_o = prog_data_buf[req_addr_i[4:0]];
                    resp_op_o = 0;
                    resp_valid_o = 1;
                    if (abstractauto.autoexecdata[autodata_idx]) begin
                        abstract_cmd = 1;
                        dm_state_next = ABSTRACT_CMD_REG_READ_RENAME;
                    end
                end
                [riscv_dm_pkg::PROGBUF0:riscv_dm_pkg::PROGBUF0+PROGRAM_SIZE-1]: begin
                    resp_data_o = prog_data_buf[req_addr_i[4:0]];
                    resp_op_o = 0;
                    resp_valid_o = 1;
                    if (abstractauto.autoexecdata[autodata_idx]) begin
                        abstract_cmd = 1;
                        dm_state_next = ABSTRACT_CMD_REG_READ_RENAME;
                    end
                end
                riscv_dm_pkg::SBCS: begin
                    resp_data_o = 32'd0;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                default: begin
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
            endcase

            if (resp_ready_i && ~abstract_cmd) begin
                dm_state_next = IDLE;
            end else if (abstract_cmd) begin
                dm_state_next = ABSTRACT_CMD_REG_READ_RENAME;
            end
        end
        WRITE: begin
            resp_data_o = 0;
            dm_state_op_next = IDLE;

            case (req_addr_i[5:0]) inside
                riscv_dm_pkg::DMCONTROL: begin
                    // individual hartsel handling
                    hartsel_next = (NUM_HARTS == 1) ? 0 : {dmcontrol_i.hartselhi, dmcontrol_i.hartsello} & {{(20-NUM_HART_BITS){1'b0}}, {NUM_HART_BITS{1'b1}}};

                    // haltreq handling, TODO: control groups
                    haltreqs_next[hartsel_next] = dmcontrol_i.haltreq;

                    // hart reset handling, TODO: control groups
                    hartresets_next[hartsel_next] = dmcontrol_i.hartreset;

                    // resumereq handling, TODO: control groups
                    if (~(dmcontrol.haltreq | dmcontrol_i.haltreq)) begin
                        resumereqs_next[hartsel_next] = dmcontrol_i.resumereq;
                    end

                    // reset halt handling
                    resethaltreqs_next[hartsel_next] = dmcontrol_i.clrresethaltreq ? 1'b0 : (resethaltreqs[hartsel_next] | dmcontrol_i.setresethaltreq);

                    dmcontrol_next.dmactive = dmcontrol_i.dmactive;
                    dmcontrol_next.ndmreset = dmcontrol_i.ndmreset;

                    //sticky bit clearing
                    if (dmcontrol_i.resumereq) begin
                        sticky_resume_ack_next[hartsel_next] = 1'b0;
                    end

                    // Handle clearing of sticky ackhavereset
                    if (dmcontrol_i.ackhavereset) begin
                        sticky_havereset_next[hartsel_next] = 1'b0;
                    end

                    // Handle clearing of sticky ackunavail
                    if (dmcontrol_i.ackunavail) begin
                        sticky_unavail_next[hartsel_next] = 1'b0;
                    end

                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::DMCS2: begin
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::DMSTATUS: begin   // READONLY
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::HARTINFO: begin   // READONLY
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::COMMAND: begin
                    if (abstractcs.cmderr == 3'b0) begin    // only allow executing a command if there wasn't a previous error
                        if (halted_i[hartsel] & ~unavail_i[hartsel]) begin
                            if (command_i.cmdtype == 8'd0) begin
                                if ((command_i.control.regno >= 16'h1000) && (command_i.control.regno <= 16'h101f)) begin
                                    abstract_cmd = 1'b1;
                                    command_next = command_i;
                                end else begin
                                    abstractcs_next.cmderr = 3'd2; // not supported
                                    resp_op_o = 0;
                                    resp_valid_o = 1;
                                end
                            end else begin
                                abstractcs_next.cmderr = 3'd2; // not supported
                                resp_op_o = 0;
                                resp_valid_o = 1;
                            end
                        end else begin
                            abstractcs_next.cmderr = 3'h4;
                            resp_op_o = 0;
                            resp_valid_o = 1;
                        end
                    end else begin
                        resp_op_o = 0;
                        resp_valid_o = 1;
                    end
                end
                riscv_dm_pkg::ABSTRACTAUTO: begin
                    abstractauto_next.autoexecdata = {{(12-DATA_SIZE){1'b0}},abstractauto_i.autoexecdata[DATA_SIZE-1:0]};
                    abstractauto_next.autoexecprogbuf = {{(16-PROGRAM_SIZE){1'b0}},abstractauto_i.autoexecprogbuf[PROGRAM_SIZE-1:0]};
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::ABSTRACTCS: begin
                    abstractcs_next.cmderr = abstractcs.cmderr & ~abstractcs_i.cmderr; // handle cmderr clearing
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::HAWINDOWSEL: begin
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::HAWINDOW: begin
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                [riscv_dm_pkg::DATA0:riscv_dm_pkg::DATA11]: begin
                    prog_data_buf_we = 1;
                    prog_data_buf_next[req_addr_i[4:0]] = req_data_i;
                    if (abstractauto.autoexecdata[autodata_idx]) begin
                        abstract_cmd = 1;
                        dm_state_next = ABSTRACT_CMD_REG_READ_RENAME;
                    end else begin
                        resp_op_o = 0;
                        resp_valid_o = 1;
                    end
                end
                [riscv_dm_pkg::PROGBUF0:riscv_dm_pkg::PROGBUF15]: begin
                    prog_data_buf_next[req_addr_i[4:0]] = req_data_i;
                    prog_data_buf_we = 1;
                    if (abstractauto.autoexecprogbuf[req_addr_i[4:0]]) begin
                        dm_state_next = ABSTRACT_CMD_REG_READ_RENAME;
                    end else begin
                        resp_op_o = 0;
                        resp_valid_o = 1;
                    end
                end
                riscv_dm_pkg::SBCS: begin
                    resp_op_o = 2'b10;  // DMI error
                    resp_valid_o = 1;
                end
                default: begin
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
            endcase

            if (resp_ready_i && ~abstract_cmd) begin
                dm_state_next = IDLE;
            end else if (abstract_cmd) begin
                dm_state_next = ABSTRACT_CMD_REG_READ_RENAME;
            end
        end
        ABSTRACT_CMD_REG_READ_RENAME: begin
            // asserts signals for reading rename table
            rnm_read_en = command.control.transfer;
            dm_state_next = ABSTRACT_CMD_REG_READ_DATA;
        end
        ABSTRACT_CMD_REG_READ_DATA: begin
            rnm_read_en = command.control.transfer;
            // Transfer bit might not be active, even in this state, because
            // we are passing by this state to go to the prog. buf. execution.
            if (command.control.transfer) begin
                // asserts signals for reading physical RF
                // TODO: optimize
                rf_preg = rnm_read_resp;

                if (command.control.write) begin
                    rf_we = 1'b1;
                    if (command.control.aarsize == 3'd3) begin  // 64b access
                        rf_wdata[31:0] = prog_data_buf[DATABUF_BEGIN];
                        rf_wdata[63:32] = prog_data_buf[DATABUF_BEGIN+1];
                    end else if (command.control.aarsize == 3'd2) begin // 32b access
                        rf_wdata[31:0] = prog_data_buf[DATABUF_BEGIN];
                    end else begin
                        abstractcs_next.cmderr = 3'd2;
                    end
                end else begin
                    rf_en = 1'b1;
                    if (command.control.aarsize == 3'd3) begin  // 64b access
                        prog_data_buf_we = 1'b1;
                        prog_data_buf_next[DATABUF_BEGIN] = rf_rdata[31:0];
                        prog_data_buf_next[DATABUF_BEGIN+1] = rf_rdata[63:32];
                    end else if (command.control.aarsize == 3'd2) begin // 32b access
                        prog_data_buf_we = 1'b1;
                        prog_data_buf_next[DATABUF_BEGIN] = rf_rdata[31:0];
                    end else begin
                        abstractcs_next.cmderr = 3'd2;
                    end
                end
            end

            if (command.control.postexec) begin
                // Not finished yet, we still have to run the program buffer
                progbuf_run_req_o[hartsel] = 1'b1;
                dm_state_next = progbuf_run_ack_i[hartsel] ? EXEC_PROGBUF_WAIT_EBREAK : EXEC_PROGBUF_WAIT_START;
            end else begin
                // We are done, give a response
                resp_op_o = 0;
                resp_data_o = 32'd0;
                resp_valid_o = 1;
                dm_state_next = IDLE;
            end
        end
        EXEC_PROGBUF_WAIT_START: begin  // wait for the core to receive the request of executing the program buffer
            progbuf_run_req_o[hartsel] = 1'b1;
            if (progbuf_run_ack_i[hartsel]) begin
                dm_state_next = EXEC_PROGBUF_WAIT_EBREAK;
            end
        end
        EXEC_PROGBUF_WAIT_EBREAK: begin // wait for the core to finish executing the program buffer and run ebreak
            if (parked_i[hartsel]) begin
                // check whether there was an exception when running the program buffer
                if (progbuf_xcpt_i[hartsel]) begin
                    abstractcs_next.cmderr = 3'd3; // set cmderr accordingly
                end
                resp_op_o = 0;
                resp_valid_o = 1;
                dm_state_next = IDLE;
            end
        end
        default:;
    endcase
end

always_comb begin: hartsel_mux
    rf_rdata = '0;
    rnm_read_resp = '0;
    for (integer i = 0; i < NUM_HARTS; i++) begin
        if (i == hartsel) begin
            rnm_read_en_o[i] = rnm_read_en;
            rnm_read_reg_o[i] = rnm_read_reg;
            rnm_read_resp = rnm_read_resp_i[i];
            rf_en_o[i] = rf_en;
            rf_preg_o[i] = rf_preg;
            rf_rdata = rf_rdata_i[i];
            rf_we_o[i] = rf_we;
            rf_wdata_o[i] = rf_wdata;
        end else begin
            rnm_read_en_o[i] = '0;
            rnm_read_reg_o[i] = '0;
            rf_en_o[i] = '0;
            rf_preg_o[i] = '0;
            rf_we_o[i] = '0;
            rf_wdata_o[i] = '0;
        end
    end
end


// ===== Program/Data buffer stuff =====

logic [MEMORY_SEL_BITS-1:0] buf_addr;
assign buf_addr = sri_addr_i[BYTE_SEL_BITS+:MEMORY_SEL_BITS];


assign sri_error_o = 1'b0;
always_comb begin
    if (sri_en_i) begin
        sri_rdata_o = {prog_data_buf[buf_addr+1], prog_data_buf[buf_addr]};
    end else begin
        sri_rdata_o = '0;
    end
end



// ===== Sequential register update block =====
always_ff @( posedge clk_i or negedge rstn_i) begin
    if (~rstn_i) begin
        dmcontrol <= 0;
        dm_state <= IDLE;

        command <= 0;

        hartsel <= '0;
        abstractcs <= '0;
        abstractauto <= '0;
        haltreqs <= '0;
        resumereqs <= '0;
        prog_data_buf <= '0;
        hartresets <= '0;
        resethaltreqs <= '0;
        sticky_havereset <= '0;
        sticky_resume_ack <= '0;
        sticky_unavail <= '0;
    end else begin
        dmcontrol <= dmcontrol_next;
        dm_state <= dm_state_next;

        command <= command_next;

        // handle dmcontrol updates
        hartsel <= hartsel_next;

        abstractcs <= abstractcs_next;
        abstractauto <= abstractauto_next;

        haltreqs <= haltreqs_next;
        resumereqs <= resumereqs_next;
        hartresets <= hartresets_next;
        resethaltreqs <= resethaltreqs_next;

        sticky_havereset <= sticky_havereset_next;
        sticky_resume_ack <= sticky_resume_ack_next;
        sticky_unavail <= sticky_unavail_next;

        if (prog_data_buf_we) begin
            prog_data_buf <= prog_data_buf_next;
        end else begin
            if (sri_we_i & sri_en_i) begin
                for (integer i = 0; i < 4; i++) begin // lower 32b half
                    if (sri_be_i[i])
                        prog_data_buf[buf_addr][i*8+:8] <= sri_wdata_i[i*8+:8];
                end
                for (integer i = 0; i < 4; i++) begin // upper 32b half
                    if (sri_be_i[i+4])
                        prog_data_buf[buf_addr+1][i*8+:8] <= sri_wdata_i[(i+4)*8+:8];
                end
            end
        end
    end
end





endmodule

