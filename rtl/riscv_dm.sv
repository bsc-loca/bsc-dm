
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

module riscv_dm #(
    parameter int PROGRAM_SIZE          = 4,                //! program buffer size, in words
    parameter int DATA_SIZE             = 4,                //! data buffer size, in words
    parameter int WORD_SIZE             = 4,                //! word size, in bytes
    localparam integer BYTE_SEL_BITS = $clog2(WORD_SIZE),
    localparam integer MEMORY_SEL_BITS = $clog2(PROGRAM_SIZE + DATA_SIZE),
    localparam int BPW = WORD_SIZE,
    localparam int ADDR_WIDTH = MEMORY_SEL_BITS + BYTE_SEL_BITS,
    localparam int DATA_WIDTH = BPW * 8
) (
    input  logic           clk_i,  //! System clock signal.
    input  logic           rstn_i, //! System reset signal (active low)

    input   logic                                       req_valid_i,
    output  logic                                       req_ready_o,
    input   logic [riscv_dm_pkg::DMI_ADDR_WIDTH-1:0]    req_addr_i,
    input   logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]    req_data_i,
    input   logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]      req_op_i,

    output  logic                                       resp_valid_o,
    input   logic                                       resp_ready_i,
    output  logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]    resp_data_o,
    output  logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]      resp_op_o,

    // Hart run control signals
    output logic [NUM_HARTS-1:0] resume_request_o,
    input logic [NUM_HARTS-1:0] resume_ack_i,
    input logic [NUM_HARTS-1:0] running_i,

    output logic [NUM_HARTS-1:0] halt_request_o,
    input logic [NUM_HARTS-1:0] halted_i,

    output logic [NUM_HARTS-1:0] halt_on_reset_o,
    output logic [NUM_HARTS-1:0] hart_reset_o,
    input logic [NUM_HARTS-1:0] havereset_i,

    input logic [NUM_HARTS-1:0] unavail_i,


    // SRI interface for program buffer
    input  logic [ADDR_WIDTH-1:0] sri_addr_i,               //! register interface address
    input  logic                  sri_en_i,                 //! register interface enable
    input  logic [DATA_WIDTH-1:0] sri_wdata_i,              //! register interface data to write
    input  logic                  sri_we_i,                 //! register interface write enable
    input  logic [BPW-1:0]        sri_be_i,                 //! register interface byte enable (write mask)
    output logic [DATA_WIDTH-1:0] sri_rdata_o,              //! register interface read data
    output logic                  sri_error_o               //! register interface error
);

localparam integer NUM_HARTS = 1;

// CDC fifos O_o


typedef enum logic [3:0] {
    IDLE,
    NOP,
    READ,
    WRITE,
    ABSTRACT_CMD_REG_READ_RENAME,
    ABSTRACT_CMD_REG_READ_DATA,
    EXEC_PROGBUF
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
// riscv_dm_pkg::dmcs2_t       dmcs2,
//                             dmcs2_next,
//                             dmcs2_i;

assign hartinfo.nscratch = 4'd0;
assign hartinfo.dataaccess = 1'b1;
assign hartinfo.datasize = 4'd4;
assign hartinfo.dataaddr = 12'd0;


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
assign abstractcs_next.progbufsize = 4;
assign abstractcs_next.busy = 0;
assign abstractcs_next.relaxedpriv = 1;
assign abstractcs_next.datacount = 1;

// ===== abstract command register =====
riscv_dm_pkg::command_t  command_i;

assign command_i = req_data_i;

logic postexec, postexec_next;

always_comb begin
    // hawindowsel_next = hawindowsel;
    // hawindow_next = hawindow;
    hartsel_next = hartsel;
    dmcontrol_next = dmcontrol;
    abstractcs_next.cmderr = abstractcs.cmderr;
    postexec_next = postexec;
    req_ready_o = 1;
    resp_valid_o = 0;
    resp_op_o = 0; // err
    clear_ackhavereset = 0;

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
            dm_state_op_next = IDLE;
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
                    resp_data_o = hartinfo;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::COMMAND: begin
                    resp_data_o = 32'd0;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::ABSTRACTCS: begin
                    resp_data_o = abstractcs;
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
                    resp_data_o = 32'haaaa5555;
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                [riscv_dm_pkg::PROGBUF0:riscv_dm_pkg::PROGBUF15]: begin
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
                dm_state_next = dm_state_op_next;
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
                        if (command_i.cmdtype == 0) begin
                            if ((command_i.control.regno >= 16'h1000) && (command_i.control.regno <= 16'h101f)) begin
                                dm_state_op_next = ABSTRACT_CMD_REG_READ_RENAME;
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
                riscv_dm_pkg::HAWINDOWSEL: begin // TODO: hardcoded for now
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                riscv_dm_pkg::HAWINDOW: begin // TODO: hardcoded for now
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                [riscv_dm_pkg::DATA0:riscv_dm_pkg::DATA11]: begin //TODO: create registers
                    resp_op_o = 0;
                    resp_valid_o = 1;
                end
                [riscv_dm_pkg::PROGBUF0:riscv_dm_pkg::PROGBUF15]: begin //TODO: create registers
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
            if (resp_ready_i)
                dm_state_next = dm_state_op_next;
        end
        ABSTRACT_CMD_REG_READ_RENAME: begin
            dm_state_next = ABSTRACT_CMD_REG_READ_DATA;
        end
        ABSTRACT_CMD_REG_READ_DATA: begin
            resp_data_o = 32'd0;
            if (postexec) begin
                postexec_next = 1'b0;
                dm_state_next = EXEC_PROGBUF;
            end else begin
                resp_op_o = 0;
                resp_valid_o = 1;
                dm_state_next = IDLE;
            end
        end
        EXEC_PROGBUF: begin
            resp_data_o = 32'ha5a5a5a5;
            resp_op_o = 0;
            resp_valid_o = 1;
            dm_state_next = IDLE;
        end
        default:;
    endcase
end


always_ff @( posedge clk_i ) begin
    if (~rstn_i) begin
        dmcontrol <= 0;
        dm_state <= IDLE;
        // TODO: actual reset values
        hartsel <= hartsel_next;
        abstractcs.cmderr <= 3'b0;
        haltreqs <= haltreqs_next;
        resumereqs <= resumereqs_next;
    end else begin
        dmcontrol <= dmcontrol_next;
        dm_state <= dm_state_next;

        // handle dmcontrol updates
        hartsel <= hartsel_next;

        abstractcs <= abstractcs_next;

        haltreqs <= haltreqs_next;
        resumereqs <= resumereqs_next;

        // handle dmcontrol clear
        ackhavereset <= ackhavereset_next & ~clear_ackhavereset;
        ackunavail <= ackunavail_next & ~clear_ackunavail;
    end
end



// ===== Program/Data buffers =====

localparam PROGBUF_BEGIN = 0;
localparam PROGBUF_END = PROGRAM_SIZE - 1;
localparam DATABUF_BEGIN = PROGRAM_SIZE;
localparam DATABUF_END =  DATABUF_BEGIN + DATA_SIZE - 1;

logic [MEMORY_SEL_BITS-1:0] buf_addr;
assign buf_addr = sri_addr_i[MEMORY_SEL_BITS+:BYTE_SEL_BITS];

logic [WORD_SIZE*8-1:0][PROGRAM_SIZE-1:0] progbuf;
logic [WORD_SIZE*8-1:0][DATA_SIZE-1:0] databuf;

always_comb begin
    sri_rdata_o = '0;
    case (buf_addr) inside
        [PROGBUF_BEGIN:PROGBUF_END]: begin
            if (sri_en_i) begin
                sri_rdata_o = progbuf[buf_addr];
            end
        end
        [DATABUF_BEGIN:DATABUF_END]: begin
            if (sri_en_i) begin
                sri_rdata_o = databuf[buf_addr];
            end
        end
    endcase
end

always_ff @(posedge clk_i or negedge rstn_i) begin
    if (~rstn_i) begin
        progbuf <= '0;
        databuf <= '0;
    end else begin
        case (buf_addr) inside
            [PROGBUF_BEGIN:PROGBUF_END]: begin
                if (sri_we_i & sri_en_i) begin
                    progbuf <= sri_wdata_i;
                end
            end
            [DATABUF_BEGIN:DATABUF_END]: begin
                if (sri_we_i & sri_en_i) begin
                    databuf <= sri_wdata_i;
                end
            end
        endcase
    end
end

endmodule

