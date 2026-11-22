/*
 * フレームバッファの表示を実機で確かめるプログラム (ILM に置き、ROM のローダーで送る。make build/fb_demo.bin)。
 *   ruby tools/ae350_load.rb <ポート> build/fb_demo.bin A0000000
 *
 * 画面全体 (1280 × 720) に絵を 2 回描き、それぞれ描くのにかかった時間を UART に出す。
 *   1 回目  データキャッシュなし (ローダーはデータキャッシュを有効にして起動するので、このプログラムが無効にする)。
 *           32 ビット (2 画素) ずつ書く。
 *           絵: 横に赤、縦に緑のグラデーション (青は半分) と、80 画素ごとの白い格子
 *   2 回目  データキャッシュあり。描き終えたら fb_flush_dcache() でメモリに書き出す (書き出しの時間も含める)。
 *           絵: 1 回目の赤と緑を入れ替え、格子を 40 画素ずらしたもの
 * 1 回目を描いてから ENABLE を 1 にし、2 回目は表示している間に描く。終わったときは ENABLE が 1 のまま (続けて mem_bench を
 * 送ると、表示している間の SDRAM の速さを測れる)。
 */

#include <stdint.h>
#include <stdio.h>

#include "fb.h"

#define MCACHE_DC 0x2u      /* mcache_ctl (CSR 0x7CA) のデータキャッシュの有効 */

static inline uint64_t rd_mcycle64(void)
{
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi));
        __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* 画面全体を描く。swap が 1 なら赤と緑を入れ替え、格子を 40 画素ずらす */
static void draw(uint32_t swap)
{
    volatile uint32_t *fb = (volatile uint32_t *)FB_DEFAULT_ADDR;
    uint32_t gy = swap ? 40u : 0u;       /* 縦の格子の位置 (80 で割った余り) */
    for (uint32_t y = 0; y < FB_HEIGHT; y++) {
        uint32_t v      = (y * 90u) >> 10;   /* 0〜63 */
        uint32_t line_w = (gy == 0u);
        uint32_t gx     = swap ? 40u : 0u;
        volatile uint32_t *row = fb + y * (FB_STRIDE / 4u);
        for (uint32_t x = 0; x < FB_WIDTH; x += 2u) {
            uint16_t p[2];
            for (uint32_t k = 0; k < 2u; k++) {
                uint32_t h = ((x + k) * 25u) >> 10;   /* 0〜31 */
                uint32_t r = swap ? (v >> 1) : h;
                uint32_t g = swap ? (h << 1) : v;
                p[k] = (line_w || gx == 0u) ? 0xFFFFu : (uint16_t)((r << 11) | (g << 5) | 16u);
                gx = (gx == 79u) ? 0u : gx + 1u;
            }
            row[x / 2u] = (uint32_t)p[0] | ((uint32_t)p[1] << 16);
        }
        gy = (gy == 79u) ? 0u : gy + 1u;
    }
}

static void report(const char *name, uint64_t cyc)
{
    /* mcycle は CPU のクロック (800 MHz) で数える */
    uint32_t us = (uint32_t)(cyc / 800u);
    printf("%s: %lu us (mcycle %lu), frame %lu, underrun %lu\n", name, (unsigned long)us, (unsigned long)cyc,
           (unsigned long)FB_FRAME, (unsigned long)(FB_STATUS & FB_STATUS_UNDERRUN));
}

int main(void)
{
    uint64_t c0, c1;

    printf("fb_demo: frame buffer 0x%08lx, %lu x %lu, ctrl %lu\n", (unsigned long)FB_BASE, (unsigned long)FB_WIDTH,
           (unsigned long)FB_HEIGHT, (unsigned long)FB_CTRL);
    FB_STATUS = FB_STATUS_UNDERRUN;

    /* 1 回目: データキャッシュなし */
    __asm__ volatile("csrc 0x7ca, %0" : : "r"(MCACHE_DC) : "memory");
    c0 = rd_mcycle64();
    draw(0u);
    c1 = rd_mcycle64();
    FB_CTRL = FB_CTRL_ENABLE;
    report("draw without data cache", c1 - c0);

    /* 2 回目: データキャッシュあり (表示している間に描く) */
    __asm__ volatile("csrs 0x7ca, %0" : : "r"(MCACHE_DC) : "memory");
    c0 = rd_mcycle64();
    draw(1u);
    fb_flush_dcache();
    c1 = rd_mcycle64();
    __asm__ volatile("csrc 0x7ca, %0" : : "r"(MCACHE_DC) : "memory");
    report("draw with data cache + write back", c1 - c0);
    return 0x600D;      /* シミュレーションのテストベンチは、この値を合格として終わる (mem_bench、hello と同じ) */
}
