/*
 * ROM に置くローダー。UART でプログラムを受信して DDR_H* の先 (SDRAM 版は 0x0000_0000〜0x01FF_FFFF、DDR3 版は
 * 0x0000_0000〜0x3FFF_FFFF) か ILM に書き込み、
 * 別のコマンドでそこへジャンプする。送信 (load) と実行 (run) を分けるので、送った内容を確かめてから実行できる。
 *
 *   Mac → ローダー                          ローダー → Mac
 *   (電源投入時、プログラムから戻ったとき)     READY ae350 loader
 *   load <アドレス 16 進 8 桁> <長さ 16 進 8 桁>  GO                (受信可能。Mac はこれを確認してからデータを送る)
 *                                           ERR range / syntax (Mac はデータを送らない)
 *   <データ (長さ分のバイト)>                  OK <長さ> <CRC-32>  (書き込んだ後にメモリから読み直したデータで計算する)
 *                                           ERR timeout        (次のバイトが LOADER_TIMEOUT_MCYCLE の間に届かなかった)
 *                                           ERR uart           (受信中に、受信バッファがあふれたか、ストップビットが 0 の
 *                                                                 文字を捨てた)
 *   run <アドレス 16 進 8 桁>                 RUN <アドレス>     (送信し終わってからジャンプする。この後はプログラムの出力)
 *   それ以外                                 ERR command
 *
 * 応答はプログラムが読むので、短い ASCII の決まった語にする:
 *   ERR range    アドレスと長さが、DDR_H* の先 (上の範囲) にも ILM (0xA000_0000〜0xA000_FFFF) にも収まらない
 *   ERR syntax   load か run の形式が違う (アドレスと長さは 16 進 8 桁、区切りは空白 1 つ)
 *   ERR command  load でも run でもない
 *   ERR timeout  データの途中で、次のバイトが届かなかった
 *   ERR uart     データの受信中に、受信エラーがあった
 *
 * - コマンドは 1 行のテキスト (\r は捨てる)。アドレスと長さを 16 進 8 桁に固定して、解析を最小限にする
 * - CRC-32 は zlib と同じ (多項式 0xEDB88320、初期値と最後の反転あり)。Ruby の Zlib.crc32 で照合できる。テーブルは使わない
 *   (1 KB の ROM を使わないため。読み直しにかかる時間は、送信にかかる時間に比べて短い)
 * - アドレスが 4 の倍数なら、4 バイトをまとめて 32 ビットで書き込み、32 ビットで読み直す (DDR_H* の転送を 4 分の 1 にする)
 * - 起動時に、データキャッシュをすべてライトバックして無効化する (mcctlcommand に L1D_WBINVAL_ALL。前に実行したプログラムが
 *   書き込んだ値が、後から新しいプログラムの上に書き戻されないようにするため)。その後、命令キャッシュだけを有効にし、
 *   データキャッシュは無効のまま受信する (書き込んだデータがそのままメモリに届く)
 * - データの受信中は、UART のリセットシーケンス (rtl/uart_reset_seq.v) の監視を止める (apb_uart の CTRL)。データに
 *   シーケンスの 8 バイトが含まれていても、リセットがかからない。受信し終わったら (OK、ERR timeout、ERR uart のどれでも)
 *   監視を再開する
 * - run では、UART の送信が終わるのを待ち、fence (書き込みを完了させる) と fence.i (命令キャッシュを無効化する) の後、
 *   データキャッシュも有効にしてからジャンプする。ジャンプ先は自分のスタートアップルーチン (sw/start.S) から始まり、
 *   main から戻るとここに戻る
 * - キャッシュの CSR (mcache_ctl 0x7CA、mcctlcommand 0x7CC) は Hazard3 にはない。例外になり、次の命令から
 *   再開する (sw/trap.c)
 */

#include <stdint.h>
#include "uart.h"
#include "trap.h"

#ifndef LOADER_TIMEOUT_MCYCLE
#define LOADER_TIMEOUT_MCYCLE 800000000u   /* 1 秒 (CORE_CLK 800 MHz)。シミュレーション用には短くしてビルドする */
#endif

#define SDRAM_END        0x02000000u   /* SDRAM 版 (32 MB) */
#define DDR3_END         0x40000000u   /* DDR3 版 (1 GB。board/tang_console/build.sh の MEM=ddr3) */
#define ILM_BASE         0xA0000000u   /* ILM にも置ける (外部メモリのウェイトを除いて CPU の速さを比べるため) */
#define ILM_END          0xA0010000u
#define MCACHE_IC        0x1u
#define MCACHE_DC        0x2u
#define L1D_WBINVAL_ALL  6u
#define UART_ERRORS      (UART_STATUS_OVERRUN | UART_STATUS_FRAME)

static void put_str(const char *s)
{
    while (*s != '\0') {
        uart_putc(*s);
        s = s + 1;
    }
}

static void put_hex(uint32_t v)
{
    for (int i = 28; i >= 0; i = i - 4) uart_putc("0123456789abcdef"[(v >> i) & 0xFu]);
}

static void reply(const char *s)
{
    put_str(s);
    put_str("\r\n");
}

static uint32_t mcycle(void)
{
    uint32_t v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

static uint32_t crc32_byte(uint32_t crc, uint32_t b)
{
    crc = crc ^ (b & 0xFFu);
    for (int k = 0; k < 8; k = k + 1) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    return crc;
}

/* 受信中に検出した受信エラーのフラグ (STATUS の bit 3 と bit 4 は読むと 0 に戻るので溜める) */
static uint32_t rx_errors;

/* 1 バイト受信する。LOADER_TIMEOUT_MCYCLE の間に届かなければ -1 */
static int getc_timeout(void)
{
    uint32_t t0 = mcycle();
    for (;;) {
        uint32_t st = UART_STATUS;
        rx_errors = rx_errors | (st & UART_ERRORS);
        if (st & UART_STATUS_RX_READY) return (int)(UART_DATA & 0xFFu);
        if (mcycle() - t0 >= LOADER_TIMEOUT_MCYCLE) return -1;
    }
}

/* 1 行受信する (\n まで。\r は捨てる。長すぎる行は切り詰める) */
static void get_line(char *buf, uint32_t max)
{
    uint32_t n = 0;
    for (;;) {
        char c = uart_getc();
        if (c == '\n') break;
        if (c == '\r') continue;
        if (n + 1 < max) {
            buf[n] = c;
            n = n + 1;
        }
    }
    buf[n] = '\0';
}

/* 16 進 8 桁を読む。読めなければ *ok を 0 にする */
static uint32_t parse_hex8(const char *s, int *ok)
{
    uint32_t v = 0;
    for (int i = 0; i < 8; i = i + 1) {
        uint32_t c = (uint8_t)s[i];
        uint32_t d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        else {
            *ok = 0;
            return 0;
        }
        v = (v << 4) | d;
    }
    return v;
}

/*
 * DDR_H* の先のメモリの終端。起動時に 0x0200_0000 (SDRAM の 32 MB の位置) を読んでみて、例外になれば SDRAM 版
 * (ahb_sdram がエラー応答を返す)、ならなければ DDR3 版 (1 GB) とみなす
 */
static uint32_t mem_end;

static void find_mem_end(void)
{
    trap_cause = 0;
    (void)load_word_4byte(SDRAM_END);
    mem_end    = (trap_cause == 0) ? DDR3_END : SDRAM_END;
    trap_cause = 0;
}

/* アドレスと長さが、DDR_H* の先のメモリか ILM のどちらかに収まるか */
static int fits(uint32_t addr, uint32_t len)
{
    if (addr < mem_end) return len <= mem_end - addr;
    if (addr >= ILM_BASE && addr < ILM_END) return len <= ILM_END - addr;
    return 0;
}

static int starts_with(const char *s, const char *p)
{
    while (*p != '\0') {
        if (*s != *p) return 0;
        s = s + 1;
        p = p + 1;
    }
    return 1;
}

static void do_load(uint32_t addr, uint32_t len)
{
    (void)UART_STATUS;   /* 前のフラグをクリアする */
    rx_errors = 0;
    UART_CTRL = UART_CTRL_SEQ_HOLD;   /* データの受信中は、データにシーケンスが含まれていてもリセットしない */
    reply("GO");
    const int words = (addr & 3u) == 0;
    uint32_t w = 0;
    for (uint32_t i = 0; i < len; i = i + 1) {
        int c = getc_timeout();
        if (c < 0) {
            UART_CTRL = 0;
            reply((rx_errors != 0) ? "ERR uart" : "ERR timeout");
            return;
        }
        if (words) {
            w = w | ((uint32_t)c << (8u * (i & 3u)));
            if ((i & 3u) == 3u) {
                *(volatile uint32_t *)(uintptr_t)(addr + i - 3u) = w;
                w = 0;
            }
        } else {
            *(volatile uint8_t *)(uintptr_t)(addr + i) = (uint8_t)c;
        }
    }
    UART_CTRL = 0;
    /* 4 バイトに満たない残り */
    if (words) {
        for (uint32_t i = len & ~3u; i < len; i = i + 1) *(volatile uint8_t *)(uintptr_t)(addr + i) = (uint8_t)(w >> (8u * (i & 3u)));
    }
    if (rx_errors != 0) {
        reply("ERR uart");
        return;
    }
    __asm__ volatile("fence" : : : "memory");
    uint32_t crc = 0xFFFFFFFFu;
    uint32_t i = 0;
    if (words) {
        for (; i + 4u <= len; i = i + 4u) {
            uint32_t v = *(volatile uint32_t *)(uintptr_t)(addr + i);
            crc = crc32_byte(crc, v);
            crc = crc32_byte(crc, v >> 8);
            crc = crc32_byte(crc, v >> 16);
            crc = crc32_byte(crc, v >> 24);
        }
    }
    for (; i < len; i = i + 1) crc = crc32_byte(crc, *(volatile uint8_t *)(uintptr_t)(addr + i));
    put_str("OK ");
    put_hex(len);
    put_str(" ");
    put_hex(crc ^ 0xFFFFFFFFu);
    put_str("\r\n");
}

static void do_run(uint32_t addr)
{
    put_str("RUN ");
    put_hex(addr);
    put_str("\r\n");
    while (UART_STATUS & UART_STATUS_BUSY) {
    }
    __asm__ volatile("fence\n\tfence.i" : : : "memory");
    __asm__ volatile("csrs 0x7ca, %0" : : "r"(MCACHE_DC) : "memory");
    ((void (*)(void))(uintptr_t)addr)();
    for (;;) {
    }
}

int main(void)
{
    __asm__ volatile("csrw 0x7cc, %0" : : "r"(L1D_WBINVAL_ALL) : "memory");
    __asm__ volatile("csrc 0x7ca, %0" : : "r"(MCACHE_DC) : "memory");
    __asm__ volatile("csrs 0x7ca, %0" : : "r"(MCACHE_IC) : "memory");
    find_mem_end();
    reply("READY ae350 loader");
    char line[40];
    for (;;) {
        get_line(line, sizeof line);
        int ok = 1;
        if (starts_with(line, "load ")) {
            uint32_t addr = parse_hex8(line + 5, &ok);
            uint32_t len  = parse_hex8(line + 14, &ok);
            if (!ok || line[13] != ' ' || line[22] != '\0') reply("ERR syntax");
            else if (!fits(addr, len)) reply("ERR range");
            else do_load(addr, len);
        } else if (starts_with(line, "run ")) {
            uint32_t addr = parse_hex8(line + 4, &ok);
            if (!ok || line[12] != '\0') reply("ERR syntax");
            else if (!fits(addr, 0)) reply("ERR range");
            else do_run(addr);
        } else if (line[0] != '\0') {
            reply("ERR command");
        }
    }
}
