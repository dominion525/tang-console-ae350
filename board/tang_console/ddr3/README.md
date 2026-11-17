# Origin of the DDR3 build files

[日本語](README.ja.md)

The files in this directory are taken from `ddr_memory/ddr_memory_test_uart` (a DDR3 test that runs on the Tang Console 138K) in Sipeed's [TangMega-138K-example](https://github.com/sipeed/TangMega-138K-example).
They are licensed under Apache-2.0 (the repository's LICENSE).

| File                        | Origin (path under `ddr_memory/ddr_memory_test_uart/`) | Changes                                                                                                                                                                        |
| --------------------------- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `gowin_pll.v`               | `src/gowin_pll/gowin_pll.v`                            | Only two lines stating the origin were added at the top                                                                                                                        |
| `pll_init.v`                | `src/pll_init.v`                                       | Only two lines stating the origin were added at the top                                                                                                                        |
| `ddr3.cst`                  | `src/ddr3_1v4_hs.cst`                                  | Only the DDR3 lines and the INS_LOC lines were kept (each line is unchanged)                                                                                                   |
| `ddr3_memory_interface.ipc` | `src/ddr3_memory_interface/ddr3_memory_interface.ipc`  | `target_device` was changed from revision C (`gw5ast138c-007`) to revision B (`gw5ast138b-011`). The key order also differs, and 9 keys for the AXI and MC settings are absent |
| `gowin_pll.mod`             | `src/gowin_pll/gowin_pll.mod`                          | `-device_version` was changed from C to B, and `-path` from the original absolute path to `./`                                                                                 |

The `.ipc` and `.mod` files are read by Gowin's tools (IP Core Generator and GowinModgen), so their origin is recorded in this README rather than in the files themselves.

`ddr3_memory_interface.v` (the Gowin DDR3 IP itself), generated from the `.ipc` file, is produced by Gowin's tools and is not included in the repository.
The generation steps are in the "DDR3 build" section of the top-level [README.md](../../../README.md).
