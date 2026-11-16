/*
 * 命令フェッチとデータの読み出しに何クロックかかるかを測るプログラム。ILM に置き (sw/ilm.ld)、
 * ROM のローダーで送って run する。
 *
 * 同じ命令を 64 個並べたものを 1,000 回繰り返し、その間の mcycle と minstret の差を出力する (ループの
 * 2 命令 (addi と bne) も数に含まれる)。
 *
 *   nop32   32 ビットの nop (addi x0, x0, 0)。1 回の命令フェッチで 1 命令
 *   nop16   16 ビットの nop (c.nop)。1 回の命令フェッチで 2 命令
 *   lw32    32 ビットの lw (スタック、つまり DLM から読む)。1 回の命令フェッチと 1 回のデータの読み出し
 */

#include <stdint.h>
#include <stdio.h>

#define LOOPS 1000

static inline uint32_t rd_mcycle(void)   { uint32_t v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }
static inline uint32_t rd_minstret(void) { uint32_t v; __asm__ volatile("csrr %0, minstret" : "=r"(v)); return v; }

static void report(const char *name, uint32_t c0, uint32_t i0, uint32_t c1, uint32_t i1)
{
    uint32_t c = c1 - c0, n = i1 - i0;
    printf("%-6s mcycle %8lu  minstret %8lu  CPI x100 %lu\n", name, (unsigned long)c, (unsigned long)n,
           (unsigned long)((uint64_t)c * 100u / n));
}

int main(void)
{
    uint32_t c0, i0, c1, i1;
    volatile uint32_t slot = 0;
    (void)slot;

    c0 = rd_mcycle(); i0 = rd_minstret();
    __asm__ volatile(
        ".option push\n.option norvc\n"
        "li t1, %0\n"
        ".option rvc\n.balign 4\n.option norvc\n"
        "1:\n.rept 64\naddi x0, x0, 0\n.endr\n"
        "addi t1, t1, -1\nbnez t1, 1b\n"
        ".option pop\n" :: "i"(LOOPS) : "t1");
    c1 = rd_mcycle(); i1 = rd_minstret();
    report("nop32", c0, i0, c1, i1);

    c0 = rd_mcycle(); i0 = rd_minstret();
    __asm__ volatile(
        ".option push\n.option norvc\n"
        "li t1, %0\n"
        ".option rvc\n.balign 4\n.option norvc\n"
        "1:\n.option rvc\n.rept 64\nc.nop\n.endr\n.option norvc\n"
        "addi t1, t1, -1\nbnez t1, 1b\n"
        ".option pop\n" :: "i"(LOOPS) : "t1");
    c1 = rd_mcycle(); i1 = rd_minstret();
    report("nop16", c0, i0, c1, i1);

    c0 = rd_mcycle(); i0 = rd_minstret();
    __asm__ volatile(
        ".option push\n.option norvc\n"
        "li t1, %1\n"
        ".option rvc\n.balign 4\n.option norvc\n"
        "1:\n.rept 64\nlw t0, 0(%0)\n.endr\n"
        "addi t1, t1, -1\nbnez t1, 1b\n"
        ".option pop\n" :: "r"(&slot), "i"(LOOPS) : "t0", "t1");
    c1 = rd_mcycle(); i1 = rd_minstret();
    report("lw32", c0, i0, c1, i1);

    return 0x600D;
}
