/* ============================================================
   link_c.ld —— 链接脚本（给 C 程序用）
   ============================================================
   和 link.ld 的区别：C 程序除了 .text（代码）还会产生
     .rodata  只读数据（字符串常量、const 数组）  <- C 能读常量靠的就是它
     .data    有初值的全局/静态变量
     .bss     初值为 0 的全局/静态变量（不占镜像空间，由 crt0 清零）
   所以要多列出这几段，并导出 __bss_start / __bss_end 给 crt0.S 用。

   存储器地址图（统一存储器扩到 128KB）：
     0x00000 - 0x0FFFF  程序镜像（.text/.rodata/.data/.bss）——最多 64KB
     0x10000 - 0x1FFFC  堆 / 动态数据
     0x1FFFC 起向下      栈（sp 初值 = 0x1FFFC，见 crt0.S）
     0x10000000 起       MMIO（UART/GPIO）
   ============================================================ */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 0x40000
}

SECTIONS {
    .text : {
        *(.text.start)      /* 启动代码放最前面，确保 0x0 就是 _start */
        *(.text*)
    } > RAM

    .rodata : { *(.rodata*) } > RAM
    .data   : { *(.data*)   } > RAM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    /* 程序镜像（含 .data/.bss）必须留在 0x10000 以下，否则会撞上栈 */
    ASSERT(. <= 0x10000, "错误：程序镜像超过 64KB，无法放进 0x0000~0xFFFF")
}
