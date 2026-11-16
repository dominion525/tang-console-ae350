/*
 * 段 5 の確認用プログラム (2026-11-10)。
 * EXTS_H* (= CPU から FPGA 側の回路へ) と、ILM / DLM (= AE350 の中のメモリ) を確かめる。
 * UART に出す行は sw/stage5_expected.txt と比べる (= ae350/Makefile)。
 *
 *   EXTS_H*   0xE800_0000〜0xE800_0FFF に FPGA 側の 4 KB の RAM (= ae350/rtl/ahb_sram.v)。その外はエラー応答
 *   ILM       0xA000_0000〜 (64 KB)。関数を写して実行する
 *   DLM       0xA020_0000〜 (64 KB)
 *
 * 戻り値は start.S が 0x0000_0000 に書き、TB (= ae350/tb/tb_mem.v) が表示する。
 *   0x600D  全部通った
 *   1〜     最初に失敗した確認の番号 (= 下の check の番号)
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "irq.h"
#include "trap.h"

#define PASS 0x600D

#define EXTS_BASE 0xE8000000u
#define ILM_BASE  0xA0000000u
#define DLM_BASE  0xA0200000u

extern char _ilm_start[], _ilm_end[], _ilm_load[];

/* ILM で実行する関数 (= リンカスクリプトの .ilm_text。初期値は ROM にあり、main が写す) */
__attribute__((section(".ilm_text"), noinline)) int ilm_func(int x)
{
    return x * 3 + 1;
}

/* DLM に置く変数 (= リンカスクリプトの .dlm_bss) */
__attribute__((section(".dlm_bss"))) static volatile uint32_t dlm_words[4];

/* 8 / 16 / 32 bit の読み書きを、1 つのメモリの範囲で確かめる (= 64 bit の上下の 32 bit の両方を使う)。
   失敗したら 1〜6、通れば 0 */
static int check_memory(uintptr_t base)
{
    volatile uint32_t *w = (volatile uint32_t *)base;
    volatile uint16_t *h = (volatile uint16_t *)base;
    volatile uint8_t  *b = (volatile uint8_t *)base;

    w[0] = 0x11223344u;
    w[1] = 0x55667788u;
    if (w[0] != 0x11223344u || w[1] != 0x55667788u) return 1;
    b[4] = 0xA1; b[5] = 0xB2; b[6] = 0xC3; b[7] = 0xD4;
    if (w[1] != 0xD4C3B2A1u || w[0] != 0x11223344u) return 2;
    h[0] = 0xBEEF;
    h[1] = 0xDEAD;
    if (w[0] != 0xDEADBEEFu) return 3;
    if (b[0] != 0xEF || b[3] != 0xDE || h[2] != 0xB2A1u || h[3] != 0xD4C3u) return 4;
    for (uint32_t i = 2; i < 8; i++) w[i] = 0xC0DE0000u + i;
    for (uint32_t i = 2; i < 8; i++) {
        if (w[i] != 0xC0DE0000u + i) return 5;
    }
    if (w[0] != 0xDEADBEEFu || w[1] != 0xD4C3B2A1u) return 6;
    return 0;
}

int main(void)
{
    int r;

    /* ---- EXTS_H*: FPGA 側の RAM ---- */

    /* 1〜6: 8 / 16 / 32 bit の読み書き (= 先頭と、末尾の手前) */
    if ((r = check_memory(EXTS_BASE)) != 0) return r;
    if ((r = check_memory(EXTS_BASE + 0x0FC0u)) != 0) return 10 + r;

    /* 17: RAM の末尾の word と先頭の word は別 (= 4 KB の中で折り返さない) */
    REG32(EXTS_BASE + 0x0FFCu) = 0x0F0F0F0Fu;
    if (REG32(EXTS_BASE + 0x0FFCu) != 0x0F0F0F0Fu || REG32(EXTS_BASE) != 0xDEADBEEFu) return 17;

    /* 18 / 19: RAM の外 (= 0xE800_1000) は、FPGA 側の RAM がエラー応答 → 読み出しは例外 5、書き込みは例外 7 */
    trap_cause = 0;
    (void)load_word_4byte(EXTS_BASE + 0x1000u);
    if (trap_cause != 5) return 18;
    trap_cause = 0;
    store_word_4byte(EXTS_BASE + 0x1000u, 1);
    if (trap_cause != 7) return 19;

    /* 20: エラー応答の後も読み書きできる */
    if (REG32(EXTS_BASE) != 0xDEADBEEFu) return 20;
    printf("exts ok\n");

    /* ---- ILM / DLM ---- */

    /* 21〜26 / 31〜36: 8 / 16 / 32 bit の読み書き */
    if ((r = check_memory(ILM_BASE + 0x8000u)) != 0) return 20 + r;
    if ((r = check_memory(DLM_BASE + 0x8000u)) != 0) return 30 + r;

    /* 37: ILM と DLM は別のメモリ (= 同じオフセットに違う値を書いても混ざらない) */
    REG32(ILM_BASE + 0x9000u) = 0x1111u;
    REG32(DLM_BASE + 0x9000u) = 0x2222u;
    if (REG32(ILM_BASE + 0x9000u) != 0x1111u || REG32(DLM_BASE + 0x9000u) != 0x2222u) return 37;

    /* 38: DLM に置いた変数 (= .dlm_bss) */
    for (int i = 0; i < 4; i++) dlm_words[i] = 0xD1D10000u + (uint32_t)i;
    if ((uintptr_t)dlm_words < DLM_BASE || (uintptr_t)dlm_words >= DLM_BASE + 0x10000u) return 38;
    for (int i = 0; i < 4; i++) {
        if (dlm_words[i] != 0xD1D10000u + (uint32_t)i) return 39;
    }

    /* 40: ILM に関数を写して実行する (= 写した後に fence.i で、先読みした命令を捨てる) */
    memcpy(_ilm_start, _ilm_load, (size_t)(_ilm_end - _ilm_start));
    __asm__ volatile("fence.i" ::: "memory");
    if ((uintptr_t)&ilm_func < ILM_BASE || (uintptr_t)&ilm_func >= ILM_BASE + 0x10000u) return 40;
    int y = ilm_func(5);
    if (y != 16) return 41;
    printf("ilm dlm ok %d\n", y);

    /*
     * ---- EXTM_H* (= FPGA 側のマスタが AE350 のメモリを読み書きする。TB のモデルが sw/stage5_extm.txt を流す) ----
     * 1. 値を置いて「EXTM 1」の行を出す → TB が読んで照らす
     * 2. TB が値を書き、最後に DLM の 0xA020_1F00 に 0x600D を書く → 待ってから確かめる
     * 背景の転送 (= +extm_bg) が DDR の 0x0000_E000〜 を読み書きし続けているので、その間も CPU の読み書きが
     * 正しいことを確かめることにもなる
     */
    volatile uint32_t *ddr_out = (volatile uint32_t *)0x00009000u;
    volatile uint32_t *dlm_out = (volatile uint32_t *)(DLM_BASE + 0x1000u);
    volatile uint32_t *flag    = (volatile uint32_t *)(DLM_BASE + 0x1F00u);
    for (uint32_t i = 0; i < 8; i++) ddr_out[i] = 0xA5A50000u + i;
    for (uint32_t i = 0; i < 4; i++) dlm_out[i] = 0xD1D1D000u + i;
    *flag = 0;
    printf("EXTM 1\n");

    /* 42: TB の合図を待つ (= 届かなければ、ここで止まらずに失敗にする) */
    int waited = 0;
    while (*flag != 0x600Du) {
        if (++waited > 2000000) return 42;
    }

    /* 43〜48: TB が書いた値 */
    if (REG32(0x00009100u) != 0x11223344u || REG32(0x00009104u) != 0x55667788u) return 43;
    if (REG32(0x00009108u) != 0x89ABCDEFu || REG32(0x0000910Cu) != 0x01234567u) return 44;
    if (*(volatile uint8_t *)(DLM_BASE + 0x1100u) != 0xAB || *(volatile uint8_t *)(DLM_BASE + 0x1107u) != 0xCD ||
        *(volatile uint16_t *)(DLM_BASE + 0x1102u) != 0xBEEF) return 45;
    if (REG32(EXTS_BASE + 0x104u) != 0xCAFEBABEu || REG32(EXTS_BASE + 0x100u) != 0xFACEFEEDu) return 46;
    if (REG32(ILM_BASE + 0xF000u) != 0x12345678u) return 47;
    if (PLIC_PRIORITY(20) != 2) return 48;

    /* 49: 1 で置いた値は、EXTM_H* が読んだ後も変わっていない */
    for (uint32_t i = 0; i < 8; i++) {
        if (ddr_out[i] != 0xA5A50000u + i) return 49;
    }
    printf("extm ok\n");

    return PASS;
}
