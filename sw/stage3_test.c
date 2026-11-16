/*
 * 段 3 の確認用プログラム (2026-11-09)。
 * APB_P* の先の UART に、newlib の printf と、UART のレジスタへの直接の書き込みで文字を出す。
 * 出る文字は sw/stage3_expected.txt と比べる (= ae350/Makefile)。
 *
 * 戻り値は start.S が 0x0000_0000 に書き、TB (= ae350/tb/tb_mem.v) が表示する。
 *   0x600D  全部通った
 *   1〜     最初に失敗した確認の番号 (= 下の check の番号)
 */

#include <stdint.h>
#include <stdio.h>

#include "trap.h"
#include "uart.h"

#define PASS 0x600D

int main(void)
{
    /* 行 1: newlib の printf (= 標準出力のバッファ、_write、_sbrk を通る) */
    printf("Hello, world!\n");

    /* 行 2: 書式つきの printf */
    printf("%d %x %s\n", 12345, 0xbeef, "ok");

    /* 1: printf が出し終わった後も、STATUS が読める (= bit 2 以上は 0) */
    if ((UART_STATUS & ~(UART_STATUS_CAN_TAKE | UART_STATUS_BUSY)) != 0) return 1;

    /* 行 3: DATA への 8 bit の書き込み (= PSTRB の下位 1 bit) */
    *(volatile uint8_t *)UART_BASE = 'A';
    *(volatile uint8_t *)UART_BASE = '\n';

    /* 2: 続けて書いた直後は送信中 */
    if ((UART_STATUS & UART_STATUS_BUSY) == 0) return 2;

    /* 3: 割り当ての無いレジスタの読み出しは PSLVERR → エラー応答 → 例外 5 (= 0x08 は CTRL になったので 0x0C で見る) */
    trap_cause = 0;
    (void)load_word_4byte(UART_BASE + 0x0C);
    if (trap_cause != 5) return 3;

    /* 4: 割り当ての無いレジスタへの書き込みは例外 7 */
    trap_cause = 0;
    store_word_4byte(UART_BASE + 0x0C, 0x41);
    if (trap_cause != 7) return 4;

    /* 5: STATUS の書き込みも例外にならない範囲 (= 読み出し専用だが、割り当てはある)。文字は出ない */
    trap_cause = 0;
    store_word_4byte(UART_BASE + 0x04, 0x41);
    if (trap_cause != 0) return 5;

    /* 6: EXTS_H* の範囲のうち、FPGA 側の RAM (= 0xE800_0000〜0xE800_0FFF) の外は、RAM がエラー応答 → 例外 5 */
    trap_cause = 0;
    (void)load_word_4byte(0xE8002000u);
    if (trap_cause != 5) return 6;

    /* 7: 送り終わるまで待つと、BUSY が 0 に戻る */
    while (UART_STATUS & UART_STATUS_BUSY) {
    }
    if ((UART_STATUS & UART_STATUS_CAN_TAKE) == 0) return 7;

    /* 8: まだ何も送られていないので、受信の FIFO は空で、エラーも無い */
    if ((UART_STATUS & (UART_STATUS_RX_READY | UART_STATUS_OVERRUN | UART_STATUS_FRAME)) != 0) return 8;

    /*
     * 段 3b: 標準入力 (= sw/stage3_input.txt を TB が送る)。
     * 「READY」の行を出すと、TB が入力ファイルの次の区切りまでを送ってくる。
     */

    /* 行 4〜5: fgets で 1 行、getchar で続きの 3 文字 */
    printf("READY line\n");
    char line[32];
    if (fgets(line, sizeof line, stdin) == NULL) return 9;
    for (char *p = line; *p; p++) {
        if (*p == '\n') *p = '\0';
    }
    printf("got [%s]\n", line);
    int c1 = getchar();
    int c2 = getchar();
    int c3 = getchar();
    if (c3 != '\n') return 10;
    printf("getchar %c %c\n", c1, c2);

    /*
     * 行 6: FIFO (= 256 文字。ae350/rtl/apb_uart.v の RX_DEPTH) を超えて送られると、あふれた分を落とし、STATUS の bit 3 が立つ。
     * TB は 257 文字送る (= あふれた後に届く文字は無いので、取り出す文字数が決まる)。数と、頭の 16 文字と最後の 1 文字を出す
     */
    printf("READY fifo\n");
    uint32_t seen = 0;
    while ((seen & UART_STATUS_OVERRUN) == 0) {
        seen |= UART_STATUS;           /* bit 3 は読むと 0 に戻るので、見たものを溜める */
    }
    if (UART_STATUS & UART_STATUS_OVERRUN) return 11;   /* 読んだので 0 に戻っている */
    static char fifo[300];
    int n = 0;
    while ((UART_STATUS & UART_STATUS_RX_READY) && n < 299) {
        fifo[n++] = (char)UART_DATA;
    }
    printf("fifo %d %.16s %c\n", n, fifo, (n > 0) ? fifo[n - 1] : '-');

    /* 7: 空の FIFO から読むと 0 */
    if (UART_DATA != 0) return 12;

    /* 行 7: ストップビットが 0 の文字は捨てられ、STATUS の bit 4 が立つ。その次の文字は受けられる */
    printf("READY frame\n");
    seen = 0;
    while ((seen & UART_STATUS_RX_READY) == 0) {
        seen |= UART_STATUS;           /* bit 4 は読むと 0 に戻るので、待つ間に見たものを溜める */
    }
    char after = (char)UART_DATA;
    if ((seen & UART_STATUS_FRAME) == 0) return 13;
    if (UART_STATUS & UART_STATUS_FRAME) return 14;     /* 読んだので 0 に戻っている */
    printf("frame %c\n", after);

    /* 行 8: 例外の後も、入力の後も文字を出せる */
    printf("bye\n");

    return PASS;
}
