
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
    parameter  integer NUM_HARTS        = 1,                //! Number of harts connected to the Debug Module
    parameter  integer PROGRAM_SIZE     = 4,                //! program buffer size, in words
    parameter  integer DATA_SIZE        = 4,                //! data buffer size, in words
    parameter  integer WORD_SIZE        = 4,                //! word size, in bytes
    parameter  integer NUM_PHYS_REGS    = 64,               //! Maximum number of physical registers for all the cores

    localparam integer XLEN             = 64,
    localparam integer PHYS_REG_BITS    = $clog2(NUM_PHYS_REGS),
    localparam integer NUM_LOGI_REGS    = 32,
    localparam integer LOGI_REG_BITS    = $clog2(NUM_LOGI_REGS),

    localparam integer BYTE_SEL_BITS    = $clog2(WORD_SIZE),
    localparam integer MEMORY_SEL_BITS  = $clog2(PROGRAM_SIZE + DATA_SIZE + 1),
    localparam integer BPW              = WORD_SIZE,
    localparam integer ADDR_WIDTH       = MEMORY_SEL_BITS + BYTE_SEL_BITS,
    localparam integer DATA_WIDTH       = BPW * 8
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

    // Hart run control signals
    output logic [NUM_HARTS-1:0]                        resume_request_o,
    input logic [NUM_HARTS-1:0]                         resume_ack_i,
    input logic [NUM_HARTS-1:0]                         running_i,

    output logic [NUM_HARTS-1:0]                        halt_request_o,
    input logic [NUM_HARTS-1:0]                         halted_i,

    output logic [NUM_HARTS-1:0]                        progbuf_run_req_o,
    input logic [NUM_HARTS-1:0]                         progbuf_run_ack_i,
    input logic [NUM_HARTS-1:0]                         parked_i,

    output logic [NUM_HARTS-1:0]                        halt_on_reset_o,
    output logic [NUM_HARTS-1:0]                        hart_reset_o,
    input logic [NUM_HARTS-1:0]                         havereset_i,

    input logic [NUM_HARTS-1:0]                         unavail_i,

    // Register read abstract command signals
    //! @virtualbus regfilebus @dir in
    output logic                        rnm_read_en_o,   //! Request reading the rename table
    output logic [PHYS_REG_BITS-1:0]    rnm_read_reg_o,  //! Logical register for which the mapping is read
    input  logic [LOGI_REG_BITS-1:0]    rnm_read_resp_i, //! Physical register mapped to the requested logical register

    output logic                        rf_en_o,            //! Read enable for the register file
    output logic                        rf_preg_o,          //! Target physical register in the register file
    input  logic [XLEN-1:0]             rf_rdata_i,         //! Data read from the register file

    output logic                        rf_we_o,            //! Write enable for the register file
    output  logic [XLEN-1:0]            rf_wdata_o,         //! Data to write to the register file
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


localparam PROGBUF_BEGIN = 0;
localparam PROGBUF_END = PROGRAM_SIZE - 1;
localparam DATABUF_BEGIN = PROGRAM_SIZE;
localparam DATABUF_END =  DATABUF_BEGIN + DATA_SIZE - 1;


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

logic [NUM_HARTS-1:0]   hawindowsel, hawindowsel_next,
                        hawindow, hawindow_next,
                        resumereqs, resumereqs_next,
                        haltreqs, haltreqs_next;

logic [19:0] hartsel, hartsel_next;

logic   clear_ackhavereset,
        clear_ackunavail,
        ackhavereset,
        ackhavereset_next,
        ackunavail,
        ackunavail_next;


assign halt_request_o = haltreqs;
assign resume_request_o = resumereqs;


// ===== hartinfo register =====

riscv_dm_pkg::hartinfo_t    hartinfo;

assign hartinfo.nscratch = 4'd0;
assign hartinfo.dataaccess = 1'b1;  // memory-mapped data regs
assign hartinfo.datasize = 4'(DATA_SIZE);
assign hartinfo.dataaddr = 12'h0;


// ===== dmcontrol register =====

riscv_dm_pkg::dmcontrol_t   dmcontrol,
                            dmcontrol_next,
                            dmcontrol_i;

assign dmcontrol_i = req_data_i;

// write only regs
assign dmcontrol_next.resumereq = 0;
assign dmcontrol_next.ackhavereset = 0;
assign dmcontrol_next.ackunavail = 0;
assign dmcontrol_next.hartselhi = 0;
assign dmcontrol_next.hartsello = 0;
assign dmcontrol_next.setkeepalive = 0;
assign dmcontrol_next.clrkeepalive = 0;
assign dmcontrol_next.setresethaltreq = 0;
assign dmcontrol_next.clrresethaltreq = 0;


// ===== dmstatus register =====
riscv_dm_pkg::dmstatus_t dmstatus;

logic [NUM_HARTS-1:0] eff_hart_win_sel;
assign eff_hart_win_sel = hawindowsel | (1'b1 << hartsel);

// TODO: parametrize
assign dmstatus.ndmresetpending = 0;
assign dmstatus.stickyunavail = 0;

assign dmstatus.allhavereset = &(eff_hart_win_sel & havereset_i);
assign dmstatus.anyhavereset = |(eff_hart_win_sel & havereset_i);

assign dmstatus.allresumeack = &(eff_hart_win_sel & resume_ack_i);
assign dmstatus.anyresumeack = |(eff_hart_win_sel & resume_ack_i);

assign dmstatus.anynonexistent = eff_hart_win_sel != 'h1; // TODO: fix this
assign dmstatus.allnonexistent = eff_hart_win_sel != 'h1;

assign dmstatus.allunavail = &(eff_hart_win_sel & unavail_i);
assign dmstatus.anyunavail = |(eff_hart_win_sel & unavail_i);

assign dmstatus.allrunning = &(eff_hart_win_sel & running_i);
assign dmstatus.anyrunning = |(eff_hart_win_sel & running_i);

assign dmstatus.allhalted = &(eff_hart_win_sel & halted_i);
assign dmstatus.anyhalted = |(eff_hart_win_sel & halted_i);

assign dmstatus.authenticated = 1;
assign dmstatus.authbusy = 1'b0;

assign dmstatus.hasresethaltreq = 1'b0; // TODO: implement if we have time
assign dmstatus.confstrptrvalid = 0;
assign dmstatus.version = 4'd3;



// ===== abstractcs register =====
riscv_dm_pkg::abstractcs_t  abstractcs,
                            abstractcs_next,
                            abstractcs_i;

assign abstractcs_i = req_data_i;

// read only regs
assign abstractcs_next.progbufsize = 5'(PROGRAM_SIZE);
assign abstractcs_next.busy = 0;
assign abstractcs_next.relaxedpriv = 1;
assign abstractcs_next.datacount = 4'(DATA_SIZE);

// ===== abstract command register =====
riscv_dm_pkg::command_t  command_i, command, command_next;

assign command_i = req_data_i;
assign rnm_read_reg_o = command.control.regno[LOGI_REG_BITS-1:0]; //extract register bits

logic postexec, postexec_next;

// ===== program buffer register =====
logic prog_data_buf_we;
logic [PROGRAM_SIZE+DATA_SIZE-1:0][WORD_SIZE*8-1:0] prog_data_buf, prog_data_buf_next;

logic abstract_cmd;
logic [XLEN-1:0] rf_logi_phys_mapping, rf_logi_phys_mapping_next;

always_comb begin
    hartsel_next = hartsel;
    dmcontrol_next = dmcontrol;
    abstractcs_next.cmderr = abstractcs.cmderr;
    postexec_next = postexec;
    req_ready_o = 1;
    resp_valid_o = 0;
    resp_op_o = 0; // err
    clear_ackhavereset = 0;
    prog_data_buf_we = 0;
    dm_state_op_next = IDLE;
    command_next = command;
    prog_data_buf_next = prog_data_buf;

    // rnm defaults
    rnm_read_en_o = 1'b0;

    // rf defaults
    rf_en_o = 1'b0;
    rf_we_o = 1'b0;
    rf_preg_o = 1'b0;
    rf_wdata_o = '0;


    case (dm_state)
        IDLE: begin
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
            resp_data_o = 32'hcafebabe;
            case (req_addr_i) inside
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
                end
                [riscv_dm_pkg::PROGBUF0:riscv_dm_pkg::PROGBUF0+PROGRAM_SIZE-1]: begin
                    resp_data_o = prog_data_buf[req_addr_i[4:0]];
                    resp_op_o = 0;
                    resp_valid_o = 1;
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

            if (resp_ready_i)
                dm_state_next = IDLE;
        end
        WRITE: begin
            req_ready_o = 0;
            resp_data_o = 0;
            dm_state_op_next = IDLE;

            case (req_addr_i) inside
                riscv_dm_pkg::DMCONTROL: begin
                    // individual hartsel handling
                    if ({dmcontrol_i.hartselhi, dmcontrol_i.hartsello} < 20'(NUM_HARTS)) begin
                        hartsel_next = {dmcontrol_i.hartselhi, dmcontrol_i.hartsello};
                    end

                    // haltreq handling, TODO: control groups
                    haltreqs_next[hartsel_next] = dmcontrol_i.haltreq;

                    // resumereq handling, TODO: control groups
                    if (~(dmcontrol.haltreq | dmcontrol_i.haltreq)) begin
                        resumereqs_next[hartsel_next] = dmcontrol_i.resumereq;
                    end

                    // ackhavereset handling
                    if (dmcontrol_i.ackhavereset) begin
                        clear_ackhavereset = 1;
                    end

                    // ackunavail handling
                    if (dmcontrol_i.ackunavail) begin
                        clear_ackunavail = 1;
                    end


                    // hasel handling, TODO: 0 only allowed for now
                    dmcontrol_next.hasel = 0;

                    dmcontrol_next.dmactive = dmcontrol_i.dmactive;

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
                    // if () begin
                    if (abstractcs.cmderr == 3'b0) begin
                        if (command_i.cmdtype == 8'd0) begin
                            if ((command_i.control.regno >= 16'h1000) && (command_i.control.regno <= 16'h101f)) begin
                                abstract_cmd = 1'b1;
                                command_next = command_i;
                                if (command_i.control.postexec) begin
                                    postexec_next = 1'b1;
                                end
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
                    end
                end
                riscv_dm_pkg::ABSTRACTCS: begin
                    abstractcs_next.cmderr = abstractcs.cmderr & ~abstractcs_i.cmderr; // busy
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
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                [riscv_dm_pkg::PROGBUF0:riscv_dm_pkg::PROGBUF15]: begin
                    prog_data_buf_next[req_addr_i[4:0]] = req_data_i;
                    prog_data_buf_we = 1;
                    resp_op_o = 0;
                    resp_valid_o = 1;
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
            end else if (resp_ready_i && abstract_cmd) begin
                if (postexec) begin
                    postexec_next = 0;
                    progbuf_run_req_o[hartsel] = 1'b1;
                    postexec_next = 1'b0;
                    dm_state_next = EXEC_PROGBUF_WAIT_START;
                end else begin
                    dm_state_next = ABSTRACT_CMD_REG_READ_RENAME;
                end
            end
        end
        ABSTRACT_CMD_REG_READ_RENAME: begin
            // asserts signals for reading rename table
            rnm_read_en_o = 1'b1;
            rf_logi_phys_mapping_next = rnm_read_resp_i;
            dm_state_next = ABSTRACT_CMD_REG_READ_DATA;
        end
        ABSTRACT_CMD_REG_READ_DATA: begin
            resp_op_o = 0;

            rf_preg_o = rf_logi_phys_mapping;
            rf_en_o = 1'b1;
            // asserts signals for reading physical RF
            if (~command.control.write & command.control.transfer) begin // copy data from core register to data
                // set signals for reading the RF

                // TODO: optimize
                if (command.control.aarsize == 3'd3) begin  // 64b access
                    prog_data_buf_we = 1'b1;
                    prog_data_buf_next[DATABUF_BEGIN] = rf_rdata_i[31:0];
                    prog_data_buf_next[DATABUF_BEGIN+1] = rf_rdata_i[63:32];
                end else if (command.control.aarsize == 3'd2) begin // 32b access
                    prog_data_buf_we = 1'b1;
                    prog_data_buf_next[DATABUF_BEGIN] = rf_rdata_i[31:0];
                end else begin
                    abstractcs_next.cmderr = 3'd2;
                end
            end else if (command.control.write & command.control.transfer) begin
                rf_we_o = 1'b1;

                // TODO: optimize
                if (command.control.aarsize == 3'd3) begin  // 64b access
                    rf_wdata_o[31:0] = prog_data_buf[DATABUF_BEGIN];
                    rf_wdata_o[63:32] = prog_data_buf[DATABUF_BEGIN+1];
                end else if (command.control.aarsize == 3'd2) begin // 32b access
                    rf_wdata_o[31:0] = prog_data_buf[DATABUF_BEGIN];
                end else begin
                    abstractcs_next.cmderr = 3'd2;
                end
            end
            resp_data_o = 32'd0;
            resp_valid_o = 1;
            dm_state_next = IDLE;
        end
        EXEC_PROGBUF_WAIT_START: begin  // wait for the core to receive the request of executing the program buffer
            if (progbuf_run_ack_i[hartsel]) begin
                progbuf_run_req_o[hartsel] = 1'b0;
                dm_state_next = EXEC_PROGBUF_WAIT_EBREAK;
            end
        end
        EXEC_PROGBUF_WAIT_EBREAK: begin // wait for the core to finish executing the program buffer and run ebreak
            if (halted_i[hartsel]) begin
                resp_op_o = 0;
                resp_valid_o = 1;
                dm_state_next = IDLE;
            end
        end
        default:;
    endcase
end


// ===== Program/Data buffer stuff =====

logic [MEMORY_SEL_BITS-1:0] buf_addr;
assign buf_addr = sri_addr_i[MEMORY_SEL_BITS+:BYTE_SEL_BITS];


always_comb begin
    if (sri_en_i) begin
        if (buf_addr > DATABUF_END) begin
            sri_rdata_o = riscv_dm_pkg::EBREAK; // ebreak
        end else begin
            sri_rdata_o = prog_data_buf[buf_addr];
        end
    end
end



// ===== Sequential register update block =====
always_ff @( posedge clk_i ) begin
    if (~rstn_i) begin
        dmcontrol <= 0;
        dm_state <= IDLE;

        postexec <= 0;
        command <= 0;

        // TODO: actual reset values
        hartsel <= hartsel_next;
        abstractcs.cmderr <= 3'b0;
        haltreqs <= haltreqs_next;
        resumereqs <= resumereqs_next;
        prog_data_buf <= '0;
    end else begin
        dmcontrol <= dmcontrol_next;
        dm_state <= dm_state_next;

        postexec <= postexec_next;

        command <= command_next;

        // handle dmcontrol updates
        hartsel <= hartsel_next;

        abstractcs <= abstractcs_next;

        haltreqs <= haltreqs_next;
        resumereqs <= resumereqs_next;

        // handle dmcontrol clear
        ackhavereset <= ackhavereset_next & ~clear_ackhavereset;
        ackunavail <= ackunavail_next & ~clear_ackunavail;

        if (prog_data_buf_we) begin
            prog_data_buf <= prog_data_buf_next;
        end else begin
            if (sri_we_i & sri_en_i) begin
                for (integer i = 0; i < BPW; i++) begin
                    if (sri_be_i[i])
                        prog_data_buf[buf_addr][i*8+:8] <= sri_wdata_i[i*8+:8];
                end
            end
        end
    end
end





endmodule

