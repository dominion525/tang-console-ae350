// =============================================================
// File:        tb/sram_tb.v
// Module:      sram_tb
// Role:        ahb_sram (= EXTS_H* の先に置く FPGA 側の RAM) の単体の TB (= 段 5、2026-11-10)。
//              モックの中央のバスは転送を 1 つずつ出すので、AHB のパイプライン (= 前の転送のデータフェーズと、次の
//              転送のアドレスフェーズが重なる) は通らない。ここでは重ねて出し、次の 2 つを確かめる。
//                - 書いた直後に同じ word を読むと、書いた値が返る (= ブロック RAM の読み出しの前に書き込みを渡す)
//                - 書き込み → 読み出し → 書き込みを重ねても、それぞれの値が正しい
//              待ち (= WAIT 1) の構成と、待たない構成 (= WAIT 0) の両方で流す。破れたら $fatal で止まる。
//
// 実行: make test-sram
// =============================================================

`default_nettype none

module sram_tb;

    reg clk;
    reg rst_n;

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
    end

    always #5 clk = ~clk;

    // 2 つの構成 (= バスの信号は共有し、hsel で選ぶ)
    reg  [31:0] haddr;
    reg  [1:0]  htrans;
    reg         hwrite;
    reg  [2:0]  hsize;
    reg  [31:0] hwdata;
    reg         sel;          // 0 = 待たない、1 = 待ちが 1 サイクル
    wire [31:0] hrdata0, hrdata1;
    wire        hreadyout0, hreadyout1;
    wire        hresp0, hresp1;

    wire        hready = sel ? hreadyout1 : hreadyout0;
    wire [31:0] hrdata = sel ? hrdata1    : hrdata0;
    wire        hresp  = sel ? hresp1     : hresp0;

    ahb_sram #(.WORDS(256), .WAIT(0)) u_w0 (
        .hclk(clk), .hresetn(rst_n), .hsel(!sel), .hready(hready), .haddr(haddr), .htrans(htrans),
        .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata), .hrdata(hrdata0), .hreadyout(hreadyout0), .hresp(hresp0)
    );

    ahb_sram #(.WORDS(256), .WAIT(1)) u_w1 (
        .hclk(clk), .hresetn(rst_n), .hsel(sel), .hready(hready), .haddr(haddr), .htrans(htrans),
        .hwrite(hwrite), .hsize(hsize), .hwdata(hwdata), .hrdata(hrdata1), .hreadyout(hreadyout1), .hresp(hresp1)
    );

    // 重ねた転送の並び: 1 つ目のアドレスフェーズ → (1 つ目のデータフェーズ = 2 つ目のアドレスフェーズ) → …
    // 各転送は {書くか, アドレス, HSIZE, 書く値 / 期待する値}
    localparam integer N = 6;
    reg [31:0] t_addr  [0:N-1];
    reg        t_write [0:N-1];
    reg [2:0]  t_size  [0:N-1];
    reg [31:0] t_data  [0:N-1];

    integer i;
    integer cfg;

    task run_pipeline;
        begin
            // 1 つ目のアドレスフェーズ
            @(posedge clk);
            haddr  <= t_addr[0];
            hwrite <= t_write[0];
            hsize  <= t_size[0];
            htrans <= 2'b10;
            for (i = 0; i < N; i = i + 1) begin
                // HREADY = 1 の端で、i 番目のアドレスフェーズが受け付けられる
                @(posedge clk);
                while (!hready) @(posedge clk);
                if (i > 0 && !t_write[i-1] && hrdata !== t_data[i-1]) begin
                    $fatal(1, "構成 %0d: %0d 番目の読み出し (0x%08x) が 0x%08x、期待は 0x%08x", cfg, i - 1, t_addr[i-1], hrdata, t_data[i-1]);
                end
                if (i > 0 && hresp) $fatal(1, "構成 %0d: %0d 番目がエラー応答", cfg, i - 1);
                // i 番目のデータフェーズ (= i + 1 番目のアドレスフェーズを重ねる)
                hwdata <= t_write[i] ? t_data[i] : 32'd0;
                if (i + 1 < N) begin
                    haddr  <= t_addr[i+1];
                    hwrite <= t_write[i+1];
                    hsize  <= t_size[i+1];
                    htrans <= 2'b10;
                end else begin
                    htrans <= 2'b00;
                end
            end
            // 最後の転送のデータフェーズの終わり
            @(posedge clk);
            while (!hready) @(posedge clk);
            if (!t_write[N-1] && hrdata !== t_data[N-1]) begin
                $fatal(1, "構成 %0d: 最後の読み出しが 0x%08x、期待は 0x%08x", cfg, hrdata, t_data[N-1]);
            end
        end
    endtask

    initial begin
        haddr = 32'd0; htrans = 2'b00; hwrite = 1'b0; hsize = 3'd2; hwdata = 32'd0; sel = 1'b0;
        // 書いた直後に同じ word を読む、を重ねる
        t_addr[0] = 32'hE800_0010; t_write[0] = 1'b1; t_size[0] = 3'd2; t_data[0] = 32'h1122_3344;
        t_addr[1] = 32'hE800_0010; t_write[1] = 1'b0; t_size[1] = 3'd2; t_data[1] = 32'h1122_3344;   // 書いた直後
        t_addr[2] = 32'hE800_0011; t_write[2] = 1'b1; t_size[2] = 3'd0; t_data[2] = 32'h0000_AA00;   // 1 byte
        t_addr[3] = 32'hE800_0010; t_write[3] = 1'b0; t_size[3] = 3'd2; t_data[3] = 32'h1122_AA44;   // 合わせた値
        t_addr[4] = 32'hE800_0014; t_write[4] = 1'b1; t_size[4] = 3'd2; t_data[4] = 32'h5566_7788;
        t_addr[5] = 32'hE800_0010; t_write[5] = 1'b0; t_size[5] = 3'd2; t_data[5] = 32'h1122_AA44;   // 別の word の後
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        for (cfg = 0; cfg < 2; cfg = cfg + 1) begin
            sel = cfg[0];
            run_pipeline();
        end
        $display("sram_tb: 合格");
        $finish;
    end

endmodule

`default_nettype wire
