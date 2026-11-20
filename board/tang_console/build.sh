#!/bin/sh
# ボード構成 (board/tang_console/top.v) のビットストリームを作る。
#   sh board/tang_console/build.sh [出力先]     (既定値は build/board)
# 先に ROM に置くプログラム (既定は sw/probe.c) をビルドし、その hex を ROM の内容として合成する。
# ビットストリームは <出力先>/ae350_probe/impl/pnr/ae350_probe.fs
#
# 構成は環境変数で選ぶ。
#   (指定なし)       DDR_H* の先はベースボードの SDRAM。コントローラは sdram_ctrl_hs + sdram_io (166.7 MHz)
#   DLY=<0〜255>     SDRAM の DQ の入力の IODELAY のステップ数 (1 ステップ約 12.5 ps、既定値 180)
#   EDGE=<0|1>       SDRAM の読み出しデータを取り込むエッジ (0 は立ち上がり、1 は立ち下がり。既定値 0)
#   RDF=<数>         SDRAM の読み出しワードを取り込むタイミング RD_FIRST (既定値 12、立ち下がりなら 11)
#   ROM=loader       ROM に、UART でプログラムを受信して外部メモリで実行するローダー (sw/loader.c) を置く。監視回路
#                    (ae350_observer) は外す。既定値は ROM=probe (sw/probe.c)
#   CPU=hazard3      本物の AE350 の代わりに、Hazard3 版 (rtl/AE350_SOC.v) をファブリック上で動かす
#   CPU=hazard3-fast 同上で、Hazard3 の高速化オプション (分岐予測、高速な乗算器) を有効にする (命令セットは AE350 と同じ)
#   MEM=ddr3         DDR_H* の先を SOM の DDR3 (Gowin の DDR3 IP、1 GB) にする。SDRAM は使わない。
#                    IP は ddr3/ddr3_memory_interface.v (IDE の IP Core Generator でリビジョン B 向けに生成したもの)
#   MEM=litedram     DDR_H* の先を SOM の DDR3 (2 個、1 GB) にし、コントローラを LiteDRAM にする (litedram/tang_console.yml から
#                    litedram_gen で出力先に生成する)。LITEX_VENV で LiteX の仮想環境を指定する (既定値はない。作り方は README)
#   PLACE=<値> ROUTE=<値>  配置配線のオプション (Gowin の place_option と route_option)。指定しなければ Gowin の既定値
#                    (CPU=hazard3 MEM=ddr3 で、配置によって core_clk のタイミング違反が出たため)。Hazard3 版の PLACE の既定値は 2
#   HDMI=1           HDMI の出力を足す (1280×720 / 60 Hz のテストパターンと、48 kHz の無音の音声。hdl-util/hdmi、HDMI の PLL は
#                    hdmi_pll.v、ピンは hdmi.cst)。CPU とはつながない。合成は SystemVerilog 2017 の指定で行う
#   TRACE=1          デバッグ用。ahb_sdram に、受け付けた転送の記録を入れる (rtl/ahb_sdram.v の AHB_SDRAM_TRACE)
G=${GOWIN_IDE:-/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE}
here=$(cd "$(dirname "$0")" && pwd)
ae=$(cd "$here/../.." && pwd)
out=${1:-$ae/build/board}
rom=${ROM:-probe}
case "$rom" in
  probe|loader) ;;
  *) echo "ROM must be probe or loader" >&2; exit 1 ;;
esac
make -C "$ae" "build/$rom.hex" || exit 1
mkdir -p "$out"
out=$(cd "$out" && pwd)
printf '`define AE350_ROM_HEX "%s/build/%s.hex"\n' "$ae" "$rom" > "$out/defines.v"
if [ "$rom" = loader ]; then
  printf '`define AE350_NO_OBSERVER\n' >> "$out/defines.v"
fi
printf '`define SDRAM_IN_DLY %s\n`define SDRAM_CAP_EDGE %s\n`define SDRAM_RD_FIRST %s\n' "${DLY:-180}" "${EDGE:-0}" "${RDF:-12}" >> "$out/defines.v"
export AE350_SDC="$here/top.sdc"
# デバッグ用: TRACE=1 で ahb_sdram に転送の記録を入れる (通常のビルドには入れない)
if [ "${TRACE:-}" = 1 ]; then
  printf '`define AHB_SDRAM_TRACE\n' >> "$out/defines.v"
fi
export AE350_BOARD_BUILD=$out
# Hazard3 版は、指定がなければ配置オプションを 2 にする (Hazard3 内部のクリティカルパスは 40 MHz に対するスラックがほとんどなく、
# CPU=hazard3 MEM=ddr3 では、既定値と PLACE=1 で core_clk にタイミング違反が出て、PLACE=2 で解消した)
# CPU=hazard3-fast は、指定がなければ配線オプションも 1 にする (MEM=ddr3 で、PLACE=2 だけでは core_clk に 5 か所の
# タイミング違反が残り、ROUTE=1 で解消した。PLACE=1、PLACE=3、ROUTE=2 では解消しなかった)
case "${CPU:-ae350}" in
  hazard3-fast) PLACE=${PLACE:-2}; ROUTE=${ROUTE:-1} ;;
  hazard3*) PLACE=${PLACE:-2} ;;
esac
export AE350_PLACE_OPTION=${PLACE:-}
export AE350_ROUTE_OPTION=${ROUTE:-}
export AE350_MEM=${MEM:-sdram}
case "$AE350_MEM" in
  sdram) ;;
  ddr3)
    printf '`define AE350_MEM_DDR3\n' >> "$out/defines.v"
    ;;
  litedram)
    printf '`define AE350_MEM_LITEDRAM\n' >> "$out/defines.v"
    ;;
  *) echo "MEM must be sdram, ddr3, or litedram" >&2; exit 1 ;;
esac
export AE350_CPU=${CPU:-ae350}
if [ "$AE350_CPU" = hazard3-fast ]; then
  AE350_CPU=hazard3
  printf '`define AE350_HAZARD3_FAST\n' >> "$out/defines.v"
fi
if [ "$AE350_CPU" = hazard3 ]; then
  printf '`define AE350_CPU_HAZARD3\n' >> "$out/defines.v"
  # ILM と DLM を Gowin の DPB で作る (rtl/ae350_fabric.v の g_tcm。2 つのクロックで書き込むメモリを、合成ツールが always の記述から推論できないため)
  printf '`define AE350_GOWIN_BSRAM\n' >> "$out/defines.v"
  ruby "$here/make_sdc_hazard3.rb" "$AE350_SDC" "$out/top_hazard3.sdc" || exit 1
  export AE350_SDC="$out/top_hazard3.sdc"
fi
if [ "$AE350_MEM" = ddr3 ]; then
  ruby "$here/make_sdc_ddr3.rb" "$AE350_SDC" "$out/top_ddr3.sdc" || exit 1
  export AE350_SDC="$out/top_ddr3.sdc"
fi
if [ "$AE350_MEM" = litedram ]; then
  # litedram/tang_console.yml の 1:2、システムクロック 50 MHz (DDR3 のクロック 100 MHz で周期 10 ns、コントローラは 20 ns)
  ruby "$here/make_sdc_litedram.rb" "$AE350_SDC" "$out/top_litedram.sdc" 10 20 || exit 1
  export AE350_SDC="$out/top_litedram.sdc"
fi
# ピン制約と配置制約は、出力先に 1 つにまとめて作る (Gowin の合成ツールは制約ファイルを 1 つしか使わず、後から追加したものだけが
# 有効になる。ddr3.cst だけが有効になり、clk50 と UART が別のピンに配置されたことがあった)。DDR3 版は top.cst に ddr3/ddr3.cst を追加する
cat "$here/top.cst" > "$out/top_build.cst" || exit 1
# HDMI=1: HDMI の出力を足す。hdl-util/hdmi の Gowin 向けのシリアライザ (OSER10) は GW_IDE のときだけ入る
export AE350_HDMI=${HDMI:-}
case "$AE350_HDMI" in
  "") ;;
  1)
    printf '`define AE350_HDMI\n`define GW_IDE\n' >> "$out/defines.v"
    cat "$here/hdmi.cst" >> "$out/top_build.cst" || exit 1
    ruby "$here/make_sdc_hdmi.rb" "$AE350_SDC" "$out/top_hdmi.sdc" || exit 1
    export AE350_SDC="$out/top_hdmi.sdc"
    ;;
  *) echo "HDMI must be 1 or unset" >&2; exit 1 ;;
esac
[ "$AE350_MEM" = ddr3 ] && cat "$here/ddr3/ddr3.cst" >> "$out/top_build.cst"
# LiteDRAM 版: litedram_gen でコントローラを出力先に生成し、ROM の内容を絶対パスで読み込むように書き換える (生成された Verilog は
# $readmemh を相対パスで書くため)。Gowin のライブラリの環境変数 (下の DYLD_*) を設定する前に実行する
if [ "$AE350_MEM" = litedram ]; then
  venv=${LITEX_VENV:-}
  [ -n "$venv" ] && [ -x "$venv/bin/litedram_gen" ] || { echo "set LITEX_VENV to a LiteX virtual environment with litedram_gen installed (see README for setup)" >&2; exit 1; }
  PATH="$venv/bin:$PATH" litedram_gen "$here/litedram/tang_console.yml" --output-dir "$out/litedram" > "$out/litedram_gen.log" 2>&1 ||
    { echo "litedram_gen failed (see $out/litedram_gen.log)" >&2; exit 1; }
  g="$out/litedram/gateware"
  sed -e "s|readmemh(\"litedram_core_rom.init\"|readmemh(\"$g/litedram_core_rom.init\"|" \
      -e "s|readmemh(\"litedram_core_sram.init\"|readmemh(\"$g/litedram_core_sram.init\"|" "$g/litedram_core.v" > "$out/litedram_core.v"
  grep -q "$g/litedram_core_rom.init" "$out/litedram_core.v" || { echo "could not rewrite the path to the ROM contents" >&2; exit 1; }
  # DDR3 のクロックを止める信号を、DHCE が受けるクロックで受け直す (理由は retime_litedram_stop.rb の冒頭)
  ruby "$here/retime_litedram_stop.rb" "$out/litedram_core.v" || exit 1
  AE350_VEXRISCV_V="$("$venv/bin/python" -c 'import pythondata_cpu_vexriscv as v; print(v.data_location)')/VexRiscv.v"   # data_location は verilog のフォルダ
  [ -f "$AE350_VEXRISCV_V" ] || { echo "VexRiscv.v not found" >&2; exit 1; }
  export AE350_VEXRISCV_V
  cat "$here/litedram/ddram.cst" >> "$out/top_build.cst"
fi
case "$(uname)" in
  Darwin) export DYLD_LIBRARY_PATH=$G/lib DYLD_FRAMEWORK_PATH=$G/lib ;;
esac
# DDR3 の PLL の本体 (gowin_pll_mod.v) は、Gowin の GowinModgen で ddr3/gowin_pll.mod から出力先に生成する (Gowin のツールが
# 生成するファイルなので、リポジトリには含めない)
if [ "$AE350_MEM" = ddr3 ]; then
  mkdir -p "$out/ddr3_pll"
  sed "s|^-path .*|-path $out/ddr3_pll/|" "$here/ddr3/gowin_pll.mod" > "$out/ddr3_pll/gowin_pll.mod"
  "$G/bin/GowinModgen" -do "$out/ddr3_pll/gowin_pll.mod" > "$out/ddr3_pll/modgen.log" 2>&1 || { cat "$out/ddr3_pll/modgen.log"; exit 1; }
  [ -f "$out/ddr3_pll/gowin_pll_mod.v" ] || { echo "could not generate the DDR3 PLL" >&2; exit 1; }
  [ -f "$here/ddr3/ddr3_memory_interface.v" ] || { echo "DDR3 IP (ddr3/ddr3_memory_interface.v) not found; generate it as described in the DDR3 build section of README.md" >&2; exit 1; }
fi
exec "$G/bin/gw_sh" "$here/build.tcl"
