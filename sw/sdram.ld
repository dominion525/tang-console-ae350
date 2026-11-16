/*
 * SDRAM で動かすプログラムのリンカスクリプト (= 2026-11-12)。ROM のローダー (= sw/loader.c) が UART で受けて SDRAM に書き、
 * run で 0x0001_0000 へ飛ぶ。
 *
 *   0x0000_0000〜0x0000_000F  .result (= TB が結果を読む場所。シミュレーションの TB が 0x0000_0008 に周波数の比を書く)
 *   0x0001_0000〜             .text、.rodata、.init_array、.data、.bss (= 送る中身は .text から .data の終わりまで)
 *   .bss の後ろ〜0x01FF_FFFF   ヒープ (= sw/syscalls.c の _sbrk)
 *   0xA020_0000〜0xA020_FFFF  スタック (= DLM、64 KB。AE350 の中のメモリなので速い)
 *
 * .data は置き場と初期値が同じ番地なので、start.S の写しは自分の上に写すだけになる。
 * start.S は START_RETURN_TO_ROM を定義して作る (= main から戻ったら、ROM のローダーへ戻る)。
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    SDRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 32M
    DLM (rw)    : ORIGIN = 0xA0200000, LENGTH = 64K
}

SECTIONS
{
    .result (NOLOAD) :
    {
        KEEP(*(.result))
        . = 16;
    } > SDRAM

    .text 0x00010000 :
    {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > SDRAM

    .rodata :
    {
        . = ALIGN(4);
        *(.rodata .rodata.* .srodata .srodata.*)
        *(.eh_frame .eh_frame.*)
    } > SDRAM

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
    } > SDRAM

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > SDRAM
    _data_load = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(4)
    {
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > SDRAM

    _heap_start = ALIGN(_bss_end, 8);
    _heap_end   = ORIGIN(SDRAM) + LENGTH(SDRAM);
    _stack_top  = ORIGIN(DLM) + LENGTH(DLM);

    /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
