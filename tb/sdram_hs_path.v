// =============================================================
// File:        ae350/tb/sdram_hs_path.v
// Module:      sdram_hs_path
// Role:        シミュレーション用の、SDRAM の制御の 166.7 MHz 版の経路 (= 2026-11-11)。
//              sdram_ctrl_hs → sdram_io (= TB 用の Gowin の IO の部品) → ボードの遅れ → SDRAM のモデル。
//              上の側の口は sdram_bridge と同じなので、TB は sdram_bridge + SDRAM のモデルの代わりに置ける。
//
//   ボードの遅れ (= パラメータ BOARD_PS、既定 0。TB では定義 SDRAM_BOARD_PS で渡す): FPGA のピンと SDRAM の間の片道の遅れ。命令、番地、クロックは行きに、
//   DQ は書くときは行きに、読むときは帰りにかかる (= 読んだ語は、c_clk から見て 2 倍遅れて届く)
//
// Ports:
//   input  wire s_clk / rst_n
//   上の側の口 (= sdram_bridge と同じ)
// =============================================================

`timescale 1ns / 1ps

module sdram_hs_path #(
    parameter integer ADDR_WIDTH = 25,
    parameter integer RD_FIRST   = 11,
    parameter integer BOARD_PS   = 0,
    parameter integer IN_DLY     = 160,
    parameter integer CAP_EDGE   = 0
) (
    input  wire                  s_clk,
    input  wire                  rst_n,
    input  wire                  fill_valid,
    input  wire [ADDR_WIDTH-5:0] fill_line,
    output wire                  fill_ready,
    output wire [127:0]          fill_data,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [7:0]            wdata,
    output wire                  wready,
    output wire                  init_done
);
    wire [3:0]  io_cmd;
    wire [12:0] io_addr;
    wire [1:0]  io_ba, io_dqm;
    wire [15:0] io_dq_out, io_dq_in;
    wire        io_dq_oe;

    sdram_ctrl_hs #(.ADDR_WIDTH (ADDR_WIDTH), .RD_FIRST (RD_FIRST)) u_ctrl (
        .clk (s_clk), .rst_n (rst_n), .fill_valid (fill_valid), .fill_line (fill_line), .fill_ready (fill_ready),
        .fill_data (fill_data), .we (we), .waddr (waddr), .wdata (wdata), .wready (wready), .init_done (init_done),
        .io_cmd (io_cmd), .io_addr (io_addr), .io_ba (io_ba), .io_dqm (io_dqm), .io_dq_out (io_dq_out),
        .io_dq_oe (io_dq_oe), .io_dq_in (io_dq_in)
    );

    // FPGA のピン
    wire [15:0] f_dq;
    wire [12:0] f_a;
    wire [1:0]  f_ba, f_dqm;
    wire        f_clk, f_cs_n, f_ras_n, f_cas_n, f_we_n;

    sdram_io #(.IN_DLY (IN_DLY), .CAP_EDGE (CAP_EDGE)) u_io (
        .s_clk (s_clk), .cmd (io_cmd), .addr (io_addr), .ba (io_ba), .dqm (io_dqm),
        .dq_out (io_dq_out), .dq_oe (io_dq_oe), .dq_in (io_dq_in),
        .sdram_dq (f_dq), .sdram_addr (f_a), .sdram_ba (f_ba), .sdram_clk (f_clk), .sdram_cs_n (f_cs_n),
        .sdram_ras_n (f_ras_n), .sdram_cas_n (f_cas_n), .sdram_we_n (f_we_n), .sdram_dqm (f_dqm)
    );

    // ---------------------------------------------------------
    // ボードの遅れ (= 遅れつきの連続代入。DQ は出している側の値を、遅れてもう一方へ渡す)
    // ---------------------------------------------------------
    localparam real BD = BOARD_PS / 1000.0;

    wire [12:0] m_a;
    wire [1:0]  m_ba, m_dqm;
    wire        m_clk, m_cs_n, m_ras_n, m_cas_n, m_we_n;
    wire [15:0] m_dq;
    wire [15:0] fpga_q  = u_io.dq_q;             // FPGA が出す値 (= IOBUF の I)
    wire        f_drive = !u_io.dq_oen[0];       // FPGA が DQ を出している (= IOBUF の OEN が 0)
    wire [15:0] to_m, to_f;
    wire        to_m_en, to_f_en;

    // 遅れが 0 のときは遅れなしで代入する (= 遅れ 0 の代入は、--no-sched-zero-delay と合わない)
    generate
        if (BOARD_PS == 0) begin : no_delay
            assign {m_a, m_ba, m_dqm, m_clk, m_cs_n, m_ras_n, m_cas_n, m_we_n} =
                   {f_a, f_ba, f_dqm, f_clk, f_cs_n, f_ras_n, f_cas_n, f_we_n};
            assign to_m    = fpga_q;
            assign to_m_en = f_drive;
            assign to_f    = u_model.dq_out;
            assign to_f_en = u_model.dq_oe;
        end else begin : delay
            assign #(BD) {m_a, m_ba, m_dqm, m_clk, m_cs_n, m_ras_n, m_cas_n, m_we_n} =
                         {f_a, f_ba, f_dqm, f_clk, f_cs_n, f_ras_n, f_cas_n, f_we_n};
            assign #(BD) to_m    = fpga_q;
            assign #(BD) to_m_en = f_drive;
            assign #(BD) to_f    = u_model.dq_out;
            assign #(BD) to_f_en = u_model.dq_oe;
        end
    endgenerate
    assign m_dq = to_m_en ? to_m : 16'hzzzz;
    assign f_dq = to_f_en ? to_f : 16'hzzzz;

    sdram_model u_model (
        .clk (m_clk), .cke (1'b1), .csn (m_cs_n), .rasn (m_ras_n), .casn (m_cas_n), .wen (m_we_n), .dqm (m_dqm),
        .ba (m_ba), .addr (m_a), .dq (m_dq)
    );

endmodule
