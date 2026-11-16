// =============================================================
// File:        ae350/tb/sdram_pll_tb.v
// Module:      sdram_pll_tb
// Role:        sdram_pll (= 166.7 MHz 版の SDRAM の制御のクロック) を、Gowin の PLL のモデルで確かめる TB (= 2026-11-11)。
//              Gowin のモデルは iverilog で動かす (= Lapidary の cores/ddr3/simulation と同じ。モデルは
//              cores/ddr3/simulation/prim_sim_gw5a.rb が直したものを使う)。破れたら $fatal で止まる。
//
//   1  lock が立つ
//   2  s_clk の周期が 6.0 ns (= 166.7 MHz) で、High の長さが 3.0 ns
//
// 実行: make -C ae350 test-sdram-pll
// =============================================================

`timescale 1ps / 1ps

module sdram_pll_tb;

    reg clk50 = 1'b0;
    always #10000 clk50 = ~clk50;          // 50 MHz

    reg pll_rst = 1'b1;

    wire s_clk, lock;
    sdram_pll u_pll (.clkin (clk50), .reset (pll_rst), .s_clk (s_clk), .lock (lock));

    time t_rise, t_fall, period, high;
    always @(posedge s_clk) begin period = $time - t_rise; t_rise = $time; end
    always @(negedge s_clk) begin high = $time - t_rise; t_fall = $time; end

    initial begin
        #200000;
        pll_rst = 1'b0;
        wait (lock);
        $display("1 lock: 合格 (%0t)", $time);
        repeat (20) @(posedge s_clk);
        @(negedge s_clk);
        if (period != 6000 || high != 3000) $fatal(1, "2: 周期 %0d ps、High %0d ps", period, high);
        $display("2 周期 6.0 ns、High 3.0 ns: 合格");
        $display("sdram_pll_tb: 合格");
        $finish;
    end

endmodule
