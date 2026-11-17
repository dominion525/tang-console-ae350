/*
 * CoreMark (EEMBC の CoreMark。ソースはリポジトリに含めず、make が build/ に取得する) を、この構成 (AE350 か
 * Hazard3 版) で動かすための定義。CoreMark のテンプレート (barebones/core_portme.h) が求める名前を、
 * この構成に合わせて新しく書いたもの。
 *
 * - 時間は mcycle (CPU のクロック数、64 ビット) で測る。1 MHz あたりのスコアは、繰り返しの回数と mcycle から出せる
 * - 秒に変換するための CPU の周波数は misa で判別する (core_portme.c)
 * - 出力は newlib の printf (sw/syscalls.c で UART に出す)
 * - 作業用のメモリはスタック (sw/sdram.ld でも sw/ae350.ld でも、DLM か DDR の決まった場所。どちらの CPU でも同じ)
 */

#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>
#include <stdint.h>

/* 0 にすると浮動小数点を使わない (Makefile の coremark_ilm_pub。小数を文字列に変換する部分を入れると ILM に収まらないため。
   スコアは mcycle と繰り返しの回数から出す) */
#ifndef HAS_FLOAT
#define HAS_FLOAT 1
#endif
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 1
/* 0 にすると、newlib の printf の代わりに CoreMark の簡易 printf (barebones/ee_printf.c) を使う (Makefile の
   coremark_ilm_pub。公表値と同じオプションでビルドするとコードが大きくなり、ILM に収まらないため) */
#ifndef HAS_PRINTF
#define HAS_PRINTF 1
#endif

#ifndef COMPILER_VERSION
#define COMPILER_VERSION "GCC" __VERSION__
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STACK"
#endif

typedef int16_t   ee_s16;
typedef uint16_t  ee_u16;
typedef int32_t   ee_s32;
typedef double    ee_f32;
typedef uint8_t   ee_u8;
typedef uint32_t  ee_u32;
typedef uintptr_t ee_ptr_int;
typedef size_t    ee_size_t;

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~3))

/* mcycle は 800 MHz では 32 ビットが 5.4 秒で一周するので、64 ビットで数える */
#define CORETIMETYPE uint64_t
typedef uint64_t CORE_TICKS;

#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STACK
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

extern ee_u32 default_num_contexts;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

#if HAS_PRINTF
#include <stdio.h>
#define ee_printf printf
#else
int ee_printf(const char *fmt, ...);
#endif

#endif
