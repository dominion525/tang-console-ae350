/*
 * CoreMark を、この構成 (= AE350 か、Hazard3 の版) で動かすための関数 (= 2026-11-13。core_portme.h の説明を見る)。
 *
 * - 時間は mcycle を 64 bit で読む (= mcycleh を前後で読み、上位が繰り上がる途中を避ける)
 * - 秒に直すための CPU の周波数は misa で見分ける: F 拡張がある (= 本物の AE350、A25 は RV32 IMAFDC) なら 800 MHz、
 *   無い (= Hazard3) なら 40 MHz (= board/tang_console/top.v の CPU=hazard3 の CORE_CLK)。シミュレーションの中の Hazard3 は
 *   800 MHz で動くので、秒の値は合わない (= シミュレーションでは、結果が正しいかだけを見る)
 * - くり返しの回数は ITERATIONS で決める (= 0 なら CoreMark が 10 秒以上になるように自分で決める)
 */

#include "coremark.h"

#if !HAS_PRINTF
#include "uart.h"

/* CoreMark の小さい printf (= barebones/ee_printf.c) が 1 文字ずつ出す先 (= Makefile がその uart_send_char をこれに差し替える) */
void ae350_uart_putc(char c)
{
    uart_putc(c);
}
#endif

#ifndef ITERATIONS
#define ITERATIONS 0
#endif

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static uint64_t read_mcycle64(void)
{
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi));
        __asm__ volatile("csrr %0, mcycle" : "=r"(lo));
        __asm__ volatile("csrr %0, mcycleh" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* 実行した命令の数 (= 1 命令あたりのクロック数を出すため。2026-11-13) */
static uint64_t read_minstret64(void)
{
    uint32_t hi, lo, hi2;
    do {
        __asm__ volatile("csrr %0, minstreth" : "=r"(hi));
        __asm__ volatile("csrr %0, minstret" : "=r"(lo));
        __asm__ volatile("csrr %0, minstreth" : "=r"(hi2));
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

static uint32_t core_hz(void)
{
    uint32_t misa;
    __asm__ volatile("csrr %0, misa" : "=r"(misa));
    return (misa & (1u << ('F' - 'A'))) ? 800000000u : 40000000u;
}

static CORE_TICKS start_time_val, stop_time_val;
static uint64_t start_instret, stop_instret;

void start_time(void)
{
    start_instret  = read_minstret64();
    start_time_val = read_mcycle64();
}

void stop_time(void)
{
    stop_time_val = read_mcycle64();
    stop_instret  = read_minstret64();
}

CORE_TICKS get_time(void)
{
    return stop_time_val - start_time_val;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
#if HAS_FLOAT
    return (secs_ret)ticks / (secs_ret)core_hz();
#else
    /* 秒が 32 bit の整数のとき (= HAS_FLOAT=0)、64 bit の ticks のまま割ってから直す (= 800 MHz では ticks が 32 bit を超える) */
    return (secs_ret)(ticks / core_hz());
#endif
}

void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *)) ee_printf("ERROR! ee_ptr_int が番地を入れられない\n");
    if (sizeof(ee_u32) != 4) ee_printf("ERROR! ee_u32 が 32 bit でない\n");
    p->portable_id = 1;
}

void portable_fini(core_portable *p)
{
    uint64_t t = get_time();
    /* 1 MHz あたりの点数を出すための生の値 (= 周波数に関係なく、くり返しの回数と mcycle から出せる) */
    ee_printf("mcycle (64 bit) : %lu %lu\n", (unsigned long)(t >> 32), (unsigned long)(t & 0xFFFFFFFFu));
    uint64_t n = stop_instret - start_instret;
    ee_printf("minstret (64 bit) : %lu %lu\n", (unsigned long)(n >> 32), (unsigned long)(n & 0xFFFFFFFFu));
    ee_printf("CPU の周波数の見立て : %lu Hz (= misa で見分けた値)\n", (unsigned long)core_hz());
    p->portable_id = 0;
}
