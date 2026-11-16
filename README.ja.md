# AE350 の Hazard3 版と Tang Console 向けボード構成

[English](README.md)

Gowin GW5AST-138 に内蔵された RISC-V ハードコア AE350（Andes A25）を扱うためのリポジトリです。
次の 2 つで構成されています。

- **Hazard3 版**（`rtl/AE350_SOC.v`）：Gowin のプリミティブ `AE350_SOC` と同じポートを持ち、内部で Hazard3 を動かす回路です。
  Gowin が提供するシミュレーションモデルはポート宣言だけで動作しないため、その代わりとして使います。
  FPGA のファブリック上で動かすこともできます（`CPU=hazard3`）。
  バスの振る舞い、アドレスマップ、PLIC と PLMT、クロックドメイン間の乗せ換えは、資料と実機での測定に合わせています。
- **ボード構成**（`board/tang_console/`）：Tang Console 138K 上で本物の AE350 を動かします。
  CPU 上のプログラムがレジスタの値を読み、UART に出力します。

## ディレクトリ構成

| ディレクトリ | 内容 |
|---|---|
| `rtl/` | Hazard3 版（AE350_SOC.v、ae350_fabric.v、ae350_plic.v、ae350_plmt.v など）と、ファブリック側の回路（apb_uart.v、apb_gpint.v、apb_paddr_probe.v、apb_reg_slice.v、ahb_reg_slice.v、ahb_sram.v、ahb_rom.v） |
| `tb/` | shell_top.v（AE350_SOC とファブリック側の回路をつないだトップ。シミュレーションと実機の両方で使う）とテストベンチ |
| `sw/` | テストプログラム（stage2_test.c〜stage5_test.c）、読み出しプログラム probe.c、リンカスクリプト |
| `board/tang_console/` | ボードのトップ、PLL、ピン制約とタイミング制約、ビルドスクリプト、監視回路 |
| `hazard3/` | Hazard3 v1.1.1 の RTL（変更点は hazard3/README.md） |
| `tools/` | ポート比較、lint とカバレッジの設定、hex 変換、UART の読み書き |

## シミュレーション

Verilator 5.052、Icarus Verilog 13.0、riscv64-elf-gcc、newlib を使います。
newlib の場所は `NEWLIB` で指定します（既定値はありません）。

| コマンド | 内容 |
|---|---|
| `make check` | プリミティブとのポート比較、lint、iverilog での読み込み |
| `make test` | テストプログラム、PLIC と RAM の単体テスト、クロックの組み合わせ、実行中のリセット、ランダムなウェイト |
| `make test-iverilog` | テストプログラムを 4 値シミュレーションで実行 |
| `make coverage` | カバレッジ |
| `make run-probe` | 読み出しプログラムを Hazard3 版で実行 |

### newlib のビルド（初回のみ）

newlib を使うプログラム（stage3_test〜stage5_test、hello、ddr3_check、mem_bench、CoreMark など）をビルドするときは、`NEWLIB` に newlib の場所を指定します（例：`make test NEWLIB=<インストール先>/riscv64-elf`）。
指定がないと、newlib を使うプログラムのビルドで止まります。
動作を確認したバージョンは 4.6.0.20260123 で、Homebrew の riscv64-elf-gcc と同じターゲットでビルドします。
tarball には libgloss のマニュアル（porting.info）が含まれておらず、その生成に makeinfo（texinfo）が必要になるため、`MAKEINFO=true` を指定してマニュアルの生成を省きます。
ライブラリ本体には影響しません。

    curl -O https://sourceware.org/pub/newlib/newlib-4.6.0.20260123.tar.gz
    tar xf newlib-4.6.0.20260123.tar.gz
    mkdir newlib-build && cd newlib-build
    ../newlib-4.6.0.20260123/configure --target=riscv64-elf --prefix=<インストール先> \
        --enable-newlib-io-long-double --enable-newlib-io-long-long --enable-newlib-io-c99-formats \
        --enable-newlib-register-fini CFLAGS_FOR_TARGET="-Os -mcmodel=medany"
    make MAKEINFO=true && make install MAKEINFO=true

## 実機

    sh board/tang_console/build.sh
    openFPGALoader -b tangconsole build/board/ae350_probe/impl/pnr/ae350_probe.fs

Gowin EDA Education 版 1.9.11.03 で、チップのリビジョン B 向けにビルドしています。
ROM はブロック RAM（内容は `sw/probe.c`）で、データとスタックは AE350 内蔵の DLM に置きます。
DDR3 は使いません。

出力は 2 つ目の USB シリアル（macOS では `/dev/cu.usbserial-<番号>1`）に 1,250,000 bps で出ます。
macOS の stty は 230400 bps を超える速度を受け付けないため、ポートを開いたまま `IOSSIOSPEED` で速度を設定します。
出力は `tools/ae350_uart.rb` で読めます。
このスクリプトは受信したデータを画面に出し、キーボードの入力を送信します。
秒数を指定するとその時間で終了し、指定しなければ Ctrl-C で終了します。
読み出しプログラムは 1 文字受け取るたびに値を出し直すので、最初から読むときは 1 文字送ります。
ただし起動直後の約 10 秒は時間を計測していて文字を受け取らないため、書き込んだ直後に全体を読むには、次のように 15 秒ほど待ちます。
`tools/ae350_uart.rb` と `tools/ae350_load.rb` は、速度の設定に macOS の `IOSSIOSPEED` を使うため、macOS でしか動きません。

    printf x | ruby tools/ae350_uart.rb /dev/cu.usbserial-<番号>1 15

CPU からの出力が 0.1 秒以上途切れると、監視回路（`board/tang_console/ae350_observer.v`）が CPU を介さずに次の行を出力します。

    OBS lk=<PLL のロック> rs=<リセット解除> hr=<HRESETN> pr=<PRESETN> rom=<ROM_H* の読み出し回数> ra=<最後のアドレス>
        apb=<APB_P* の転送回数> pa=<最後の PADDR> tx=<CPU が出力した文字数> c=<最後の文字> m=<その他の出力>

### 本物の AE350 を動かすための設定

- **CORE_CLK を生成する PLL を `PLL_R[0]` に配置します。**
  AE350 の CORE_CLK は、`PLL_R[0]` の clkout1 から専用配線で供給されます（Gowin MUG1031 8.4）。
  配置を指定しなくても合成と配置配線は警告なしで通りますが、その場合 AE350 は HRESETN と PRESETN を 0 のまま出力し、命令を一度もフェッチしません。
  配置は `top.cst` の `INS_LOC "u_pll/u_pll_s8" PLL_R[0];` で指定します（合成後のインスタンス名には `_s` が付きます）。
- **JTAG を使わないときは、`DBG_TCK`、`TMS_IN`、`TRST_IN` を 1、`TDI_IN` を 0 にします。**
  `POR_N` は 1 に固定し、リセットは `HW_RSTN` だけでかけます（LiteX の gowin_ae350 と同じ値です）。
- **`APB_P*` と `EXTS_H*` にレジスタを挟みます。**
  AE350 は FPGA の端（R0C160）にあり、配線だけで片道 4 ns 前後かかります。
  AE350 から出てファブリックの論理を通り、AE350 に戻る経路は、100 MHz のタイミングを満たしません。
  レジスタを挟む前は、`APB_P*` で UART への書き込みが途中で止まっていました。
  レジスタを挟んだうえで、`EXTS_H*` 側のスライスは `GRP_LOC` で AE350 の近くに配置します。
  `SDRAM=hs ROM=loader` のビルドでは、配置配線の結果は AHB_CLK 106.4 MHz、APB_CLK 130.3 MHz でした（ビルドの組み合わせと配置によって変わります）。

### 実機で読んだ値

| 項目 | 読んだ値 |
|---|---|
| CPU の識別子 | mvendorid 0x31e、marchid 0x80000a25、mimpid 0x160 |
| misa | 0x4094312d（RV32 IMAFDC + N、S、U、X） |
| ILM と DLM | 0xA000_0000 と 0xA020_0000、リセット直後から有効 |
| リセット直後のキャッシュ | mcache_ctl 0（無効） |
| mcycle と mtime | mcycle は 800 MHz、mtime は 100 MHz（AHB_CLK で進む） |
| PLIC | ターゲット 2 つ（0 が MEIP、1 が SEIP）、ソース 31 本、優先度 0〜3、全ソースがレベル割り込み。claim はしきい値で絞られ、complete は enable を落としていても有効 |
| GP_INT | GP_INT[0] はソース 4、GP_INT[1〜15] はソース 11〜25 |
| APB_P* の PADDR | 0xF800_0000 以降の全アドレスが出る。1 バイトと 2 バイトのアクセスも 4 バイト境界に揃い、PWDATA は書き込むバイトレーンにだけ値が入る |

Hazard3 版はこれらの値に合わせています。
ただし CPU は Hazard3 なので、次の点は本物と異なります。

- キャッシュ、F / D 拡張、S モードがありません（misa は Hazard3 の値です。PLIC のターゲット 1 の割り込みは CPU に接続していません）。
- Andes 独自の CSR（milmb、mdlmb、mcache_ctl、mmisc_ctl など）がありません（読むと不正命令例外になります）。
- 命令フェッチの速さと、バスのウェイトサイクル数が異なります。

## ローダー（UART でプログラムを送り、外部メモリで実行する）

ROM にローダー（`sw/loader.c`、2,001 バイト）を置くと、16 KB の ROM に焼き込まずに、UART 経由でプログラムを送って実行できます。
送り先は DDR_H* の先の外部メモリ（SDRAM 版はベースボードの SDRAM0 で 32 MB、DDR3 版は SOM の DDR3 で 1 GB）か、ILM です。
ビットストリームを作り直さずに、プログラムを何度でも上書きして送れます。

    SDRAM=hs ROM=loader sh board/tang_console/build.sh build/board-loader
    openFPGALoader -b tangconsole build/board-loader/ae350_probe/impl/pnr/ae350_probe.fs
    make build/hello.bin
    ruby tools/ae350_load.rb /dev/cu.usbserial-<番号>1 build/hello.bin

`ae350_load.rb` は、UART のリセットシーケンスで AE350 をリセットしてローダーに戻し、プログラムを送って長さと CRC-32 を照合し、一致すれば実行します。
その後は UART の出力を画面に出し、キーボードの入力を送信します。
プログラムが終了してローダーに戻るか、Ctrl-C で終了します。
UART の速度は 1,250,000 bps です（macOS では `IOSSIOSPEED` で設定します）。
ROM をローダーにしたビルドでは、監視回路は入れません。

### コマンドと応答

コマンドは 1 行のテキストで、アドレスと長さは 16 進 8 桁で書きます。
応答の行末は `\r\n` です。

| Mac → ローダー | ローダー → Mac |
|---|---|
| （電源投入時、プログラムから戻ったとき） | `READY ae350 loader` |
| `load <アドレス> <長さ>` | `GO`（受信可能）、`ERR range`、`ERR syntax` |
| データ（長さ分のバイト） | `OK <長さ> <CRC-32>`、`ERR timeout`、`ERR uart` |
| `run <アドレス>` | `RUN <アドレス>`（この後はプログラムの出力） |
| それ以外 | `ERR command` |

- データは `GO` を確認してから送ります。こうすると、拒否されたときにデータがコマンドとして解釈されません。
- アドレスと長さが外部メモリか ILM（0xA000_0000〜0xA000_FFFF）の範囲に収まらないと、`ERR range` を返します。
  外部メモリの容量は、起動時に 0x0200_0000 を読んで判別します（例外になれば SDRAM 版で 32 MB、ならなければ DDR3 版で 1 GB です）。
- `OK` の CRC-32 は、書き込んだ後に外部メモリから読み直したデータで計算します。
  zlib と同じ値なので、Ruby の `Zlib.crc32` で照合できます。
- データの途中で次のバイトが 1 秒届かないと `ERR timeout` を返します。
  受信中に受信バッファがあふれるか、ストップビットが 0 の文字を捨てると `ERR uart` を返します。
  どちらの場合もコマンド待ちに戻ります。
- 受信中はデータキャッシュを無効にして、外部メモリに直接書き込みます。
  `run` では `fence` と `fence.i` を実行し、データキャッシュを有効にしてからジャンプします。
  起動時には、データキャッシュを全てライトバックして無効化します（前のプログラムのデータが、新しいプログラムの上に書き戻されないようにするためです）。

### 外部メモリで動かすプログラム

リンカスクリプトは `sw/sdram.ld` です。
コード、データ、ヒープを外部メモリの 0x0001_0000 から配置し、スタックを DLM に置きます。
`sw/start.S` を `START_RETURN_TO_ROM` を定義してビルドすると、`main` から戻ったときに ROM のローダーに戻ります。
ビルド方法は Makefile の `hello.bin`（newlib の printf と fgets を使う 48,464 バイトのプログラム）を参照してください。

### リセットシーケンスでローダーに戻す

UART に 8 バイトのリセットシーケンス `1B 1B 61 65 33 35 30 21`（ESC ESC "ae350!"）が連続して届くと、`rtl/uart_reset_seq.v` が AE350 の `HW_RSTN` に 10 µs のリセットをかけ、ROM のローダーから起動し直します。
プログラムが固まっても、電源を入れ直さずに戻せます。
SDRAM コントローラと、シーケンスを監視する回路自体はリセットしません。
ローダーがデータを受信している間は監視を止める（`rtl/apb_uart.v` の CTRL レジスタ）ので、送るプログラムにこの 8 バイトが含まれていてもリセットはかかりません。
プログラムの実行中にこの 8 バイトを含む入力を送ると、リセットがかかります。

### テスト

| コマンド | 内容 |
|---|---|
| `make test-loader` | 拒否されるコマンド、GO、タイムアウト、受信エラー、CRC-32、リセットシーケンスを含むデータ、止まらないプログラムからのリセットシーケンスによる復帰、hello の送信と実行（実機と同じ 1.25 Mbps の間隔で送るので、数分かかる） |
| `make test-uart-reset` | リセットシーケンス検出回路の単体テスト |
| `make test-uart-tool` | tools/ae350_uart.rb の単体テスト（シリアルポートの代わりに UNIX ドメインソケットを使う） |

`make test-loader` の手順ファイルは `tools/loader_test.rb` が生成し、テストベンチの `+uart_script` で流します。
3 つとも `make test` に含まれています。

### 実機での確認（166.7 MHz 版）

- hello を 0.4 秒で送って実行し、ローダーに戻った後、電源を入れ直さずにもう一度送って実行しました。
- 止まらないプログラムを実行した後、電源を入れ直さずにリセットシーケンスで戻し、hello を実行しました。

## DDR3 版（DDR_H* の先を SOM の DDR3 にする）

    MEM=ddr3 ROM=loader sh board/tang_console/build.sh build/board-ddr3

DDR_H* の先を、ベースボードの SDRAM ではなく SOM の DDR3（H5TQ4G63EFR を 2 個、DQ 32 ビット、1 GB）にします。
DDR3 コントローラは Gowin の DDR3 Memory Interface IP（メモリクロック 400 MHz、1:4）で、DDR_H* との間は `rtl/ahb_ddr3.v` が接続します。
シミュレーションでは DDR_H* の先は SDRAM のままで、DDR3 版は実機でのみ確認します（IP 本体が暗号化されていて、シミュレーションできないためです）。

### IP の生成（初回のみ）

IP 本体は Gowin のツールが生成するファイルなので、リポジトリには含めていません。
設定ファイル `board/tang_console/ddr3/ddr3_memory_interface.ipc` から、Gowin EDA の IP Core Generator で生成します。

1. IP Core Generator を開き、Open Config File で `board/tang_console/ddr3/ddr3_memory_interface.ipc` を開きます。
2. Device が GW5AST-138、Device Version が B になっていることを確認して OK を押します。
3. 同じフォルダに `ddr3_memory_interface.v` が生成されます。
   「Decode Process failed」と表示されることがありますが、生成されないのはシミュレーション用の `.vo` だけで、合成には使いません。

チップのリビジョン C のボードでは、`.ipc` の `target_device` を `gw5ast138c-007` にして生成します（`build.tcl` と `board/tang_console/ddr3/gowin_pll.mod` の `-device_version` も C に変えます）。
DDR3 用 PLL の本体（`gowin_pll_mod.v`）は、`build.sh` が `board/tang_console/ddr3/gowin_pll.mod` から Gowin の GowinModgen で出力先に生成します。

設定ファイル、PLL のラッパー（`gowin_pll.v`、`pll_init.v`）、ピン制約（`ddr3.cst`）の出典は、Sipeed の TangMega-138K-example の `ddr_memory/ddr_memory_test_uart`（Apache-2.0。Tang Console 138K で動作する DDR3 のテスト）です。

### ブリッジ回路（`rtl/ahb_ddr3.v`）

- DDR_H*（64 ビット AHB、DDR_CLK 50 MHz）の転送を 1 つずつ IP のクロック（100 MHz）に乗せ換え、IP への読み出しコマンドと書き込みコマンドに変換します。
  IP は 1 コマンドで 32 バイト（DQ 32 ビット × 8 ビート）を読み書きします。
- 書き込みでは、32 バイトのうち HSIZE とアドレスで決まるバイトだけを書き込みます（ほかのバイトはマスクします）。
  IP がコマンドを受け付けた時点で AE350 に応答を返します。
- 読み出しでは、32 バイトを読んでアドレスのビット 4〜3 で選んだ 8 バイトを返し、その 32 バイトを保持します。
  同じ 32 バイトへの読み出しは、IP にアクセスせずに保持した値から返します。
  同じ 32 バイトへの書き込みでは、保持した値も更新します。
- 1 GB を超えるアドレスはエラー応答を返します。
  ただし 0x7F00_0000 からの 32 バイトは時間計測用のカウンタで、読むと値が返ります（`sw/mem_bench.c` が計測区間の前後の差を取ります）。

  | オフセット | 内容 |
  |---|---|
  | +0x00 | 読み出し転送の数 |
  | +0x04 | 読み出しで AE350 を待たせた DDR_CLK のサイクル数 |
  | +0x08 | 書き込み転送の数 |
  | +0x0C | 書き込みで AE350 を待たせた DDR_CLK のサイクル数 |
  | +0x10 | 読み出しコマンドが受け付けられるまでの IP クロック数 |
  | +0x14 | 読み出しコマンドからデータが返るまでの IP クロック数 |
  | +0x18 | 書き込みコマンドが受け付けられるまでの IP クロック数 |
  | +0x1C | 保持した 32 バイトから返した読み出しの数 |

### アクセス速度（`sw/mem_bench.c`、データキャッシュなし、AE350 の CPU クロック 800 MHz で数えた 1 アクセスあたりのサイクル数）

| アクセス | DDR3 | SDRAM（166.7 MHz 版） |
|---|---|---|
| シーケンシャル書き込み | 96（120 ns） | 258（322 ns） |
| シーケンシャル読み出し | 179（224 ns） | 320（400 ns） |
| ランダム読み出し（4 KB 間隔） | 468（585 ns） | 320（400 ns） |

シーケンシャル読み出しでは、8 回のうち 7 回を保持した 32 バイトから返します。
ランダム読み出しでは毎回 IP から読み、IP の内部（読み出しコマンドからデータが返るまで）で IP クロック約 32 サイクル（320 ns）かかります。
DDR_H* の手前（AE350 の内部）とクロック乗せ換えにかかる時間は、SDRAM 版と同じです。
データキャッシュを有効にした CoreMark は、DDR3 版と SDRAM 版でほぼ同じでした（2183.7 と 2183.8）。

### Hazard3 版との組み合わせ

`CPU=hazard3 MEM=ddr3` でもビルドできます。
Hazard3 版では、`build.sh` が配置オプション（Gowin の `place_option`）を 2 にします。
Hazard3 内部のクリティカルパス（命令を受け取ってからデコードとバイパスの選択まで）は 40 MHz に対する余裕がほとんどなく、DDR3 版では既定の配置で core_clk が 38.5 MHz、`PLACE=2` で 40.1 MHz でした。

### 実機での確認

- `sw/ddr3_check.c`（ILM に置き、データキャッシュを無効にして DDR3 に書き込んで読み返す）で、アドレス 0 と 2^5〜2^29（1 GB 分のアドレス線）、32 バイト（IP の 1 コマンド分）の中の 4 つの 8 バイト、1、2、4 バイトの書き込みがすべて一致し、1 GB を超えるアドレス（0x4000_0000）では例外 5 になりました。
- hello と CoreMark（`build/coremark.bin`）を DDR3 に置いて実行しました。
- ローダーで 0x3FFF_0000 と 0x0200_0000 に送ったデータの CRC-32 が一致し、0x3FFF_FFF0 からの 32 バイトと 0x4000_0000 は `ERR range` になりました。
- Hazard3 版（`CPU=hazard3 MEM=ddr3`）でも、`ddr3_check`、`mem_bench`、hello、CoreMark（DDR3 に置いて 8.28）が動作しました。

## LiteDRAM 版（DDR3 コントローラをオープンソースにする）

    MEM=litedram ROM=loader sh board/tang_console/build.sh build/board-litedram

DDR_H* の先は DDR3 版と同じ SOM の DDR3（2 個、DQ 32 ビット、1 GB）で、コントローラを Gowin の IP ではなく LiteDRAM（BSD-2-Clause）にします。
アドレスと容量は DDR3 版と同じなので、`sw/ddr3_check.c` と `sw/mem_bench.c` はそのまま動きます。
Gowin の IP より遅いものの、生成される Verilog も含めてオープンソースで、IP Core Generator で IP を生成する手順が要りません。

### LiteX の仮想環境の作成（初回のみ）

`build.sh` は合成のたびに、LiteDRAM の `litedram_gen` で設定ファイル（`board/tang_console/litedram/tang_console.yml`）からコントローラの Verilog を出力先に生成します。
`litedram_gen` は Python の仮想環境にインストールし、その場所を `LITEX_VENV` で指定します（例：`MEM=litedram LITEX_VENV=<仮想環境> sh board/tang_console/build.sh`。既定値はありません）。
動作を確認したバージョンは次のとおりです（pip でインストールします）。

| パッケージ | リポジトリ | バージョン |
|---|---|---|
| migen | https://github.com/m-labs/migen | e19524c |
| litex | https://github.com/enjoy-digital/litex | 8cba6a6 |
| litedram | https://github.com/enjoy-digital/litedram | 60b5ae1 |
| litex-boards | https://github.com/litex-hub/litex-boards | 78bc7d7 |
| pythondata-cpu-vexriscv | https://github.com/litex-hub/pythondata-cpu-vexriscv | 642ecfe |
| pythondata-software-picolibc | https://github.com/litex-hub/pythondata-software-picolibc | 6a13ccc |
| pythondata-software-compiler_rt | https://github.com/litex-hub/pythondata-software-compiler_rt | 6eb7660 |
| meson | | 1.9.1 |
| ninja | | 1.13.0 |

各リポジトリを上記のコミットでインストールします。
picolibc と compiler_rt は中身を git のサブモジュールで持っているため、tarball ではなく git からインストールします。

    python3 -m venv <仮想環境>
    <仮想環境>/bin/pip install meson==1.9.1 ninja==1.13.0
    <仮想環境>/bin/pip install \
        https://github.com/m-labs/migen/archive/e19524c963a8342952840983047557707fbe0b6a.tar.gz \
        https://github.com/enjoy-digital/litex/archive/8cba6a6cc4455e5549b67ef8f9388116e9294d71.tar.gz \
        https://github.com/enjoy-digital/litedram/archive/60b5ae1b1ee5bc16ea695a93399434919797ff31.tar.gz \
        https://github.com/litex-hub/litex-boards/archive/78bc7d7e4a3b88098d552345444f2739f15a04f3.tar.gz \
        https://github.com/litex-hub/pythondata-cpu-vexriscv/archive/642ecfed1c84460555d6d803d660cc60cfc1ecb6.tar.gz \
        git+https://github.com/litex-hub/pythondata-software-picolibc@6a13ccce7c575b32c102dd9dc52178505b81fe39 \
        git+https://github.com/litex-hub/pythondata-software-compiler_rt@6eb76609c9627bf26635e57c63fb22cda7115887

生成されるコントローラには、初期化とリードレベリングを行う小さな CPU（VexRiscv）と、そのプログラム（LiteX の BIOS）が含まれます。
このプログラムは、ほかのプログラムと同じ RISC-V コンパイラ（`riscv64-elf-gcc`）でビルドされます。
`build.sh` は、生成された Verilog で ROM の初期値を読み込むパスを絶対パスに書き換え、仮想環境にある VexRiscv の Verilog を合成に加えます。
生成されたファイルはリポジトリに含めません。

### 設定

| 項目 | 設定 |
|---|---|
| 速度 | 1:2、コントローラ 50 MHz、DDR3 クロック 100 MHz（200 MT/s、DLL オフ） |
| ユーザポート | native（1 アクセス 32 バイト、アドレス 25 ビット） |
| ピン | `board/tang_console/litedram/ddram.cst`（1 個目は LiteX-Boards の Tang Console 定義、2 個目は Sipeed の DDR3 テストの .cst から） |

より速い設定（1:4、コントローラ 100 MHz、DDR3 400 MHz）は、コントローラのクロックが 100 MHz のタイミングを満たさなかったため採用していません。
詳細は `tang_console.yml` の冒頭に書いてあります。

電源投入から初期化とレベリングが終わるまでは、ボードの UART に LiteDRAM の初期化ログ（115,200 bps）が出ます。
その後は AE350 の UART に切り替わります。

### ブリッジ回路（`rtl/ahb_litedram.v`）

`rtl/ahb_ddr3.v` と同じ構成で、DDR_H* の転送を LiteDRAM のコントローラクロック（50 MHz）に乗せ換え、native ポートのコマンドに変換します。
直前に読んだ 32 バイトを保持すること、1 GB を超えるアドレスでエラー応答を返すこと、0x7F00_0000 からのカウンタの並びも同じです（カウンタの「IP クロック」は LiteDRAM のコントローラクロックに読み替えます）。
DDR3 の容量と 1 アクセスの幅はパラメータ（`MEM_AW`、`LINE_AW`）で変えられ、DDR3 1 個（512 MB、16 バイト）の構成にもできます。

### アクセス速度（`sw/mem_bench.c`、データキャッシュなし、AE350 の CPU クロック 800 MHz で数えた 1 アクセスあたりのサイクル数）

| アクセス | LiteDRAM | DDR3（Gowin の IP） | SDRAM（166.7 MHz 版） |
|---|---|---|---|
| シーケンシャル書き込み | 298（372 ns） | 96（120 ns） | 258（322 ns） |
| シーケンシャル読み出し | 260（325 ns） | 179（224 ns） | 320（400 ns） |
| ランダム読み出し（4 KB 間隔） | 781（976 ns） | 468（585 ns） | 320（400 ns） |

読み出しコマンドからデータが返るまでは、コントローラクロックで約 34 サイクルで、Gowin の IP（約 32 サイクル）とほぼ同じです。
コントローラクロックが Gowin の IP の半分（50 MHz と 100 MHz）なので、時間では約 2 倍になります。
書き込みでは、コマンドとデータが受け付けられるまでにコントローラクロックで約 12 サイクルかかります（Gowin の IP は 1 サイクルです）。

### 実機での確認

- LiteDRAM の初期化ログで、1.0 GiB 32-bit @ 200 MT/s として初期化され、4 組（DQS ごと）すべてでリードレベリングが通り、LiteDRAM 自身のメモリテストが通りました。
- `sw/ddr3_check.c` で、1 GB 分のアドレス線、32 バイトの中の 4 つの 8 バイト、1、2、4 バイトの書き込みがすべて一致し、1 GB を超えるアドレス（0x4000_0000）では例外 5 になりました。
- `sw/mem_bench.c` のシーケンシャル読み出しで読んだ 1024 ワードが、書き込んだ値と一致しました。
- hello を DDR3 に置いて実行しました（DDR3 1 個、512 MB の構成）。

## ライセンス

このリポジトリは Apache-2.0（`LICENSE`）です。
ただし次のファイルは他の作者によるもので、元のライセンスのまま含めています。

| 場所 | 出典 | ライセンス（本文） |
|---|---|---|
| `hazard3/` | Hazard3 v1.1.1（Luke Wren）。変更点は hazard3/README.md | Apache-2.0（hazard3/LICENSE） |
| `rtl/vendor/verilog-uart/` | verilog-uart（Alex Forencich） | MIT（rtl/vendor/verilog-uart/COPYING） |
| `tb/vendor/zeitlos/sdram_model.v` | zeitlos（Lone Dynamics）。変更点はファイルの冒頭 | 独自の条件（tb/vendor/zeitlos/LICENSE.md） |
| `board/tang_console/ddr3/` | Sipeed の TangMega-138K-example。ファイルごとの出典は board/tang_console/ddr3/README.md | Apache-2.0（LICENSE） |
| `board/tang_console/litedram/tang_console.yml` | LiteDRAM の examples/tang_mega_138k_pro.yml | BSD-2-Clause（board/tang_console/litedram/LICENSE.litedram） |
| `board/tang_console/litedram/ddram.cst` | 1 個目の DDR3：LiteX-Boards の Tang Console 定義 | BSD-2-Clause（board/tang_console/litedram/LICENSE.litex-boards） |
| `board/tang_console/litedram/ddram.cst` | 2 個目の DDR3：Sipeed の TangMega-138K-example | Apache-2.0（LICENSE） |
