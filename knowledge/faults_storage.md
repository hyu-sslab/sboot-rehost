# Knowledge table - vendor storage controller walls

The trap table for `fixer-storage`. **A new wall is one new row here.**
Classification table: `knowledge/faults_unified.md`.

The walls below are UFS. **eMMC controllers (MediaTek MSDC) have their own
section further down** - the method is the same, the walls are not.

## What this is for

This is where rehosting happens *by implementing the controller*. The
goal is not "mount a rootfs" - it is **driving the real vendor UFS controller**
far enough that the kernel enumerates partitions. Every milestone below is a
graduation mark on that controller's completeness, not a separate objective.

Core idea: **use the driver as the instrument.** With no datasheet, observe which
registers the real vendor driver polls and what value it waits for, then fill the
model from that observation.

**The vendor driver need not be a `.ko`.** Kernels that compile UFS in
(`CONFIG_SCSI_UFS_*=y`) have no module by design, yet the real vendor driver is
present and will drive a modelled controller. Only
"no `.ko` **and** no driver in the kernel image" is a genuine blocker.

Log sources: the kernel console plus the storage model's own `qemu_log` (vendor
window reads and writes, UTRD/UPIU transactions).

| name | log signature | treatment |
|---|---|---|
| `poll_stall` | hundreds of repeating `RD <win>+0x… -> 0x0` lines | if that offset is a done/ready bit, set **only that bit**. If the awaited bit is unknown, derive it |
| `desc_addr_corrupt` | `NOP OUT failed -22`, response ttype mismatch | dump the raw 32-byte UTRD. Bit 31 set in the lo dword means a **sign-extension bug**: cast to `(uint32_t)` before widening |
| `prdt_stride` | reads "succeed" (`got == bytes`) but userspace executes wrong bytes: SIGILL, `init` dies early, loaded page contents mismatch the on-disk block | dump PRDT entries and measure the **actual stride between them**. Vendor extensions widen the sg entry (Samsung Exynos FMP inline crypto: 16 B descriptor + 112 B = **128 B stride**). Fix the scatter walk's stride; do not assume 16 B |
| `pwrmode_timeout` | `change_power_mode … -110`, `uic … timeout` | re-check the DME opcode. For `attr==PWRMode`, set `HCS.UPMCRS=1` and raise the `IS.UPMS` completion IRQ |
| `gear_source` | `max_gear(0)`, `Failed getting max … power mode` | when the log has no gear read, confirm the window and offset by `.ko` disassembly and return the gear value there |
| `upiu_field_off` | `[sda] Attached` but no `sda1`, `lun=68 edtl=0` | correct `handle_scsi` to `lun = cmd[2]`, `edtl = cmd[12..15]` |
| `block_size` | only LBA0 is read, `EFI PART` not found | locate the `EFI PART` signature in the backing image, then set `EUFS_LBS` to 512 or 4096 |
| `vendor_telemetry_null` | null-pointer Oops after the power mode passes | return early from the telemetry function (`*_sec_set_features` family) with `mov w0,#0; ret`. Bypass documentation mandatory |
| `irq_edge_level` | UIC command times out `-110` even though the model set the completion bit | the HCI interrupt must be **level-triggered** (`qemu_set_irq` held while IS & IE), not a pulse. An edge is missed and the driver waits forever |
| `is_bit_layout` | power-mode change times out `-110` while link-up worked | the IS register bit positions are wrong. Derive each from the driver's masks - **UPMS is bit 4**, ULSS bit 8, UCCS bit 10; guessing bit 8 for UPMS is the common miss |
| `query_upiu_overwrite` | `Response size is bigger than buffer`, or the descriptor arrives with a corrupt header | write the response UPIU **once**: place the descriptor at `resp+32` and write header+payload in a single transfer. Writing them separately lets the second write clobber the header. Cap the length by the request's own field |
| `sparse_super_gpt` | `[sda] Attached` but no partitions, and the backing image is `super.img` | an Android **sparse super is not a GPT disk**. Decode the sparse image and synthesise a LUN with a GPT (primary + backup) whose partition covers it, then back the model with that |
| `unknown` | nothing above matches | **static-analyzer re-derivation** |

## UniPro DME opcodes

| command | opcode |
|---|---|
| `DME_GET` | 0x01 |
| `DME_SET` | 0x02 |
| `DME_PEER_GET` | 0x03 |
| `DME_PEER_SET` | 0x04 |

## Milestone ladder - the completion bar

| stage | milestone | line shape (seen on one device; derive yours) | walls to clear |
|---|---|---|---|
| — | `link_up` | `scsi host\d+: ufshcd`, or a `… UFS link established` line | PHY calibration (`poll_stall`) |
| — | `power_mode` | `Power mode change\(\d+\): M\(\d+\)G\(\d+\)L\(\d+\)<mode>\(\d+\)` | `desc_addr_corrupt`, `pwrmode_timeout`, `gear_source` |
| — | `scsi_attach` | `\[sd[a-z]+\] Attached SCSI disk` | Query device, `vendor_telemetry_null` |
| **최소 완료** | **`partitions_up`** | `sd[a-z]+: sd[a-z]+\d+( sd[a-z]+\d+)*` | `upiu_field_off`, `block_size`, `prdt_stride` |
| **최종 칸** | `super_mounted` | `erofs: \(device dm-\d+(/dm-\d+)?\): mounted` plus the super-mount success line the target prints | async probe timing |

The patterns are shapes: the literal text, the device names and the counts differ per kernel and per
device. The line to watch for is the one your own target prints, derived from its kernel strings.

**`partitions_up` is minimum completion; `super_mounted` is the
final rung - the full UFS controller.** Below `partitions_up` the controller is unfinished:
report the highest milestone honestly and treat the next wall. Never dress
partial progress up as completion.

**The capstone depends on the image topology, not on effort.** Only firmware that
ships a `super.img` (dm-linear, usually EROFS) can print that line. Firmware with
separate `system`/`vendor` raw images - often ext4, mounting as
`EXT4-fs (sda): mounted filesystem` / `VFS: Mounted root (ext4 filesystem)` -
**completes at `partitions_up`** and never has a final rung. Keeping `super_mounted` as a
required rung there would demand a goal that cannot exist.

## eMMC controller (MSDC) - walls seen on one MediaTek device

The method is the one above: **use the driver as the instrument**, observe what
the real driver does to the controller and model only that. The table is
**knowledge rows, not code** - you read the signature and then correct the model
you wrote. Register and DMA semantics here come from **one** controller
(MediaTek MSDC); that they hold on another eMMC controller is **unverified**.
Register names are as that vendor driver spells them. **Offsets and bit
positions are derived from the driver's own accesses, never taken from this
table.**

An eMMC controller is also driven **twice** - by the bootloader and later by the
kernel - and the two drivers program it differently. A model fitted to one driver
breaks under the other.

| name | log signature | treatment |
|---|---|---|
| `emmc_sd_probe_answered` | the bootloader's medium init fails or falls onto the SD path, and its log shows SD-only probe commands (CMD8 with the 0x1aa check pattern, CMD55/ACMD41, CMD5) that the model **answered** | an eMMC device does not answer those commands. Let them time out through the controller's command-timeout status instead of fabricating a response |
| `emmc_36bit_addr` | the kernel reports `mmcblk0 … 0 B` although the bootloader read the same medium | the kernel's controller driver uses **36-bit DMA addresses**, so a buffer above 4 GiB needs the high address bits (the EXT_CSD read is where it shows first). Implement the high-address register (`DMA_SA_H4B`) and the `PTR_H4` / `NEXT_H4` fields of the GPD and BD descriptors. Derive their offsets from the driver's accesses |
| `emmc_wp_group` | `Start 0x… of disk mmcblk0 not write group aligned` while partitions are added, or `PIO Data Timeout: CMD<31>` after a write-protect query | two faces of the write-protect group model. (a) report a write-group size the partition starts satisfy in CSD / EXT_CSD - take the unit from the failing check, not from this row. (b) answer the write-protect status queries (CMD30 / CMD31) with 0 instead of letting them time out |
| `msdc_dma_rerun` | **a different Oops on every run** (kernfs, inode, slab) or corrupted freed buffers while MMC reads are in flight | the model leaves the DMA `START` bit set in the register, so every read-modify-write of `DMA_CTRL` starts the transfer again and overwrites a buffer the kernel already freed. `START` is a **write-1 pulse** and reads back 0; in descriptor mode run a GPD only while its `HWO` bit is 1. Suspect this **before** any patch of an allocator or I/O scheduler |
| `msdc_basic_len` | a small buffer (4 KiB on the device studied) is followed by far more overwritten memory (about 124 KiB there) | basic-DMA mode: the model ignores `DMA_LEN`. Move exactly `DMA_LEN` bytes per `START` |
| `msdc_write_lost` | part of a written file reads back as zero blocks (a mapped library crashes in userspace; the on-disk image differs from the source) | `BLK_NUM` is an **upper bound**, not a count to wait for: the model waited until that many blocks had arrived before writing, so a shorter write was dropped. Write the actual bytes at each `START` immediately and clear the transfer state at the next data command or stop command. **Compare the written image with its source (`cmp`) before blaming userspace** |

**Lesson, promoted from the one run that paid for it:** random Oops over freed
memory means **the DMA model re-ran a transfer** until shown otherwise. On the
device studied, three patches against an I/O scheduler treated what
`msdc_dma_rerun` caused, and nobody took them back out after the real cause was
fixed. Take a symptom patch back out and re-verify once its cause is fixed.

### eMMC milestones

The UFS ladder above (`sda: sda1 …`) does not apply; a separate rung exists for
the medium itself.

| milestone | what to observe | channel |
|---|---|---|
| `medium_up` | the bootloader's own medium-init line naming the eMMC type. **It is the primary evidence for the medium type** - a `ufshci` node in the DTB is a SoC-shared node and is no evidence on its own | UART |
| `partitions_up` | `mmcblk\d+: p\d+` in the kernel log (the **memory-dump** channel when the UART is silent) | memdump |

## When the value lives in code - `.ko` disassembly (ask static-analyzer)

```
find the .rodata file offset of the string, e.g. "max_gear(%d)"
 -> readelf -r <ko>, find the .rela.text entry referencing it -> .text offset
 -> objdump -d / capstone: ldr xbase / mov wimm / bl readl
 -> conclude readl(<window> + <imm>) and model that window and offset
```

## The most harmful cheat in this domain

**Adaptive toggles are absolutely forbidden.** "Change the value based on the read
count" (return 0 twelve times, then alternate 0xFFFFFFFF) is most tempting here,
because the driver visibly progresses. It sends the firmware down a wrong branch
and **fakes a pass** (honesty rule 1). **Model constant ready values only.**

- **Rule out hypotheses with a raw byte dump** before concluding, especially for
  `desc_addr_corrupt` and `prdt_stride`.
- **Completeness is not correctness.** Instrumenting a read to check
  `got == bytes` proves every byte arrived; it says nothing about *where* they
  were placed. A wrong PRDT stride passes that check and still corrupts
  multi-page transfers, so the mount (single-entry, one page) works while
  userspace executes garbage. When reads "succeed" but the loaded pages disagree
  with the on-disk blocks, measure the descriptor stride before blaming anything
  outside the storage model.
- **Doubt constants, field positions and block sizes**; re-check them against the
  spec or the on-disk signature rather than intuition.
- **Document every `.ko` bypass.** Replacing real driver code defeats the point.
