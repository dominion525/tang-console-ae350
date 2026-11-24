/*
 * フレームバッファの表示で、時間とともに動く絵を出すプログラム (ILM に置き、ROM のローダーで送る。make build/fb_animate.bin)。
 *   ruby tools/ae350_load.rb <ポート> build/fb_animate.bin A0000000
 *
 * 背景 (fb_demo の 1 回目と同じグラデーションと 80 画素ごとの白い格子) の上を、64 × 64 画素のマゼンタの四角が、画面の端で
 * 跳ね返りながら 1 フレームごとに動く。止まらずに動き続ける (止めるときは、ローダーで次のプログラムを送る。リセットで止まる)。
 *
 * ROM のローダーは、プログラムをデータキャッシュを有効にして起動する (sw/loader.c の do_run)。最初にデータキャッシュを無効にし、
 * フレームバッファへの書き込みが SDRAM に直接届くようにする (キャッシュを通すと、書いた画素がキャッシュに残ったまま FB_BASE を
 * 切り替えることになり、表示が古い画素を読む。また、書き込みのたびにラインの読み込みと書き戻しが起き、遅い)。
 *
 * フレームバッファは 2 枚 (FB0、FB1)。表示していない方に描き、描き終えたら FB_BASE を切り替える (表示の回路は FB_BASE を
 * フレームの始まりで取り込むので、切り替えはフレームの境目で起きる)。1 フレームで描くのは、前にその 1 枚に描いた四角を背景で
 * 消すことと、新しい位置に四角を描くことだけ。背景は、横の位置で決まる部分 (赤、青、縦の格子) を最初に表にしておき、そのラインの
 * 縦の位置で決まる部分 (緑) との OR で書く (1 画素ずつ計算すると、消すのに 400〜500 µs かかり、垂直帰線に収まらなかったため)。
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
#define MCACHE_DC  0x2u              /* mcache_ctl (CSR 0x7CA) のデータキャッシュの有効 */

static inline uint32_t rd_mcycle(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

/*
 * 背景 (fb_demo の 1 回目と同じ)。赤は横、緑は縦の位置で決まり、青は一定、80 画素ごとの格子は白。
 * colpair[i] は横の 2 画素 (2i、2i + 1) の、赤と青の部分 (格子の画素は 0xFFFF)。ライン y の背景の 32 ビットは、横の格子の
 * ラインなら全部白、そうでなければ colpair[i] | (緑の部分を 2 画素分並べたもの)。格子の画素は 0xFFFF なので、OR しても白のまま
 */
static uint32_t colpair[FB_WIDTH / 2u];

static void make_colpair(void)
{
    for (uint32_t i = 0; i < FB_WIDTH / 2u; i++) {
        uint32_t p[2];
        for (uint32_t k = 0; k < 2u; k++) {
            uint32_t x = 2u * i + k;
            p[k] = ((x % 80u) == 0u) ? 0xFFFFu : ((((x * 25u) >> 10) << 11) | 16u);
        }
        colpair[i] = p[0] | (p[1] << 16);
    }
}

/* ライン y の、緑の部分を 2 画素分並べたもの (横の格子のラインは全部白) */
static inline uint32_t row_bits(uint32_t y, uint32_t *white)
{
    uint32_t g = ((y * 90u) >> 10) << 5;
    *white = (y % 80u) == 0u;
    return g | (g << 16);
}

/* 1 枚に背景を描く */
static void draw_bg(uint32_t base)
{
    for (uint32_t y = 0; y < FB_HEIGHT; y++) {
        volatile uint32_t *row = (volatile uint32_t *)(base + y * FB_STRIDE);
        uint32_t white;
        uint32_t g2 = row_bits(y, &white);
        for (uint32_t i = 0; i < FB_WIDTH / 2u; i++) row[i] = white ? 0xFFFFFFFFu : (colpair[i] | g2);
    }
}

/* (x0, y0) からの四角を、背景 (fill が 0) か四角の色 (fill が 1) で塗る。x0 は偶数 */
static void draw_sq(uint32_t base, uint32_t x0, uint32_t y0, uint32_t fill)
{
    const uint32_t sq2 = (uint32_t)SQ_COLOR | ((uint32_t)SQ_COLOR << 16);
    for (uint32_t y = y0; y < y0 + SQ; y++) {
        volatile uint32_t *row = (volatile uint32_t *)(base + y * FB_STRIDE) + x0 / 2u;
        if (fill) {
            for (uint32_t i = 0; i < SQ / 2u; i++) row[i] = sq2;
        } else {
            uint32_t white;
            uint32_t g2 = row_bits(y, &white);
            const uint32_t *cp = &colpair[x0 / 2u];
            for (uint32_t i = 0; i < SQ / 2u; i++) row[i] = white ? 0xFFFFFFFFu : (cp[i] | g2);
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

    fb_flush_dcache();   /* ローダーが起動してからキャッシュに入った書き込みを、メモリに書き出す */
    __asm__ volatile("csrc 0x7ca, %0" : : "r"(MCACHE_DC) : "memory");   /* データキャッシュを無効にする */
    printf("fb_animate: FB0 0x%08lx FB1 0x%08lx, square %lu, report every %lu frames\n", (unsigned long)FB0,
           (unsigned long)FB1, (unsigned long)SQ, (unsigned long)REPORT_FRAMES);
    /* 両方に背景と、最初の位置の四角を描き、FB0 を表示する */
    make_colpair();
    draw_bg(FB0);
    draw_bg(FB1);
    draw_sq(FB0, x, y, 1u);
    draw_sq(FB1, x, y, 1u);
    fb_sync();
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
        fb_sync();
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
