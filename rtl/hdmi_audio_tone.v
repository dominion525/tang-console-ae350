// =============================================================
// File:        rtl/hdmi_audio_tone.v
// Module:      hdmi_audio_tone
// Role:        HDMI の出力回路 (rtl/vendor/hdmi/hdmi.sv) に渡す、音声のサンプリングの合図 (clk_audio) と試験音。
//              試験音は TONE_HZ の矩形波で、振幅は AMPLITUDE (16 ビットの符号付き)。左右に同じ値を渡す。
//
//   - 画素クロック (CLK_HZ) はサンプリング周波数 (RATE) で割り切れない (74.25 MHz ÷ 48 kHz = 1546.875) ので、
//     累算器に毎クロック RATE を足し、CLK_HZ を超えたら CLK_HZ を引いてサンプルを 1 つ進める。サンプルの間隔は
//     1546 か 1547 クロックになり、平均は RATE と一致する
//   - clk_audio は、サンプルを進めるクロックで 1 クロックだけ 1 になる。hdmi.sv (rtl/vendor/hdmi/packet_picker.sv の ae350: の変更) は clk_audio を
//     クロックとして使わず、画素クロックで立ち上がりを検出するので、clk_audio は画素クロックに同期していればよい
//   - sample は clk_audio と同じクロックで次の値に変わる。hdmi.sv は、clk_audio が 1 になった次のクロックで立ち上がりを検出して
//     sample を取り込むので、変わった後の値を取り込む (間隔は変わらない)
//
// Ports:
//   input  wire               clk        画素クロック
//   input  wire               reset      同期リセット (1 の間、累算器と波形を最初に戻す。hdmi.sv の reset と同じ向き)
//   output reg                clk_audio  サンプリングの合図
//   output reg signed [15:0]  sample     試験音のサンプル
//
// Parameters:
//   CLK_HZ     画素クロックの周波数 (Hz)
//   RATE       サンプリング周波数 (Hz)
//   TONE_HZ    試験音の周波数 (Hz。RATE ÷ TONE_HZ が偶数になる値)
//   AMPLITUDE  試験音の振幅 (既定値 2048 は、16 ビットの最大値の約 1/16)
//
// Clock:       clk
// Reset:       reset (同期、1 でリセット)
// =============================================================

`default_nettype none

module hdmi_audio_tone #(
    parameter integer CLK_HZ    = 74250000,
    parameter integer RATE      = 48000,
    parameter integer TONE_HZ   = 1000,
    parameter integer AMPLITUDE = 2048
) (
    input  wire              clk,
    input  wire              reset,
    output reg               clk_audio,
    output reg signed [15:0] sample
);
    localparam integer HALF = RATE / TONE_HZ / 2;   // 矩形波の半周期のサンプル数
    localparam integer AW   = $clog2(CLK_HZ + RATE);
    localparam integer PW   = $clog2(HALF * 2);
    localparam [AW-1:0] CLK_HZ_C = CLK_HZ[AW-1:0];
    localparam [AW-1:0] RATE_C   = RATE[AW-1:0];
    localparam [PW-1:0] HALF_C   = HALF[PW-1:0];
    localparam signed [15:0] AMP_C = AMPLITUDE[15:0];

    reg [AW-1:0] acc;
    reg [PW-1:0] phase;   // 半周期の中のサンプルの番号
    wire [AW-1:0] acc_next = acc + RATE_C;
    wire          tick     = acc_next >= CLK_HZ_C;

    always @(posedge clk) begin
        if (reset) begin
            acc       <= {AW{1'b0}};
            phase     <= {PW{1'b0}};
            clk_audio <= 1'b0;
            sample    <= AMP_C;
        end else begin
            acc       <= tick ? acc_next - CLK_HZ_C : acc_next;
            clk_audio <= tick;
            if (tick) begin
                if (phase == HALF_C - 1'b1) begin
                    phase  <= {PW{1'b0}};
                    sample <= -sample;
                end else begin
                    phase  <= phase + 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
