# Hazard3（取り込んだもの）

[English](README.md)

RISC-V の CPU コア Hazard3 です。
AE350 の Hazard3 版（`rtl/AE350_SOC.v`）の内部で CPU として使います。
シミュレーションと、FPGA のファブリック上で動かす Hazard3 版（`CPU=hazard3`）で使い、本物の AE350 を使う構成には含まれません。

| 項目           | 内容                                         |
| -------------- | -------------------------------------------- |
| 出典           | https://github.com/Wren6991/Hazard3          |
| バージョン     | v1.1.1（コミット 8af9929）                   |
| ライセンス     | Apache-2.0（同じディレクトリの LICENSE）     |
| 取り込んだ範囲 | `hdl/`（`hdl/arith/muldiv_model.py` を除く） |

## 上流からの変更点

AE350 の CPU（Andes A25）と同じ動作にするために、次の箇所を変えています。
変えた行には `ae350:` で始まるコメントを付けています。

| ファイル                     | 変更内容                                                                 | 理由                                                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `hdl/hazard3_csr.v`          | mcountinhibit の初期値を 0 にした（上流は 1 で、カウンタが止まった状態） | Gowin の BSP（delay.c）は、A25 では mcycle と minstret がリセット直後から進むことを前提に、mcountinhibit を設定せずに mcycle で時間を計るため |
| `hdl/hazard3_config.vh`      | パラメータ MARCHID_VAL、MIMPID_OVERRIDE、MIMPID_VAL を追加した           | AE350 の A25 と同じ marchid と mimpid を返すため。既定値は上流と同じ                                                                          |
| `hdl/hazard3_config_inst.vh` | 上の 3 つのパラメータを渡すようにした                                    | 同上                                                                                                                                          |
| `hdl/hazard3_csr.v`          | marchid と mimpid を、上のパラメータから返すようにした                   | 同上                                                                                                                                          |

上流との差分は `git diff --no-index <上流の hdl> hazard3/hdl` で確認できます。
