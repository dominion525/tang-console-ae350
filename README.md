# A Hazard3 version of AE350, and a board design for Tang Console

[日本語](README.ja.md)

This repository is for working with AE350 (= Andes A25), the RISC-V hard core inside the Gowin GW5AST-138. It has two parts.

- **Hazard3 version** (= `rtl/AE350_SOC.v`): a circuit with the same ports as Gowin's `AE350_SOC` primitive, running Hazard3 inside. It is used for simulation and can also run in the FPGA fabric (= `CPU=hazard3`). Gowin's simulation model only declares the ports and does not run, so this is used in its place. The bus behavior, address map, PLIC / PLMT, and clock domain crossings follow the documentation and measurements on the real chip
- **Board design** (= `board/tang_console/`): runs the real AE350 on a Tang Console 138K. A CPU program reads register values and prints them over UART

## Directories

    rtl/                 Hazard3 version (= AE350_SOC.v, ae350_fabric.v, ae350_plic.v, ae350_plmt.v, ...) and the FPGA fabric side
                         (= apb_uart.v, apb_gpint.v, apb_paddr_probe.v, apb_reg_slice.v, ahb_reg_slice.v, ahb_sram.v, ahb_rom.v)
    tb/                  shell_top.v (= top that connects AE350_SOC and the fabric side; used in simulation and on the board), testbenches
    sw/                  test programs (= stages 2-5), the probe program probe.c, linker scripts
    board/tang_console/  board top, PLLs, pin and clock constraints, build scripts, observer circuit
    hazard3/             Hazard3 v1.1.1 RTL (= changes are listed in hazard3/README.md)
    tools/               port comparison, lint and coverage settings, hex conversion

## Simulation

Uses Verilator 5.052, Icarus Verilog 13.0, riscv64-elf-gcc, and newlib (= pass its location with `NEWLIB`; there is no default).

    make check          compare the primitive's ports, lint, read with iverilog
    make test           stages 2-5, unit testbenches for PLIC and RAM, clock combinations, reset during execution, random wait states
    make test-iverilog  run stages 2-5 with 4-state simulation
    make coverage       coverage
    make run-probe      run the probe program on the Hazard3 version

### Building newlib (= once, before the first build)

To build programs that use newlib (= stages 3-5, hello, ddr3_check, mem_bench, CoreMark, ...), pass the newlib location with `NEWLIB` (= `make test NEWLIB=<prefix>/riscv64-elf`). Without it, the build stops when it reaches a program that uses newlib. The tested version is 4.6.0.20260123, built for the same target as riscv64-elf-gcc (= Homebrew). The tarball does not contain the libgloss manual (= porting.info), and building the manual needs makeinfo (= texinfo), so `MAKEINFO=true` skips the manual (= the libraries are not affected).

    curl -O https://sourceware.org/pub/newlib/newlib-4.6.0.20260123.tar.gz
    tar xf newlib-4.6.0.20260123.tar.gz
    mkdir newlib-build && cd newlib-build
    ../newlib-4.6.0.20260123/configure --target=riscv64-elf --prefix=<prefix> \
        --enable-newlib-io-long-double --enable-newlib-io-long-long --enable-newlib-io-c99-formats \
        --enable-newlib-register-fini CFLAGS_FOR_TARGET="-Os -mcmodel=medany"
    make MAKEINFO=true && make install MAKEINFO=true

## Board

    sh board/tang_console/build.sh
    openFPGALoader -b tangconsole build/board/ae350_probe/impl/pnr/ae350_probe.fs

Built with Gowin EDA Education 1.9.11.03 for chip revision B. The ROM is block RAM (= contents from `sw/probe.c`), data and stack are in the DLM inside AE350, and DDR3 is not used. Output goes to the second USB serial port (= /dev/cu.usbserial-<number>1 on macOS) at 1,250,000 bps (= macOS stty does not accept speeds above 230400, so the port is kept open and set with `IOSSIOSPEED`). Send any character to print the values again. Read the output with `tools/ae350_uart.rb` (= prints what it receives and sends keyboard input; it ends after the given number of seconds, or on Ctrl-C if no seconds are given).

    printf x | ruby tools/ae350_uart.rb /dev/cu.usbserial-<number>1 15

When the CPU output stops for more than 0.1 s, the observer circuit (= `board/tang_console/ae350_observer.v`) prints the following line without going through the CPU.

    OBS lk=<PLL lock> rs=<reset released> hr=<HRESETN> pr=<PRESETN> rom=<ROM_H* read count> ra=<last address>
        apb=<APB_P* transfer count> pa=<last PADDR> tx=<characters sent by the CPU> c=<last character> m=<other outputs>

### Settings needed to run the real AE350

- **Place the PLL that drives CORE_CLK at `PLL_R[0]`.** AE350's CORE_CLK comes through a dedicated route from clkout1 of `PLL_R[0]` (= Gowin MUG1031 8.4). Without the placement, synthesis and place-and-route pass without warnings, but AE350 keeps HRESETN / PRESETN at 0 and never fetches an instruction. The placement is `INS_LOC "u_pll/u_pll_s8" PLL_R[0];` in `top.cst` (= names after synthesis get a `_s` suffix)
- **Inputs when JTAG is not used: `DBG_TCK` / `TMS_IN` / `TRST_IN` = 1, `TDI_IN` = 0.** `POR_N` is 1, and reset is applied only through `HW_RSTN` (= the same values as LiteX's gowin_ae350)
- **Put registers on `APB_P*` and `EXTS_H*`.** AE350 sits at the edge of the FPGA (= R0C160), and the routing alone takes about 4 ns each way. A path that leaves AE350, goes through fabric logic, and returns to AE350 does not meet timing at 100 MHz. Before the registers were added, `APB_P*` stopped in the middle of a UART write. With the registers, the `EXTS_H*` slice is placed near AE350 with `GRP_LOC`. The place-and-route report for the `SDRAM=hs ROM=loader` build (= 2026-11-12) gave AHB_CLK 106.4 MHz and APB_CLK 130.3 MHz (= the numbers change with the build options and placement)

### Values read on the board

    CPU identifiers          mvendorid 0x31e, marchid 0x80000a25, mimpid 0x160
    misa                     0x4094312d (= RV32 IMAFDC + N, S, U, X)
    ILM / DLM                0xA000_0000 / 0xA020_0000, enabled from reset
    cache after reset        mcache_ctl 0 (= disabled)
    mcycle and mtime         mcycle 800 MHz, mtime 100 MHz (= counts with AHB_CLK)
    PLIC                     2 targets (= 0 is MEIP, 1 is SEIP), 31 sources, priorities 0-3, all sources level-triggered,
                             claim is filtered by the threshold, complete works even when enable is cleared
    GP_INT                   GP_INT[0] -> source 4, GP_INT[1-15] -> sources 11-25
    APB_P* PADDR             every address from 0xF800_0000 up appears on PADDR. 1- and 2-byte accesses are aligned to 4 bytes,
                             and PWDATA carries values only in the byte lanes being written

The Hazard3 version follows these values. Because the CPU inside is Hazard3, it differs from the real AE350 in the following points.

- No caches, no F / D extensions, no S mode (= misa is Hazard3's value; the PLIC target 1 notification is not connected to the CPU)
- No Andes CSRs (= milmb, mdlmb, mcache_ctl, mmisc_ctl, ...; reading them raises an illegal instruction exception)
- Instruction fetch speed and bus wait cycles

## Loader (= send a program over UART and run it from SDRAM)

With the loader (= `sw/loader.c`, 2,001 bytes) in the ROM, a program can be sent over UART to the memory behind DDR_H* (= the baseboard SDRAM0, 32 MB, for the SDRAM build; the SOM DDR3, 1 GB, for the DDR3 build) or to the ILM, without burning it into the 16 KB ROM. Programs can be sent again and again, overwriting the previous one, without rebuilding the bitstream.

    SDRAM=hs ROM=loader sh board/tang_console/build.sh build/board-loader
    openFPGALoader -b tangconsole build/board-loader/ae350_probe/impl/pnr/ae350_probe.fs
    make build/hello.bin
    ruby tools/ae350_load.rb /dev/cu.usbserial-<number>1 build/hello.bin

`ae350_load.rb` resets AE350 back into the loader with the UART reset sequence, sends the program, checks the length and CRC-32, and runs it if they match. After that it shows the UART output and sends keyboard input. It ends when the program returns to the loader or on Ctrl-C. The UART runs at 1,250,000 bps (= set with `IOSSIOSPEED` on macOS). In the loader build, the observer circuit is left out.

### Commands and replies

Commands are one line of text; addresses and lengths are 8 hexadecimal digits. Replies end with `\r\n`.

    Mac -> loader                          loader -> Mac
    (power on, return from a program)      READY ae350 loader
    load <address> <length>                GO (= ready to receive) / ERR range / ERR syntax
    <payload (= length bytes)>             OK <length> <CRC-32> / ERR timeout / ERR uart
    run <address>                          RUN <address> (= program output follows)
    anything else                          ERR command

- Send the payload only after `GO`, so that a refused payload is not read as commands
- The address and length must fit in the memory behind DDR_H* or in the ILM (= 0xA000_0000-0xA000_FFFF), otherwise `ERR range`. The size behind DDR_H* is detected at start-up by reading 0x0200_0000 (= an exception means the SDRAM build with 32 MB, otherwise the DDR3 build with 1 GB)
- The CRC-32 in `OK` is computed over the payload read back from the memory behind DDR_H* after writing (= same value as zlib; Ruby's `Zlib.crc32` can check it)
- If the next byte of the payload does not arrive within 1 second, the reply is `ERR timeout`. If the receiver overflows or a character with a 0 stop bit is dropped while receiving, the reply is `ERR uart`. Both return to waiting for a command
- While receiving, the data cache is off and the payload is written straight to the memory behind DDR_H*. `run` executes `fence` and `fence.i`, turns the data cache on, and jumps. At start-up the whole data cache is written back and invalidated (= so that values from the previous program are not written back over the new one)

### Programs that run from SDRAM

The linker script is `sw/sdram.ld`. It places code, data, and heap in SDRAM from 0x0001_0000, and the stack in the DLM. Building `sw/start.S` with `START_RETURN_TO_ROM` defined makes a return from `main` go back to the loader in ROM. For how to build one, see `hello.bin` in the Makefile (= 48,464 bytes, using newlib's printf and fgets).

### Returning to the loader with the UART reset sequence

When the 8-byte reset sequence `1B 1B 61 65 33 35 30 21` (= ESC ESC "ae350!") arrives on the UART in a row, `rtl/uart_reset_seq.v` asserts reset on AE350's `HW_RSTN` for 10 µs, and AE350 starts again from the loader in ROM. A hung program can be recovered without power cycling. The SDRAM controller and the sequence watcher itself are not reset. While the loader is receiving a payload, the watcher is disabled (= CTRL in `rtl/apb_uart.v`), so a payload containing these 8 bytes does not trigger a reset. Sending input that contains these 8 bytes while a program is running does trigger a reset.

### Tests

    make test-loader       refused commands, GO, timeout, receive errors, CRC-32, payload containing the reset sequence,
                           returning by the reset sequence from a program that does not stop,
                           sending and running hello (= sent at the board's 1.25 Mbps pace; takes a few minutes)
    make test-uart-reset   unit testbench for the reset sequence circuit

The command scripts are generated by `tools/loader_test.rb` and fed through the testbench's `+uart_script`. Both targets are part of `make test`.

### Checked on the board (= 166.7 MHz version)

- Sent hello in 0.4 s and ran it; after it returned to the loader, sent and ran it again without power cycling
- After running a program that does not stop, returned with the reset sequence and ran hello without power cycling

## DDR3 build (= DDR_H* goes to the SOM DDR3)

    MEM=ddr3 ROM=loader sh board/tang_console/build.sh build/board-ddr3

DDR_H* goes to the SOM DDR3 (= two H5TQ4G63EFR, 32-bit DQ, 1 GB) instead of the baseboard SDRAM. The DDR3 controller is Gowin's DDR3 Memory Interface IP (= memory clock 400 MHz, 1:4), and `rtl/ahb_ddr3.v` connects it to DDR_H*. In simulation, DDR_H* still goes to SDRAM; the DDR3 build is checked only on the board (= the IP body is encrypted and cannot be simulated).

### Generating the IP (= once, before the first build)

The IP body is generated by Gowin's tools and is not in the repository. Generate it from the settings (= `board/tang_console/ddr3/ddr3_memory_interface.ipc`) with the IP Core Generator in Gowin EDA.

1. Open the IP Core Generator and open `board/tang_console/ddr3/ddr3_memory_interface.ipc` with Open Config File
2. Check that Device is GW5AST-138 and Device Version is B, then press OK
3. `ddr3_memory_interface.v` is created in the same folder (= "Decode Process failed" may appear; only the simulation `.vo` is missing, which synthesis does not use)

For a board with chip revision C, set `target_device` in the `.ipc` to `gw5ast138c-007` (= and change `-device_version` in `build.tcl` and `board/tang_console/ddr3/gowin_pll.mod` to C). The DDR3 PLL body (= `gowin_pll_mod.v`) is generated by `build.sh` from `board/tang_console/ddr3/gowin_pll.mod` with Gowin's GowinModgen into the output directory.

The settings, the PLL wrapper (= `gowin_pll.v`, `pll_init.v`), and the pin constraints (= `ddr3.cst`) come from `ddr_memory/ddr_memory_test_uart` in Sipeed's TangMega-138K-example (= Apache-2.0; a DDR3 test that runs on the Tang Console 138K).

### Bridge (= `rtl/ahb_ddr3.v`)

- Each DDR_H* transfer (= 64-bit AHB, DDR_CLK 50 MHz) is moved to the IP clock (= 100 MHz) one at a time and turned into an IP read or write command. One IP command reads or writes 32 bytes (= 32-bit DQ x 8 beats)
- Writes write only the bytes selected by HSIZE and the address within the 32 bytes (= the others are masked). The reply goes back to AE350 when the IP accepts the command
- Reads read 32 bytes, return the 8 bytes selected by address bits 4-3, and keep the 32 bytes. Reads of the same 32 bytes are answered from the kept value without going to the IP. Writes to the same 32 bytes also update the kept value
- Addresses outside 1 GB get an error response, except the 32 bytes from 0x7F00_0000, which are counters for measuring time (= read for the value; `sw/mem_bench.c` takes the difference before and after)

      +0x00 number of read transfers                    +0x04 DDR_CLK cycles AE350 waited on reads
      +0x08 number of write transfers                   +0x0C DDR_CLK cycles AE350 waited on writes
      +0x10 IP clocks until a read command is accepted  +0x14 IP clocks from a read command to its data
      +0x18 IP clocks until a write command is accepted +0x1C reads answered from the kept 32 bytes

### Speed (= `sw/mem_bench.c`, no data cache, per access in AE350 CPU cycles at 800 MHz)

    access                          DDR3             SDRAM (= 166.7 MHz version)
    sequential write                96 (= 120 ns)    258 (= 322 ns)
    sequential read                 179 (= 224 ns)   320 (= 400 ns)
    random read (= 4 KB stride)     468 (= 585 ns)   320 (= 400 ns)

In sequential reads, 7 out of 8 reads are answered from the kept 32 bytes. In random reads, every read goes to the IP, and the IP itself (= from the read command to the data) takes about 32 IP clock cycles (= 320 ns). The time before DDR_H* (= inside AE350) and in the clock crossing is the same as in the SDRAM build. CoreMark with the data cache enabled is almost the same in the DDR3 and SDRAM builds (= 2183.7 and 2183.8).

### Hazard3 version

`CPU=hazard3 MEM=ddr3` also builds. For the Hazard3 version, `build.sh` sets the placement option (= Gowin's `place_option`) to 2. The slow path inside Hazard3 (= from receiving an instruction to decode and bypass) has almost no margin at 40 MHz; in the DDR3 build, core_clk reached 38.5 MHz with the default placement and 40.1 MHz with `PLACE=2`.

### Checked on the board

- `sw/ddr3_check.c` (= placed in the ILM, writes to DDR3 and reads back with the data cache off): addresses 0 and 2^5-2^29 (= the address lines of 1 GB), the four 8-byte parts in 32 bytes (= one IP command), and 1 / 2 / 4-byte writes matched, and outside 1 GB (= 0x4000_0000) raised exception 5
- Ran hello and CoreMark (= `build/coremark.bin`) placed in DDR3
- With the loader, the CRC-32 of payloads sent to 0x3FFF_0000 and 0x0200_0000 matched, and 32 bytes from 0x3FFF_FFF0 and 0x4000_0000 gave `ERR range`
- The Hazard3 version (= `CPU=hazard3 MEM=ddr3`) also ran `ddr3_check`, `mem_bench`, hello, and CoreMark (= 8.28, with the program in DDR3)

## LiteDRAM build (= open-source DDR3 controller)

    MEM=litedram ROM=loader sh board/tang_console/build.sh build/board-litedram

DDR_H* goes to the same SOM DDR3 as the DDR3 build (= two chips, 32-bit DQ, 1 GB), with LiteDRAM (= BSD-2-Clause) as the controller instead of Gowin's IP. The addresses and size are the same as the DDR3 build, so `sw/ddr3_check.c` and `sw/mem_bench.c` run unchanged. It is slower than Gowin's IP, but it is open source including the generated Verilog, and it does not need the step of generating the IP with the IP Core Generator.

### Creating the LiteX virtual environment (= once, before the first build)

On every synthesis, `build.sh` runs LiteDRAM's `litedram_gen` to write the controller Verilog into the output directory from the settings (= `board/tang_console/litedram/tang_console.yml`). `litedram_gen` is installed in a Python virtual environment, whose location is given with `LITEX_VENV` (= `MEM=litedram LITEX_VENV=<venv> sh board/tang_console/build.sh`; there is no default). The tested versions are as follows (= installed with pip).

    migen                            https://github.com/m-labs/migen                                e19524c
    litex                            https://github.com/enjoy-digital/litex                         8cba6a6
    litedram                         https://github.com/enjoy-digital/litedram                      60b5ae1
    litex-boards                     https://github.com/litex-hub/litex-boards                      78bc7d7
    pythondata-cpu-vexriscv          https://github.com/litex-hub/pythondata-cpu-vexriscv           642ecfe
    pythondata-software-picolibc     https://github.com/litex-hub/pythondata-software-picolibc      6a13ccc
    pythondata-software-compiler_rt  https://github.com/litex-hub/pythondata-software-compiler_rt   6eb7660
    meson 1.9.1, ninja 1.13.0

To create it (= install each repository at the commit above; picolibc and compiler_rt keep their contents in git submodules, so they are installed from git instead of a tarball):

    python3 -m venv <venv>
    <venv>/bin/pip install meson==1.9.1 ninja==1.13.0
    <venv>/bin/pip install \
        https://github.com/m-labs/migen/archive/e19524c963a8342952840983047557707fbe0b6a.tar.gz \
        https://github.com/enjoy-digital/litex/archive/8cba6a6cc4455e5549b67ef8f9388116e9294d71.tar.gz \
        https://github.com/enjoy-digital/litedram/archive/60b5ae1b1ee5bc16ea695a93399434919797ff31.tar.gz \
        https://github.com/litex-hub/litex-boards/archive/78bc7d7e4a3b88098d552345444f2739f15a04f3.tar.gz \
        https://github.com/litex-hub/pythondata-cpu-vexriscv/archive/642ecfed1c84460555d6d803d660cc60cfc1ecb6.tar.gz \
        git+https://github.com/litex-hub/pythondata-software-picolibc@6a13ccce7c575b32c102dd9dc52178505b81fe39 \
        git+https://github.com/litex-hub/pythondata-software-compiler_rt@6eb76609c9627bf26635e57c63fb22cda7115887

The generated controller contains a small CPU (= VexRiscv) for initialization and read leveling, and its program (= the LiteX BIOS). The program is built with the same RISC-V compiler as the other programs (= `riscv64-elf-gcc`). `build.sh` rewrites the file paths used to load the ROM contents in the generated Verilog to absolute paths, and adds the VexRiscv Verilog from the virtual environment to synthesis. The generated files are not in the repository.

### Settings

    speed       1:2, controller 50 MHz, DDR3 clock 100 MHz (= 200 MT/s, DLL off)
    user port   native (= 32 bytes per access, 25-bit address)
    pins        board/tang_console/litedram/ddram.cst (= first chip from LiteX-Boards' Tang Console definition, second from Sipeed's DDR3 test .cst)

The faster setting (= 1:4, controller 100 MHz, DDR3 400 MHz) was not chosen because the controller clock did not meet timing at 100 MHz. Details are at the top of `tang_console.yml`.

From power-on until initialization and leveling finish, LiteDRAM's initialization log (= 115,200 bps) appears on the board UART. After that, the UART switches to AE350.

### Bridge (= `rtl/ahb_litedram.v`)

Like `rtl/ahb_ddr3.v`, it moves DDR_H* transfers to the LiteDRAM controller clock (= 50 MHz) and turns them into native port commands. Keeping the last 32 bytes read, the error response outside 1 GB, and the counter layout from 0x7F00_0000 are also the same (= the "IP clock" in the counters is the LiteDRAM controller clock). The DDR3 size and access width are parameters (= `MEM_AW`, `LINE_AW`), so a single DDR3 chip (= 512 MB, 16 bytes) also works.

### Speed (= `sw/mem_bench.c`, no data cache, per access in AE350 CPU cycles at 800 MHz)

    access                          LiteDRAM         DDR3 (= Gowin IP)   SDRAM (= 166.7 MHz version)
    sequential write                298 (= 372 ns)   96 (= 120 ns)       258 (= 322 ns)
    sequential read                 260 (= 325 ns)   179 (= 224 ns)      320 (= 400 ns)
    random read (= 4 KB stride)     781 (= 976 ns)   468 (= 585 ns)      320 (= 400 ns)

From a read command to its data takes about 34 controller clock cycles, almost the same as Gowin's IP (= about 32 cycles). The controller clock is half that of Gowin's IP (= 50 MHz and 100 MHz), so the time is about twice as long. Writes take about 12 controller clock cycles until the command and data are accepted (= 1 cycle for Gowin's IP).

### Checked on the board

- LiteDRAM's initialization log showed initialization as 1.0 GiB 32-bit @ 200 MT/s, read leveling passed for all 4 groups (= DQS), and LiteDRAM's own memory test passed
- With `sw/ddr3_check.c`, the 1 GB address lines, the four 8-byte parts in 32 bytes, and 1 / 2 / 4-byte writes matched, and outside 1 GB (= 0x4000_0000) raised exception 5
- The 1024 words read in the sequential read of `sw/mem_bench.c` matched the written values
- Ran hello placed in DDR3 (= with one DDR3 chip, 512 MB)

## License

This repository is Apache-2.0 (= `LICENSE`). The following files were made by others and are included under their original licenses.

    location                                     origin                                            license (= text)
    hazard3/                                     Hazard3 v1.1.1 (= Luke Wren). Changes are listed  Apache-2.0 (= hazard3/LICENSE)
                                                 in hazard3/README.md
    rtl/vendor/verilog-uart/                     verilog-uart (= Alex Forencich)                   MIT (= rtl/vendor/verilog-uart/COPYING)
    tb/vendor/zeitlos/sdram_model.v              zeitlos (= Lone Dynamics). Changes are listed at  own terms (= tb/vendor/zeitlos/LICENSE.md)
                                                 the top of the file
    board/tang_console/ddr3/                     Sipeed's TangMega-138K-example. Origin of each    Apache-2.0 (= LICENSE)
                                                 file is in board/tang_console/ddr3/README.md
    board/tang_console/litedram/tang_console.yml examples/tang_mega_138k_pro.yml in LiteDRAM       BSD-2-Clause (= board/tang_console/litedram/LICENSE.litedram)
    board/tang_console/litedram/ddram.cst        first DDR3: LiteX-Boards' Tang Console definition BSD-2-Clause (= board/tang_console/litedram/LICENSE.litex-boards)
                                                 second DDR3: Sipeed's TangMega-138K-example       Apache-2.0 (= LICENSE)
