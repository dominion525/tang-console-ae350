/*
 * PLMT、PLIC、GP_INT を駆動するレジスタ、割り込みの CSR の定義。
 *
 *   PLMT   0xE600_0000  MUG1029 の表 15-1 の配置 (hart 0)
 *   PLIC   0xE400_0000  Andes NCEPLIC100 (RISC-V の PLIC の標準の配置 + Andes の拡張、ターゲット 0)
 *   GPINT  0xF800_1000  ファブリック側のレジスタ (rtl/apb_gpint.v)。下位 16 ビットが GP_INT[15:0]
 */

#ifndef AE350_IRQ_H
#define AE350_IRQ_H

#include <stdint.h>

#define REG32(addr) (*(volatile uint32_t *)(addr))

/* PLMT */
#define PLMT_BASE        0xE6000000u
#define PLMT_MTIME_LO    REG32(PLMT_BASE + 0x00)
#define PLMT_MTIME_HI    REG32(PLMT_BASE + 0x04)
#define PLMT_MTIMECMP_LO REG32(PLMT_BASE + 0x08)
#define PLMT_MTIMECMP_HI REG32(PLMT_BASE + 0x0C)

/* PLIC */
#define PLIC_BASE        0xE4000000u
#define PLIC_FEATURE     REG32(PLIC_BASE + 0x000000)   /* Andes: bit0 PREEMPT、bit1 VECTORED */
#define PLIC_PRIORITY(id) REG32(PLIC_BASE + 4u * (id))
#define PLIC_PENDING     REG32(PLIC_BASE + 0x001000)
#define PLIC_TRIGGER     REG32(PLIC_BASE + 0x001080)   /* Andes: 0 レベル、1 エッジ (読み出し専用) */
#define PLIC_NUMBER      REG32(PLIC_BASE + 0x001100)   /* Andes: {ターゲット数, ソース数} */
#define PLIC_VERSION     REG32(PLIC_BASE + 0x001104)   /* Andes: {最大優先度, バージョン} */
#define PLIC_ENABLE      REG32(PLIC_BASE + 0x002000)
#define PLIC_THRESHOLD   REG32(PLIC_BASE + 0x200000)
#define PLIC_CLAIM       REG32(PLIC_BASE + 0x200004)
#define PLIC_PPS         REG32(PLIC_BASE + 0x200400)   /* Andes: プリエンプトされた優先度のスタック (ワード 0) */
/* ターゲット 1 (S モードへの通知。実機では mip の bit 9) */
#define PLIC_ENABLE1     REG32(PLIC_BASE + 0x002080)
#define PLIC_THRESHOLD1  REG32(PLIC_BASE + 0x201000)
#define PLIC_CLAIM1      REG32(PLIC_BASE + 0x201004)
#define PLIC_PPS1        REG32(PLIC_BASE + 0x201400)

#define PLIC_FEATURE_PREEMPT  (1u << 0)
#define PLIC_FEATURE_VECTORED (1u << 1)

/* GP_INT のソース番号 (MUG1029 の表 4-2) */
#define PLIC_ID_GP0      4u
#define PLIC_ID_GP(n)    ((n) == 0 ? PLIC_ID_GP0 : 10u + (n))   /* GP1〜GP15 → 11〜25 */

/* GP_INT を駆動するレジスタ */
#define GPINT            REG32(0xF8001000u)

/* mcause */
#define MCAUSE_M_TIMER   0x80000007u
#define MCAUSE_M_EXT     0x8000000Bu

/* mie と mip のビット、mstatus.MIE */
#define MIP_MTIP         (1u << 7)
#define MIP_MEIP         (1u << 11)
#define MSTATUS_MIE      (1u << 3)

#define csr_read(csr) ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_set(csr, bits) __asm__ volatile("csrs " #csr ", %0" : : "r"(bits))
#define csr_clear(csr, bits) __asm__ volatile("csrc " #csr ", %0" : : "r"(bits))

/* mtime を 64 ビットで読む: 上位、下位、上位の順に読み、2 回の上位が同じなら、間に桁上がりを挟んでいない */
static inline uint64_t mtime_read(void)
{
    uint32_t hi, lo, hi2;
    do {
        hi  = PLMT_MTIME_HI;
        lo  = PLMT_MTIME_LO;
        hi2 = PLMT_MTIME_HI;
    } while (hi != hi2);
    return ((uint64_t)hi << 32) | lo;
}

/* mtimecmp を 64 ビットで書く: 下位を最大値にしてから上位、下位の順に書き、途中で余計な割り込みを出さない */
static inline void mtimecmp_write(uint64_t v)
{
    PLMT_MTIMECMP_LO = 0xFFFFFFFFu;
    PLMT_MTIMECMP_HI = (uint32_t)(v >> 32);
    PLMT_MTIMECMP_LO = (uint32_t)v;
}

#endif
