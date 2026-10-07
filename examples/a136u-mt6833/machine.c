/*
 * ===========================================================================
 * REFERENCE ONLY - VALUES ARE NOT BORROWABLE
 * ===========================================================================
 * This file is the machine of ONE manual run: SM-A136U (MT6833), firmware build
 * A136USQSFDYJ1, QEMU 10.2.2. It is kept to show what a mixed AArch32/AArch64
 * machine needed, not what yours should contain. Nothing below was derived by
 * sboot-rehost, and the firmware it ran is NOT part of this repository.
 *
 *  - Every address, offset, register value and patch byte belongs to that one
 *    build. Derive yours from your own target (STATIC.md); never copy a value.
 *    The structure to read is in templates/machine_mixed_arch.c.tmpl.
 *  - The header comment right below is STALE. It describes the v1 machine
 *    (load_base and reset_pc of the first attempt). The code was changed to v2:
 *    trust the LOAD_BASE / RESET_PC defines, not that comment.
 *  - Verification was bypassed. The runtime patches force every digest and
 *    signature-padding comparison in the bootloader to "equal" and the crypto
 *    engine model does no cryptography, so a run of this machine reaches
 *    verify_ok only as "reached, bypassed" (see bypasses.md and README.md).
 *  - Several bypasses are unverified (cause never confirmed, or a patch kept
 *    after its likely root cause turned out to be a model error), and 22 ledger entries
 *    have no recorded side effect. bypasses.md lists them at the top.
 *  - The runtime patch table has no build identification and checks each entry
 *    on its own; kernel rows assume a fixed kernel address (no randomisation).
 *    The ledger engine in templates/machine_mixed_arch.c.tmpl is the corrected
 *    shape (identified target, atomic groups, apply-or-record).
 *  - The kernel log of this machine is visible only through a memory dump of
 *    the log region, not on the UART.
 * Original source follows, unchanged.
 * ===========================================================================
 */
/*
 * QEMU machine: rehost-sma136ua136usqsfdyj1-preloader  (MediaTek preloader, AArch32)
 *
 * NEW STAGE (round ~21): runs preloader.img for real instead of skipping it
 * (bypasses.md #1 documented that skip as "a practical choice to narrow this
 * attempt's scope to LK-alone" - not a methodology change). The LK-only
 * machine (sma136ua136usqsfdyj1_full.c) hit a structural wall at 0x32c8
 * (ARM32_ATTEMPT.md 7-n) that needs real DRAM-training output only preloader
 * itself produces. Running preloader's own algorithm under emulation - even
 * with fake/default register readback - gives a DERIVED value, not a guess.
 *
 * Entry point derivation (this round, from preloader.img directly - not
 * borrowed): the file is a BRLYT-headed image (magic "BRLYT" at file offset
 * 0, matches "preloader_payload.bin" used by this workspace's Ghidra project
 * at file offset 0x200 onward) followed by a chained GFH "FILE_INFO" header
 * (magic 0x014d4d4d, "MMM\x01") declaring load_addr=0x200f10 at payload
 * offset 0x600. Right after a second, shorter GFH-style block, payload
 * offset 0x6f4 (= VA 0x201604) holds the first instruction with no
 * cross-references from anywhere else in the image (confirmed via Ghidra:
 * zero refs, and it is NOT inside any auto-detected function) - an
 * unconditional `b 0x201620`. Everything that follows is textbook ARM reset
 * code: CPSR mode switch to SVC + IRQ/FIQ disable, SCTLR I-cache-on/D-cache-off,
 * then a full r0-lr register clear, then MIDR read + bitfield extraction to
 * branch on CPU part number and affinity (primary vs secondary core, and
 * Cortex-A55 vs Cortex-A76 per the DTB's cluster0/cluster1 - matches this
 * exact device). This pattern (register clear immediately after a save of
 * the raw incoming r4) is the same shape as LK's own crt0, and is only
 * reachable from BROM's own jump - no bypass needed for this part, same
 * reasoning as LK's reset_pc.
 *
 * Derived premises:
 *   load_base   0x200f10  (GFH FILE_INFO header, file offset 0x600 within
 *               the header-stripped payload - preloader.img's own GFH table,
 *               not borrowed from LK or any other device)
 *   reset_pc    0x201604  (first unreferenced instruction after the header
 *               chain, see above - this round's own disassembly)
 *   memory      SRAM, not DRAM - preloader runs BEFORE DRAM training, so it
 *               must execute from on-chip SRAM. Exact MT6833 SRAM size is
 *               not yet derived; a generously-sized placeholder RAM region
 *               is mapped so the image and its runtime stack/bss fit, to be
 *               narrowed once real bounds are observed (data abort outside
 *               it would be the signal).
 *   cpu         cortex-a55, aarch64=false (same as LK - this device boots
 *               AArch32 end to end until the kernel handoff SMC)
 *
 * This stage is EXPECTED to hit many new unmapped-MMIO stop points before it
 * gets anywhere - exactly like sma136ua136usqsfdyj1_full.c's first ~9 rounds.
 * Each one gets the same treatment: disassemble the real fault, derive what
 * the address is from the DTB/strings, add a minimal placeholder, document
 * in bypasses.md. The goal is not a complete preloader boot - it is reaching
 * far enough to read back whatever FUN_00231e90 (DRAM init orchestrator,
 * ARM32_ATTEMPT.md 7-n) writes into its result buffers, and feed THAT
 * (derived from really running the real algorithm) into the LK machine's
 * boot-tag instead of the LK machine's own guesswork.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qemu/error-report.h"
#include "qemu/log.h"
#include "qemu/units.h"
#include "qemu/timer.h"
#include "qobject/qlist.h"
#include "hw/qdev-properties.h"
#include "system/cpus.h"
#include "qom/object.h"
#include "hw/sysbus.h"
#include "hw/boards.h"
#include "hw/qdev-core.h"
#include "hw/loader.h"
#include "system/reset.h"
#include "system/system.h"
#include "target/arm/cpu.h"
#include "target/arm/cpu-features.h"
#include "target/arm/cpregs.h"
#include "cpu.h"
#include "chardev/char-fe.h"
#include "hw/arm/machines-qom.h"
#include "exec/cpu-common.h"
#include "exec/tb-flush.h"
#include <sys/mman.h>
#include <fcntl.h>

#define TYPE_REHOST_PRELOADER_MACHINE MACHINE_TYPE_NAME("rehost-sma136ua136usqsfdyj1-preloader")
OBJECT_DECLARE_SIMPLE_TYPE(RehostPreloaderState, REHOST_PRELOADER_MACHINE)

/* ---- Memory skeleton ---- */
/* Round 2 finding: every CPU-type dispatch branch in crt0 (MIDR partnum
 * checks against 0xd03/0xd04 = Cortex-A53/A35, neither of which is this
 * device's real Cortex-A55/A76 - re-verified by hand, ARM32_ATTEMPT.md 9-c)
 * converges on the SAME continuation before reaching a jump to 0x227a84,
 * which runs a byte-fill loop with a length literal (0xdeadbeff) that
 * overflows to a near-wraparound end address. Since this path is identical
 * regardless of CPU type, real Cortex-A55 silicon hits the exact same code -
 * meaning this almost certainly DOES fault on real hardware too, quickly
 * (our SRAM is only 8MiB), and the resulting Data Abort is handled by a real
 * vector table BROM's own ROM leaves mapped at 0x0 (LOVECS, SCTLR.V=0 is the
 * common reset default - matches this round's observed IFAR/DFAR values,
 * all low addresses). We have nothing mapped at 0x0, so the abort cascades
 * into an unrecoverable Prefetch-Abort loop instead. This is an
 * architectural placeholder (every vector slot self-loops, distinguishable
 * by the PC/FAR value if we land on one), not a guessed data value - no
 * attempt is made to invent what a "real" handler would do. */
#define VECTOR_BASE   0x00000000ULL
#define VECTOR_SIZE   0x1000ULL

/* SRAM region sized generously (8MiB) to hold the ~4MiB preloader.img plus
 * runtime stack/bss/heap - exact real SRAM bounds not yet derived, see file
 * header comment. Based at 0x100000 (1MiB), round enough below load_base
 * (0x200f10) to leave room for anything preloader expects below its own
 * image (e.g. a boot-arg/handoff block from BROM) without guessing its
 * exact size yet. */
#define SRAM_BASE     0x00100000ULL
#define SRAM_SIZE     (8ULL * MiB)

#define LOAD_BASE     0x200910ULL     /* v2: payload offset 0 = 0x200910 (GFH at payload+0x600 = 0x200f10); proven by *0x251078==0xc00 and jump literal 0x227a85 -> real main prologue */
#define RESET_PC      0x201004ULL     /* v2: old 0x201604 - 0x600 */

#define UART_BASE     0x11002000ULL   /* DTB serial@11002000 - same physical
                                        * UART as the LK machine; preloader
                                        * likely uses it too for early log */
#define UART_SIZE     0x1000ULL
#define UART_TX_OFF   0x00ULL
#define UART_LSR_OFF  0x14ULL
#define UART_LSR_RX_READY  0x01ULL
#define UART_LSR_TX_EMPTY  0x60ULL   /* THRE|TEMT: LK putc (0x48292d0a) waits for (LSR & 0x60) == 0x60 */

/* MSDC0 (eMMC controller), round 3 finding - preloader's device-registry
 * lookup (FUN_00206a54) returns NULL for "boot device(1)" because nothing
 * ever registered a storage device (ARM32_ATTEMPT.md 9-g). Real MSDC strings
 * confirmed in this binary ("[MSDC] before bug_on", "MSDC_FIFOCS",
 * "eMMC cid:", "msdc_cmd") - a real MMC/SD host controller driver exists.
 * DTB: msdc@11230000 (index 0, bus-width 8 = the eMMC/boot device; the DTB
 * ALSO declares msdc@11240000/index 1 for the SD slot, bus-width 4 - not
 * mapped yet, only the boot device). Pure absorbing placeholder (reads 0,
 * writes ignored) - same first step as every LK MMIO placeholder before it:
 * map it, observe the actual next fault/behaviour, refine from there. Not
 * yet known whether read-as-zero lets registration succeed or fail cleanly. */
#define MSDC0_BASE    0x11230000ULL
#define MSDC0_SIZE    0x10000ULL

/* GPIO boot-strap read, round 3 finding (ARM32_ATTEMPT.md 9-h):
 * FUN_002311bc (the function that decides whether to probe MSDC at all)
 * reads *(0x100056f0) and branches on bits 17-18 (mask 0x60000): value
 * 0x20000 -> calls FUN_00229b50 (the real MSDC/eMMC probe, traced this
 * round); anything else -> calls FUN_0023a968 (a different storage driver
 * entirely) and MSDC is never touched. 0x100056f0 falls inside the DTB's
 * gpio@10005000 block (0x10005000 + 0x6f0 = 0x100056f0) - a hardware
 * boot-strap-pin read, not a software flag we failed to initialize. This
 * device's DTB independently confirms it boots from MSDC0/eMMC
 * (msdc@11230000, bus-width 8 = the classic eMMC signature; msdc@11240000,
 * bus-width 4, is the SD slot) - so 0x20000 at this exact offset is the
 * DTB-grounded expected value, not an invented one. */
#define GPIO_BASE     0x10005000ULL
#define GPIO_SIZE     0x1000ULL
#define GPIO_BOOTSEL_OFF  0x6f0ULL
#define GPIO_BOOTSEL_VAL  0x20000ULL   /* bits 17-18 of mask 0x60000 - eMMC */

/* PL_LOG_STORE device-list node injection (round 10, bypasses.md #21) - see
 * the long comment at the injection site (uart_write) for the full
 * derivation. DEVICE_NODE_ADDR sits in the free SRAM span between the image
 * end (0x600d10) and DRAM_STRUCT_BASE (0x700000), well clear of both. */
#define DEVICE_LIST_HEAD_VA  0x270704ULL
#define DEVICE_NODE_ADDR     0x690000ULL
#define DEVICE_NODE_SIZE     0x40ULL

/* ---- State ---- */
struct RehostPreloaderState {
    MachineState parent_obj;
    ARMCPU *cpu;
    MemoryRegion uart_io;
    MemoryRegion msdc0_io;
    MemoryRegion gpio_io;
    CharFrontend uart_chr;
    uint8_t  rx[256];
    unsigned rx_head, rx_tail, rx_count;
    uint8_t  msdc0_regs[MSDC0_SIZE];
    bool     device_node_injected;
};

static RehostPreloaderState *g_pl_state;

/* ---- UART (copied convention from the LK machine - UNVERIFIED 16550-ish
 * layout, bypasses.md #2 in the LK machine applies here too until checked
 * against preloader's own driver code) ---- */
static uint64_t uart_read(void *opaque, hwaddr addr, unsigned size) {
    RehostPreloaderState *s = opaque;
    if (addr == UART_LSR_OFF) {
        uint64_t v = UART_LSR_TX_EMPTY;
        if (s->rx_count > 0) v |= UART_LSR_RX_READY;
        return v;
    }
    if (addr == UART_TX_OFF && s->rx_count > 0) {
        uint8_t c = s->rx[s->rx_head];
        s->rx_head = (s->rx_head + 1) % sizeof(s->rx);
        s->rx_count--;
        return c;
    }
    return 0;
}

/* PL_LOG_STORE device-list node injection - round 10, bypasses.md #21.
 * ARM32_ATTEMPT.md 9-k/9-m: every character this UART prints tail-calls
 * through FUN_00227c4c into a check that, if the list FUN_00206a54 searches
 * is still empty, retriggers FUN_00227a38's whole device search - which
 * fails, prints more characters, and recurses without bound (confirmed via
 * gdb: SP grows +0x38 per visit until it runs off the end of SRAM, no
 * matter how much margin bypasses.md #18 gives it). The list head
 * (DEVICE_LIST_HEAD_VA = 0x270704) is a genuine BSS global - crt0 zeroes it
 * on every boot, so it cannot be pre-seeded from machine-init C code (same
 * class of problem as bypasses.md #13's first, failed attempt). Writing it
 * here instead, on the first character this UART ever transmits, is safe
 * BECAUSE we have already observed (bypasses.md #14) that real console
 * output only starts well after crt0's BSS-clear loops have both completed
 * - this is the same established "wait until a point we know is safe"
 * technique, just triggered by a UART write instead of machine-init.
 * The injected node: offset 0x00 = type 1 (matches FUN_00227790's "find
 * device type 1" call, confirmed via disassembly), offset 0x1c = 0 (next
 * pointer, NULL - a one-entry list, not invented beyond what's needed to
 * be found). All other fields - including the "+4" field the success path
 * multiplies into a capacity calculation - are left at 0, the same
 * "unknown value -> empty scratch, not a guessed number" principle used
 * throughout this machine (bypasses.md #3, #11, #13). This does NOT claim
 * to be a real, working device - it only stops the search from failing, so
 * whatever the capacity math does with a zero should surface as a NEW,
 * single, traceable stop point instead of the current unbounded recursion -
 * that would itself be progress even if the new stop point needs its own
 * fix next. */
static void inject_device_list_node(RehostPreloaderState *s) {
    MachineState *ms = MACHINE(s);
    uint8_t *sram = memory_region_get_ram_ptr(ms->ram);
    uint8_t *node = sram + (DEVICE_NODE_ADDR - SRAM_BASE);
    memset(node, 0, DEVICE_NODE_SIZE);
    *(uint32_t *)(node + 0x00) = 1;   /* type = 1 */
    *(uint32_t *)(node + 0x1c) = 0;   /* next = NULL */
    *(uint32_t *)(sram + (DEVICE_LIST_HEAD_VA - SRAM_BASE)) = (uint32_t)DEVICE_NODE_ADDR;
    info_report("rehost-preloader: bypass - injected minimal device-list "
                "node (type=1, all other fields zero) at 0x%" PRIx64
                ", list head 0x270704 now points to it (bypasses.md #21, "
                "round 10)", (uint64_t)DEVICE_NODE_ADDR);
}

static void uart_write(void *opaque, hwaddr addr, uint64_t val, unsigned size) {
    RehostPreloaderState *s = opaque;
    if (addr == UART_TX_OFF) {
        uint8_t c = (uint8_t)val;
        qemu_chr_fe_write_all(&s->uart_chr, &c, 1);
    }
}

static const MemoryRegionOps uart_io_ops = {
    .read = uart_read,
    .write = uart_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
};

/* Pure absorbing placeholder - same pattern as the LK machine's UART2/IOCFG/
 * PWRAP placeholders (bypasses.md #4/#5/#6 in that machine). Only .write is
 * still used directly (by gpio_io_ops) since MSDC0 moved to a real
 * read-write register bank (round 9, below). */
static void absorb_write(void *opaque, hwaddr addr, uint64_t val, unsigned size) {
}

/* MSDC0 (0x11230000) real-enough register bank - round 9, replaces the pure
 * absorbing placeholder (bypasses.md #16) now that ARM32_ATTEMPT.md 9-l/9-m
 * traced FUN_0022acb0's actual reset sequence: it writes MSDC_CFG (+0x0) bit2
 * (RST) then polls the SAME register until bit2 self-clears, then sets
 * +0x14 bit31 (FIFOCLR-style ack) and polls the SAME register until THAT
 * self-clears too - both are real MTK MSDC hardware auto-clear "command"
 * bits (write 1 to start, hardware clears when done), not invented
 * behavior. Every other offset this sequence touches (+0x4, +0xc, +0x30,
 * +0x70, +0xb8, ...) is plain read-modify-write with no polling observed,
 * so a faithful read-back shadow (not pure absorb) is needed for those
 * accumulated OR/AND sequences to behave correctly. */
/* ---- MSDC0 + eMMC card (bypasses.md #35) ----
 * Register map/bit meanings follow the MediaTek MSDC host controller (DTB
 * msdc@11230000, bus-width 8 = eMMC). Command/response behaviour is a minimal
 * eMMC 5.1 card backed by a disk image (env REHOST_EMMC_IMG, 512-byte sectors).
 * Each behaviour is added only when the real driver observed it (see log lines
 * "MSDC CMD n arg"). */
static int msdc_logn;
static uint8_t *emmc_img; static uint64_t emmc_size;
static bool g_post_handoff;   /* tentative definition; set when LK's hand-off to the AArch64 core happened (bypasses.md #103) */
static uint32_t msdc_int, msdc_inten, sdc_arg, sdc_cmd, sdc_resp[4], sdc_blknum = 1;
static unsigned emmc_state;           /* 0 idle 1 ready 2 ident 3 stby 4 tran */
static uint8_t extcsd[512];
static uint32_t erase_start, erase_end;   /* eMMC CMD35/CMD36 range (bypasses.md #113) */
static uint8_t *rd_buf; static size_t rd_len, rd_pos; static uint32_t rd_arg; static bool rd_dma_done, dma_armed; static size_t rd_dma_pos, wr_dma_pos;
static uint32_t dma_sa, dma_ctrl, dma_cfg, dma_len, dma_sa_h4;   /* dma_sa_h4: MSDC_DMA_SA_H4B (0x8c) bits[3:0] = address bits [35:32] (bypasses.md #110) */
static uint32_t cmd23_count;
/* bypasses.md #46: MID 0x15 (Samsung) CBX 01 OID 00 PNM "DV6DAB" = entry 3 of the preloader eMMC+LPDDR4X table at 0x251f50
 * (4 GB: 2 GB + 2 GB ranks); the table is the only evidence of which parts the firmware accepts, the exact part of this unit is unknown */
static uint8_t emmc_cid[16] = {0,0,0,0,0,0,0,0,0,0x01,0x00,0x00,0x00,0x12,0x34,0x01};   /* bytes 0..8 (MID, CBX, OID, PNM) are copied from the firmware's own table at machine init (below) */
/* bypasses.md #111: the kernel (Samsung add_partition check) rejects partitions whose start/end is not aligned to the write-protect group:
 * "mmcblk0: pN could not be added: 5 / Start 0x7800 of disk mmcblk0 not write group aligned". ERASE_GRP_SIZE / ERASE_GRP_MULT / WP_GRP_SIZE (CSD bits 46:32, bytes 10-11)
 * were 0x1f each (32*32*32 sectors = 16 MiB); they are 0 now (1 sector) and EXT_CSD HC_ERASE_GRP_SIZE/HC_WP_GRP_SIZE (224/221) are 1 (512 KiB, below). */
static uint8_t emmc_csd[16] = {0xd0,0x0f,0x00,0x32,0x0f,0x59,0x03,0xff,0xff,0xff,0x00,0x00,0x92,0x40,0x40,0x01};

#define INT_CMDRDY  (1u<<8)
#define INT_XFERC   (1u<<12)
#define INT_DXFER   (1u<<13)

static void emmc_set_r1(uint32_t status) { sdc_resp[0] = status; }

/* bypasses.md #57: RPMB (EXT_CSD[179] & 7 == 3). The preloader reads the write counter / data through
 * authenticated frames. No key exists in this model, so the MAC field (frame bytes 196..227) is left
 * zero and not verified; counters/addresses/nonce follow the JEDEC frame layout:
 * 228..483 data, 484..499 nonce, 500..503 write counter, 504 address, 506 block count, 508 result, 510 type. */
static uint8_t rpmb_resp[512]; static uint32_t rpmb_counter;
static uint8_t *wr_buf; static size_t wr_len, wr_pos; static bool wr_pending;
static uint64_t wr_lba;
static size_t wr_commit_off, g_gpd_done;   /* bypasses.md #130: bytes of the current write command already committed to the image / bytes moved by the last GPD run */
static void rpmb_process(const uint8_t *f) {
    unsigned type = (f[510] << 8) | f[511];
    if (msdc_logn < 5000) { msdc_logn++; info_report("RPMB request type=0x%x addr=%u blocks=%u", type, (f[504] << 8) | f[505], (f[506] << 8) | f[507]); }
    if (type == 0x0005) return;                         /* result read: keep the stored response */
    memset(rpmb_resp, 0, 512);
    memcpy(rpmb_resp + 484, f + 484, 16);               /* nonce echo */
    switch (type) {
    case 0x0001: break;                                 /* key programming: accepted */
    case 0x0002: break;                                 /* write counter read */
    case 0x0003: rpmb_counter++; break;                 /* authenticated data write */
    case 0x0004: memcpy(rpmb_resp + 504, f + 504, 4);   /* data read: zero data, echo address/count */
                 break;
    default: rpmb_resp[509] = 1; break;                 /* general failure */
    }
    rpmb_resp[510] = ((type | 0x0100) >> 8) & 0xff;
    rpmb_resp[511] = (type | 0x0100) & 0xff;
    if (type == 0x0004 || type == 0x0002 || type == 0x0003 || type == 0x0001) { rpmb_resp[500] = rpmb_counter >> 24; rpmb_resp[501] = rpmb_counter >> 16; rpmb_resp[502] = rpmb_counter >> 8; rpmb_resp[503] = rpmb_counter; }
}
static void emmc_write_done(void) {
    if ((extcsd[179] & 7) == 3 && wr_len >= 512) rpmb_process(wr_buf);
    else if (g_post_handoff && emmc_img && (uint64_t)wr_lba * 512 + wr_len <= emmc_size) {
        /* bypasses.md #116: after the hand-off writes land in the (MAP_PRIVATE) image so that the kernel/init can format and use partitions (userdata, metadata) during the run; the file is never modified. */
        memcpy(emmc_img + (uint64_t)wr_lba * 512, wr_buf, wr_len);
    } else if (msdc_logn < 5000) { msdc_logn++; info_report("MSDC write %zu bytes to LBA %" PRIu64 " (dropped)", wr_len, wr_lba); }
    g_free(wr_buf); wr_buf = NULL; wr_len = wr_pos = 0; wr_pending = false;
    msdc_int |= INT_XFERC | INT_DXFER;
}
static void emmc_dma_run(void);
static void emmc_cmd(uint32_t cmd, uint32_t arg) {
    unsigned op = cmd & 0x3f, dtype = (cmd >> 11) & 3;
    uint32_t st = (emmc_state << 9) | 0x100;
    if (msdc_logn < 5000) { msdc_logn++; info_report("MSDC CMD%u arg=0x%x raw=0x%x", op, arg, cmd); }
    if (getenv("REHOST_MSDC_TRACE4") && g_post_handoff) { static int n8; if (n8 < 400000) { n8++; info_report("MSDC4 CMD%u arg=0x%x dtype=%u blknum=%u cmd23=%u dma_ctrl=0x%x dma_len=0x%x", op, arg, dtype, (unsigned)sdc_blknum, (unsigned)cmd23_count, dma_ctrl, dma_len); } }
    /* bypasses.md #130: a write command is no longer completed by emmc_write_done (every START commits its bytes), so its state is dropped when the next data command or the stop command
     * arrives; otherwise the next read's DMA START was taken for a continuation of the write and no data was delivered (LK ended in Odin download mode: sec_check_download 7). */
    if (op == 0 || op == 7 || op == 8 || op == 12 || op == 17 || op == 18 || op == 24 || op == 25 || op == 30 || op == 31) { g_free(wr_buf); wr_buf = NULL; wr_len = wr_pos = 0; wr_pending = false; wr_dma_pos = 0; }
    g_free(rd_buf); rd_buf = NULL; rd_len = rd_pos = 0; rd_dma_done = false; rd_dma_pos = 0;
    switch (op) {
    case 0: emmc_state = 0; break;
    case 1: sdc_resp[0] = 0xc0ff8080u; emmc_state = 1; break;
    case 2: for (int i = 0; i < 4; i++) sdc_resp[3 - i] = (emmc_cid[4*i] << 24) | (emmc_cid[4*i+1] << 16) | (emmc_cid[4*i+2] << 8) | emmc_cid[4*i+3];
            emmc_state = 2; break;
    case 3: emmc_state = 3; emmc_set_r1((3u << 9) | 0x100); break;
    case 9: for (int i = 0; i < 4; i++) sdc_resp[3 - i] = (emmc_csd[4*i] << 24) | (emmc_csd[4*i+1] << 16) | (emmc_csd[4*i+2] << 8) | emmc_csd[4*i+3]; break;
    case 7: emmc_state = 4; emmc_set_r1((4u << 9) | 0x100); break;
    case 6: if (((arg >> 24) & 3) == 3) extcsd[(arg >> 16) & 0xff] = (arg >> 8) & 0xff;
            emmc_set_r1(st); break;
    case 8: rd_len = 512; rd_buf = g_malloc(512); memcpy(rd_buf, extcsd, 512); emmc_set_r1(st); break;
    case 17: case 18: {
            uint64_t blocks = (op == 17) ? 1 : (cmd23_count ? cmd23_count : sdc_blknum);
            uint64_t off = (uint64_t)arg * 512; rd_arg = arg;
            rd_len = blocks * 512; rd_buf = g_malloc0(rd_len);
            if ((extcsd[179] & 7) == 3) memcpy(rd_buf, rpmb_resp, MIN(rd_len, (size_t)512));
            else if (emmc_img && off < emmc_size) memcpy(rd_buf, emmc_img + off, MIN(rd_len, emmc_size - off));
            emmc_set_r1(st); cmd23_count = 0; break; }
    case 24: case 25: {
            uint64_t blocks = (op == 24) ? 1 : (cmd23_count ? cmd23_count : sdc_blknum);
            g_free(wr_buf); wr_len = blocks * 512; wr_buf = g_malloc0(wr_len); wr_pos = 0; wr_pending = true; wr_lba = arg; wr_commit_off = 0; wr_dma_pos = 0;
            emmc_set_r1(st); cmd23_count = 0; break; }
    /* bypasses.md #112: eMMC CMD30 (SEND_WRITE_PROT: 32 bits) and CMD31 (SEND_WRITE_PROT_TYPE: 64 bits). The kernel's partition scan asks for the write-protect state of the
     * write group at every partition start ("msdc0 -> XXX PIO Data Timeout: CMD<31>" -> "mmcblk0: pN could not be added: 5"); no group is protected: all zeros. */
    case 30: rd_len = 4; rd_buf = g_malloc0(4); emmc_set_r1(st); break;
    case 31: rd_len = 8; rd_buf = g_malloc0(8); emmc_set_r1(st); break;
    /* bypasses.md #113: eMMC erase (CMD35 ERASE_GROUP_START, CMD36 ERASE_GROUP_END, CMD38 ERASE; arg 0 = erase, 1 = trim, 3 = discard). First-stage init wipes the metadata
     * partition because the factory misc.bin carries a recovery command ("--data_resizing"): BLKDISCARD -> "Discard failure on /dev/block/by-name/metadata: I/O error" ->
     * WipeBlockDevice aborts init. The range is zeroed in the (in-memory) image; the write is not persisted. */
    case 35: erase_start = arg; emmc_set_r1(st); break;
    case 36: erase_end = arg; emmc_set_r1(st); break;
    case 38: if (emmc_img && erase_start <= erase_end) {
                 uint64_t o0 = (uint64_t)erase_start * 512, o1 = ((uint64_t)erase_end + 1) * 512;
                 if (o0 < emmc_size) memset(emmc_img + o0, 0, MIN(o1, emmc_size) - o0);
             }
             emmc_set_r1(st); break;
    case 12: wr_pending = false; emmc_set_r1(st); break;
    case 23: cmd23_count = arg & 0xffff; emmc_set_r1(st); break;
    default: emmc_set_r1(st); break;
    }
    rd_pos = 0;
    if (op == 35 || op == 36 || op == 38) { static int nlog; if (nlog < 200) { nlog++; info_report("MSDC CMD%u arg=0x%x -> resp0=0x%x (erase range 0x%x..0x%x)", op, arg, sdc_resp[0], erase_start, erase_end); } }
    /* bypasses.md #74: an eMMC does not answer SD/SDIO probing. LK's mmc_init_card tries CMD8(0x1aa), CMD55, ACMD41 (and CMD5)
     * first and expects a command timeout (MSDC_INT bit9) to fall back to CMD1; answering them made it take the SD path
     * ("[mmc_init_card]: failed, err=4"). CMD8 is only valid as SEND_EXT_CSD in transfer state (4). */
    if (op == 55 || op == 41 || op == 5 || (op == 8 && emmc_state != 4)) {
        msdc_int |= (1u << 9);
        return;
    }
    msdc_int |= INT_CMDRDY;
    /* bypasses.md #120: DMA_CTRL.START is a write-1 pulse, not a level (see the 0x98 write handler); a START that arrives before the data command is remembered */
    if (dtype && dma_armed && (rd_buf || (wr_pending && wr_buf))) { static int nar; if (nar < 200) { nar++; info_report("MSDC STALE-ARMED run at CMD%u arg=0x%x sa=0x%x len=0x%x", op, arg, dma_sa, dma_len); } dma_armed = false; emmc_dma_run(); }
    if (rd_buf && dtype) {
        /* DMA path completes when DMA_CTRL start is written; PIO path is drained via RXDATA */
        if (false) emmc_dma_run();   /* DMA START was armed before the command (bypasses.md #120: START now self-clears, so it is not re-written later) */
    }
}
/* bypasses.md #78: MSDC descriptor DMA (DMA_CTRL bit8 = MODE). LK builds a GPD at DMA_SA ({flags: hwo=bit0, bdp=bit1; next; ptr; ...}) whose
 * ptr is a BD chain ({flags: eol=bit0; next; ptr = data buffer; buflen}); the basic-mode model overwrote the descriptors with the sector.
 * Walk the chain and copy to/from the BD buffers; hardware clears HWO when the transfer is done. */
static bool msdc_gpd_xfer(uint8_t *buf, size_t len, bool to_mem) {
    /* bypasses.md #110: the kernel's msdc driver uses 36-bit DMA addresses (DRAM sits at 0x40000000.., buffers above 4 GiB): MSDC_DMA_SA_H4B (0x8c) holds bits [35:32] of the
     * GPD address and the descriptors carry NEXT_H4 = gpd_info/bd_info bits [27:24] and PTR_H4 = bits [31:28]. The kernel EXT_CSD read (CMD8) therefore went to 0x128ee800 instead of
     * 0x1_28ee_e800 -> SEC_COUNT read as 0 -> "mmcblk0: ... 0 B", no partitions, init aborts. LK keeps all of them 0. */
    uint32_t gpd[8] = {0};
    uint64_t gpd_addr = ((uint64_t)(dma_sa_h4 & 0xf) << 32) | dma_sa;
    address_space_read(&address_space_memory, gpd_addr, MEMTXATTRS_UNSPECIFIED, gpd, sizeof(gpd));
    if (getenv("REHOST_MSDC_TRACE5")) { static int n6; if (n6 < 60) { n6++; info_report("MSDC5 GPD %08x %08x %08x %08x %08x %08x %08x %08x len=%zu dir=%d ctrl=0x%x", gpd[0], gpd[1], gpd[2], gpd[3], gpd[4], gpd[5], gpd[6], gpd[7], len, (int)to_mem, dma_ctrl); } }
    size_t done = 0;
    /* bypasses.md #120: the engine only works on a GPD whose HWO bit (0) is set; a START written while the GPD was already completed (HWO cleared) moves nothing */
    g_gpd_done = 0;
    if (g_post_handoff && !(gpd[0] & 1)) return false;
    if (gpd[0] & 2) {                                   /* bdp: BD chain */
        uint64_t bdp = ((uint64_t)((gpd[0] >> 28) & 0xf) << 32) | gpd[2];
        for (int guard = 0; guard < 64 && done < len; guard++) {
            uint32_t bd[4] = {0};
            address_space_read(&address_space_memory, bdp, MEMTXATTRS_UNSPECIFIED, bd, sizeof(bd));
            size_t n = MIN((size_t)(bd[3] & 0xffffff), len - done);
            if (getenv("REHOST_MSDC_TRACE5")) { static int n7; if (n7 < 120) { n7++; info_report("MSDC5 BD%d %08x %08x %08x %08x", guard, bd[0], bd[1], bd[2], bd[3]); } }
            uint64_t data = ((uint64_t)((bd[0] >> 28) & 0xf) << 32) | bd[2];
            if (getenv("REHOST_MSDC_TRACE3") && g_post_handoff && (((bd[0] >> 24) & 0xff) || data < 0x40000000ULL)) { static int nb; if (nb < 400) { nb++; info_report("MSDC BD %d: bd=%08x %08x %08x %08x -> data 0x%" PRIx64 " n=%zu%s", guard, bd[0], bd[1], bd[2], bd[3], data, n, (data < 0x40000000ULL) ? " **NOT RAM**" : ""); } }
            if (getenv("REHOST_MSDC_TRACE4") && g_post_handoff) { static int n4; if (n4 < 30000) { n4++; info_report("MSDC4 t=%" PRId64 "ms %s lba=0x%x len=%zu bd%d data=0x%" PRIx64 " n=%zu", qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL), to_mem ? "R" : "W", rd_arg, len, guard, data, n); } }
            if (to_mem) address_space_write(&address_space_memory, data, MEMTXATTRS_UNSPECIFIED, buf + done, n);
            else        address_space_read(&address_space_memory, data, MEMTXATTRS_UNSPECIFIED, buf + done, n);
            done += n;
            if (bd[0] & 1) break;                       /* eol */
            bdp = ((uint64_t)((bd[0] >> 24) & 0xf) << 32) | bd[1];
        }
    } else {                                            /* GPD points straight at the data */
        size_t n = MIN((size_t)((gpd[3] & 0xffff) ? (gpd[3] & 0xffff) : len), len);
        uint64_t data = ((uint64_t)((gpd[0] >> 28) & 0xf) << 32) | gpd[2];
        if (to_mem) address_space_write(&address_space_memory, data, MEMTXATTRS_UNSPECIFIED, buf, n);
        else        address_space_read(&address_space_memory, data, MEMTXATTRS_UNSPECIFIED, buf, n);
        done = n;
    }
    g_gpd_done = done;
    gpd[0] &= ~1u;                                      /* HWO cleared by the engine */
    address_space_write(&address_space_memory, gpd_addr, MEMTXATTRS_UNSPECIFIED, gpd, sizeof(gpd));
    if (msdc_logn < 5000) { msdc_logn++; info_report("MSDC GPD DMA %s %zu/%zu bytes (GPD@0x%" PRIx64 ")", to_mem ? "->mem" : "<-mem", done, len, gpd_addr); }
    return true;
}
static void emmc_dma_run(void) {
    bool desc = (dma_ctrl & 0x100) != 0;
    if (getenv("REHOST_MSDC_TRACE4") && g_post_handoff) { static int n9; if (n9 < 400000) { n9++; info_report("MSDC4 DMARUN desc=%d rd_buf=%d wr=%d rdlen=%zu pos=%zu done=%d ctrl=0x%x len=0x%x sa=0x%x", desc, rd_buf != NULL, (int)wr_pending, rd_len, rd_dma_pos, (int)rd_dma_done, dma_ctrl, dma_len, dma_sa); } }
    if (wr_pending && wr_buf) {
        /* bypasses.md #130: a write command's BLK_NUM is only an upper bound; the data actually moved is what the DMA programs (GPD/BD chain total, or DMA_LEN per START in basic
         * mode), in as many STARTs as the kernel needs. The model used to wait until BLK_NUM*512 bytes had arrived and then write that whole length: when fewer bytes came, the
         * command was never completed and the data was LOST (zero blocks in files: the decompressed ART apex had 33 zero 4 KiB blocks -> libart crash in zygote), and a completed
         * one wrote zero padding over neighbouring blocks. Every START now commits exactly the bytes it moved at the running position of the command. */
        static uint8_t scratch[1 << 20];
        size_t n;
        if (desc) {
            if (!msdc_gpd_xfer(scratch, sizeof(scratch), false)) return;
            n = g_gpd_done;
        } else {
            n = wr_len > wr_dma_pos ? wr_len - wr_dma_pos : 0;
            if (g_post_handoff && dma_len && dma_len < n) n = dma_len;
            if (n > sizeof(scratch)) n = sizeof(scratch);
            address_space_read(&address_space_memory, ((uint64_t)(dma_sa_h4 & 0xf) << 32) | dma_sa, MEMTXATTRS_UNSPECIFIED, scratch, n);
            if (g_post_handoff) dma_ctrl &= ~1u;
        }
        if ((extcsd[179] & 7) == 3) {                   /* RPMB frames: needs the whole buffer */
            memcpy(wr_buf + MIN(wr_dma_pos, wr_len), scratch, MIN(n, wr_len - MIN(wr_dma_pos, wr_len)));
            wr_dma_pos += n;
            if (wr_dma_pos < wr_len) return;
            wr_dma_pos = 0;
            emmc_write_done();
            return;
        }
        if (g_post_handoff && emmc_img && (uint64_t)wr_lba * 512 + wr_commit_off + n <= emmc_size) memcpy(emmc_img + (uint64_t)wr_lba * 512 + wr_commit_off, scratch, n);
        else if (msdc_logn < 5000) { msdc_logn++; info_report("MSDC write %zu bytes to LBA %" PRIu64 "+0x%zx (dropped)", n, wr_lba, wr_commit_off); }
        wr_commit_off += n; wr_dma_pos += n;
        msdc_int |= INT_XFERC | INT_DXFER;
        return;
    }
    if (!rd_buf) return;
    /* bypasses.md #119: the kernel writes DMA_CTRL with the START bit set more than once per command (resume/stop bits keep bit0), and every write re-ran the
     * descriptor chain: the already-delivered sectors were copied AGAIN into BD buffers that the kernel had meanwhile freed and reused (slab inodes, kernfs nodes,
     * page-cache pages) -> random "kernfs rb_insert_color NULL deref", "__atime_needs_update paging request c3ab3e09..." (vbmeta bytes inside an inode) Oopses.
     * A real engine moves the data once per command (HWO of the GPD is cleared when it finishes). */
    if (desc) {
        /* (a positional "several GPD runs per read command" variant made LK enter Odin download mode: LK's multi-block reads rely on one run per command) */
        if (g_post_handoff && rd_dma_done) return;
        if (!msdc_gpd_xfer(rd_buf, rd_len, true)) return;
        rd_dma_done = true;
    } else {
        if (getenv("REHOST_MSDC_TRACE4") && g_post_handoff) { static int n5; if (n5 < 30000) { n5++; info_report("MSDC4 t=%" PRId64 "ms basic-R lba=0x%x len=%zu sa=0x%x h4=%x dma_len=0x%x ctrl=0x%x cfg=0x%x done=%d", qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL), rd_arg, rd_len, dma_sa, dma_sa_h4, dma_len, dma_ctrl, dma_cfg, (int)rd_dma_done); } }
        /* bypasses.md #120: basic-DMA moves DMA_LEN bytes per START; the model used to write the whole command (128 KiB) at DMA_SA although the kernel armed a
         * 4 KiB chunk -> 124 KiB over slab/inode/kernfs pages. Chunks are delivered in order, and START self-clears (it read back as 1, so every later
         * read-modify-write of DMA_CTRL re-armed the engine). */
        size_t n = rd_len - rd_dma_pos;
        if (g_post_handoff && dma_len && dma_len < n) n = dma_len;
        if (g_post_handoff && rd_dma_done) return;
        MemTxResult r = address_space_write(&address_space_memory, ((uint64_t)(dma_sa_h4 & 0xf) << 32) | dma_sa, MEMTXATTRS_UNSPECIFIED, rd_buf + rd_dma_pos, n);
        if (msdc_logn < 5000) { msdc_logn++; info_report("MSDC DMA %zu bytes -> 0x%x (r=%d)", n, dma_sa, (int)r); }
        rd_dma_pos += n;
        if (g_post_handoff) dma_ctrl &= ~1u;
        if (rd_dma_pos >= rd_len) rd_dma_done = true;
    }
    rd_pos = rd_len;
    msdc_int |= INT_XFERC | INT_DXFER;
}
/* bypasses.md #75: MSDC0 interrupt (DTB msdc@11230000 interrupts = <GIC_SPI 0x63 level-high>) -> GIC SPI 99. LK sleeps in WFI after starting a
 * DMA transfer and relies on this interrupt. Level = (MSDC_INT & MSDC_INTEN) != 0. */
static qemu_irq g_msdc_irq;
static void msdc_update_irq(void) {
    if (g_msdc_irq) qemu_set_irq(g_msdc_irq, (msdc_int & msdc_inten) != 0);
}
static uint64_t msdc0_read(void *opaque, hwaddr addr, unsigned size) {
    RehostPreloaderState *s = opaque;
    uint64_t v = 0;
    if (addr + size <= MSDC0_SIZE) memcpy(&v, s->msdc0_regs + addr, size);
    switch (addr) {
    case 0x0:  v &= ~(uint64_t)0x4; v |= 0x80; break;       /* RST self-clears; CKSTB */
    case 0x8:  v = 0x01ff0001u; break;                       /* MSDC_PS: card present, CMD+DAT0-7 lines high (R1b busy-wait on DAT0) */
    case 0xc:  v = msdc_int; break;
    case 0x10: v = msdc_inten; break;
    case 0x14: { size_t rem = rd_len - rd_pos; v = (rem > 128 ? 128 : rem); break; }  /* RX count; CLR self-clears */
    case 0x1c: { uint32_t w = 0; if (rd_buf && rd_pos < rd_len) { memcpy(&w, rd_buf + rd_pos, MIN((size_t)4, rd_len - rd_pos)); rd_pos += 4; }
                 v = w; if (rd_buf && rd_pos >= rd_len) msdc_int |= INT_XFERC; break; }
    case 0x34: v = sdc_cmd; break;
    case 0x38: v = sdc_arg; break;
    case 0x3c: v = 0; break;                                  /* SDC_STS: never busy */
    case 0x40: v = sdc_resp[0]; break;
    case 0x44: v = sdc_resp[1]; break;
    case 0x48: v = sdc_resp[2]; break;
    case 0x4c: v = sdc_resp[3]; break;
    case 0x50: v = sdc_blknum; break;
    }
    if (msdc_logn < 600 && addr != 0x0 && addr != 0x14 && addr != 0xc && addr != 0x8 && addr != 0x1c && addr != 0x3c) { msdc_logn++; info_report("MSDC R 0x%x = 0x%x", (unsigned)addr, (unsigned)v); }
    msdc_update_irq();
    return v;
}
static void msdc0_write(void *opaque, hwaddr addr, uint64_t val, unsigned size) {
    RehostPreloaderState *s = opaque;
    if (getenv("REHOST_MSDC_TRACE") && (addr == 0xc || addr == 0x10 || addr == 0x98 || addr == 0x0)) {
        static int n; if (n < 200) { n++; info_report("MSDC W 0x%x = 0x%x (INT=0x%x INTEN=0x%x)", (unsigned)addr, (unsigned)val, msdc_int, msdc_inten); }
    }
    if (0 && addr != 0x0) { msdc_logn++; info_report("MSDC W 0x%x = 0x%x", (unsigned)addr, (unsigned)val); }
    if (getenv("REHOST_MSDC_TRACE2")) {   /* every distinct MSDC register offset the first 3 times it is written (kernel phase: find the 64-bit DMA address high bits register) */
        static uint8_t cnt[0x400]; unsigned o = (unsigned)(addr >> 2);
        if (o < 0x400 && cnt[o] < 3) { cnt[o]++; info_report("MSDC W2 0x%x = 0x%x (size %u)", (unsigned)addr, (unsigned)val, size); }
    }
    if (getenv("REHOST_MSDC_TRACE6") && g_post_handoff && (addr == 0x10 || addr == 0x14 || (addr >= 0x8c && addr <= 0xa8))) { static int n6w; if (n6w < 2000000) { n6w++; info_report("MSDC6 W 0x%x = 0x%x", (unsigned)addr, (unsigned)val); } }
    if (addr + size <= MSDC0_SIZE) memcpy(s->msdc0_regs + addr, &val, size);
    switch (addr) {
    case 0xc:  msdc_int &= ~(uint32_t)val; break;            /* write-1-to-clear */
    case 0x10: msdc_inten = val; break;
    case 0x34: sdc_cmd = val; emmc_cmd(sdc_cmd, sdc_arg); break;   /* driver writes ARG first, then CMD starts the transaction */
    case 0x18: if (wr_pending && wr_buf && wr_pos + 4 <= wr_len) { memcpy(wr_buf + wr_pos, &val, 4); wr_pos += 4; if (wr_pos >= wr_len) emmc_write_done(); } break;
    case 0x38: sdc_arg = val; break;
    case 0x50: sdc_blknum = val; break;
    case 0x8c: dma_sa_h4 = val & 0xf; break;
    case 0x90: dma_sa = val; break;
    /* bypasses.md #120: START (bit 0) is a write-1 pulse. The model kept it set, so every later read-modify-write of DMA_CTRL while the kernel was still programming
     * the engine (mode/burst/stop bits, before DMA_SA of the NEW command was written) re-ran the engine with a stale DMA_SA/GPD and copied sector data over buffers the
     * kernel had already freed (kernfs/inode/slab corruption). A pulse with no data command pending is remembered and fires when the command arrives. */
    case 0x98: dma_ctrl = val & ~1u; { uint32_t rv = dma_ctrl; memcpy(s->msdc0_regs + 0x98, &rv, 4); } /* the raw register store must not read back START either */
        if (val & 1) { if (rd_buf || (wr_pending && wr_buf)) emmc_dma_run(); else dma_armed = true; } break;
    case 0x9c: dma_cfg = val; break;
    case 0xa8: dma_len = val; break;
    }
    msdc_update_irq();
}
static const MemoryRegionOps msdc0_io_ops = {
    .read = msdc0_read,
    .write = msdc0_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
};

/* GPIO boot-strap placeholder - absorbing except for the one confirmed
 * offset (see GPIO_BOOTSEL_OFF comment above). */
static uint64_t gpio_read(void *opaque, hwaddr addr, unsigned size) {
    if (getenv("REHOST_GPIO_TRACE")) {
        static uint8_t seen[0x1000 / 4];
        if (addr < 0x1000 && !seen[addr >> 2]) { seen[addr >> 2] = 1; info_report("GPIO first read +0x%x", (unsigned)addr); }
    }
    if (addr == GPIO_BOOTSEL_OFF) {
        return GPIO_BOOTSEL_VAL;
    }
    return 0;
}
static const MemoryRegionOps gpio_io_ops = {
    .read = gpio_read,
    .write = absorb_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 4 },
};

static int uart_can_receive(void *opaque) {
    RehostPreloaderState *s = opaque;
    return (int)(sizeof(s->rx) - s->rx_count);
}

static void uart_receive(void *opaque, const uint8_t *buf, int size) {
    RehostPreloaderState *s = opaque;
    for (int i = 0; i < size && s->rx_count < sizeof(s->rx); i++) {
        s->rx[s->rx_tail] = buf[i];
        s->rx_tail = (s->rx_tail + 1) % sizeof(s->rx);
        s->rx_count++;
    }
}

static const struct { uint64_t base, size; } dtb_blocks[] = {
    /* bypasses.md #54: eFuse controller, not in the DTB; address taken from FUN_00242dac (0x242dd4 literal) "[EFUSE] Start Check" */
    {0x11c10000ULL, 0x1000ULL},
    /* bypasses.md #64: chipid@08000000 (DTB node, below the 0x0c000000 shadow window): APHW code/subcode/version words read by the
     * boot-tag builder FUN_00224db4 (0x224ef8). Left 0: the real hw_code of this SoC is not derivable from the firmware images. */
    {0x08000000ULL, 0x1000ULL},
    {0xc000000ULL, 0x40000ULL},
    {0xc040000ULL, 0x200000ULL},
    {0xc400000ULL, 0x40000ULL},
    {0xc530000ULL, 0x5000ULL},
    {0xc538000ULL, 0x5000ULL},
    {0xc540000ULL, 0x22000ULL},
    {0xc562000ULL, 0x4ULL},
    {0xc562004ULL, 0x4ULL},
    {0xd000000ULL, 0x10000ULL},
    {0xd010000ULL, 0x1000ULL},
    {0xd01a000ULL, 0x1000ULL},
    {0xd020000ULL, 0x10000ULL},
    {0xd030000ULL, 0x10000ULL},
    {0xd040000ULL, 0x100ULL},
    {0xd040800ULL, 0x100ULL},
    {0xd040900ULL, 0x100ULL},
    {0xd040a00ULL, 0x100ULL},
    {0xd041000ULL, 0x3000ULL},
    {0xd0a0000ULL, 0x10000ULL},
    {0xd0c0000ULL, 0x40000ULL},
    {0x10000000ULL, 0x1000ULL},
    {0x10001000ULL, 0x1000ULL},
    {0x10002000ULL, 0x1000ULL},
    {0x10003000ULL, 0x1000ULL},
    {0x10005000ULL, 0x1000ULL},
    {0x10006000ULL, 0x1000ULL},
    {0x10007000ULL, 0x100ULL},
    {0x10008000ULL, 0x1000ULL},
    {0x1000a000ULL, 0x1000ULL},
    {0x1000b000ULL, 0x1000ULL},
    {0x1000c000ULL, 0xe00ULL},
    {0x1000ce00ULL, 0x200ULL},
    {0x1000d000ULL, 0x1000ULL},
    {0x1000e000ULL, 0x1000ULL},
    {0x1000f800ULL, 0x1000ULL},
    {0x10011000ULL, 0x1000ULL},
    {0x10012000ULL, 0x1000ULL},
    {0x10013000ULL, 0x1000ULL},
    {0x10014000ULL, 0x400ULL},
    {0x10014400ULL, 0x400ULL},
    {0x10014800ULL, 0x400ULL},
    {0x10014c00ULL, 0x400ULL},
    {0x10015000ULL, 0x1000ULL},
    {0x10016000ULL, 0x1000ULL},
    {0x10017000ULL, 0x1000ULL},
    {0x10018000ULL, 0x1000ULL},
    {0x10019000ULL, 0x1000ULL},
    {0x1001a000ULL, 0x1000ULL},
    {0x1001b000ULL, 0x1000ULL},
    {0x1001c000ULL, 0x1000ULL},
    {0x1001e000ULL, 0x4000ULL},
    {0x10022000ULL, 0x1000ULL},
    {0x10023000ULL, 0x1000ULL},
    {0x10024000ULL, 0x1000ULL},
    {0x10025000ULL, 0x1000ULL},
    {0x10026000ULL, 0x1000ULL},
    {0x10027000ULL, 0x8ffULL},
    {0x10027900ULL, 0x500ULL},
    {0x10028000ULL, 0x1000ULL},
    {0x10029000ULL, 0x100ULL},
    {0x10030000ULL, 0x1000ULL},
    {0x10033000ULL, 0x1000ULL},
    {0x10048000ULL, 0x1000ULL},
    {0x10200000ULL, 0x1000ULL},
    {0x10201000ULL, 0x1000ULL},
    {0x10202000ULL, 0x1000ULL},
    {0x10203000ULL, 0x1000ULL},
    {0x10204000ULL, 0x1000ULL},
    {0x10207000ULL, 0x1000ULL},
    {0x10208000ULL, 0x1000ULL},
    {0x10209000ULL, 0x1000ULL},
    {0x1020a000ULL, 0x1000ULL},
    {0x1020b000ULL, 0x1000ULL},
    {0x1020c000ULL, 0x1000ULL},
    {0x1020d000ULL, 0x1000ULL},
    {0x1020e000ULL, 0x1000ULL},
    {0x1020f000ULL, 0x1000ULL},
    {0x10210000ULL, 0x1000ULL},
    {0x10211000ULL, 0x1000ULL},
    {0x10212000ULL, 0x80ULL},
    {0x10212100ULL, 0x80ULL},
    {0x10212200ULL, 0x80ULL},
    {0x10212300ULL, 0x80ULL},
    {0x10213000ULL, 0x1000ULL},
    {0x10214000ULL, 0x1000ULL},
    {0x10215000ULL, 0x1000ULL},
    {0x10216000ULL, 0x1000ULL},
    {0x10217000ULL, 0x1000ULL},
    {0x10218000ULL, 0x1000ULL},
    {0x10219000ULL, 0x1000ULL},
    {0x1021a000ULL, 0x1000ULL},
    {0x1021b000ULL, 0x1000ULL},
    {0x1021c000ULL, 0x400ULL},
    {0x1021d000ULL, 0x1000ULL},
    {0x1021e000ULL, 0x1000ULL},
    {0x1021f000ULL, 0x1000ULL},
    {0x10225000ULL, 0x1000ULL},
    {0x10226000ULL, 0x1000ULL},
    {0x10227000ULL, 0x1000ULL},
    {0x10228000ULL, 0x4000ULL},
    {0x1022c000ULL, 0x1000ULL},
    {0x1022d000ULL, 0x1000ULL},
    {0x1022e000ULL, 0x1000ULL},
    {0x1022f000ULL, 0x1000ULL},
    {0x10230000ULL, 0x2000ULL},
    {0x10234000ULL, 0x1000ULL},
    {0x10235000ULL, 0x1000ULL},
    {0x10236000ULL, 0x1000ULL},
    {0x10238000ULL, 0x2000ULL},
    {0x1023c000ULL, 0x1000ULL},
    {0x1023d000ULL, 0x1000ULL},
    {0x1023e000ULL, 0x1000ULL},
    {0x1023f000ULL, 0x1000ULL},
    {0x10240000ULL, 0x2000ULL},
    {0x10242000ULL, 0x2000ULL},
    {0x10244000ULL, 0x1000ULL},
    {0x10245000ULL, 0x1000ULL},
    {0x10246000ULL, 0x1000ULL},
    {0x10248000ULL, 0x2000ULL},
    {0x1024a000ULL, 0x2000ULL},
    {0x1024c000ULL, 0x40ULL},
    {0x1024d000ULL, 0x1000ULL},
    {0x1024e000ULL, 0x1000ULL},
    {0x10250000ULL, 0x2000ULL},
    {0x10252000ULL, 0x2000ULL},
    {0x10254000ULL, 0x1000ULL},
    {0x10255000ULL, 0x1000ULL},
    {0x10256000ULL, 0x2000ULL},
    {0x10258000ULL, 0x2000ULL},
    {0x1025a000ULL, 0x2000ULL},
    {0x1025c000ULL, 0x1000ULL},
    {0x1025d000ULL, 0x1000ULL},
    {0x1025e000ULL, 0x1000ULL},
    {0x1025f000ULL, 0x1000ULL},
    {0x10260000ULL, 0x2000ULL},
    {0x10262000ULL, 0x2000ULL},
    {0x10264000ULL, 0x1000ULL},
    {0x10265000ULL, 0x1000ULL},
    {0x10266000ULL, 0x2000ULL},
    {0x10268000ULL, 0x2000ULL},
    {0x1026a000ULL, 0x2000ULL},
    {0x10274000ULL, 0x1000ULL},
    {0x10275000ULL, 0x1000ULL},
    {0x10309000ULL, 0x1000ULL},
    {0x1030a000ULL, 0x1000ULL},
    {0x1030b000ULL, 0x1000ULL},
    {0x1030c000ULL, 0x1000ULL},
    {0x1030d000ULL, 0x1000ULL},
    {0x10312000ULL, 0x1000ULL},
    {0x10313000ULL, 0x1000ULL},
    {0x10314000ULL, 0x1000ULL},
    {0x10318000ULL, 0x1000ULL},
    {0x10319000ULL, 0x1000ULL},
    {0x1031a000ULL, 0x1000ULL},
    {0x1031b000ULL, 0x1000ULL},
    {0x10400000ULL, 0x28000ULL},
    {0x10440000ULL, 0x10000ULL},
    {0x10450000ULL, 0x100ULL},
    {0x10451000ULL, 0x4ULL},
    {0x10451004ULL, 0x4ULL},
    {0x10460000ULL, 0x100ULL},
    {0x10461000ULL, 0x4ULL},
    {0x10461004ULL, 0x4ULL},
    {0x10470000ULL, 0x100ULL},
    {0x10471000ULL, 0x4ULL},
    {0x10471004ULL, 0x4ULL},
    {0x10480000ULL, 0x100ULL},
    {0x10481000ULL, 0x4ULL},
    {0x10481004ULL, 0x4ULL},
    {0x10490000ULL, 0x100ULL},
    {0x10491000ULL, 0x4ULL},
    {0x10491004ULL, 0x4ULL},
    {0x10500000ULL, 0xc0000ULL},
    {0x10721000ULL, 0x1000ULL},
    {0x10724000ULL, 0x1000ULL},
    {0x10730000ULL, 0x3000ULL},
    {0x10740000ULL, 0x1000ULL},
    {0x10752000ULL, 0x1000ULL},
    {0x10760000ULL, 0x40000ULL},
    {0x107a5000ULL, 0x4ULL},
    {0x107a5020ULL, 0x4ULL},
    {0x107a5024ULL, 0x4ULL},
    {0x107a5028ULL, 0x4ULL},
    {0x107a502cULL, 0x4ULL},
    {0x107a5030ULL, 0x4ULL},
    {0x107fb000ULL, 0x100ULL},
    {0x107fb100ULL, 0x4ULL},
    {0x107fb10cULL, 0x4ULL},
    {0x107fc000ULL, 0x100ULL},
    {0x107fc100ULL, 0x4ULL},
    {0x107fc10cULL, 0x4ULL},
    {0x107fd000ULL, 0x100ULL},
    {0x107fd100ULL, 0x4ULL},
    {0x107fd10cULL, 0x4ULL},
    {0x107fe000ULL, 0x100ULL},
    {0x107fe100ULL, 0x4ULL},
    {0x107fe10cULL, 0x4ULL},
    {0x107ff000ULL, 0x100ULL},
    {0x107ff100ULL, 0x4ULL},
    {0x107ff10cULL, 0x4ULL},
    {0x10900000ULL, 0x40000ULL},
    {0x10940000ULL, 0xc0000ULL},
    {0x10a00000ULL, 0x40000ULL},
    {0x10a40000ULL, 0xc0000ULL},
    {0x11001000ULL, 0x1000ULL},
    {0x11002000ULL, 0x1000ULL},
    {0x11003000ULL, 0x1000ULL},
    {0x11007000ULL, 0x1000ULL},
    {0x1100a000ULL, 0x100ULL},
    {0x1100b000ULL, 0x1000ULL},
    {0x1100c000ULL, 0x1000ULL},
    {0x1100e000ULL, 0x1000ULL},
    {0x11010000ULL, 0x100ULL},
    {0x11012000ULL, 0x100ULL},
    {0x11013000ULL, 0x100ULL},
    {0x11015000ULL, 0x1000ULL},
    {0x11017000ULL, 0x1000ULL},
    {0x11018000ULL, 0x100ULL},
    {0x11019000ULL, 0x100ULL},
    {0x1101d000ULL, 0x100ULL},
    {0x1101e000ULL, 0x100ULL},
    {0x11020000ULL, 0x1000ULL},
    {0x11200000ULL, 0x10000ULL},
    {0x11210000ULL, 0x2000ULL},
    {0x11212000ULL, 0xd000ULL},
    {0x11230000ULL, 0x10000ULL},
    {0x11240000ULL, 0x1000ULL},
    {0x11270000ULL, 0x2300ULL},
    {0x11278000ULL, 0x1000ULL},
    {0x11c30000ULL, 0x1000ULL},
    {0x11c70000ULL, 0x1000ULL},
    {0x11cb0000ULL, 0x1000ULL},
    {0x11cb1000ULL, 0x1000ULL},
    {0x11d00000ULL, 0x1000ULL},
    {0x11d01000ULL, 0x1000ULL},
    {0x11d02000ULL, 0x1000ULL},
    {0x11d10000ULL, 0x1000ULL},
    {0x11d20000ULL, 0x1000ULL},
    {0x11d21000ULL, 0x1000ULL},
    {0x11d22000ULL, 0x1000ULL},
    {0x11d23000ULL, 0x1000ULL},
    {0x11d40000ULL, 0x1000ULL},
    {0x11e00000ULL, 0x1000ULL},
    {0x11e01000ULL, 0x1000ULL},
    {0x11e02000ULL, 0x1000ULL},
    {0x11e03000ULL, 0x1000ULL},
    {0x11e20000ULL, 0x1000ULL},
    {0x11e40000ULL, 0x10000ULL},
    {0x11e50000ULL, 0x1000ULL},
    {0x11e60000ULL, 0x1000ULL},
    {0x11ea0000ULL, 0x1000ULL},
    {0x11f00000ULL, 0x1000ULL},
    {0x11f01000ULL, 0x1000ULL},
    {0x11f50000ULL, 0x1000ULL},
    {0x11fa0000ULL, 0xc000ULL},
    {0x13000000ULL, 0x4000ULL},
    {0x13e00000ULL, 0x112000ULL},
    {0x13fb7000ULL, 0x3000ULL},
    {0x13fbb000ULL, 0x1000ULL},
    {0x13fbc000ULL, 0x1000ULL},
    {0x13fbd000ULL, 0x1000ULL},
    {0x13fbf000ULL, 0x1000ULL},
    {0x13fce000ULL, 0x2000ULL},
    {0x14000000ULL, 0x1000ULL},
    {0x14001000ULL, 0x1000ULL},
    {0x14002000ULL, 0x1000ULL},
    {0x14003000ULL, 0x1000ULL},
    {0x14004000ULL, 0x1000ULL},
    {0x14005000ULL, 0x1000ULL},
    {0x14006000ULL, 0x1000ULL},
    {0x14007000ULL, 0x1000ULL},
    {0x14008000ULL, 0x1000ULL},
    {0x14009000ULL, 0x1000ULL},
    {0x1400a000ULL, 0x1000ULL},
    {0x1400b000ULL, 0x1000ULL},
    {0x1400c000ULL, 0x1000ULL},
    {0x1400d000ULL, 0x1000ULL},
    {0x1400e000ULL, 0x1000ULL},
    {0x1400f000ULL, 0x1000ULL},
    {0x14010000ULL, 0x1000ULL},
    {0x14011000ULL, 0x1000ULL},
    {0x14012000ULL, 0x1000ULL},
    {0x14013000ULL, 0x1000ULL},
    {0x14014000ULL, 0x1000ULL},
    {0x14015000ULL, 0x1000ULL},
    {0x14016000ULL, 0x1000ULL},
    {0x14017000ULL, 0x1000ULL},
    {0x14018000ULL, 0x1000ULL},
    {0x14019000ULL, 0x1000ULL},
    {0x1401a000ULL, 0x1000ULL},
    {0x1401b000ULL, 0x1000ULL},
    {0x1401c000ULL, 0x1000ULL},
    {0x1401d000ULL, 0x1000ULL},
    {0x1401e000ULL, 0x1000ULL},
    {0x1401f000ULL, 0xe1000ULL},
    {0x15010000ULL, 0x1000ULL},
    {0x15011000ULL, 0x1000ULL},
    {0x15012000ULL, 0x1000ULL},
    {0x15020000ULL, 0x1000ULL},
    {0x15021000ULL, 0xc000ULL},
    {0x1502e000ULL, 0x1000ULL},
    {0x1502f000ULL, 0x1000ULL},
    {0x15030000ULL, 0x1000ULL},
    {0x15810000ULL, 0x1000ULL},
    {0x15811000ULL, 0x1000ULL},
    {0x15812000ULL, 0x1000ULL},
    {0x15820000ULL, 0x1000ULL},
    {0x15821000ULL, 0x1000ULL},
    {0x15822000ULL, 0x1000ULL},
    {0x15823000ULL, 0x1000ULL},
    {0x15824000ULL, 0x1000ULL},
    {0x15825000ULL, 0x1000ULL},
    {0x15826000ULL, 0x1000ULL},
    {0x15827000ULL, 0x1000ULL},
    {0x15828000ULL, 0x1000ULL},
    {0x15829000ULL, 0x1000ULL},
    {0x1582a000ULL, 0x1000ULL},
    {0x1582b000ULL, 0x1000ULL},
    {0x1582c000ULL, 0x1000ULL},
    {0x1582e000ULL, 0x1000ULL},
    {0x15830000ULL, 0x1000ULL},
    {0x16000000ULL, 0x40000ULL},
    {0x17000000ULL, 0x10000ULL},
    {0x17010000ULL, 0x1000ULL},
    {0x17011000ULL, 0x1000ULL},
    {0x17020000ULL, 0x2000ULL},
    {0x17030000ULL, 0x10000ULL},
    {0x17040000ULL, 0x10000ULL},
    {0x17820000ULL, 0x10000ULL},
    {0x18000000ULL, 0x100000ULL},
    {0x1a000000ULL, 0x1000ULL},
    {0x1a001000ULL, 0x1000ULL},
    {0x1a002000ULL, 0x1000ULL},
    {0x1a003000ULL, 0x1000ULL},
    {0x1a004000ULL, 0x1000ULL},
    {0x1a005000ULL, 0x1000ULL},
    {0x1a006000ULL, 0x1000ULL},
    {0x1a007000ULL, 0x1000ULL},
    {0x1a008000ULL, 0x1000ULL},
    {0x1a009000ULL, 0x1000ULL},
    {0x1a00c000ULL, 0x1000ULL},
    {0x1a00d000ULL, 0x1000ULL},
    {0x1a00f000ULL, 0x1000ULL},
    {0x1a010000ULL, 0x1000ULL},
    {0x1a011000ULL, 0x1000ULL},
    {0x1a030000ULL, 0x8000ULL},
    {0x1a038000ULL, 0x8000ULL},
    {0x1a04f000ULL, 0x1000ULL},
    {0x1a050000ULL, 0x8000ULL},
    {0x1a058000ULL, 0x8000ULL},
    {0x1a06f000ULL, 0x1000ULL},
    {0x1a070000ULL, 0x8000ULL},
    {0x1a078000ULL, 0x8000ULL},
    {0x1a08f000ULL, 0x1000ULL},
    {0x1a092000ULL, 0x1000ULL},
    {0x1a093000ULL, 0x1000ULL},
    {0x1a094000ULL, 0x1000ULL},
    {0x1a095000ULL, 0x1000ULL},
    {0x1a096000ULL, 0x1000ULL},
    {0x1a097000ULL, 0x1000ULL},
    {0x1a101000ULL, 0x1000ULL},
    {0x1b000000ULL, 0x1000ULL},
    {0x1b001000ULL, 0x1000ULL},
    {0x1b002000ULL, 0x1000ULL},
    {0x1b003000ULL, 0x1000ULL},
    {0x1b00e000ULL, 0x1000ULL},
    {0x1b00f000ULL, 0x1000ULL},
    {0x1b100000ULL, 0x1000ULL},
    {0x1b10f000ULL, 0x1000ULL},
    {0x1f000000ULL, 0x1000ULL},
    {0x1f001000ULL, 0x1000ULL},
    {0x1f002000ULL, 0x1000ULL},
    {0x1f003000ULL, 0x1000ULL},
    {0x1f004000ULL, 0x1000ULL},
    {0x1f005000ULL, 0x1000ULL},
    {0x1f006000ULL, 0x1000ULL},
    {0x1f007000ULL, 0x1000ULL},
    {0x1f008000ULL, 0x1000ULL},
    {0x1f009000ULL, 0x1000ULL},
    {0x1f00a000ULL, 0x1000ULL},
    {0x1f00b000ULL, 0x1000ULL},
    {0x1f00c000ULL, 0x1000ULL},
    {0x1f00d000ULL, 0x1000ULL},
    {0x1f00e000ULL, 0x1000ULL},
    {0x1f00f000ULL, 0x1000ULL},
};

/* v2 (bypasses.md #30): every DTB-declared peripheral reg block in 0x10000000-0x1fffffff
 * that has no dedicated model below is mapped as a faithful read-write shadow
 * (reads return what was last written, 0 initially). Dedicated models (UART,
 * GPIO bootsel, MSDC0) are mapped first and win; overlapping blocks are skipped. */
/* v2 (bypasses.md #32): per-address read overrides for registers whose real hardware
 * behaviour is a status bit the firmware polls for. Each entry is DERIVED from the
 * polling loop it unblocks (address, bit, why) - see the comment on each line. */
static const struct { uint64_t addr; uint32_t val; } read_overrides[] = {
    /* SPM PWR_STATUS / PWR_STATUS_2ND (0x10006000+0x16c/0x170): mtcmos loop at 0x23664e polls bit21 of both until set after power-on request */
    /* bypasses.md #96: BL31 (0x48c0c5f4..0x48c0c60c, entered through LK's kernel-jump SMC) spins on "ldr w0,[0x0c53a840]; cmp w0,#0xc001; b.ne". The register is in the
     * MCUSYS (mcucfg 0x0c530000) block; the compared constant is the only evidence for its ready value, so reads report 0xc001. */
    {0x0c53a840ULL, 0x0000c001U},
    /* bypasses.md #98: SPM CPU_PWR_STATUS (0x10006174). The kernel's PSCI CPU_ON (smp_init) makes BL31 power a core through the SPM and poll this register for the
     * core bit (0x48c13100: "ldr w1,[0x10006174]; and w0,w0,w1", mask 2 = core 1) until it is set; the cores are reported as powered. */
    {0x10006174ULL, 0xffffffffU},
    {0x1000616cULL, 0xffffffffU},
    {0x10006170ULL, 0xffffffffU},
    /* bypasses.md #48: DRAMC_NAO +0x170 (ctx offset 0x40170): FUN_002210cc (0x2210a0) polls == 8 (command state machine idle)
     * after an SPCMD with AO+0x108 bit15 set, 100000 x 1 ms timeout; reports idle immediately */
    {0x10234170ULL, 0x00000008U},
    {0x10244170ULL, 0x00000008U},
};
/* AND-masks (self-clearing start bits) applied before the OR-masks. */
static const struct { uint64_t addr; uint32_t mask; } read_and_masks[] = {
    /* bypasses.md #41: topckgen frequency meter FUN_0020dfd8 (CLK26CALI_0 0x10000220 / CLK26CALI_1 0x10000224):
     * firmware sets bit4 = start and polls it until clear (0x20e01e); result = (reg1 & 0xffff) * 26 >> 10 MHz */
    {0x10000220ULL, ~0x10U},
    {0x10000224ULL, 0xffff0000U},
};
/* OR-masks applied on top of the stored value: status bits the firmware polls for completion. */
static const struct { uint64_t addr; uint32_t mask; } read_or_masks[] = {
    /* HACC (DTB hacc@1000a000) +0x008 bit31: set after the firmware sets bit30 (loop at 0x2415d4) */
    {0x1000a008ULL, 0x80008000U},
    /* bypasses.md #49: DRAMC_NAO +0x80 bit2 (ctx 0x40080), FUN_00220d90 poll */
    /* bypasses.md #50: DDRPHY_NAO +0x510 bit2 (ctx 0x80510) poll in FUN_00210cc8, request is AO-PHY +0x670 */
    {0x10236510ULL, 0x00000004U},
    {0x10246510ULL, 0x00000004U},
    /* bypasses.md #51: DDRPHY_NAO +0x10 bits16/17 (ctx 0x80010), FUN_0020d340 (0x20d432) waits for both with no timeout (per-channel DLL/calibration done) */
    {0x10236010ULL, 0x00030000U},
    {0x10246010ULL, 0x00030000U},
    /* bypasses.md #52: DRAMC_NAO +0x54 bit0 (ctx 0x40054) = test-engine compare complete, polled 100 x 1 ms at 0x2136fa; error bits stay 0 (pass) */
    {0x10234054ULL, 0x00000001U},
    {0x10244054ULL, 0x00000001U},
    /* bypasses.md #53: DDRPHY reg 0x109470b0 handshake-ack bits [15:14], [19:18], ... (all-ones) (FUN_0020d8d8 loop 0x20d994 waits for (bits & chmask) == chmask, no timeout) */
    {0x109470b0ULL, 0xffffffffU},
    {0x109570b0ULL, 0xffffffffU},
    /* bypasses.md #54: eFuse CON bit0 = ready, polled up to 1048576 times after a bit2 re-init request (0x242c10) */
    {0x11c10000ULL, 0x00000001U},
    /* bypasses.md #56: TRNG (DTB trng@1020f000) CTRL bit31 = data ready after start (bit0), polled at 0x240f24; data register stays 0 (no entropy source) */
    {0x1020f000ULL, 0x80000000U},
    /* bypasses.md #58: keypad matrix KP_MEM1..5 (0x10010004 + 4*(key>>4)), FUN_002263a4 generic path: a set bit means NOT pressed */
    {0x10010004ULL, 0x0000ffffU}, {0x10010008ULL, 0x0000ffffU}, {0x1001000cULL, 0x0000ffffU}, {0x10010010ULL, 0x0000ffffU}, {0x10010014ULL, 0x0000ffffU},
    /* bypasses.md #69: HACC (0x1000a000) +0x104 bit15 = done, polled by BL31 at 0x48c159d8 / 0x48c15984 (hardware crypto, no result computed) */
    {0x1000a104ULL, 0x00008000U},
    /* bypasses.md #73: AUXADC (0x11001000) DAT0..DAT15 (+0x14 + 4*ch) bit12 = data ready; LK adc_api waits for it ('wait for channel[6] ready bit == 1').
     * Data values stay 0 (no analog inputs). The register layout (mt6577-style) is assumed from the DTB compatible mt6768-auxadc. */
    {0x11001014ULL, 0x00001000U}, {0x11001018ULL, 0x00001000U}, {0x1100101cULL, 0x00001000U}, {0x11001020ULL, 0x00001000U}, {0x11001024ULL, 0x00001000U}, {0x11001028ULL, 0x00001000U}, {0x1100102cULL, 0x00001000U}, {0x11001030ULL, 0x00001000U}, {0x11001034ULL, 0x00001000U}, {0x11001038ULL, 0x00001000U}, {0x1100103cULL, 0x00001000U}, {0x11001040ULL, 0x00001000U}, {0x11001044ULL, 0x00001000U}, {0x11001048ULL, 0x00001000U}, {0x1100104cULL, 0x00001000U}, {0x11001050ULL, 0x00001000U},
    {0x10234080ULL, 0x00000004U},
    {0x10244080ULL, 0x00000004U},
    /* bypasses.md #42: DRAMC_NAO SPCMDRESP (0x10234088 ch A, 0x10244088 ch B; ctx offset 0x40088): the firmware pulses an SPCMD bit
     * (+0x60124, value 0x800) and polls bit0 (MRW response) at 0x22180c; the command is treated as completed instantly */
    {0x10234088ULL, 0xffffffffU},
    {0x10244088ULL, 0xffffffffU},
    /* bypasses.md #44: DRAMC_NAO +0x120 (ctx offset 0x40120): FUN_00221014 polls (reg & mask) == mask, mask = 1 or 3, with a
     * 100000 x 1 ms timeout; MRW/MRR response bits report done instantly (stub, no DRAM device behind) */
    {0x10234120ULL, 0x00000003U},
    {0x10244120ULL, 0x00000003U},
    /* freq meter counter: 0x400 -> 1024 * 26 / 1024 = 26 MHz for whichever clock was selected (stub, no real clock tree) */
    {0x10000224ULL, 0x00000400U},
};
typedef struct DtbShadow { MemoryRegion mr; uint8_t *buf; uint64_t size; uint64_t base; } DtbShadow;
/* diagnostic: report a register that is read 3000 times in a row (a poll loop) once per distinct address */
static bool g_post_handoff;   /* set when LK's hand-off to the AArch64 core happened (bypasses.md #103) */
static uint64_t poll_last, poll_cnt; static uint64_t poll_reported[64]; static unsigned poll_nrep;
static uint8_t nao_seen[2][0x400];
static void poll_note(uint64_t addr, uint64_t v) {
    if ((addr & ~0xfffULL) == 0x10234000ULL || (addr & ~0xfffULL) == 0x10244000ULL) {
        unsigned ch = (addr >> 16) & 1, ix = (addr & 0xfff) >> 2;
        if (!nao_seen[ch][ix]) { nao_seen[ch][ix] = 1; info_report("rehost-preloader: NAO%u first read +0x%x = 0x%" PRIx64, ch, (unsigned)(addr & 0xfff), v); }
    }
    if (addr == poll_last) {
        if (++poll_cnt == 3000) {
            for (unsigned i = 0; i < poll_nrep; i++) if (poll_reported[i] == addr) return;
            if (poll_nrep < 64) poll_reported[poll_nrep++] = addr;
            info_report("rehost-preloader: POLL 0x%" PRIx64 " = 0x%" PRIx64, addr, v);
        }
    } else { poll_last = addr; poll_cnt = 0; }
}
/* bypasses.md #45: LPDDR4X mode registers behind the DRAMC MRR engine (FUN_00221648: MR number -> AO+0x128 bits[15:8],
 * SPCMD AO+0x124 bit12, response NAO+0x88 bit1, data NAO+0x8c). check_qvl (dramc_top.c:1626, 0x21ee32) compares MR5
 * vendor id and the rank sizes decoded from MR8 against the 15-entry table at 0x251f50 (eMMC+LPDDR4X parts). The values
 * below select the 4 GB Samsung entries (MR5 = 0x01 Samsung, MR8 = 0x10 as returned by dram_mr_value() below; an earlier comment said 0x08 but the code never returned it, the table match is what was observed to pass check_qvl). */
static uint32_t dram_mr_sel[2];
static uint32_t dram_mr_value(uint32_t mr) {
    switch (mr) {
    case 5: return 0x01;
    case 8: return 0x10;
    default: return 0;
    }
}
static uint64_t shadow_read(void *o, hwaddr a, unsigned sz) {
    DtbShadow *d = o; uint64_t v = 0;
    if (d->base + a == 0x1023408cULL) { uint32_t m = dram_mr_value(dram_mr_sel[0]); return (m << 16) | m; }
    if (d->base + a == 0x1024408cULL) { uint32_t m = dram_mr_value(dram_mr_sel[1]); return (m << 16) | m; }
    /* bypasses.md #95 / #103: SPM PWR_STATUS / PWR_STATUS_2ND. Before the hand-off the preloader polls them with the all-ones stub (read_overrides). Afterwards bit k
     * follows domain k = the PWR_CON register at 0x10006300 + 4k: set only while both PWR_ON (bit2) and PWR_ON_2ND (bit3) are set, which is the sequence the kernel
     * (clk-mt6833-pg.c spm_mtcmos_ctrl_*_pwr) and LK (MD1, bit0 at 0x10006300) use: power on = set bit2, then bit3, poll status set; off = clear bit2/bit3, poll clear. */
    if ((d->base + a == 0x1000616cULL || d->base + a == 0x10006170ULL) && d->base == 0x10006000ULL && g_post_handoff && 0x400 <= d->size) {
        uint32_t st = 0;
        for (unsigned k = 0; k < 32; k++) { uint32_t pc; memcpy(&pc, d->buf + 0x300 + 4 * k, 4); if ((pc & 0xc) == 0xc) st |= 1u << k; }
        return st;
    }
    for (size_t i = 0; i < sizeof(read_overrides)/sizeof(read_overrides[0]); i++) {
        if (read_overrides[i].addr == d->base + a) return read_overrides[i].val;
    }
    if (a + sz <= d->size) memcpy(&v, d->buf + a, sz);
    /* bypasses.md #102: SPM *_PWR_CON registers (0x10006300..0x100063ff): the SRAM_PDN_ACK bits [15:12] mirror SRAM_PDN [11:8] instantly (clk-mt6833-pg.c, e.g. VDE2_PWR_CON
     * 0x10006340: "bit8 set -> poll bit12 until set", "bit8 clear -> poll bit12 until clear"; observed in the kernel log: WARNING clk-mt6833-pg.c:902 at +0x1d4) */
    if (d->base == 0x10006000ULL && a >= 0x300 && a < 0x400 && sz == 4) v = (v & ~0xf000ULL) | ((v & 0x0f00ULL) << 4);
    for (size_t i = 0; i < sizeof(read_and_masks)/sizeof(read_and_masks[0]); i++) {
        if (read_and_masks[i].addr == d->base + a) v &= read_and_masks[i].mask;
    }
    for (size_t i = 0; i < sizeof(read_or_masks)/sizeof(read_or_masks[0]); i++) {
        if (read_or_masks[i].addr == d->base + a) v |= read_or_masks[i].mask;
    }
    poll_note(d->base + a, v);
    return v;
}
/* bypasses.md #94: INFRACFG_AO bus-protect handshakes. LK (FUN_482197d0, modem power-down) writes a mask to a SET register and polls the status register until the bits
 * are set (0x100012a0 -> 0x10001228 bit7; 0x10001b84 -> 0x10001b90 mask 0x10401); a write to SET+4 releases the bits (the matching CLR register, inferred from the
 * SET/CLR/STA layout). The bus-protect hardware acknowledges instantly: the status register mirrors SET minus CLR. */
/* The kernel (clk-mt6833-pg.c) uses the same SET/CLR/STA scheme for every group. Offsets from its register dump (EN, STA0, STA1) and code (VDE: SET 0x2d4,
 * CLR 0x2d8, STA1 0x2ec): groups with SET = EN+4 and CLR = EN+8 are MM (EN 0x2d0), 2 (0x710), MM_2 (0xdc8), VDNR (0xb80); the first two groups have their own
 * SET/CLR (0x2a0/0x2a4 for EN 0x220, 0x2a8/0x2ac for EN 0x250, inferred). STA0 mirrors STA1. bypasses.md #101. */
static const struct { uint64_t set, sta; } bus_protect[] = {
    {0x100012a0ULL, 0x10001228ULL}, {0x10001b84ULL, 0x10001b90ULL}, {0x100012a8ULL, 0x10001258ULL},
    {0x100012d4ULL, 0x100012ecULL}, {0x10001714ULL, 0x10001724ULL}, {0x10001dccULL, 0x10001dd8ULL},
};
static void bus_protect_write(DtbShadow *d, uint64_t addr, uint64_t v) {
    for (size_t i = 0; i < sizeof(bus_protect)/sizeof(bus_protect[0]); i++) {
        uint64_t so = bus_protect[i].sta - d->base; uint32_t cur;
        if (addr != bus_protect[i].set && addr != bus_protect[i].set + 4) continue;
        if (so + 4 > d->size) continue;
        memcpy(&cur, d->buf + so, 4);
        if (addr == bus_protect[i].set) cur |= (uint32_t)v; else cur &= ~(uint32_t)v;
        memcpy(d->buf + so, &cur, 4);
    }
}
static void shadow_write(void *o, hwaddr a, uint64_t v, unsigned sz) {
    DtbShadow *d = o;
    bus_protect_write(d, d->base + a, v);
    if (d->base + a == 0x10230128ULL) dram_mr_sel[0] = (v >> 8) & 0xff;
    if (d->base + a == 0x10240128ULL) dram_mr_sel[1] = (v >> 8) & 0xff;
    if (a + sz <= d->size) memcpy(d->buf + a, &v, sz);
}
static const MemoryRegionOps shadow_ops = {
    .read = shadow_read, .write = shadow_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
};


/* v2: catch-all for undeclared peripheral space (priority below every real block).
 * Reads 0, writes ignored; logs each distinct 4KB page the first time it is touched
 * so unknown-but-real blocks (e.g. 0x11c10000) show up in the console log. */
static uint8_t catchall_seen[0x14000];
static uint64_t catchall_read(void *o, hwaddr a, unsigned sz) {
    uint64_t pg = (0x0c000000ULL + a) >> 12, idx = pg - 0xc000;
    if (idx < 0x14000 && !catchall_seen[idx]) {
        catchall_seen[idx] = 1;
        info_report("rehost-preloader: UNMODELLED read  0x%" PRIx64, (uint64_t)(0x0c000000ULL + a));
    }
    return 0;
}
static void catchall_write(void *o, hwaddr a, uint64_t v, unsigned sz) {
    uint64_t pg = (0x0c000000ULL + a) >> 12, idx = pg - 0xc000;
    if (idx < 0x14000 && !catchall_seen[idx]) {
        catchall_seen[idx] = 1;
        info_report("rehost-preloader: UNMODELLED write 0x%" PRIx64 " = 0x%" PRIx64, (uint64_t)(0x0c000000ULL + a), v);
    }
}
static const MemoryRegionOps catchall_ops = {
    .read = catchall_read, .write = catchall_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
};


/* v2 (bypasses.md #31): MediaTek APXGPT general-purpose timer (DTB apxgpt@10008000).
 * The firmware udelay/timeout helper (0x2375e8) reads GPT4_CNT at +0x48 and compares
 * deltas; modelled as a free-running 13 MHz counter (same 13 MHz the DTB declares
 * for the arch timer) driven by the QEMU virtual clock. Other offsets: RW shadow. */
/* bypasses.md #76: APXGPT timers 1..5 with interrupt (DTB apxgpt interrupts = <GIC_SPI 0xd3 level-high> -> INTID 243). LK programs GPT5
 * as its scheduler tick (observed: IRQEN=0x10, GPT5 CON=1, CLK=0x10, CMP=0x147): CLK bit4 selects the 32.768 kHz source (0x147 ticks =
 * 10 ms), otherwise 13 MHz; CON bit0 enable, bit1 clear, bits[5:4] mode (00 one-shot, 01 repeat). Layout per timer n: base 0x10*n,
 * +0 CON, +4 CLK, +8 CNT, +0xc COMPARE; IRQEN 0x00, IRQSTA 0x04, IRQACK 0x08. GPT4's CNT keeps the free-running 13 MHz meaning. */
/* time scale of the free-running 13 MHz counter; the preloader's slow DRAM waits need it > 1, but a scaled counter wraps its 32 bits
 * every 4.3 s / scale, so it is dropped to 1 at the AArch64 handoff (bypasses.md #85) */
static uint64_t g_gpt_scale;
static qemu_irq g_gpt_irq;
static QEMUTimer *g_gpt_timer[6];
static int64_t g_gpt_start[6];
static uint32_t gpt_reg32(hwaddr a);
static uint8_t gpt_regs[0x1000];
static uint32_t gpt_reg32(hwaddr a) { uint32_t v; memcpy(&v, gpt_regs + a, 4); return v; }
static void gpt_update_irq(void) {
    if (getenv("REHOST_GPT_TRACE")) { static int lastl = -1; int l = (gpt_reg32(0x00) & gpt_reg32(0x04) & 0x3f) != 0; if (l != lastl) { lastl = l; static int c2; if ((long long)(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / 1000000) > 2500 && c2++ < 400) info_report("GPT irq level=%d t=%lld ms", l, (long long)(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / 1000000)); } }
    if (g_gpt_irq) qemu_set_irq(g_gpt_irq, (gpt_reg32(0x00) & gpt_reg32(0x04) & 0x3f) != 0);
}
/* TCG runs LK orders of magnitude slower than the SoC, so a real-rate 10 ms scheduler tick lands before LK has initialised its timer
 * queue (observed: timer_tick walks an uninitialised list -> data abort at 0xeafffffe, the vector page). REHOST_TICK_SLOW (default 1)
 * stretches the wall-clock period of the 32 kHz-sourced timers only. */
static double gpt_hz(int n) {
    static double slow;
    if (slow == 0) { const char *e = getenv("REHOST_TICK_SLOW"); slow = e ? strtod(e, NULL) : 1; if (slow < 1) slow = 1; }
    return ((gpt_reg32(0x10 * n + 4) & 0x10) ? 32768.0 / slow : 13000000.0);
}
static void gpt_arm(int n) {
    uint32_t con = gpt_reg32(0x10 * n);
    if (!(con & 1) || !g_gpt_timer[n]) return;
    int64_t ticks = gpt_reg32(0x10 * n + 0xc);
    int64_t ns = (int64_t)((double)ticks * 1e9 / gpt_hz(n));
    timer_mod_ns(g_gpt_timer[n], g_gpt_start[n] + (ns > 1000 ? ns : 1000));
}
static void gpt_fire(void *opaque) {
    int n = (int)(intptr_t)opaque;
    if (getenv("REHOST_GPT_TRACE")) { static int c; if ((long long)(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / 1000000) > 2500 && c++ < 400) info_report("GPT%d fire #%d t=%lld ms CON=0x%x STA=0x%x", n, c, (long long)(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / 1000000), gpt_reg32(0x10 * n), gpt_reg32(4)); }
    uint32_t sta = gpt_reg32(0x04) | (1u << (n - 1));
    memcpy(gpt_regs + 0x04, &sta, 4);
    uint32_t con = gpt_reg32(0x10 * n);
    if (((con >> 4) & 3) == 1) {                    /* repeat */
        g_gpt_start[n] = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
        gpt_arm(n);
    } else {                                        /* one-shot: stops */
        con &= ~1u; memcpy(gpt_regs + 0x10 * n, &con, 4);
    }
    gpt_update_irq();
}
static uint64_t gpt_read(void *o, hwaddr a, unsigned sz) {
    if (a == 0x48) {
        /* REHOST_TIME_SCALE (default 1) speeds the udelay clock so the firmware's 100000 x 1 ms poll timeouts
         * do not take minutes of wall time; it never changes what the firmware reads, only how fast it elapses */
        if (!g_gpt_scale) { const char *e = getenv("REHOST_TIME_SCALE"); g_gpt_scale = e ? strtoull(e, NULL, 0) : 1; if (!g_gpt_scale) g_gpt_scale = 1; }
        return (uint32_t)((uint64_t)qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) * 13ULL * g_gpt_scale / 1000ULL);
    }
    for (int n = 1; n <= 5; n++) {
        if (n != 4 && a == (hwaddr)(0x10 * n + 8) && (gpt_reg32(0x10 * n) & 1)) {
            return (uint32_t)((double)(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) - g_gpt_start[n]) * gpt_hz(n) / 1e9);
        }
    }
    uint64_t v = 0;
    if (a + sz <= sizeof(gpt_regs)) memcpy(&v, gpt_regs + a, sz);
    return v;
}
static void gpt_write(void *o, hwaddr a, uint64_t v, unsigned sz) {
    if (getenv("REHOST_GPT_TRACE") && (a == 0x08 || a == 0x00 || a == 0x50 || a == 0x5c)) { static int c; if ((long long)(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / 1000000) > 2500 && c++ < 400) info_report("GPT W +0x%x = 0x%x sz=%u t=%lld ms", (unsigned)a, (unsigned)v, sz, (long long)(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / 1000000)); }
    if (a == 0x08 && sz == 4) {                     /* IRQACK: write-1-to-clear IRQSTA */
        uint32_t sta = gpt_reg32(0x04) & ~(uint32_t)v;
        memcpy(gpt_regs + 0x04, &sta, 4);
        gpt_update_irq();
        return;
    }
    if (a + sz <= sizeof(gpt_regs)) memcpy(gpt_regs + a, &v, sz);
    if (a == 0x00) gpt_update_irq();
    for (int n = 1; n <= 5; n++) {
        if (a == (hwaddr)(0x10 * n) && sz == 4) {
            if (!(v & 1)) { if (g_gpt_timer[n]) timer_del(g_gpt_timer[n]); }
            else { g_gpt_start[n] = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL); gpt_arm(n); }
        }
    }
}
static const MemoryRegionOps gpt_ops = {
    .read = gpt_read, .write = gpt_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
};


/* v2 (bypasses.md #33): MediaTek PMIF SPMI master software-interface FSM
 * (DTB spmi@10027000 "mt6833-pmif-m", ap_swinf_no=2). Derived from the firmware
 * own access sequence at 0x234170: write request to ACC, poll STA bits[3:1]==6
 * (WFVLDCLR), read RDATA, write 1 to VLD_CLR; idle check expects STA==0.
 * Register layout per channel c (stride 0x40): ACC 0x800, WDATA 0x804,
 * RDATA 0x814, VLD_CLR 0x824, STA 0x828 - the poll address seen at runtime
 * 0x100278a8 = 0x828 + 2*0x40 confirms this stride/base. PMIC register reads
 * return 0 (no PMIC modelled). */
static uint8_t pmif_regs[0x900];
static uint8_t pmif_sta[8];
/* Minimal PMIC register file behind the SPMI master (one 64KB space per slave id 0-15).
 * Defaults are DERIVED from firmware expectations, not guessed:
 *  - slave 3 reg 0x0009: FUN_002367c8 (SPMI sampling-phase calibration) reads it and
 *    requires (slave_table.expect ^ value) & 0xf0 == 0 with expect byte 0x15 read from the
 *    slave table at 0x2549ac (+0x16) -> value 0x15.
 *  - reg 0x000b == 0x15 for the same slave class: FUN_0022d5ac requires local_1b[0]==0x15.
 * Everything else is plain read/write storage (reset value 0). */
static uint8_t pmic_regs[16][0x10000];
static int pmic_logn;
static uint64_t pmif_read(void *o, hwaddr a, unsigned sz) {
    if (a >= 0x828 && ((a - 0x828) % 0x40) == 0 && (a - 0x828) / 0x40 < 4) {
        return (uint64_t)pmif_sta[(a - 0x828) / 0x40] << 1;
    }
    uint64_t v = 0;
    if (a + sz <= sizeof(pmif_regs)) memcpy(&v, pmif_regs + a, sz);
    return v;
}
static void pmif_write(void *o, hwaddr a, uint64_t v, unsigned sz) {
    if (a + sz <= sizeof(pmif_regs)) memcpy(pmif_regs + a, &v, sz);
    if (a >= 0x800 && a < 0x900) {
        unsigned ch = (a - 0x800) / 0x40, off = (a - 0x800) % 0x40;
        if (ch < 4 && off == 0x00) {
            uint32_t acc = (uint32_t)v;
            unsigned slv = (acc >> 24) & 0xf, reg = acc & 0xffff, len = ((acc >> 16) & 0xff) + 1;
            uint32_t wd; memcpy(&wd, pmif_regs + 0x800 + ch * 0x40 + 4, 4);
            uint32_t rd = 0;
            if (acc & 0x20000000) {            /* write: completes immediately, stays idle */
                for (unsigned i = 0; i < len && i < 4; i++) pmic_regs[slv][(reg + i) & 0xffff] = (wd >> (8 * i)) & 0xff;
                pmif_sta[ch] = 0;
            } else {                            /* read: response valid until VLD_CLR */
                for (unsigned i = 0; i < len && i < 4; i++) rd |= (uint32_t)pmic_regs[slv][(reg + i) & 0xffff] << (8 * i);
                memcpy(pmif_regs + 0x800 + ch * 0x40 + 0x14, &rd, 4);
                pmif_sta[ch] = 6;
                if (pmic_logn < 30 || (reg == 0x2a && pmic_logn < 400)) { pmic_logn++; info_report("PMIC rd slv%u reg 0x%x -> 0x%x", slv, reg, rd); }
            }
        }
        if (ch < 4 && off == 0x24 && (v & 1)) pmif_sta[ch] = 0;   /* VLD_CLR -> idle */
    }
}
static const MemoryRegionOps pmif_ops = {
    .read = pmif_read, .write = pmif_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
};


/* v2 (bypasses.md #34): MediaTek PWRAP (DTB pwrap@10026000) WACS2 channel, the
 * main-PMIC 16-bit register bus. Layout read from the firmware own polling code
 * at 0x23375a: CMD 0x880, RDATA 0x894, VLDCLR 0x8a4, STA 0x8a8 (bits[3:1]: 0 idle,
 * 6 = wait-valid-clear). CMD = register address, bit29 = write, data in WDATA 0x884.
 * PMIC registers are plain 16-bit storage (reset 0). */
static uint8_t pwrap_regs[0x1000];
static uint16_t pmic_main[0x8000];
static uint8_t pwrap_sta;
static int pwrap_logn;
static uint64_t pwrap_read(void *o, hwaddr a, unsigned sz) {
    if (a == 0x8a8) return ((uint64_t)pwrap_sta << 1) | 0x8000;   /* bit15 WACS2 init-done: checked by FUN_00233684 (returns 7 otherwise) */
    uint64_t v = 0;
    if (a + sz <= sizeof(pwrap_regs)) memcpy(&v, pwrap_regs + a, sz);
    return v;
}
static void pwrap_write(void *o, hwaddr a, uint64_t v, unsigned sz) {
    if (a + sz <= sizeof(pwrap_regs)) memcpy(pwrap_regs + a, &v, sz);
    if (a == 0x880) {
        /* firmware helpers (0x23375a read, 0x2337a0 write): CMD = register address
         * (<=16 bit), write adds bit29 and puts data in WDATA (0x884). */
        uint32_t cmd = (uint32_t)v;
        unsigned adr = cmd & 0x7fff;
        if (cmd & 0x20000000u) {
            uint32_t wd; memcpy(&wd, pwrap_regs + 0x884, 4);
            pmic_main[adr] = wd & 0xffff;
            pwrap_sta = 0;
        } else {
            uint32_t rd = pmic_main[adr];
            if (adr == 0x3a2) {
                /* v2 (bypasses.md #37): PMIC OTP read port. FUN_00232d68 selects the word
                 * with reg 0x38a (= index << 1), pulses 0x39a, polls 0x3a4 busy, then reads
                 * 0x3a2. Word 3 must have bits[15:13] == 5 (assert pmic_initial_setting.c:641,
                 * 0x233310); every other word stays 0 until the firmware asserts otherwise. */
                unsigned idx = (pmic_main[0x38a] & 0xff) >> 1;
                rd = (idx == 3) ? (5u << 13) : 0;
            }
            if (adr == 0x546) {
                /* bypasses.md #40: busy flag, bit3 polled until clear at 0x2350d8 (1000 x 1 ms
                 * timeout, FUN_00234ff4); the request completes instantly in the model */
                rd &= ~0x8u;
            }
            memcpy(pwrap_regs + 0x894, &rd, 4);
            pwrap_sta = 6;
            if (pwrap_logn < 30 || (adr == 0x2a && pwrap_logn < 400)) { pwrap_logn++; info_report("PWRAP rd 0x%x -> 0x%x", adr, rd); }
        }
    }
    if (a == 0x8a4 && (v & 1)) pwrap_sta = 0;
}
static const MemoryRegionOps pwrap_ops = {
    .read = pwrap_read, .write = pwrap_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
};


/* v2 (bypasses.md #36): ARM CryptoCell DXCC (DTB dxcc_sec@10210000). Only the
 * queue/completion handshake seen in FUN_00242304 is modelled; no crypto is
 * computed (outputs stay as the firmware left them) - the secure-boot engine is
 * stubbed per project policy (encrypted/verified regions are skipped).
 *  +0xe80..0xe94 descriptor words (write of the last word, +0xe94, = queue push)
 *  +0xe9c  queue content: reads 8 (space available, bit3 polled at 0x241e76)
 *  +0xa00  IRR: bit2 set after a push (polled at 0x2423b8); +0xa08 ICR clears bits
 *  +0xba0  completion counter polled for non-zero: 1 after a push */
static uint8_t dxcc_regs[0x1000];
static uint32_t dxcc_irr, dxcc_comp;
static uint64_t dxcc_read(void *o, hwaddr a, unsigned sz) {
    /* bypasses.md #55: CryptoCell life-cycle query FUN_00240f6c: +0xabc bit0 = NVM idle/ready, +0xad4 low byte = LCS.
     * 5 = Secure (a retail unit); bit8 (error) stays clear; OTP word 10 low nibble must be 3 (see 0x240fa6) */
    /* bypasses.md #72: TEEGRIS (BL32, S-EL1) maps this block and reads a free-running 64-bit counter at +0xa78 (lo) / +0xa7c (hi)
     * (loop 0x76a4af10: it reads both halves, folds lo^hi and waits until a target is reached - a udelay). Frequency unknown;
     * modelled as the same 13 MHz virtual-clock counter as the GPT. */
    if (a == 0xa78 || a == 0xa7c) {
        uint64_t t = (uint64_t)qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) * 13ULL / 1000ULL;
        return a == 0xa78 ? (uint32_t)t : (uint32_t)(t >> 32);
    }
    if (a == 0xab4) return 1;                     /* OTP read done (FUN_002412fc polls bit0) */
    if (a == 0xaac) {                             /* OTP data for the word index latched in +0xaa4 ((idx << 2) | 0x10000) */
        uint32_t cmd; memcpy(&cmd, dxcc_regs + 0xaa4, 4);
        return (((cmd & 0xffff) >> 2) == 10) ? 0x00030000u : 0;   /* word 10: bits[19:16] == 3 required (0x240fa6) */
    }
    if (a == 0xabc) return 1;
    if (a == 0xad4) return 5;
    if (a == 0xe9c) return 8;
    if (a == 0xa00) return dxcc_irr;
    if (a == 0xba0) return dxcc_comp;
    uint64_t v = 0;
    if (a + sz <= sizeof(dxcc_regs)) memcpy(&v, dxcc_regs + a, sz);
    return v;
}
static void dxcc_write(void *o, hwaddr a, uint64_t v, unsigned sz) {
    if (a + sz <= sizeof(dxcc_regs)) memcpy(dxcc_regs + a, &v, sz);
    if (a == 0xe94) { dxcc_irr |= 4; dxcc_comp = 1; }
    if (a == 0xa08) dxcc_irr &= ~(uint32_t)v;
}
static const MemoryRegionOps dxcc_ops = {
    .read = dxcc_read, .write = dxcc_write,
    .endianness = DEVICE_NATIVE_ENDIAN,
    .valid = { .min_access_size = 1, .max_access_size = 8 },
};

/* ---- AArch32 preloader -> AArch64 ATF handoff (bypasses.md #65) ----
 * FUN_00227a10 ("[BLDR] jump to 0x%x") stores the BL31 entry (value at 0x255050, here 0x48c03000) into the RVBAR register
 * whose address is held at 0x255054 (0x0c53c900, MCUCFG), sets RMR bits AA64|RR (CP15 c12,c0,2 |= 1, |= 2) and spins on
 * WFI at 0x22626c/0x226270. On the SoC that is a warm reset into AArch64 at RVBAR. QEMU cannot switch one CPU between an
 * AArch32-only and an AArch64 feature set, so a second, AArch64-capable cortex-a55 sits powered off; when cpu0 parks in
 * that spin loop it is halted for good and cpu1 is reset with rvbar = the stored value and started. */
static ARMCPU *g_cpu64;
/* QEMU's minimal RAS leaves the error-record registers UNDEFINED (it reports ERRIDR_EL1 = 0). BL31 for this cortex-a55 still
 * touches them unconditionally (0x48c26770 ERRSELR_EL1 / ERXCTLR_EL1), as the real core has two records. RAZ/WI stand-ins. */
#define RAS_REG(nm, cm, o2) { .name = nm, .state = ARM_CP_STATE_AA64, .opc0 = 3, .opc1 = 0, .crn = 5, .crm = cm, .opc2 = o2,     .access = PL1_RW, .type = ARM_CP_CONST, .resetvalue = 0 }
/* Implementation-defined cortex-a55 registers (crn=15) used by BL31's MediaTek cluster bring-up. They have no architectural
 * meaning in QEMU; modelled as plain RW storage per (opc1, crm, opc2). The one status/ack pair found so far:
 * s3_0_c15_c3_5 is written with |0xf0 and s3_0_c15_c3_7 bits[7:4] are polled until they read 0xf (0x48c10d44..0x48c10d60),
 * so c3_7 reads back what c3_5 holds. */
static uint64_t a55_impdef[2][16][8];
static uint64_t a55_impdef_read(CPUARMState *env, const ARMCPRegInfo *ri) {
    unsigned h = ri->opc1 == 6;
    if (!h && ri->crm == 3 && ri->opc2 == 7) return a55_impdef[0][3][5];
    return a55_impdef[h][ri->crm][ri->opc2];
}
static void a55_impdef_write(CPUARMState *env, const ARMCPRegInfo *ri, uint64_t v) {
    a55_impdef[ri->opc1 == 6][ri->crm][ri->opc2] = v;
}
static ARMCPRegInfo a55_impdef_regs[2 * 16 * 8];
static void define_a55_impdef(ARMCPU *cpu) {
    int n = 0;
    for (int h = 0; h < 2; h++) for (int cm = 0; cm < 16; cm++) for (int o2 = 0; o2 < 8; o2++) {
        ARMCPRegInfo *r = &a55_impdef_regs[n++];
        r->name = "A55_IMPDEF"; r->state = ARM_CP_STATE_AA64; r->opc0 = 3; r->opc1 = h ? 6 : 0; r->crn = 15; r->crm = cm; r->opc2 = o2;
        r->access = h ? PL3_RW : PL1_RW; r->type = ARM_CP_NO_RAW; r->readfn = a55_impdef_read; r->writefn = a55_impdef_write;
    }
    define_arm_cp_regs(cpu, a55_impdef_regs);
}

static const ARMCPRegInfo mt6833_mpidr[] = {
    { .name = "MPIDR_EL1", .state = ARM_CP_STATE_AA64, .opc0 = 3, .opc1 = 0, .crn = 0, .crm = 0, .opc2 = 5,
      .access = PL1_R, .type = ARM_CP_CONST | ARM_CP_OVERRIDE, .resetvalue = 0x81000000 },
};
static const ARMCPRegInfo ras_error_records[] = {
    RAS_REG("ERRSELR_EL1", 3, 1),
    RAS_REG("ERXFR_EL1", 4, 0), RAS_REG("ERXCTLR_EL1", 4, 1), RAS_REG("ERXSTATUS_EL1", 4, 2), RAS_REG("ERXADDR_EL1", 4, 3),
    RAS_REG("ERXMISC0_EL1", 5, 0), RAS_REG("ERXMISC1_EL1", 5, 1),
};
static QEMUTimer *g_handoff_timer;
/* ---- LK runtime code patches (bypasses.md #88) ----
 * LK is compressed in its image and runs after relocation, so it cannot be patched in the file. A virtual-time poll applies each patch the
 * first time the expected original bytes are seen at its (physical == virtual) address. Entries only apply when REHOST_LK_PATCHES is set. */
static const struct { uint32_t addr; uint8_t from[2], to[2]; const char *why; } lk_patches[] = {
    /* LK's oem image verification (FUN_482c794c, "[SBC][oem] img auth ...") compares a 32-byte digest with the one carried by the image and returns
     * 0x7021 on mismatch; the dtb overlay then stays uninitialised, FUN_482868ec sets sec_check_download=7 (AST_DLOAD) and LK enters Odin. The digest
     * is Samsung-signed material that cannot be reproduced here, so the compare result is stubbed: "cbz r0,pass" -> "b pass" (bypasses.md #89). */
    {0x482c798aU, {0x68, 0xb1}, {0x0d, 0xe0}, "oem img digest compare -> always pass"},
    /* The digests those checks compare come from LK's SHA service: SMC 0x8200010b..0x8200010f into BL31, which drives the CryptoCell (DXCC). The DXCC model only
     * does the queue handshake, so every digest is wrong ("avb_vbmeta_image.c:207 Hash does not match!", boot state red -> download mode). libavb funnels all digest and
     * signature-padding comparisons through avb_safe_memcmp (FUN_482b9510); it is made to report "equal": "cbz r2,..." -> "movs r0,#0", "push {r4,r5}" -> "bx lr" (bypasses.md #90). */
    {0x482b9510U, {0x8a, 0xb1}, {0x00, 0x20}, "avb_safe_memcmp: movs r0,#0"},
    {0x482b9512U, {0x30, 0xb4}, {0x70, 0x47}, "avb_safe_memcmp: bx lr"},
    /* The AVB chain descriptors name the partitions "prism" and "optics", which belong to the CSC package (not in the firmware set); with zero-filled partitions the Samsung
     * signer check marks them CUSTOM, avb_slot_verify ends in an error and the boot state becomes red (value 3 in the state table of FUN_48285f94). FUN_48286190 then calls
     * red_state_warning (FUN_482860a8, which enters download mode). The branch "state==3 -> warning" is NOPed so the boot continues with the red state recorded
     * (bypasses.md #91). */
    {0x482861a0U, {0x03, 0xd0}, {0x00, 0xbf}, "red boot state: skip red_state_warning"},
    /* bypasses.md #121: the prism/optics partitions (CSC package, not in the firmware set) cannot be authenticated, so Android's first-stage init (libfs_avb, real memcmp, real RSA)
     * ends in "avb_vbmeta_image.c:207 Hash does not match! / prism: HASH_MISMATCH -> ERROR_VERIFICATION / PUBLIC_KEY_REJECTED isn't allowed" because LK reports the device LOCKED
     * (androidboot.vbmeta.device_state=locked, seccfg is zero-filled -> lock_state 2). With an unlocked device init tolerates verification errors, exactly what a real unlocked
     * handset does. FUN_482b422c (AVB ops get_device_unlocked) computes unlocked = !(lock_state in {1,2,4}) from the seccfg value read into [sp+4]; "ldr r2,[sp,#4]" is
     * replaced by "movs r2,#3" (LKS_UNLOCK) so the device is reported unlocked. The seccfg itself is not rewritten (its hash is bound to hardware keys). */
    {0x482b424cU, {0x01, 0x9a}, {0x03, 0x22}, "AVB get_device_unlocked: lock_state := 3 (unlocked)"},
    /* bypasses.md #122: Android's fs_mgr tolerates AVB verification errors only when androidboot.verifiedbootstate == "orange" (IsDeviceUnlocked() looks at that property, not at
     * vbmeta.device_state). LK keeps the state RED (3) because prism/optics fail the Samsung signer check. FUN_48286208 maps the boot state to the cmdline string with a TBB
     * table at 0x4828621a (state 0 green, 1 yellow, 2 orange, 3 red -> branch offsets 14 02 0e 08); the entry for state 3 is pointed at the orange case (08 -> 0e), so the kernel
     * command line says verifiedbootstate=orange, consistent with the device_state=unlocked of #121. LK's own state stays red (its red warning is skipped by #91). */
    {0x4828621cU, {0x0e, 0x08}, {0x0e, 0x0e}, "cmdline verifiedbootstate: red -> orange"},
    /* bypasses.md #123 (kernel text; VA 0xffffff8008c88990 = PA 0x40c88990): the kernel's software watchdog (softdog, soft_panic=1) was armed by Android userspace with a 600 s margin
     * and nothing pets it in this model (the vendor watchdog daemon/services never get that far: tz_service restarts forever, no TEEGRIS), so "softdog: Initiating panic" /
     * "Kernel panic - not syncing: Software Watchdog Timer expired 600s" resets the machine ~13 min after init starts. In softdog_fire the first instruction of the expiry path
     * ("adrp x0,<msg>") becomes "b .-12" to the function's normal return ("mov w0,wzr; ldp x29,x30,[sp],#16; ret"): the watchdog fires harmlessly. */
    {0x40c88990U, {0xa0, 0x71}, {0xfd, 0xff}, "kernel softdog_fire: skip panic (1/2)"},
    {0x40c88992U, {0x00, 0x90}, {0xff, 0x17}, "kernel softdog_fire: skip panic (2/2)"},
    /* bypasses.md #125: /vendor/etc/init/teegris_v4.rc was edited in the eMMC image (patch_emmc.py: `wait_for_prop vendor.tz*daemon Ready` -> `setprop`), so its dm-verity hashtree no longer matches
     * the (signed) vbmeta descriptor. Setting the vbmeta HASHTREE_DISABLED flag is no option (LK's vbmeta authinfo check then waits for a key forever), so the hashtree error mode that LK
     * puts on the command line is switched from the "enforcing" string to the "logging" string that LK already contains (libavb: ignore_corruption). FUN_482b4f.. selects one of the
     * strings "eio" (0x48325350) / "logging" (0x48325368) / "enforcing" (0x48325330) per mode; the two PC-relative literals (at 0x482b50b0 and 0x482b50c0, read by the `ldr r3,[pc,#..];
     * add r3,pc` pairs at 0x482b4fe2 and 0x482b5004) that name "enforcing" are changed to name "logging": the low halfword 0x0348 -> 0x0380 and 0x0326 -> 0x035e (offset to
     * 0x48325368 from the add's PC). Only numbers are written; no text. */
    {0x482b50b0U, {0x48, 0x03}, {0x80, 0x03}, "veritymode: enforcing literal -> logging (1/2)"},
    {0x482b50c0U, {0x26, 0x03}, {0x5e, 0x03}, "veritymode: enforcing literal -> logging (2/2)"},
    /* bypasses.md #126 (kernel text; VA 0xffffff8008caed4c = PA 0x40caed4c): Samsung's dm-verity handler (called from verity_work when a data block fails its hash and FEC cannot repair it,
     * "device-mapper: verity: 253:3: data block 7261 is corrupted") prints the block and calls panic("dmv corrupt") whatever the veritymode. The edited vendor rc
     * (patch_emmc.py/patch_emmc3.py) is exactly such a block. The handler's first two instructions become "mov w0,wzr; ret": corruption is ignored (return 0 = proceed with the data read). */
    {0x40caed4cU, {0xff, 0x03}, {0xe0, 0x03}, "kernel verity corruption handler: mov w0,wzr (1/4)"},
    {0x40caed4eU, {0x03, 0xd1}, {0x1f, 0x2a}, "kernel verity corruption handler (2/4)"},
    {0x40caed50U, {0xfd, 0x7b}, {0xc0, 0x03}, "kernel verity corruption handler: ret (3/4)"},
    {0x40caed52U, {0x06, 0xa9}, {0x5f, 0xd6}, "kernel verity corruption handler (4/4)"},
    /* bypasses.md #129 (kernel text; VA 0xffffff80086baed4 = PA 0x406baed4): Android's mtkPowerAIDL HAL reads a debugfs attribute whose getter idletime_get dereferences a global MTK idle-driver
     * object (*(0xffffff800a5470c8)+0x340) that is never created here (SPM/MCUSYS idle states are not modelled): "NULL pointer dereference at 0x340, pc idletime_get+0x14" killed the kernel at
     * ~301 s, right after zygote and surfaceflinger were started. The getter becomes "str xzr,[x1]; mov w0,wzr; ret" (idle time 0, success). */
    {0x406baed4U, {0xfd, 0x7b}, {0x3f, 0x00}, "kernel idletime_get: return 0 (1/6)"},
    {0x406baed6U, {0xbe, 0xa9}, {0x00, 0xf9}, "kernel idletime_get (2/6)"},
    {0x406baed8U, {0xf3, 0x0b}, {0xe0, 0x03}, "kernel idletime_get (3/6)"},
    {0x406baedaU, {0x00, 0xf9}, {0x1f, 0x2a}, "kernel idletime_get (4/6)"},
    {0x406baedcU, {0xfd, 0x03}, {0xc0, 0x03}, "kernel idletime_get (5/6)"},
    {0x406baedeU, {0x00, 0x91}, {0x5f, 0xd6}, "kernel idletime_get (6/6)"},
    /* SPM firmware loader (FUN_48292820): the "spmfw" partition is not part of the firmware set (zero-filled here), so the SBC auth init for it (FUN_482c8474(1)) fails
     * with 0x6003 and the loader calls red_state_warning (download mode). "bne cert_vfy_fail" is NOPed; the following oem digest check is already stubbed (#89/#90).
     * The zero firmware is then handed to the SPM (SMC 0x8200022a), which only affects power management (bypasses.md #92). */
    {0x482928e8U, {0x3d, 0xd1}, {0x00, 0xbf}, "spmfw SBC auth init failure ignored"},
    /* ...and the earlier gate: FUN_482c76bc("spmfw") finds no SBC certificate container in the zero-filled partition and returns 0x6003 (image auth init fail);
     * "bne cert_vfy_fail" at 0x482928d2 is NOPed as well (bypasses.md #92). */
    {0x482928d2U, {0x59, 0xd1}, {0x00, 0xbf}, "spmfw SBC cert container missing ignored"},
    /* Modem loader (FUN_48289a1c): the zero-filled md1img partition has no sub-image header (magic 0x58881688), so the loader prints "load sub image md1rom fail" and calls
     * FUN_482537e4, the "SECURE CHECK" error screen, which shows secure_error.jpg and polls the keys forever (until key 8). The modem image is not part of the firmware set;
     * FUN_482537e4 is made to return at once ("push {r4,lr}" -> "bx lr") so the loader returns its error and LK continues without a modem (bypasses.md #93). */
    {0x482537e4U, {0x10, 0xb5}, {0x70, 0x47}, "secure check error screen: return instead of waiting for a key"},
    /* bypasses.md #100 (kernel text, physical = 0x40080000 + (VA - 0xffffff8008080000), no KASLR): the PMIC regmap of the 4.14 kernel is reached through an IPI to the SSPM
     * power coprocessor, whose firmware is not part of the firmware set. The IPI times out and sspm_ipi_timeout_cb (VA 0xffffff80087cef24) raises an AEE exception and
     * BUG()s ("kernel BUG at sspm_ipi_timeout_cb.c:61", PC 0xffffff80087cef64) -> panic -> PSCI reset. The callback is turned into "ret" so the IPI just fails. */
    {0x407cef24U, {0xfd, 0x7b}, {0xc0, 0x03}, "kernel sspm_ipi_timeout_cb: ret (1/2)"},
    {0x407cef26U, {0xbf, 0xa9}, {0x5f, 0xd6}, "kernel sspm_ipi_timeout_cb: ret (2/2)"},
    /* bypasses.md #105 (kernel text): mtk_ipi_send_compl (VA 0xffffff80085c6188) waits ~2 s for an SSPM/MCUPM acknowledgement that never comes (no coprocessor firmware), and every
     * PMIC register access of the kernel goes through it, so pid 1 crawls (one 2 s timeout per register). The first two instructions ("sub sp,sp,#0x90; stp x29,x30,[sp,#48]")
     * become "mov w0,wzr; ret": the IPI "succeeds" at once (revised after #108/#109: with "fail at once (-6)" the PMIC regulators never registered and
     * vendor drivers dereferenced ERR_PTR(-EPROBE_DEFER) regulators -> Oops in eem_probe and pbm/gpufreq; reads return whatever the message buffer holds). */
    {0x405c6188U, {0xff, 0x43}, {0xe0, 0x03}, "kernel mtk_ipi_send_compl: succeed at once (1/4)"},
    {0x405c618aU, {0x02, 0xd1}, {0x1f, 0x2a}, "kernel mtk_ipi_send_compl: succeed at once (2/4)"},
    {0x405c618cU, {0xfd, 0x7b}, {0xc0, 0x03}, "kernel mtk_ipi_send_compl: succeed at once (3/4)"},
    {0x405c618eU, {0x03, 0xa9}, {0x5f, 0xd6}, "kernel mtk_ipi_send_compl: succeed at once (4/4)"},
    /* bypasses.md #106 (kernel text): no LCM is attached (LK: islcmfound = 0, androidboot lcdtype=0), so the Samsung display glue ("smcdsd: lcdtype(0) is invalid")
     * leaves the panel list inconsistent and mtk_dsi_probe -> find_panel_ext (VA 0xffffff80086c28c0) dereferences a garbage list entry ("Unable to handle kernel paging
     * request at virtual address 636f732d646e63", Oops -> panic -> reset). The lookup is made to return NULL ("mov x0,xzr; ret"), i.e. "no panel". */
    {0x406c28c0U, {0xfd, 0x7b}, {0xe0, 0x03}, "kernel find_panel_ext: return NULL (1/4)"},
    {0x406c28c2U, {0xbe, 0xa9}, {0x1f, 0xaa}, "kernel find_panel_ext: return NULL (2/4)"},
    {0x406c28c4U, {0xf4, 0x4f}, {0xc0, 0x03}, "kernel find_panel_ext: return NULL (3/4)"},
    {0x406c28c6U, {0x01, 0xa9}, {0x5f, 0xd6}, "kernel find_panel_ext: return NULL (4/4)"},
    /* bypasses.md #107 (kernel text): without a panel mtk_dsi_probe (VA 0xffffff80086a133c) -> mipi_dsi_host_register keeps re-probing the Samsung panel driver, which
     * re-registers its lcd drivers every 10 ms ("lcd_driver_init: ... already registered") and corrupts the panel list (WARN list_add corruption); the spam also fills
     * the 256 KiB pstore console ring within a few hundred ms. The DSI host probe fails at once with -ENODEV ("movn w0,#18; ret"): no display. */
    {0x406a133cU, {0xff, 0xc3}, {0x40, 0x02}, "kernel mtk_dsi_probe: -ENODEV (1/4)"},
    {0x406a133eU, {0x04, 0xd1}, {0x80, 0x12}, "kernel mtk_dsi_probe: -ENODEV (2/4)"},
    {0x406a1340U, {0xfd, 0x7b}, {0xc0, 0x03}, "kernel mtk_dsi_probe: -ENODEV (3/4)"},
    {0x406a1342U, {0x0e, 0xa9}, {0x5f, 0xd6}, "kernel mtk_dsi_probe: -ENODEV (4/4)"},
    /* bypasses.md #108 (kernel text): eem_probe (EEM, CPU voltage tuning; VA 0xffffff8008737a40) calls regulator_set_mode() on a regulator pointer that is an error
     * value because the PMIC regulators are not usable (the PMIC regmap goes through the absent SSPM): "Unable to handle kernel paging request at virtual address
     * fffffffffffffe4b" in regulator_set_mode <- eem_probe+0xc80, Oops in pid 1 -> panic. The probe fails at once with -ENODEV ("movn w0,#18; ret"). */
    {0x40737a40U, {0xff, 0x43}, {0x40, 0x02}, "kernel eem_probe: -ENODEV (1/4)"},
    {0x40737a42U, {0x02, 0xd1}, {0x80, 0x12}, "kernel eem_probe: -ENODEV (2/4)"},
    {0x40737a44U, {0xfd, 0x7b}, {0xc0, 0x03}, "kernel eem_probe: -ENODEV (3/4)"},
    {0x40737a46U, {0x03, 0xa9}, {0x5f, 0xd6}, "kernel eem_probe: -ENODEV (4/4)"},
    /* bypasses.md #114 (kernel text): cfq_completed_request (VA 0xffffff8008505540, CFQ elevator completion hook, void) dereferences a NULL cfq queue for the request that completes
     * after init reads the (empty) metadata partition ("Unable to handle kernel NULL pointer dereference at virtual address 000000b8", x19 = 0) -> Oops in mmcqd/0. The hook
     * only does I/O scheduler accounting; the first instruction becomes "ret". */
    {0x40505540U, {0xff, 0xc3}, {0xc0, 0x03}, "kernel cfq_completed_request: ret (1/2)"},
    {0x40505542U, {0x01, 0xd1}, {0x5f, 0xd6}, "kernel cfq_completed_request: ret (2/2)"},
    /* bypasses.md #117 (kernel text): once the completion hook is a no-op the matching cfq_put_request (VA 0xffffff8008506064) trips BUG_ON(!cfqq->allocated[rw]) ("kernel BUG at
     * block/cfq-iosched.c:4465!", mmcqd/0, when init reads the metadata/super partitions): the CFQ accounting of requests that bypassed cfq_set_request is inconsistent.
     * It is also made a no-op ("ret"); a request's elevator private data is only bookkeeping. */
    {0x40506064U, {0xfd, 0x7b}, {0xc0, 0x03}, "kernel cfq_put_request: ret (1/2)"},
    {0x40506066U, {0xbd, 0xa9}, {0x5f, 0xd6}, "kernel cfq_put_request: ret (2/2)"},
    /* bypasses.md #118 (kernel text): the CFQ elevator is unusable here ("Unable to handle kernel NULL pointer dereference at virtual address 000000a0" in cfq_set_request+0x208,
     * init reading the super partition; before that cfq_completed_request / cfq_put_request faulted: its per-queue state is inconsistent). get_request() treats a failing
     * elevator_set_req_fn as "no elevator private data" (RQF_ELVPRIV cleared) and goes on, so cfq_set_request (VA 0xffffff8008505d50) returns -ENOMEM at once
     * ("movn w0,#11; ret"); #114/#117 are then redundant but harmless. */
    {0x40505d50U, {0xff, 0x03}, {0x60, 0x01}, "kernel cfq_set_request: -ENOMEM (1/4)"},
    {0x40505d52U, {0x02, 0xd1}, {0x80, 0x12}, "kernel cfq_set_request: -ENOMEM (2/4)"},
    {0x40505d54U, {0xfd, 0x7b}, {0xc0, 0x03}, "kernel cfq_set_request: -ENOMEM (3/4)"},
    {0x40505d56U, {0x02, 0xa9}, {0x5f, 0xd6}, "kernel cfq_set_request: -ENOMEM (4/4)"},
    /* bypasses.md #109 (kernel text): psci_cpu_boot (VA 0xffffff80080903b8) gets PSCI_E_INVALID_PARAMS from BL31 for CPU_ON (only 2 CPUs exist in the machine, the DT lists 8),
     * and the PPM hotplug thread ("cpuhp-ppm") retries in a tight loop, printing "psci: failed to boot CPUn (-22)" thousands of times per second: the 256 KiB pstore ring
     * keeps only ~1 s and the single TCG thread is hogged. "mov w20,w0" -> "mov w20,wzr": the call reports success (no message); the core never comes online and the kernel
     * gives up after its own timeout. */
    {0x400903f6U, {0x00, 0x2a}, {0x1f, 0x2a}, "kernel psci_cpu_boot: report success"},
    /* bypasses.md #104 (kernel text): tscpu_thermal_probe -> read_all_tc_temperature (VA 0xffffff8008a354f8) re-reads the thermal controllers 20 times and then BUG()s
     * ("kernel BUG at mtk_ts_cpu_noBank.c:1625") when a temperature stays outside (-30000, 129000] mC; the LVTS thermal sensors are not modelled (raw count 0). The two
     * branches that lead to the BUG (VA 0x...a35644 "b 0x...a35654" and the fall-through at 0x...a35654) are redirected to the function epilogue (0x...a3566c). */
    {0x40a35644U, {0x04, 0x00}, {0x0a, 0x00}, "kernel read_all_tc_temperature: skip BUG (1/3)"},
    {0x40a35654U, {0x20, 0x7f}, {0x06, 0x00}, "kernel read_all_tc_temperature: skip BUG (2/3)"},
    {0x40a35656U, {0x00, 0xb0}, {0x00, 0x14}, "kernel read_all_tc_temperature: skip BUG (3/3)"},
};
static bool lk_patch_done[sizeof(lk_patches) / sizeof(lk_patches[0])];
static QEMUTimer *g_lkp_timer;
static void lkp_tick(void *opaque) {
    for (size_t i = 0; i < sizeof(lk_patches) / sizeof(lk_patches[0]); i++) {
        if (lk_patch_done[i]) continue;
        uint8_t cur[2];
        address_space_read(&address_space_memory, lk_patches[i].addr, MEMTXATTRS_UNSPECIFIED, cur, 2);
        if (cur[0] == lk_patches[i].from[0] && cur[1] == lk_patches[i].from[1]) {
            address_space_write(&address_space_memory, lk_patches[i].addr, MEMTXATTRS_UNSPECIFIED, lk_patches[i].to, 2);
            lk_patch_done[i] = true;
            info_report("rehost-preloader: LK runtime patch @0x%x (%s)", lk_patches[i].addr, lk_patches[i].why);
        }
    }
    timer_mod(g_lkp_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 2);
}
static QEMUTimer *g_hb_timer;
static void hb_tick(void *opaque) {
    info_report("heartbeat virt=%lld ms real=%lld ms", (long long)(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / 1000000), (long long)(qemu_clock_get_ns(QEMU_CLOCK_REALTIME) / 1000000));
    timer_mod(g_hb_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 1000);
}
static void handoff_tick(void *opaque) {
    ARMCPU *c0 = g_pl_state->cpu;
    uint32_t pc = c0->env.regs[15];
    if (pc >= 0x226268 && pc <= 0x226274) {
        uint32_t lo = 0, hi = 0;
        address_space_read(&address_space_memory, 0x0c53c900ULL, MEMTXATTRS_UNSPECIFIED, &lo, 4);
        address_space_read(&address_space_memory, 0x0c53c904ULL, MEMTXATTRS_UNSPECIFIED, &hi, 4);
        uint64_t rvbar = ((uint64_t)hi << 32) | lo;
        info_report("rehost-preloader: warm reset to AArch64 requested (cpu0 pc=0x%x), RVBAR=0x%" PRIx64, pc, rvbar);
        CPU(c0)->halted = 1;
        g_gpt_scale = 1;
        g_post_handoff = true;
        /* bypasses.md #99: the kernel's mt6358 driver (compatible "mt6359-pmic" under pwrap@10026000) reads PMIC register 0x8 (HWCID) and accepts only 0x57xx / 0x58xx /
         * 0x59xx / 0x66xx / 0x90xx (switch in mt6358_probe); an unsupported id takes an error path that dereferences NULL (irq_domain_remove) -> Oops -> PSCI reset.
         * 0x59xx = MT6359 (only the family byte is known; the revision byte is left 0). Set after the hand-off so the preloader's PMIC code sees the old value. */
        pmic_main[0x8] = 0x5900;
        object_property_set_uint(OBJECT(g_cpu64), "rvbar", rvbar, &error_abort);
        cpu_reset(CPU(g_cpu64));
        /* The register file survives a warm reset on the real core: AArch32 R0..R14 are X0..X14 of the new AArch64 state.
         * BL31's entry does "mov x20,x0 ... bl bl31_early_platform_setup" and dereferences x0 (bypasses.md #67). */
        for (int i = 0; i < 15; i++) {
            g_cpu64->env.xregs[i] = c0->env.regs[i];
        }
        info_report("rehost-preloader: handoff regs r0=0x%x r1=0x%x r2=0x%x r3=0x%x", c0->env.regs[0], c0->env.regs[1], c0->env.regs[2], c0->env.regs[3]);
        g_cpu64->power_state = PSCI_ON;   /* bypasses.md #86: created with start-powered-off, QEMU's arm_cpu_has_work() is false while power_state == PSCI_OFF,
                                           * so the first WFI (LK's idle thread) never woke up again and the scheduler tick died (the 19th GPT5 IRQ was never taken) */
        CPU(g_cpu64)->halted = 0;
        qemu_cpu_kick(CPU(g_cpu64));
        return;
    }
    timer_mod(g_handoff_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 5);
}

/* ---- CPU reset ---- */
static void cpu_reset_hook(void *opaque) {
    ARMCPU *cpu = opaque;
    CPUState *cs = CPU(cpu);
    cpu_reset(cs);
    cpu_set_pc(cs, (vaddr)RESET_PC);
    /* No boot-tag/r4 handoff modelled yet for the BROM->preloader edge - this
     * is the FIRST round for this stage, same starting point LK's machine
     * had before bypasses.md #3 was derived. If preloader's own entry code
     * reads an incoming register before this machine supplies one, that
     * will surface as an early, specific stop point to investigate - not
     * guessed in advance. */
}

/* ---- Container placement ---- */
/* preloader.img carries the BRLYT+GFH header chain described in the file
 * header comment. The payload (header-stripped) was already isolated once
 * this round at file offset 0x200 for Ghidra analysis (preloader_payload.bin,
 * matches load_addr 0x200f10 exactly) - this mirrors that same, now-verified
 * split directly from the authoritative preloader.img, not from the
 * extracted copy. */
static void place_container(RehostPreloaderState *s, MachineState *ms) {
    if (!ms->kernel_filename) {
        error_report("no container given (-kernel <preloader.img>)"); exit(1);
    }
    FILE *f = fopen(ms->kernel_filename, "rb");
    if (!f) { error_report("cannot open '%s'", ms->kernel_filename); exit(1); }
    fseek(f, 0, SEEK_END); long total = ftell(f); fseek(f, 0, SEEK_SET);
    if (total <= 0) { error_report("empty container"); exit(1); }
    uint8_t *buf = g_malloc0(total);
    if (fread(buf, 1, total, f) != (size_t)total) { error_report("short read"); exit(1); }
    fclose(f);

    const uint64_t HEADER_SIZE = 0x200;
    if (total <= (long)HEADER_SIZE) {
        error_report("container smaller than header (%ld <= %" PRIu64 ")",
                     total, HEADER_SIZE);
        exit(1);
    }
    uint64_t payload_size = (uint64_t)total - HEADER_SIZE;
    if (LOAD_BASE + payload_size > SRAM_BASE + SRAM_SIZE) {
        error_report("payload does not fit in modelled SRAM (payload_size=%"
                     PRIu64 ")", payload_size);
        exit(1);
    }
    uint8_t *dst = memory_region_get_ram_ptr(ms->ram) + (LOAD_BASE - SRAM_BASE);
    memcpy(dst, buf + HEADER_SIZE, payload_size);
    /* bypasses.md #46: the eMMC identification (MID 0x15, CBX 01, OID 00, PNM) is not typed here: it is read from entry 3 of the preloader's own eMMC+LPDDR4X table at 0x252060 (3 bytes + 6 bytes) */
    if (0x252060 + 9 <= LOAD_BASE + payload_size) memcpy(emmc_cid, dst + (0x252060 - LOAD_BASE), 9);
    g_free(buf);
    /* Code bypasses (each documented in bypasses.md). Thumb "movs r0,#0; bx lr" at a function entry. */
    static const struct { uint32_t addr; const char *why; } ret0_patches[] = {
        /* #47: FUN_00213dcc(ctx, rank, 0): DRAMC RX/DQS window calibration sweep for the given rank, returns 0 = success.
         * Called once as (ctx, 1, 0) from FUN_0021ce10 to detect rank 1; no DRAM PHY is modelled so the sweep could never
         * succeed and ctx[2] (rank count) dropped to 1, making check_qvl (dramc_top.c:1626) fail. */
        {0x213dccU, "rank1 RX calibration"},
        /* #70: FUN_002249c0 = "GenieZone in use" (returns (word != 0x4e6f475a "ZGoN")). The gz1 partition in this model has to be the
         * ATF image (it is the only partition the ATF loader accepts), whose first sector is parsed as a GZ table, so the sentinel is
         * never set and the boot tag list carries GZ tags and the BL33 entry becomes the GZ hypervisor at 0x7ee00000 (GZ image: not
         * available). Forced to 0 = "no GZ": BL33 entry stays the LK at 0x48200000. */
        {0x2249c0U, "GZ in use -> no"},
    };
    /* #59: SSPM / MCUPM (power-management coprocessor) firmware is not part of the AP/BL packages of this build, so the
     * partitions cannot be provided. Each "not found" / "load fail" exit is redirected past its own block (the shared
     * failure exit 0x227e62 must stay intact: an earlier version of this patch redirected it and made the MCUPM failure
     * re-enter the SSPM continuation forever):
     *  SSPM  not found 0x227e3c  b 0x227e5e   -> b 0x22804c (code after a successful SSPM load)
     *  SSPM  load fail 0x227e54  cbz r0,0x227e64 -> b 0x22804c
     *  MCUPM not found 0x2281e0  b 0x227e5e   -> b 0x228360 (final stage: "load images" report, gz_post_init, ...)
     *  MCUPM load fail 0x2281fa  cbz r0,0x22820a -> b 0x228360 */
    static const struct { uint32_t addr; uint16_t from, to; const char *why; } hw_patches[] = {
        /* #80: the preloader switches its UART log (and the log flag LK inherits) off unless the RST/home key is held (FUN_002263a4(17),
         * 0x230da2..0x230da8). Holding that key (REHOST_LOG_KEY) also makes LK select Samsung download mode ("drawimg: ... Display download
         * Logo"), so the key stays released and the "log off" decision is skipped instead: cbnz r0,0x230dba -> b 0x230dc4. */
        {0x230da8U, 0xb938, 0xe00c, "keep UART log on without the key"},
        {0x227e3cU, 0xe00f, 0xe106, "SSPM not found -> continue"},
        {0x227e54U, 0xb130, 0xe0fa, "SSPM load fail -> continue"},
        {0x2281e0U, 0xe63d, 0xe0be, "MCUPM not found -> final stage"},
        {0x2281faU, 0xb130, 0xe0b1, "MCUPM load fail -> final stage"},
        /* #61: FUN_002304c0 (partition image loader) copies every image header sector (0x200 bytes) to
         * base + 0x766a4 + count * 0x200 and counts it; that buffer holds 20 entries and is followed directly by the
         * partition table (base + 0x78ea4). This model loads more images/sections than the buffer holds (the ATF image
         * alone is read in 11+ pieces), the copies overrun into the table and the later lookup of "lk" fails
         * (get_img_size 0x200000). The copy length 0x200 -> 0 (mov.w r2,#512 -> mov.w r2,#0 at 0x2305e2). */
        /* #62: security-library bump heap. FUN_00235ff4 (re-init, base FUN_00236484 = 0x10c020, size FUN_00236490 = 4096) is only
         * called by FUN_002304c0 on a SECURE chip; free (FUN_0023f17c) is an empty function. This model reports "[LIB] NS-CHIP"
         * (no SBC efuse), so the heap is never reset and every image-header check (thunk_FUN_00241378 mallocs 0x240, one per
         * ATF/TEE/LK piece) leaks until "[STDLIB] malloc: heap size not enough" -> "tee1 part. TEE verify fail".
         * Heap moved to 0x400000 (unused SRAM in this model) and enlarged to 128 KiB:
         *  0x23648c/e: literal 0xffed5b96 -> 0x001c9b76 (base = literal + 0x23648a = 0x400000)
         *  0x236492: mov.w r0,#0x1000 (5080) -> mov.w r0,#0x20000 (3000) */
        {0x23648cU, 0x5b96, 0x9b76, "sec heap base lo"},
        {0x23648eU, 0xffed, 0x001c, "sec heap base hi"},
        {0x236492U, 0x5080, 0x3000, "sec heap size 0x20000"},
        {0x2305e2U, 0xf44f, 0xf04f, "header-copy length (1/2)"},
        {0x2305e4U, 0x7200, 0x0200, "header-copy length (2/2)"},
    };
    for (size_t i = 0; i < sizeof(hw_patches)/sizeof(hw_patches[0]); i++) {
        uint16_t *hp = (uint16_t *)(dst + (hw_patches[i].addr - LOAD_BASE));
        if (*hp != hw_patches[i].from) { error_report("rehost-preloader: patch @0x%x expects 0x%04x, found 0x%04x", hw_patches[i].addr, hw_patches[i].from, *hp); exit(1); }
        *hp = hw_patches[i].to;
        info_report("rehost-preloader: code patch @0x%x (%s)", hw_patches[i].addr, hw_patches[i].why);
    }
    for (size_t i = 0; i < sizeof(ret0_patches)/sizeof(ret0_patches[0]); i++) {
        uint8_t *p = dst + (ret0_patches[i].addr - LOAD_BASE);
        p[0] = 0x00; p[1] = 0x20; p[2] = 0x70; p[3] = 0x47;
        info_report("rehost-preloader: code patch ret0 @0x%x (%s)", ret0_patches[i].addr, ret0_patches[i].why);
    }
    info_report("rehost-preloader: container placed at 0x%" PRIx64 " (%" PRIu64
                " bytes, header %" PRIu64 " bytes skipped)",
                LOAD_BASE, payload_size, HEADER_SIZE);
}

/* ---- Machine init ---- */
static void rehost_preloader_init(MachineState *ms) {
    RehostPreloaderState *s = REHOST_PRELOADER_MACHINE(ms);
    g_pl_state = s;
    MemoryRegion *sysmem = get_system_memory();

    ms->ram = g_new(MemoryRegion, 1);
    memory_region_init_ram(ms->ram, NULL, "rehost-preloader.sram", SRAM_SIZE,
                           &error_fatal);
    memory_region_add_subregion(sysmem, SRAM_BASE, ms->ram);

    /* bypasses.md #43: DRAM. The preloader finishes its DRAM bring-up (FUN_00231e90) and starts
     * touching 0x40000000 (DFAR at 0x2234d4). DTB /memory = <0x40000000 0x3e605000>; the model
     * maps a flat 4 GiB (0x40000000-0x13fffffff = 2 ranks x 2 GB, matching the modelled
     * MR8/EMI rank sizes) with no DRAMC/PHY timing behaviour. */
    MemoryRegion *dram = g_new(MemoryRegion, 1);
    memory_region_init_ram(dram, NULL, "rehost-preloader.dram", 0x100000000ULL, &error_fatal);
    memory_region_add_subregion(sysmem, 0x40000000ULL, dram);

    /* Minimal vector table at 0x0 - see VECTOR_BASE comment above. Each of
     * the 8 ARM32 exception slots gets "b ." (0xEAFFFFFE, branch to self) so
     * any exception taken before preloader sets its own VBAR parks cleanly
     * and observably instead of cascading into unmapped-vector chaos. */
    MemoryRegion *vectors = g_new(MemoryRegion, 1);
    memory_region_init_ram(vectors, NULL, "rehost-preloader.vectors",
                           VECTOR_SIZE, &error_fatal);
    memory_region_add_subregion(sysmem, VECTOR_BASE, vectors);
    uint32_t *vec = memory_region_get_ram_ptr(vectors);
    for (int i = 0; i < 8; i++) {
        vec[i] = 0xEAFFFFFEU;
    }
    /* Round 4 (bypasses.md #18, re-applying what round 2 reverted): slot 2
     * (SWI, offset 0x08) is taken from inside FUN_00234d64 (the printf/log
     * formatter - LR points straight back into its caller's next
     * instruction after "bl 0x234d64"), confirmed via QEMU monitor this is
     * where EVERY run now stably parks (ARM32_ATTEMPT.md 9-h) - it is a
     * required gate, not an optional experiment. MOVS PC,LR (standard ARM
     * "return from SWI", no LR adjustment needed) is architecturally
     * correct for an SWI regardless of what the specific call was for.
     * Round 2 saw 138,885 "Undefined Instruction" exceptions after this and
     * reverted out of caution; this round re-applies it and traces that
     * storm to its root cause the same way every other stop point in this
     * machine was solved, instead of treating the reversion as final.
     *
     * Traced this round: MOVS PC,LR resumed in ARM state at the return
     * address (0x227ae8), but the real code there is Thumb ("str r3,[r4,#4]"
     * = 0x6063, decodes as the real instruction only in Thumb mode -
     * confirmed by disassembling the same bytes both ways; ARM mode calls
     * it UNDEFINED, matching QEMU's exact exception exactly). This means
     * SPSR's T-bit was not correctly restored by the plain MOVS-based
     * return in this scenario. LR's bit 0 is set (0x227ae5), i.e. the
     * firmware's OWN calling convention already encodes "return to Thumb"
     * there - BX LR respects that bit for interworking regardless of
     * SPSR/CPSR state, so it is used instead of MOVS PC,LR. */
    vec[2] = 0xE12FFF1EU;  /* bx lr */

    /* bypasses.md #97: the AArch64 CPU is created FIRST so that it gets QEMU cpu index 0 = GIC CPU 0 = redistributor frame 0 (0x0c040000). BL31 derives its core
     * from MPIDR (Aff0 = 0 -> core 0) and programs the groups / secure PPIs of frame 0 only; with the AArch64 CPU at index 1 the kernel found its redistributor in
     * frame 1 (GICR_IGROUPR0 = 0, every PPI secure Group 0) and could never enable the NS physical timer PPI -> no tick, idle forever after init_heavy_tlb. */
    {
        Object *c1 = object_new(ARM_CPU_TYPE_NAME("cortex-a55"));
        object_property_set_int(c1, "cntfrq", 13000000, &error_fatal);
        /* bypasses.md #66: BL31 (cortex-a55) touches the RAS registers ERRSELR_EL1/ERXCTLR_EL1 (0x48c26770); QEMU's cortex-a55
         * model does not advertise FEAT_RAS and UNDEFs them -> "Unhandled Exception in EL3". Advertise RAS = 1 before realize so QEMU
         * registers its (RAZ/WI-style) RAS register set. */
        FIELD_DP64_IDREG(&ARM_CPU(c1)->isar, ID_AA64PFR0, RAS, 1);
        /* bypasses.md #68: the AArch64 CPU stands in for the boot core (core 0 of cluster 0), not for QEMU cpu index 1. BL32 (TEEGRIS)
         * looks the core up by MPIDR_EL1 in an 8-entry table at 0x76a05cc8 (entries 0x81000000, 0x81000100, ... : MT bit set, Aff1 = core) and
         * spins on "b ." (0x76a05ce8) when it is not found; QEMU would report 0x80000001. MPIDR_EL1 is overridden below. */
        /* bypasses.md #77: the GIC routes by the CPUs' affinity (GICD_IROUTER = 0 = affinity 0.0.0.0, what LK writes for every SPI).
         * cpu1 (the AArch64 stand-in for the boot core) must own affinity 0; the parked AArch32 preloader core gets 0x100. */
        object_property_set_int(c1, "mp-affinity", 0, &error_fatal);
        object_property_set_bool(c1, "start-powered-off", true, &error_fatal);
        qdev_realize(DEVICE(c1), NULL, &error_fatal);
        g_cpu64 = ARM_CPU(c1);
        define_arm_cp_regs(g_cpu64, ras_error_records);
        define_a55_impdef(g_cpu64);
        define_arm_cp_regs(g_cpu64, mt6833_mpidr);
        if (getenv("REHOST_LK_PATCHES") && *getenv("REHOST_LK_PATCHES")) { g_lkp_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, lkp_tick, NULL); timer_mod(g_lkp_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 2); }
        if (getenv("REHOST_HEARTBEAT")) { g_hb_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, hb_tick, NULL); timer_mod(g_hb_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 1000); }
        g_handoff_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, handoff_tick, NULL);
        timer_mod(g_handoff_timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + 5);
    }

    Object *cpuobj = object_new(ARM_CPU_TYPE_NAME("cortex-a55"));
    s->cpu = ARM_CPU(cpuobj);
    object_property_set_bool(cpuobj, "aarch64", false, &error_fatal);
    object_property_set_int(cpuobj, "cntfrq", 13000000, &error_fatal);
    object_property_set_int(cpuobj, "mp-affinity", 0x100, &error_fatal);
    qdev_realize(DEVICE(cpuobj), NULL, &error_fatal);

    /* bypasses.md #71: GICv3 (DTB gic@0x0c000000: distributor 0x40000, redistributors 0x0c040000..). LK enables the system register
     * interface (mcr p15,0,r4,c12,c12,5 = ICC_SRE at 0x4825aad8) and UNDEFs without a GIC. Both CPUs are attached (QEMU's GIC maps
     * CPU index -> redistributor); no interrupt sources are wired yet. */
    {
        DeviceState *gic = qdev_new("arm-gicv3");
        SysBusDevice *gsb = SYS_BUS_DEVICE(gic);
        qdev_prop_set_uint32(gic, "revision", 3);
        qdev_prop_set_uint32(gic, "num-cpu", 2);
        qdev_prop_set_uint32(gic, "num-irq", 288);
        QList *rc = qlist_new();
        qlist_append_int(rc, 2);
        qdev_prop_set_array(gic, "redist-region-count", rc);
        qdev_prop_set_bit(gic, "has-security-extensions", true);
        object_property_set_link(OBJECT(gic), "sysmem", OBJECT(sysmem), &error_fatal);
        sysbus_realize_and_unref(gsb, &error_fatal);
        sysbus_mmio_map(gsb, 0, 0x0c000000ULL);
        sysbus_mmio_map(gsb, 1, 0x0c040000ULL);
        for (int i = 0; i < 2; i++) {
            DeviceState *cpud = DEVICE(i == 0 ? (Object *)g_cpu64 : (Object *)s->cpu);
            sysbus_connect_irq(gsb, i, qdev_get_gpio_in(cpud, ARM_CPU_IRQ));
            sysbus_connect_irq(gsb, 2 + i, qdev_get_gpio_in(cpud, ARM_CPU_FIQ));
            sysbus_connect_irq(gsb, 4 + i, qdev_get_gpio_in(cpud, ARM_CPU_VIRQ));
            sysbus_connect_irq(gsb, 6 + i, qdev_get_gpio_in(cpud, ARM_CPU_VFIQ));
            if (i == 0) g_msdc_irq = qdev_get_gpio_in(gic, 99);   /* LK waits for this interrupt (msdc_lk_intr_wait) */
            if (i == 0) {
                g_gpt_irq = qdev_get_gpio_in(gic, 211);
                for (int n = 1; n <= 5; n++) g_gpt_timer[n] = timer_new_ns(QEMU_CLOCK_VIRTUAL, gpt_fire, (void *)(intptr_t)n);
            }
            /* generic timer PPIs -> GIC (same wiring as hw/arm/virt.c): PPI base = (num_irq - 32) + cpu * 32 + 16 */
            {
                static const int timer_ppi[] = { 14, 11, 10, 13 };   /* GTIMER_PHYS (30), VIRT (27), HYP (26), SEC (29) */
                int ppibase = (288 - 32) + i * 32 + 16;
                for (int t = 0; t < 4; t++) {
                    qdev_connect_gpio_out(cpud, t, qdev_get_gpio_in(gic, ppibase + timer_ppi[t]));
                }
            }
        }
    }

    memory_region_init_io(&s->uart_io, NULL, &uart_io_ops, s,
                          "rehost-preloader.uart", UART_SIZE);
    memory_region_add_subregion(sysmem, UART_BASE, &s->uart_io);

    memory_region_init_io(&s->msdc0_io, NULL, &msdc0_io_ops, s,
                          "rehost-preloader.msdc0", MSDC0_SIZE);
    memory_region_add_subregion(sysmem, MSDC0_BASE, &s->msdc0_io);

    memory_region_init_io(&s->gpio_io, NULL, &gpio_io_ops, s,
                          "rehost-preloader.gpio", GPIO_SIZE);
    memory_region_add_subregion(sysmem, GPIO_BASE, &s->gpio_io);


    /* v2: shadow-map remaining DTB blocks (skip any overlapping a dedicated model). */
    {
        const uint64_t ded[][2] = {{UART_BASE,UART_SIZE},{MSDC0_BASE,MSDC0_SIZE},{GPIO_BASE,GPIO_SIZE},{0x10008000ULL,0x1000ULL},{0x10027000ULL,0x900ULL},{0x10026000ULL,0x1000ULL},{0x10210000ULL,0x1000ULL},{0x0c000000ULL,0x40000ULL},{0x0c040000ULL,0x200000ULL}};
        int mapped = 0;
        for (size_t i = 0; i < sizeof(dtb_blocks)/sizeof(dtb_blocks[0]); i++) {
            bool skip = false;
            for (size_t k = 0; k < 9; k++) {
                if (dtb_blocks[i].base < ded[k][0] + ded[k][1] &&
                    ded[k][0] < dtb_blocks[i].base + dtb_blocks[i].size) skip = true;
            }
            if (skip) continue;
            DtbShadow *d = g_new0(DtbShadow, 1);
            d->size = dtb_blocks[i].size;
            d->base = dtb_blocks[i].base;
            d->buf = g_malloc0(d->size);
            memory_region_init_io(&d->mr, NULL, &shadow_ops, d, "rehost-preloader.dtbshadow", d->size);
            memory_region_add_subregion(sysmem, dtb_blocks[i].base, &d->mr);
            mapped++;
        }
        info_report("rehost-preloader: %d DTB peripheral blocks mapped as RW shadow", mapped);
    }


    {
        MemoryRegion *ca = g_new0(MemoryRegion, 1);
        memory_region_init_io(ca, NULL, &catchall_ops, NULL, "rehost-preloader.catchall", 0x14000000ULL);
        memory_region_add_subregion_overlap(sysmem, 0x0c000000ULL, ca, -10);
    }


    {
        MemoryRegion *gpt = g_new0(MemoryRegion, 1);
        memory_region_init_io(gpt, NULL, &gpt_ops, NULL, "rehost-preloader.apxgpt", 0x1000);
        memory_region_add_subregion(sysmem, 0x10008000ULL, gpt);
    }


    {
        MemoryRegion *pm = g_new0(MemoryRegion, 1);
        pmic_regs[3][0x0009] = 0x15; pmic_regs[3][0x000b] = 0x15;
        /* bypasses.md #87: PMIC AUXADC result registers (channel table at 0x254250: request reg 0x1108/0x110a, data regs 0x10b0 (ch0 = BATADC), 0x108e,
         * 0x1090, 0x10c4, 0x10c6, 0x10c8, 0x1092, 0x1094, 0x10a2, 0x109a, 0x10bc, 0x109e): bit15 = data ready, bits[14:0] = raw. Without it the preloader
         * logs "pmic_get_auxadc_value (0) Time out!" and LK reads a 0 V battery -> boot mode 9 = LOW_POWER_OFF_CHARGING instead of normal boot.
         * Conversion of channel 0 (FUN_00232bc0: raw * 35 * 180 >> 15): raw 20800 = 4.0 V. The other channels report 0 (no inputs). */
        {
            static const unsigned adc_regs[] = {0x10b0, 0x108e, 0x1090, 0x10c4, 0x10c6, 0x10c8, 0x1092, 0x1094, 0x10a2, 0x109a, 0x10bc, 0x109e};
            for (unsigned k = 0; k < sizeof(adc_regs) / sizeof(adc_regs[0]); k++) {
                uint16_t v = 0x8000 | (adc_regs[k] == 0x10b0 ? 20800 : 0);
                pmic_main[adc_regs[k]] = v;
                pmic_regs[3][adc_regs[k]] = v & 0xff; pmic_regs[3][adc_regs[k] + 1] = v >> 8;
            }
        }
        memory_region_init_io(pm, NULL, &pmif_ops, NULL, "rehost-preloader.pmif", 0x900);
        memory_region_add_subregion(sysmem, 0x10027000ULL, pm);
    }


    {
        MemoryRegion *pw = g_new0(MemoryRegion, 1);
        pmic_main[0x2a] = (getenv("REHOST_LOG_KEY") && *getenv("REHOST_LOG_KEY")) ? 0x0002 : 0x000a;   /* REHOST_LOG_KEY=1 holds the RST/home key: FUN_002263a4(17) -> "Log" stays on (0x230da2) */
        if (0) pmic_main[0x2a] = 0x000a;    /* TOPSTATUS: bit3 (RST/home key, FUN_00232778) and bit1 (pwr key, FUN_00232758) set = released (code returns 1 - bit) */
        pmic_main[0xa1a] = 0x0004;   /* bypasses.md #38: bit2 -> global 0x272d30 (read via FUN_00232678 at 0x232a74), the flag
                                      * FUN_00232860 returns; non-zero = "Power key boot!" (0x231b56), zero + no charger = "Unknown boot" -> power off */
        pmic_main[0xc8e] = 0x1000;   /* bypasses.md #39: fuel-gauge efuse word, FUN_002060f4 (0x206156) loops "[PMIC ERROR]NO EFUSE!!" while (reg & 0x1fff)==0;
                                      * only non-zero is required, 0x1000 is a stub value (encrypted/factory-trim data is not available) */
        pmic_main[0x40e] = 0x5aa5;   /* DEW_READ_TEST: pwrap init (FUN_002337f8) requires 0x5aa5 */
        memory_region_init_io(pw, NULL, &pwrap_ops, NULL, "rehost-preloader.pwrap", 0x1000);
        memory_region_add_subregion(sysmem, 0x10026000ULL, pw);
    }


    {
        const char *img = getenv("REHOST_EMMC_IMG");
        extcsd[192] = 8;                       /* EXT_CSD_REV 5.1 */
        extcsd[196] = 0x57;                    /* DEVICE_TYPE */
        extcsd[168] = 0x20;                    /* bypasses.md #63: RPMB_SIZE_MULT (128 KiB units) = 4 MiB; FUN_00224ce8 needs >= 0x20000 or prints "gz insufficient RPMB size" with a bad %s */
        extcsd[226] = 0x10; extcsd[160] = 0x03; /* BOOT_SIZE_MULT, partitioning support */
        extcsd[224] = 1; extcsd[221] = 1;       /* bypasses.md #111: HC_ERASE_GRP_SIZE = HC_WP_GRP_SIZE = 1 (512 KiB units) */
        if (img) {
            bool wb = getenv("REHOST_EMMC_WRITEBACK") != NULL;   /* diagnostics: post-hand-off writes go to the image file (MAP_SHARED) so /data (tombstones, logs) can be read after the run */
            FILE *f = fopen(img, wb ? "r+b" : "rb");
            if (f) {
                fseek(f, 0, SEEK_END); emmc_size = ftell(f); fseek(f, 0, SEEK_SET);
                /* bypasses.md #116: the image can be many GB (real super partition): map it MAP_PRIVATE instead of reading it into memory */
                emmc_img = mmap(NULL, emmc_size, PROT_READ | PROT_WRITE, wb ? MAP_SHARED : (MAP_PRIVATE | MAP_NORESERVE), fileno(f), 0);
                if (emmc_img == MAP_FAILED) { error_report("mmap emmc img failed"); exit(1); }
                fclose(f);
                uint32_t sec = emmc_size / 512;
                memcpy(extcsd + 212, &sec, 4);
                info_report("rehost-preloader: eMMC image %s %" PRIu64 " bytes (%u sectors)", img, emmc_size, sec);
            }
        }
    }


    {
        MemoryRegion *dx = g_new0(MemoryRegion, 1);
        memory_region_init_io(dx, NULL, &dxcc_ops, NULL, "rehost-preloader.dxcc", 0x1000);
        memory_region_add_subregion(sysmem, 0x10210000ULL, dx);
    }

    if (serial_hd(0)) {
        qemu_chr_fe_init(&s->uart_chr, serial_hd(0), &error_abort);
        qemu_chr_fe_set_handlers(&s->uart_chr, uart_can_receive,
                                 uart_receive, NULL, NULL, s, NULL, true);
    }

    place_container(s, ms);

    /* v2 (bypasses.md #30): ALL pointer bypasses of v1 (#11,#12,#13,#14,#21,#29) removed - they were artifacts of loading the payload 0x600 too high. */

    qemu_register_reset(cpu_reset_hook, s->cpu);
}

static const char * const rehost_preloader_valid_cpu_types[] = {
    ARM_CPU_TYPE_NAME("cortex-a55"), NULL,
};

static void rehost_preloader_class_init(ObjectClass *oc, const void *data) {
    MachineClass *mc = MACHINE_CLASS(oc);
    mc->desc = "rehost: SM-A136U/MT6833 preloader (AArch32, round ~21)";
    mc->init = rehost_preloader_init;
    mc->valid_cpu_types = rehost_preloader_valid_cpu_types;
    mc->default_cpu_type = ARM_CPU_TYPE_NAME("cortex-a55");
    mc->max_cpus = 1;
    mc->no_floppy = true;
    mc->no_cdrom = true;
}

static const TypeInfo rehost_preloader_machine_typeinfo = {
    .name = TYPE_REHOST_PRELOADER_MACHINE,
    .parent = TYPE_MACHINE,
    .class_init = rehost_preloader_class_init,
    .instance_size = sizeof(RehostPreloaderState),
    /* REQUIRED on QEMU 10.2.2 - see the LK machine's own rehost_info for the
     * full explanation (ARM32_ATTEMPT.md 7-b): without this, -M help/-M
     * <name> silently never find the type even though registration succeeds. */
    .interfaces = aarch64_machine_interfaces,
};

static void rehost_preloader_machine_register(void) {
    type_register_static(&rehost_preloader_machine_typeinfo);
}
type_init(rehost_preloader_machine_register)
