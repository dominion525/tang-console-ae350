/*
 * フレームバッファの表示で、時間とともに動く絵を出すプログラム (ILM に置き、ROM のローダーで送る。make build/fb_animate.bin)。
 *   ruby tools/ae350_load.rb <ポート> build/fb_animate.bin A0000000
 *
 * 背景 (fb_demo の 1 回目と同じグラデーションと 80 画素ごとの白い格子) の上を、64 × 64 画素のマゼンタの四角が、画面の端で
 * 跳ね返りながら 1 フレームごとに動く。止まらずに動き続ける (止めるときは、ローダーで次のプログラムを送る。リセットで止まる)。
 *
 * フレームバッファは 2 枚 (FB0、FB1)。表示していない方に描き、描き終えたら FB_BASE を切り替える (表示の回路は FB_BASE を
 * フレームの始まりで取り込むので、切り替えはフレームの境目で起きる)。1 フレームで描くのは、前にその 1 枚に描いた四角を背景で
 * 消すことと、新しい位置に四角を描くことだけ。
 *   - FRAME が増えた (垂直帰線が始まった) ところで描き始める。描いているのは、直前のフレームを表示し終えた 1 枚
 *   - 垂直帰線 (30 ライン、約 667 µs) のうちに FB_BASE を書けば次のフレームから切り替わる。間に合わなければ 1 フレーム遅れて
 *     切り替わる (表示中の 1 枚には描かないので、絵は崩れない)。描くのに 667 µs 以上かかった回数を「late」として数える
 *   - REPORT_FRAMES フレームごとに、フレーム数、late の回数、描く時間の最大、UNDERRUN を UART に出す
 */

#include <stdint.h>
#include <stdio.h>

#include "fb.h"

#ifndef REPORT_FRAMES
#define REPORT_FRAMES 60u           /* 1 秒ごと */
#endif

#define FB0        FB_DEFAULT_ADDR
#define FB1        (FB_DEFAULT_ADDR + FB_STRIDE * FB_HEIGHT)    /* 0x01DC_2000 */
#define SQ         64u              /* 四角の大きさ (画素) */
#define SQ_COLOR   0xF81Fu          /* マゼンタ */
#define VBLANK_CYC 533600u          /* 垂直帰線 30 ライン = 667 µs (mcycle は 800 MHz で数える) */

static inline uint32_t rd_mcycle(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

/* 背景の 1 画素 (fb_demo の 1 回目と同じ。格子のときは grid を 1 にする) */
static inline uint16_t bg(uint32_t x, uint32_t y, uint32_t grid)
{
    if (grid) return 0xFFFFu;
    return (uint16_t)((((x * 25u) >> 10) << 11) | (((y * 90u) >> 10) << 5) | 16u);
}

/* 1 枚に背景を描く */
static void draw_bg(uint32_t base)
{
    for (uint32_t y = 0; y < FB_HEIGHT; y++) {
        volatile uint32_t *row = (volatile uint32_t *)(base + y * FB_STRIDE);
        uint32_t gy = (y % 80u) == 0u;
        for (uint32_t x = 0; x < FB_WIDTH; x += 2u) {
            uint16_t p0 = bg(x, y, gy || (x % 80u) == 0u);
            uint16_t p1 = bg(x + 1u, y, gy || ((x + 1u) % 80u) == 0u);
            row[x / 2u] = (uint32_t)p0 | ((uint32_t)p1 << 16);
        }
    }
}

/* (x0, y0) からの四角を、背景 (fill が 0) か四角の色 (fill が 1) で塗る。x0 は偶数 */
static void draw_sq(uint32_t base, uint32_t x0, uint32_t y0, uint32_t fill)
{
    uint8_t gx[SQ];
    if (!fill) {
        for (uint32_t i = 0; i < SQ; i++) gx[i] = ((x0 + i) % 80u) == 0u;
    }
    for (uint32_t y = y0; y < y0 + SQ; y++) {
        volatile uint32_t *row = (volatile uint32_t *)(base + y * FB_STRIDE);
        uint32_t gy = (y % 80u) == 0u;
        for (uint32_t i = 0; i < SQ; i += 2u) {
            uint32_t x = x0 + i;
            uint16_t p0 = fill ? SQ_COLOR : bg(x, y, gy || gx[i]);
            uint16_t p1 = fill ? SQ_COLOR : bg(x + 1u, y, gy || gx[i + 1u]);
            row[x / 2u] = (uint32_t)p0 | ((uint32_t)p1 << 16);
        }
    }
}

int main(void)
{
    const uint32_t base[2] = {FB0, FB1};
    uint32_t px[2] = {0, 0}, py[2] = {0, 0};   /* それぞれの 1 枚に、前に描いた四角の位置 */
    uint32_t x = 0, y = 0;
    int32_t  vx = 4, vy = 3;                    /* 1 フレームに動く画素数 (vx は偶数。32 ビットずつ書くため) */
    uint32_t back = 1;                          /* 次に描く 1 枚 (FB0 を表示しているので FB1) */
    uint32_t frames = 0, late = 0, max_cyc = 0;

    printf("fb_animate: FB0 0x%08lx FB1 0x%08lx, square %lu, report every %lu frames\n", (unsigned long)FB0,
           (unsigned long)FB1, (unsigned long)SQ, (unsigned long)REPORT_FRAMES);
    /* 両方に背景と、最初の位置の四角を描き、FB0 を表示する */
    draw_bg(FB0);
    draw_bg(FB1);
    draw_sq(FB0, x, y, 1u);
    draw_sq(FB1, x, y, 1u);
    FB_BASE   = FB0;
    FB_STATUS = FB_STATUS_UNDERRUN;
    FB_CTRL   = FB_CTRL_ENABLE;

    uint32_t f = FB_FRAME;
    for (;;) {
        /* 垂直帰線の始まりを待つ */
        while (FB_FRAME == f) {
        }
        f = FB_FRAME;
        uint32_t c0 = rd_mcycle();

        /* 次の位置 (端で跳ね返る) */
        int32_t nx = (int32_t)x + vx, ny = (int32_t)y + vy;
        if (nx < 0 || nx > (int32_t)(FB_WIDTH - SQ))  { vx = -vx; nx = (int32_t)x + vx; }
        if (ny < 0 || ny > (int32_t)(FB_HEIGHT - SQ)) { vy = -vy; ny = (int32_t)y + vy; }
        x = (uint32_t)nx;
        y = (uint32_t)ny;

        /* 表示していない 1 枚で、前の四角を消して新しい位置に描き、切り替える */
        draw_sq(base[back], px[back], py[back], 0u);
        draw_sq(base[back], x, y, 1u);
        px[back] = x;
        py[back] = y;
        FB_BASE = base[back];
        back ^= 1u;

        uint32_t cyc = rd_mcycle() - c0;
        if (cyc > max_cyc) max_cyc = cyc;
        if (cyc > VBLANK_CYC) late++;
        frames++;
        if (frames % REPORT_FRAMES == 0u) {
            printf("frames %lu, late %lu, max draw %lu us, underrun %lu\n", (unsigned long)frames, (unsigned long)late,
                   (unsigned long)(max_cyc / 800u), (unsigned long)(FB_STATUS & FB_STATUS_UNDERRUN));
            max_cyc = 0;
        }
    }
}
