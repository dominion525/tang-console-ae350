/*
 * AE350 のアドレスマップに合わせたリンカスクリプト (= 段 2、2026-11-08)。
 *
 *   0x8000_0000〜  命令メモリ (ROM_H* の先)   .text、.rodata、.data の初期値
 *   0x0000_0000〜  データメモリ (DDR_H* の先) .result、.data、.bss、スタック
 *   0xA000_0000〜  ILM (= AE350 の中のメモリ)     .ilm_text (= 段 5。初期値は ROM に置き、プログラムが写す)
 *   0xA020_0000〜  DLM (= 同上)                   .dlm_bss (= 段 5。初期化しない)
 *
 * 大きさはシミュレーションのメモリモデル (= tb/ahb_*_model.v) に合わせて 64 KB ずつ。
 * DDR の後ろのほうは、.bss の後ろからヒープ、0x0000_9000〜0x0000_AFFF は段 5 の EXTM_H* の確認用、末尾の 20 KB がスタック。
 * .result (= 0x0000_0000 の 16 byte) は TB が結果を読む場所で、.data より前に置く。
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x80000000, LENGTH = 64K
    DDR (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
    ILM (rwx) : ORIGIN = 0xA0000000, LENGTH = 64K
    DLM (rw)  : ORIGIN = 0xA0200000, LENGTH = 64K
}

SECTIONS
{
    .result (NOLOAD) :
    {
        KEEP(*(.result))
        . = 16;
    } > DDR

    .text :
    {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ROM

    .rodata :
    {
        . = ALIGN(4);
        *(.rodata .rodata.* .srodata .srodata.*)
        *(.eh_frame .eh_frame.*)
    } > ROM

    /* newlib の __libc_init_array / exit が参照する (= start.S は呼ばないが、リンクには要る) */
    .init_array :
    {
        . = ALIGN(4);
        PROVIDE_HIDDEN(__preinit_array_start = .);
        KEEP(*(.preinit_array))
        PROVIDE_HIDDEN(__preinit_array_end = .);
        PROVIDE_HIDDEN(__init_array_start = .);
        KEEP(*(SORT(.init_array.*)))
        KEEP(*(.init_array))
        PROVIDE_HIDDEN(__init_array_end = .);
        PROVIDE_HIDDEN(__fini_array_start = .);
        KEEP(*(SORT(.fini_array.*)))
        KEEP(*(.fini_array))
        PROVIDE_HIDDEN(__fini_array_end = .);
    } > ROM

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > DDR AT > ROM
    _data_load = LOADADDR(.data);

    /* ILM に置く命令 (= 段 5)。初期値は ROM に置き、プログラムが写してから呼ぶ (= start.S は写さない) */
    .ilm_text : ALIGN(4)
    {
        _ilm_start = .;
        KEEP(*(.ilm_text .ilm_text.*))
        . = ALIGN(4);
        _ilm_end = .;
    } > ILM AT > ROM
    _ilm_load = LOADADDR(.ilm_text);

    /* DLM に置くデータ (= 段 5)。初期化しない */
    .dlm_bss (NOLOAD) : ALIGN(8)
    {
        *(.dlm_bss .dlm_bss.*)
    } > DLM

    .bss (NOLOAD) : ALIGN(4)
    {
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > DDR

    /*
     * DDR の後ろのほう:
     *   0x0000_9000〜0x0000_9FFF  段 5 の EXTM_H* の手順が読み書きする (= sw/stage5_extm.txt)
     *   0x0000_A000〜0x0000_AFFF  段 5 の EXTM_H* の背景の転送が読み書きする (= TB の +extm_bg)
     *   0x0000_B000〜0x0000_FFFF  スタック (= 20 KB。段 5 のプログラムが使ったのは 660 byte (= 2026-11-10 に測った)。
     *                             超えて 0x0000_A000〜 に書くと、段 5 の TB が止める)
     * ヒープは .bss の後ろから 0x0000_9000 の手前まで (= sw/syscalls.c の _sbrk)
     */
    _heap_start = ALIGN(_bss_end, 8);
    _stack_top  = ORIGIN(DDR) + LENGTH(DDR);
    _heap_end   = _stack_top - 28K;

    /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
