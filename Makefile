# AE350 の Hazard3 版 (rtl/AE350_SOC.v) のシミュレーションと、プログラムのビルド
#
#   make check    下の 3 つを続けて実行する
#   make ports    Hazard3 版とプリミティブのポートを比べる
#   make lint     Verilator の lint (-Wall。取り込んだ Hazard3 と UART のファイルは対象にしない)
#   make iverilog Icarus Verilog で読み込めるか (-g2001)
#
#   make test     テストプログラム (stage2〜stage5) を、ウェイトサイクル数を変えて 2 回ずつ実行し、単体テストベンチ、
#                 クロックの組み合わせ、途中のリセット、ランダムなウェイト、SDRAM の経路、ローダーなどのテストも実行する。
#                 stage3 は sw/stage3_input.txt を UART に送り、stage3〜stage5 は UART に出力された文字を
#                 sw/stage*_expected.txt と比べる

GOWIN_PRIM ?= /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/simlib/gw5a/prim_sim.v

# newlib の場所は NEWLIB で指定する (既定値は持たない。作り方は README)。newlib を使うプログラムをビルドするときだけ、場所を確かめる
NEWLIB_CHECK = $(if $(wildcard $(NEWLIB)/include/stdio.h),,$(error NEWLIB に newlib の場所を指定する (= <場所>/include と <場所>/lib/rv32imac/ilp32 があるところ。作り方は README)))

HZ3_SOC      := rtl/AE350_SOC.v
HZ3_SOC_SRCS := $(HZ3_SOC) rtl/ae350_fabric.v rtl/ae350_reset_sync.v rtl/ae350_plic.v rtl/ae350_plmt.v
FPGA_SRCS    := rtl/apb_uart.v rtl/uart_reset_seq.v rtl/apb_gpint.v rtl/apb_paddr_probe.v rtl/apb_reg_slice.v rtl/ahb_reg_slice.v rtl/ahb_sram.v rtl/vendor/verilog-uart/uart_tx.v rtl/vendor/verilog-uart/uart_rx.v
SHELL_TOP    := tb/shell_top.v
TB_SRCS      := tb/tb_mem.v tb/ahb_rom_model.v tb/ahb_ddr_model.v

HAZARD3_DIR  := hazard3/hdl
HAZARD3_SRCS := $(addprefix $(HAZARD3_DIR)/, \
	hazard3_cpu_1port.v hazard3_core.v hazard3_csr.v hazard3_decode.v hazard3_frontend.v \
	hazard3_instr_decompress.v hazard3_irq_ctrl.v hazard3_pmp.v hazard3_power_ctrl.v \
	hazard3_regfile_1w2r.v hazard3_triggers.v \
	arith/hazard3_alu.v arith/hazard3_branchcmp.v arith/hazard3_mul_fast.v arith/hazard3_muldiv_seq.v \
	arith/hazard3_onehot_encode.v arith/hazard3_onehot_priority.v arith/hazard3_onehot_priority_dynamic.v \
	arith/hazard3_priority_encode.v arith/hazard3_shift_barrel.v)

RTL_SRCS := $(HZ3_SOC_SRCS) $(FPGA_SRCS) $(SHELL_TOP) $(HAZARD3_SRCS)

VERILATOR_FLAGS := -Wall --timescale 1ns/1ps -I$(HAZARD3_DIR) tools/lint.vlt

BUILD := build
SIM   := $(BUILD)/tb_mem/Vtb_mem
PLL_STUB   := $(BUILD)/gowin_pll_stub.v

# DDR_H* の先を、実機と同じ SDRAM の経路にしたシミュレータ (ahb_sdram → sdram_bridge → SDRAM のモデル)
SDRAM_SRCS  := rtl/ahb_sdram.v rtl/sdram_bridge.v tb/vendor/zeitlos/sdram_model.v
SDRAM_FLAGS := -DTB_SDRAM
SIM_SDRAM   := $(BUILD)/tb_sdram/Vtb_mem

# ソフトウェア
RISCV_PREFIX ?= riscv64-elf-
SW_ARCH    := -march=rv32imac_zicsr_zifencei -mabi=ilp32
SW_LDFLAGS := -nostdlib -nostartfiles -T sw/ae350.ld -Wl,--no-warn-rwx-segments
# stage2: C ライブラリを使わない
SW2_CFLAGS := $(SW_ARCH) -O2 -Wall -Wextra -ffreestanding
# stage3 以降: newlib を使う
SW3_CFLAGS = $(NEWLIB_CHECK)$(SW_ARCH) -O2 -Wall -Wextra -isystem $(NEWLIB)/include
SW3_LIBS   = -L$(NEWLIB)/lib/rv32imac/ilp32 -Wl,--start-group -lc -lgcc -Wl,--end-group

.PHONY: check ports lint iverilog test test-stage2 test-stage3 test-stage4

check: ports lint iverilog

ports:
	ruby tools/check_ports.rb $(GOWIN_PRIM) $(HZ3_SOC)

lint: $(PLL_STUB)
	verilator --lint-only $(VERILATOR_FLAGS) --top-module shell_top $(RTL_SRCS)
	verilator --lint-only $(VERILATOR_FLAGS) --timing --no-sched-zero-delay --top-module tb_mem $(RTL_SRCS) $(TB_SRCS)
	verilator --lint-only $(VERILATOR_FLAGS) --top-module ae350_probe_top $(BOARD_SRCS)
	verilator --lint-only $(VERILATOR_FLAGS) +define+SDRAM_HS +define+AE350_NO_OBSERVER +define+AHB_SDRAM_TRACE --top-module ae350_probe_top $(BOARD_SRCS)
	@# ahb_ddr3 は DDR3 の IP (暗号化されていて Verilator では読めない) につなぐので、単体で lint にかける。トップのポートになるので、
	@# 使わない htrans[0] (ahb_sdram と同じく NONSEQ と SEQ を区別しない) の警告だけを外す
	verilator --lint-only $(VERILATOR_FLAGS) -Wno-UNUSEDSIGNAL --top-module ahb_ddr3 rtl/ahb_ddr3.v
	verilator --lint-only $(VERILATOR_FLAGS) -Wno-UNUSEDSIGNAL --top-module ahb_litedram rtl/ahb_litedram.v

# ボードの回路 (board/tang_console/top.v) の lint。Gowin のプリミティブのうち PLL は、Gowin のモデルから作った空のモジュールに、
# IO のプリミティブ (sdram_io.v の ODDR、IDDR、IOBUF、IODELAY) はテストベンチ用のモデルに置き換える。マクロで回路が変わるので、
# 既定の構成 (probe、20 MHz 版、監視回路あり) と、すべてを入れた構成 (166.7 MHz 版、監視回路なし、転送の記録あり) の 2 通りで実行する
BOARD_SRCS := $(RTL_SRCS) rtl/ahb_rom.v rtl/ahb_sdram.v rtl/sdram_ctrl_hs.v rtl/sdram_io.v rtl/sdram_bridge.v rtl/reset_gen.v \
              tb/gowin_io_models.v $(PLL_STUB) board/tang_console/ae350_pll.v board/tang_console/sdram_pll.v \
              board/tang_console/ae350_observer.v board/tang_console/top.v

$(PLL_STUB): tools/gowin_pll_stub.rb
	mkdir -p $(BUILD)
	ruby tools/gowin_pll_stub.rb $(GOWIN_PRIM) $@

iverilog:
	iverilog -g2001 -I $(HAZARD3_DIR) -s shell_top -o /dev/null $(RTL_SRCS)

# --- プログラム ---

SW_COMMON := sw/start.S sw/trap.c

$(BUILD)/stage2.elf: $(SW_COMMON) sw/stage2_test.c sw/trap.h sw/ae350.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW2_CFLAGS) $(SW_COMMON) sw/stage2_test.c $(SW_LDFLAGS) -lgcc -o $@

$(BUILD)/stage3.elf: $(SW_COMMON) sw/stage3_test.c sw/syscalls.c sw/uart.h sw/trap.h sw/ae350.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/stage3_test.c sw/syscalls.c $(SW_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/stage4.elf: $(SW_COMMON) sw/stage4_test.c sw/syscalls.c sw/uart.h sw/irq.h sw/trap.h sw/ae350.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/stage4_test.c sw/syscalls.c $(SW_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/stage5.elf: $(SW_COMMON) sw/stage5_test.c sw/syscalls.c sw/uart.h sw/irq.h sw/trap.h sw/ae350.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/stage5_test.c sw/syscalls.c $(SW_LDFLAGS) $(SW3_LIBS) -o $@

# 転送の種類ごとに、1 回あたりのサイクル数を測る (バスの構成を変える前後で比べるため)
$(BUILD)/bench.elf: $(SW_COMMON) sw/bench.c sw/syscalls.c sw/uart.h sw/irq.h sw/ae350.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/bench.c sw/syscalls.c $(SW_LDFLAGS) $(SW3_LIBS) -o $@

# 実機の値を読むプログラム (board/tang_console/ の構成。ROM はブロック RAM、データは DLM)
$(BUILD)/probe.elf: sw/start.S sw/trap.c sw/probe.c sw/uart.h sw/trap.h sw/board.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW2_CFLAGS) $(SW_COMMON) sw/probe.c -nostdlib -nostartfiles -T sw/board.ld -Wl,--no-warn-rwx-segments -lgcc -o $@

# ROM に置くローダー (UART でプログラムを受信して外部メモリに書き込み、別のコマンドでそこへジャンプする。ROM と DLM の配置は probe と同じ)
$(BUILD)/loader.elf: sw/start.S sw/trap.c sw/loader.c sw/uart.h sw/board.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW2_CFLAGS) $(SW_COMMON) sw/loader.c -nostdlib -nostartfiles -T sw/board.ld -Wl,--no-warn-rwx-segments -lgcc -o $@

# 外部メモリで実行するプログラム (ROM のローダーで送る。sw/sdram.ld。main から戻るとローダーに戻る)。送るのは .bin
SDRAM_PROG_LDFLAGS := -DSTART_RETURN_TO_ROM -nostdlib -nostartfiles -T sw/sdram.ld -Wl,--no-warn-rwx-segments
# ILM で実行するプログラム (sw/ilm.ld。命令とデータを CPU の近くのメモリに置く)
ILM_PROG_LDFLAGS   := -DSTART_RETURN_TO_ROM -nostdlib -nostartfiles -T sw/ilm.ld -Wl,--no-warn-rwx-segments
$(BUILD)/hello.elf: $(SW_COMMON) sw/hello.c sw/syscalls.c sw/uart.h sw/sdram.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/hello.c sw/syscalls.c $(SDRAM_PROG_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/hello.bin: $(BUILD)/hello.elf
	$(RISCV_PREFIX)objdump -d -h $< > $(BUILD)/hello.dis
	$(RISCV_PREFIX)objcopy -O binary $< $@

$(BUILD)/%.hex: $(BUILD)/%.elf tools/bin2hex.rb
	$(RISCV_PREFIX)objdump -d -h $< > $(BUILD)/$*.dis
	$(RISCV_PREFIX)objcopy -O binary $< $(BUILD)/$*.bin
	ruby tools/bin2hex.rb $(BUILD)/$*.bin $@

# --- シミュレーション (Verilator) ---

$(SIM): $(RTL_SRCS) $(TB_SRCS) tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) --top-module tb_mem -Mdir $(BUILD)/tb_mem $(RTL_SRCS) $(TB_SRCS)

# 1 回実行する: $(1) = プログラム名、$(2) = ROM のウェイト、$(3) = DDR のウェイト、$(4) = その他の plusarg。
# 出力は $(BUILD)/<名前>_w<ROM><DDR>.log
define run_sim
	$(SIM) +rom=$(BUILD)/$(1).hex +rom_wait=$(2) +ddr_wait=$(3) $(4) > $(BUILD)/$(1)_w$(2)$(3).log 2>&1; \
	status=$$?; cat $(BUILD)/$(1)_w$(2)$(3).log; exit $$status
endef

# 1 回実行して出力を比べる: $(1) = プログラム名、$(2) = ログの名前、$(3) = plusarg
define run_cmp
	$(SIM) +rom=$(BUILD)/$(1).hex $(3) > $(BUILD)/$(2).log 2>&1; status=$$?; cat $(BUILD)/$(2).log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/$(2).log | diff sw/$(1)_expected.txt -
endef

test: test-plic test-sram test-sdram-unit test-sdram-io test-sdram-pll test-sdram-hs-unit test-stage2 test-stage3 test-stage4 test-stage5 test-clocks test-reset test-random test-sdram test-sdram-hs test-loader test-uart-reset test-uart-tool

# ROM のローダーのテスト (tools/loader_test.rb が手順と期待の出力を作る)。シミュレーション用のローダーは、タイムアウトを
# 200,000 mcycle (250 µs) にする (実機は 1 秒)。送信は実機の 1.25 Mbps と同じ間隔で行うので、hello は数分かかる
$(BUILD)/loader_sim.elf: sw/start.S sw/trap.c sw/loader.c sw/uart.h sw/board.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW2_CFLAGS) -DLOADER_TIMEOUT_MCYCLE=200000 $(SW_COMMON) sw/loader.c -nostdlib -nostartfiles -T sw/board.ld -Wl,--no-warn-rwx-segments -lgcc -o $@

$(BUILD)/sdram_min.elf: $(SW_COMMON) sw/sdram_min.c sw/sdram.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW2_CFLAGS) $(SW_COMMON) sw/sdram_min.c $(SDRAM_PROG_LDFLAGS) -lgcc -o $@

$(BUILD)/sdram_min.bin: $(BUILD)/sdram_min.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

# 同じプログラムを ILM に置いたもの (ローダーが ILM に書き込んで run できることを確かめる)
$(BUILD)/ilm_min.elf: $(SW_COMMON) sw/sdram_min.c sw/ilm.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW2_CFLAGS) $(SW_COMMON) sw/sdram_min.c $(ILM_PROG_LDFLAGS) -lgcc -o $@

$(BUILD)/ilm_min.bin: $(BUILD)/ilm_min.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

# 命令フェッチとデータの読み出しに何クロックかかるかを測る (ILM に置く。実機ではローダーで送る)
$(BUILD)/fetch_probe.elf: $(SW_COMMON) sw/fetch_probe.c sw/syscalls.c sw/ilm.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/fetch_probe.c sw/syscalls.c $(ILM_PROG_LDFLAGS) $(SW3_LIBS) -o $@

# DDR_H* の先の DDR3 (board/tang_console/build.sh の MEM=ddr3) に書き込んで読み返す (ILM に置く。実機ではローダーで送る)
$(BUILD)/ddr3_check.elf: $(SW_COMMON) sw/ddr3_check.c sw/syscalls.c sw/trap.h sw/ilm.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/ddr3_check.c sw/syscalls.c $(ILM_PROG_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/ddr3_check.bin: $(BUILD)/ddr3_check.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

# 同じものを、DDR3 1 個 (512 MB) の構成に合わせたもの
$(BUILD)/ddr3_check_512.elf: $(SW_COMMON) sw/ddr3_check.c sw/syscalls.c sw/trap.h sw/ilm.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) -DDDR3_BITS=29 $(SW_COMMON) sw/ddr3_check.c sw/syscalls.c $(ILM_PROG_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/ddr3_check_512.bin: $(BUILD)/ddr3_check_512.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

# DDR_H* の先のメモリ (SDRAM か DDR3) への 1 回の読み書きにかかるクロック数を測る (ILM に置く。実機ではローダーで送る)
$(BUILD)/mem_bench.elf: $(SW_COMMON) sw/mem_bench.c sw/syscalls.c sw/trap.h sw/uart.h sw/ilm.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/mem_bench.c sw/syscalls.c $(ILM_PROG_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/mem_bench.bin: $(BUILD)/mem_bench.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

$(BUILD)/time_probe.elf: $(SW_COMMON) sw/time_probe.c sw/syscalls.c sw/trap.h sw/ilm.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW3_CFLAGS) $(SW_COMMON) sw/time_probe.c sw/syscalls.c $(ILM_PROG_LDFLAGS) $(SW3_LIBS) -o $@

# キャッシュを有効にすると、短い間隔でだけ mcycle と mtime の差が合わなくなる現象を調べる (ILM に置く。実機ではローダーで送る)
$(BUILD)/time_probe.bin: $(BUILD)/time_probe.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

$(BUILD)/fetch_probe.bin: $(BUILD)/fetch_probe.elf
	$(RISCV_PREFIX)objdump -d $< > $(BUILD)/fetch_probe.dis
	$(RISCV_PREFIX)objcopy -O binary $< $@

$(BUILD)/sdram_hang.elf: $(SW_COMMON) sw/sdram_hang.c sw/sdram.ld
	mkdir -p $(BUILD)
	$(RISCV_PREFIX)gcc $(SW2_CFLAGS) $(SW_COMMON) sw/sdram_hang.c $(SDRAM_PROG_LDFLAGS) -lgcc -o $@

$(BUILD)/sdram_hang.bin: $(BUILD)/sdram_hang.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

# CoreMark (EEMBC。ソースは Apache-2.0、名前の使用は EEMBC の規定に従う。リポジトリには含めず、決めたコミットを build/ に
# 取得し、チェックサムで照合してから使う。一度取得したものは再利用する)。この構成に合わせる部分は sw/coremark/
#   build/coremark_sim.hex  シミュレーション用。ROM に置き (sw/ae350.ld)、繰り返しは 1 回 (結果が正しいかだけを見る)
#   build/coremark.bin      実機用。外部メモリに置き (sw/sdram.ld。ローダーで送る)、繰り返しは自動 (10 秒以上になる回数)
COREMARK_SHA  := 1f483d5b8316753a742cbf5590caf5bd0a4e4777
COREMARK_SUM  := 4067e7f260218df13f2875d8f821a8ff32a84153c6e0759d7c89f96c0a8bf987
COREMARK_DIR  := $(BUILD)/coremark-$(COREMARK_SHA)
COREMARK_SRCS := $(addprefix $(COREMARK_DIR)/, core_list_join.c core_main.c core_matrix.c core_state.c core_util.c)
COREMARK_OPT  := -O2
COREMARK_FLAGS = $(SW3_CFLAGS) $(COREMARK_OPT) -Isw/coremark -I$(COREMARK_DIR) -DPERFORMANCE_RUN=1 \
                 -DFLAGS_STR='"$(COREMARK_OPT) $(SW_ARCH)"'

$(COREMARK_DIR)/core_main.c:
	mkdir -p $(BUILD)
	curl -sSL -o $(BUILD)/coremark-$(COREMARK_SHA).tar.gz https://codeload.github.com/eembc/coremark/tar.gz/$(COREMARK_SHA)
	echo "$(COREMARK_SUM)  $(BUILD)/coremark-$(COREMARK_SHA).tar.gz" | shasum -a 256 -c -
	tar -xzf $(BUILD)/coremark-$(COREMARK_SHA).tar.gz -C $(BUILD)
	touch $@

$(BUILD)/coremark_sim.elf: $(COREMARK_DIR)/core_main.c sw/coremark/core_portme.c sw/coremark/core_portme.h $(SW_COMMON) sw/syscalls.c sw/ae350.ld
	$(RISCV_PREFIX)gcc $(COREMARK_FLAGS) -DITERATIONS=1 $(SW_COMMON) $(COREMARK_SRCS) sw/coremark/core_portme.c sw/syscalls.c \
	    $(SW_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/coremark.elf: $(COREMARK_DIR)/core_main.c sw/coremark/core_portme.c sw/coremark/core_portme.h $(SW_COMMON) sw/syscalls.c sw/sdram.ld
	$(RISCV_PREFIX)gcc $(COREMARK_FLAGS) -DITERATIONS=0 $(SW_COMMON) $(COREMARK_SRCS) sw/coremark/core_portme.c sw/syscalls.c \
	    $(SDRAM_PROG_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/coremark_ilm.elf: $(COREMARK_DIR)/core_main.c sw/coremark/core_portme.c sw/coremark/core_portme.h $(SW_COMMON) sw/syscalls.c sw/ilm.ld
	$(RISCV_PREFIX)gcc $(COREMARK_FLAGS) -DITERATIONS=0 $(SW_COMMON) $(COREMARK_SRCS) sw/coremark/core_portme.c sw/syscalls.c \
	    $(ILM_PROG_LDFLAGS) $(SW3_LIBS) -o $@

$(BUILD)/coremark_ilm.bin: $(BUILD)/coremark_ilm.elf
	$(RISCV_PREFIX)objcopy -O binary $< $@

# 公表値 (Hazard3 の README にある RP2350 の値) と同じオプションでビルドした、ILM に置く CoreMark。C 拡張を使わない
# (rv32ima) ので、libgcc は C 拡張を使う版 (rv32imac。計測区間の外の、整数の割り算などで使う) を明示して使う。コードが
# 大きくなり、newlib の printf と合わせると ILM に収まらないので、CoreMark の簡易 printf (barebones/ee_printf.c) を使い、浮動小数点も
# 使わない (HAS_FLOAT=0。秒と 1 秒あたりの回数は整数で出力される。スコアは mcycle と繰り返しの回数から出す)。
# ee_printf.c の uart_send_char は「ここに実装を書く」という #error だけなので、core_portme.c の ae350_uart_putc を呼ぶ形に書き換えてコピーする
PUB_OPT     := -O3 -mbranch-cost=1 -funroll-all-loops --param max-inline-insns-auto=200 -finline-limit=10000 \
               -fno-code-hoisting -fno-if-conversion2 -falign-functions=4 -falign-jumps=4 -falign-loops=4
PUB_ARCH    := -march=rv32ima_zicsr_zifencei -mabi=ilp32
PUB_LIBGCC  := $(dir $(shell $(RISCV_PREFIX)gcc -march=rv32imac -mabi=ilp32 -print-libgcc-file-name))
PUB_SRCS     = $(COREMARK_SRCS) $(BUILD)/coremark_ee_printf.c sw/coremark/core_portme.c sw/syscalls.c

$(BUILD)/coremark_ee_printf.c: $(COREMARK_DIR)/core_main.c
	sed 's|^#error "You must implement the method uart_send_char.*|    extern void ae350_uart_putc(char); ae350_uart_putc(c);|' \
	    $(COREMARK_DIR)/barebones/ee_printf.c > $@
	grep -q ae350_uart_putc $@

define PUB_RULE
$(BUILD)/coremark_ilm_$(1).elf: $(BUILD)/coremark_ee_printf.c sw/coremark/core_portme.c sw/coremark/core_portme.h $(SW_COMMON) sw/syscalls.c sw/ilm.ld
	$(RISCV_PREFIX)gcc $$(SW3_CFLAGS) -Wno-unused-parameter -Wno-implicit-fallthrough $(PUB_OPT) $(2) -DHAS_PRINTF=0 -DHAS_FLOAT=0 -Isw -Isw/coremark -I$(COREMARK_DIR) -DPERFORMANCE_RUN=1 \
	    -DFLAGS_STR='"$(PUB_OPT) $(2)"' -DITERATIONS=0 $(SW_COMMON) $(PUB_SRCS) \
	    $(ILM_PROG_LDFLAGS) -L$(PUB_LIBGCC) -L$$(NEWLIB)/lib/rv32imac/ilp32 -Wl,--start-group -lc -lgcc -Wl,--end-group -o $$@

$(BUILD)/coremark_ilm_$(1).bin: $(BUILD)/coremark_ilm_$(1).elf
	$(RISCV_PREFIX)objcopy -O binary $$< $$@
endef
$(eval $(call PUB_RULE,pub,$(PUB_ARCH)))

$(BUILD)/coremark.bin: $(BUILD)/coremark.elf
	$(RISCV_PREFIX)objdump -d -h $< > $(BUILD)/coremark.dis
	$(RISCV_PREFIX)objcopy -O binary $< $@

# CoreMark をシミュレーションの Hazard3 版で 1 回繰り返し、結果が正しいかを確かめる。実行時間が 10 秒より短いと、CoreMark は
# 「Errors detected」を出力する (実行時間の規定を満たさないとエラー数に 1 を加える) ので、3 つの CRC が 2K performance run の正しい値
# (core_main.c の表の 3 番目) であることと、CRC のエラーの行がないことで判定する。main の戻り値は 0 なので、テストベンチは
# 「失敗」で終わる (終了コードは見ない)。CoreMark の取得にネットワークが必要なので、make test には含めない
.PHONY: coremark-sim
coremark-sim: $(SIM) $(BUILD)/coremark_sim.hex
	-$(SIM) +rom=$(BUILD)/coremark_sim.hex +max_cycles=200000000 > $(BUILD)/coremark_sim.log 2>&1
	grep -a '^UART: ' $(BUILD)/coremark_sim.log
	grep -q '^UART: \[0\]crclist       : 0xe714$$' $(BUILD)/coremark_sim.log
	grep -q '^UART: \[0\]crcmatrix     : 0x1fd7$$' $(BUILD)/coremark_sim.log
	grep -q '^UART: \[0\]crcstate      : 0x8e3a$$' $(BUILD)/coremark_sim.log
	! grep -q '^UART: \[0\]ERROR' $(BUILD)/coremark_sim.log
	@echo "coremark-sim: CRC は正しい"

.PHONY: test-loader
test-loader: $(SIM_SDRAM) $(BUILD)/loader_sim.hex $(BUILD)/ilm_min.bin $(BUILD)/sdram_hang.bin $(BUILD)/hello.bin tools/loader_test.rb
	ruby tools/loader_test.rb cmds $(BUILD)/ilm_min.bin $(BUILD)/sdram_hang.bin $(BUILD)/loader_cmds.txt $(BUILD)/loader_cmds_expected.txt $(BUILD)
	$(SIM_SDRAM) +rom=$(BUILD)/loader_sim.hex +uart_script=$(BUILD)/loader_cmds.txt $(SDRAM_RUN) > $(BUILD)/loader_cmds.log 2>&1; status=$$?; cat $(BUILD)/loader_cmds.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/loader_cmds.log | tr -d '\r' | diff $(BUILD)/loader_cmds_expected.txt -
	ruby tools/loader_test.rb hello $(BUILD)/hello.bin $(BUILD)/hello.dis $(BUILD)/loader_hello.txt $(BUILD)/loader_hello_expected.txt
	$(SIM_SDRAM) +rom=$(BUILD)/loader_sim.hex +uart_script=$(BUILD)/loader_hello.txt +max_cycles=80000000 > $(BUILD)/loader_hello.log 2>&1; status=$$?; cat $(BUILD)/loader_hello.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/loader_hello.log | tr -d '\r' | diff $(BUILD)/loader_hello_expected.txt -

# ウェイトを転送ごとにランダムに決め (ROM と DDR とも 0〜3 サイクル)、乱数の種を 3 つ変えて stage2〜stage5 を実行する
RAND := +rom_wait_rand=3 +ddr_wait_rand=3

# DDR_H* の先を SDRAM の経路にして、stage3〜stage5 を実行する (SDRAM は 1 回の転送が遅いので、打ち切りのサイクル数を増やす)。
# stage2 は、テストベンチの DDR のモデルにエラーを返させる確認 (+ddr_err) を含むので実行しない
$(SIM_SDRAM): $(RTL_SRCS) $(TB_SRCS) $(SDRAM_SRCS) tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) $(SDRAM_FLAGS) --top-module tb_mem -Mdir $(BUILD)/tb_sdram $(RTL_SRCS) $(TB_SRCS) $(SDRAM_SRCS)

SDRAM_RUN := +max_cycles=20000000

# ahb_sdram の単体テストベンチ (ahb_sdram → sdram_bridge → SDRAM のモデル)
SIM_SDRAM_UNIT := $(BUILD)/sdram_tb/Vsdram_tb

$(SIM_SDRAM_UNIT): rtl/ahb_sdram.v tb/sdram_tb.v rtl/sdram_bridge.v tb/vendor/zeitlos/sdram_model.v tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) --top-module sdram_tb -Mdir $(BUILD)/sdram_tb \
		rtl/ahb_sdram.v tb/sdram_tb.v rtl/sdram_bridge.v tb/vendor/zeitlos/sdram_model.v

# sdram_io (SDRAM のピン周りの回路。166.7 MHz 版で使う) の単体テストベンチ。Gowin の IO プリミティブはテストベンチ用のモデル
SIM_SDRAM_IO := $(BUILD)/sdram_io_tb/Vsdram_io_tb

$(SIM_SDRAM_IO): rtl/sdram_io.v tb/sdram_io_tb.v tb/gowin_io_models.v tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing $(VERILATOR_FLAGS) --top-module sdram_io_tb -Mdir $(BUILD)/sdram_io_tb rtl/sdram_io.v tb/sdram_io_tb.v tb/gowin_io_models.v

# uart_reset_seq (UART のリセットシーケンスで AE350 をリセットする回路) の単体テストベンチ
SIM_UART_RESET := $(BUILD)/uart_reset_seq_tb/Vuart_reset_seq_tb
$(SIM_UART_RESET): rtl/uart_reset_seq.v tb/uart_reset_seq_tb.v rtl/vendor/verilog-uart/uart_rx.v tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing $(VERILATOR_FLAGS) --top-module uart_reset_seq_tb -Mdir $(BUILD)/uart_reset_seq_tb rtl/uart_reset_seq.v tb/uart_reset_seq_tb.v rtl/vendor/verilog-uart/uart_rx.v

.PHONY: test-uart-reset
test-uart-reset: $(SIM_UART_RESET)
	$(SIM_UART_RESET)

# tools/ae350_uart.rb のテスト (シリアルポートの代わりに UNIX ドメインソケットを使う。速度の設定は実機でしか確かめられない)
.PHONY: test-uart-tool
test-uart-tool:
	ruby tools/test_ae350_uart.rb

.PHONY: test-sdram-io
test-sdram-io: $(SIM_SDRAM_IO)
	$(SIM_SDRAM_IO)

# sdram_pll (2 つ目の PLL) を Gowin の PLL のモデルで確かめる (iverilog。モデルは、tools/prim_sim_gw5a.rb で
# 固定の位相の設定を直したものを build/ に作る。Gowin のファイルなのでコミットしない)
GOWIN_SIMLIB ?= /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE/simlib
PRIM_SIM_GW5A := $(BUILD)/prim_sim_gw5a.v

$(PRIM_SIM_GW5A): tools/prim_sim_gw5a.rb
	mkdir -p $(BUILD)
	ruby tools/prim_sim_gw5a.rb $(GOWIN_SIMLIB)/gw5a/prim_sim.v $(GOWIN_SIMLIB)/gw2a/prim_sim.v $@

$(BUILD)/sdram_pll_tb.vvp: board/tang_console/sdram_pll.v tb/sdram_pll_tb.v $(PRIM_SIM_GW5A)
	mkdir -p $(BUILD)
	iverilog -g2012 -s sdram_pll_tb -o $@ board/tang_console/sdram_pll.v tb/sdram_pll_tb.v $(PRIM_SIM_GW5A)

.PHONY: test-sdram-pll
test-sdram-pll: $(BUILD)/sdram_pll_tb.vvp
	vvp -n $(BUILD)/sdram_pll_tb.vvp

# 166.7 MHz 版の経路 (sdram_ctrl_hs → sdram_io → ボード上の遅延 → SDRAM のモデル) で、ahb_sdram の単体テストベンチを実行する
# +cap_phase=<0〜47> (c_clk の位相、0.125 ns ステップ)、+board_ps=<ps> (ボード上の片道の遅延)
HS_SRCS            := rtl/sdram_ctrl_hs.v rtl/sdram_io.v tb/gowin_io_models.v tb/sdram_hs_path.v tb/vendor/zeitlos/sdram_model.v
SIM_SDRAM_HS_UNIT  := $(BUILD)/sdram_hs_tb/Vsdram_tb

$(SIM_SDRAM_HS_UNIT): rtl/ahb_sdram.v tb/sdram_tb.v $(HS_SRCS) tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) -DSDRAM_HS --top-module sdram_tb -Mdir $(BUILD)/sdram_hs_tb \
		rtl/ahb_sdram.v tb/sdram_tb.v $(HS_SRCS)

# 166.7 MHz 版の経路で、stage3〜stage5 を実行する
SIM_SDRAM_HS := $(BUILD)/tb_sdram_hs/Vtb_mem

$(SIM_SDRAM_HS): $(RTL_SRCS) $(TB_SRCS) rtl/ahb_sdram.v $(HS_SRCS) tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) -DTB_SDRAM -DSDRAM_HS --top-module tb_mem -Mdir $(BUILD)/tb_sdram_hs \
		$(RTL_SRCS) $(TB_SRCS) rtl/ahb_sdram.v $(HS_SRCS)

.PHONY: test-sdram-hs
test-sdram-hs: $(SIM_SDRAM_HS) $(BUILD)/stage3.hex $(BUILD)/stage4.hex $(BUILD)/stage5.hex sw/stage3_input.txt sw/stage3_expected.txt sw/stage4_expected.txt sw/stage5_expected.txt sw/stage5_extm.txt
	$(SIM_SDRAM_HS) +rom=$(BUILD)/stage3.hex $(SDRAM_RUN) +uart_in=sw/stage3_input.txt > $(BUILD)/sdram_hs_stage3.log 2>&1; status=$$?; cat $(BUILD)/sdram_hs_stage3.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/sdram_hs_stage3.log | diff sw/stage3_expected.txt -
	$(SIM_SDRAM_HS) +rom=$(BUILD)/stage4.hex $(SDRAM_RUN) > $(BUILD)/sdram_hs_stage4.log 2>&1; status=$$?; cat $(BUILD)/sdram_hs_stage4.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/sdram_hs_stage4.log | diff sw/stage4_expected.txt -
	$(SIM_SDRAM_HS) +rom=$(BUILD)/stage5.hex $(SDRAM_RUN) $(STAGE5_EXTM) > $(BUILD)/sdram_hs_stage5.log 2>&1; status=$$?; cat $(BUILD)/sdram_hs_stage5.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/sdram_hs_stage5.log | diff sw/stage5_expected.txt -

.PHONY: test-sdram-hs-unit
test-sdram-hs-unit: $(SIM_SDRAM_HS_UNIT)
	$(SIM_SDRAM_HS_UNIT) > $(BUILD)/sdram_hs_tb.log 2>&1; status=$$?; cat $(BUILD)/sdram_hs_tb.log; exit $$status
	! grep -q -i "error\|violation" $(BUILD)/sdram_hs_tb.log

.PHONY: test-sdram-unit
test-sdram-unit: $(SIM_SDRAM_UNIT)
	$(SIM_SDRAM_UNIT) > $(BUILD)/sdram_tb.log 2>&1; status=$$?; cat $(BUILD)/sdram_tb.log; exit $$status
	! grep -q -i "error\|violation" $(BUILD)/sdram_tb.log

.PHONY: test-sdram
test-sdram: $(SIM_SDRAM) $(BUILD)/stage3.hex $(BUILD)/stage4.hex $(BUILD)/stage5.hex sw/stage3_input.txt sw/stage3_expected.txt sw/stage4_expected.txt sw/stage5_expected.txt sw/stage5_extm.txt
	$(SIM_SDRAM) +rom=$(BUILD)/stage3.hex $(SDRAM_RUN) +uart_in=sw/stage3_input.txt > $(BUILD)/sdram_stage3.log 2>&1; status=$$?; cat $(BUILD)/sdram_stage3.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/sdram_stage3.log | diff sw/stage3_expected.txt -
	$(SIM_SDRAM) +rom=$(BUILD)/stage4.hex $(SDRAM_RUN) > $(BUILD)/sdram_stage4.log 2>&1; status=$$?; cat $(BUILD)/sdram_stage4.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/sdram_stage4.log | diff sw/stage4_expected.txt -
	$(SIM_SDRAM) +rom=$(BUILD)/stage5.hex $(SDRAM_RUN) $(STAGE5_EXTM) > $(BUILD)/sdram_stage5.log 2>&1; status=$$?; cat $(BUILD)/sdram_stage5.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/sdram_stage5.log | diff sw/stage5_expected.txt -

.PHONY: test-random
test-random: $(SIM) $(BUILD)/stage2.hex $(BUILD)/stage3.hex $(BUILD)/stage4.hex $(BUILD)/stage5.hex sw/stage3_input.txt sw/stage3_expected.txt sw/stage4_expected.txt
	for seed in 1 2 3; do \
		$(SIM) +rom=$(BUILD)/stage2.hex $(STAGE2_ERR) $(RAND) +seed=$$seed > $(BUILD)/stage2_rand$$seed.log 2>&1 || { cat $(BUILD)/stage2_rand$$seed.log; exit 1; }; \
		grep '^合格' $(BUILD)/stage2_rand$$seed.log; \
		$(SIM) +rom=$(BUILD)/stage3.hex +uart_in=sw/stage3_input.txt $(RAND) +seed=$$seed > $(BUILD)/stage3_rand$$seed.log 2>&1 || { cat $(BUILD)/stage3_rand$$seed.log; exit 1; }; \
		sed -n 's/^UART: //p' $(BUILD)/stage3_rand$$seed.log | diff sw/stage3_expected.txt - || exit 1; \
		$(SIM) +rom=$(BUILD)/stage4.hex $(RAND) +seed=$$seed > $(BUILD)/stage4_rand$$seed.log 2>&1 || { cat $(BUILD)/stage4_rand$$seed.log; exit 1; }; \
		sed -n 's/^UART: //p' $(BUILD)/stage4_rand$$seed.log | diff sw/stage4_expected.txt - || exit 1; \
		$(SIM) +rom=$(BUILD)/stage5.hex $(STAGE5_EXTM) $(RAND) +seed=$$seed > $(BUILD)/stage5_rand$$seed.log 2>&1 || { cat $(BUILD)/stage5_rand$$seed.log; exit 1; }; \
		sed -n 's/^UART: //p' $(BUILD)/stage5_rand$$seed.log | diff sw/stage5_expected.txt - || exit 1; \
		echo "種 $$seed: 段 2〜5 合格"; \
	done

# 実機の値を読むプログラムをシミュレーションで実行する (出力の形式を、実機で動かす前に確かめるため)。実機の構成と同じく、
# DDR_H* の先を SDRAM の経路にしたシミュレータで実行する
.PHONY: run-probe
run-probe: $(SIM_SDRAM) $(BUILD)/probe.hex
	$(SIM_SDRAM) +rom=$(BUILD)/probe.hex $(SDRAM_RUN) > $(BUILD)/probe.log 2>&1; status=$$?; grep '^UART: \|^結果\|Fatal' $(BUILD)/probe.log; exit $$status

.PHONY: bench
bench: $(SIM) $(BUILD)/bench.hex
	$(SIM) +rom=$(BUILD)/bench.hex > $(BUILD)/bench.log 2>&1; status=$$?; grep '^UART: \|^結果' $(BUILD)/bench.log; exit $$status

# 動作の途中でリセットをかけ、リセットの後に stage4 が最初から正しく動くことを確かめる (「途中のリセット」の行より後の
# UART の出力を比べる)。AHB_CLK の 200000 サイクル目は、stage4 の PLIC の確認の途中
.PHONY: test-reset
test-reset: $(SIM) $(BUILD)/stage4.hex sw/stage4_expected.txt
	$(SIM) +rom=$(BUILD)/stage4.hex +reset_at=200000 > $(BUILD)/stage4_reset.log 2>&1; status=$$?; cat $(BUILD)/stage4_reset.log; exit $$status
	grep -q '^途中のリセット' $(BUILD)/stage4_reset.log
	sed -n '/^途中のリセット/,$$p' $(BUILD)/stage4_reset.log | sed -n 's/^UART: //p' | diff sw/stage4_expected.txt -

# クロックの組み合わせを変えて実行する (既定のリファレンスデザインの周波数のほかに、クロック乗せ換えがどの比でも動くことを確かめる)
#   same   すべて 100 MHz
#   odd    CORE 50 MHz (バスより遅い)、AHB 100 MHz、APB 33 MHz、DDR 133 MHz
CLK_SAME := +core_hp=5000 +ahb_hp=5000 +apb_hp=5000 +ddr_hp=5000
CLK_ODD  := +core_hp=10000 +ahb_hp=5000 +apb_hp=15151 +ddr_hp=3759

.PHONY: test-clocks
test-clocks: $(SIM) $(BUILD)/stage3.hex $(BUILD)/stage4.hex $(BUILD)/stage5.hex sw/stage3_input.txt sw/stage3_expected.txt sw/stage4_expected.txt
	$(call run_cmp,stage3,stage3_same,$(CLK_SAME) +rom_wait=1 +ddr_wait=2 +uart_in=sw/stage3_input.txt)
	$(call run_cmp,stage4,stage4_same,$(CLK_SAME) +rom_wait=1 +ddr_wait=2)
	$(call run_cmp,stage3,stage3_odd,$(CLK_ODD) +rom_wait=1 +ddr_wait=2 +uart_in=sw/stage3_input.txt)
	$(call run_cmp,stage4,stage4_odd,$(CLK_ODD) +rom_wait=1 +ddr_wait=2)
	$(call run_cmp,stage5,stage5_same,$(CLK_SAME) +rom_wait=1 +ddr_wait=2 $(STAGE5_EXTM))
	$(call run_cmp,stage5,stage5_odd,$(CLK_ODD) +rom_wait=1 +ddr_wait=2 $(STAGE5_EXTM))

# PLIC の単体テストベンチ (エッジのソースと、claim をしきい値で絞らない構成)
SIM_PLIC := $(BUILD)/plic_tb/Vplic_tb

$(SIM_PLIC): rtl/ae350_plic.v tb/plic_tb.v tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing $(VERILATOR_FLAGS) --top-module plic_tb -Mdir $(BUILD)/plic_tb rtl/ae350_plic.v tb/plic_tb.v

.PHONY: test-plic
test-plic: $(SIM_PLIC)
	$(SIM_PLIC)

# EXTS_H* の先の RAM の単体テストベンチ (AHB のパイプラインで、書き込んだ直後に同じワードを読む)
SIM_SRAM := $(BUILD)/sram_tb/Vsram_tb

$(SIM_SRAM): rtl/ahb_sram.v tb/sram_tb.v tools/lint.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing $(VERILATOR_FLAGS) --top-module sram_tb -Mdir $(BUILD)/sram_tb rtl/ahb_sram.v tb/sram_tb.v

.PHONY: test-sram
test-sram: $(SIM_SRAM)
	$(SIM_SRAM)

# stage2 は、メモリのエラー応答を確かめる (sw/stage2_test.c の 15〜17)
STAGE2_ERR := +rom_err=8000F000 +ddr_err=00008000

test-stage2: $(SIM) $(BUILD)/stage2.hex
	$(call run_sim,stage2,0,0,$(STAGE2_ERR))
	$(call run_sim,stage2,1,2,$(STAGE2_ERR))

test-stage3: $(SIM) $(BUILD)/stage3.hex sw/stage3_input.txt sw/stage3_expected.txt
	$(call run_sim,stage3,0,0,+uart_in=sw/stage3_input.txt)
	sed -n 's/^UART: //p' $(BUILD)/stage3_w00.log | diff sw/stage3_expected.txt -
	$(call run_sim,stage3,1,2,+uart_in=sw/stage3_input.txt)
	sed -n 's/^UART: //p' $(BUILD)/stage3_w12.log | diff sw/stage3_expected.txt -

test-stage4: $(SIM) $(BUILD)/stage4.hex sw/stage4_expected.txt
	$(call run_sim,stage4,0,0)
	sed -n 's/^UART: //p' $(BUILD)/stage4_w00.log | diff sw/stage4_expected.txt -
	$(call run_sim,stage4,1,2)
	sed -n 's/^UART: //p' $(BUILD)/stage4_w12.log | diff sw/stage4_expected.txt -

# --- 4 値のシミュレーション (iverilog) ---
# 不定値 (X、Z) を扱うシミュレータで同じテストベンチを実行し、テストベンチの不定値の検査 (バスの信号、割り込み、TXD) と、
# 初期化されていない値が結果に影響しないことを確かめる。iverilog は Verilator より遅いので、別のターゲットにする
SIM_IV := $(BUILD)/tb_iv.vvp

$(SIM_IV): $(RTL_SRCS) $(TB_SRCS)
	mkdir -p $(BUILD)
	iverilog -g2012 -I $(HAZARD3_DIR) -s tb_mem -o $@ $(RTL_SRCS) $(TB_SRCS)

.PHONY: test-iverilog
test-iverilog: $(SIM_IV) $(BUILD)/stage2.hex $(BUILD)/stage3.hex $(BUILD)/stage4.hex $(BUILD)/stage5.hex sw/stage3_input.txt sw/stage3_expected.txt sw/stage4_expected.txt
	vvp -n $(SIM_IV) +rom=$(BUILD)/stage2.hex $(STAGE2_ERR) > $(BUILD)/stage2_iv.log 2>&1; status=$$?; cat $(BUILD)/stage2_iv.log; exit $$status
	grep -q '^合格' $(BUILD)/stage2_iv.log
	vvp -n $(SIM_IV) +rom=$(BUILD)/stage3.hex +uart_in=sw/stage3_input.txt > $(BUILD)/stage3_iv.log 2>&1; status=$$?; cat $(BUILD)/stage3_iv.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/stage3_iv.log | diff sw/stage3_expected.txt -
	vvp -n $(SIM_IV) +rom=$(BUILD)/stage4.hex > $(BUILD)/stage4_iv.log 2>&1; status=$$?; cat $(BUILD)/stage4_iv.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/stage4_iv.log | diff sw/stage4_expected.txt -
	vvp -n $(SIM_IV) +rom=$(BUILD)/stage5.hex $(STAGE5_EXTM) > $(BUILD)/stage5_iv.log 2>&1; status=$$?; cat $(BUILD)/stage5_iv.log; exit $$status
	sed -n 's/^UART: //p' $(BUILD)/stage5_iv.log | diff sw/stage5_expected.txt -

.PHONY: test-stage5
# stage5 は、EXTM_H* の手順 (sw/stage5_extm.txt) と背景の転送を、テストベンチのマスタのモデルで実行する
STAGE5_EXTM := +extm_cmd=sw/stage5_extm.txt +extm_bg=1

test-stage5: $(SIM) $(BUILD)/stage5.hex sw/stage5_expected.txt sw/stage5_extm.txt
	$(call run_sim,stage5,0,0,$(STAGE5_EXTM))
	sed -n 's/^UART: //p' $(BUILD)/stage5_w00.log | diff sw/stage5_expected.txt -
	$(call run_sim,stage5,1,2,$(STAGE5_EXTM))
	sed -n 's/^UART: //p' $(BUILD)/stage5_w12.log | diff sw/stage5_expected.txt -

# --- カバレッジ (Verilator の行とトグル) ---
# test と同じ範囲 (stage2〜stage4 の固定のウェイト、クロックの組み合わせ、途中のリセット、ランダムなウェイト、PLIC の単体テストベンチ) を、
# カバレッジを数えるようにビルドしたテストベンチで実行し、集計する。数える対象は tools/coverage.vlt で決める。
#   $(BUILD)/cov/all.dat           すべての実行を集計したもの
#   $(BUILD)/cov/annotated/        ソースに実行回数を書き込んだもの (一度も通っていない点のある行に % か ~ の印が付く)
SIM_COV      := $(BUILD)/tb_cov/Vtb_mem
SIM_COV_PLIC := $(BUILD)/plic_cov/Vplic_tb
SIM_COV_SRAM := $(BUILD)/sram_cov/Vsram_tb
SIM_COV_SDRAM_UNIT := $(BUILD)/sdram_unit_cov/Vsdram_tb
SIM_COV_SDRAM      := $(BUILD)/tb_sdram_cov/Vtb_mem
SIM_COV_SDRAM_HS_UNIT := $(BUILD)/sdram_hs_unit_cov/Vsdram_tb
SIM_COV_SDRAM_HS      := $(BUILD)/tb_sdram_hs_cov/Vtb_mem
COV          := $(BUILD)/cov
COV_FLAGS    := --coverage-line --coverage-toggle -Wno-UNOPTFLAT tools/coverage.vlt

$(SIM_COV): $(RTL_SRCS) $(TB_SRCS) tools/lint.vlt tools/coverage.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) $(COV_FLAGS) \
		--top-module tb_mem -Mdir $(BUILD)/tb_cov $(RTL_SRCS) $(TB_SRCS)

$(SIM_COV_SDRAM_UNIT): rtl/ahb_sdram.v tb/sdram_tb.v rtl/sdram_bridge.v tb/vendor/zeitlos/sdram_model.v tools/lint.vlt tools/coverage.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) $(COV_FLAGS) --top-module sdram_tb \
		-Mdir $(BUILD)/sdram_unit_cov rtl/ahb_sdram.v tb/sdram_tb.v rtl/sdram_bridge.v tb/vendor/zeitlos/sdram_model.v

$(SIM_COV_SDRAM): $(RTL_SRCS) $(TB_SRCS) $(SDRAM_SRCS) tools/lint.vlt tools/coverage.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) $(COV_FLAGS) $(SDRAM_FLAGS) --top-module tb_mem \
		-Mdir $(BUILD)/tb_sdram_cov $(RTL_SRCS) $(TB_SRCS) $(SDRAM_SRCS)

$(SIM_COV_SDRAM_HS_UNIT): rtl/ahb_sdram.v tb/sdram_tb.v $(HS_SRCS) tools/lint.vlt tools/coverage.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) $(COV_FLAGS) -DSDRAM_HS --top-module sdram_tb \
		-Mdir $(BUILD)/sdram_hs_unit_cov rtl/ahb_sdram.v tb/sdram_tb.v $(HS_SRCS)

$(SIM_COV_SDRAM_HS): $(RTL_SRCS) $(TB_SRCS) rtl/ahb_sdram.v $(HS_SRCS) tools/lint.vlt tools/coverage.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing --no-sched-zero-delay $(VERILATOR_FLAGS) $(COV_FLAGS) -DTB_SDRAM -DSDRAM_HS --top-module tb_mem \
		-Mdir $(BUILD)/tb_sdram_hs_cov $(RTL_SRCS) $(TB_SRCS) rtl/ahb_sdram.v $(HS_SRCS)

$(SIM_COV_SRAM): rtl/ahb_sram.v tb/sram_tb.v tools/lint.vlt tools/coverage.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing $(VERILATOR_FLAGS) $(COV_FLAGS) --top-module sram_tb -Mdir $(BUILD)/sram_cov \
		rtl/ahb_sram.v tb/sram_tb.v

$(SIM_COV_PLIC): rtl/ae350_plic.v tb/plic_tb.v tools/lint.vlt tools/coverage.vlt
	mkdir -p $(BUILD)
	verilator --binary --timing $(VERILATOR_FLAGS) $(COV_FLAGS) --top-module plic_tb -Mdir $(BUILD)/plic_cov \
		rtl/ae350_plic.v tb/plic_tb.v

# 1 回実行する: $(1) = プログラム名、$(2) = 出力の名前、$(3) = plusarg
define run_cov
	$(SIM_COV) +rom=$(BUILD)/$(1).hex $(3) +verilator+coverage+file+$(COV)/$(2).dat > $(COV)/$(2).log 2>&1 \
		|| (cat $(COV)/$(2).log; exit 1)
endef

S3_IN    := +uart_in=sw/stage3_input.txt
WAIT12   := +rom_wait=1 +ddr_wait=2
COV_RUNS := stage2_w00 stage2_w12 stage3_w00 stage3_w12 stage4_w00 stage4_w12 stage3_same stage4_same \
            stage3_odd stage4_odd stage4_reset stage2_rand1 stage3_rand1 stage4_rand1 \
            stage5_w00 stage5_w12 stage5_odd stage5_rand1

.PHONY: coverage
coverage: $(SIM_COV) $(SIM_COV_PLIC) $(SIM_COV_SRAM) $(SIM_COV_SDRAM_UNIT) $(SIM_COV_SDRAM) $(SIM_COV_SDRAM_HS_UNIT) $(SIM_COV_SDRAM_HS) $(BUILD)/stage2.hex $(BUILD)/stage3.hex $(BUILD)/stage4.hex $(BUILD)/stage5.hex
	mkdir -p $(COV)
	$(call run_cov,stage2,stage2_w00,$(STAGE2_ERR))
	$(call run_cov,stage2,stage2_w12,$(STAGE2_ERR) $(WAIT12))
	$(call run_cov,stage3,stage3_w00,$(S3_IN))
	$(call run_cov,stage3,stage3_w12,$(S3_IN) $(WAIT12))
	$(call run_cov,stage4,stage4_w00,)
	$(call run_cov,stage4,stage4_w12,$(WAIT12))
	$(call run_cov,stage3,stage3_same,$(S3_IN) $(CLK_SAME) $(WAIT12))
	$(call run_cov,stage4,stage4_same,$(CLK_SAME) $(WAIT12))
	$(call run_cov,stage3,stage3_odd,$(S3_IN) $(CLK_ODD) $(WAIT12))
	$(call run_cov,stage4,stage4_odd,$(CLK_ODD) $(WAIT12))
	$(call run_cov,stage4,stage4_reset,+reset_at=200000)
	$(call run_cov,stage2,stage2_rand1,$(STAGE2_ERR) $(RAND) +seed=1)
	$(call run_cov,stage3,stage3_rand1,$(S3_IN) $(RAND) +seed=1)
	$(call run_cov,stage4,stage4_rand1,$(RAND) +seed=1)
	$(call run_cov,stage5,stage5_w00,$(STAGE5_EXTM))
	$(call run_cov,stage5,stage5_w12,$(STAGE5_EXTM) $(WAIT12))
	$(call run_cov,stage5,stage5_odd,$(STAGE5_EXTM) $(CLK_ODD) $(WAIT12))
	$(call run_cov,stage5,stage5_rand1,$(STAGE5_EXTM) $(RAND) +seed=1)
	$(SIM_COV_PLIC) +verilator+coverage+file+$(COV)/plic_tb.dat > $(COV)/plic_tb.log 2>&1 || (cat $(COV)/plic_tb.log; exit 1)
	$(SIM_COV_SRAM) +verilator+coverage+file+$(COV)/sram_tb.dat > $(COV)/sram_tb.log 2>&1 || (cat $(COV)/sram_tb.log; exit 1)
	$(SIM_COV_SDRAM_UNIT) +verilator+coverage+file+$(COV)/sdram_tb.dat > $(COV)/sdram_tb.log 2>&1 || (cat $(COV)/sdram_tb.log; exit 1)
	$(SIM_COV_SDRAM) +rom=$(BUILD)/stage3.hex $(SDRAM_RUN) $(S3_IN) +verilator+coverage+file+$(COV)/sdram_stage3.dat > $(COV)/sdram_stage3.log 2>&1 || (cat $(COV)/sdram_stage3.log; exit 1)
	$(SIM_COV_SDRAM) +rom=$(BUILD)/stage4.hex $(SDRAM_RUN) +verilator+coverage+file+$(COV)/sdram_stage4.dat > $(COV)/sdram_stage4.log 2>&1 || (cat $(COV)/sdram_stage4.log; exit 1)
	$(SIM_COV_SDRAM) +rom=$(BUILD)/stage5.hex $(SDRAM_RUN) $(STAGE5_EXTM) +verilator+coverage+file+$(COV)/sdram_stage5.dat > $(COV)/sdram_stage5.log 2>&1 || (cat $(COV)/sdram_stage5.log; exit 1)
	$(SIM_COV_SDRAM_HS_UNIT) +verilator+coverage+file+$(COV)/sdram_hs_tb.dat > $(COV)/sdram_hs_tb.log 2>&1 || (cat $(COV)/sdram_hs_tb.log; exit 1)
	$(SIM_COV_SDRAM_HS) +rom=$(BUILD)/stage4.hex $(SDRAM_RUN) +verilator+coverage+file+$(COV)/sdram_hs_stage4.dat > $(COV)/sdram_hs_stage4.log 2>&1 || (cat $(COV)/sdram_hs_stage4.log; exit 1)
	verilator_coverage --write $(COV)/all.dat $(addprefix $(COV)/,$(addsuffix .dat,$(COV_RUNS))) $(COV)/plic_tb.dat $(COV)/sram_tb.dat \
		$(COV)/sdram_tb.dat $(COV)/sdram_stage3.dat $(COV)/sdram_stage4.dat $(COV)/sdram_stage5.dat \
		$(COV)/sdram_hs_tb.dat $(COV)/sdram_hs_stage4.dat
	verilator_coverage --annotate $(COV)/annotated --annotate-min 1 $(COV)/all.dat
