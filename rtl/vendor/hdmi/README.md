# hdmi (vendored)

[日本語](README.ja.md)

HDMI 1.4b video and audio output (TMDS encoding, data island packets, and serializer), written in SystemVerilog.
This is code by another author, with some changes for use on this board (see "Changes from upstream" below).

| Item           | Details                                                                                        |
| -------------- | ---------------------------------------------------------------------------------------------- |
| Origin         | https://github.com/hdl-util/hdmi                                                               |
| Commit         | 517e214 (2026-11-10; the latest commit in the original repository at the time it was included) |
| Files included | the 10 files in `src/` (`*.sv`), `LICENSE-MIT`, `LICENSE-APACHE`                               |
| License        | MIT or Apache-2.0, at your option (text in LICENSE-MIT and LICENSE-APACHE)                     |

**The repository's LICENSE (Apache-2.0) does not apply to the code in this directory.**
The code in this directory is covered by the terms in LICENSE-MIT or LICENSE-APACHE.

## Changes from upstream

Changed lines carry a comment starting with `ae350:`.

| File                                 | Change                                                                                                             | Reason                                                                                                                                                                        |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `audio_clock_regeneration_packet.sv` | `clk_audio` is no longer used as a clock; the logic runs on `clk_pixel` and detects the rising edge of `clk_audio` | `clk_audio` (48 kHz) cannot come from a PLL and is made from a counter on `clk_pixel`; a fabric-made signal is not used as a clock                                            |
| `packet_picker.sv`                   | Same as above                                                                                                      | Same as above                                                                                                                                                                 |
| `audio_clock_regeneration_packet.sv` | In the initial value of `CYCLE_TIME_STAMP_COUNTER_IDEAL`, `VIDEO_RATE * int'(N)` is changed to `VIDEO_RATE * N`    | Verilator 5.052 cannot evaluate an `int'()` inside a real-valued expression as a constant and stops with an error. `N` is a positive 20-bit value, so the result is unchanged |
| `serializer.sv`                      | On Gowin, the TMDS clock is also sent through `OSER10` as `10'b0000011111` (upstream drives `clk_pixel` directly)  | To send the clock through the same path as the three data lanes                                                                                                               |

With this change, `clk_audio` must be synchronous to `clk_pixel`.

## Lint

Verilator warnings are suppressed in `tools/lint.vlt` for the files in this directory only.
