// See LICENSE.SiFive for license details.

#include "remote_bitbang.h"
#include <cstdlib>

remote_bitbang_t* jtag;
extern "C" int jtag_tick(
    unsigned char* jtag_TCK,
    unsigned char* jtag_TMS,
    unsigned char* jtag_TDI,
    unsigned char* jtag_TRSTn,
    unsigned char jtag_TDO,
    unsigned int jtag_port)
{
    if (!jtag) {
        // TODO: Pass in real port number
        jtag = new remote_bitbang_t(jtag_port);
    }

    jtag->tick(jtag_TCK, jtag_TMS, jtag_TDI, jtag_TRSTn, jtag_TDO);

    return jtag->done() ? (jtag->exit_code() << 1 | 1) : 0;
}
