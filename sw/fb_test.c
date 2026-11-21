/*
 * フレームバッファの表示の回路のテストプログラム (make test-fb。シミュレーション用、ROM に置く)。
 * フレームバッファ (既定の場所) の先頭の 4 ラインに模様を描き、データキャッシュをライトバックしてから CTRL を 1 にする。
 * 表示の回路が描いた値を出していることは、テストベンチ (tb/tb_mem.v の TB_FB) が、ENABLE になった後のフレームの先頭の
 * 4 ラインの画素を SDRAM の内容と比べて確かめる。このプログラムは FRAME が 3 増えるまで (ENABLE になったフレームとその次の
 * フレームを表示し終えるまで) 待ち、UNDERRUN を UART に出す。UART に出力する行は sw/fb_test_expected.txt と比べる (Makefile)。
 *
 * 戻り値は start.S が 0x0000_0000 に書き込み、テストベンチが表示する。
 *   0x600D  合格
 *   1       FB_BASE のリセット後の値が違う
 *   2       UNDERRUN が 1
 */

#include <stdint.h>
#include <stdio.h>

#include "fb.h"

#define PASS  0x600D
#define LINES 4u

int main(void)
{
    volatile uint16_t *fb = (volatile uint16_t *)FB_DEFAULT_ADDR;

    if (FB_BASE != FB_DEFAULT_ADDR) {
        printf("fb base %08lx\n", (unsigned long)FB_BASE);
        return 1;
    }
    /* 画素ごとに違う値 (横はグラデーション、縦は 1 ラインごとに色を変える) */
    for (uint32_t y = 0; y < LINES; y++) {
        for (uint32_t x = 0; x < FB_WIDTH; x++) {
            fb[y * (FB_STRIDE / 2u) + x] = (uint16_t)(fb_rgb(x & 0xFFu, (x >> 2) ^ (y * 64u), y * 85u) ^ (x >> 8));
        }
    }
    fb_flush_dcache();

    uint32_t f0 = FB_FRAME;
    FB_CTRL = FB_CTRL_ENABLE;
    while (FB_FRAME - f0 < 3u) {
    }
    uint32_t st = FB_STATUS;
    printf("fb ctrl %lu underrun %lu\n", (unsigned long)(FB_CTRL & 1u), (unsigned long)(st & FB_STATUS_UNDERRUN));
    return (st & FB_STATUS_UNDERRUN) ? 2 : PASS;
}
