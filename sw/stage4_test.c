/*
 * 段 4 の確認用プログラム (2026-11-10)。
 * PLMT のタイマ割り込みと、GP_INT → PLIC → 外部割り込みの経路を確かめる。
 * UART に出す行は sw/stage4_expected.txt と比べる (= ae350/Makefile)。
 *
 * 戻り値は start.S が 0x0000_0000 に書き、TB (= ae350/tb/tb_mem.v) が表示する。
 *   0x600D  全部通った
 *   1〜     最初に失敗した確認の番号 (= 下の check の番号)
 */

#include <stdint.h>
#include <stdio.h>

#include "irq.h"
#include "trap.h"

#define PASS 0x600D

static volatile int      timer_hits;
static volatile int      ext_hits;
static volatile uint32_t last_cause;
static volatile uint32_t ext_ids[4];

/* GP_INT のビットを下げ、APB の書き込みが終わったことを読み返しで確かめる */
static void gpint_lower(uint32_t bits)
{
    GPINT &= ~bits;
    (void)GPINT;
}

static uint32_t gpint_bit_of(uint32_t id)
{
    if (id == PLIC_ID_GP0) return 1u << 0;
    if (id >= 11 && id <= 25) return 1u << (id - 10);
    return 0;
}

void irq_handler(uint32_t mcause)
{
    last_cause = mcause;
    if (mcause == MCAUSE_M_TIMER) {
        mtimecmp_write(UINT64_MAX);      /* 次に設定するまで止める */
        timer_hits++;
    } else if (mcause == MCAUSE_M_EXT) {
        uint32_t id = PLIC_CLAIM;
        if (ext_hits < 4) ext_ids[ext_hits] = id;
        gpint_lower(gpint_bit_of(id));   /* ソースを下げてから complete する (= レベル) */
        PLIC_CLAIM = id;
        ext_hits++;
    }
}

/*
 * 割り込みを待つ。「回数を確かめる → wfi」の間に割り込みが来て処理まで終わると、wfi は次の割り込みまで
 * 眠り続ける。そのため、確かめてから wfi に入るまでは mstatus.MIE を 0 にしておく (= wfi は、mie で許した
 * 割り込みが pending になれば MIE が 0 でも起きる)。起きたら MIE を一度 1 にして、割り込みの処理を走らせる
 */
static void wait_until(volatile int *counter, int value)
{
    csr_clear(mstatus, MSTATUS_MIE);
    while (*counter < value) {
        __asm__ volatile("wfi");
        csr_set(mstatus, MSTATUS_MIE);
        csr_clear(mstatus, MSTATUS_MIE);
    }
    csr_set(mstatus, MSTATUS_MIE);
}

/*
 * PLIC のレジスタを書いた後の mip.MEIP: PLIC の meip は次のサイクルに変わり、Hazard3 は irq の入力を
 * レジスタで受けてから mip に見せるので、少し待ってから読む
 */
static int meip_settled(void)
{
    for (volatile int i = 0; i < 8; i++) {
    }
    return (csr_read(mip) & MIP_MEIP) != 0;
}

/* PLIC の pending のビットが立つまで待つ (= GP_INT は 2 段の同期を通る) */
static int wait_pending(uint32_t mask)
{
    for (int i = 0; i < 1000; i++) {
        if ((PLIC_PENDING & mask) == mask) return 1;
    }
    return 0;
}

int main(void)
{
    /*
     * 22: PLIC (= NCEPLIC100) の初期値。どれも、まだ何も書いていない状態で見る
     *   feature 0、priority 1 (= 標準の PLIC と違う)、threshold 0、PPS 0、
     *   0x1100 = {ターゲット 2, ソース 31}、0x1104 = {最大優先度 3, 版 1}、0x1080 = 0 (= 全ソースがレベル) (= 実機の値)
     */
    if (PLIC_FEATURE != 0 || PLIC_PRIORITY(1) != 1 || PLIC_PRIORITY(31) != 1 || PLIC_THRESHOLD != 0 ||
        PLIC_PPS != 0 || PLIC_PENDING != 0 || PLIC_ENABLE != 0) return 22;
    if (PLIC_NUMBER != ((2u << 16) | 31u) || PLIC_VERSION != ((3u << 16) | 1u) || PLIC_TRIGGER != 0) return 23;

    /* ---- PLMT ---- */

    /* 1: mtime が進む */
    uint64_t t0 = mtime_read();
    for (volatile int i = 0; i < 100; i++) {
    }
    uint64_t t1 = mtime_read();
    if (t1 <= t0) return 1;

    /*
     * 21: mcycle と minstret は、CSR に何も書かなくてもリセット直後から進む (= AE350 の A25 と同じ。
     * Gowin の BSP の delay.c は mcountinhibit に触れずに mcycle で時間を測る)
     */
    uint32_t cyc0 = csr_read(mcycle);
    uint32_t ins0 = csr_read(minstret);
    for (volatile int i = 0; i < 100; i++) {
    }
    uint32_t cyc1 = csr_read(mcycle);
    uint32_t ins1 = csr_read(minstret);
    if (cyc1 - cyc0 < 100 || ins1 - ins0 < 100) return 21;

    /*
     * 45: mcycle は CORE_CLK、mtime は AHB_CLK で進むので、進み方の比は 2 つのクロックの周波数の比になる
     * (= リファレンスデザインでは 800 / 100 = 8)。TB が比 × 256 を 0x0000_0008 に置く。差は 2% まで
     */
    uint32_t want256 = *(volatile uint32_t *)0x00000008u;
    uint32_t mt_a  = PLMT_MTIME_LO;
    uint32_t cyc_a = csr_read(mcycle);
    for (volatile int i = 0; i < 2000; i++) {
    }
    uint32_t mt_b  = PLMT_MTIME_LO;
    uint32_t cyc_b = csr_read(mcycle);
    uint32_t got256 = (uint32_t)(((uint64_t)(cyc_b - cyc_a) * 256u) / (mt_b - mt_a));
    if (want256 == 0 || got256 * 50u < want256 * 49u || got256 * 50u > want256 * 51u) return 45;

    /* 2: mtimecmp の初期値は最大で、mip.MTIP は立っていない */
    if (PLMT_MTIMECMP_LO != 0xFFFFFFFFu || PLMT_MTIMECMP_HI != 0xFFFFFFFFu) return 2;
    if (csr_read(mip) & MIP_MTIP) return 3;

    /* 4: 割り込みを許していなくても、mtime が mtimecmp に達すると mip.MTIP が立つ。mtimecmp を戻すと下がる */
    mtimecmp_write(mtime_read() + 20);
    int seen = 0;
    for (int i = 0; i < 1000 && !seen; i++) seen = (csr_read(mip) & MIP_MTIP) != 0;
    if (!seen || timer_hits != 0) return 4;
    mtimecmp_write(UINT64_MAX);
    if (csr_read(mip) & MIP_MTIP) return 5;

    /* 6: タイマ割り込みを 3 回受ける */
    csr_set(mie, MIP_MTIP);
    csr_set(mstatus, MSTATUS_MIE);
    for (int n = 1; n <= 3; n++) {
        mtimecmp_write(mtime_read() + 50);
        wait_until(&timer_hits, n);
        if (last_cause != MCAUSE_M_TIMER) return 6;
    }
    csr_clear(mie, MIP_MTIP);
    printf("timer %d\n", timer_hits);

    /* ---- PLIC (割り込みで受ける) ---- */

    /* 7: GP0 / GP15 / GP1 を 1 本ずつ立て、外部割り込みで claim する */
    uint32_t gps[3] = { 0, 15, 1 };
    for (int k = 0; k < 3; k++) PLIC_PRIORITY(PLIC_ID_GP(gps[k])) = 1;
    PLIC_ENABLE = (1u << PLIC_ID_GP(0)) | (1u << PLIC_ID_GP(15)) | (1u << PLIC_ID_GP(1));
    PLIC_THRESHOLD = 0;
    csr_set(mie, MIP_MEIP);
    for (int k = 0; k < 3; k++) {
        GPINT = 1u << gps[k];
        wait_until(&ext_hits, k + 1);
        if (last_cause != MCAUSE_M_EXT) return 7;
    }
    if (GPINT != 0 || PLIC_PENDING != 0) return 8;
    printf("ext %lu %lu %lu\n", (unsigned long)ext_ids[0], (unsigned long)ext_ids[1], (unsigned long)ext_ids[2]);

    /* ---- PLIC (割り込みを止めて、レジスタで確かめる) ---- */
    csr_clear(mstatus, MSTATUS_MIE);

    /* 9: 優先度: GP2 (= 12、優先度 1) と GP3 (= 13、優先度 3) を同時に立てると、claim は 13、12、0 の順 */
    PLIC_PRIORITY(12) = 1;
    PLIC_PRIORITY(13) = 3;
    PLIC_ENABLE = (1u << 12) | (1u << 13);
    GPINT = (1u << 2) | (1u << 3);
    if (!wait_pending((1u << 12) | (1u << 13))) return 9;
    if (!meip_settled()) return 10;
    uint32_t c1 = PLIC_CLAIM;
    uint32_t c2 = PLIC_CLAIM;
    uint32_t c3 = PLIC_CLAIM;
    gpint_lower((1u << 2) | (1u << 3));
    PLIC_CLAIM = c1;
    PLIC_CLAIM = c2;
    printf("prio %lu %lu %lu\n", (unsigned long)c1, (unsigned long)c2, (unsigned long)c3);

    /* 11: しきい値: 優先度 3 のソースは、しきい値 3 では通知されず、しきい値 2 では通知される */
    PLIC_THRESHOLD = 3;
    GPINT = 1u << 3;
    if (!wait_pending(1u << 13)) return 11;
    if (meip_settled()) return 12;
    if (PLIC_CLAIM != 0) return 13;
    PLIC_THRESHOLD = 2;
    if (!meip_settled()) return 14;
    uint32_t c4 = PLIC_CLAIM;
    gpint_lower(1u << 3);
    PLIC_CLAIM = c4;
    PLIC_THRESHOLD = 0;
    printf("threshold %lu\n", (unsigned long)c4);

    /* 15: レベル: ソースが立ったまま complete すると、また pending になり、もう一度 claim できる */
    PLIC_PRIORITY(PLIC_ID_GP0) = 1;
    PLIC_ENABLE = 1u << PLIC_ID_GP0;
    GPINT = 1u << 0;
    if (!wait_pending(1u << PLIC_ID_GP0)) return 15;
    uint32_t c5 = PLIC_CLAIM;
    if (PLIC_PENDING & (1u << PLIC_ID_GP0)) return 16;   /* claim で落ちている */
    PLIC_CLAIM = c5;                                      /* ソースは立ったまま */
    if (!wait_pending(1u << PLIC_ID_GP0)) return 17;
    uint32_t c6 = PLIC_CLAIM;
    gpint_lower(1u << 0);
    PLIC_CLAIM = c6;
    printf("level %lu %lu\n", (unsigned long)c5, (unsigned long)c6);

    /* 18: enable していないソースは、pending になっても通知されない */
    PLIC_PRIORITY(14) = 1;
    PLIC_ENABLE = 0;
    GPINT = 1u << 4;
    if (!wait_pending(1u << 14)) return 18;
    if (meip_settled()) return 19;
    if (PLIC_CLAIM != 0) return 20;
    gpint_lower(1u << 4);
    printf("disabled ok\n");

    /* ---- PLIC: Andes NCEPLIC100 の拡張 ---- */

    /* 18 で立てたままのソース 14 の pending を、claim / complete で片付ける */
    PLIC_ENABLE = 1u << 14;
    uint32_t c14 = PLIC_CLAIM;
    PLIC_CLAIM = c14;
    PLIC_ENABLE = 0;
    if (c14 != 14 || PLIC_PENDING != 0) return 44;

    /* 24: feature は 2 bit を読み書きできる。上位は 0。trigger は読み出し専用 */
    PLIC_FEATURE = 0xFFFFFFFFu;
    if (PLIC_FEATURE != (PLIC_FEATURE_PREEMPT | PLIC_FEATURE_VECTORED)) return 24;
    PLIC_FEATURE = 0;
    PLIC_TRIGGER = 0xFFFFFFFFu;
    if (PLIC_TRIGGER != 0) return 25;

    /* 26: 優先度は 2 bit (= 0〜3)。上位のビットは持たない。ソースは 1〜31 (= 実機と同じ) */
    PLIC_PRIORITY(20) = 15;
    if (PLIC_PRIORITY(20) != 3) return 26;
    PLIC_PRIORITY(20) = 1;
    PLIC_PRIORITY(31) = 2;
    PLIC_ENABLE = 0xFFFFFFFFu;
    if (PLIC_PRIORITY(31) != 2 || PLIC_ENABLE != 0xFFFFFFFEu) return 27;
    PLIC_PRIORITY(31) = 1;
    PLIC_ENABLE = 0;

    /* 28: pending は書いて立てられる (= OR)。0 を書いても落ちない。落とせるのは claim だけ */
    PLIC_PENDING = 1u << 20;
    PLIC_PENDING = 0;
    if (PLIC_PENDING != (1u << 20)) return 28;
    PLIC_ENABLE = 1u << 20;
    uint32_t c7 = PLIC_CLAIM;
    if (PLIC_PENDING != 0) return 29;
    PLIC_CLAIM = c7;
    PLIC_ENABLE = 0;
    printf("swpend %lu\n", (unsigned long)c7);

    /*
     * 30: complete は、そのソースの enable が立っていなくても効く (= 実機で確かめた)。enable を落として complete
     * しても、ゲートウェイは再開し、ソースが立ったままなら、enable を戻した後に pending が立つ
     */
    PLIC_PRIORITY(PLIC_ID_GP0) = 1;
    PLIC_ENABLE = 1u << PLIC_ID_GP0;
    GPINT = 1u << 0;
    if (!wait_pending(1u << PLIC_ID_GP0)) return 30;
    uint32_t c8 = PLIC_CLAIM;
    PLIC_ENABLE = 0;
    PLIC_CLAIM = c8;                                   /* enable が無くても効く */
    PLIC_ENABLE = 1u << PLIC_ID_GP0;
    if (!wait_pending(1u << PLIC_ID_GP0)) return 31;   /* ソースが立ったままなので、また立つ */
    uint32_t c9 = PLIC_CLAIM;
    gpint_lower(1u << 0);
    PLIC_CLAIM = c9;
    PLIC_ENABLE = 0;
    printf("gateway %lu %lu\n", (unsigned long)c8, (unsigned long)c9);

    /*
     * 33: PREEMPT (= 入れ子)。claim で今の threshold を PPS に積み、claim したソースの優先度を threshold に書く。
     * complete で PPS の最も高い優先度を threshold に戻す。threshold 以下のソースは通知されない
     *   GP1 (= 11) 優先度 1、GP2 (= 12) 優先度 3、GP3 (= 13) 優先度 2
     */
    PLIC_FEATURE = PLIC_FEATURE_PREEMPT;
    PLIC_THRESHOLD = 0;
    PLIC_PRIORITY(11) = 1;
    PLIC_PRIORITY(12) = 3;
    PLIC_PRIORITY(13) = 2;
    PLIC_ENABLE = (1u << 11) | (1u << 12) | (1u << 13);
    GPINT = 1u << 1;
    if (!wait_pending(1u << 11)) return 33;
    uint32_t p1 = PLIC_CLAIM;                                            /* 11 */
    if (PLIC_THRESHOLD != 1 || PLIC_PPS != 0x1u) return 34;             /* 0 を積んで 1 に */
    GPINT = (1u << 1) | (1u << 2) | (1u << 3);
    if (!wait_pending((1u << 12) | (1u << 13))) return 35;
    if (!meip_settled()) return 36;                                      /* 3 > 1 */
    uint32_t p2 = PLIC_CLAIM;                                            /* 12 */
    if (PLIC_THRESHOLD != 3 || PLIC_PPS != 0x3u) return 37;             /* 1 を積んで 3 に */
    if (meip_settled()) return 38;                                       /* 13 の優先度 2 は 3 以下 */
    gpint_lower(1u << 2);
    PLIC_CLAIM = p2;
    if (PLIC_THRESHOLD != 1 || PLIC_PPS != 0x1u) return 39;             /* 1 に戻る */
    if (!meip_settled()) return 40;                                      /* 13 の優先度 2 は 1 より大きい */
    uint32_t p3 = PLIC_CLAIM;                                            /* 13 */
    if (PLIC_THRESHOLD != 2 || PLIC_PPS != 0x3u) return 41;
    gpint_lower(1u << 3);
    PLIC_CLAIM = p3;
    if (PLIC_THRESHOLD != 1 || PLIC_PPS != 0x1u) return 42;
    gpint_lower(1u << 1);
    PLIC_CLAIM = p1;
    if (PLIC_THRESHOLD != 0 || PLIC_PPS != 0) return 43;
    PLIC_FEATURE = 0;
    PLIC_ENABLE = 0;
    printf("preempt %lu %lu %lu\n", (unsigned long)p1, (unsigned long)p2, (unsigned long)p3);

    /* ---- APB の先: どこにも当たらないアドレスと、GP_INT のレジスタの割り当ての無いオフセット ---- */

    /* 46: 0xF800_2000 はどの周辺回路にも当たらない → PSLVERR → 例外 5 / 7 */
    trap_cause = 0;
    (void)load_word_4byte(0xF8002000u);
    if (trap_cause != 5) return 46;
    trap_cause = 0;
    store_word_4byte(0xF8002000u, 1);
    if (trap_cause != 7) return 47;

    /* 48: GP_INT のレジスタは 0x00 だけ。0x04 は PSLVERR → 例外 5 */
    trap_cause = 0;
    (void)load_word_4byte(0xF8001004u);
    if (trap_cause != 5) return 48;

    /* ---- GP_INT の 16 本すべて (= GP0 → 4、GP1〜GP15 → 11〜25) ---- */
    uint32_t ids[16];
    uint32_t all = 0;
    for (int n = 0; n < 16; n++) {
        PLIC_PRIORITY(PLIC_ID_GP(n)) = 1;
        all |= 1u << PLIC_ID_GP(n);
    }
    PLIC_ENABLE = all;
    for (int n = 0; n < 16; n++) {
        GPINT = 1u << n;
        if (!wait_pending(1u << PLIC_ID_GP(n))) return 49;
        ids[n] = PLIC_CLAIM;
        gpint_lower(1u << n);
        PLIC_CLAIM = ids[n];
        if (ids[n] != PLIC_ID_GP(n)) return 50;
    }
    PLIC_ENABLE = 0;
    printf("gp");
    for (int n = 0; n < 16; n++) printf(" %lu", (unsigned long)ids[n]);
    printf("\n");

    /* ---- PLIC: 優先度 3 と 2、32 bit でない書き込み ---- */

    /* 51: 優先度 3 (= GP2、12) と 2 (= GP1、11) を同時に立てると、3 から claim される */
    PLIC_PRIORITY(11) = 2;
    PLIC_PRIORITY(12) = 3;
    PLIC_ENABLE = (1u << 11) | (1u << 12);
    GPINT = (1u << 1) | (1u << 2);
    if (!wait_pending((1u << 11) | (1u << 12))) return 51;
    uint32_t q1 = PLIC_CLAIM;
    uint32_t q2 = PLIC_CLAIM;
    gpint_lower((1u << 1) | (1u << 2));
    PLIC_CLAIM = q1;
    PLIC_CLAIM = q2;
    PLIC_ENABLE = 0;
    printf("prio3 %lu %lu\n", (unsigned long)q1, (unsigned long)q2);

    /* 52: PLIC は 32 bit の書き込みだけを受ける。1 byte の書き込みは無視される */
    *(volatile uint8_t *)(PLIC_BASE + 4u * 11) = 1;
    if (PLIC_PRIORITY(11) != 2) return 52;

    /* ---- PLMT: 8 / 16 bit の書き込み、割り当ての無いオフセット、mtime の書き込みと繰り上がり ---- */

    /* 53: mtimecmp に 1 byte / 2 byte で書くと、そのバイトだけが変わる */
    mtimecmp_write(UINT64_MAX);
    *(volatile uint8_t *)(PLMT_BASE + 0x09) = 0x12;
    *(volatile uint16_t *)(PLMT_BASE + 0x0E) = 0x3456;
    if (PLMT_MTIMECMP_LO != 0xFFFF12FFu || PLMT_MTIMECMP_HI != 0x3456FFFFu) return 53;
    mtimecmp_write(UINT64_MAX);

    /* 54: 割り当ての無いオフセット (0x10) は、読むと 0、書いても何も起きない */
    REG32(PLMT_BASE + 0x10) = 0x55u;
    if (REG32(PLMT_BASE + 0x10) != 0) return 54;

    /* 55: mtime は書ける。下位が一周すると上位に繰り上がる */
    PLMT_MTIME_HI = 0;
    PLMT_MTIME_LO = 0xFFFFFF00u;
    if (PLMT_MTIME_HI != 0) return 55;
    int carried = 0;
    for (int i = 0; i < 1000 && !carried; i++) carried = (PLMT_MTIME_HI == 1);
    if (!carried || PLMT_MTIME_LO > 0x00010000u) return 56;
    printf("plmt ok\n");

    /* 57: PLIC の PPS はソフトウェアから読み書きできる (= AX45 18.4.11、診断のため)。優先度 0〜3 の 4 bit を持つ (= 実機と同じ) */
    PLIC_PPS = 0x0000842Au;
    if (PLIC_PPS != 0x0000000Au) return 57;
    PLIC_PPS = 0;

    /* 58: GP_INT のレジスタは、書いたバイトレーンだけが変わる (= PSTRB) */
    GPINT = 0;
    *(volatile uint8_t *)0xF8001001u = 0x80;          /* 上位のバイトだけ: GP15 */
    if (GPINT != 0x8000u) return 58;
    *(volatile uint8_t *)0xF8001000u = 0x01;          /* 下位のバイトだけ: GP0 */
    if (GPINT != 0x8001u) return 59;
    GPINT = 0;
    printf("pps gpint ok\n");

    /*
     * 72: APB_P* の 1 / 2 byte の読み書きは、PADDR が 4 byte に揃い、PWDATA は書くバイトのレーンだけに値が入る
     * (= 実機と同じ形。0xF800_F000 の PADDR を読み返すレジスタで見る。0x1C は読み出しの PADDR の下位 8 bit を並べて返す)
     */
    *(volatile uint8_t *)0xF800F023u = 0xAB;
    if (REG32(0xF800F000u) != 0xF800F020u || REG32(0xF800F004u) != 0x8u || REG32(0xF800F008u) != 0xAB000000u) return 72;
    *(volatile uint16_t *)0xF800F012u = 0xBEEF;
    if (REG32(0xF800F000u) != 0xF800F010u || REG32(0xF800F004u) != 0xCu || REG32(0xF800F008u) != 0xBEEF0000u) return 73;
    if (*(volatile uint8_t *)0xF800F01Du != 0x1Cu || *(volatile uint16_t *)0xF800F01Eu != 0x1C1Cu) return 74;
    printf("apb subword ok\n");

    /* 75: CPU の識別子は、実機の A25 と同じ値 (= Tang Console で読んだ値) */
    if (csr_read(mvendorid) != 0x31Eu || csr_read(marchid) != 0x80000A25u || csr_read(mimpid) != 0x160u) return 75;
    printf("ids ok\n");

    /*
     * 60: PLIC のターゲット 1 (= 実機では S モードへの通知)。enable、threshold、claim / complete、PPS をターゲットごとに
     * 持ち、pending とゲートウェイは共通。feature (= PREEMPT) も共通。CPU には届かないので、レジスタだけで見る
     * 先に、58〜59 で GP_INT を立てたときの pending (= 25 と 4) を claim / complete で片付ける
     */
    PLIC_ENABLE = 0xFFFFFFFEu;
    for (int n = 0; n < 40; n++) {
        uint32_t c = PLIC_CLAIM;
        if (c == 0) break;
        PLIC_CLAIM = c;
    }
    PLIC_ENABLE = 0;
    if (PLIC_PENDING != 0) return 71;
    if (PLIC_ENABLE1 != 0 || PLIC_THRESHOLD1 != 0 || PLIC_PPS1 != 0) return 60;
    PLIC_ENABLE1 = 0xFFFFFFFFu;
    PLIC_THRESHOLD1 = 0xFFFFFFFFu;
    PLIC_PPS1 = 0xFFFFFFFFu;
    if (PLIC_ENABLE1 != 0xFFFFFFFEu || PLIC_THRESHOLD1 != 3 || PLIC_PPS1 != 0xFu) return 61;
    if (PLIC_ENABLE != 0 || PLIC_THRESHOLD != 0 || PLIC_PPS != 0) return 62;   /* ターゲット 0 は変わらない */
    PLIC_ENABLE1 = 0;
    PLIC_THRESHOLD1 = 0;
    PLIC_PPS1 = 0;

    /* 63: ターゲット 1 だけが enable したソースは、ターゲット 1 で claim でき、ターゲット 0 では claim できない */
    PLIC_PRIORITY(PLIC_ID_GP0) = 1;
    PLIC_ENABLE1 = 1u << PLIC_ID_GP0;
    GPINT = 1u << 0;
    if (!wait_pending(1u << PLIC_ID_GP0)) return 63;
    if (meip_settled()) return 64;                                        /* ターゲット 0 には通知しない */
    if (PLIC_CLAIM != 0) return 65;
    uint32_t t1a = PLIC_CLAIM1;
    gpint_lower(1u << 0);
    for (volatile int i = 0; i < 20; i++) {                               /* ソースが 0 になったのが PLIC に届くまで待つ */
    }
    PLIC_CLAIM1 = t1a;
    if (t1a != PLIC_ID_GP0 || PLIC_PENDING != 0) return 66;

    /* 67: ターゲット 1 の threshold で claim が絞られ、PREEMPT ではターゲット 1 の threshold と PPS だけが動く */
    PLIC_THRESHOLD1 = 1;
    PLIC_PENDING = 1u << 20;                                              /* priority 1 */
    if (PLIC_CLAIM1 != 0) return 67;
    PLIC_THRESHOLD1 = 0;
    PLIC_FEATURE = PLIC_FEATURE_PREEMPT;
    PLIC_PRIORITY(20) = 2;
    PLIC_ENABLE1 = 1u << 20;
    uint32_t t1b = PLIC_CLAIM1;
    if (PLIC_THRESHOLD1 != 2 || PLIC_PPS1 != 0x1u) return 68;
    if (PLIC_THRESHOLD != 0 || PLIC_PPS != 0) return 69;
    PLIC_CLAIM1 = t1b;
    if (PLIC_THRESHOLD1 != 0 || PLIC_PPS1 != 0) return 70;
    PLIC_FEATURE = 0;
    PLIC_PRIORITY(20) = 1;
    PLIC_ENABLE1 = 0;
    printf("target1 %lu %lu\n", (unsigned long)t1a, (unsigned long)t1b);

    return PASS;
}
