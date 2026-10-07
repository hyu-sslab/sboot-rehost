# Runbook - MediaTek family

The order in which to work a MediaTek firmware, so that nobody has to prompt each
step: **what is solved now, what comes next, and what after that.** Every agent the
pipeline delegates to gets this file on its `Runbook:` line, because
`profiles/mediatek.yaml` lists it.

The plugin is a **guide**, never device code: it gives the **order**, the
**evidence** to collect and the **measurement** that decides. The values always
come from the target firmware.

- **There are no values here.** Where an address, a log line or a number appears
  it is an **example** from one device (`example`) and **not borrowable** - derive
  yours (honesty rule 3).
- The order comes from one manual run (50 rounds) on one device. **That it holds
  on another MediaTek device is unverified**; until a second device confirms a
  step it is a candidate, not a family fact.
- **This guide has not yet been exercised end to end by the agent loop on real
  firmware.** The automatic path (`start`) has never been run on a MediaTek device
  from the first stage to the last rung, so the order below is a design built from
  that one manual run, not a result the loop has measured (honesty rule 4).
- No war stories, no calendar time, no cost. The record of how a run went is
  `JOURNAL.md`.
- This file gives the **order**. A stop point inside a step is treated from the
  knowledge tables (`knowledge/faults_mediatek.md`, `faults_storage.md`,
  `faults_unified.md`).

---

## 1. How to use it

| # | rule |
|---|---|
| 1 | **Find your position by observation.** On the goal ladder, take the lowest rung that has **not** been reached; start at the step that covers it. The ladder is measured (`observation.json`, `rounds.jsonl`), not remembered. The steps below are numbered in the ladder's order, which is not always the order events happen in time (a stage that reads the next stage from the medium needs the medium before that stage's entry; the kernel lists its partitions before it starts `init`), so the "Stops" of a step say when the cause sits in a neighbouring step |
| 2 | **Classify the stop point from the tables.** `unknown` is a correct answer: do not guess, send it to static-analyzer for re-derivation. When the re-derivation adds no new fact and every owning fixer answers "no change to try", the **script** declares `EXHAUSTED` - not you |
| 3 | **The same fingerprint after changes that did nothing means the layer is wrong.** Suspect a build-layer premise (CPU type, entry PC, load address, CPU creation order) before a fifth symptom patch |
| 4 | **One change per round**, with a rationale and the four-field bypass record. A change that does not move the fingerprint does not count as an attempt |
| 5 | A stop point that is in no table is `unknown`: static-analyzer derives it first. `fixer-general` is reached only after the specialists declined a mechanism that **is** understood, and it then writes `fixer_candidates.md`, which is the input to the next revision of this runbook |
| 6 | **When you ask for a re-derivation, hand over the focus.** (a) the first exception's ELR/FAR and the disassembly range around it; (b) the last stretch of the relevant channel (UART, or the last tens of lines of the memory-dump log); (c) the rows the previous step left in the derived-stop-point table of `STATIC.md`. "Analyse again" with no focus repeats the same facts, reads as "no new facts" and reaches `EXHAUSTED` early (design proposal, untested) |
| 7 | **UART silence is not a stop point.** The kernel of this family may print nothing on the UART while it runs. Look at the memory-dump channel first |
| 8 | **Host lines are not guest evidence.** Lines starting `qemu-system-aarch64:` are our machine talking. They may help to locate a stop point; they never prove that the guest reached anything |
| 9 | **A bypassed verification is not "reached".** `verify_ok` behind a bypass is `reached_bypassed`, labelled, with its side effect written down |

## 2. Common traps

| trap | what prevents it |
|---|---|
| Declaring "not in the package" (a coprocessor image, a firmware blob, `super` - judged absent three times on one device) | **Enumerate the package members** and write the list to `STATIC.md` before saying "absent" |
| Fixing the load base on a weak anchor (an offset error in the base invalidated every bypass derived from it) | A base counts only as the pipeline counts it (S1): AArch32 needs **two independent anchors on one value**; AArch64 needs the one literal anchor that lands exactly where the file's zero padding begins. Pointer containment alone is a candidate, never a base |
| Calling high entropy "encrypted" (the boot and recovery kernels were gzip) | Check compression first |
| Treating a random Oops over freed memory as a driver bug and patching around it | **Random Oops over freed memory means the DMA model first** (`msdc_dma_rerun`) |
| Fixing an image and not checking what came out (a lost write hid behind a disabled verity) | After any image change, `cmp` the product against the source |
| Running the bootloader alone, without the first stage | **Start with the chain that includes the first stage.** Check statically first whether the bootloader reads a structure the first stage hands over |
| Running an exception loop to the time limit | The pipeline's early stop (`max_exceptions`) is **opt-in and off by default**, so a round runs to its timeout unless the caller turned it on. You bound the loop yourself: the round timeout caps the time, and the fingerprint's exception count - compared by order of magnitude (`2.86M` and `2.88M` are one observation) - tells you it is a storm. Classify it in that round from the first exception (`origin`), not from the last FAR, instead of letting later rounds repeat it |
| Believing a medium type from a DTB node (a `ufshci` node exists on an eMMC device) | The bootloader's own log decides (S5) |

## 3. Steps

Each step: **done when** (observation) -> **derive** -> **typical stops and next
action** -> **do not**. The ids follow the ladder: stage entries (S2-S4), then the
medium (S5), the bootloader's verification and jump (S6), the kernel (S7-S9).

### S0. Package inventory (before the ladder)

- **Done when:** `STATIC.md` lists every member of the AP and BL archives, each
  marked used or unused.
- **Derive:** the members (first stage, bootloader, secure OS, power firmware, boot
  parameters, fuse image, boot / recovery / dtbo / vbmeta images, `super`,
  coprocessor firmware), their container header and compression, each stage's
  architecture, the medium type.
- **Stops:** high entropy -> check compression before saying "encrypted".
- **Do not:** write "absent" without the list.

### S1. Stage map

- **Done when:** every stage the map marks runnable (`state: exec`) carries, at stage
  level, `entry_pc`, `arch`, `origin`, `confidence` and `state`, and a `base` object
  whose **`base.load_base`** is the load address (`load_base` is not a stage-level
  field). `confidence` counts the way the pipeline counts it, per ISA:
  - **AArch64: `derived`** - one literal anchor that lands exactly where the file's
    zero padding begins. The pipeline accepts it as confirmed.
  - **AArch32: `cross_checked`** - **two independent anchors** converge on one value.
    One anchor leaves the stage `unconfirmed`.
  - `unconfirmed` (or a pointer-containment-only candidate) is never a confirmed base.

  Stages that start in the container carry `origin: container`; the ones read from the
  medium carry `medium`; the kernel carries `handoff`. A stage no image carries (an EL3
  monitor, a secure OS, the kernel) is not derived by the tool: add it only with evidence
  you can cite (a load address read from a log, a trace PC) and mark its confidence for
  what that evidence is.
- **Stops:** the anchors do not converge -> the stage is `unconfirmed`: **not runnable,
  and not encrypted either** (no skip plan, and not a bypass). Its candidates are in
  `base.candidates`, the anchors rejected with their reasons in `base.rejected_anchors`.
  Write it to `STATIC.md` as "unconfirmed - settled at step N" with what evidence would
  decide it. **When no stage at all is runnable** the pipeline makes **one bounded
  re-derivation** aimed at those anchors; if the stage is still unconfirmed, **Build
  refuses to guess an entry** and the run stops as `BLOCKED_BUILD`. While other stages
  are runnable the unconfirmed one just stays out of the ladder. Exit code 3 of the tool
  is a different case: no entry signature was found (`BLOCKED_ARCH`, a gap in the tool,
  not "no stages"). An unknown container header form -> obtain the parsing evidence first
  and write the verdict, "unconfirmed" included, to `STATIC.md`.
- **Do not:** fix a base on a candidate, and on AArch32 do not fix it on one anchor.

### S2. The first stage prints on the UART (`stage_entry`, first stage)

- **Done when:** the first stage's own UART output appears (a token derived from
  its image, not from this file).
- **Derive:** where the vectors are and how a software-interrupt return is done, the
  stack, and whether a literal-pool indirect jump in the start-up code steps over
  the stage's own initialisation (`ldr pc, [pc, #-4]` shape).
- **Stops:** a Data Abort -> disassemble around the fault address, name the access
  target, treat **one** thing. The first stage's own log is switched off by a
  branch -> model the log-key input as "not pressed".
- **Do not:** guess a value; use an adaptive toggle.

### S3. SoC-common blocks (the first stage's log runs to its end)

- **Done when:** the first stage reaches its own "jump to the next stage" line.
- **Method:** open the blocks the DTB lists as **shadow windows, but record the first
  access to each**; from the `UNMODELLED` and `POLL` lines find the polling loops and
  inject the awaited bit. Blocks that need a state machine (timers, PMIC
  communication, bus protection, power domains) get their FSM from the firmware's
  own polling code.
- **Record every window** (a machine built from the mixed-architecture template). Each
  window the machine opens, each read override and each injected or assumed value is one
  row of the `address windows` table in `STATIC.md` (appended, never overwritten); the
  classifier and the fixers read that table, not the machine source. The columns are
  defined once, in the Conventions block at the top of `templates/machine_mixed_arch.c.tmpl`
  - read them there; they are not repeated here.
- **Stops:** a step that cannot be reached in principle (DRAM calibration) -> report
  its result as success but record it as a **value** with the side effect "the
  result of a fake input".
- **Do not:** jump the polling loop with a code patch. The model and the value come
  first.
- **The machine's own lines.** A machine built from the mixed-arch template reports on
  stderr; the lines land in `07_logs/host_<N>.txt` (a wall-clock epoch may precede each
  one, then `qemu-system-*: info: rehost: `). The pipeline writes that file **whenever a round
  produced host lines** - with or without a memory-dump plan - and
  `observation.json` `host_log` names its path (`null` when the round had none). They are
  the machine speaking - **never guest evidence** - and they are where S3 reads its facts:
  - `ACCESSED|UNMODELLED read 0x<addr> window=<name>` / `... write 0x<addr> = 0x<val> window=<name>`
    - the first access to a 4 KiB page of a shadow window (`ACCESSED`) or to an address no
      model owns (`UNMODELLED`); once per page
  - `POLL 0x<addr> = 0x<val>` - the same address read many times in a row (a polling loop)
  - `patch applied <id> group=<n> @0x<addr> ...`, `PATCH-REFUSED <id> group=<n>: <reason>`
    and the exit report `patch ledger: <id> applied|NOT applied: <reason>` - which bypass
    rows took effect (a refused row is a bypass that did not happen)
  - `REHOST-RX s= e= p= q=` - receive-path counters (bytes the firmware read, empty reads,
    status polls, queued); the harness reads them, you read them to tell "the firmware never
    looked at its input" from "it sits waiting for it". **This line is printed without the
    `rehost: ` prefix** (`qemu-system-*: info: REHOST-RX ...`), so a search for
    `info: rehost: REHOST-RX` finds nothing
  - `warm reset to AArch64 requested (...)` - the handoff between the 32-bit and 64-bit CPU

### S4. Chain handoff (first stage -> EL3 monitor -> bootloader)

- **Done when:** the monitor's entry PC is **seen in the trace** and the bootloader
  starts (each stage's entry rung).
- **Derive:** the register the first stage writes the monitor's entry to and the value,
  how the core switch is requested and where the spin is, the bootloader's load
  address, the argument buffers.
- **Stops:**
  - a later stage never starts, and its `origin` is `medium` -> the stage before it reads
    it from the boot medium: look at S5's `medium_up` evidence first (a missing medium
    model stops the chain here, before any stage entry the ladder lists).
  - the monitor stops on an EL3 exception -> disassemble ELR and name the access
    (RAS, an implementation-defined register).
  - the secure OS' first execution stops in a core-table search -> check which MPIDR
    it requires.
  - **no kernel tick later** -> the interrupt controller's redistributor frame and
    the CPU creation order (`gic_redistributor_order`, build layer).
- **Order for an implementation-defined register stop** (example, one device:
  RAS error records and a CPU implementation-defined block): (1) name the target from
  ELR; (2) check whether the value read is used by a later branch; (3) if it is not,
  read-as-zero / write-ignored; if it is, derive the value and model it.
- **Do not:** conclude "did not enter" because the UART shows no monitor output.
  Confirm with the trace PC.

### S5. Boot medium (`medium_up`, `partitions`)

- **Done when:** the medium-init line (`medium_up`) and the bootloader's own
  partition-table recognition line (`partitions`) are on the UART (tokens derived from
  the images that print them). On a chain whose later stages are read from the medium
  the medium-init line belongs to the stage that does the reading - on the one device
  studied the first stage, before the bootloader's own entry - while the partition
  line is the bootloader's.
- **Derive:** the **medium type, from the bootloader's log first**, then the DTB
  controller node and the table the bootloader reads. Which partitions it looks up
  **by name**. Where it expects vendor structures (a partition information table, a
  boot parameter block) and what it compares.
- **Stops:** the bootloader falls to download mode -> see `download_mode_entry`;
  there are three candidate causes, so **find in the log which branch fired**, then
  treat one. The bootloader's SD probe commands answered by the eMMC model -> the SD
  path (`emmc_sd_probe_answered`): make them time out.
- **Do not:** call the medium UFS because a `ufshci` node exists.

### S6. The bootloader (`verify_ok`, `kernel_entry`)

- **Done when:** the bootloader's own line right before the kernel jump appears (a
  token derived from its image).
- **Derive:** what the bootloader's boot decision reads (keys, charger, battery,
  parameter partition) and **how it verifies** - whether the hash is software or a
  hardware engine. Record the answer as the `hash_engine` row in `STATIC.md` (`hardware`
  or `software`, evidence with a function address or SMC id; no row while undecided); only
  a derived `hardware` row opens the order below.
- **Stops:** verification fails. **If the hash is a hardware engine** (reached by SMC
  through the monitor), take the order from the bypass policy: (a) model the engine
  so the digests are really computed; (b) a comparison patch with a label (mark F)
  when (a) does not work out; (c) stop, which is the strict option rather than the
  default. If the boot mode is wrong -> check the input values (ADC and the like).
- **A bypassed `verify_ok` is `reached_bypassed`.** Run the negative test (corrupt
  one byte of vbmeta, run, a failure must appear). A stubbed comparison always says
  "equal", so **a corrupted image that still passes is the evidence of the forgery.**
- **Do not:** patch verification silently and report `verify_ok` as plain reached.

### S7. Kernel jump and liveness (`kernel_alive`)

- **Done when:** the kernel's banner (or an alternative token carrying a kernel
  timestamp and a task prefix) is in the **memory-dump** log (the round's merged
  kernel log, `07_logs/kernel_<N>.log`; `observation.json` `kernel_log` names it).
- **Derive:** how the kernel is jumped to (the argument that carries the entry), what
  the monitor waits for just before it, and the location and size of the kernel log
  buffer (the bootloader's reserved-memory table, or the `ramoops.*` words of the
  command line) -> write `memdump_plan.json` and the evidence to `STATIC.md`. The plan
  needs the base and the size; if no source gives the console (ring) size the plan
  carries `0`, which the scan reads as "assume the whole region is the ring" (a longer
  interval between dumps) - say in `STATIC.md` that it is unconfirmed.
- **Stops:** nothing after the jump -> **UART silence is not evidence of a stop.**
  Look at the dump. If the dump is empty as well and reset/watchdog block accesses are
  visible, classify it as the **hypothesis** `guest_reset_after_jump`.
- **Next action for that hypothesis:** (1) record when the reset/watchdog block access
  appears after the jump (host lines; `guest_reset_signal` in `observation.json`);
  (2) pin the guest PC that performs it with a narrow `-d exec` trace; (3) disassemble
  the function and tell the call path apart (panic handling, watchdog service, a PSCI
  reset call); (4) once one is established, classify by that cause. **If step 1 finds
  no access, drop the hypothesis.** Do not name a cause beforehand - the hypothesis
  itself is unverified.
- **The kernel channel's line format.** A memory-dump line counts as a running kernel only
  with a kernel timestamp and the task that printed it (`[pid:comm]`); that form was
  confirmed on one kernel only. A kernel whose ring lacks it needs
  `<workdir>/kernel_task_regex.txt` - write one regular expression (the subset ERE and
  Python `re` share, first capture group = the task name) on its first non-empty line. It is
  **searched, not anchored**, in the first 64 characters of the line's text (the part after
  the timestamp), so a hit anywhere in that window counts: add `^` yourself when the task
  must be the first thing on the line. The round script hands it to the scan. Say why in
  `STATIC.md`. Do not set an environment variable for it.
- **Do not:** stop because the kernel is quiet; set the dump interval longer than the
  ring can hold.

### S8. Kernel to init (`userspace`)

- **Done when:** the kernel's own line that the first-stage `init` started is in the
  memory-dump log (a token derived from the kernel image).
- **Order note.** The ladder lists `userspace` before `partitions_up`, but the kernel
  lists its partitions **before** it starts `init` (on the one device studied the
  enumeration line came well before the `init` line). So a missing `userspace` rung may
  well be a kernel-storage stop: read the end of the kernel log first; if the mmc block
  device never produced its partitions, treat it from the storage list below.
- **Stops -> suspect the model first:**
  - capacity 0 B -> the kernel driver's DMA address width (`emmc_36bit_addr`)
  - random Oops, corrupted freed memory -> DMA re-execution, length ignored
    (`msdc_dma_rerun`, `msdc_basic_len`)
  - part of a file reads as zero -> a lost write (`msdc_write_lost`)
  - a stop for lack of hardware (coprocessor IPI, thermal sensor, panel, power-domain
    ACK) -> the order below.
- **Order for a stop caused by absent hardware:** (1) classify, from the stalled
  function's symbol, which hardware dependence it is. (2) **Check the package
  inventory** for the coprocessor or firmware image: on one device it was there and
  was judged absent. (3) If it is there, try to load it; if it is not, or cannot run,
  handle it with a model or a value. (4) Only then patch, and record it.
- **Patch rules:** only when the original bytes match; one row per patch in the
  ledger; when the cause is unexplained, mark the ledger meta line with `표지=X` so a
  later round can re-verify it.
- **Do not:** patch a symptom whose cause is a model you wrote.

### S9. Partitions and super (`partitions_up`, `super_mounted`) - the end of F3

- **Done when:** the kernel's partition enumeration (`mmcblk\d+: p\d+` shape) appears in
  the kernel log (`partitions_up`) and, for a firmware that ships `super`
  (`has_super`), the first-stage `init` has created the logical partitions from `super`
  and switched root (`super_mounted`).
- **Stops:** `userspace` was reached but `partitions_up` is not observed -> the line may
  sit in a stretch the ring overwrote between two dumps (read the merge's gap report
  before calling it a stop); if it really is absent, take S8's storage list. A model
  fitted to one driver and broken under the other fails here: the same controller is
  driven twice (the bootloader's driver, then the kernel's), and a fix that helps one
  side and breaks the other is wrong.
- **Out of scope:** everything after that (second-stage init, waiting for TEE
  properties, service start, `sys.boot_completed`). An image change (I) is
  considered only at F3, with a label; F2 runs do not modify firmware bytes.

## 4. Stop and resume

- A stop is a handover, not an abandonment. `RESUME.md` records where the run reached
  (by rung), the last fingerprint, the changes tried and their effects, what is still
  untried, and the log paths of the last round (console, trace, and the round's
  `kernel_log` and `host_log` where `observation.json` names them). **It does not record a
  runbook step**: the step is derived, by rule 1, from the rung list.
- On resume, find the position again by rule 1. No additional prompt is needed.
- User input is recorded verbatim, not summarised.

## 5. Relation to the knowledge tables

| this runbook | the knowledge tables (`faults_*.md`) |
|---|---|
| **order**: which step now, which next | **treatment**: the cause of this stop point and how to fix it |
| "what to suspect first" per step | a signature and an owning fixer per stop point |

A new stop point is one row in the table. A new piece of order is one paragraph
here. Connecting a family's table and runbook to the agents is **one line in the
profile** (`knowledge:` and `runbook:`).
