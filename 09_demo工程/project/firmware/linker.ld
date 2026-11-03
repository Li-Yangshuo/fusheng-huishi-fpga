OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0xf9000000, LENGTH = 8K }
SECTIONS {
 .text : { KEEP(*(.text.start)) *(.text*) *(.rodata*) } > RAM
 .data : { *(.sdata*) *(.data*) } > RAM
 .bss (NOLOAD) : { . = ALIGN(4); __bss_start = .; *(.sbss*) *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > RAM
 __stack_top = ORIGIN(RAM) + LENGTH(RAM);
 ASSERT(__bss_end <= __stack_top - 768, "RAM exceeds firmware plus stack budget")
 /DISCARD/ : { *(.comment*) *(.eh_frame*) }
}
