/*
 * 実機の値を読むプログラム (= board/tang_console/ の構成で動かす。2026-11-10)。
 *
 * モックを作るときに資料で決めきれなかった値と、本物の AE350 の素性を読み、UART に 1 行ずつ出す。
 * 読むと例外になるもの (= 無い CSR、エラー応答のアドレス) は、mcause を「例外」として出す。
 * 出し終わったら、UART に何か 1 文字送るともう一度出す。
 *
 * 行の形: <名前> <値 (16 進 8 桁)>   か   <名前> 例外 <mcause>
 *
 * モックでも流せる (= make run-probe)。そのときは終わりに DDR の 0x0000_0000 に 0x600D を書き、
 * TB を止める (= 実機の DDR_H* の先には何も無いので、書いても何も起きない)。
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
        put_str(" 例外 ");
        put_hex(trap_cause);
    } else {
        put_str(" ");
        put_hex(v);
    }
    put_str("\r\n");
}

/* CSR を読む。無い CSR は例外になり、sw/trap.c が次の命令から再開する (= csrr は常に 4 byte) */
#define READ_CSR(num) ({                                              \
    uint32_t v_;                                                      \
    trap_cause = 0;                                                   \
    __asm__ volatile("li %0, 0\n\tcsrr %0, " #num : "=&r"(v_) : : "memory"); \
    v_;                                                               \
})

#define CSR_LINE(name, num) put_line(name, READ_CSR(num))

/* CSR のビットを立てる / 落とす。無い CSR (= モックの Hazard3) は例外になり、次の命令から再開する */
#define SET_CSR(num, bits) __asm__ volatile("csrs " #num ", %0" : : "r"(bits) : "memory")
#define CLEAR_CSR(num, bits) __asm__ volatile("csrc " #num ", %0" : : "r"(bits) : "memory")

/*
 * 命令とデータのキャッシュを入れる (= mcache_ctl、0x7CA)。N25F のキャッシュは電源を入れた直後は切れていて、起動の
 * プログラムが入れる。値は Gowin の BSP (= ae350_coremark/ae350.c の __platform_init) と同じ: 命令とデータのキャッシュ
 * (= bit 0 / 1)、命令とデータの先読み (= bit 9 / 10)、データの write-around (= bit 13〜14 を 1)、一貫性 (= bit 19)。
 * 一貫性があるときは、入るまで (= bit 20) 待つ
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

/* 全部 1 を書いて読み返し、読む前の値に戻す (= 書けるビットを知る)。書けないアドレスは例外を出す */
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

/* 割り込みは CPU に入れない (= mie は 0 のまま)。PLIC のレジスタだけで挙動を見る */
static void plic_behavior(void)
{
    put_str("-- PLIC の挙動\r\n");
    trap_cause = 0;
    w32(PLIC_EN0, 0); w32(PLIC_EN1, 0); w32(PLIC_TH0, 0); w32(PLIC_TH1, 0);
    for (uint32_t id = 1; id < 32; id = id + 1) w32(PLIC_PRIO(id), 1);

    /* 0. pending を空にする (= 前の「書けるビット」の確認で全部立っている。pending は claim でしか落とせない) */
    w32(PLIC_EN0, 0xFFFFFFFEu);
    for (int n = 0; n < 40; n = n + 1) {
        uint32_t c = r32(PLIC_CL0);
        if (c == 0) break;
        w32(PLIC_CL0, c);
    }
    put_num("空にした後の pending", r32(PLIC_PEND));

    /* 1. GP_INT の 16 本がどのソースか (= 立てて pending を読み、落としてから claim / complete で片付ける) */
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
    put_num("片付けた後の pending", r32(PLIC_PEND));

    /* 2. レベルの再通知: GP0 を立てたまま claim / complete し、また pending が立つか */
    w32(GPINT, 1);
    settle();
    uint32_t id = r32(PLIC_CL0);
    put_num("gp0 を立てたまま claim", id);
    put_num("  claim の直後の pending", r32(PLIC_PEND));
    w32(PLIC_CL0, id);
    settle();
    put_num("  complete の後の pending", r32(PLIC_PEND));
    w32(GPINT, 0);
    id = r32(PLIC_CL0);
    w32(PLIC_CL0, id);
    put_num("  片付けの claim", id);

    /* 3. enable を落としてから complete したとき、効くか (= 効けば、立てたままの GP0 がまた pending になる) */
    w32(GPINT, 1);
    settle();
    id = r32(PLIC_CL0);
    w32(PLIC_EN0, 0);
    w32(PLIC_CL0, id);
    w32(PLIC_EN0, 0xFFFFFFFEu);
    settle();
    put_num("enable を落として complete した後の pending", r32(PLIC_PEND));
    w32(PLIC_CL0, id);
    settle();
    put_num("enable を戻して complete した後の pending", r32(PLIC_PEND));
    w32(GPINT, 0);
    id = r32(PLIC_CL0);
    w32(PLIC_CL0, id);

    /* 4. pending に書いて立てる (= ソース 5) */
    w32(PLIC_PEND, 1u << 5);
    put_num("pending に bit 5 を書いた後", r32(PLIC_PEND));
    id = r32(PLIC_CL0);
    put_num("  claim", id);
    w32(PLIC_CL0, id);
    put_num("  complete の後の pending", r32(PLIC_PEND));

    /* 5. claim はしきい値で絞るか (= priority 1、threshold 2) */
    w32(PLIC_TH0, 2);
    w32(PLIC_PEND, 1u << 5);
    id = r32(PLIC_CL0);
    put_num("threshold 2 で priority 1 を claim", id);
    if (id != 0) w32(PLIC_CL0, id);
    w32(PLIC_TH0, 0);
    id = r32(PLIC_CL0);
    put_num("  threshold 0 に戻して claim", id);
    if (id != 0) w32(PLIC_CL0, id);

    /* 6. PREEMPT: priority 2 を claim したときの threshold と PPS、complete の後 */
    w32(PLIC, 1);
    put_num("feature に 1 を書いた後", r32(PLIC));
    w32(PLIC_PRIO(5), 2);
    w32(PLIC_PEND, 1u << 5);
    id = r32(PLIC_CL0);
    put_num("PREEMPT で claim", id);
    put_num("  threshold", r32(PLIC_TH0));
    put_num("  PPS", r32(PLIC_PPS0));
    w32(PLIC_CL0, id);
    put_num("  complete の後の threshold", r32(PLIC_TH0));
    put_num("  complete の後の PPS", r32(PLIC_PPS0));
    w32(PLIC_CL0, 5);
    put_num("  PPS が空で complete した後の threshold", r32(PLIC_TH0));
    w32(PLIC, 0);
    w32(PLIC_PRIO(5), 1);
    w32(PLIC_TH0, 0);

    /* 7. ターゲット 1 の claim (= ターゲット 0 の enable は落とす) */
    w32(PLIC_EN0, 0);
    w32(PLIC_EN1, 1u << 5);
    w32(PLIC_PEND, 1u << 5);
    put_num("ターゲット 0 の claim (= enable 0)", r32(PLIC_CL0));
    id = r32(PLIC_CL1);
    put_num("ターゲット 1 の claim", id);
    w32(PLIC_CL1, id);
    put_num("  complete の後の pending", r32(PLIC_PEND));
w32(PLIC_EN1, 0);

/* 8. PPS の幅 (= ターゲット 0 の 8 ワード、ターゲット 1 の先頭) */
put_str("-- PLIC の PPS とターゲット 1\r\n");
for (uint32_t k = 0; k < 8; k = k + 1) {
    put_str("pps t0 word");
    uart_putc((char)("0123456789abcdef"[k]));
    wb_line("", PLIC_PPS0 + 4u * k);
}
wb_line("pps t1 0x201400", PLIC + 0x201400u);

/* 9. ターゲット 1 の通知は mip のどこに出るか (= ターゲット 0 と比べる。割り込みは入れない) */
w32(PLIC_PRIO(5), 1);
w32(PLIC_EN0, 0); w32(PLIC_EN1, 0); w32(PLIC_TH0, 0); w32(PLIC_TH1, 0);
put_num("mip (何も立てない)", READ_CSR(0x344));
w32(PLIC_EN0, 1u << 5);
w32(PLIC_PEND, 1u << 5);
settle();
put_num("mip (ターゲット 0 に通知)", READ_CSR(0x344));
w32(PLIC_EN0, 0);
w32(PLIC_EN1, 1u << 5);
settle();
put_num("mip (ターゲット 1 に通知)", READ_CSR(0x344));

/* 10. ターゲット 1 の PREEMPT (= feature はターゲットに共通) */
w32(PLIC, 1);
w32(PLIC_PRIO(5), 2);
id = r32(PLIC_CL1);
put_num("ターゲット 1 で PREEMPT の claim", id);
put_num("  threshold t1", r32(PLIC_TH1));
put_num("  pps t1", r32(PLIC + 0x201400u));
put_num("  threshold t0", r32(PLIC_TH0));
w32(PLIC_CL1, id);
put_num("  complete の後の threshold t1", r32(PLIC_TH1));
put_num("  complete の後の pps t1", r32(PLIC + 0x201400u));
w32(PLIC, 0);
w32(PLIC_PRIO(5), 1);
w32(PLIC_TH1, 0);
w32(PLIC_EN1, 0);
    (void)gp0_src;
}

/*
 * ahb_sdram のカウンタ (= 0x0300_0000〜。読みと書きの転送の数、AE350 を待たせた DDR_CLK のサイクル数、SDRAM のクロックの側の
 * 行の読みと書きのサイクル数、書いた byte の数) の 7 つを読む
 */
#define SDRAM_STAT_BASE 0x03000000u
#define SDRAM_STAT_N    7
static void sdram_stat(uint32_t *v)
{
    /*
     * 前の書き込みが DDR_H* で終わってから読む。N25F は書き込みの終わりを待たずに進み、番地の違う読み出しは書き込みの
     * バッファを追い越す (= RVWMO で許される)。fence が無いと、最後の 2〜3 個の書き込みが数に入らないことがあった
     * (= 実機、2026-11-12)。Hazard3 は書き込みを 1 つずつ終わらせるので、シミュレーションでは起きない
     */
    __asm__ volatile("fence" : : : "memory");
    for (uint32_t k = 0; k < SDRAM_STAT_N; k = k + 1) v[k] = load_word_4byte(SDRAM_STAT_BASE + 4u * k);
}

/* カウンタの前後の差を出す */
static void sdram_stat_lines(const char *what, const uint32_t *a, const uint32_t *b)
{
    static const char *const names[SDRAM_STAT_N] = {
        "読みの転送の数", "読みで待たせた DDR_CLK", "書きの転送の数", "書きで待たせた DDR_CLK",
        "行の読みの SDRAM のクロック", "書きの SDRAM のクロック", "SDRAM に書いた byte の数",
    };
    for (uint32_t k = 0; k < SDRAM_STAT_N; k = k + 1) {
        put_str(what);
        put_str(" ");
        put_line(names[k], b[k] - a[k]);
    }
}

/*
 * DDR_H* の先の SDRAM (= 0x0000_0000〜、32 MB。rtl/ahb_sdram.v → rtl/sdram_bridge.v)。
 * 32 / 16 / 8 bit の読み書き、32 MB の一番上、32 MB の外のエラー応答、4 KB の読み書きの照合、読み書きのサイクル数を見る
 */
static void sdram_check(void)
{
    /*
     * この確認の間はデータキャッシュを切る (= 読み書きを SDRAM まで届かせ、カウンタの古い値を読まない)。SDRAM に書くのは
     * この確認の中だけなので、切る前にキャッシュから書き戻すものは無い
     */
    CLEAR_CSR(0x7CA, MCACHE_DC_EN);
    put_str("-- DDR_H* の先の SDRAM (= 0x0000_0000、32 MB)\r\n");
    trap_cause = 0;
    store_word_4byte(0x00001000u, 0x11223344u);
    store_word_4byte(0x00001004u, 0x55667788u);
    *(volatile uint16_t *)0x00001002u = 0xBEEF;
    *(volatile uint8_t *)0x00001005u = 0xAB;
    store_word_4byte(0x01FFFFFCu, 0xCAFEF00Du);
    put_line("書き込みの例外", 0);
    mem_line("0x00001000 (= 0x11223344 の上位 2 byte に 0xbeef)", 0x00001000u);
    mem_line("0x00001004 (= 0x55667788 の byte 1 に 0xab)", 0x00001004u);
    mem_line("0x01fffffc (= 32 MB の一番上、0xcafef00d)", 0x01FFFFFCu);
    mem_line("0x02000000 (= 32 MB の外。例外 5 になる)", 0x02000000u);

    /*
     * 1 MB 先に、番地から決まる値とその反転を書いて読み返す (= 違う語の数)。実機では 64 KB、シミュレーション (= Andes の
     * CSR が読めない) では 4 KB。最初の 1024 語の書きと読みの mcycle も出す
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
    put_line("照合した語の数 (= 2 通り)", words * 2u);
    put_line("照合で違った語の数", bad);
    put_line("32 bit の書き 1024 回の mcycle", c_wr);
    put_line("32 bit の読み 1024 回の mcycle (= 照合を含む)", c_rd);
    sdram_stat_lines("書き 1024 回の", s_w0, s_w1);
    sdram_stat_lines("読み 1024 回の", s_r0, s_r1);
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

put_str("-- PLIC の書けるビット (= 全部 1 を書いて読み返し、元に戻す)\r\n");
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
     * 2000 回のループの前後で mcycle と mtime を読む。同じ測定を 2 回くり返し、1 回目 (= 命令がキャッシュに無い) と
     * 2 回目 (= キャッシュにある) の両方を出す。mtime を読む前後の mcycle も読み、mtime を読むのにかかったクロック数を
     * 始まりと終わりで出す (= 2026-11-13。キャッシュを入れると、1 回目の mcycle の差が mtime の差の 8 倍より大きく
     * なっていた。mcycle の区間と mtime の区間の始まりと終わりのずれが、どれだけあるかを見るため)
     */
    for (uint32_t pass = 0; pass < 2; pass = pass + 1) {
        /*
         * UART が送り終わるのを待ってから測る。AE350 は UART への書き込みを溜めたまま先へ進み、mtime の読み出しがその
         * 後ろで待たされて、その時間が mcycle の区間にだけ入る (= 2026-11-13 に sw/time_probe.c で確かめた)
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
        put_str(pass == 0 ? "(1 回目)\r\n" : "(2 回目)\r\n");
        put_line("mcycle の差", c1 - c0);
        put_line("mtime の差", t1 - t0);
        put_line("始まりの mtime を読む間の mcycle", c0b - c0);
        put_line("終わりの mtime を読む間の mcycle", c1b - c1);
    }

    put_str("-- AE350 の中の APB\r\n");
    mem_line("smu 0x00", 0xF0100000u);
    mem_line("smu 0x04", 0xF0100004u);
    mem_line("uart1 0x00", 0xF0200000u);
    mem_line("uart2 0x00", 0xF0300000u);
    mem_line("pit 0x00", 0xF0400000u);

    put_str("-- APB_P* の PADDR\r\n");
    trap_cause = 0;
    store_word_4byte(0xF800F010u, 0x12345678u);
    put_line("書き込み 0xf800f010 の結果", 0);
    mem_line("  届いた PADDR", 0xF800F000u);
    mem_line("  届いた PSTRB", 0xF800F004u);
    mem_line("  届いた PWDATA", 0xF800F008u);
    store_byte(0xF800F023u, 0xAB);
    mem_line("書き込み 0xf800f023 (1 byte) の PADDR", 0xF800F000u);
    mem_line("  PSTRB", 0xF800F004u);
    mem_line("  PWDATA", 0xF800F008u);
    *(volatile uint16_t *)0xF800F012u = 0xBEEF;
    mem_line("書き込み 0xf800f012 (2 byte) の PADDR", 0xF800F000u);
    mem_line("  PSTRB", 0xF800F004u);
    mem_line("  PWDATA", 0xF800F008u);
    trap_cause = 0;
    put_line("読み出し 0xf800f01d (1 byte) の PADDR の下位", *(volatile uint8_t *)0xF800F01Du);
    trap_cause = 0;
    put_line("読み出し 0xf800f01e (2 byte) の PADDR の下位", *(volatile uint16_t *)0xF800F01Eu);
    trap_cause = 0;
    put_line("読み出し 0xf800f01f (1 byte) の PADDR の下位", *(volatile uint8_t *)0xF800F01Fu);
    mem_line("読み出し 0xf800f00c の PADDR", 0xF800F00Cu);
    mem_line("読み出し 0xf800ffec の PADDR", 0xF800FFECu);

    put_str("-- EXTS_H* の先の RAM (= 0xE800_0000、4 KB)\r\n");
    trap_cause = 0;
    store_word_4byte(0xE8000000u, 0x11223344u);
    store_word_4byte(0xE8000FFCu, 0x55667788u);
    *(volatile uint16_t *)0xE8000002u = 0xBEEF;
    *(volatile uint8_t *)0xE8000FFDu = 0xAB;
    put_line("書き込みの例外", 0);
    mem_line("0xe8000000 (= 0x11223344 の上位 2 byte に 0xbeef)", 0xE8000000u);
    mem_line("0xe8000ffc (= 0x55667788 の byte 1 に 0xab)", 0xE8000FFCu);
    mem_line("0xe8001000 (= RAM の外。例外 5 になる)", 0xE8001000u);

    sdram_check();

    put_str("== end ==\r\n");
}

/* mcycle を 64 bit で読む (= 上位が繰り上がる途中を避ける) */
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

/* mtime を 64 bit で読む */
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
 * mtime と mcycle の速さを壁時計と比べるための行を出す。mcycle で間を空けて 10 行出し、受ける側 (= Mac) が
 * 各行の届いた時刻を記録する。行の形: "tick <番号> mtime <16 進 16 桁> mcycle <16 進 16 桁>"
 * 実機では間を 8 億 mcycle (= CORE_CLK が 800 MHz なら 1 秒) にする。モック (= Andes の CSR が読めない) では短くする
 */
static void ticks(void)
{
    (void)READ_CSR(0xFC2);
    uint64_t gap = (trap_cause != 0) ? 20000u : 800000000u;
    put_str("-- 時間\r\n");
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
    put_str("-- 時間 end\r\n");
}

int main(void)
{
    cache_enable();
    report();
    ticks();
    /*
     * モックの TB に終わりを知らせる。0 番地への書き込みは C で書くと GCC が消すので、命令で書く。実機 (= Andes の CSR が
     * 読める) では書かない (= 0 番地は SDRAM で、データキャッシュに書いたまま残る)
     */
    (void)READ_CSR(0xFC2);
    if (trap_cause != 0) store_word_4byte(0x00000000u, 0x600Du);
    trap_cause = 0;
    for (;;) {
        (void)uart_getc();
        report();
    }
}
