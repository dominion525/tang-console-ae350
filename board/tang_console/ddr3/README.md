# DDR3 の版のファイルの出どころ

このディレクトリのファイルは、Sipeed の TangMega-138K-example (= https://github.com/sipeed/TangMega-138K-example) の `ddr_memory/ddr_memory_test_uart` (= Tang Console 138K で動いた DDR3 の試験) から来ている。ライセンスは Apache-2.0 (= リポジトリの LICENSE)。

    ファイル                    出どころ (= ddr_memory/ddr_memory_test_uart/ の下)
                                変更
    gowin_pll.v                 src/gowin_pll/gowin_pll.v
                                なし (= 冒頭に出どころの 2 行を足しただけ)
    pll_init.v                  src/pll_init.v
                                なし (= 冒頭に出どころの 2 行を足しただけ)
    ddr3.cst                    src/ddr3_1v4_hs.cst
                                DDR3 の行と INS_LOC の行を選んだ (= 行の中身は元のまま)
    ddr3_memory_interface.ipc   src/ddr3_memory_interface/ddr3_memory_interface.ipc
                                target_device を版 C (= gw5ast138c-007) から版 B (= gw5ast138b-011) に変えた。ほかに、キーの並びが
                                違い、AXI と MC の設定のキー (= 9 個) が無い
    gowin_pll.mod               src/gowin_pll/gowin_pll.mod
                                -device_version を C から B に、-path を元の絶対パスから ./ に変えた

`.ipc` と `.mod` は Gowin のツール (= IP Core Generator、GowinModgen) が読むファイルなので、出どころはファイルの中ではなく、ここに書く。

`.ipc` から作る `ddr3_memory_interface.v` (= Gowin の DDR3 の IP の本体) は、Gowin のツールが作るファイルなので、リポジトリには入れない。作り方は README.md の「DDR3 build」(= 日本語は README.ja.md の「DDR3 の版」)。
