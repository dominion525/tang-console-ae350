/*
 * 外部メモリで動かすプログラムのリンカスクリプト。ROM のローダー (sw/loader.c) が UART で受信して外部メモリに書き込み、
 * run で 0x0001_0000 にジャンプする。
 *
 *   0x0000_0000〜0x0000_000F  .result (テストベンチが結果を読む場所。シミュレーションのテストベンチは 0x0000_0008 に周波数比を書く)
 *   0x0001_0000〜             .text、.rodata、.init_array、.data、.bss (送る内容は .text から .data の終わりまで)
 *   .bss の後ろ〜0x01FF_FFFF   ヒープ (sw/syscalls.c の _sbrk)
 *   0xA020_0000〜0xA020_FFFF  スタック (DLM、64 KB。AE350 の内蔵メモリなので速い)
 *
 * .data は配置先と初期値が同じアドレスなので、start.S のコピーは同じ場所への上書きになる。
 * start.S は START_RETURN_TO_ROM を定義してビルドする (main から戻ったら、ROM のローダーに戻る)。
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

    /* newlib の __libc_init_array と exit が参照する (start.S は呼ばないが、リンクには必要) */
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
