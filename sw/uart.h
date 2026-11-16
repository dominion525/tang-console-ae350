/*
 * APB_P* の先の UART (= rtl/apb_uart.v) のレジスタ (段 3、2026-11-09。段 3b で受信を足した)。
 */

#ifndef AE350_UART_H
#define AE350_UART_H

#include <stdint.h>

#define UART_BASE       0xF8000000u
#define UART_DATA       (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_STATUS     (*(volatile uint32_t *)(UART_BASE + 0x04))
#define UART_CTRL       (*(volatile uint32_t *)(UART_BASE + 0x08))

#define UART_CTRL_SEQ_HOLD    (1u << 0)   /* UART の合図 (= rtl/uart_reset_seq.v) を見張らない */

#define UART_STATUS_CAN_TAKE  (1u << 0)   /* 送信: 次の文字を待たずに受け取れる */
#define UART_STATUS_BUSY      (1u << 1)   /* 送信: 送信待ちか、送り出している途中の文字がある */
#define UART_STATUS_RX_READY  (1u << 2)   /* 受信: FIFO に文字がある */
#define UART_STATUS_OVERRUN   (1u << 3)   /* 受信: FIFO があふれて文字を落とした (読むと 0 に戻る) */
#define UART_STATUS_FRAME     (1u << 4)   /* 受信: ストップビットが 0 の文字を捨てた (読むと 0 に戻る) */

/* DATA への書き込みは、送信待ちの文字が残っているとバスを待たせるので、書くだけでよい */
static inline void uart_putc(char c)
{
    UART_DATA = (uint8_t)c;
}

/* 受信した文字が届くまで待ち、1 文字取り出す */
static inline char uart_getc(void)
{
    while ((UART_STATUS & UART_STATUS_RX_READY) == 0) {
    }
    return (char)UART_DATA;
}

#endif
