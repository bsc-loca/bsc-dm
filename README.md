# BSC RISC-V Debug Module

This repo contains an implementation of a Debug Module that conforms to the non-ISA part of the [RISC-V Debug Specification version 1.0.0-rc3](https://github.com/riscv/riscv-debug-spec).

## Build
For building the simulation, run:
```sh
make
```

## JTAG probe simulation with OpenOCD
First, we need to compile OpenOCD with the remote-bitbang transport for being able to communicate with the simulated JTAG probe:
```sh
git clone https://gitlab.bsc.es/atafalla/openocd && cd openocd
./bootstrap
./configure --disable-all --enable-remote_bitbang
make -j8
```

Open a terminal and run the simulation with `./sim`. It will start and print a message with the network port where it's listening.

Then, on another terminal and from the openocd directory, run:
```
./src/openocd -c "debug_level 3" -c "adapter driver remote_bitbang" -c "remote_bitbang host localhost" -c "remote_bitbang port 44589" -c "jtag newtap ox cpu -irlen 5 -expected-id 0x149511c3" -c "target create op riscv -chain-position ox.cpu" -c "init" 2>&1 | tee openocd.log
```
