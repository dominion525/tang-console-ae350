/*
 * 転送の種類ごとに、1 回の読み書きにかかる CPU (CORE_CLK) のサイクル数を測る。
 * バスの構成を変える前後で比べるためのもので、合否は判定しない (結果は常に 0x600D)。
 *
 * 1 回あたりのサイクル数 = mcycle の差 ÷ 回数。ループの命令の分も含む (前後で同じプログラムを比べるため)。
 * 出力は「名前 サイクル数 × 10」(小数 1 桁を整数で出す)。
 */

#include <stdint.h>
#include <stdio.h>

#include "irq.h"
#include "uart.h"

#define N 64

static const volatile uint32_t rom_words[N] = { 1 };
static volatile uint32_t ddr_words[N];

#define MEASURE(name, body)                                   \
    do {                                                      \
        uint32_t c0 = csr_read(mcycle);                       \
        for (int i = 0; i < N; i++) { body; }                 \
        uint32_t c1 = csr_read(mcycle);                       \
        printf("%s %lu\n", name, (unsigned long)((c1 - c0) * 10u / N)); \
    } while (0)

int main(void)
{
    volatile uint32_t sink = 0;

    MEASURE("loop_only", (void)0);
    MEASURE("rom_read", sink += rom_words[i]);
    MEASURE("ddr_read", sink += ddr_words[i]);
    MEASURE("ddr_write", ddr_words[i] = (uint32_t)i);
    MEASURE("plmt_read", sink += PLMT_MTIME_LO);
    MEASURE("plic_read", sink += PLIC_PRIORITY(1));
    MEASURE("apb_read", sink += UART_STATUS);
    MEASURE("apb_write", GPINT = 0);
    (void)sink;
    return 0x600D;
}
