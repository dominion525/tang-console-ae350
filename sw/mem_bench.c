/*
 * DDR_H* の先のメモリ (SDRAM か DDR3) への 1 回の読み書きにかかる、CPU のクロック数を測るプログラム。
 * ILM に置き (sw/ilm.ld)、ROM のローダーで送って run する。SDRAM 版と DDR3 版 (board/tang_console/build.sh の
 * MEM=ddr3) で同じものを実行して比べる。
 *
 * データキャッシュを無効にして測る (mcache_ctl の bit 1。キャッシュが有効だと、メモリまでアクセスしない)。測る前に、UART の
 * 送信が終わるのを待つ (AE350 は UART への書き込みを溜めたまま先へ進み、直後のバスの読み出しが待たされる。sw/time_probe.c)。
 *
 *   シーケンシャル書き込み          32 ビットを 4 バイトずつ進めて 1024 回書き込み、最後に fence (溜まった書き込みが終わるまで待つ) を置く
 *   シーケンシャル読み出し          32 ビットを 4 バイトずつ進めて 1024 回読む
 *   ランダム読み出し (4 KB 間隔)    32 ビットを 4096 バイトずつ進めて 1024 回読む (毎回別のラインなので、前に読んだものを再利用できない)
 *
 * 1 回あたりのクロック数は mcycle の合計 ÷ 1024 (100 倍した値を出力する)。
 *
 * DDR_H* の先の回路のカウンタも、それぞれの前後で読み、1 回あたりの差を出力する (DDR3 の読み出しが SDRAM より遅い原因の
 * 内訳を調べるため)。DDR3 版は rtl/ahb_ddr3.v の 0x7F00_0000、SDRAM 版は rtl/ahb_sdram.v の 0x0300_0000。0x7F00_0000 を読んで
 * 例外にならなければ DDR3 版とみなす。
 */

#include <stdint.h>
#include <stdio.h>
#include "trap.h"
#include "uart.h"

#define N     1024u
#define BASE  0x00800000u

static inline uint32_t rd_mcycle(void) { uint32_t v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }
static inline void fence(void) { __asm__ volatile("fence" ::: "memory"); }
static inline void uart_idle(void)
{
    while (UART_STATUS & UART_STATUS_BUSY) {
    }
}

/* アドレスは volatile の変数を足して作る (GCC に定数のアドレスとして扱わせない。sw/ddr3_check.c と同じ) */
static volatile uintptr_t base0 = BASE;

static void report(const char *name, uint32_t cyc)
{
    printf("%-26s mcycle %8lu  per access x100 %lu\n", name, (unsigned long)cyc, (unsigned long)((uint64_t)cyc * 100u / N));
}

/* DDR_H* の先の回路のカウンタ (8 ワード) */
#define STAT_DDR3   0x7F000000u
#define STAT_SDRAM  0x03000000u
static uint32_t stat_base;
static void snap(uint32_t *v)
{
    fence();
    for (int i = 0; i < 8; i++) v[i] = load_word_4byte(stat_base + 4u * (uint32_t)i);
}

/* カウンタの前後の差を、1 回あたり (100 倍) で出力する */
static void report_stat(const char *name, const uint32_t *a, const uint32_t *b)
{
    static const char *const ddr3[8] = {"reads", "DDR_CLK stalled on reads", "writes", "DDR_CLK stalled on writes",
                                        "IP clocks until read command accepted", "IP clocks from read command to data",
                                        "IP clocks until write command accepted", "reads served from kept 32 bytes"};
    static const char *const sdram[8] = {"reads", "DDR_CLK stalled on reads", "writes", "DDR_CLK stalled on writes",
                                         "SDRAM clocks for line reads", "SDRAM clocks for writes", "bytes written to SDRAM", "0"};
    const char *const *nm = (stat_base == STAT_DDR3) ? ddr3 : sdram;
    printf("  %s counter deltas (per access x100)\n", name);
    for (int i = 0; i < 8; i++) {
        uint32_t d = b[i] - a[i];
        printf("    %-44s %8lu  (x100 %lu)\n", nm[i], (unsigned long)d, (unsigned long)((uint64_t)d * 100u / N));
    }
}

int main(void)
{
    __asm__ volatile("csrc 0x7CA, %0" : : "r"(2u) : "memory");   // データキャッシュを無効にする
    trap_cause = 0;
    fence();
    uintptr_t b = base0;
    uint32_t c0, c1, sum = 0;
    uint32_t s0[8], s1[8], s2[8], s3[8], s4[8], s5[8];
    static uint32_t got[N];   // シーケンシャル読み出しで読んだ値 (書き込んだ値 0〜1023 と照合する)

    (void)load_word_4byte(STAT_DDR3);
    stat_base = (trap_cause == 0) ? STAT_DDR3 : STAT_SDRAM;
    trap_cause = 0;

    uart_idle();
    snap(s0);
    c0 = rd_mcycle();
    for (uint32_t i = 0; i < N; i++) *(volatile uint32_t *)(b + 4 * i) = i;
    fence();
    c1 = rd_mcycle();
    snap(s1);
    uint32_t wr = c1 - c0;

    uart_idle();
    snap(s2);
    c0 = rd_mcycle();
    for (uint32_t i = 0; i < N; i++) got[i] = *(volatile uint32_t *)(b + 4 * i);
    c1 = rd_mcycle();
    snap(s3);
    uint32_t rd = c1 - c0;

    uart_idle();
    snap(s4);
    c0 = rd_mcycle();
    for (uint32_t i = 0; i < N; i++) sum += *(volatile uint32_t *)(b + 4096 * i);
    c1 = rd_mcycle();
    snap(s5);
    uint32_t rds = c1 - c0;

    printf("-- memory behind DDR_H* (from 0x%08lx, data cache off, N = %lu)\n", (unsigned long)b, (unsigned long)N);
    printf("counters: %s\n", stat_base == STAT_DDR3 ? "ahb_ddr3 (0x7F00_0000)" : "ahb_sdram (0x0300_0000)");
    report("sequential write", wr);
    report_stat("sequential write", s0, s1);
    report("sequential read", rd);
    report_stat("sequential read", s2, s3);
    report("random read (4 KB stride)", rds);
    report_stat("random read (4 KB stride)", s4, s5);
    int bad = 0;
    for (uint32_t i = 0; i < N; i++) {
        if (got[i] != i) {
            if (bad < 8) printf("mismatch: word %lu %08lx (expected %08lx)\n", (unsigned long)i, (unsigned long)got[i], (unsigned long)i);
            bad++;
        }
    }
    printf("sequential read data check: mismatches %d / %lu\n", bad, (unsigned long)N);
    printf("sum of random read data %08lx\n", (unsigned long)sum);
    return 0x600D;
}
