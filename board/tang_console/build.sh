#!/bin/sh
# 実機の値を読む構成 (= board/tang_console/top.v) のビットストリームを作る。
#   sh board/tang_console/build.sh [出力先]     (= 既定は build/board)
# 先に読み出しプログラム (= sw/probe.c) を作り、その hex を ROM の中身として合成する。
# ビットストリームは <出力先>/ae350_probe/impl/pnr/ae350_probe.fs
#
# SDRAM の制御は、環境変数で選ぶ。
#   (指定なし)       sdram_bridge (= 20 MHz 版)
#   SDRAM=hs         sdram_ctrl_hs + sdram_io (= 166.7 MHz 版)。DLY=<0〜255> (= DQ の入力の IODELAY の刻み、約 12.5 ps、
#                    既定 180)、EDGE=<0|1> (= 0 立ち上がり、1 立ち下がりで取る。既定 0)、RDF=<数> (= 読んだ語を取る位置
#                    RD_FIRST、既定 12。立ち下がりなら 11)。クロックの指定は top.sdc から作り、出力先に置く
#   ROM=loader       ROM に、プログラムを UART で受けて SDRAM で動かすローダー (= sw/loader.c) を置く。観測の回路
#                    (= ae350_observer) は外す。既定は ROM=probe (= sw/probe.c)
#   CPU=hazard3      本物の AE350 の代わりに、Hazard3 の版 (= rtl/AE350_SOC.v) を FPGA のロジックで動かす
#   CPU=hazard3-fast 同上で、Hazard3 の速さの選択肢 (= 分岐予測、速い乗算器) と Zb* の拡張を全部入れる (= AE350 との互換性は無い)
#   MEM=ddr3         DDR_H* の先を SOM の DDR3 (= Gowin の DDR3 の IP、1 GB) にする。SDRAM は使わない (= SDRAM=hs とは
#                    一緒に使えない)。IP は ddr3/ddr3_memory_interface.v (= IDE の IP Core Generator で版 B 向けに作ったもの)
#   MEM=litedram     実験。DDR_H* の先を SOM の DDR3 の 1 個目 (= 512 MB) にし、制御は LiteDRAM (= litedram/tang_console.yml を
#                    litedram_gen で出力先に書き出す)。LITEX_VENV で LiteX の仮想環境を指定する (= 既定値は無い。作り方は README)
#   PLACE=<値> ROUTE=<値>  配置配線の設定 (= Gowin の place_option / route_option)。指定しなければ Gowin の既定
#                    (= 2026-11-16、CPU=hazard3 MEM=ddr3 で core_clk の違反が配置で出たため)。Hazard3 の版の PLACE の既定は 2
#   TRACE=1          実験用。ahb_sdram に、受けた転送の記録を入れる (= rtl/ahb_sdram.v の AHB_SDRAM_TRACE)
G=${GOWIN_IDE:-/Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE}
here=$(cd "$(dirname "$0")" && pwd)
ae=$(cd "$here/../.." && pwd)
out=${1:-$ae/build/board}
rom=${ROM:-probe}
case "$rom" in
  probe|loader) ;;
  *) echo "ROM は probe か loader" >&2; exit 1 ;;
esac
make -C "$ae" "build/$rom.hex" || exit 1
mkdir -p "$out"
out=$(cd "$out" && pwd)
printf '`define AE350_ROM_HEX "%s/build/%s.hex"\n' "$ae" "$rom" > "$out/defines.v"
if [ "$rom" = loader ]; then
  printf '`define AE350_NO_OBSERVER\n' >> "$out/defines.v"
fi
if [ "${SDRAM:-}" = hs ]; then
  dly=${DLY:-180}
  edge=${EDGE:-0}
  rdf=${RDF:-12}
  printf '`define SDRAM_HS\n`define SDRAM_IN_DLY %s\n`define SDRAM_CAP_EDGE %s\n`define SDRAM_RD_FIRST %s\n' "$dly" "$edge" "$rdf" >> "$out/defines.v"
  ruby "$here/make_sdc_hs.rb" "$here/top.sdc" "$out/top.sdc" || exit 1
  export AE350_SDC="$out/top.sdc"
else
  export AE350_SDC="$here/top.sdc"
fi
# 実験用: TRACE=1 で ahb_sdram に転送の記録を入れる (= 本番のビルドには入れない)
if [ "${TRACE:-}" = 1 ]; then
  printf '`define AHB_SDRAM_TRACE\n' >> "$out/defines.v"
fi
export AE350_BOARD_BUILD=$out
# Hazard3 の版は、指定が無ければ配置の設定を 2 にする (= 2026-11-16。Hazard3 の中の遅い経路は 40 MHz に対する余裕がほとんど無く、
# CPU=hazard3 MEM=ddr3 では、既定と PLACE=1 で core_clk に違反が出て、PLACE=2 で消えた)
case "${CPU:-ae350}" in
  hazard3*) PLACE=${PLACE:-2} ;;
esac
export AE350_PLACE_OPTION=${PLACE:-}
export AE350_ROUTE_OPTION=${ROUTE:-}
export AE350_MEM=${MEM:-sdram}
case "$AE350_MEM" in
  sdram) ;;
  ddr3)
    [ "${SDRAM:-}" = hs ] && { echo "MEM=ddr3 と SDRAM=hs は一緒に使えない" >&2; exit 1; }
    printf '`define AE350_MEM_DDR3\n' >> "$out/defines.v"
    ;;
  litedram)
    [ "${SDRAM:-}" = hs ] && { echo "MEM=litedram と SDRAM=hs は一緒に使えない" >&2; exit 1; }
    printf '`define AE350_MEM_LITEDRAM\n' >> "$out/defines.v"
    ;;
  *) echo "MEM は sdram、ddr3、litedram のどれか" >&2; exit 1 ;;
esac
export AE350_CPU=${CPU:-ae350}
if [ "$AE350_CPU" = hazard3-fast ]; then
  AE350_CPU=hazard3
  printf '`define AE350_HAZARD3_FAST\n' >> "$out/defines.v"
fi
if [ "$AE350_CPU" = hazard3 ]; then
  printf '`define AE350_CPU_HAZARD3\n' >> "$out/defines.v"
  # ILM / DLM を Gowin の DPB で作る (= rtl/ae350_fabric.v の g_tcm。2 つのクロックで書く記憶を、合成が always から作れないため)
  printf '`define AE350_GOWIN_BSRAM\n' >> "$out/defines.v"
  ruby "$here/make_sdc_hazard3.rb" "$AE350_SDC" "$out/top_hazard3.sdc" || exit 1
  export AE350_SDC="$out/top_hazard3.sdc"
fi
if [ "$AE350_MEM" = ddr3 ]; then
  ruby "$here/make_sdc_ddr3.rb" "$AE350_SDC" "$out/top_ddr3.sdc" || exit 1
  export AE350_SDC="$out/top_ddr3.sdc"
fi
if [ "$AE350_MEM" = litedram ]; then
  # litedram/tang_console.yml の 1:2、システム 50 MHz (= DDR3 のクロック 100 MHz、周期 10 ns、制御 20 ns)
  ruby "$here/make_sdc_litedram.rb" "$AE350_SDC" "$out/top_litedram.sdc" 10 20 || exit 1
  export AE350_SDC="$out/top_litedram.sdc"
fi
# ピンと配置の制約は、出力先に 1 つにまとめて作る (= Gowin の合成は制約のファイルを 1 つしか使わず、後から足したものだけが
# 効く。2026-11-13、ddr3.cst だけが効いて clk50 と UART が別のピンに置かれた)。DDR3 の版は top.cst に ddr3/ddr3.cst を足す
cat "$here/top.cst" > "$out/top_build.cst" || exit 1
[ "$AE350_MEM" = ddr3 ] && cat "$here/ddr3/ddr3.cst" >> "$out/top_build.cst"
# LiteDRAM の版: litedram_gen で制御を出力先に書き出し、ROM の中身を絶対パスで読むように写す (= 書き出した Verilog は
# $readmemh を相対パスで書く)。Gowin のライブラリの環境変数 (= 下の DYLD_*) を設定する前に動かす
if [ "$AE350_MEM" = litedram ]; then
  venv=${LITEX_VENV:-}
  [ -n "$venv" ] && [ -x "$venv/bin/litedram_gen" ] || { echo "LITEX_VENV に、litedram_gen を入れた LiteX の仮想環境を指定する (= 作り方は README)" >&2; exit 1; }
  PATH="$venv/bin:$PATH" litedram_gen "$here/litedram/tang_console.yml" --output-dir "$out/litedram" > "$out/litedram_gen.log" 2>&1 ||
    { echo "litedram_gen が失敗した (= $out/litedram_gen.log)" >&2; exit 1; }
  g="$out/litedram/gateware"
  sed -e "s|readmemh(\"litedram_core_rom.init\"|readmemh(\"$g/litedram_core_rom.init\"|" \
      -e "s|readmemh(\"litedram_core_sram.init\"|readmemh(\"$g/litedram_core_sram.init\"|" "$g/litedram_core.v" > "$out/litedram_core.v"
  grep -q "$g/litedram_core_rom.init" "$out/litedram_core.v" || { echo "ROM の中身のパスを書き換えられなかった" >&2; exit 1; }
  AE350_VEXRISCV_V="$("$venv/bin/python" -c 'import pythondata_cpu_vexriscv as v; print(v.data_location)')/VexRiscv.v"   # data_location が verilog のフォルダ
  [ -f "$AE350_VEXRISCV_V" ] || { echo "VexRiscv.v が無い" >&2; exit 1; }
  export AE350_VEXRISCV_V
  cat "$here/litedram/ddram.cst" >> "$out/top_build.cst"
fi
case "$(uname)" in
  Darwin) export DYLD_LIBRARY_PATH=$G/lib DYLD_FRAMEWORK_PATH=$G/lib ;;
esac
# DDR3 の PLL の中身 (= gowin_pll_mod.v) は、Gowin の GowinModgen で ddr3/gowin_pll.mod から出力先に作る (= Gowin のツールが
# 作るファイルなのでリポジトリに入れない。2026-11-13)
if [ "$AE350_MEM" = ddr3 ]; then
  mkdir -p "$out/ddr3_pll"
  sed "s|^-path .*|-path $out/ddr3_pll/|" "$here/ddr3/gowin_pll.mod" > "$out/ddr3_pll/gowin_pll.mod"
  "$G/bin/GowinModgen" -do "$out/ddr3_pll/gowin_pll.mod" > "$out/ddr3_pll/modgen.log" 2>&1 || { cat "$out/ddr3_pll/modgen.log"; exit 1; }
  [ -f "$out/ddr3_pll/gowin_pll_mod.v" ] || { echo "DDR3 の PLL を作れなかった" >&2; exit 1; }
  [ -f "$here/ddr3/ddr3_memory_interface.v" ] || { echo "DDR3 の IP (= ddr3/ddr3_memory_interface.v) が無い。README.md の「DDR3 build」(= README.ja.md の「DDR3 の版」) の手順で作る" >&2; exit 1; }
fi
exec "$G/bin/gw_sh" "$here/build.tcl"
