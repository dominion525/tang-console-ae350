# AE350 の Hazard3 の版と、Tang Console での実機の構成

[English](README.md)

Gowin GW5AST-138 の中にある RISC-V のハードコア AE350 (= Andes A25) を扱うためのもの。2 つの部分からなる。

- **Hazard3 の版** (= `rtl/AE350_SOC.v`): Gowin の部品 `AE350_SOC` と同じポートを持ち、中で Hazard3 を動かす回路。シミュレーションに使い、FPGA のロジックでも動かせる (= `CPU=hazard3`)。Gowin のシミュレーションのモデルはポートを並べただけで動かないので、その代わりに使う。バスの形、アドレスマップ、PLIC / PLMT、クロックごとの乗せ換えを、資料と実機に合わせてある
- **実機の構成** (= `board/tang_console/`): Tang Console 138K の上で本物の AE350 を動かし、CPU のプログラムからレジスタの値を読んで UART に出す

## ディレクトリ

    rtl/                 Hazard3 の版 (= AE350_SOC.v、ae350_fabric.v、ae350_plic.v、ae350_plmt.v ほか) と、FPGA のロジック側の回路
                         (= apb_uart.v、apb_gpint.v、apb_paddr_probe.v、apb_reg_slice.v、ahb_reg_slice.v、ahb_sram.v、ahb_rom.v)
    tb/                  shell_top.v (= AE350_SOC と FPGA 側の回路をつないだトップ。シミュレーションでも実機でも使う)、TB
    sw/                  確認用のプログラム (= 段 2〜5)、読み出しプログラム probe.c、リンカスクリプト
    board/tang_console/  実機のトップ、PLL、ピンとクロックの指定、ビルドのスクリプト、見張りの回路
    hazard3/             Hazard3 v1.1.1 の RTL (= 変えた箇所は hazard3/README.md)
    tools/               ポートの比較、lint とカバレッジの指定、hex への変換

## シミュレーション

Verilator 5.052、Icarus Verilog 13.0、riscv64-elf-gcc と newlib (= `NEWLIB` で場所を渡す。既定値は無い) を使う。

    make check          部品とポートの比較、lint、iverilog での読み込み
    make test           段 2〜5、PLIC と RAM の単体の TB、クロックの組み合わせ、途中のリセット、乱数の待ち
    make test-iverilog  段 2〜5 を 4 値で流す
    make coverage       カバレッジ
    make run-probe      読み出しプログラムを Hazard3 の版で流す

### newlib を作る (= 最初に 1 回)

newlib を使うプログラム (= 段 3〜5、hello、ddr3_check、mem_bench、CoreMark など) を作るときは、`NEWLIB` に newlib の場所を渡す (= `make test NEWLIB=<場所>/riscv64-elf`)。渡していないと、newlib を使うプログラムを作るところで止まる。確かめた版は 4.6.0.20260123 で、riscv64-elf-gcc (= Homebrew) と同じ target で作る。tarball には libgloss の文書 (= porting.info) が入っておらず、作るのに makeinfo (= texinfo) が要るので、`MAKEINFO=true` で文書を作らないようにする (= ライブラリには関係しない)。

    curl -O https://sourceware.org/pub/newlib/newlib-4.6.0.20260123.tar.gz
    tar xf newlib-4.6.0.20260123.tar.gz
    mkdir newlib-build && cd newlib-build
    ../newlib-4.6.0.20260123/configure --target=riscv64-elf --prefix=<場所> \
        --enable-newlib-io-long-double --enable-newlib-io-long-long --enable-newlib-io-c99-formats \
        --enable-newlib-register-fini CFLAGS_FOR_TARGET="-Os -mcmodel=medany"
    make MAKEINFO=true && make install MAKEINFO=true

## 実機

    sh board/tang_console/build.sh
    openFPGALoader -b tangconsole build/board/ae350_probe/impl/pnr/ae350_probe.fs

ビルドは Gowin EDA の Education 版 1.9.11.03、チップの版 B で通している。ROM はブロック RAM (= 中身は `sw/probe.c`)、データとスタックは AE350 の中の DLM で、DDR3 は使わない。出力は USB シリアルの 2 つ目 (= macOS では /dev/cu.usbserial-<番号>1) に 1,250,000 bps で出る (= macOS の stty は 230400 を超える速さを受けないので、ポートを開いたまま `IOSSIOSPEED` で設定する)。何か 1 文字送ると、もう一度出す。

CPU の文字が 0.1 秒以上途切れると、見張りの回路 (= `board/tang_console/ae350_observer.v`) が、CPU を通さずに次の 1 行を出す。

    OBS lk=<PLL の lock> rs=<リセットの解除> hr=<HRESETN> pr=<PRESETN> rom=<ROM_H* の読み出しの回数> ra=<最後の番地>
        apb=<APB_P* の転送の回数> pa=<最後の PADDR> tx=<CPU が出した文字の数> c=<最後の文字> m=<ほかの出力>

### 本物の AE350 を動かすための設定

- **CORE_CLK を出す PLL を `PLL_R[0]` に置く。** AE350 の CORE_CLK は `PLL_R[0]` の clkout1 から専用の経路で届く (= Gowin MUG1031 8.4)。置き場所を指定しないと、合成も配置配線も警告なしで通るのに、AE350 は HRESETN / PRESETN を 0 のまま出し、命令を 1 回も読まない。指定は `top.cst` の `INS_LOC "u_pll/u_pll_s8" PLL_R[0];` (= 合成後の名前は `_s` 付きになる)
- **JTAG を使わないときの入力は `DBG_TCK` / `TMS_IN` / `TRST_IN` = 1、`TDI_IN` = 0。** `POR_N` は 1 にし、リセットは `HW_RSTN` だけでかける (= LiteX の gowin_ae350 と同じ値)
- **`APB_P*` と `EXTS_H*` をレジスタで区切る。** AE350 は FPGA の端 (= R0C160) にあり、行きと帰りの配線だけで片道 4 ns 前後かかる。AE350 から出た信号が FPGA 側の論理を通って AE350 に戻る経路は、100 MHz に収まらない。APB_P* は、区切る前は UART の書き込みの途中で止まった。区切ったうえで、EXTS_H* のスライスは `GRP_LOC` で AE350 の近くに置く。配置配線の報告は、`SDRAM=hs ROM=loader` のビルド (= 2026-11-12) で AHB_CLK 106.4 MHz、APB_CLK 130.3 MHz (= 数字はビルドの組み合わせと配置で変わる)

### 実機で読んだ値

    CPU の識別子             mvendorid 0x31e、marchid 0x80000a25、mimpid 0x160
    misa                    0x4094312d (= RV32 IMAFDC + N、S、U、X)
    ILM / DLM               0xA000_0000 / 0xA020_0000、起動直後から有効
    起動直後のキャッシュ        mcache_ctl 0 (= 無効)
    mcycle と mtime          mcycle 800 MHz、mtime 100 MHz (= AHB_CLK で進む)
    PLIC                    ターゲット 2 (= 0 は MEIP、1 は SEIP)、ソース 31、優先度 0〜3、全ソースがレベル、
                            claim はしきい値で絞る、complete は enable を落としていても効く
    GP_INT                  GP_INT[0] → ソース 4、GP_INT[1〜15] → ソース 11〜25
    APB_P* の PADDR          0xF800_0000 からの全アドレス。1 / 2 byte の読み書きでも 4 byte に揃い、
                            PWDATA は書くバイトのレーンだけに値が入る

Hazard3 の版はこれらに合わせてある。ただし、中の CPU は Hazard3 なので、次の点は本物と違う。

- キャッシュ、F / D 拡張、S モードが無い (= misa は Hazard3 の値。PLIC のターゲット 1 の通知は CPU につながない)
- Andes の CSR (= milmb、mdlmb、mcache_ctl、mmisc_ctl ほか) が無い (= 読むと不正命令の例外)
- 命令を読む速さとバスの待ちのサイクル数

## ローダー (= プログラムを UART で送り、SDRAM で動かす)

ROM にローダー (= `sw/loader.c`、2,001 byte) を置くと、16 KB の ROM に焼き込まずに、プログラムを UART で DDR_H* の先 (= SDRAM の版はベースボードの SDRAM0、32 MB。DDR3 の版は SOM の DDR3、1 GB) か ILM に送って動かせる。ビットストリームを作り直さずに、プログラムを何度でも上書きで送れる。

    SDRAM=hs ROM=loader sh board/tang_console/build.sh build/board-loader
    openFPGALoader -b tangconsole build/board-loader/ae350_probe/impl/pnr/ae350_probe.fs
    make build/hello.bin
    ruby tools/ae350_load.rb /dev/cu.usbserial-<番号>1 build/hello.bin

`ae350_load.rb` は、UART の合図で AE350 をリセットしてローダーに戻し、プログラムを送って長さと CRC-32 を照らし、合えば動かす。その後は UART の出力を画面に出し、キーボードの入力を送る。プログラムが終わってローダーに戻るか、Ctrl-C で終わる。UART は 1,250,000 bps (= macOS では `IOSSIOSPEED` で設定する)。ROM がローダーのビルドでは、見張りの回路は外す。

### 命令と返事

命令は 1 行の文字で、番地と長さは 16 進 8 桁。返事は行の終わりが `\r\n`。

    Mac → ローダー                        ローダー → Mac
    (電源投入、プログラムから戻った)          READY ae350 loader
    load <番地> <長さ>                     GO (= 受けられる) / ERR range / ERR syntax
    <中身 (= 長さ byte)>                   OK <長さ> <CRC-32> / ERR timeout / ERR uart
    run <番地>                             RUN <番地> (= この後はプログラムの出力)
    それ以外                               ERR command

- `GO` を見てから中身を送る。断られたときに中身が命令として読まれない
- 番地と長さは、DDR_H* の先か ILM (= 0xA000_0000〜0xA000_FFFF) に収まらないと `ERR range`。DDR_H* の先の大きさは、起動のときに 0x0200_0000 を読んで見分ける (= 例外になれば SDRAM の版で 32 MB、ならなければ DDR3 の版で 1 GB)
- `OK` の CRC-32 は、書いた後に SDRAM から読み直した中身で計算する (= zlib と同じ値。Ruby の `Zlib.crc32` で照らせる)
- 中身の途中で次の byte が 1 秒来ないと `ERR timeout`、受けている間に受信があふれるかストップビットが 0 の文字を捨てると `ERR uart` を返し、命令待ちに戻る
- 受けている間はデータキャッシュを切って SDRAM に直接書く。`run` では `fence` と `fence.i` の後、データキャッシュを入れてから飛ぶ。起動の始めにデータキャッシュを全部書き戻して捨てる (= 前のプログラムの値が、新しいプログラムの上に書き戻されないように)

### SDRAM で動かすプログラム

リンカスクリプトは `sw/sdram.ld`。プログラムとデータとヒープを SDRAM の 0x0001_0000 から、スタックを DLM に置く。`sw/start.S` を `START_RETURN_TO_ROM` を定義して作ると、`main` から戻ったときに ROM のローダーへ戻る。作り方は Makefile の `hello.bin` (= newlib の printf と fgets を使う 48,464 byte) を見る。

### UART の合図でローダーへ戻す

UART に 8 byte の合図 `1B 1B 61 65 33 35 30 21` (= ESC ESC "ae350!") が続けて来ると、`rtl/uart_reset_seq.v` が AE350 の `HW_RSTN` にリセットを 10 µs 入れ、ROM のローダーから始め直す。プログラムが固まっていても、電源を入れ直さずに戻せる。SDRAM の制御と、合図を見張る回路自身はリセットしない。ローダーが中身を受けている間は見張りを止める (= `rtl/apb_uart.v` の CTRL) ので、送るプログラムの中身にこの 8 byte が並んでいても、リセットはかからない。プログラムの実行中に、この 8 byte を含む入力を送ると、リセットがかかる。

### テスト

    make test-loader       断られる命令、GO、時間切れ、受信の誤り、CRC-32、合図を含む中身、止まらないプログラムから
                           合図で戻る、
                           hello を送って動かす (= 送る間隔は実機の 1.25 Mbps と同じ。数分かかる)
    make test-uart-reset   合図の回路の単体の TB

手順のファイルは `tools/loader_test.rb` が作り、TB の `+uart_script` で流す。どちらも `make test` に入っている。

### 実機で確かめたこと (= 166.7 MHz 版)

- hello を 0.4 秒で送って動かし、終わってローダーに戻った後、電源を入れ直さずにもう一度送って動かした
- 止まらないプログラムを動かした後、電源を入れ直さずに、合図で戻して hello を動かした

## DDR3 の版 (= DDR_H* の先を SOM の DDR3 にする)

    MEM=ddr3 ROM=loader sh board/tang_console/build.sh build/board-ddr3

DDR_H* の先を、ベースボードの SDRAM の代わりに、SOM の DDR3 (= H5TQ4G63EFR が 2 個、DQ 32 bit、1 GB) にする。DDR3 の制御は Gowin の DDR3 Memory Interface の IP (= メモリのクロック 400 MHz、1:4) で、DDR_H* との間は `rtl/ahb_ddr3.v` がつなぐ。シミュレーションでは DDR_H* の先は SDRAM のままで、DDR3 の版は実機でだけ確かめる (= IP の本体が暗号化されていて、シミュレーションできない)。

### IP を作る (= 最初に 1 回)

IP の本体は Gowin のツールが作るファイルなので、リポジトリには入れていない。設定 (= `board/tang_console/ddr3/ddr3_memory_interface.ipc`) から、Gowin EDA の IP Core Generator で作る。

1. IP Core Generator を開き、Open Config File で `board/tang_console/ddr3/ddr3_memory_interface.ipc` を開く
2. Device が GW5AST-138、Device Version が B (= 手元のボード) になっていることを確かめて OK を押す
3. 同じフォルダに `ddr3_memory_interface.v` ができる (= 「Decode Process failed」と出ることがあるが、できないのはシミュレーション用の `.vo` だけで、合成には使わない)

チップの版 C のボードでは、`.ipc` の `target_device` を `gw5ast138c-007` にして作る (= `build.tcl` と `board/tang_console/ddr3/gowin_pll.mod` の `-device_version` も C に変える)。DDR3 の PLL の中身 (= `gowin_pll_mod.v`) は、`build.sh` が `board/tang_console/ddr3/gowin_pll.mod` から Gowin の GowinModgen で出力先に作る。

設定、PLL の外側 (= `gowin_pll.v`、`pll_init.v`)、ピンの制約 (= `ddr3.cst`) の出どころは、Sipeed の TangMega-138K-example の `ddr_memory/ddr_memory_test_uart` (= Apache-2.0。Tang Console 138K で動いた DDR3 の試験)。

### つなぐ回路 (= `rtl/ahb_ddr3.v`)

- DDR_H* (= 64 bit の AHB、DDR_CLK 50 MHz) の転送を 1 つずつ、IP のクロック (= 100 MHz) に乗せ換えて、IP の読み書きの命令にする。IP は 1 回の命令で 32 byte (= DQ 32 bit × 8 回) を読み書きする
- 書きは、32 byte のうち HSIZE と番地で決まる byte だけを書く (= ほかの byte はマスクする)。IP が命令を受けた時点で AE350 に返す
- 読みは、32 byte を読んで番地の bit 4〜3 で 8 byte を返し、その 32 byte を覚えておく。同じ 32 byte の読みは、IP に行かずに覚えている値から返す。同じ 32 byte への書きは、覚えている値も書き換える
- 1 GB の外の番地はエラー応答。ただし 0x7F00_0000 からの 32 byte は、時間を数えるカウンタ (= 読むと値。`sw/mem_bench.c` が前後の差を取る)

      +0x00 読みの転送の数                       +0x04 読みで AE350 を待たせた DDR_CLK のサイクル数
      +0x08 書きの転送の数                       +0x0C 書きで AE350 を待たせた DDR_CLK のサイクル数
      +0x10 読みの命令が受けられるまでの IP のクロック  +0x14 読みの命令から値が来るまでの IP のクロック
      +0x18 書きの命令が受けられるまでの IP のクロック  +0x1C 覚えている 32 byte から返した読みの数

### 速さ (= `sw/mem_bench.c`、データのキャッシュなし、AE350 の CPU の 800 MHz で数えた 1 回あたり)

    読み書き                       DDR3            SDRAM (= 166.7 MHz 版)
    シーケンシャル書き込み             96 (= 120 ns)    258 (= 322 ns)
    シーケンシャル読み出し            179 (= 224 ns)    320 (= 400 ns)
    ランダム読み出し (= 4 KB 間隔)     468 (= 585 ns)    320 (= 400 ns)

シーケンシャル読み出しでは、8 回のうち 7 回を覚えている 32 byte から返す。ランダム読み出しでは毎回 IP から読み、IP の中 (= 読みの命令から値が来るまで) に IP のクロックで約 32 サイクル (= 320 ns) かかる。DDR_H* の手前 (= AE350 の中) と乗せ換えにかかる時間は、SDRAM の版と同じ。データのキャッシュを入れた CoreMark は、DDR3 の版と SDRAM の版でほぼ同じ (= 2183.7 と 2183.8)。

### Hazard3 の版

`CPU=hazard3 MEM=ddr3` でも作れる。Hazard3 の版は、`build.sh` が配置の設定 (= Gowin の `place_option`) を 2 にする。Hazard3 の中の遅い経路 (= 命令を受け取ってから解読とバイパスまで) は 40 MHz に対する余裕がほとんど無く、DDR3 の版では、既定の配置で core_clk が 38.5 MHz になり、`PLACE=2` で 40.1 MHz になった。

### 実機で確かめたこと

- `sw/ddr3_check.c` (= ILM に置き、データのキャッシュを切って DDR3 に書いて読み返す): 0 と 2^5〜2^29 の番地 (= 1 GB の番地の線)、32 byte (= IP の 1 回の命令) の中の 4 つの 8 byte、1 / 2 / 4 byte の書き込みが合い、1 GB の外 (= 0x4000_0000) は例外 5 になった
- hello と CoreMark (= `build/coremark.bin`) を DDR3 に置いて動かした
- ローダーで、0x3FFF_0000 と 0x0200_0000 に送った中身の CRC-32 が合い、0x3FFF_FFF0 から 32 byte と 0x4000_0000 は `ERR range` になった
- Hazard3 の版 (= `CPU=hazard3 MEM=ddr3`) でも、`ddr3_check`、`mem_bench`、hello、CoreMark (= DDR3 に置いて 8.28) が動いた

## LiteDRAM の版 (= DDR3 の制御をオープンソースにする)

    MEM=litedram ROM=loader sh board/tang_console/build.sh build/board-litedram

DDR_H* の先は DDR3 の版と同じ SOM の DDR3 (= 2 個、DQ 32 bit、1 GB) で、制御を Gowin の IP の代わりに LiteDRAM (= BSD-2-Clause) にする。番地と容量は DDR3 の版と同じなので、`sw/ddr3_check.c` と `sw/mem_bench.c` はそのまま動く。Gowin の IP より遅いが、生成した Verilog も含めてオープンソースで、IP Core Generator で IP を作る手順が要らない。

### LiteX の仮想環境を作る (= 最初に 1 回)

`build.sh` は合成のたびに、LiteDRAM の `litedram_gen` で、設定 (= `board/tang_console/litedram/tang_console.yml`) から制御の Verilog を出力先に書き出す。`litedram_gen` は Python の仮想環境に入れる。場所は `LITEX_VENV` で指定する (= `MEM=litedram LITEX_VENV=<場所> sh board/tang_console/build.sh`。既定値は無い)。確かめた版は次のとおり (= pip で入れる)。

    migen                            https://github.com/m-labs/migen                                e19524c
    litex                            https://github.com/enjoy-digital/litex                         8cba6a6
    litedram                         https://github.com/enjoy-digital/litedram                      60b5ae1
    litex-boards                     https://github.com/litex-hub/litex-boards                      78bc7d7
    pythondata-cpu-vexriscv          https://github.com/litex-hub/pythondata-cpu-vexriscv           642ecfe
    pythondata-software-picolibc     https://github.com/litex-hub/pythondata-software-picolibc      6a13ccc
    pythondata-software-compiler_rt  https://github.com/litex-hub/pythondata-software-compiler_rt   6eb7660
    meson 1.9.1、ninja 1.13.0

作り方 (= 各リポジトリの、上のコミットを入れる。picolibc と compiler_rt は中身を git の submodule で持つので、tarball ではなく git から入れる)。

    python3 -m venv <場所>
    <場所>/bin/pip install meson==1.9.1 ninja==1.13.0
    <場所>/bin/pip install \
        https://github.com/m-labs/migen/archive/e19524c963a8342952840983047557707fbe0b6a.tar.gz \
        https://github.com/enjoy-digital/litex/archive/8cba6a6cc4455e5549b67ef8f9388116e9294d71.tar.gz \
        https://github.com/enjoy-digital/litedram/archive/60b5ae1b1ee5bc16ea695a93399434919797ff31.tar.gz \
        https://github.com/litex-hub/litex-boards/archive/78bc7d7e4a3b88098d552345444f2739f15a04f3.tar.gz \
        https://github.com/litex-hub/pythondata-cpu-vexriscv/archive/642ecfed1c84460555d6d803d660cc60cfc1ecb6.tar.gz \
        git+https://github.com/litex-hub/pythondata-software-picolibc@6a13ccce7c575b32c102dd9dc52178505b81fe39 \
        git+https://github.com/litex-hub/pythondata-software-compiler_rt@6eb76609c9627bf26635e57c63fb22cda7115887

書き出した制御の中には、初期化と読み出しの調整をする小さな CPU (= VexRiscv) と、そのプログラム (= LiteX の BIOS) が入る。プログラムは、ほかのプログラムと同じ RISC-V のコンパイラ (= `riscv64-elf-gcc`) で作られる。`build.sh` は、書き出した Verilog の ROM の中身の読み込みを絶対パスに書き換え、仮想環境の VexRiscv の Verilog を合成に足す。書き出したものはリポジトリに入れない。

### 設定

    速さ        1:2、制御 50 MHz、DDR3 のクロック 100 MHz (= 200 MT/s、DLL を切る)
    利用者の口  native (= 1 回 32 byte、番地 25 bit)
    ピン        board/tang_console/litedram/ddram.cst (= 1 個目は LiteX-Boards の Tang Console の定義、2 個目は Sipeed の DDR3 の試験の .cst)

速い設定 (= 1:4、制御 100 MHz、DDR3 400 MHz) は、制御のクロックが 100 MHz に収まらず、選ばなかった。理由は `tang_console.yml` の冒頭に書いてある。

電源を入れてから初期化と調整が済むまでは、ボードの UART に LiteDRAM の初期化の記録 (= 115,200 bps) が出る。済んだ後は AE350 の UART に切り替わる。

### つなぐ回路 (= `rtl/ahb_litedram.v`)

`rtl/ahb_ddr3.v` と同じ形で、DDR_H* の転送を LiteDRAM の制御のクロック (= 50 MHz) に乗せ換え、native port の命令にする。直前に読んだ 32 byte を覚えておくこと、1 GB の外の番地がエラー応答なこと、0x7F00_0000 からのカウンタの並びも同じ (= カウンタの「IP のクロック」は、LiteDRAM の制御のクロック)。DDR3 の容量と 1 回の幅はパラメータ (= `MEM_AW`、`LINE_AW`) で、DDR3 1 個 (= 512 MB、16 byte) にもできる。

### 速さ (= `sw/mem_bench.c`、データのキャッシュなし、AE350 の CPU の 800 MHz で数えた 1 回あたり)

    読み書き                       LiteDRAM          DDR3 (= Gowin の IP)   SDRAM (= 166.7 MHz 版)
    シーケンシャル書き込み            298 (= 372 ns)    96 (= 120 ns)         258 (= 322 ns)
    シーケンシャル読み出し            260 (= 325 ns)    179 (= 224 ns)        320 (= 400 ns)
    ランダム読み出し (= 4 KB 間隔)     781 (= 976 ns)    468 (= 585 ns)        320 (= 400 ns)

読みの命令から値が来るまでは、制御のクロックで約 34 サイクルで、Gowin の IP (= 約 32 サイクル) とほぼ同じ。制御のクロックが Gowin の IP の半分 (= 50 MHz と 100 MHz) なので、時間では約 2 倍になる。書きは、命令とデータが受けられるまでに制御のクロックで約 12 サイクルかかる (= Gowin の IP は 1 サイクル)。

### 実機で確かめたこと

- LiteDRAM の初期化の記録で、1.0 GiB 32-bit @ 200 MT/s として初期化し、読み出しの調整が 4 組 (= DQS) とも通り、LiteDRAM 自身のメモリの試験が通った
- `sw/ddr3_check.c` で、1 GB の番地の線、32 byte の中の 4 つの 8 byte、1 / 2 / 4 byte の書き込みが合い、1 GB の外 (= 0x4000_0000) は例外 5 になった
- `sw/mem_bench.c` のシーケンシャル読み出しで読んだ 1024 語が、書いた値と合った
- hello を DDR3 に置いて動かした (= DDR3 1 個、512 MB の形で)

## ライセンス

このリポジトリは Apache-2.0 (= `LICENSE`)。ただし、次のファイルは他の人が作ったもので、元のライセンスのまま入れている。

    場所                                         出どころ                                          ライセンス (= 本文)
    hazard3/                                     Hazard3 v1.1.1 (= Luke Wren)。変えた箇所は         Apache-2.0 (= hazard3/LICENSE)
                                                 hazard3/README.md
    rtl/vendor/verilog-uart/                     verilog-uart (= Alex Forencich)                   MIT (= rtl/vendor/verilog-uart/COPYING)
    tb/vendor/zeitlos/sdram_model.v              zeitlos (= Lone Dynamics)。変えた箇所はファイルの冒頭  独自の条件 (= tb/vendor/zeitlos/LICENSE.md)
    board/tang_console/ddr3/                     Sipeed の TangMega-138K-example。ファイルごとの     Apache-2.0 (= LICENSE)
                                                 出どころは board/tang_console/ddr3/README.md
    board/tang_console/litedram/tang_console.yml LiteDRAM の examples/tang_mega_138k_pro.yml        BSD-2-Clause (= board/tang_console/litedram/LICENSE.litedram)
    board/tang_console/litedram/ddram.cst        1 個目の DDR3: LiteX-Boards の Tang Console の定義  BSD-2-Clause (= board/tang_console/litedram/LICENSE.litex-boards)
                                                 2 個目の DDR3: Sipeed の TangMega-138K-example     Apache-2.0 (= LICENSE)
