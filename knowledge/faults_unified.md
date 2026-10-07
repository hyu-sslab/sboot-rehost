# Knowledge table - unified chain stop points

Read by `fault-classifier` when naming a stop point, and by the fixers when
choosing a treatment. **A new stop-point class is one new row here** - the agent
prompts stay untouched.

The unified flow rehosts one chain, so one table covers it. The **위치** column
says where in the chain a class can appear; a classifier that names a kernel
fault while the run is still in the first stage has named the wrong thing.

Log sources: the `qemu -d int,in_asm,unimp,guest_errors` trace, the console, and
the storage model's own `qemu_log`.

Depth references (procedure, not classification):
`knowledge/faults_storage.md` (controller walls) · `knowledge/kernel_gates.md`
(gate patch-site derivation).

---

## 1. Chain-wide (any stage)

| name | log signature | owning fixer | treatment |
|---|---|---|---|
| `data_abort_unmapped` | `Taking exception 4 [Data Abort]` with `FAR 0x…` in an unmodelled region | `fixer-memory` | add a MemoryRegion covering that FAR (read 0 / write absorb) |
| `infinite_poll` | the same FAR repeating hundreds of times, only runtime grows | `fixer-memory` | return a constant with **only the awaited bit** set for that offset |
| `unmapped_mmio` | one-shot unmapped MMIO report (catch-all) | `fixer-memory` | check the DTB first, then a peripheral window or RAM |
| `smc_undef` | `Taking exception 2 [Undefined]` and ELR disassembles to `smc` | `fixer-el3` | handle that function id in the SMC shim |
| `fpu_trap` | `Taking exception 2` and ELR is FP/SVE (`ldr q`, `str q`, `ld1`) | `fixer-el3` | `cpacr_el1 = 0x300000` in the reset hook (widen to 0x333000) |
| `console_silent` | 0 bytes of console and 0 exceptions | `fixer-bootflow` | route the stage's putc callback to a direct UART write. **Never print from the machine** |
| `unknown` | nothing above matches | - | **static-analyzer re-derivation**, never a guess |

## 2. Stage transitions (the unified track's own classes)

| name | 위치 | log signature | owning fixer | treatment |
|---|---|---|---|---|
| `handoff_slot_missing` | 첫 스테이지 | a call through a handoff-surface slot the machine left empty: prefetch abort with ELR = 0 or a small constant, right after a `ldr wN,[<handoff window>] ; blr xN` | `fixer-bootflow` | fill **that one slot** with a model. Derive its contract from the call site's argument setup, not from what the name suggests. Record it as a bypass (4 fields) |
| `stage_handoff_missing` | 스킵 직후 스테이지 | a stage reads a memory word before it writes anything, and the value is garbage because the stage that wrote it was skipped | `fixer-bootflow` | first re-check `stage_map.json`: if the read target is a **hardware register**, this is not the fault - model the register. Only a word a skipped stage genuinely wrote qualifies, and supplying it is a bypass that must be documented |
| `handoff_slot_empty` | 스킵 직후 스테이지 | a magic check on a word a skipped stage should have written fails, and that failure is itself the entry condition for a download or flash mode - the bootloader announces that mode (`FDT_ERR_BADMAGIC`, `Invalid Magic`; the mode line itself differs per bootloader, `Entering odin mode` is the Exynos one, one device) | `fixer-bootflow` | fill only the field the check reads, and only with the **three pieces of evidence**: the reading instruction's address (capstone), the trace line or console line that shows it ran, and what stops being verified once filled. Missing any one of the three -> return `unknown`, do not invent the value |
| `boot_info_word_missing` | 첫 스테이지 | the stage reads a boot-information word left by the mask ROM (media type, signature nibble) and takes the wrong branch - typically "no boot device" or a fallback to a medium that is not modelled | `fixer-bootflow` | derive the encoding from the consumer, not from the vendor doc: find every branch that tests bits of that word and set only the bits those branches require. Record as a bypass |
| `download_mode_entry` | 부트로더 | the console shows the bootloader announcing a download or flash mode - the firmware gave up on booting and offered flashing instead (Exynos, one device: `parallel_download_init` / `Entering odin mode` / `[CC MODE] Failed`; a family table such as `faults_mediatek.md` extends this row with its own shape) | `fixer-bootflow` | this is a **symptom, not a cause**. Walk back to the check that failed (usually a preceding magic or signature test) and repair that. Patching the download branch itself hides the real stop point |
| `qemu_abort` | 무관 | QEMU exited non-zero **after** the guest had already produced console output; stderr carries an `Assertion ... failed` naming a QEMU source file | `fixer-general` | this is a machine-source defect, not an environment problem - the assert names the file and function, so the place is already located. Typical case: a BlockBackend borrowed with `blk_by_name()` but never given permissions with `blk_set_perm()`, which reads fine and asserts on the first write |
| `stage_entry_el_mismatch` | 어느 스테이지든 | `FAR == ELR` at a low unmapped address, exception count in the millions, 0 bytes of console | **build layer - no fixer** | the machine entered the stage at an exception level it was not built for. **Derive the level from the stage's own entry stub** - whichever `vbar_el*` it writes is the level it expects (`stage_map.json` records this). `supervisor` routes `rebuild` with that level. Do **not** default to `has_el3=false`: a first stage that writes `vbar_el3` needs EL3, and the opposite default silently breaks it |
| `stage_decrypt_blocked` | 암호화 스테이지 경계 | the firmware reaches a decrypt routine for a stage the entropy map marked encrypted, and fails | **not a firmware fault - no fixer** | the key is in silicon and is not in the package. This stage was supposed to be skipped: the previous stage's entry should have been redirected to the next executable stage. If the run got here, the redirect is missing or wrong - that is a **build-layer** correction, not a round |

## 3. Bootloader stage

| name | log signature | owning fixer | treatment |
|---|---|---|---|
| `null_ret` | `Taking exception 3 [Prefetch Abort]` with FAR=0 and ELR=0 | `fixer-bootflow` | trace back to the **last caller**; the callee returned null |
| `shell_exit_early` | the shell exits without input, no autoboot-aborted line | `fixer-bootflow` | make the derived getline timeout branch unconditional |
| `shell_mode_gate` | shell function entered and returns immediately, before the input gate is polled | `fixer-bootflow` | the predicate reads a mode/token word with no supplier here. Derive the predicate and neutralise **that one branch**; record as a guest-image patch bypass |
| `harness_input_starved` | `fingerprint.json` `input.starved: true` - the gate polled (`rx_polls > 0`) and read **none** of our bytes (`rx_served == 0`) | **harness - no fixer** | not a firmware stop point. Re-run; if it repeats, check `input_plan.json`'s `contiguous` / `empty_poll_budget` against the gate's disassembly |

## 4. Verified boot

| name | log signature | owning fixer | treatment |
|---|---|---|---|
| `avb_verify_fail` | the bootloader's own AVB path reports a verification failure | `fixer-secureboot` | ⚠ **first ask whether it SHOULD fail.** In the negative test a corrupted vbmeta must fail - that is a pass, not a fault. If the image is intact, the fault is in what we fed it: check the vbmeta/keystorage partitions in the boot medium, then the RPMB rollback answer. **First derive where the digest is computed** (the static-analyzer's `hash_engine` row in `STATIC.md`: `hardware` or `software`, with a hex function address or SMC id as evidence; only a usable `hardware` row opens the exception below). Software hash: **patching the verification out forfeits the whole claim.** Hardware engine (the digest path goes through an SMC or engine MMIO): an untouched pass is impossible without an engine, so the order is **model the engine -> labelled bypass (flag F, the cell becomes `reached_bypassed`) -> stop**; a bypass is never silent and never loosens the recording rule |
| `rollback_index_unavailable` | verification stalls or fails right after an RPMB read | `fixer-secureboot` | answer the RPMB read from the modelled key/counter store. Derive the expected index from the image, do not invent a value that merely makes it pass |
| `keystore_partition_missing` | the bootloader cannot find its key store on the medium | `fixer-storage` | the synthesised medium is missing that partition. Add it in `build_lu.py` with the name the bootloader actually looks for (derive the name from its strings) |

## 5. Boot medium / storage controller

The controller walls live in **`knowledge/faults_storage.md`** and are owned by
`fixer-storage`: `poll_stall` · `desc_addr_corrupt` · `prdt_stride` ·
`pwrmode_timeout` · `gear_source` · `upiu_field_off` · `block_size` ·
`vendor_telemetry_null` · `irq_edge_level` · `is_bit_layout` ·
`query_upiu_overwrite` · `sparse_super_gpt`.

| name | log signature | owning fixer | treatment |
|---|---|---|---|
| `partition_table_unavailable` | the firmware reports its partition table absent or failing its integrity check, and every partition lookup fails with it | `fixer-storage` | **In the unified flow this is a real fault, not a boundary.** The medium is modelled here, so an absent table means the synthesised image is wrong: check the GPT `EFI PART` signature offset against the block size the controller reports, then the partition entries |

> The same controller is driven **twice** - once by the bootloader's own driver
> and again by the kernel's. A model fitted to one and broken under the other is
> not a model of the controller; it is a model of one driver's expectations.
> When a fix helps one side and breaks the other, the fix is wrong.

## 6. Kernel

| name | log signature | owning fixer | treatment |
|---|---|---|---|
| `kernel_oops` | `Internal error: Oops` / `Unable to handle kernel … at <addr>` with a symbol | `fixer-kernel` | a security-gate symbol gets a `.text` patch. **Vendor telemetry belongs to `fixer-storage`** |
| `security_gate` | early panic with a `fips`/`crypto`/`defex`/`selinux`/`avb` symbol | `fixer-kernel` | add `(off, expected, new, why)` to `kernel_patch_sites.json` (the file `patch_kernel.py` takes). **Pre-image check is mandatory** |
| `psci_suspend` | stalls after WFI, cpuidle hangs | `fixer-el3` | let the shim handle `CPU_SUSPEND`. **`psci_conduit=DISABLED` is forbidden** |
| `hvc_pkvm` | hangs after HVC with `kvm-arm.mode=protected` in cmdline | `fixer-el3` | **remove the HVC interception** - the kernel's own pKVM handles it |
| `gic_ppi` | `gicv3_set_irq` assert, arch-timer not firing | `fixer-kernel` | wire the arch-timer PPIs as **full INTIDs** (29 / 30 / 27 / 26) |
| `cpu_cluster_mpidr` | `psci … cpu_on` returns **-22**, then the boot stops silently in `cpuhp` | `fixer-memory` | make cores-per-cluster match the DTB `cpu reg` encoding so MPIDRs line up |
| `rootfs_mount` | `Kernel panic … VFS: Unable to mount root` | `fixer-kernel` | DT fstab or dm-linear supermount. **A boot image with `ramdisk_size=0` is system-as-root: there is no initramfs and userspace does not exist until storage works** |

---

## Build-layer stop points

Some stop points cannot be fixed inside the loop at all. A fixer changes one
place in the machine sources that exist; it cannot change a premise the machine
was **built on** - `has_el3`, the entry exception level, entry PC, the per-stage
load bases, the memory skeleton, the CPU type, or which stages get skipped.

For these the owning column reads **build layer**, and the treatment is for
`supervisor` to route `rebuild` with a concrete premise correction. Handing one
to a fixer produces a band-aid that changes nothing - which is what a run of
identical fingerprints looks like.

`stage_map.json` is the record of those premises. When a build-layer stop point
fires, re-read it before proposing the correction.

## Derived stop points - the owner column in `STATIC.md`

The static-analyzer appends each stop point it has explained to the `## 도출된 정지점` table of
`STATIC.md` (`scripts/derived_facts.py` reads it; the classifier and the fixers match against
it). The **owner cell** of such a row is exactly one of the six fixer names - `fixer-memory`,
`fixer-el3`, `fixer-bootflow`, `fixer-secureboot`, `fixer-storage`, `fixer-kernel` - or the
literal word `build` (a build-layer premise: no fixer). Nothing else goes there: not
`fixer-general` (reached only after a specialist declines), not a sentence. A row whose owner
cell is none of these is skipped, so nobody ever sees it. This file's own tables write the
same thing as "build layer - no fixer"; a derived row writes `build`.

## Common 4-byte AArch64 encodings

| instruction | encoding |
|---|---|
| `MOV W0, #0` | `0x52800000` |
| `MOV W0, #1` | `0x52800020` |
| `RET` | `0xD65F03C0` |
| `NOP` | `0xD503201F` |
| `B .` (spin in place) | `0x14000000` |
| `B target` | `0x14000000 \| ((target - PC) / 4) & 0x03FFFFFF` |

Apply a byte patch **only when the original 4 bytes match the expected pre-image.**

## Traps

- **Do not cover `null_ret` with a NOP.** It only moves the symptom; the cause is
  a function returning null further back.
- **Do not answer `infinite_poll` with 0xFFFFFFFF.** Extra bits get set and the
  firmware takes a wrong branch. Derive the awaited bit instead.
- **Do not solve `console_silent` by printing from the machine.** That is
  self-injection; the provenance gate catches it and voids the milestone.
- **Do not patch out `avb_verify_fail` when the hash is software.** The images are
  genuinely signed, so a failure means our model or our medium is wrong. Patching it
  forfeits the one claim this flow exists to make. **When the hash is a hardware
  engine that is not modelled, that premise is false:** model the engine first; only
  if that is infeasible patch the comparison as a **labelled bypass** (flag F, 4-field
  record with a real 부작용, `/* bypass:<id> */` row, cell `reached_bypassed`); otherwise
  stop (`fixer-secureboot`).
- **Do not name a kernel class while the run is still in a bootloader stage.**
  Check the 위치 column; a misnamed stop point sends a fixer to a stage that is
  not even running yet.
- **A boot that stops with no error message is usually a lock, not a crash.**
  Check CPU onlining and `initcall_debug` before assuming a missing peripheral.
