module riscv_dm_wrapper #(
    parameter  integer NUM_HARTS        = 1,                //! Number of harts connected to the Debug Module
    parameter  integer PROGRAM_SIZE     = 4,                //! program buffer size, in words
    parameter  integer DATA_SIZE        = 4,                //! data buffer size, in words
    parameter  integer WORD_SIZE        = 4,                //! word size, in bytes
    parameter  integer NUM_PHYS_REGS    = 64,               //! Maximum number of physical registers for all the cores

    parameter  integer AXI_ADDR_WIDTH   = 64,
    parameter  integer AXI_DATA_WIDTH   = 64,

    localparam integer XLEN             = 64,
    localparam integer PHYS_REG_BITS    = $clog2(NUM_PHYS_REGS),
    localparam integer NUM_LOGI_REGS    = 32,
    localparam integer LOGI_REG_BITS    = $clog2(NUM_LOGI_REGS),

    localparam integer BYTE_SEL_BITS    = $clog2(WORD_SIZE),
    localparam integer MEMORY_SEL_BITS  = $clog2(PROGRAM_SIZE + DATA_SIZE + 1),
    localparam integer BPW              = 8,
    localparam integer ADDR_WIDTH       = 64,
    localparam integer DATA_WIDTH       = 64 //! Size of the SRI data channel
)(
    input logic                             clk_i,
    input logic                             rstn_i,

    input  logic [ADDR_WIDTH-1:0]           sri_addr_i,
    input  logic                            sri_en_i,
    input  logic                            sri_we_i,
    input  logic [DATA_WIDTH-1:0]           sri_wdata_i,
    input  logic [(DATA_WIDTH/8)-1:0]       sri_be_i,
    output logic [DATA_WIDTH-1:0]           sri_rdata_o,
    output logic                            sri_error_o,

    // JTAG ports
    input   logic                           tms_i,
    input   logic                           tck_i,
    input   logic                           trst_i,
    input   logic                           tdi_i,
    output  logic                           tdo_o,
    output  logic                           tdo_driven_o,

    input   logic [31:0]                    idcode_i,

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
    output logic [NUM_HARTS-1:0]                     rnm_read_en_o,
    output logic [NUM_HARTS-1:0][LOGI_REG_BITS-1:0]  rnm_read_reg_o,
    input  logic [NUM_HARTS-1:0][PHYS_REG_BITS-1:0]  rnm_read_resp_i,

    output logic [NUM_HARTS-1:0]                     rf_en_o,
    output logic [NUM_HARTS-1:0][PHYS_REG_BITS-1:0]  rf_preg_o,
    input  logic [NUM_HARTS-1:0][XLEN-1:0]           rf_rdata_i,

    output logic [NUM_HARTS-1:0]                     rf_we_o,
    output logic [NUM_HARTS-1:0][XLEN-1:0]           rf_wdata_o
    //! @end
);
    logic                                       req_valid;
    logic                                       req_ready;
    logic [riscv_dm_pkg::DMI_ADDR_WIDTH-1:0]    req_addr;
    logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]    req_data;
    logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]      req_op;
    logic                                       req_valid_cdc;
    logic                                       req_ready_cdc;
    logic [riscv_dm_pkg::DMI_ADDR_WIDTH-1:0]    req_addr_cdc;
    logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]    req_data_cdc;
    logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]      req_op_cdc;

    logic                                       resp_valid;
    logic                                       resp_ready;
    logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]    resp_data;
    logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]      resp_op;
    logic                                       resp_valid_cdc;
    logic                                       resp_ready_cdc;
    logic [riscv_dm_pkg::DMI_DATA_WIDTH-1:0]    resp_data_cdc;
    logic [riscv_dm_pkg::DMI_OP_WIDTH-1:0]      resp_op_cdc;

    riscv_dtm dtm(
        .tms_i          (tms_i),
        .tck_i          (tck_i),
        .trst_i         (trst_i),
        .tdi_i          (tdi_i),
        .tdo_o          (tdo_o),
        .tdo_driven_o   (tdo_driven_o),
        .idcode_i       (idcode_i),

        .req_valid_o    (req_valid),
        .req_ready_i    (req_ready),
        .req_addr_o     (req_addr),
        .req_data_o     (req_data),
        .req_op_o       (req_op),

        .resp_valid_i   (resp_valid_cdc),
        .resp_ready_o   (resp_ready_cdc),
        .resp_data_i    (resp_data_cdc),
        .resp_op_i      (resp_op_cdc)
    );

    cdc_2phase_clearable #(
        .T                      (logic [riscv_dm_pkg::DMI_ADDR_WIDTH+riscv_dm_pkg::DMI_DATA_WIDTH+riscv_dm_pkg::DMI_OP_WIDTH-1:0])
    ) req_cdc (
        .src_rst_ni             (~trst_i),
        .src_clk_i              (tck_i),
        .src_clear_i            ('0),
        .src_clear_pending_o    (),
        .src_data_i             ({req_addr, req_data, req_op}),
        .src_valid_i            (req_valid),
        .src_ready_o            (req_ready),

        .dst_rst_ni             (rstn_i),
        .dst_clk_i              (clk_i),
        .dst_clear_i            ('0),
        .dst_clear_pending_o    (),
        .dst_data_o             ({req_addr_cdc, req_data_cdc, req_op_cdc}),
        .dst_valid_o            (req_valid_cdc),
        .dst_ready_i            (req_ready_cdc)
    );

    cdc_2phase_clearable #(
        .T(logic [riscv_dm_pkg::DMI_DATA_WIDTH+riscv_dm_pkg::DMI_OP_WIDTH-1:0])
    ) resp_cdc (
        .src_rst_ni             (rstn_i),
        .src_clk_i              (clk_i),
        .src_clear_i            ('0),
        .src_clear_pending_o    (),
        .src_data_i             ({resp_data, resp_op}),
        .src_valid_i            (resp_valid),
        .src_ready_o            (resp_ready),

        .dst_rst_ni             (~trst_i),
        .dst_clk_i              (tck_i),
        .dst_clear_i            ('0),
        .dst_clear_pending_o    (),
        .dst_data_o             ({resp_data_cdc, resp_op_cdc}),
        .dst_valid_o            (resp_valid_cdc),
        .dst_ready_i            (resp_ready_cdc)
    );

    riscv_dm #(
        .NUM_HARTS          (NUM_HARTS),
        .PROGRAM_SIZE       (PROGRAM_SIZE),
        .DATA_SIZE          (DATA_SIZE),
        .WORD_SIZE          (WORD_SIZE),
        .NUM_PHYS_REGS      (NUM_PHYS_REGS)
    ) dm(
        .clk_i              (clk_i),
        .rstn_i             (rstn_i),

        .req_valid_i        (req_valid_cdc),
        .req_ready_o        (req_ready_cdc),
        .req_addr_i         (req_addr_cdc),
        .req_data_i         (req_data_cdc),
        .req_op_i           (req_op_cdc),

        .resp_valid_o       (resp_valid),
        .resp_ready_i       (resp_ready),
        .resp_data_o        (resp_data),
        .resp_op_o          (resp_op),

        .resume_request_o   (resume_request_o),
        .resume_ack_i       (resume_ack_i),
        .running_i          (running_i),

        .halt_request_o     (halt_request_o),
        .halted_i           (halted_i),

        .progbuf_run_req_o  (progbuf_run_req_o),
        .progbuf_run_ack_i  (progbuf_run_ack_i),
        .progbuf_xcpt_i     (progbuf_xcpt_i),
        .parked_i           (parked_i),

        .halt_on_reset_o    (halt_on_reset_o),
        .hart_reset_o       (hart_reset_o),

        .havereset_i        (havereset_i),
        .unavail_i          (unavail_i),

        .rnm_read_en_o      (rnm_read_en_o),
        .rnm_read_reg_o     (rnm_read_reg_o),
        .rnm_read_resp_i    (rnm_read_resp_i),

        .rf_en_o            (rf_en_o),
        .rf_preg_o          (rf_preg_o),
        .rf_rdata_i         (rf_rdata_i),

        .rf_we_o            (rf_we_o),
        .rf_wdata_o         (rf_wdata_o),


        .sri_addr_i         (sri_addr_i),
        .sri_en_i           (sri_en_i),
        .sri_wdata_i        (sri_wdata_i),
        .sri_we_i           (sri_we_i),
        .sri_be_i           (sri_be_i),
        .sri_rdata_o        (sri_rdata_o),
        .sri_error_o        (sri_error_o)
    );
endmodule
