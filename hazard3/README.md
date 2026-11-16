# Hazard3 (コピー)

AE350 のシミュレーション用モック (`rtl/AE350_SOC.v`) の中で CPU として使う。
実機には載らない。

- 出どころ: https://github.com/Wren6991/Hazard3
- 版: v1.1.1 (コミット 8af9929)
- ライセンス: Apache-2.0 (= 同じディレクトリの LICENSE)
- コピーしたもの: `hdl/` (`hdl/arith/muldiv_model.py` を除く)

## 上流から変えた箇所

AE350 の CPU (Andes A25) と同じ挙動にするために変えた。変えた行には `ae350:` で始まるコメントを付けてある。

```
ファイル                  変えたこと                                            理由
hdl/hazard3_csr.v        mcountinhibit の初期値を 0 にした (= 上流は 1。カウンタを止めた状態)    Gowin の BSP (delay.c) は mcountinhibit に触れずに mcycle で時間を測る。
                                                                             A25 はリセット直後から mcycle / minstret が進む前提 (2026-11-10)
hdl/hazard3_config.vh    パラメータ MARCHID_VAL / MIMPID_OVERRIDE / MIMPID_VAL を足した        AE350 の A25 と同じ marchid / mimpid を返すため。既定は上流と同じ値 (2026-11-10)
hdl/hazard3_config_inst.vh  上の 3 つを渡す
hdl/hazard3_csr.v        marchid と mimpid を、上のパラメータから返すようにした
```

上流と比べるときは `git diff --no-index <上流の hdl> hazard3/hdl` で確かめる。
