/*
 * フレームバッファの表示の回路 (rtl/fb_display.v) の制御レジスタと、使うための関数。
 *
 * 画素は RGB565 (16 ビット。赤 15〜11、緑 10〜5、青 4〜0)。画面は 1280 × 720 で、行の間隔は FB_STRIDE バイト。
 * フレームバッファの既定の場所は FB_DEFAULT_ADDR (SDRAM の 28 MB 目。sw/sdram.ld のヒープはその手前まで)。
 * CTRL と FB_BASE は、表示の回路がフレームの始まりで取り込む (書いた次のフレームから効く)。
 * ROM のローダーで起動したプログラムは、データキャッシュが有効になっている (sw/loader.c の do_run)。データキャッシュを
 * 有効のまま描いた場合は、描き終えたら fb_flush_dcache() でメモリに書き出す (書き出さないと、表示の回路は古い画素を読む)。
 * データキャッシュを無効にして描けば (mcache_ctl の bit 1 を 0 に)、書き込みは SDRAM に直接届く。
 */

#ifndef FB_H
#define FB_H

#include <stdint.h>

#define FB_WIDTH        1280u
#define FB_HEIGHT       720u
#define FB_STRIDE       2560u              /* バイト */
#define FB_DEFAULT_ADDR 0x01C00000u

#define FB_REG(off)     (*(volatile uint32_t *)(0xF8002000u + (off)))
#define FB_CTRL         FB_REG(0x00)       /* bit 0 ENABLE (0 はカラーバー、1 はフレームバッファ) */
#define FB_BASE         FB_REG(0x04)       /* フレームバッファの先頭のバイトアドレス (下位 4 ビットは 0。SDRAM の 32 MB の中のアドレスで、ビット 31〜25 は 0 になる。ラインのアドレスは 32 MB を超えると 0 に折り返す) */
#define FB_FRAME        FB_REG(0x08)       /* 表示したフレームの数 (垂直帰線の始まりで 1 増える) */
#define FB_STATUS       FB_REG(0x0C)       /* bit 0 UNDERRUN (1 を書くと 0 に戻る) */

#define FB_CTRL_ENABLE    1u
#define FB_STATUS_UNDERRUN 1u

/* RGB888 から RGB565 を作る */
static inline uint16_t fb_rgb(uint32_t r, uint32_t g, uint32_t b)
{
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

/*
 * データキャッシュをすべてライトバックして無効化する (mcctlcommand、CSR 0x7CC に L1D_WBINVAL_ALL。ROM のローダーと同じ)。
 * Hazard3 版 (シミュレーション) にはこの CSR がないので例外になり、sw/trap.c が次の命令から再開する。
 */
static inline void fb_flush_dcache(void)
{
    __asm__ volatile("csrw 0x7cc, %0" : : "r"(6u) : "memory");
}

/*
 * 書いた画素が SDRAM に届くのを待つ。表示を切り替える (CTRL、FB_BASE を書く) 前に呼ぶ。
 * SDRAM の前の回路 (rtl/ahb_sdram.v) は、書き込みをバッファに溜めて先に終わらせる。表示の回路は SDRAM を直接読むので、
 * バッファに残る書き込みを追い越して読むことがある。SDRAM の側の読み出し (ここではカウンタ、0x0300_0000) は、バッファが空に
 * なるまで待ってから行われるので、それを 1 回読む。前後の fence は、CPU の中に溜まった書き込みを先に出し切るため。
 * データキャッシュを有効にして描いた場合は、先に fb_flush_dcache() で書き出してから呼ぶ (キャッシュに当たった読み出しは、
 * SDRAM の側に届かない)。
 */
static inline void fb_sync(void)
{
    __asm__ volatile("fence" : : : "memory");
    (void)*(volatile uint32_t *)0x03000000u;
    __asm__ volatile("fence" : : : "memory");
}

#endif
