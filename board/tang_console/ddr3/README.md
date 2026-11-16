# DDR3 の版のファイルの出どころ

このディレクトリのファイルは、Sipeed の TangMega-138K-example (= https://github.com/sipeed/TangMega-138K-example) の `ddr_memory/ddr_memory_test_uart` (= Tang Console 138K で動いた DDR3 の試験) から来ている。ライセンスは Apache-2.0 (= リポジトリの LICENSE)。

    ファイル                       出どころ                                         変更
    gowin_pll.v                    src/gowin_pll/gowin_pll.v                         なし
    pll_init.v                     src/pll_init.v                                    なし
    ddr3.cst                       src/ddr3_1v4_hs.cst の DDR3 の行と INS_LOC の行       行を選んだだけ (= 中身は元のまま)
    ddr3_memory_interface.ipc      DDR3 の IP の設定                                  チップの版 B (= gw5ast138b-011) 向けに作った
    gowin_pll.mod                  DDR3 の PLL の設定                                 チップの版 B 向けに作った

`.ipc` と `.mod` は Gowin のツール (= IP Core Generator、GowinModgen) が読むファイルなので、出どころはファイルの中ではなく、ここに書く。

`.ipc` から作る `ddr3_memory_interface.v` (= Gowin の DDR3 の IP の本体) は、Gowin のツールが作るファイルなので、リポジトリには入れない。作り方は README の「DDR3 の版」。
