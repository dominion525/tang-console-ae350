/*
 * 実機の値を読む構成 (= ae350/board/tang_console/) のリンカスクリプト (= 2026-11-10)。
 *
 *   0x8000_0000〜  ROM (= ROM_H* の先のブロック RAM、16 KB)   .text、.rodata、.data の初期値
 *   0xA020_0000〜  DLM (= AE350 の中のメモリ、64 KB)          .result、.data、.bss、スタック
 *
 * DDR_H* の先には何も置かない (= DDR3 を使わない) ので、データもスタックも DLM に置く。
 * start.S が参照する名前 (= _data_load / _data_start / _data_end / _bss_start / _bss_end / _stack_top) は
 * sw/ae350.ld と同じ。
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x80000000, LENGTH = 16K
    DLM (rw)  : ORIGIN = 0xA0200000, LENGTH = 64K
}

SECTIONS
{
    .result (NOLOAD) :
    {
        KEEP(*(.result))
        . = 16;
    } > DLM

    .text :
    {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ROM

    .rodata :
    {
        . = ALIGN(4);
        *(.rodata .rodata.* .srodata .srodata.*)
    } > ROM

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > DLM AT > ROM
    _data_load = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(4)
    {
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > DLM

    _stack_top = ORIGIN(DLM) + LENGTH(DLM);

    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame .eh_frame.*) }
}
