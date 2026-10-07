# Knowledge table - MediaTek family stop points

Read by `fault-classifier` when naming a stop point, and by the fixers when
choosing a treatment. The pipeline hands it over because `profiles/mediatek.yaml`
lists it under `knowledge:` - **a new MediaTek stop point is one new row here**,
the agent prompts stay untouched.

It **adds** to `knowledge/faults_unified.md`; every name there still applies on
this family. Match against both. The progress order (which step comes next) is
the runbook, `knowledge/runbook_mediatek.md`; this table is the **treatment** for
a stop point inside a step.

**No values live here.** The rows say what a stop point looks like and what
mechanism sits behind it. Addresses, register offsets and the bit that a poll
waits for are derived from the target firmware (honesty rule 1). Anything written
as `(one device)` was observed on a single MediaTek firmware - it is a shape to
look for, not a fact about yours.

The 위치 column says where in the chain a class can appear. Log sources: the
`qemu -d int,in_asm,unimp,guest_errors` trace, the guest console (UART plus the
memory-dump kernel log), and the storage model's own `qemu_log`. **Host
diagnostic lines (`qemu-system-aarch64: …`) are our machine talking** - they may
help locate a stop point, they are never evidence that the guest reached
anything.

---

## 1. Boot medium and bootloader

| name | 위치 | log signature | owning fixer | treatment |
|---|---|---|---|---|
| `download_mode_entry` | 부트로더 | the bootloader's secure-boot download check reports a non-boot decision and it offers flashing (`sec_check_download: 7`, one device). **Extends the row of the same name in `faults_unified.md`** | `fixer-bootflow` | a **symptom, not a cause**: read WHICH branch fired in the log before changing anything. Three causes were seen on one device. (1) a vendor boot-parameter structure the bootloader expects at a medium position it compares against: derive the position from the comparison in its disassembly - never guess the layout; this is a defect of the medium we synthesised, so rank `fixer-storage` next. (2) a digest comparison that fails because a hardware hash engine is not modelled: take the verification order of the runbook (model first, labelled bypass second). (3) a write state left unfinished by the storage model so the next read never completes: see `msdc_write_lost` |
| `emmc_sd_probe_answered` | 부트로더 | the bootloader's medium init fails or drops onto the SD path while its log shows SD-card probe commands that our model **answered** | `fixer-storage` | eMMC section of `knowledge/faults_storage.md`. The model answered commands an eMMC device does not answer; make them time out |

## 2. EL3 monitor to kernel

| name | 위치 | log signature | owning fixer | treatment |
|---|---|---|---|---|
| `gic_redistributor_order` | 커널 | no kernel timer tick: the kernel log stops advancing and the CPUs idle in WFI with **no exception storm**, after the bootloader and the monitor ran normally (one device) | **build layer - no fixer** | the monitor initialises only the redistributor frame of the CPU whose affinity is 0, and QEMU numbers the interrupt controller's CPU interfaces by **CPU creation order**. If the CPU that runs the monitor was not created first, its frame is never set up. Derive which frame the monitor writes from the monitor's own init and from the GIC register reads at the stall - not from this row. `supervisor` routes `rebuild` with the creation order; a fixer can only treat the next symptom |
| `guest_reset_after_jump` | 커널 진입 직후 | **hypothesis, not confirmed.** After the bootloader's kernel-jump line there is no kernel text in either channel, and the host lines show a reset or watchdog block being touched within seconds of the jump (`observation.json` `guest_reset_signal`). On one device 3 of 12 early stops had no known cause, and in the one stop whose host lines were compared that read came right after the jump (normal runs show it only when the guest reboots). Not re-measured | none yet | **do not fix, derive.** (1) record when the access appears after the jump. (2) pin the guest PC that performs it with a narrow `-d exec` trace. (3) disassemble that function and tell its call path apart: panic handling, watchdog service or a firmware reset call. (4) once one is established it is a stop point with a cause - write the row to `STATIC.md`. **If step 1 finds no access, drop the hypothesis.** The cause is not known: do not name one in advance, and do not build a reset model on the hypothesis alone |

## 3. Kernel

| name | 위치 | log signature | owning fixer | treatment |
|---|---|---|---|---|
| `coprocessor_ipi_timeout` | 커널 | `kernel BUG at <name>_ipi_timeout_cb`-shaped Oops: a vendor driver waits for an IPI reply from a coprocessor (power, sensor-hub, MCU) that nothing runs here | `fixer-kernel` | **list the package components first** - the coprocessor image may ship in the package (on one device it did, and was judged absent three times). "Absent" is written only from that inventory. If it is there, loading it is the honest path. If it cannot run, model the mailbox reply (model or value) before any `.text` patch; patch only when a model is unrealistic, pre-image mandatory, one site per round. Say in 이유 whether the image was present |
| `mmc_partition_scan_failed` | 커널 | `Attempted to kill init` together with a `partition(s) not found`-style message: the mmc block device never produced its partitions | `fixer-storage` | **a downstream stop point - one stop point, not many.** Walk back to the controller model: capacity `0 B` -> `emmc_36bit_addr`; `not write group aligned` or a `PIO Data Timeout` on a write-protect query -> `emmc_wp_group`; a different Oops each run -> `msdc_dma_rerun`. Do not name each downstream failure on its own and do not send `fixer-memory` or `fixer-kernel` after them. If no eMMC row matches, answer `unknown` |
| `softdog_expired` | 커널 | `Software Watchdog Timer expired` panic well after userspace started | `fixer-kernel` | userspace armed a software watchdog and nothing here pings it. It appears only in long runs, so it is not a stop point for a rung observed earlier. Treatment: a `.text` patch of the expiry panic path, pre-image mandatory, four-field bypass whose 부작용 says the watchdog is no longer enforced |

## 4. Boot medium - eMMC controller

The eMMC controller walls are in **`knowledge/faults_storage.md`** (section
"eMMC controller") and are owned by `fixer-storage`: `emmc_sd_probe_answered` ·
`emmc_36bit_addr` · `emmc_wp_group` · `msdc_dma_rerun` · `msdc_basic_len` ·
`msdc_write_lost`. The boot medium type is decided in step S5 of the runbook,
from the bootloader's own log - not from a `ufshci` node alone.

## 5. Seen, not yet classified

No log signature was recorded for these, so they are **not rows**. When one
fires, the honest answer is `unknown` and a re-derivation; the finding then
becomes a row in `STATIC.md`.

- The EL3 monitor stops on an exception at an access to an implementation-defined
  or RAS register. The instruction at ELR names the register; the runbook (S4)
  gives the order of treatment.
- The secure OS' first execution stops while searching a core table: check which
  MPIDR it requires.

Out of scope: second-stage init and TEE services (F3 and later).

---

## Traps

- **A random Oops over freed memory is not `kernel_oops` or `security_gate`.** If
  it differs from run to run and corrupts kernfs or inode caches, suspect the
  storage model's DMA re-execution (`msdc_dma_rerun`) first. On one device three
  patches against an I/O scheduler were written for what the DMA model caused,
  and they were never taken back out.
- **UART silence from the kernel is not `console_silent`.** On this family the
  kernel may print nothing on the UART while it runs; its log is in the memory
  dump channel. `console_silent` means **0 bytes of console and 0 exceptions for
  the whole run**, not "the bootloader's lines stop at the jump".
- **Do not call a coprocessor stop point "hardware missing" from the symptom
  alone.** Inventory the package first.
- **Do not patch out a failed verification to move a rung.** A bypassed
  `verify_ok` is `reached_bypassed`, labelled, and recorded with its side
  effect. See the verification order in the runbook (S6).
