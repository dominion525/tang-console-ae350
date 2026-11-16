/*
 * ROM に置くローダー (= 2026-11-12)。UART でプログラムを受けて DDR_H* の先 (= SDRAM の版は 0x0000_0000〜0x01FF_FFFF、DDR3 の版は
 * 0x0000_0000〜0x3FFF_FFFF) か ILM に書き、
 * 別の命令で、そこへ飛ぶ。送る (load) と動かす (run) を分けるので、送った中身を確かめてから動かせる。
 *
 *   Mac → ローダー                       ローダー → Mac
 *   (電源投入、プログラムから戻った)          READY ae350 loader
 *   load <番地 16 進 8 桁> <長さ 16 進 8 桁>  GO                (= 受けられる。Mac はこれを見てから中身を送る)
 *                                        ERR range / syntax (= Mac は中身を送らない)
 *   <中身 (= 長さ byte)>                  OK <長さ> <CRC-32>  (= 書いた後に SDRAM から読み直した中身で計算)
 *                                        ERR timeout        (= 次の byte が LOADER_TIMEOUT_MCYCLE 来なかった)
 *                                        ERR uart           (= 受けている間に、受信があふれたか、ストップビットが 0 の
 *                                                              文字を捨てた)
 *   run <番地 16 進 8 桁>                  RUN <番地>         (= 送り終わってから飛ぶ。この後はプログラムの出力)
 *   それ以外                              ERR command
 *
 * 返事は機械が読むので、短い ASCII の決まった語にする:
 *   ERR range    番地と長さが、DDR_H* の先 (= 上の範囲) にも ILM (= 0xA000_0000〜0xA000_FFFF) にも収まらない
 *   ERR syntax   load / run の形が違う (= 番地と長さは 16 進 8 桁、間は空白 1 つ)
 *   ERR command  load でも run でもない
 *   ERR timeout  中身の途中で、次の byte が来なかった
 *   ERR uart     中身を受けている間に、受信の誤りがあった
 *
 * - 命令は 1 行の文字 (= \r は捨てる)。番地と長さは 16 進 8 桁に決めて、読み取りを最小にする
 * - CRC-32 は zlib と同じ (= 多項式 0xEDB88320、初期値と最後の反転あり)。Ruby の Zlib.crc32 で照らせる。表は使わない
 *   (= 1 KB の ROM を使わない。読み直しは送る時間に比べて短い)
 * - 番地が 4 の倍数なら、4 byte をまとめて 32 bit で書き、32 bit で読み直す (= DDR_H* の転送を 4 分の 1 にする)
 * - 起動の始めに、データキャッシュを全部書き戻して捨てる (= mcctlcommand に L1D_WBINVAL_ALL。前に動かしたプログラムが
 *   書いた値が、後で新しいプログラムの上に書き戻されないように)。その後、命令キャッシュだけを入れ、データキャッシュは
 *   切ったまま受ける (= 書いた中身がそのまま SDRAM に届く)
 * - 中身を受けている間は、UART の合図 (= ae350/rtl/uart_reset_seq.v) の見張りを止める (= apb_uart の CTRL)。中身に合図の
 *   8 byte が並んでいても、リセットがかからない。受け終わったら (= OK、ERR timeout、ERR uart のどれでも) 見張りに戻す
 * - run では、UART が送り終わるのを待ち、fence (= 書き込みを終わらせる) と fence.i (= 命令キャッシュを捨てる) の後、
 *   データキャッシュも入れてから飛ぶ。飛んだ先は自分のスタートアップ (= sw/start.S) から始め、main から戻るとここへ戻る
 * - キャッシュの CSR (= mcache_ctl 0x7CA、mcctlcommand 0x7CC) は、モックの Hazard3 には無い。例外になり、次の命令から
 *   再開する (= sw/trap.c)
 */

#include <stdint.h>
#include "uart.h"
#include "trap.h"

#ifndef LOADER_TIMEOUT_MCYCLE
#define LOADER_TIMEOUT_MCYCLE 800000000u   /* 1 秒 (= CORE_CLK 800 MHz)。シミュレーションでは短くして作る */
#endif

#define SDRAM_END        0x02000000u   /* SDRAM の版 (= 32 MB) */
#define DDR3_END         0x40000000u   /* DDR3 の版 (= 1 GB。board/tang_console/build.sh の MEM=ddr3、2026-11-14) */
#define ILM_BASE         0xA0000000u   /* ILM にも置ける (= 2026-11-13。SDRAM の待ちを除いて CPU の速さを比べるため) */
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

/* 受けている間に見た、受信の誤りの印 (= STATUS の bit 3 / 4 は読むと 0 に戻るので溜める) */
static uint32_t rx_errors;

/* 1 byte を受ける。LOADER_TIMEOUT_MCYCLE の間に届かなければ -1 */
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

/* 1 行を受ける (= \n まで。\r は捨てる。長すぎる行は切り詰める) */
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
 * DDR_H* の先のメモリの終わり。起動のときに 0x0200_0000 (= SDRAM の 32 MB の位置) を読んでみて、例外になれば SDRAM の版
 * (= ahb_sdram がエラー応答を返す)、ならなければ DDR3 の版 (= 1 GB) とみなす
 */
static uint32_t mem_end;

static void find_mem_end(void)
{
    trap_cause = 0;
    (void)load_word_4byte(SDRAM_END);
    mem_end    = (trap_cause == 0) ? DDR3_END : SDRAM_END;
    trap_cause = 0;
}

/* 番地と長さが、DDR_H* の先のメモリか ILM のどちらかに収まるか */
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
    (void)UART_STATUS;   /* 前の印を消す */
    rx_errors = 0;
    UART_CTRL = UART_CTRL_SEQ_HOLD;   /* 中身を受けている間は、中身に合図が並んでいてもリセットしない */
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
    /* 4 byte に満たない残り */
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
