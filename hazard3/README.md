# Hazard3 (vendored)

[日本語](README.ja.md)

This is the CPU used inside the AE350 Hazard3 version (`rtl/AE350_SOC.v`).
It is used in simulation and in the Hazard3 version running in the FPGA fabric (`CPU=hazard3`), and is not part of the builds that use the real AE350.

| Item           | Details                                     |
| -------------- | ------------------------------------------- |
| Origin         | https://github.com/Wren6991/Hazard3         |
| Version        | v1.1.1 (commit 8af9929)                     |
| License        | Apache-2.0 (LICENSE in this directory)      |
| Files included | `hdl/` (except `hdl/arith/muldiv_model.py`) |

## Changes from upstream

The following changes make it behave like the AE350 CPU (Andes A25).
Each changed line carries a comment starting with `ae350:`.

| File                         | Change                                                                             | Reason                                                                                                                                       |
| ---------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `hdl/hazard3_csr.v`          | The reset value of mcountinhibit is 0 (upstream it is 1, which stops the counters) | Gowin's BSP (delay.c) measures time with mcycle without setting mcountinhibit, assuming that mcycle and minstret on the A25 count from reset |
| `hdl/hazard3_config.vh`      | Added the parameters MARCHID_VAL, MIMPID_OVERRIDE, and MIMPID_VAL                  | To return the same marchid and mimpid as the A25 in AE350. The defaults are the upstream values                                              |
| `hdl/hazard3_config_inst.vh` | Passes the three parameters above                                                  | Same as above                                                                                                                                |
| `hdl/hazard3_csr.v`          | marchid and mimpid are returned from the parameters above                          | Same as above                                                                                                                                |

To compare with upstream, run `git diff --no-index <upstream hdl> hazard3/hdl`.
