# AE350 Hazard3 Version and Tang Console Board Design

[日本語](README.ja.md)

This repository targets AE350 (Andes A25), the RISC-V hard core built into the Gowin GW5AST-138.
It consists of two parts.

- **Hazard3 version** (`rtl/AE350_SOC.v`): a circuit with the same ports as Gowin's `AE350_SOC` primitive, with a Hazard3 core inside.
  Gowin's simulation model only declares the ports and does not simulate anything, so this version is used in its place.
  It can also run in the FPGA fabric (`CPU=hazard3`).
  Its bus behavior, address map, PLIC and PLMT, and clock domain crossings follow the documentation and measurements taken on real hardware.
- **Board design** (`board/tang_console/`): runs the real AE350 on a Tang Console 138K.
  A program on the CPU reads register values and prints them over the UART.

## Repository layout

| Directory             | Contents                                                                                                                                                                                                                     |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rtl/`                | The Hazard3 version (AE350_SOC.v, ae350_fabric.v, ae350_plic.v, ae350_plmt.v, and others) and the fabric-side circuits (apb_uart.v, apb_gpint.v, apb_paddr_probe.v, apb_reg_slice.v, ahb_reg_slice.v, ahb_sram.v, ahb_rom.v) |
| `tb/`                 | shell_top.v (the top level that connects AE350_SOC to the fabric-side circuits; used both in simulation and on the board) and the testbenches                                                                                |
| `sw/`                 | Test programs (stage2_test.c to stage5_test.c), the probe program probe.c, and linker scripts                                                                                                                                |
| `board/tang_console/` | Board top level, PLLs, pin and timing constraints, build scripts, and the monitor circuit                                                                                                                                    |
| `hazard3/`            | Hazard3 v1.1.1 RTL (changes are listed in [hazard3/README.md](hazard3/README.md))                                                                                                                                            |
| `tools/`              | Port comparison, lint and coverage settings, hex conversion, and UART access                                                                                                                                                 |

## Simulation

Simulation uses Verilator 5.052, Icarus Verilog 13.0, riscv64-elf-gcc, and newlib.
Pass the newlib location with `NEWLIB`; there is no default.

| Command              | Description                                                                                                      |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `make check`         | Compare ports with the primitive, run lint, and parse the sources with iverilog                                  |
| `make test`          | Test programs, PLIC and RAM unit tests, clock ratio combinations, reset during execution, and random wait states |
| `make test-iverilog` | Run the test programs with 4-state simulation                                                                    |
| `make coverage`      | Coverage                                                                                                         |
| `make run-probe`     | Run the probe program on the Hazard3 version                                                                     |

### Building newlib (first time only)

To build the programs that use newlib (stage3_test to stage5_test, hello, ddr3_check, mem_bench, CoreMark, and others), set `NEWLIB` to the newlib location, for example `make test NEWLIB=<prefix>/riscv64-elf`.
Without it, the build stops at the first program that needs newlib.
The tested version is 4.6.0.20260123, built for the same target as Homebrew's riscv64-elf-gcc.
The tarball does not include the libgloss manual (porting.info), and generating it requires makeinfo (texinfo), so `MAKEINFO=true` skips the manual.
The libraries themselves are not affected.

    curl -O https://sourceware.org/pub/newlib/newlib-4.6.0.20260123.tar.gz
    tar xf newlib-4.6.0.20260123.tar.gz
    mkdir newlib-build && cd newlib-build
    ../newlib-4.6.0.20260123/configure --target=riscv64-elf --prefix=<prefix> \
        --enable-newlib-io-long-double --enable-newlib-io-long-long --enable-newlib-io-c99-formats \
        --enable-newlib-register-fini CFLAGS_FOR_TARGET="-Os -mcmodel=medany"
    make MAKEINFO=true && make install MAKEINFO=true

## Running on the board

    sh board/tang_console/build.sh
    openFPGALoader -b tangconsole build/board/ae350_probe/impl/pnr/ae350_probe.fs

The design is built with Gowin EDA Education 1.9.11.03 for chip revision B.
**It has been verified only on a Tang Console 138K with chip revision B.**
Boards with chip revision C have not been tested.
To try it on a revision C board, change `-device_version` in `board/tang_console/build.tcl` to C before building.
For the DDR3 build, also change the DDR3 IP and PLL settings to C (see "Generating the IP").

In the default build, the ROM is block RAM holding `sw/probe.c`, and data and stack are placed in the DLM inside AE350.
DDR3 is not used.

DDR_H* is connected to the SDRAM on the baseboard (32 MB).
There are two SDRAM controllers, selected with the `SDRAM` environment variable.

| Setting    | Controller                                 | Clock     |
| ---------- | ------------------------------------------ | --------- |
| none       | `rtl/sdram_bridge.v`                       | 20 MHz    |
| `SDRAM=hs` | `rtl/sdram_ctrl_hs.v` and `rtl/sdram_io.v` | 166.7 MHz |

Below, a build with SDRAM behind DDR_H* is called the **SDRAM build**, and the `SDRAM=hs` variant of it the **166.7 MHz build**.

Output appears on the second USB serial port (`/dev/cu.usbserial-<number>1` on macOS) at 1,250,000 bps.
The macOS `stty` command does not accept rates above 230400 bps, so the scripts that talk to the UART (`tools/ae350_uart.rb` and `tools/ae350_load.rb`) set the rate with the macOS `IOSSIOSPEED` call while the port is open.
As a result, these two scripts run only on macOS.

Use `tools/ae350_uart.rb` to read the output.
The script prints whatever it receives and sends keyboard input to the board.
It exits after the given number of seconds, or on Ctrl-C if no duration is given.
The probe program prints its values again each time it receives a character, so send one character to read them from the beginning.
For about 10 seconds after start-up, however, the program is measuring time and does not accept characters, so to read everything right after programming the board, wait about 15 seconds as shown below.

    printf x | ruby tools/ae350_uart.rb /dev/cu.usbserial-<number>1 15

If the CPU stops printing for more than 0.1 s, the monitor circuit (`board/tang_console/ae350_observer.v`) prints the following line on its own, without the CPU.

    OBS lk=<PLL lock> rs=<reset released> hr=<HRESETN> pr=<PRESETN> rom=<ROM_H* read count> ra=<last address>
        apb=<APB_P* transfer count> pa=<last PADDR> tx=<characters sent by the CPU> c=<last character> m=<other outputs>

### Settings required to run the real AE350

- **CORE_CLK PLL placement**: Place the PLL that generates CORE_CLK at `PLL_R[0]`.
  AE350's CORE_CLK is supplied over dedicated routing from clkout1 of `PLL_R[0]` (Gowin MUG1031, section 8.4).
  Without this placement, synthesis and place-and-route complete without warnings, but AE350 holds HRESETN and PRESETN at 0 and never fetches an instruction.
  The placement is set with `INS_LOC "u_pll/u_pll_s8" PLL_R[0];` in `top.cst` (instance names get an `_s` suffix after synthesis).
- **JTAG inputs**: When JTAG is not used, tie `DBG_TCK`, `TMS_IN`, and `TRST_IN` to 1 and `TDI_IN` to 0.
  Tie `POR_N` to 1 and apply reset only through `HW_RSTN` (the same values as LiteX's gowin_ae350).
- **Registers on `APB_P*` and `EXTS_H*`**: Insert registers on `APB_P*` and `EXTS_H*`.
  AE350 sits at the edge of the FPGA (R0C160), and routing alone takes about 4 ns each way.
  A path that leaves AE350, passes through fabric logic, and returns to AE350 does not meet timing at 100 MHz.
  Without the registers, UART writes over `APB_P*` stalled partway through.
  In addition to the registers, the `EXTS_H*` slices are placed near AE350 with `GRP_LOC`.
  For the `SDRAM=hs ROM=loader` build, place-and-route reported AHB_CLK at 106.4 MHz and APB_CLK at 130.3 MHz (the figures vary with the build options and placement).

### Values read on the board

| Item                    | Value                                                                                                                                                                                          |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CPU identification      | mvendorid 0x31e, marchid 0x80000a25, mimpid 0x160                                                                                                                                              |
| misa                    | 0x4094312d (RV32 IMAFDC + N, S, U, X)                                                                                                                                                          |
| ILM and DLM             | 0xA000_0000 and 0xA020_0000, enabled out of reset                                                                                                                                              |
| Cache state after reset | mcache_ctl 0 (disabled)                                                                                                                                                                        |
| mcycle and mtime        | mcycle runs at 800 MHz and mtime at 100 MHz (clocked by AHB_CLK)                                                                                                                               |
| PLIC                    | 2 targets (0 is MEIP, 1 is SEIP), 31 sources, priorities 0 to 3, all sources level-triggered. Claims are filtered by the threshold, and complete takes effect even when the source is disabled |
| GP_INT                  | GP_INT[0] maps to source 4, and GP_INT[1] to GP_INT[15] map to sources 11 to 25                                                                                                                |
| APB_P* PADDR            | Every address from 0xF800_0000 upward appears. Byte and halfword accesses are aligned to 4 bytes, and PWDATA carries data only in the byte lanes being written                                 |

The Hazard3 version follows these values.
Because its CPU is Hazard3, however, it differs from the real AE350 in the following ways.

- It has no caches, no F or D extension, and no S mode (misa holds Hazard3's value, and PLIC target 1 is not connected to the CPU).
- It has no Andes-specific CSRs such as milmb, mdlmb, mcache_ctl, and mmisc_ctl (accessing them raises an illegal instruction exception).
- Instruction fetch speed and bus wait cycles differ.

## Loader (sending a program over the UART and running it from external memory)

With the loader (`sw/loader.c`, 2,001 bytes) in the ROM, programs can be sent over the UART and run without burning them into the 16 KB ROM.
The destination is either the external memory behind DDR_H* (the 32 MB SDRAM0 on the baseboard in the SDRAM build, or the 1 GB DDR3 on the SOM in the DDR3 build) or the ILM.
Programs can be sent repeatedly, overwriting the previous one, without rebuilding the bitstream.

    SDRAM=hs ROM=loader sh board/tang_console/build.sh build/board-loader
    openFPGALoader -b tangconsole build/board-loader/ae350_probe/impl/pnr/ae350_probe.fs
    make build/hello.bin
    ruby tools/ae350_load.rb /dev/cu.usbserial-<number>1 build/hello.bin

`ae350_load.rb` resets AE350 into the loader with the UART reset sequence, sends the program, verifies the length and CRC-32, and runs the program if they match.
It then prints the UART output and sends keyboard input.
It exits when the program returns to the loader, or on Ctrl-C.
The UART runs at 1,250,000 bps (for how the rate is set, see "Running on the board").
Builds with the loader in ROM do not include the monitor circuit.

### Commands and responses

Each command is a single line of text, with addresses and lengths written as 8 hexadecimal digits.
Responses end with `\r\n`.

| Host to loader                           | Loader to host                                        |
| ---------------------------------------- | ----------------------------------------------------- |
| (at power-on, or when a program returns) | `READY ae350 loader`                                  |
| `load <address> <length>`                | `GO` (ready to receive), `ERR range`, or `ERR syntax` |
| Data (length bytes)                      | `OK <length> <CRC-32>`, `ERR timeout`, or `ERR uart`  |
| `run <address>`                          | `RUN <address>` (followed by the program's output)    |
| Anything else                            | `ERR command`                                         |

- Send the data only after receiving `GO`, so that rejected data is not interpreted as commands.
- If the address and length do not fit within the external memory or the ILM (0xA000_0000 to 0xA000_FFFF), the loader returns `ERR range`.
  The loader determines the external memory size at start-up by reading 0x0200_0000 (an exception means the SDRAM build with 32 MB; otherwise it is the DDR3 build with 1 GB).
- The CRC-32 in `OK` is computed over the data read back from external memory after writing.
  It matches zlib's CRC-32, so Ruby's `Zlib.crc32` can verify it.
- If the next byte of data does not arrive within 1 second, the loader returns `ERR timeout`.
  If the receive buffer overflows during reception, or a character with a 0 stop bit is discarded, it returns `ERR uart`.
  In both cases it goes back to waiting for a command.
- During reception, the data cache is disabled and data is written directly to external memory.
  `run` executes `fence` and `fence.i`, enables the data cache, and then jumps to the program.
  At start-up, the loader writes back and invalidates the entire data cache, so that data from the previous program is not written back over the new one.

### Programs that run from external memory

The linker script is `sw/sdram.ld`.
It places code, data, and heap in external memory starting at 0x0001_0000, and the stack in the DLM.
If `sw/start.S` is built with `START_RETURN_TO_ROM` defined, returning from `main` goes back to the loader in ROM.
For the build steps, see the `hello.bin` target in the Makefile (a 48,464-byte program that uses newlib's printf and fgets).

### Returning to the loader with the reset sequence

When the 8-byte reset sequence `1B 1B 61 65 33 35 30 21` (ESC ESC "ae350!") arrives consecutively on the UART, `rtl/uart_reset_seq.v` asserts AE350's `HW_RSTN` for 10 µs, and AE350 restarts from the loader in ROM.
A hung program can be recovered this way without a power cycle.
The SDRAM controller and the sequence detector itself are not reset.
While the loader is receiving data, detection is disabled (the CTRL register in `rtl/apb_uart.v`), so a program that contains these 8 bytes does not trigger a reset.
Sending input that contains these 8 bytes while a program is running does trigger a reset.

### Loader tests

| Command                | Description                                                                                                                                                                                                                                                              |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `make test-loader`     | Rejected commands, GO, timeout, receive errors, CRC-32, data containing the reset sequence, recovery from a program that never returns by the reset sequence, and sending and running hello (sent at the same 1.25 Mbps pace as on the board, so it takes a few minutes) |
| `make test-uart-reset` | Unit test of the reset sequence detector                                                                                                                                                                                                                                 |
| `make test-uart-tool`  | Unit test of tools/ae350_uart.rb (uses a UNIX domain socket pair in place of a serial port)                                                                                                                                                                              |

The command script for `make test-loader` is generated by `tools/loader_test.rb` and fed to the testbench through `+uart_script`.
All three are part of `make test`.

### Verified on the board (166.7 MHz build)

- Sent hello in 0.4 s and ran it; after it returned to the loader, sent and ran it again without a power cycle.
- After running a program that never returns, recovered with the reset sequence and ran hello without a power cycle.

## DDR3 build (DDR_H* connected to the SOM's DDR3)

    MEM=ddr3 ROM=loader sh board/tang_console/build.sh build/board-ddr3

This build connects DDR_H* to the DDR3 on the SOM (two H5TQ4G63EFR chips, 32-bit DQ, 1 GB) instead of the SDRAM on the baseboard.
The DDR3 controller is Gowin's DDR3 Memory Interface IP (400 MHz memory clock, 1:4), and `rtl/ahb_ddr3.v` connects it to DDR_H*.
In simulation, DDR_H* still connects to SDRAM, and the DDR3 build is verified only on the board, because the IP is encrypted and cannot be simulated.

### Generating the IP (first time only)

The IP is generated by Gowin's tools, so it is not included in the repository.
Generate it from the configuration file `board/tang_console/ddr3/ddr3_memory_interface.ipc` with the IP Core Generator in Gowin EDA.

1. Open the IP Core Generator and load `board/tang_console/ddr3/ddr3_memory_interface.ipc` with Open Config File.
2. Check that Device is GW5AST-138 and Device Version is B, then click OK.
3. `ddr3_memory_interface.v` is generated in the same folder.
   "Decode Process failed" may appear, but only the simulation file `.vo` is missing, and synthesis does not use it.

`build.sh` generates the DDR3 PLL (`gowin_pll_mod.v`) into the output directory from `board/tang_console/ddr3/gowin_pll.mod` with Gowin's GowinModgen.

For a board with chip revision C, set `target_device` in the `.ipc` file to `gw5ast138c-007` before generating, and also change `-device_version` in `board/tang_console/ddr3/gowin_pll.mod` to C (for the change to `build.tcl`, see "Running on the board").
This procedure has not been tested on a revision C board.

The configuration file, the PLL wrappers (`gowin_pll.v`, `pll_init.v`), and the pin constraints (`ddr3.cst`) are taken from `ddr_memory/ddr_memory_test_uart` in Sipeed's TangMega-138K-example (Apache-2.0; a DDR3 test that runs on the Tang Console 138K).

### Bridge (`rtl/ahb_ddr3.v`)

- Each DDR_H* transfer (64-bit AHB, DDR_CLK 50 MHz) crosses into the IP clock domain (100 MHz) one at a time and becomes an IP read or write command.
  One IP command reads or writes 32 bytes (32-bit DQ × 8 beats).
- A write updates only the bytes within the 32 bytes selected by HSIZE and the address; the other bytes are masked.
  The bridge responds to AE350 as soon as the IP accepts the command.
- A read fetches 32 bytes, returns the 8 bytes selected by address bits 4 to 3, and keeps the 32 bytes.
  Later reads within the same 32 bytes are served from the kept data without accessing the IP.
  Writes within the same 32 bytes also update the kept data.
- Addresses beyond 1 GB get an error response.
  The exception is the 32 bytes at 0x7F00_0000, which hold performance counters that can be read (`sw/mem_bench.c` takes the difference before and after each measurement).

  | Offset | Contents                                          |
  | ------ | ------------------------------------------------- |
  | +0x00  | Number of read transfers                          |
  | +0x04  | DDR_CLK cycles AE350 was stalled on reads         |
  | +0x08  | Number of write transfers                         |
  | +0x0C  | DDR_CLK cycles AE350 was stalled on writes        |
  | +0x10  | IP clock cycles until a read command is accepted  |
  | +0x14  | IP clock cycles from a read command to its data   |
  | +0x18  | IP clock cycles until a write command is accepted |
  | +0x1C  | Number of reads served from the kept 32 bytes     |

### Access speed

AE350 CPU cycles per access at 800 MHz, measured with `sw/mem_bench.c` with the data cache off.

| Access                    | DDR3         | SDRAM (166.7 MHz build) |
| ------------------------- | ------------ | ----------------------- |
| Sequential write          | 96 (120 ns)  | 258 (322 ns)            |
| Sequential read           | 179 (224 ns) | 320 (400 ns)            |
| Random read (4 KB stride) | 468 (585 ns) | 320 (400 ns)            |

In sequential reads, 7 out of every 8 reads are served from the kept 32 bytes.
In random reads, every read goes to the IP, and the IP alone (from the read command to the data) takes about 32 IP clock cycles (320 ns).
The time spent before DDR_H* (inside AE350) and in the clock domain crossing is the same as in the SDRAM build.
With the data cache enabled, CoreMark scores were almost the same for the DDR3 and SDRAM builds (2183.7 and 2183.8).

### Combining with the Hazard3 version

`CPU=hazard3 MEM=ddr3` also builds.
For the Hazard3 version, `build.sh` sets the placement option (Gowin's `place_option`) to 2.
The critical path inside Hazard3 (from receiving an instruction through decode and bypass selection) has almost no slack at 40 MHz; in the DDR3 build, core_clk reached 38.5 MHz with the default placement and 40.1 MHz with `PLACE=2`.

### Verified on the board

- With `sw/ddr3_check.c` (placed in the ILM; writes to DDR3 with the data cache off and reads back), address 0 and addresses 2^5 to 2^29 (the address lines for 1 GB), the four 8-byte words within 32 bytes (one IP command), and byte, halfword, and word writes all matched, and an address beyond 1 GB (0x4000_0000) raised exception 5.
- Ran hello and CoreMark (`build/coremark.bin`) from DDR3.
- Through the loader, the CRC-32 of data sent to 0x3FFF_0000 and 0x0200_0000 matched, and 32 bytes at 0x3FFF_FFF0 and an address of 0x4000_0000 were rejected with `ERR range`.
- The Hazard3 version (`CPU=hazard3 MEM=ddr3`) also ran `ddr3_check`, `mem_bench`, hello, and CoreMark (8.28 from DDR3).

## LiteDRAM build (open-source DDR3 controller)

    MEM=litedram ROM=loader sh board/tang_console/build.sh build/board-litedram

This build uses the same SOM DDR3 as the DDR3 build (two chips, 32-bit DQ, 1 GB), but with LiteDRAM (BSD-2-Clause) as the controller instead of Gowin's IP.
The addresses and size are the same as the DDR3 build, so `sw/ddr3_check.c` and `sw/mem_bench.c` run unchanged.
It is slower than Gowin's IP, but it is open source down to the generated Verilog, and it does not require generating an IP with the IP Core Generator.

### Creating the LiteX virtual environment (first time only)

On every synthesis run, `build.sh` uses LiteDRAM's `litedram_gen` to generate the controller Verilog in the output directory from the configuration file (`board/tang_console/litedram/tang_console.yml`).
Install `litedram_gen` in a Python virtual environment and pass its location with `LITEX_VENV`, for example `MEM=litedram LITEX_VENV=<venv> sh board/tang_console/build.sh`; there is no default.
The tested versions are listed below, and all are installed with pip.

| Package                         | Repository                                                   | Version |
| ------------------------------- | ------------------------------------------------------------ | ------- |
| migen                           | https://github.com/m-labs/migen                              | e19524c |
| litex                           | https://github.com/enjoy-digital/litex                       | 8cba6a6 |
| litedram                        | https://github.com/enjoy-digital/litedram                    | 60b5ae1 |
| litex-boards                    | https://github.com/litex-hub/litex-boards                    | 78bc7d7 |
| pythondata-cpu-vexriscv         | https://github.com/litex-hub/pythondata-cpu-vexriscv         | 642ecfe |
| pythondata-software-picolibc    | https://github.com/litex-hub/pythondata-software-picolibc    | 6a13ccc |
| pythondata-software-compiler_rt | https://github.com/litex-hub/pythondata-software-compiler_rt | 6eb7660 |
| meson                           |                                                              | 1.9.1   |
| ninja                           |                                                              | 1.13.0  |

Install each repository at the commit listed above.
picolibc and compiler_rt keep their sources in git submodules, so install them from git rather than from a tarball.

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

The generated controller includes a small CPU (VexRiscv) that performs initialization and read leveling, together with its firmware (the LiteX BIOS).
The firmware is built with the same RISC-V compiler as the other programs (`riscv64-elf-gcc`).
`build.sh` rewrites the paths the generated Verilog uses to load the ROM contents into absolute paths, and adds the VexRiscv Verilog from the virtual environment to synthesis.
Generated files are not included in the repository.

### Configuration

| Item      | Setting                                                                                                                                             |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Speed     | 1:2, controller at 50 MHz, DDR3 clock at 100 MHz (200 MT/s, DLL off)                                                                                |
| User port | native (32 bytes per access, 25-bit address)                                                                                                        |
| Pins      | `board/tang_console/litedram/ddram.cst` (the first chip from LiteX-Boards' Tang Console definition, the second from the .cst in Sipeed's DDR3 test) |

The faster configuration (1:4, controller at 100 MHz, DDR3 at 400 MHz) is not used because the controller clock did not meet timing at 100 MHz.
The details are at the top of `tang_console.yml`.

From power-on until initialization and leveling complete, LiteDRAM's initialization log (115,200 bps) appears on the board's UART.
After that, the UART switches over to AE350.

### Bridge (`rtl/ahb_litedram.v`)

Like `rtl/ahb_ddr3.v`, this bridge moves DDR_H* transfers into the LiteDRAM controller clock domain (50 MHz) and converts them into native port commands.
It also keeps the last 32 bytes read, returns an error response for addresses beyond 1 GB, and uses the same counter layout at 0x7F00_0000 (the "IP clock" in the counters is the LiteDRAM controller clock).
The DDR3 size and access width are parameters (`MEM_AW`, `LINE_AW`), so a single DDR3 chip (512 MB, 16 bytes) is also supported.

### Access speed

AE350 CPU cycles per access, measured under the same conditions as the DDR3 build (`sw/mem_bench.c`, data cache off, 800 MHz).

| Access                    | LiteDRAM     | DDR3 (Gowin IP) | SDRAM (166.7 MHz build) |
| ------------------------- | ------------ | --------------- | ----------------------- |
| Sequential write          | 298 (372 ns) | 96 (120 ns)     | 258 (322 ns)            |
| Sequential read           | 260 (325 ns) | 179 (224 ns)    | 320 (400 ns)            |
| Random read (4 KB stride) | 781 (976 ns) | 468 (585 ns)    | 320 (400 ns)            |

A read takes about 34 controller clock cycles from command to data, almost the same as Gowin's IP (about 32 cycles).
The controller clock is half that of Gowin's IP (50 MHz versus 100 MHz), so the time is about twice as long.
A write takes about 12 controller clock cycles until the command and data are accepted (1 cycle with Gowin's IP).

### Verified on the board

- LiteDRAM's initialization log reported 1.0 GiB 32-bit @ 200 MT/s, read leveling passed for all 4 DQS groups, and LiteDRAM's built-in memory test passed.
- With `sw/ddr3_check.c`, the 1 GB address lines, the four 8-byte words within 32 bytes, and byte, halfword, and word writes all matched, and an address beyond 1 GB (0x4000_0000) raised exception 5.
- The 1024 words read in the sequential read of `sw/mem_bench.c` matched the values written.
- Ran hello from DDR3 (in a single-chip, 512 MB configuration).

## License

This repository is licensed under Apache-2.0 (`LICENSE`).
The following files are by other authors and are included under their original licenses.

| Location                                       | Origin                                                                                                                               | License (text)                                                  |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------- |
| `hazard3/`                                     | Hazard3 v1.1.1 (Luke Wren). Changes are listed in [hazard3/README.md](hazard3/README.md)                                             | Apache-2.0 (hazard3/LICENSE)                                    |
| `rtl/vendor/verilog-uart/`                     | verilog-uart (Alex Forencich)                                                                                                        | MIT (rtl/vendor/verilog-uart/COPYING)                           |
| `rtl/vendor/hdmi/`                             | hdmi (hdl-util, Sameer Puri)                                                                                                         | MIT or Apache-2.0 (rtl/vendor/hdmi/LICENSE-MIT, LICENSE-APACHE) |
| `tb/vendor/zeitlos/sdram_model.v`              | zeitlos (Lone Dynamics). Changes are listed at the top of the file                                                                   | Custom terms (tb/vendor/zeitlos/LICENSE.md)                     |
| `board/tang_console/ddr3/`                     | Sipeed's TangMega-138K-example. The origin of each file is in [board/tang_console/ddr3/README.md](board/tang_console/ddr3/README.md) | Apache-2.0 (LICENSE)                                            |
| `board/tang_console/litedram/tang_console.yml` | examples/tang_mega_138k_pro.yml in LiteDRAM                                                                                          | BSD-2-Clause (board/tang_console/litedram/LICENSE.litedram)     |
| `board/tang_console/litedram/ddram.cst`        | First DDR3: LiteX-Boards' Tang Console definition                                                                                    | BSD-2-Clause (board/tang_console/litedram/LICENSE.litex-boards) |
| `board/tang_console/litedram/ddram.cst`        | Second DDR3: Sipeed's TangMega-138K-example                                                                                          | Apache-2.0 (LICENSE)                                            |
