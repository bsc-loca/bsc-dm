package riscv_dm_pkg;
    parameter logic [3:0] DTM_VERSION = 4'd1;
    parameter logic [2:0] DTM_IDLE_CYCLES = 3'd2;
    parameter integer DMI_OP_WIDTH = 2;
    parameter integer DMI_DATA_WIDTH = 32;
    parameter integer DMI_ADDR_WIDTH = 7;


    // ===== DMI definitions =====
    parameter logic [1:0] WR_OP_NOP = 2'b00;
    parameter logic [1:0] WR_OP_RD  = 2'b01;
    parameter logic [1:0] WR_OP_WR  = 2'b10;

    parameter logic [1:0] RD_OP_SUCCESS = 2'b00;
    parameter logic [1:0] RD_OP_FAILED  = 2'b10;
    parameter logic [1:0] RD_OP_BUSY    = 2'b11;


    typedef struct packed {
        logic [DMI_ADDR_WIDTH-1:0] addr;
        logic [DMI_DATA_WIDTH-1:0] data;
        logic [DMI_OP_WIDTH-1:0] op;
    } dmi_t;
    parameter integer DMI_WIDTH = $bits(dmi_t);

    parameter logic [31:0] EBREAK = 32'h00100073;



   // ===== DTMCS definitions =====
    typedef struct packed {
        logic [10:0] _pad1;
        logic [2:0] errinfo;
        logic       dtmhardreset;
        logic       dmireset;
        logic       _pad2;
        logic [2:0] idle;
        logic [1:0] dmistat;
        logic [5:0] abits;
        logic [3:0] version;
    } dtmcs_t;
    parameter logic [5:0] DTM_ADDR_BITS = 6'(DMI_ADDR_WIDTH);
    parameter integer DTMCS_WIDTH = $bits(dtmcs_t);

    typedef struct packed {
        logic [6:0] _pad1;
        logic       ndmresetpending;
        logic       stickyunavail;
        logic       impebreak;
        logic [1:0] _pad2;
        logic       allhavereset;
        logic       anyhavereset;
        logic       allresumeack;
        logic       anyresumeack;
        logic       allnonexistent;
        logic       anynonexistent;
        logic       allunavail;
        logic       anyunavail;
        logic       allrunning;
        logic       anyrunning;
        logic       allhalted;
        logic       anyhalted;
        logic       authenticated;
        logic       authbusy;
        logic       hasresethaltreq;
        logic       confstrptrvalid;
        logic [3:0] version;
    } dmstatus_t;

    typedef struct packed {
        logic       haltreq;
        logic       resumereq;
        logic       hartreset;
        logic       ackhavereset;
        logic       ackunavail;
        logic       hasel;
        logic [9:0] hartsello;
        logic [9:0] hartselhi;
        logic       setkeepalive;
        logic       clrkeepalive;
        logic       setresethaltreq;
        logic       clrresethaltreq;
        logic       ndmreset;
        logic       dmactive;
    } dmcontrol_t;

    typedef struct packed {
        logic [7:0] _pad1;
        logic [3:0] nscratch;
        logic [2:0] _pad2;
        logic       dataaccess;
        logic [3:0] datasize;
        logic [11:0] dataaddr;
    } hartinfo_t;

    typedef struct packed {
        logic [19:0] _pad1;
        logic        grouptype;
        logic [3:0]  dmexttrigger;
        logic [4:0]  group;
        logic        hgwrite;
        logic        hgselect;
    } dmcs2_t;

    typedef struct packed {
        logic [2:0]  _pad1;
        logic [4:0]  progbufsize;
        logic [10:0] _pad2;
        logic        busy;
        logic        relaxedpriv;
        logic [2:0]  cmderr;
        logic [3:0]  _pad3;
        logic [3:0]  datacount;
    } abstractcs_t;

    typedef struct packed {
        logic        _pad1;
        logic [2:0]  aarsize;
        logic        aarpostincrement;
        logic        postexec;
        logic        transfer;
        logic        write;
        logic [15:0] regno;
    } access_register_t;

    typedef struct packed {
        logic [7:0]         cmdtype;
        access_register_t   control;
    } command_t;


    typedef enum logic[6:0] {
        DATA0        = 7'h04,
        DATA11       = 7'h0c,
        DMCONTROL    = 7'h10,
        DMSTATUS     = 7'h11,
        HARTINFO     = 7'h12,
        HAWINDOWSEL  = 7'h14,
        HAWINDOW     = 7'h15,
        ABSTRACTCS   = 7'h16,
        COMMAND      = 7'h17,
        ABSTRACTAUTO = 7'h18,
        NEXTDM       = 7'h1d,
        PROGBUF0     = 7'h20,
        PROGBUF15    = 7'h2f,
        DMCS2        = 7'h32,
        SBCS         = 7'h38
    } dm_reg_t;

    typedef struct packed {
        logic [15:0] autoexecprogbuf;
        logic [3:0] _pad1;
        logic [11:0] autoexecdata;
    } abstractauto_t;

endpackage
