/*
 * ILM で動かすプログラムのリンカスクリプト (= 2026-11-13)。ROM のローダー (= sw/loader.c) が UART で受けて ILM に書き、
 * run で 0xA000_0000 へ飛ぶ。命令もデータも CPU のそばのメモリ (= ILM / DLM) に置くので、SDRAM の待ちが入らない
 * (= AE350 と Hazard3 の CPU の速さを、メモリの差を除いて比べるため)。
 *
 *   0x0000_0000〜0x0000_000F  .result (= SDRAM。TB が結果を読む場所。sw/sdram.ld と同じ)
 *   0xA000_0000〜0xA000_FFFF  ILM (= 64 KB): .text、.rodata、.init_array、.data の初期値 (= 送る中身)
 *   0xA020_0000〜0xA020_FFFF  DLM (= 64 KB): .data (= start.S が ILM から写す)、.bss、ヒープ、スタック
 *
 * start.S は START_RETURN_TO_ROM を定義して作る (= main から戻ったら、ROM のローダーへ戻る)。
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    SDRAM (rw) : ORIGIN = 0x00000000, LENGTH = 32M
    ILM (rwx)  : ORIGIN = 0xA0000000, LENGTH = 64K
    DLM (rw)   : ORIGIN = 0xA0200000, LENGTH = 64K
}

SECTIONS
{
    .result (NOLOAD) :
    {
        KEEP(*(.result))
        . = 16;
    } > SDRAM

    .text :
    {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ILM

    .rodata :
    {
        . = ALIGN(4);
        *(.rodata .rodata.* .srodata .srodata.*)
        *(.eh_frame .eh_frame.*)
    } > ILM

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
    } > ILM

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > DLM AT > ILM
    _data_load = LOADADDR(.data);

    .bss (NOLOAD) : ALIGN(4)
    {
        _bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > DLM

    /* DLM の後ろ 16 KB をスタック、.bss の後ろからその手前までをヒープにする */
    _stack_top  = ORIGIN(DLM) + LENGTH(DLM);
    _heap_start = ALIGN(_bss_end, 8);
    _heap_end   = _stack_top - 16K;

    /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
