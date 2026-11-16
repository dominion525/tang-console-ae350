/*
 * SDRAM で動かす確かめのプログラム (= 2026-11-12)。ROM のローダーで送って run する (= sw/sdram.ld)。
 * newlib の printf で、自分の main の番地 (= SDRAM の 0x0001_0000〜 にあること) を出し、1 行受けてそのまま返し、
 * 0x600D (= TB の合格) を返す。main から戻ると、start.S が ROM のローダーへ戻る。
 */

#include <stdint.h>
#include <stdio.h>

int main(void)
{
    printf("hello from SDRAM (main 0x%08lx)\n", (unsigned long)(uintptr_t)main);
    printf("READY 1 行を送ってください\n");
    char buf[64];
    if (fgets(buf, sizeof buf, stdin) != NULL) printf("受けた行: %s", buf);
    else printf("受けた行: (無い)\n");
    return 0x600D;
}
