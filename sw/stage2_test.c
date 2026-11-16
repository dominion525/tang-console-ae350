/*
 * 段 2 の確認用プログラム (2026-11-08)。
 * AE350 のアドレスマップとバスの形 (= ROM_H* と DDR_H*) で、命令の読み出し、データの読み書き、
 * エラー応答が動くかを確かめる。
 *
 * 戻り値は start.S が 0x0000_0000 に書き、TB (= tb/tb_mem.v) が表示する。
 *   0x600D  全部通った
 *   1〜     最初に失敗した確認の番号 (= 下の check の番号)
 */

#include <stdint.h>

#include "trap.h"

#define PASS 0x600D

/* .data: 初期値を ROM から写せているか */
static volatile uint32_t data_word = 0x12345678u;

/* .bss: 0 にできているか (= メモリモデルの初期値は 0xA5 で埋まっている) */
static volatile uint32_t bss_words[4];

/* .rodata: ROM から 8 / 16 / 32 bit で読めるか */
static const uint32_t rom_words[2] = { 0x89ABCDEFu, 0x01234567u };

/* DDR の読み書きに使う。64 bit の境界にそろえ、上下の 32 bit の両方を使う */
static volatile uint8_t buf[16] __attribute__((aligned(8)));

int main(void)
{
    const volatile uint8_t  *rom8  = (const volatile uint8_t *)rom_words;
    const volatile uint16_t *rom16 = (const volatile uint16_t *)rom_words;
    const volatile uint32_t *rom32 = (const volatile uint32_t *)rom_words;
    volatile uint16_t *buf16 = (volatile uint16_t *)buf;
    volatile uint32_t *buf32 = (volatile uint32_t *)buf;

    /* 1: .data */
    if (data_word != 0x12345678u) return 1;

    /* 2: .bss */
    for (int i = 0; i < 4; i++) {
        if (bss_words[i] != 0) return 2;
    }

    /* 3〜5: ROM の 32 / 16 / 8 bit の読み出し (= 上位・下位のバイトレーン) */
    if (rom32[0] != 0x89ABCDEFu || rom32[1] != 0x01234567u) return 3;
    if (rom16[0] != 0xCDEFu || rom16[1] != 0x89ABu || rom16[3] != 0x0123u) return 4;
    if (rom8[0] != 0xEFu || rom8[1] != 0xCDu || rom8[2] != 0xABu || rom8[3] != 0x89u || rom8[6] != 0x23u) return 5;

    /* 6: DDR の 32 bit の書き込みと読み出し (= 下位と上位の 32 bit) */
    buf32[0] = 0x11111111u;
    buf32[1] = 0x22222222u;
    if (buf32[0] != 0x11111111u || buf32[1] != 0x22222222u) return 6;

    /* 7: DDR の 8 bit の書き込み (= 上位の 32 bit の 4 レーン) を 32 bit で読む */
    buf[4] = 0xA1; buf[5] = 0xB2; buf[6] = 0xC3; buf[7] = 0xD4;
    if (buf32[1] != 0xD4C3B2A1u || buf32[0] != 0x11111111u) return 7;

    /* 8: DDR の 16 bit の書き込み (= 下位の 32 bit の 2 レーン) */
    buf16[0] = 0x3344u;
    buf16[1] = 0x5566u;
    if (buf32[0] != 0x55663344u || buf32[1] != 0xD4C3B2A1u) return 8;

    /* 9: DDR の 8 / 16 bit の読み出し */
    if (buf[5] != 0xB2u || buf[7] != 0xD4u || buf16[1] != 0x5566u || buf16[3] != 0xD4C3u) return 9;

    /* 10: 続けて書いてすぐ読む */
    for (uint32_t i = 0; i < 4; i++) {
        buf32[i] = 0xC0DE0000u + i;
        if (buf32[i] != 0xC0DE0000u + i) return 10;
    }

    /* 11: 割り当ての無い範囲 (= 0xC000_0000、AE350 では BMC) の読み出しはエラー応答 → 例外 5 */
    trap_cause = 0;
    (void)load_word_4byte(0xC0000000u);
    if (trap_cause != 5) return 11;

    /* 12: ROM の範囲への書き込みはエラー応答 → 例外 7 */
    trap_cause = 0;
    store_word_4byte(0x80000000u, 0xDEADBEEFu);
    if (trap_cause != 7) return 12;

    /* 13: ROM への書き込みで ROM の中身が変わっていない */
    if (rom32[0] != 0x89ABCDEFu) return 13;

    /* 14: 例外の後も DDR を読み書きできる */
    buf32[0] = 0x600D600Du;
    if (buf32[0] != 0x600D600Du) return 14;

    /*
     * 15〜17: メモリがエラー応答を返したとき (= TB の +rom_err=8000F000 +ddr_err=00008000、Makefile)。
     * ROM_H* / DDR_H* の HRESP = 1 が CPU に届き、読み出しは例外 5、書き込みは例外 7 になる
     */
    trap_cause = 0;
    (void)load_word_4byte(0x8000F000u);
    if (trap_cause != 5) return 15;
    trap_cause = 0;
    (void)load_word_4byte(0x00008000u);
    if (trap_cause != 5) return 16;
    trap_cause = 0;
    store_word_4byte(0x00008004u, 0x12345678u);
    if (trap_cause != 7) return 17;

    /* 18: エラー応答の後も、ROM と DDR を読み書きできる */
    buf32[1] = 0x0BADF00Du;
    if (buf32[1] != 0x0BADF00Du || rom32[1] != 0x01234567u) return 18;

    return PASS;
}
