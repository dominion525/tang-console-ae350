/*
 * 例外を確かめるための道具 (段 4 の後、2026-11-10。段 2 / 段 3 の確認用プログラムにあったものをまとめた)。
 *
 *   trap_cause         例外の mcause (= sw/trap.c が書く)
 *   load_word_4byte    4 byte の命令 (= 圧縮しない lw) で読む。例外のときは sw/trap.c が次の命令から再開する
 *   store_word_4byte   4 byte の命令 (= 圧縮しない sw) で書く
 */

#ifndef AE350_TRAP_H
#define AE350_TRAP_H

#include <stdint.h>

extern volatile uint32_t trap_cause;

static inline uint32_t load_word_4byte(uintptr_t addr)
{
    uint32_t v;
    __asm__ volatile(
        ".option push\n"
        ".option norvc\n"
        "lw %0, 0(%1)\n"
        ".option pop\n"
        : "=r"(v) : "r"(addr) : "memory");
    return v;
}

static inline void store_word_4byte(uintptr_t addr, uint32_t v)
{
    __asm__ volatile(
        ".option push\n"
        ".option norvc\n"
        "sw %0, 0(%1)\n"
        ".option pop\n"
        : : "r"(v), "r"(addr) : "memory");
}

#endif
