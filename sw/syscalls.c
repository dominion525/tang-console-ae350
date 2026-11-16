/*
 * newlib が呼ぶシステムコール (段 3、2026-11-09)。
 * 標準出力と標準エラーは UART (= sw/uart.h) に出し、標準入力は UART から読む (= 段 3b)。
 * ファイルは無い。ヒープはリンカスクリプトの _heap_start〜_heap_end。
 */

#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>

#include "uart.h"

#undef errno
extern int errno;

extern char _heap_start[];
extern char _heap_end[];

int _write(int fd, const char *buf, int len)
{
    if (fd != 1 && fd != 2) {
        errno = EBADF;
        return -1;
    }
    for (int i = 0; i < len; i++) {
        uart_putc(buf[i]);
    }
    return len;
}

/*
 * 標準入力: 1 文字目は届くまで待つ。2 文字目からは、FIFO に残っている分だけ読む。
 * 改行を読んだら、そこで返す (= newlib の行バッファの読み方に合わせる)
 */
int _read(int fd, char *buf, int len)
{
    if (fd != 0) {
        errno = EBADF;
        return -1;
    }
    int n = 0;
    while (n < len) {
        if (n > 0 && (UART_STATUS & UART_STATUS_RX_READY) == 0) break;
        char c = uart_getc();
        buf[n++] = c;
        if (c == '\n') break;
    }
    return n;
}

void *_sbrk(ptrdiff_t incr)
{
    static char *brk = _heap_start;
    char *prev = brk;
    if (brk + incr > _heap_end || brk + incr < _heap_start) {
        errno = ENOMEM;
        return (void *)-1;
    }
    brk += incr;
    return prev;
}

int _close(int fd)
{
    (void)fd;
    errno = EBADF;
    return -1;
}

int _fstat(int fd, struct stat *st)
{
    (void)fd;
    st->st_mode = S_IFCHR;
    return 0;
}

int _isatty(int fd)
{
    return fd == 0 || fd == 1 || fd == 2;
}

int _lseek(int fd, int offset, int whence)
{
    (void)fd;
    (void)offset;
    (void)whence;
    return 0;
}

int _getpid(void)
{
    return 1;
}

int _kill(int pid, int sig)
{
    (void)pid;
    (void)sig;
    errno = EINVAL;
    return -1;
}

void _exit(int status)
{
    (void)status;
    for (;;) {
    }
}
