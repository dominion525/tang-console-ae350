/*
 * DDR_H* の先の DDR3 (= board/tang_console/build.sh の MEM=ddr3、1 GB) に書いて読み返すプログラム (= 2026-11-13)。
 * ILM に置いて (= sw/ilm.ld)、ROM のローダーで送って run する。
 *
 * 最初にデータのキャッシュを切る (= mcache_ctl の bit 1。キャッシュが入っていると、書いた値をキャッシュから読み返すだけで
 * DDR3 を通らない)。書いた後と読む前に fence を置く (= AE350 は書き込みを溜めたまま先へ進み、番地の違う読み出しが追い越す)。
 *
 *   番地の線   0 と 2^5〜2^29 の番地に、番地ごとに違う 64 bit の値を書き、全部書いてから読み返す (= 番地の線が切れていたり
 *              つながっていたりすると、別の番地の値が見える)
 *   同じ行     32 byte (= DDR3 の IP の 1 回の命令) の中の 4 つの 8 byte に違う値を書き、読み返す (= 256 bit の中の並び)
 *   幅         8 byte を書いた後、1 / 2 / 4 byte を書き、8 byte で読み返す (= 書き込みのマスク)
 *   範囲の外   2^DDR3_BITS (= 既定 0x4000_0000、1 GB の外) を読むと例外 5 (= ahb_ddr3 / ahb_litedram のエラー応答)
 *
 * DDR3_BITS は DDR3 の大きさの bit 数 (= 既定 30、1 GB。LiteDRAM の版 (= MEM=litedram、512 MB) は 29。Makefile の ddr3_check_512)
 *
 * 全部合えば 0x600D を返す。Hazard3 (= Andes の CSR が無い) では、キャッシュを切る CSR が例外になり、sw/trap.c が次の
 * 命令から再開する。
 */

#include <stdint.h>
#include <stdio.h>
#include "trap.h"

#ifndef DDR3_BITS
#define DDR3_BITS 30
#endif

static int errors;

static void check64(const char *name, uintptr_t a, uint64_t got, uint64_t want)
{
    if (got != want) {
        errors++;
        printf("違う %s %08lx: %08lx%08lx (期待 %08lx%08lx)\n", name, (unsigned long)a, (unsigned long)(got >> 32),
               (unsigned long)got, (unsigned long)(want >> 32), (unsigned long)want);
    }
}

static inline void fence(void) { __asm__ volatile("fence" ::: "memory"); }

static uint64_t pattern(uintptr_t a) { return ((uint64_t)(a ^ 0x5A5A5A5Au) << 32) | (uint64_t)(~a); }

/*
 * 番地は volatile の変数を足して作る。番地 0 を定数のまま C で読み書きすると、GCC がヌルポインタ (= 未定義の動作) と
 * 見なして、それ以降の処理を消し ebreak に置き換える (= 2026-11-13 に、main がキャッシュを切った直後に ebreak で終わっていた)
 */
static volatile uintptr_t base0 = 0;
static inline volatile uint64_t *at64(uintptr_t a) { return (volatile uint64_t *)(base0 + a); }

int main(void)
{
    __asm__ volatile("csrc 0x7CA, %0" : : "r"(2u) : "memory");   // データのキャッシュを切る
    trap_cause = 0;
    fence();

    /* 番地の線 */
    *at64(0) = pattern(0);
    for (int b = 5; b < DDR3_BITS; b++) *at64((uintptr_t)1u << b) = pattern((uintptr_t)1u << b);
    fence();
    check64("番地の線", 0, *at64(0), pattern(0));
    for (int b = 5; b < DDR3_BITS; b++) {
        uintptr_t a = (uintptr_t)1u << b;
        check64("番地の線", a, *at64(a), pattern(a));
    }
    printf("番地の線 (= 0 と 2^5〜2^%d): 違った数 %d\n", DDR3_BITS - 1, errors);

    /* 同じ行 (= 32 byte) の中の 4 つの 8 byte */
    int e0 = errors;
    uintptr_t line = 0x00300000u;
    for (int i = 0; i < 4; i++) *(volatile uint64_t *)(line + 8 * i) = 0x1111111111111111ull * (uint64_t)(i + 1);
    fence();
    for (int i = 0; i < 4; i++) {
        check64("同じ行", line + 8 * i, *(volatile uint64_t *)(line + 8 * i), 0x1111111111111111ull * (uint64_t)(i + 1));
    }
    printf("同じ行の 4 つの 8 byte: 違った数 %d\n", errors - e0);

    /* 幅 (= 書き込みのマスク) */
    e0 = errors;
    uintptr_t w = 0x00400008u;
    *(volatile uint64_t *)w = 0x1122334455667788ull;
    *(volatile uint8_t *)(w + 1)  = 0xAB;
    *(volatile uint16_t *)(w + 4) = 0xBEEF;
    *(volatile uint8_t *)(w + 7)  = 0xCD;
    fence();
    check64("幅", w, *(volatile uint64_t *)w, 0xCD22BEEF5566AB88ull);   // byte 1 = AB、byte 4〜5 = BEEF、byte 7 = CD
    *(volatile uint32_t *)(w + 4) = 0x0BADF00Du;
    fence();
    check64("幅", w, *(volatile uint64_t *)w, 0x0BADF00D5566AB88ull);
    printf("1 / 2 / 4 byte の書き込み: 違った数 %d\n", errors - e0);

    /* 範囲の外 */
    (void)load_word_4byte((uintptr_t)1u << DDR3_BITS);
    printf("0x%08lx を読んだ例外 %lu (= 期待 5)\n", (unsigned long)(1u << DDR3_BITS), (unsigned long)trap_cause);
    if (trap_cause != 5) errors++;
    trap_cause = 0;

    printf("DDR3 の確認: %s (違った数 %d)\n", errors == 0 ? "OK" : "NG", errors);
    return errors == 0 ? 0x600D : 1;
}
