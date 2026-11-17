/*
 * DDR_H* の先の DDR3 (board/tang_console/build.sh の MEM=ddr3、1 GB) に書き込んで読み返すプログラム。
 * ILM に置き (sw/ilm.ld)、ROM のローダーで送って run する。
 *
 * 最初にデータキャッシュを無効にする (mcache_ctl の bit 1。キャッシュが有効だと、書き込んだ値をキャッシュから読み返すだけで
 * DDR3 を通らない)。書き込みの後と読み出しの前に fence を置く (AE350 は書き込みを溜めたまま先へ進み、アドレスの異なる読み出しが追い越す)。
 *
 *   アドレス線   アドレス 0 と 2^5〜2^29 に、アドレスごとに異なる 64 ビットの値を書き込み、すべて書き込んでから読み返す
 *                (アドレス線が断線や短絡していると、別のアドレスの値が見える)
 *   同じライン   32 バイト (DDR3 の IP の 1 コマンド分) の中の 4 つの 8 バイトに異なる値を書き込み、読み返す (256 ビットの中の並び)
 *   幅           8 バイトを書き込んだ後、1、2、4 バイトを書き込み、8 バイトで読み返す (書き込みマスク)
 *   範囲外       2^DDR3_BITS (既定値 0x4000_0000。1 GB の外) を読むと例外 5 (ahb_ddr3 と ahb_litedram のエラー応答)
 *
 * DDR3_BITS は DDR3 の容量のビット数 (既定値 30 で 1 GB。DDR3 1 個の構成 (512 MB) では 29。Makefile の ddr3_check_512)
 *
 * すべて一致すれば 0x600D を返す。Hazard3 (Andes の CSR がない) では、キャッシュを無効にする CSR が例外になり、sw/trap.c が次の
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
        printf("mismatch %s %08lx: %08lx%08lx (expected %08lx%08lx)\n", name, (unsigned long)a, (unsigned long)(got >> 32),
               (unsigned long)got, (unsigned long)(want >> 32), (unsigned long)want);
    }
}

static inline void fence(void) { __asm__ volatile("fence" ::: "memory"); }

static uint64_t pattern(uintptr_t a) { return ((uint64_t)(a ^ 0x5A5A5A5Au) << 32) | (uint64_t)(~a); }

/*
 * アドレスは volatile の変数を足して作る。アドレス 0 を定数のまま C で読み書きすると、GCC がヌルポインタ (未定義動作) と
 * 見なして、それ以降の処理を削除し ebreak に置き換える (main がキャッシュを無効にした直後に ebreak で終わっていた)
 */
static volatile uintptr_t base0 = 0;
static inline volatile uint64_t *at64(uintptr_t a) { return (volatile uint64_t *)(base0 + a); }

int main(void)
{
    __asm__ volatile("csrc 0x7CA, %0" : : "r"(2u) : "memory");   // データキャッシュを無効にする
    trap_cause = 0;
    fence();

    /* アドレス線 */
    *at64(0) = pattern(0);
    for (int b = 5; b < DDR3_BITS; b++) *at64((uintptr_t)1u << b) = pattern((uintptr_t)1u << b);
    fence();
    check64("address lines", 0, *at64(0), pattern(0));
    for (int b = 5; b < DDR3_BITS; b++) {
        uintptr_t a = (uintptr_t)1u << b;
        check64("address lines", a, *at64(a), pattern(a));
    }
    printf("address lines (0 and 2^5 to 2^%d): mismatches %d\n", DDR3_BITS - 1, errors);

    /* 同じライン (32 バイト) の中の 4 つの 8 バイト */
    int e0 = errors;
    uintptr_t line = 0x00300000u;
    for (int i = 0; i < 4; i++) *(volatile uint64_t *)(line + 8 * i) = 0x1111111111111111ull * (uint64_t)(i + 1);
    fence();
    for (int i = 0; i < 4; i++) {
        check64("same line", line + 8 * i, *(volatile uint64_t *)(line + 8 * i), 0x1111111111111111ull * (uint64_t)(i + 1));
    }
    printf("four 8-byte words in one line: mismatches %d\n", errors - e0);

    /* 幅 (書き込みマスク) */
    e0 = errors;
    uintptr_t w = 0x00400008u;
    *(volatile uint64_t *)w = 0x1122334455667788ull;
    *(volatile uint8_t *)(w + 1)  = 0xAB;
    *(volatile uint16_t *)(w + 4) = 0xBEEF;
    *(volatile uint8_t *)(w + 7)  = 0xCD;
    fence();
    check64("width", w, *(volatile uint64_t *)w, 0xCD22BEEF5566AB88ull);   // バイト 1 = AB、バイト 4〜5 = BEEF、バイト 7 = CD
    *(volatile uint32_t *)(w + 4) = 0x0BADF00Du;
    fence();
    check64("width", w, *(volatile uint64_t *)w, 0x0BADF00D5566AB88ull);
    printf("byte, halfword, and word writes: mismatches %d\n", errors - e0);

    /* 範囲外 */
    (void)load_word_4byte((uintptr_t)1u << DDR3_BITS);
    printf("exception on reading 0x%08lx: %lu (expected 5)\n", (unsigned long)(1u << DDR3_BITS), (unsigned long)trap_cause);
    if (trap_cause != 5) errors++;
    trap_cause = 0;

    printf("DDR3 check: %s (mismatches %d)\n", errors == 0 ? "OK" : "NG", errors);
    return errors == 0 ? 0x600D : 1;
}
