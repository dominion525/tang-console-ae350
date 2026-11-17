/*
 * 例外と割り込みの処理。start.S の trap_entry から呼ばれる。
 *
 *   例外    mcause を trap_cause に書き、例外を起こした命令 (4 バイトの命令に限る) の次から再開する。
 *           テストプログラムが、エラー応答による例外を確かめるのに使う
 *   割り込み irq_handler(mcause) を呼び、割り込まれた命令から再開する。irq_handler はプログラムが定義する
 *           (定義しなければ何もしない)
 */

#include <stdint.h>

volatile uint32_t trap_cause;

__attribute__((weak)) void irq_handler(uint32_t mcause)
{
    (void)mcause;
}

uintptr_t trap_handler(uint32_t mcause, uintptr_t mepc)
{
    if (mcause & 0x80000000u) {
        irq_handler(mcause);
        return mepc;
    }
    trap_cause = mcause;
    return mepc + 4;
}
