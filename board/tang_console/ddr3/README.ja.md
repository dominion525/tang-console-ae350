# DDR3 版のファイルの出典

[English](README.md)

このディレクトリのファイルは、Sipeed の [TangMega-138K-example](https://github.com/sipeed/TangMega-138K-example) にある `ddr_memory/ddr_memory_test_uart`（Tang Console 138K で動作する DDR3 のテスト）から取り込んだものです。
ライセンスは Apache-2.0（リポジトリの LICENSE）です。

| ファイル                    | 出典（`ddr_memory/ddr_memory_test_uart/` からのパス） | 変更点                                                                                                                                                  |
| --------------------------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gowin_pll.v`               | `src/gowin_pll/gowin_pll.v`                           | 冒頭に出典の 2 行を足しただけで、ほかは元のまま                                                                                                         |
| `pll_init.v`                | `src/pll_init.v`                                      | 冒頭に出典の 2 行を足しただけで、ほかは元のまま                                                                                                         |
| `ddr3.cst`                  | `src/ddr3_1v4_hs.cst`                                 | DDR3 の行と INS_LOC の行だけを抜き出した（各行の内容は元のまま）                                                                                        |
| `ddr3_memory_interface.ipc` | `src/ddr3_memory_interface/ddr3_memory_interface.ipc` | `target_device` をリビジョン C（`gw5ast138c-007`）からリビジョン B（`gw5ast138b-011`）に変えた。キーの並び順が異なり、AXI と MC の設定のキー 9 個がない |
| `gowin_pll.mod`             | `src/gowin_pll/gowin_pll.mod`                         | `-device_version` を C から B に、`-path` を元の絶対パスから `./` に変えた                                                                              |

`.ipc` と `.mod` は Gowin のツール（IP Core Generator と GowinModgen）が読み込むファイルなので、出典はファイルの中ではなくこの README に書いています。

`.ipc` から生成する `ddr3_memory_interface.v`（Gowin の DDR3 IP の本体）は、Gowin のツールが生成するファイルなので、リポジトリには含めていません。
生成手順は、リポジトリのトップの [README.ja.md](../../../README.ja.md) の「DDR3 版」にあります。
