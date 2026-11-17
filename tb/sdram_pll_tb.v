// =============================================================
// File:        tb/sdram_pll_tb.v
// Module:      sdram_pll_tb
// Role:        sdram_pll (166.7 MHz 版の SDRAM コントローラのクロック) を、Gowin の PLL のモデルで確かめるテストベンチ。
//              Gowin のモデルは iverilog で動かす (tools/prim_sim_gw5a.rb で修正したモデルを使う)。
//              期待と違えば $fatal で止まる。
//
//   1  lock が 1 になる
//   2  s_clk の周期が 6.0 ns (166.7 MHz) で、High の期間が 3.0 ns
//
// 実行: make test-sdram-pll
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
        $display("1 lock: PASS (%0t)", $time);
        repeat (20) @(posedge s_clk);
        @(negedge s_clk);
        if (period != 6000 || high != 3000) $fatal(1, "2: period %0d ps, high %0d ps", period, high);
        $display("2 period 6.0 ns, high 3.0 ns: PASS");
        $display("sdram_pll_tb: PASS");
        $finish;
    end

endmodule
