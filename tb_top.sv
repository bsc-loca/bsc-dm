module tb_top();

logic clk, rstn;
initial begin
    forever begin
        clk = #1 ~clk;
        $display("tick");
    end
end

initial begin
    $dumpfile("trace.vcd");
    $dumpvars();
end

initial begin
    rstn = 0;
    rstn = #2 1;
end


logic tck, tms, tdi, tdo, trstn, tdo_driven;

SimJTAG #(
    .TICK_DELAY(0)
) JTAG_DPI (
    .clock(clk),
    .reset(~rstn),

    .enable(1),
    .init_done(1),

    .jtag_TCK(tck),
    .jtag_TMS(tms),
    .jtag_TDI(tdi),
    .jtag_TRSTn(trstn),

    .jtag_TDO_data(tdo),
    .jtag_TDO_driven(tdo_driven),

    .exit()
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
    .tms_i(tms),
    .tck_i(tck),
    .trst_i(~trstn),
    .tdi_i(tdi),
    .tdo_o(tdo),
    .tdo_driven_o(tdo_driven),

    .req_valid_o(req_valid),
    .req_ready_i(req_ready),
    .req_addr_o(req_addr),
    .req_data_o(req_data),
    .req_op_o(req_op),

    .resp_valid_i(resp_valid_cdc),
    .resp_ready_o(resp_ready_cdc),
    .resp_data_i(resp_data_cdc),
    .resp_op_i(resp_op_cdc)
);

cdc_fifo_gray_clearable #(
    .WIDTH(riscv_dm_pkg::DMI_ADDR_WIDTH+riscv_dm_pkg::DMI_DATA_WIDTH+riscv_dm_pkg::DMI_OP_WIDTH)
) req_cdc_fifo (
    .src_rst_ni(trstn),
    .src_clk_i(tck),
    .src_clear_i(0),
    .src_clear_pending_o(),
    .src_data_i({req_addr, req_data, req_op}),
    .src_valid_i(req_valid),
    .src_ready_o(req_ready),

    .dst_rst_ni(rstn),
    .dst_clk_i(clk),
    .dst_clear_i(0),
    .dst_clear_pending_o(),
    .dst_data_o({req_addr_cdc, req_data_cdc, req_op_cdc}),
    .dst_valid_o(req_valid_cdc),
    .dst_ready_i(req_ready_cdc)
);

cdc_fifo_gray_clearable #(
    .WIDTH(riscv_dm_pkg::DMI_DATA_WIDTH+riscv_dm_pkg::DMI_OP_WIDTH)
) resp_cdc_fifo (
    .src_rst_ni(rstn),
    .src_clk_i(clk),
    .src_clear_i(0),
    .src_clear_pending_o(),
    .src_data_i({resp_data, resp_op}),
    .src_valid_i(resp_valid),
    .src_ready_o(resp_ready),

    .dst_rst_ni(trstn),
    .dst_clk_i(tck),
    .dst_clear_i(0),
    .dst_clear_pending_o(),
    .dst_data_o({resp_data_cdc, resp_op_cdc}),
    .dst_valid_o(resp_valid_cdc),
    .dst_ready_i(resp_ready_cdc)
);

logic halt_request, resume_request, halted, resumeack;

riscv_dm dm(
    .clk_i(clk),
    .rstn_i(rstn),

    .req_valid_i(req_valid_cdc),
    .req_ready_o(req_ready_cdc),
    .req_addr_i(req_addr_cdc),
    .req_data_i(req_data_cdc),
    .req_op_i(req_op_cdc),

    .resp_valid_o(resp_valid),
    .resp_ready_i(resp_ready),
    .resp_data_o(resp_data),
    .resp_op_o(resp_op),

    .resume_request_o(resume_request),
    .halt_request_o(halt_request),
    .halt_on_reset_o(),
    .hart_reset_o(),

    .resume_ack_i(resumeack),
    .halted_i(halted),
    .running_i(~halted),
    .havereset_i(0),
    .unavail_i(0)
);

logic [7:0] delay;

assign resumeack = |(~delay);

always_ff @(posedge clk or negedge rstn) begin
    if (~rstn) begin
        delay <= 0;
    end else begin
        if (halt_request & ~resume_request) begin
            delay <= {delay[6:0], 1'b1};
        end else if (resume_request) begin
            delay <= {delay[6:0], 1'b0};
        end
    end
end

assign halted = delay[7];

endmodule
