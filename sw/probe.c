/*
 * 実機の値を読むプログラム (board/tang_console/ の構成で動かす)。
 *
 * Hazard3 版を作るときに資料だけでは決めきれなかった値と、本物の AE350 の仕様を読み出し、UART に 1 行ずつ出力する。
 * 読むと例外になるもの (存在しない CSR、エラー応答を返すアドレス) は、mcause を「exception」として出力する。
 * 出力し終わった後、UART に何か 1 文字送ると、もう一度出力する。
 *
 * 行の形式: <名前> <値 (16 進 8 桁)>   か   <名前> exception <mcause>
 *
 * Hazard3 版でも実行できる (make run-probe)。そのときは最後に DDR の 0x0000_0000 に 0x600D を書き込み、
 * テストベンチを止める (実機の DDR_H* の先には何もないので、書き込んでも何も起きない)。
 */

#include <stdint.h>
#include "uart.h"
#include "trap.h"

static void put_str(const char *s)
{
    while (*s) uart_putc(*s++);
}

static void put_hex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4) uart_putc("0123456789abcdef"[(v >> i) & 15u]);
}

static void put_line(const char *name, uint32_t v)
{
    put_str(name);
    if (trap_cause != 0) {
        put_str(" exception ");
        put_hex(trap_cause);
    } else {
        put_str(" ");
        put_hex(v);
    }
    put_str("\r\n");
}

/* CSR を読む。存在しない CSR は例外になり、sw/trap.c が次の命令から再開する (csrr は常に 4 バイト) */
#define READ_CSR(num) ({                                              \
    uint32_t v_;                                                      \
    trap_cause = 0;                                                   \
    __asm__ volatile("li %0, 0\n\tcsrr %0, " #num : "=&r"(v_) : : "memory"); \
    v_;                                                               \
})

#define CSR_LINE(name, num) put_line(name, READ_CSR(num))

/* CSR のビットを 1 にする、0 にする。存在しない CSR (Hazard3) は例外になり、次の命令から再開する */
#define SET_CSR(num, bits) __asm__ volatile("csrs " #num ", %0" : : "r"(bits) : "memory")
#define CLEAR_CSR(num, bits) __asm__ volatile("csrc " #num ", %0" : : "r"(bits) : "memory")

/*
 * 命令キャッシュとデータキャッシュを有効にする (mcache_ctl、0x7CA)。N25F のキャッシュは電源投入直後は無効で、起動時の
 * プログラムが有効にする。値は Gowin の BSP (ae350_coremark/ae350.c の __platform_init) と同じ: 命令キャッシュとデータキャッシュ
 * (bit 0 と 1)、命令とデータのプリフェッチ (bit 9 と 10)、データの write-around (bit 13〜14 を 1)、コヒーレンシ (bit 19)。
 * コヒーレンシを使うときは、有効になる (bit 20) まで待つ
 */
#define MCACHE_DC_EN 0x2u
static void cache_enable(void)
{
    CLEAR_CSR(0x7CA, 3u << 13);
    SET_CSR(0x7CA, (1u << 19) | (1u << 13) | (1u << 10) | (1u << 9) | MCACHE_DC_EN | 1u);
    if (READ_CSR(0x7CA) & (1u << 19)) {
        while ((READ_CSR(0x7CA) & (1u << 20)) == 0) {
        }
    }
    trap_cause = 0;
}

static uint32_t read_mem(uintptr_t addr)
{
    trap_cause = 0;
    return load_word_4byte(addr);
}

static void mem_line(const char *name, uintptr_t addr)
{
    put_line(name, read_mem(addr));
}

/* すべて 1 を書き込んで読み返し、元の値に戻す (書き込めるビットを調べる)。書き込めないアドレスは例外を出す */
static void wb_line(const char *name, uintptr_t addr)
{
    uint32_t before = read_mem(addr);
    if (trap_cause != 0) {
        put_line(name, 0);
        return;
    }
    store_word_4byte(addr, 0xFFFFFFFFu);
    uint32_t after = read_mem(addr);
    uint32_t cause = trap_cause;
    store_word_4byte(addr, before);
    trap_cause = cause;
    put_line(name, after);
}

static void store_byte(uintptr_t addr, uint8_t v)
{
    *(volatile uint8_t *)addr = v;
}

#define PLIC        0xE4000000u
#define PLIC_PRIO(id) (PLIC + 4u * (id))
#define PLIC_PEND   (PLIC + 0x1000u)
#define PLIC_EN0    (PLIC + 0x2000u)
#define PLIC_EN1    (PLIC + 0x2080u)
#define PLIC_TH0    (PLIC + 0x200000u)
#define PLIC_CL0    (PLIC + 0x200004u)
#define PLIC_PPS0   (PLIC + 0x200400u)
#define PLIC_TH1    (PLIC + 0x201000u)
#define PLIC_CL1    (PLIC + 0x201004u)
#define GPINT       0xF8001000u

static void w32(uintptr_t a, uint32_t v) { store_word_4byte(a, v); }
static uint32_t r32(uintptr_t a) { return load_word_4byte(a); }
static void settle(void) { for (volatile int i = 0; i < 200; i = i + 1) { } }

static void put_num(const char *name, uint32_t v) { trap_cause = 0; put_line(name, v); }

/* 割り込みは CPU に通さない (mie は 0 のまま)。PLIC のレジスタだけで動作を調べる */
static void plic_behavior(void)
{
    put_str("-- PLIC behavior\r\n");
    trap_cause = 0;
    w32(PLIC_EN0, 0); w32(PLIC_EN1, 0); w32(PLIC_TH0, 0); w32(PLIC_TH1, 0);
    for (uint32_t id = 1; id < 32; id = id + 1) w32(PLIC_PRIO(id), 1);

    /* 0. pending を空にする (前の「書き込めるビット」の確認で、すべて 1 になっている。pending は claim でしかクリアできない) */
    w32(PLIC_EN0, 0xFFFFFFFEu);
    for (int n = 0; n < 40; n = n + 1) {
        uint32_t c = r32(PLIC_CL0);
        if (c == 0) break;
        w32(PLIC_CL0, c);
    }
    put_num("pending after clearing", r32(PLIC_PEND));

    /* 1. GP_INT の 16 本がどのソースか (1 にして pending を読み、0 に戻してから claim と complete で片付ける) */
    uint32_t gp0_src = 0;
    for (uint32_t i = 0; i < 16; i = i + 1) {
        w32(GPINT, 1u << i);
        settle();
        uint32_t pend = r32(PLIC_PEND);
        w32(GPINT, 0);
        uint32_t id = r32(PLIC_CL0);
        w32(PLIC_CL0, id);
        if (i == 0) gp0_src = id;
        put_str("gp");
        uart_putc((char)("0123456789abcdef"[i]));
        put_num(" pending", pend);
        put_num("    claim", id);
    }
    put_num("pending after cleanup", r32(PLIC_PEND));

    /* 2. レベルの再通知: GP0 を 1 にしたまま claim と complete を行い、また pending になるか */
    w32(GPINT, 1);
    settle();
    uint32_t id = r32(PLIC_CL0);
    put_num("claim with gp0 held high", id);
    put_num("  pending right after claim", r32(PLIC_PEND));
    w32(PLIC_CL0, id);
    settle();
    put_num("  pending after complete", r32(PLIC_PEND));
    w32(GPINT, 0);
    id = r32(PLIC_CL0);
    w32(PLIC_CL0, id);
    put_num("  cleanup claim", id);

    /* 3. enable を 0 にしてから complete したとき、有効か (有効なら、1 のままの GP0 がまた pending になる) */
    w32(GPINT, 1);
    settle();
    id = r32(PLIC_CL0);
    w32(PLIC_EN0, 0);
    w32(PLIC_CL0, id);
    w32(PLIC_EN0, 0xFFFFFFFEu);
    settle();
    put_num("pending after complete with enable cleared", r32(PLIC_PEND));
    w32(PLIC_CL0, id);
    settle();
    put_num("pending after complete with enable restored", r32(PLIC_PEND));
    w32(GPINT, 0);
    id = r32(PLIC_CL0);
    w32(PLIC_CL0, id);

    /* 4. pending に書き込んで 1 にする (ソース 5) */
    w32(PLIC_PEND, 1u << 5);
    put_num("after writing bit 5 to pending", r32(PLIC_PEND));
    id = r32(PLIC_CL0);
    put_num("  claim", id);
    w32(PLIC_CL0, id);
    put_num("  pending after complete", r32(PLIC_PEND));

    /* 5. claim はしきい値で絞られるか (priority 1、threshold 2) */
    w32(PLIC_TH0, 2);
    w32(PLIC_PEND, 1u << 5);
    id = r32(PLIC_CL0);
    put_num("claim priority 1 at threshold 2", id);
    if (id != 0) w32(PLIC_CL0, id);
    w32(PLIC_TH0, 0);
    id = r32(PLIC_CL0);
    put_num("  claim after restoring threshold 0", id);
    if (id != 0) w32(PLIC_CL0, id);

    /* 6. PREEMPT: priority 2 のソースを claim したときの threshold と PPS、complete の後 */
    w32(PLIC, 1);
    put_num("after writing 1 to feature", r32(PLIC));
    w32(PLIC_PRIO(5), 2);
    w32(PLIC_PEND, 1u << 5);
    id = r32(PLIC_CL0);
    put_num("claim with PREEMPT", id);
    put_num("  threshold", r32(PLIC_TH0));
    put_num("  PPS", r32(PLIC_PPS0));
    w32(PLIC_CL0, id);
    put_num("  threshold after complete", r32(PLIC_TH0));
    put_num("  PPS after complete", r32(PLIC_PPS0));
    w32(PLIC_CL0, 5);
    put_num("  threshold after complete with empty PPS", r32(PLIC_TH0));
    w32(PLIC, 0);
    w32(PLIC_PRIO(5), 1);
    w32(PLIC_TH0, 0);

    /* 7. ターゲット 1 の claim (ターゲット 0 の enable は 0 にする) */
    w32(PLIC_EN0, 0);
    w32(PLIC_EN1, 1u << 5);
    w32(PLIC_PEND, 1u << 5);
    put_num("target 0 claim (enable 0)", r32(PLIC_CL0));
    id = r32(PLIC_CL1);
    put_num("target 1 claim", id);
    w32(PLIC_CL1, id);
    put_num("  pending after complete", r32(PLIC_PEND));
w32(PLIC_EN1, 0);

/* 8. PPS の幅 (ターゲット 0 の 8 ワードと、ターゲット 1 の先頭) */
put_str("-- PLIC PPS and target 1\r\n");
for (uint32_t k = 0; k < 8; k = k + 1) {
    put_str("pps t0 word");
    uart_putc((char)("0123456789abcdef"[k]));
    wb_line("", PLIC_PPS0 + 4u * k);
}
wb_line("pps t1 0x201400", PLIC + 0x201400u);

/* 9. ターゲット 1 の通知は mip のどこに出るか (ターゲット 0 と比べる。割り込みは通さない) */
w32(PLIC_PRIO(5), 1);
w32(PLIC_EN0, 0); w32(PLIC_EN1, 0); w32(PLIC_TH0, 0); w32(PLIC_TH1, 0);
put_num("mip (nothing pending)", READ_CSR(0x344));
w32(PLIC_EN0, 1u << 5);
w32(PLIC_PEND, 1u << 5);
settle();
put_num("mip (notify target 0)", READ_CSR(0x344));
w32(PLIC_EN0, 0);
w32(PLIC_EN1, 1u << 5);
settle();
put_num("mip (notify target 1)", READ_CSR(0x344));

/* 10. ターゲット 1 の PREEMPT (feature はターゲットで共通) */
w32(PLIC, 1);
w32(PLIC_PRIO(5), 2);
id = r32(PLIC_CL1);
put_num("target 1 claim with PREEMPT", id);
put_num("  threshold t1", r32(PLIC_TH1));
put_num("  pps t1", r32(PLIC + 0x201400u));
put_num("  threshold t0", r32(PLIC_TH0));
w32(PLIC_CL1, id);
put_num("  threshold t1 after complete", r32(PLIC_TH1));
put_num("  pps t1 after complete", r32(PLIC + 0x201400u));
w32(PLIC, 0);
w32(PLIC_PRIO(5), 1);
w32(PLIC_TH1, 0);
w32(PLIC_EN1, 0);
    (void)gp0_src;
}

/*
 * ahb_sdram のカウンタ (0x0300_0000〜。読み出しと書き込みの転送の数、AE350 を待たせた DDR_CLK のサイクル数、SDRAM のクロック側の
 * ライン読み出しと書き込みのサイクル数、書き込んだバイト数) の 7 つを読む
 */
#define SDRAM_STAT_BASE 0x03000000u
#define SDRAM_STAT_N    7
static void sdram_stat(uint32_t *v)
{
    /*
     * 前の書き込みが DDR_H* で完了してから読む。N25F は書き込みの完了を待たずに先へ進み、アドレスの異なる読み出しが書き込み
     * バッファを追い越す (RVWMO で許されている)。fence がないと、最後の 2〜3 個の書き込みが数に入らないことがあった
     * (実機で観測)。Hazard3 は書き込みを 1 つずつ完了させるので、シミュレーションでは起きない
     */
    __asm__ volatile("fence" : : : "memory");
    for (uint32_t k = 0; k < SDRAM_STAT_N; k = k + 1) v[k] = load_word_4byte(SDRAM_STAT_BASE + 4u * k);
}

/* カウンタの前後の差を出力する */
static void sdram_stat_lines(const char *what, const uint32_t *a, const uint32_t *b)
{
    static const char *const names[SDRAM_STAT_N] = {
        "read transfers", "DDR_CLK stalled on reads", "write transfers", "DDR_CLK stalled on writes",
        "SDRAM clocks for line reads", "SDRAM clocks for writes", "bytes written to SDRAM",
    };
    for (uint32_t k = 0; k < SDRAM_STAT_N; k = k + 1) {
        put_str(what);
        put_str(" ");
        put_line(names[k], b[k] - a[k]);
    }
}

/*
 * DDR_H* の先の SDRAM (0x0000_0000〜、32 MB。rtl/ahb_sdram.v → rtl/sdram_bridge.v)。
 * 32、16、8 ビットの読み書き、32 MB の最上位、32 MB の外のエラー応答、4 KB の読み書きの照合、読み書きのサイクル数を確かめる
 */
static void sdram_check(void)
{
    /*
     * この確認の間はデータキャッシュを無効にする (読み書きを SDRAM まで届かせ、カウンタの古い値を読まないため)。SDRAM に
     * 書き込むのはこの確認の中だけなので、無効にする前にキャッシュからライトバックするものはない
     */
    CLEAR_CSR(0x7CA, MCACHE_DC_EN);
    put_str("-- SDRAM behind DDR_H* (0x0000_0000, 32 MB)\r\n");
    trap_cause = 0;
    store_word_4byte(0x00001000u, 0x11223344u);
    store_word_4byte(0x00001004u, 0x55667788u);
    *(volatile uint16_t *)0x00001002u = 0xBEEF;
    *(volatile uint8_t *)0x00001005u = 0xAB;
    store_word_4byte(0x01FFFFFCu, 0xCAFEF00Du);
    put_line("exception on write", 0);
    mem_line("0x00001000 (0x11223344 with upper 2 bytes 0xbeef)", 0x00001000u);
    mem_line("0x00001004 (0x55667788 with byte 1 0xab)", 0x00001004u);
    mem_line("0x01fffffc (top of 32 MB, 0xcafef00d)", 0x01FFFFFCu);
    mem_line("0x02000000 (outside 32 MB, raises exception 5)", 0x02000000u);

    /*
     * 1 MB 先に、アドレスから決まる値とその反転を書き込んで読み返す (一致しないワードの数を出す)。実機では 64 KB、
     * シミュレーション (Andes の CSR が読めない) では 4 KB。最初の 1024 ワードの書き込みと読み出しの mcycle も出力する
     */
    (void)READ_CSR(0xFC2);
    const uint32_t words = (trap_cause != 0) ? 1024u : 16384u;
    const uintptr_t base = 0x00100000u;
    uint32_t bad = 0, c_wr = 0, c_rd = 0;
    uint32_t s_w0[SDRAM_STAT_N], s_w1[SDRAM_STAT_N], s_r0[SDRAM_STAT_N], s_r1[SDRAM_STAT_N];
    for (uint32_t pass = 0; pass < 2; pass = pass + 1) {
        const uint32_t inv = pass ? 0xFFFFFFFFu : 0u;
        if (pass == 0) sdram_stat(s_w0);
        uint32_t c0 = READ_CSR(0xB00);
        for (uint32_t i = 0; i < words; i = i + 1) {
            store_word_4byte(base + 4u * i, ((base + 4u * i) ^ 0x5A5A0000u ^ i) ^ inv);
            if (i == 1023u && pass == 0) {
                c_wr = READ_CSR(0xB00) - c0;
                sdram_stat(s_w1);
            }
        }
        if (pass == 0) sdram_stat(s_r0);
        uint32_t c1 = READ_CSR(0xB00);
        for (uint32_t i = 0; i < words; i = i + 1) {
            if (load_word_4byte(base + 4u * i) != (((base + 4u * i) ^ 0x5A5A0000u ^ i) ^ inv)) bad = bad + 1;
            if (i == 1023u && pass == 0) {
                c_rd = READ_CSR(0xB00) - c1;
                sdram_stat(s_r1);
            }
        }
    }
    trap_cause = 0;
    put_line("words checked (2 patterns)", words * 2u);
    put_line("mismatched words", bad);
    put_line("mcycle for 1024 32-bit writes", c_wr);
    put_line("mcycle for 1024 32-bit reads (including check)", c_rd);
    sdram_stat_lines("1024 writes:", s_w0, s_w1);
    sdram_stat_lines("1024 reads:", s_r0, s_r1);
    SET_CSR(0x7CA, MCACHE_DC_EN);
    trap_cause = 0;
}

static void report(void)
{
    put_str("== AE350 probe ==\r\n");

    put_str("-- CSR\r\n");
    CSR_LINE("misa", 0x301);
    CSR_LINE("mvendorid", 0xF11);
    CSR_LINE("marchid", 0xF12);
    CSR_LINE("mimpid", 0xF13);
    CSR_LINE("mhartid", 0xF14);
    CSR_LINE("mstatus", 0x300);
    CSR_LINE("mcountinhibit", 0x320);
    CSR_LINE("micm_cfg", 0xFC0);
    CSR_LINE("mdcm_cfg", 0xFC1);
    CSR_LINE("mmsc_cfg", 0xFC2);
    CSR_LINE("milmb", 0x7C0);
    CSR_LINE("mdlmb", 0x7C1);
    CSR_LINE("mcache_ctl", 0x7CA);
    CSR_LINE("mmisc_ctl", 0x7D0);

    put_str("-- PLIC\r\n");
    mem_line("plic 0x000000 feature", 0xE4000000u);
    mem_line("plic 0x000004 priority1", 0xE4000004u);
    mem_line("plic 0x000050 priority20", 0xE4000050u);
    mem_line("plic 0x001000 pending", 0xE4001000u);
    mem_line("plic 0x001080 trigger", 0xE4001080u);
    mem_line("plic 0x001100", 0xE4001100u);
    mem_line("plic 0x001104", 0xE4001104u);
    mem_line("plic 0x002000 enable", 0xE4002000u);
    mem_line("plic 0x200000 threshold", 0xE4200000u);

put_str("-- PLIC writable bits (write all ones, read back, restore)\r\n");
wb_line("priority1", 0xE4000004u);
wb_line("priority31", 0xE400007Cu);
wb_line("enable t0 0x002000", 0xE4002000u);
wb_line("enable t1 0x002080", 0xE4002080u);
wb_line("threshold t0 0x200000", 0xE4200000u);
wb_line("threshold t1 0x201000", 0xE4201000u);
wb_line("pending 0x001000", 0xE4001000u);

    plic_behavior();

    put_str("-- PLMT\r\n");
    mem_line("plmt mtimecmp lo", 0xE6000008u);
    mem_line("plmt mtimecmp hi", 0xE600000Cu);
    /*
     * 2000 回のループの前後で mcycle と mtime を読む。同じ測定を 2 回繰り返し、1 回目 (命令がキャッシュにない) と
     * 2 回目 (キャッシュにある) の両方を出力する。mtime を読む前後の mcycle も読み、mtime を読むのにかかったクロック数を
     * 開始時と終了時で出力する (キャッシュを有効にすると、1 回目の mcycle の差が mtime の差の 8 倍より大きく
     * なっていたため。mcycle の区間と mtime の区間の、開始と終了のずれがどれだけあるかを調べる)
     */
    for (uint32_t pass = 0; pass < 2; pass = pass + 1) {
        /*
         * UART の送信が終わるのを待ってから測る。AE350 は UART への書き込みを溜めたまま先へ進み、mtime の読み出しがその
         * 後ろで待たされて、その時間が mcycle の区間にだけ入る (sw/time_probe.c で確かめた)
         */
        while (UART_STATUS & UART_STATUS_BUSY) {
        }
        uint32_t c0  = READ_CSR(0xB00);
        uint32_t t0  = read_mem(0xE6000000u);
        uint32_t c0b = READ_CSR(0xB00);
        for (volatile uint32_t i = 0; i < 2000; i = i + 1) {
        }
        uint32_t c1  = READ_CSR(0xB00);
        uint32_t t1  = read_mem(0xE6000000u);
        uint32_t c1b = READ_CSR(0xB00);
        trap_cause = 0;
        put_str(pass == 0 ? "(1st run)\r\n" : "(2nd run)\r\n");
        put_line("mcycle delta", c1 - c0);
        put_line("mtime delta", t1 - t0);
        put_line("mcycle while reading mtime at start", c0b - c0);
        put_line("mcycle while reading mtime at end", c1b - c1);
    }

    put_str("-- APB inside AE350\r\n");
    mem_line("smu 0x00", 0xF0100000u);
    mem_line("smu 0x04", 0xF0100004u);
    mem_line("uart1 0x00", 0xF0200000u);
    mem_line("uart2 0x00", 0xF0300000u);
    mem_line("pit 0x00", 0xF0400000u);

    put_str("-- APB_P* PADDR\r\n");
    trap_cause = 0;
    store_word_4byte(0xF800F010u, 0x12345678u);
    put_line("result of write to 0xf800f010", 0);
    mem_line("  received PADDR", 0xF800F000u);
    mem_line("  received PSTRB", 0xF800F004u);
    mem_line("  received PWDATA", 0xF800F008u);
    store_byte(0xF800F023u, 0xAB);
    mem_line("PADDR of write to 0xf800f023 (1 byte)", 0xF800F000u);
    mem_line("  PSTRB", 0xF800F004u);
    mem_line("  PWDATA", 0xF800F008u);
    *(volatile uint16_t *)0xF800F012u = 0xBEEF;
    mem_line("PADDR of write to 0xf800f012 (2 bytes)", 0xF800F000u);
    mem_line("  PSTRB", 0xF800F004u);
    mem_line("  PWDATA", 0xF800F008u);
    trap_cause = 0;
    put_line("low PADDR of read from 0xf800f01d (1 byte)", *(volatile uint8_t *)0xF800F01Du);
    trap_cause = 0;
    put_line("low PADDR of read from 0xf800f01e (2 bytes)", *(volatile uint16_t *)0xF800F01Eu);
    trap_cause = 0;
    put_line("low PADDR of read from 0xf800f01f (1 byte)", *(volatile uint8_t *)0xF800F01Fu);
    mem_line("PADDR of read from 0xf800f00c", 0xF800F00Cu);
    mem_line("PADDR of read from 0xf800ffec", 0xF800FFECu);

    put_str("-- RAM behind EXTS_H* (0xE800_0000, 4 KB)\r\n");
    trap_cause = 0;
    store_word_4byte(0xE8000000u, 0x11223344u);
    store_word_4byte(0xE8000FFCu, 0x55667788u);
    *(volatile uint16_t *)0xE8000002u = 0xBEEF;
    *(volatile uint8_t *)0xE8000FFDu = 0xAB;
    put_line("exception on write", 0);
    mem_line("0xe8000000 (0x11223344 with upper 2 bytes 0xbeef)", 0xE8000000u);
    mem_line("0xe8000ffc (0x55667788 with byte 1 0xab)", 0xE8000FFCu);
    mem_line("0xe8001000 (outside the RAM, raises exception 5)", 0xE8001000u);

    sdram_check();

    put_str("== end ==\r\n");
}

/* mcycle を 64 ビットで読む (上位の桁上がりの途中を避ける) */
static uint64_t mcycle64(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = READ_CSR(0xB80);
        lo  = READ_CSR(0xB00);
        hi2 = READ_CSR(0xB80);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* mtime を 64 ビットで読む */
static uint64_t mtime64(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = r32(0xE6000004u);
        lo  = r32(0xE6000000u);
        hi2 = r32(0xE6000004u);
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/*
 * mtime と mcycle の速さを実時間と比べるための行を出力する。mcycle で間隔を空けて 10 行出力し、受信側 (Mac) が
 * 各行が届いた時刻を記録する。行の形式: "tick <番号> mtime <16 進 16 桁> mcycle <16 進 16 桁>"
 * 実機では間隔を 8 億 mcycle (CORE_CLK が 800 MHz なら 1 秒) にする。Hazard3 版 (Andes の CSR が読めない) では短くする
 */
static void ticks(void)
{
    (void)READ_CSR(0xFC2);
    uint64_t gap = (trap_cause != 0) ? 20000u : 800000000u;
    put_str("-- time\r\n");
    for (uint32_t n = 0; n < 10; n = n + 1) {
        uint64_t c0 = mcycle64();
        uint64_t t0 = mtime64();
        put_str("tick ");
        uart_putc((char)("0123456789"[n]));
        put_str(" mtime ");
        put_hex((uint32_t)(t0 >> 32));
        put_hex((uint32_t)t0);
        put_str(" mcycle ");
        put_hex((uint32_t)(c0 >> 32));
        put_hex((uint32_t)c0);
        put_str("\r\n");
        while (mcycle64() - c0 < gap) {
        }
    }
    put_str("-- time end\r\n");
}

int main(void)
{
    cache_enable();
    report();
    ticks();
    /*
     * Hazard3 版のテストベンチに終了を知らせる。アドレス 0 への書き込みは C で書くと GCC が削除するので、命令で書く。実機 (Andes の
     * CSR が読める) では書き込まない (アドレス 0 は SDRAM で、データキャッシュに書き込んだまま残るため)
     */
    (void)READ_CSR(0xFC2);
    if (trap_cause != 0) store_word_4byte(0x00000000u, 0x600Du);
    trap_cause = 0;
    for (;;) {
        (void)uart_getc();
        report();
    }
}
