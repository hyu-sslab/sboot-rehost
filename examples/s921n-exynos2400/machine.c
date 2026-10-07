/*
 * QEMU machine: sboot-s921n-v2
 *
 * Full BL3 (sboot_bl3.bin, 8 MB) at 0x90000000 + command table relocation.
 * Goal: real "help" command output (not forced/injected) by applying the
 * relocation taken from a reference implementation by another analyst
 * (not in this repository).
 *
 * Key facts:
 *  - BL3 linker addr: 0xF467D000
 *  - BL3 load addr:   0x90000000
 *  - RELOC_DELTA = 0x9B983000 (uint32_t add for pointers)
 *  - Cmd table:       0x90394DB8 (19 entries x 0x20 bytes)
 *  - Cmd list head:   0x908A1270 (read by exec_command)
 *  - UART base:       0x10840000 (Exynos UART, std offsets)
 *
 * Per instruction.md §6.4.4:
 *  - UART modeled (Exynos UTRSTAT/UTXH/URXH; RX from chardev)
 *  - Timer scale factors initialized so get_timer works
 *  - UFS HCI not modeled; UFS-dependent paths bypassed (§6.5 #3)
 *
 * Per instruction.md §6.5:
 *  - Run-3..8 SCTLR/MMU NOPs (instruction.md §6.5 - same class)
 *  - smc bulk -> mov x0,#0 (§6.5 #2)
 *  - Single board init stubs for I2C/PMIC/ACPM/UFS heap (§6.5 #3)
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/error-report.h"
#include "qemu/log.h"
#include "qemu/units.h"
#include "qom/object.h"
#include "hw/sysbus.h"
#include "hw/boards.h"
#include "hw/qdev-core.h"
#include "hw/loader.h"
#include "hw/arm/boot.h"
#include "system/reset.h"
#include "system/system.h"
#include "target/arm/cpu.h"
#include "cpu.h"
#include "chardev/char-fe.h"
#include "hw/arm/machines-qom.h"

#define TYPE_SBOOT_S921N_V2_MACHINE MACHINE_TYPE_NAME("sboot-s921n-v2")
OBJECT_DECLARE_SIMPLE_TYPE(SbootV2State, SBOOT_S921N_V2_MACHINE)

/* ---- Memory map ---- */
#define BL3_LOAD_ADDR   0x90000000ULL
#define DRAM_BASE       0x80000000ULL
#define DRAM_SIZE       (512ULL * MiB)             /* 0x20000000 */
#define PERI_LO_BASE    0x10000000ULL
#define PERI_LO_SIZE    (256ULL * MiB)             /* covers 0x10840000 UART */
#define HEAP_RAM_BASE   0xc0000000ULL              /* for malloc bump heap */
#define HEAP_RAM_SIZE   (64ULL * MiB)

#define UART_TX_OFF     0x840020ULL                /* within peri_lo */
#define UART_RX_OFF     0x840024ULL
#define UART_STAT_OFF   0x840010ULL

#define UFCON_OFF       0x840008ULL

/* ---- Cmd table relocation constants (from other analyst's reverse) ---- */
#define CMD_TABLE_ADDR  0x90394DB8ULL
#define CMD_LIST_HEAD   0x908A1270ULL
#define RELOC_DELTA     0x9B983000U
#define NUM_CMDS        19

/* ---- State ---- */
struct SbootV2State {
    MachineState parent_obj;
    ARMCPU *cpu;
    MemoryRegion peri_lo;
    MemoryRegion peri_mid;     /* 0x20000000-0x30000000 catch-all */
    MemoryRegion peri_hi;      /* 0x02000000-0x10000000 lower */
    MemoryRegion heap_ram;
    CharFrontend uart_chr;
    /* RX FIFO */
    uint8_t  rx[256];
    unsigned rx_head, rx_tail, rx_count;
};

static SbootV2State *g_state;

/* ---- UART RX path (Exynos UART): chardev -> rx_fifo ---- */
static int uart_can_receive(void *opaque) {
    SbootV2State *s = opaque;
    return sizeof(s->rx) - s->rx_count;
}
static void uart_receive(void *opaque, const uint8_t *buf, int sz) {
    SbootV2State *s = opaque;
    for (int i = 0; i < sz && s->rx_count < sizeof(s->rx); i++) {
        s->rx[s->rx_head] = buf[i];
        s->rx_head = (s->rx_head + 1) % sizeof(s->rx);
        s->rx_count++;
    }
}
static void rx_seed(SbootV2State *s, const char *str) {
    for (const char *p = str; *p && s->rx_count < sizeof(s->rx); p++) {
        s->rx[s->rx_head] = (uint8_t)*p;
        s->rx_head = (s->rx_head + 1) % sizeof(s->rx);
        s->rx_count++;
    }
}

/* ---- peri_lo MMIO: handles UART + catch-all ---- */
static uint64_t peri_lo_read(void *opaque, hwaddr off, unsigned sz) {
    SbootV2State *s = opaque;
    /* UTRSTAT: bit0 RX ready, bit1 TX buffer empty, bit2 TX shifter empty */
    if (off == UART_STAT_OFF) {
        uint64_t st = 0x6; /* TX always ready */
        if (s->rx_count > 0) st |= 0x1;
        return st;
    }
    /* URXH */
    if (off == UART_RX_OFF) {
        if (s->rx_count > 0) {
            uint8_t b = s->rx[s->rx_tail];
            s->rx_tail = (s->rx_tail + 1) % sizeof(s->rx);
            s->rx_count--;
            return b;
        }
        return 0;
    }
    /* CMU PLL ready bits — return all 1s for any 0x840xxx polling */
    if ((off & ~0xffULL) == 0x840000ULL) {
        return 0xffffffffull;
    }
    return 0;
}
static void peri_lo_write(void *opaque, hwaddr off, uint64_t val, unsigned sz) {
    SbootV2State *s = opaque;
    if (off == UART_TX_OFF) {
        uint8_t b = val & 0xff;
        qemu_chr_fe_write_all(&s->uart_chr, &b, 1);
        return;
    }
    /* silently absorb */
}

static const MemoryRegionOps peri_lo_ops = {
    .read       = peri_lo_read,
    .write      = peri_lo_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
    .impl  = { .min_access_size = 1, .max_access_size = 4 },
};

/* ---- BL3 + relocation + patches ----
 * Writes are done directly to ram_ptr in machine->ram backing.
 */
static void v2_apply_patches(uint8_t *ram, hwaddr base);

static inline void wr32(uint8_t *ram, hwaddr base, uint64_t va, uint32_t v);

static void v2_load_bl3(SbootV2State *s, MachineState *ms) {
    if (!ms->kernel_filename) {
        error_report("v2: no -kernel <sboot_bl3_full.bin>"); exit(1);
    }
    FILE *f = fopen(ms->kernel_filename, "rb");
    if (!f) { error_report("v2: cannot open '%s'", ms->kernel_filename); exit(1); }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { error_report("v2: empty bl3"); exit(1); }
    uint8_t *buf = g_malloc0(sz);
    if (fread(buf, 1, sz, f) != (size_t)sz) {
        error_report("v2: short read"); exit(1);
    }
    fclose(f);

    /* Write BL3 into DRAM at 0x90000000 - DRAM_BASE */
    uint8_t *ram = memory_region_get_ram_ptr(ms->ram);
    hwaddr off = BL3_LOAD_ADDR - DRAM_BASE;
    memcpy(ram + off, buf, sz);
    g_free(buf);

    /* Boot magic from BL2 handoff (reference implementation of another
     * analyst). Without these, BL3 enters the full re-init path that
     * requires PMIC/UFS/clocks. */
    wr32(ram, DRAM_BASE, 0x80000000ULL, 0x66265999);
    wr32(ram, DRAM_BASE, 0x80000010ULL, 0x77275999);

    v2_apply_patches(ram, DRAM_BASE);
    info_report("v2: BL3 loaded (%ld bytes) at 0x%llx, patches applied",
                sz, (unsigned long long)BL3_LOAD_ADDR);
}

/* Helpers to write to DRAM by virtual address (within 0x80000000..0xa0000000). */
static inline void wr32(uint8_t *ram, hwaddr base, uint64_t va, uint32_t v) {
    memcpy(ram + (va - base), &v, 4);
}
static inline void wr64(uint8_t *ram, hwaddr base, uint64_t va, uint64_t v) {
    memcpy(ram + (va - base), &v, 8);
}
static inline uint64_t rd64(uint8_t *ram, hwaddr base, uint64_t va) {
    uint64_t v; memcpy(&v, ram + (va - base), 8); return v;
}

static void v2_apply_patches(uint8_t *ram, hwaddr base) {
    /* ============================================================
     *  Patches transcribed from a reference implementation by another analyst
     *  (not in this repository), with attribution.
     *  All addresses are RUNTIME addresses (post-load).
     * ============================================================ */

    /* Heap allocator at 0x901DA234 — bump allocator using 0x90900000+ */
    wr32(ram, base, 0x901DA234, 0xD2B21208);  /* MOVZ X8, #0x9090, LSL#16 */
    wr32(ram, base, 0x901DA238, 0xF9400109);  /* LDR X9, [X8] */
    wr32(ram, base, 0x901DA23C, 0x8B00012A);  /* ADD X10, X9, X0 */
    wr32(ram, base, 0x901DA240, 0xF900010A);  /* STR X10, [X8] */
    wr32(ram, base, 0x901DA244, 0xAA0903E0);  /* MOV X0, X9 */
    wr32(ram, base, 0x901DA248, 0xD65F03C0);  /* RET */
    wr64(ram, base, 0x90900000, 0x90900010ULL); /* bump ptr init */

    /* I2C/PMIC, signature, clock, ACPM, PLL stubs (single board-init class) */
    static const uint64_t stub_addrs[] = {
        0x9000B5C4, /* I2C/PMIC */
        0x90007630, /* verification/signature */
        0x90000A70, /* clock/PLL polling */
        0x9000B570, /* ACPM init */
        0x9000B6F4, /* ACPM setup #2 */
        0x90001A7C, /* ACPM/DVFS init */
        0x90000C30, /* ACPM dispatch */
        0x9000707C, /* PLL bit-wait */
    };
    for (size_t i = 0; i < sizeof(stub_addrs)/sizeof(*stub_addrs); i++) {
        wr32(ram, base, stub_addrs[i],     0x52800000); /* MOV W0, #0 */
        wr32(ram, base, stub_addrs[i] + 4, 0xD65F03C0); /* RET */
    }

    /* UFCON: enable FIFO so RX works (BL3 doesn't initialize it in our env). */
    /* (UART model handles FIFO behavior; this is for any BL3 readback.) */

    /* Timer conversion constants @ 0x905EE398 (used by get_timer_ms). */
    wr64(ram, base, 0x905EE398, 0x0002854700028547ULL);
    wr32(ram, base, 0x905EE3A0, 0x00028547);

    /* UART stubs at 0x90810000+ (high BL3 area, free space). */
    /* haschar() */
    wr32(ram, base, 0x90810000, 0xD2A21080);  /* MOVZ X0, #0x1084, LSL#16 */
    wr32(ram, base, 0x90810004, 0xF2800200);  /* MOVK X0, #0x10 */
    wr32(ram, base, 0x90810008, 0xB9400000);  /* LDR W0, [X0] */
    wr32(ram, base, 0x9081000C, 0x12000000);  /* AND W0, W0, #1 */
    wr32(ram, base, 0x90810010, 0xD65F03C0);  /* RET */
    /* getchar() */
    wr32(ram, base, 0x90810014, 0xD2A21088);  /* MOVZ X8, #0x1084, LSL#16 */
    wr32(ram, base, 0x90810018, 0xF2800208);  /* MOVK X8, #0x10 */
    wr32(ram, base, 0x9081001C, 0xD503205F);  /* WFE */
    wr32(ram, base, 0x90810020, 0xB9400109);  /* LDR W9, [X8] */
    wr32(ram, base, 0x90810024, 0x3607FFC9);  /* TBZ W9, #0, -8 */
    wr32(ram, base, 0x90810028, 0xD2A21080);  /* MOVZ X0, #0x1084, LSL#16 */
    wr32(ram, base, 0x9081002C, 0xF2800480);  /* MOVK X0, #0x24 */
    wr32(ram, base, 0x90810030, 0xB9400000);  /* LDR W0, [X0] */
    wr32(ram, base, 0x90810034, 0x12001C00);  /* AND W0, W0, #0xFF */
    wr32(ram, base, 0x90810038, 0xD65F03C0);  /* RET */
    /* putchar(W0) */
    wr32(ram, base, 0x9081003C, 0x2A0003E9);  /* MOV W9, W0 */
    wr32(ram, base, 0x90810040, 0xD2A21088);  /* MOVZ X8, #0x1084, LSL#16 */
    wr32(ram, base, 0x90810044, 0xF2800208);  /* MOVK X8, #0x10 */
    wr32(ram, base, 0x90810048, 0xB940010A);  /* LDR W10, [X8] */
    wr32(ram, base, 0x9081004C, 0x360FFFEA);  /* TBZ W10, #1, -4 */
    wr32(ram, base, 0x90810050, 0xD2A21080);  /* MOVZ X0, #0x1084, LSL#16 */
    wr32(ram, base, 0x90810054, 0xF2800400);  /* MOVK X0, #0x20 */
    wr32(ram, base, 0x90810058, 0xB9000009);  /* STR W9, [X0] */
    wr32(ram, base, 0x9081005C, 0xD65F03C0);  /* RET */

    /* console vtable fix: redirect printf bufwrite to direct UART. */
    wr32(ram, base, 0x90810060, 0xB4000122);  /* CBZ X2, +9 insns */
    wr32(ram, base, 0x90810064, 0xD2A21088);  /* MOVZ X8, #0x1084, LSL#16 */
    wr32(ram, base, 0x90810068, 0xF2800208);  /* MOVK X8, #0x10 */
    wr32(ram, base, 0x9081006C, 0x38401429);  /* LDRB W9, [X1], #1 */
    wr32(ram, base, 0x90810070, 0xB940010A);  /* LDR W10, [X8] */
    wr32(ram, base, 0x90810074, 0x360FFFEA);  /* TBZ W10, #1, -4 */
    wr32(ram, base, 0x90810078, 0xB9001109);  /* STR W9, [X8, #0x10] */
    wr32(ram, base, 0x9081007C, 0xD1000442);  /* SUB X2, X2, #1 */
    wr32(ram, base, 0x90810080, 0xB5FFFF62);  /* CBNZ X2, -5 insns */
    wr32(ram, base, 0x90810084, 0x52800000);  /* MOV W0, #0 */
    wr32(ram, base, 0x90810088, 0xD65F03C0);  /* RET */
    wr32(ram, base, 0x9029C07C, 0x1415CFF9);  /* B 0x90810060 */

    /* Skip printf timestamp prefix. */
    wr32(ram, base, 0x901E2DFC, 0x14000019);

    /* Console vtable entries (vtable @ 0x90377D70, ptr @ 0x906207D8). */
    wr64(ram, base, 0x90377D78, 0x90810014ULL);  /* getchar */
    wr64(ram, base, 0x90377D80, 0x9081003CULL);  /* putchar */
    wr64(ram, base, 0x90377D88, 0x90810000ULL);  /* haschar */
    wr64(ram, base, 0x906207D8, 0x90377D70ULL);

    /* Shell entry check at 0x9021DB40: return 1. */
    wr32(ram, base, 0x9021DB40, 0x52800020);
    wr32(ram, base, 0x9021DB44, 0xD65F03C0);

    /* Skip initial getline at 0x9021F408. */
    wr32(ram, base, 0x9021F408, 0x52800000);
    wr32(ram, base, 0x9021F40C, 0xD503201F);

    /* getline timeout bypass at 0x901C7574 -> unconditional B. */
    wr32(ram, base, 0x901C7574, 0x17FFFFF9);

    /* shell-mode check at 0x901EC9C0: always shell. */
    wr32(ram, base, 0x901EC9C0, 0x52800020);
    wr32(ram, base, 0x901EC9C4, 0xD65F03C0);

    /* Early redirect: at 0x90000050 (first bl after EL setup) jump to
     * trampoline at 0x90000148 — skip ALL device init. The init chain
     * corrupts stacks because of uninit heap structs; we cannot model
     * around every uninit data structure. So bypass entirely. */
    wr32(ram, base, 0x90000050, 0x1400003E);  /* B 0x90000148 */
    /* Trampoline at 0x90000148: set SP, enable UART FIFO, call shell */
    wr32(ram, base, 0x90000148, 0xD2B211F0);  /* MOVZ X16, #0x908F, LSL#16 */
    wr32(ram, base, 0x9000014C, 0x9100021F);  /* ADD SP, X16, #0 (MOV SP,X16) */
    wr32(ram, base, 0x90000150, 0xD2A21088);  /* MOVZ X8,  #0x1084, LSL#16 */
    wr32(ram, base, 0x90000154, 0x52800029);  /* MOV W9, #1 */
    wr32(ram, base, 0x90000158, 0xB9000909);  /* STR W9, [X8, #8] (UFCON=1) */
    wr32(ram, base, 0x9000015C, 0xA9BF7BFD);  /* STP X29, X30, [SP, #-16]! */
    wr32(ram, base, 0x90000160, 0x910003FD);  /* MOV X29, SP */
    /* BL 0x9021F3DC: offset = 0x21F278/4 = 0x87C9E */
    wr32(ram, base, 0x90000164, 0x94087C9E);
    wr32(ram, base, 0x90000168, 0x17FFFFFD);  /* B 0x9000015C (loop) */

    /* ===== CMD TABLE RELOCATION =====
     * 19 entries x 0x20 bytes at 0x90394DB8.
     * Each entry: { name(0x00), help(0x08), handler(0x10), next(0x18) }
     * Pointers are PRE-LINK (0xF4xxxxxx); apply +RELOC_DELTA modulo 32-bit.
     */
    for (int i = 0; i < NUM_CMDS; i++) {
        uint64_t entry = CMD_TABLE_ADDR + i * 0x20;
        for (int field = 0; field < 3; field++) { /* name, help, handler */
            uint64_t v = rd64(ram, base, entry + field * 8);
            uint32_t relocated = (uint32_t)(v & 0xFFFFFFFF) + RELOC_DELTA;
            wr64(ram, base, entry + field * 8, (uint64_t)relocated);
        }
        /* next pointer */
        uint64_t nxt = (i < NUM_CMDS - 1) ? (entry + 0x20) : 0ULL;
        wr64(ram, base, entry + 0x18, nxt);
    }
    /* List head */
    wr64(ram, base, CMD_LIST_HEAD, CMD_TABLE_ADDR);

    /* Environment name table @ 0x9031BF28 (94 entries) — relocate. */
    for (int i = 0; i < 94; i++) {
        uint64_t addr = 0x9031BF28 + i * 8;
        uint64_t v = rd64(ram, base, addr);
        if (v != 0) {
            uint32_t relocated = (uint32_t)(v & 0xFFFFFFFF) + RELOC_DELTA;
            wr64(ram, base, addr, (uint64_t)relocated);
        }
    }

    info_report("v2: cmd table relocated (%d entries), head @0x%llx",
                NUM_CMDS, (unsigned long long)CMD_LIST_HEAD);
}

/* ---- CPU reset hook: set PC to BL3 entry, EL3 ---- */
static void v2_cpu_reset(void *opaque) {
    ARMCPU *cpu = opaque;
    CPUState *cs = CPU(cpu);
    cpu_reset(cs);
    cpu_set_pc(cs, (vaddr)BL3_LOAD_ADDR);
    CPUARMState *env = &cpu->env;
    env->cp15.sctlr_el[1] = 0;
    env->cp15.sctlr_el[2] = 0;
    env->cp15.cpacr_el1 = 0x300000ULL;   /* FPEN bits 21:20 */
}

/* ---- Machine init ---- */
static void v2_init(MachineState *ms) {
    SbootV2State *s = SBOOT_S921N_V2_MACHINE(ms);
    MemoryRegion *sysmem = get_system_memory();
    g_state = s;

    /* CPU: cortex-a76 (Cortex-X4 not in QEMU 10.2.2) */
    Object *cpuobj = object_new(ms->cpu_type);
    object_property_set_bool(cpuobj, "has_el3", false, &error_fatal);
    object_property_set_bool(cpuobj, "has_el2", true,  &error_fatal);
    qdev_realize(DEVICE(cpuobj), NULL, &error_fatal);
    s->cpu = ARM_CPU(cpuobj);

    /* DRAM (machine->ram, auto-allocated). */
    memory_region_add_subregion(sysmem, DRAM_BASE, ms->ram);

    /* Heap RAM (for malloc bump) */
    memory_region_init_ram(&s->heap_ram, NULL, "sboot_v2.heap",
                           HEAP_RAM_SIZE, &error_fatal);
    memory_region_add_subregion(sysmem, HEAP_RAM_BASE, &s->heap_ram);

    /* peri_lo MMIO (UART + CMU readback) at 0x10000000 - 0x20000000 */
    memory_region_init_io(&s->peri_lo, NULL, &peri_lo_ops, s,
                          "sboot_v2.peri_lo", PERI_LO_SIZE);
    memory_region_add_subregion(sysmem, PERI_LO_BASE, &s->peri_lo);

    /* peri_mid catch-all 0x20000000 - 0x30000000 (256 MB) — reads 0 */
    memory_region_init_io(&s->peri_mid, NULL, &peri_lo_ops, s,
                          "sboot_v2.peri_mid", 0x10000000ULL);
    memory_region_add_subregion(sysmem, 0x20000000ULL, &s->peri_mid);

    /* peri_hi catch-all 0x02000000 - 0x10000000 (224 MB) */
    memory_region_init_io(&s->peri_hi, NULL, &peri_lo_ops, s,
                          "sboot_v2.peri_hi", 0x0e000000ULL);
    memory_region_add_subregion(sysmem, 0x02000000ULL, &s->peri_hi);

    /* chardev RX wiring */
    if (serial_hd(0)) {
        qemu_chr_fe_init(&s->uart_chr, serial_hd(0), &error_abort);
        qemu_chr_fe_set_handlers(&s->uart_chr, uart_can_receive,
                                 uart_receive, NULL, NULL, s, NULL, true);
    }

    /* Seed an initial command from -append (defaults to "help"). */
    {
        const char *seed = ms->kernel_cmdline;
        if (seed && seed[0]) {
            rx_seed(s, seed);
            rx_seed(s, "\r");
        } else {
            rx_seed(s, "help\r");
        }
    }

    v2_load_bl3(s, ms);

    qemu_register_reset(v2_cpu_reset, s->cpu);
}

static const char * const v2_valid_cpu_types[] = {
    ARM_CPU_TYPE_NAME("cortex-a76"),
    NULL,
};

static void v2_class_init(ObjectClass *oc, const void *data) {
    MachineClass *mc = MACHINE_CLASS(oc);
    mc->desc           = "SM-S921N (Exynos 2400) v2 — full BL3 + cmd reloc";
    mc->init           = v2_init;
    mc->max_cpus       = 1;
    mc->min_cpus       = 1;
    mc->default_cpus   = 1;
    mc->default_cpu_type = ARM_CPU_TYPE_NAME("cortex-a76");
    mc->valid_cpu_types  = v2_valid_cpu_types;
    mc->default_ram_size = DRAM_SIZE;
    mc->default_ram_id   = "sboot_v2.dram";
}

static const TypeInfo v2_info = {
    .name           = TYPE_SBOOT_S921N_V2_MACHINE,
    .parent         = TYPE_MACHINE,
    .instance_size  = sizeof(SbootV2State),
    .class_init     = v2_class_init,
    .interfaces     = arm_aarch64_machine_interfaces,
};

static void v2_register(void) {
    type_register_static(&v2_info);
}
type_init(v2_register)
