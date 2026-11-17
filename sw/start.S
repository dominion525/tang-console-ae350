/*
 * スタートアップルーチン。リセットベクタ 0x8000_0000 に置く。
 *
 *   1. スタックと mtvec を設定する
 *   2. .data の初期値を ROM から DDR にコピーする
 *   3. .bss を 0 にする
 *   4. main を呼び、戻り値を result (0x0000_0000) に書いて停止する
 *
 * 例外と割り込みの入口 (trap_entry) は、レジスタを退避して sw/trap.c の trap_handler を呼ぶ。
 */

    .section .text.start, "ax"
    .globl _start
_start:
    la      sp, _stack_top
    la      t0, trap_entry
    csrw    mtvec, t0

    la      t0, _data_load
    la      t1, _data_start
    la      t2, _data_end
1:  bgeu    t1, t2, 2f
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       1b

2:  la      t1, _bss_start
    la      t2, _bss_end
3:  bgeu    t1, t2, 4f
    sw      zero, 0(t1)
    addi    t1, t1, 4
    j       3b

4:  call    main
    la      t0, result
    sw      a0, 0(t0)
#ifdef START_RETURN_TO_ROM
    /* 外部メモリで動かすプログラム (sw/sdram.ld): 書き込みを完了させてから、ROM のローダーに戻る */
    fence
    li      t0, 0x80000000
    jr      t0
#endif
5:  j       5b

    /*
     * 例外と割り込みの入口: 呼び出し側が保存するレジスタ (ra、t0〜t6、a0〜a7) を退避し、
     * trap_handler(mcause, mepc) (sw/trap.c) を呼ぶ。戻り値を mepc に設定し、mret で戻る
     */
    .balign 4
    .globl trap_entry
trap_entry:
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a2, 24(sp)
    sw      a3, 28(sp)
    sw      a4, 32(sp)
    sw      a5, 36(sp)
    sw      a6, 40(sp)
    sw      a7, 44(sp)
    sw      t3, 48(sp)
    sw      t4, 52(sp)
    sw      t5, 56(sp)
    sw      t6, 60(sp)
    csrr    a0, mcause
    csrr    a1, mepc
    call    trap_handler
    csrw    mepc, a0
    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a2, 24(sp)
    lw      a3, 28(sp)
    lw      a4, 32(sp)
    lw      a5, 36(sp)
    lw      a6, 40(sp)
    lw      a7, 44(sp)
    lw      t3, 48(sp)
    lw      t4, 52(sp)
    lw      t5, 56(sp)
    lw      t6, 60(sp)
    addi    sp, sp, 64
    mret

    .section .result, "aw", @nobits
    .globl result
result:
    .space  4
