/*
 * SDRAM で動かす、止まらないプログラム (= 2026-11-12。ローダーのテストで、固まったプログラムから UART の合図
 * (= ae350/rtl/uart_reset_seq.v) でローダーへ戻れることを確かめるのに使う)。
 */

int main(void)
{
    for (;;) {
        __asm__ volatile("" : : : "memory");
    }
}
