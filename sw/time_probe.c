/*
 * キャッシュを有効にすると、短い間隔でだけ mcycle と mtime の差が合わなくなる現象を調べるプログラム。
 * ILM に置き (sw/ilm.ld)、ROM のローダーで送って run する。
 *
 * probe (sw/probe.c) の PLMT の行では、2000 回のループの前後で読んだ差の比 (mcycle / mtime) が、キャッシュを有効にする
 * 前は 8.0 (800 MHz ÷ 100 MHz のとおり)、有効にした後は 71.7 だった。キャッシュを有効にする前と後で、次の 2 つを 3 回ずつ測る。
 *
 *   gap     mtime (0xE600_0000 の下位 32 ビット) を読み、mcycle で 8,000 クロック (800 MHz なら 10 µs) 待って、もう一度読む
 *   loop    probe と同じ形 (volatile の変数で 2000 回回るループ) の前後で、mcycle と mtime を読む
 *
 * キャッシュを有効にする値は probe と同じ (mcache_ctl、0x7CA)。Hazard3 (Andes の CSR がない) では例外になり、sw/trap.c が
 * 次の命令から再開する (キャッシュを有効にしない側だけを 2 回測ることになる)。
 */

#include <stdint.h>
#include <stdio.h>
#include "trap.h"
#include "uart.h"

#define PLMT_MTIME 0xE6000000u

static inline uint32_t rd_mcycle(void) { uint32_t v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }

static uint32_t rd_csr_7ca(void)
{
    uint32_t v = 0;
    trap_cause = 0;
    __asm__ volatile("li %0, 0\n\tcsrr %0, 0x7CA" : "=&r"(v) : : "memory");
    return v;
}

static void cache_enable(void)
{
    __asm__ volatile("csrc 0x7CA, %0" : : "r"(3u << 13) : "memory");
    __asm__ volatile("csrs 0x7CA, %0" : : "r"((1u << 19) | (1u << 13) | (1u << 10) | (1u << 9) | 2u | 1u) : "memory");
    if (rd_csr_7ca() & (1u << 19)) {
        while ((rd_csr_7ca() & (1u << 20)) == 0) {
        }
    }
    trap_cause = 0;
}

static void measure(const char *label)
{
    printf("-- %s (mcache_ctl %08lx, exception %lu)\n", label, (unsigned long)rd_csr_7ca(), (unsigned long)trap_cause);
    trap_cause = 0;
    for (int k = 0; k < 3; k++) {
        uint32_t c0 = rd_mcycle();
        uint32_t t0 = load_word_4byte(PLMT_MTIME);
        while (rd_mcycle() - c0 < 8000u) {
        }
        uint32_t c1 = rd_mcycle();
        uint32_t t1 = load_word_4byte(PLMT_MTIME);
        printf("gap  mcycle %8lu  mtime %8lu\n", (unsigned long)(c1 - c0), (unsigned long)(t1 - t0));
    }
    for (int k = 0; k < 3; k++) {
        uint32_t c0 = rd_mcycle();
        uint32_t t0 = load_word_4byte(PLMT_MTIME);
        for (volatile uint32_t i = 0; i < 2000; i = i + 1) {
        }
        uint32_t c1 = rd_mcycle();
        uint32_t t1 = load_word_4byte(PLMT_MTIME);
        printf("loop mcycle %8lu  mtime %8lu\n", (unsigned long)(c1 - c0), (unsigned long)(t1 - t0));
    }
}

/*
 * 直前に UART へ n 文字書き込んでから mtime を読み、読むのにかかった mcycle を返す。UART の DATA への書き込みは、前の文字の
 * 送信が終わっていないとバスを待たせる (sw/uart.h)。CPU が書き込みを保留したまま先へ進むなら、mtime の読み出しがその後ろで
 * 待たされるはず (probe のループの前の mtime の読み出しに、6,000〜19,000 クロックかかっていた現象を調べるため)。
 * wait_idle が 1 なら、書き込んだ後 UART の送信が終わる (BUSY が 0 になる) のを待ってから測る
 */
static uint32_t read_after_uart(int n, int wait_idle)
{
    for (int i = 0; i < n; i++) uart_putc('.');
    if (wait_idle) {
        while (UART_STATUS & UART_STATUS_BUSY) {
        }
    }
    uint32_t c0 = rd_mcycle();
    (void)load_word_4byte(PLMT_MTIME);
    uint32_t c1 = rd_mcycle();
    return c1 - c0;
}

int main(void)
{
    measure("before enabling the cache");
    cache_enable();
    measure("after enabling the cache");

    /* 測っている間は printf を使わない (結果は配列に保持し、後で出力する) */
    static const int ns[] = {0, 1, 2, 3, 4, 8};
    uint32_t r[6][3], idle[3];
    for (int k = 0; k < 3; k++) {
        for (int j = 0; j < 6; j++) {
            while (UART_STATUS & UART_STATUS_BUSY) {
            }
            r[j][k] = read_after_uart(ns[j], 0);
        }
        while (UART_STATUS & UART_STATUS_BUSY) {
        }
        idle[k] = read_after_uart(8, 1);
    }
    printf("\n-- mcycle to read mtime right after writing n characters to the UART (3 runs)\n");
    for (int j = 0; j < 6; j++) {
        printf("n=%d  %8lu %8lu %8lu\n", ns[j], (unsigned long)r[j][0], (unsigned long)r[j][1], (unsigned long)r[j][2]);
    }
    printf("n=8, after waiting for TX idle  %8lu %8lu %8lu\n", (unsigned long)idle[0], (unsigned long)idle[1],
           (unsigned long)idle[2]);
    return 0x600D;
}
