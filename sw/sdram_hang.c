/*
 * 外部メモリで動かす、終了しないプログラム。ローダーのテストで、固まったプログラムから UART のリセットシーケンス
 * (rtl/uart_reset_seq.v) でローダーに戻れることを確かめるのに使う。
 */

int main(void)
{
    for (;;) {
        __asm__ volatile("" : : : "memory");
    }
}
