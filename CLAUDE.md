# sboot-rehost - always-loaded context

Plugin that runs mobile-device firmware on QEMU **as the original binaries**.
These rules apply to every round, derivation and verification.

## Language

LLM-read files are concise English: this file, skills except `status`, `agents/`, `knowledge/`, prompts in `workflows/pipeline.js`.
Human-read text is Korean: reports, progress, documents agents write, README, CHANGELOG, the `status` skill.
All text addressed to the user (progress, reports, questions, summaries, documents) is natural, formal Korean. Do not coin terms: use 정지점, 회차, 우회, 마일스톤, 도출; keep standard English terms such as fastboot, UART, MemoryRegion untranslated.
Report templates and sample output shown to the user stay Korean verbatim.
Scripts, verifier and tests match the Korean literals below byte for byte. Never translate or reword them.

| Korean literals that scripts and tests match | Matched by |
|---|---|
| `대상` · `이유` · `방법` · `부작용` · `알려진 부작용` (bypass-ledger fields), `메타` (meta line) | `check_change.sh`, `verify_gates.py`, `verify.py`, `revert_change.sh` |
| `종류` · `표지` · `출처` · `도출` · `근거` (meta-line keys) | `verify_gates.py` (called by `check_change.sh`) |
| `(기록 없음)` (empty-record marker) | `check_change.sh`, `verify_gates.py`, `verify.py`, `pipeline.js` |
| `## 도출된 정지점` (heading), `시그니처` (header cell) | `derived_facts.py`, `static_rotate.py`, `pipeline.js` |
| `미확정` (underived-cell marker) | `verify_gates.py`, `stage_map.py`, `pipeline.js` |
| `주소 창` (address-window table) | `verify_gates.py`, `static_rotate.py`, `verify.py`, `pipeline.js` |
| `VERIFIED (출처 검증 통과)` · `검증 우회 N건` · `verify_ok: reached_bypassed` (verdict phrase; failing form `UNVERIFIED (출처 검증 실패)`) | `verify_gates.py`, `verify.py`, `pipeline.js` |
| `F2 (verify_ok 우회 N건)` (grade label) | `pipeline.js` |
| `배너 미관측` (fallback-token note) | `pipeline.js` |

---

## 1. What it does

Load the bootloader container **once**; run from the first stage until the kernel mounts rootfs as **one continuous
run**. Firmware code itself loads each later stage.

```
load container → stage0 → stage1 → … → bootloader → kernel → rootfs
                   ↑                        │
             reset PC (derived)      bootloader reads the kernel from the medium and loads it
```

**Never pass `-kernel Image`, `-dtb` or `-initrd` to QEMU**: that skips the boot, indistinguishable from prior work
that runs only a kernel image.

A stage that cannot run (encrypted or absent from the package) is skipped by **re-pointing entry to the next runnable
stage**; record the skip in the bypass record.

---

## 2. Terms

| Term | Meaning |
|---|---|
| **Stage** | One boot-chain step (BL1 · BL2 · bootloader …); count and names derived into `stage_map.json` |
| **Round** | 1 run + analysis + 1 change (`run N`) |
| **Stop point** | Where the run cannot advance, and why |
| **Run fingerprint** | Stop-point identifier: first exception's ESR/FAR/ELR, milestone, distinct console line count, exception-count magnitude |
| **Goal ladder** | Ordered goals (e.g. `bl1_entry → bl2_entry → shell → …`) |
| **Bypass** | Anything made different from real hardware; all recorded |
| **Layer** | What a round can fix (loop) vs. a machine-generation premise (build) |
| **Family** | SoC product line (exynos · mediatek …). `start` detects it and picks the family kit (profile · runbook · knowledge table); the kit holds no values |
| **Rung status** | `reached` · `reached_bypassed` · `not_reached` |
| **Verification bypass** | Bypass (mark F) that changes the firmware's verification result; makes that rung `reached_bypassed` |

---

## 3. Goal ladder and grades

The goal ladder is **not fixed**: `stage_map.json` counts runnable stages, one rung each, then the common tail (stage
count varies per firmware).

```
stage_entry × N  →  [<surface>]  →  medium_up  →  partitions  →  verify_ok
                 →  kernel_entry  →  kernel_alive  →  userspace  →  rootfs
```

`[<surface>]` is an **optional rung** (see "Surface").

| Grade | Scope | Meaning |
|---|---|---|
| **F1** | all stage entries + surface (if any) | bootloader chain runs |
| **F2** | F1 + `medium_up` · `partitions` · `verify_ok` · `kernel_entry` · **`kernel_alive`** | kernel runs |
| **F3** | F2 + `userspace` · `partitions_up` (+ `super_mounted`) | completes through rootfs mount |

- static-analyzer derives each rung's observed string into `milestone_tokens.txt` (no vendor strings in code):
  `<rung><TAB><token>[<TAB><channel>]`, channel `uart` (default) or `memdump`; old two-column files still read.
- No `super.img`: omit `super_mounted` (`has_super`).
- **`kernel_entry` is not `kernel_alive`.** `kernel_entry`: bootloader printed **its own kernel-jump line** (derived per
  bootloader: the `kernel_entry` token). `kernel_alive`: a **line only the kernel can emit is confirmed on any
  observation channel**. Counting the jump alone reports a run complete though the kernel never ran.
  - Priority: ① kernel banner (`Linux version`) ② fallback token (e.g. kernel memory-free message); a fallback token
    records **"배너 미관측"**.
  - `uart`: token string match. **`memdump` is never judged by one string**: needs 2+ lines with kernel timestamp and
    task prefix (rule 6).
- **Quiet kernel: check the command line first.** Bootloader picks `console=ram` → a booted kernel prints nothing on
  serial; silence is not failure. static-analyzer derives candidates into `cmdline_plan.json`; `build_lu.py` writes the
  UART combination into the **partition the plan names** (`partition`; the name if `source` is one partition name; or
  manifest `cmdline_partition`): the bootloader's own path, not a bypass. Command line not from a partition: nothing
  written, `warning_cmdline`. No named partition: the fallback of writing to an existing partition `param` exists **only
  with `build_lu.py --family exynos`** (name is a guess: `warning_cmdline_target`); other families have no such fallback or
  vendor default name. Pipeline always passes `--family`; omitting it = old behavior (Exynos default) +
  `warning_family`.
  Observed once: UART requested yet silent (one MediaTek device, cause **unconfirmed**) → judge by `memdump`.
- **F1 needs no medium model**: first stage reads blocks via a function pointer an earlier stage left. Confirm F1, then
  F2.

### Surface

Bootloader interactive surface (UART shell or fastboot/USB) is a **derived value**. A command table in the binary is
unreachable if the dispatcher never references it.

**The surface rung is optional.** Derived `none` → drop it from the ladder, record `autoboot` (some bootloaders reach
the kernel without input). `BLOCKED_NO_INPUT_PATH` is not raised statically: **only when a round was observed stopped
waiting for input and no input path exists** (§10).

**The surface rung's observed string and interrupt pattern are also derived.** Shell surface with missing or empty
`milestone_tokens.txt`: no banner decides the rung, not counted as reached, `surface_not_credited` in `fingerprint.json`
gives the reason (`run_full.sh` has no built-in banner). No derived `input_plan.json` (both `bytes` and `count`):
`uart_harness.py` sends no interrupt pattern, records `source: "absent"`; there is no default repeat count.

### Rung status and reached statements

| Rung status | Meaning |
|---|---|
| `reached` | observed as execution evidence |
| `reached_bypassed` | observed, but the rung's verdict depends on a **verification bypass** (§7, §11) |
| `not_reached` | not observed; never fill an unobserved rung as reached |

- Grade reports use rung status as is: `verify_ok` `reached_bypassed` → **"F2 (verify_ok 우회 N건)"**, not "F2 도달".
  The grade does not drop; the reach is stated honestly.
- `reached_goals` holds **observed rungs only**; never fill a lower rung because a higher one was reached (rule 5).
- Beyond F3 (service start, `sys.boot_completed`) is undefined.

### Observation channels

| Channel | Content | Guest evidence |
|---|---|---|
| `uart` | guest UART TX (`07_logs/console_N.txt`) | **yes** |
| `memdump` | guest-RAM kernel log ring (pstore etc.) read by the host, rebuilt as `07_logs/kernel_N.log` | **yes**: host read it; machine must not write it |
| `host` | machine's `info_report` and other QEMU host diagnostics (`07_logs/host_N.txt`). Always used when the round emitted host lines, regardless of plan | **no**: we emitted it |
| `trace` | `-d` trace filter result (stage entry PCs) | entry PC confirmation only |

- **Guest console = `uart` + `memdump`.** Mixed-in host lines make bypass-description strings match machine source and
  trigger a false source-negative accusation.
- `memdump` is on only with `memdump_plan.json` (region location and size). Derive the location from the bootloader
  log's reserved-memory table or the kernel command line; basis in `STATIC.md`. No plan: channel off. Optional keys
  `reset_patterns`, `reset_window_s` (guest reset signal). No source for ring capacity (`console_size`) → 0, scan treats
  the whole region as the ring.
- Usable plan: `run_full.sh` exports the region to QEMU as `REHOST_MEMDUMP_REGION=<base>:<size>` (hex, `0x` prefix), a
  write protection so the machine does not write into the host-read region. No plan, or an unusable one: variable
  **not set**, and a value left in the caller's environment is also cleared.
- Task prefix (`[pid:comm]`) confirmed on one kernel only. Another format: static-analyzer writes
  `kernel_task_regex.txt` in the workdir (first non-empty line = one regex); `run_full.sh` passes it to the scan. Env
  var `KERNEL_TASK_REGEX` wins. Invalid regex: reported, default used.
- `observation.json` carries `kernel_log` and `host_log` (paths of `07_logs/kernel_N.log` and `07_logs/host_N.txt`),
  `null` if absent. Host file absent only when the channel was off and no lines appeared (channel on: empty file
  remains). Never guess a path.
- A silent stop differs from a **guest reset right after the jump**: host-line reset or watchdog access seen right
  after the jump raises `guest_reset_signal` (candidate stop point `guest_reset_after_jump`; cause an unconfirmed
  hypothesis).

### Families and kits

`start` detects the family **when it receives the firmware** (container magic, image names, package parts). `init`
does not know the firmware, so it does not detect. Detection picks search hints and the kit; **per-stage `arch` is
derived, not detected.**

| Kit | Location |
|---|---|
| Profile (where to look) | `profiles/<family>.yaml` |
| Runbook (current step, next step) | `knowledge/runbook_<family>.md` |
| Family knowledge table (stop point → cause → remedy) | `knowledge/faults_<family>.md` |
| Reference example (**never borrow values**) | `examples/<device>/` |

- Profile flat keys `knowledge:` · `runbook:` point at the kit. `scripts/family_kit.py` reads them by regex; the
  pipeline reads kits only through it, adding `Family knowledge:` and `Runbook:` lines to classifier, fixer,
  static-analyzer and supervisor delegation prompts.
- Record the detection and its **basis** in `INPUT.md`, `STATIC.md` and `journal.sh decision`. No basis: `generic`.
- **Kits contain no values** (addresses · offsets · register values · bypass numbers). Values are derived from the
  target firmware and live only in the workspace (rule 3). Example values are not borrowed.
- MediaTek kit = general candidate derived from **one SM-A136U**; generality on other SoCs unconfirmed. Current status
  and open items: the latest `CHANGELOG.md` entry and README "현재 상태" are canonical.

---

## 4. Components

> Scripts measure; agents interpret and control; a stop decision's input is an observed fact.

### Agents (`agents/`)

| Name | Role | Source edit |
|---|---|---|
| `static-analyzer` | derives facts from binaries and assets; no basis: "미확정" | no (analysis docs only) |
| `supervisor` | routing, stop, layer judgement, bypass withdrawal | no |
| `fault-classifier` | names the stop point from logs, assigns an owner; `unknown` if unsure | no |
| `fixer-memory` `fixer-el3` `fixer-bootflow` `fixer-secureboot` `fixer-storage` `fixer-kernel` | fix the owned stop point directly (1 per round) | **yes** |
| `fixer-general` | only when no owner exists. Unlimited scope: one coherent mechanism may span several places and files and is handled in one round | **yes** |
| `verifier` | second re-verification of script measurements | no (verdict docs only) |

**Only fixers may edit.** If the classifier also fixed, it would name a nonexistent cause to create something to fix.

`fixer-general` is reached only after every specialist declined. Unlimited scope means "nothing to try" rarely comes
back, so `stop_conditions.py` **does not count a change that failed to move the fingerprint as an attempt**; that change
must also pass `check_change.sh` to count (violation: reverted, recorded `reverted`). The **scope differs**: ownerless
stop points often span what specialists split between them, so **one coherent mechanism** may be fixed across several
places and files in one round and counts as one change. The pipeline gives `CHANGE_SCOPE=general` to `fixer-general`
only; in that scope `check_change.sh` **skips only the single-source-file check and the `MAX_HUNKS` check.** All other
checks (no change · bypass record 4 fields · usable record · patch-table row correspondence · the `hash_engine` row for
a mark `F` hash bypass) bind as for specialists: a wider fixing scope does not widen what may go unrecorded. A machine
cannot count whether the change is really one mechanism; `agents/fixer-general.md` rule 1 only requires a one-sentence
explanation.

Rules shared by all fixers (one change per round, what counts as one differs per fixer · no speculative stubs · bypass
record · open question → `no_new_change=true` + `rationale`) live in one constant `FIXER_RULES` in
`workflows/pipeline.js`, appended to every fixer prompt (specialists and `fixer-general`). `agents/fixer-*.md` hold only
that fixer's own content. A declining fixer's `rationale` is the focus of the next static-analyzer escalation.

### Scripts (`scripts/`, `workflows/`)

| Name | Role |
|---|---|
| `workflows/pipeline.js` | Flow control; enforces that agents cannot overturn an observed-fact stop |
| `purge_cache.sh` | **Force-deletes old version caches (`init` step 1)** |
| `clean_env.sh` | `init` layered cleanup (L1~L4; reports path and size deleted). `--status` only compares the environment manifest |
| `qemu_tree.sh` | Resets QEMU tree to pristine (`reset` · `status` · `record`); used at Build start |
| `check_version.sh` | **Plugin version check (first gate)** |
| `check_env.sh` | Runtime preflight + environment manifest comparison |
| `family_kit.py` | Reads profile `knowledge:` · `runbook:`, lists the family kit as JSON (no PyYAML) |
| `stage_map.py` | Derives stage map (entropy · entry stub · strings · load address). Schema v2: per stage `arch` · `origin` · `entry_pc` · `confidence`. arm32: container header · GFH · two anchors. Once per image; `--merge` combines in chain order. `--detect-arch <path>` prints one image's architecture as a JSON line (`arch` · `entry_signature` · `basis` · `confidence`); no signature → `unknown` is the honest answer |
| `detect_medium.py` | Boot medium (eMMC · UFS) from bootloader log, then DTB; `unknown` if undecided |
| `extract_boot_assets.sh` | Extracts kernel boot assets (`Image` · DTB · initrd · super) from `02_unpacked/boot.img` into `fw/`. Standard unpack, not derivation; **pipeline calls it before Analyze** (F2+, non-interactive, idempotent; exit codes 0~4 in script header) |
| `carve_disasm.py` | capstone wrapper; `carve_check` string/size criteria from `--family` (no criteria and no container-header basis → `is_full: null`, not false; omitted → old per-ISA criteria) |
| `build_lu.py` | Synthesizes boot medium (GPT + partitions). Per entry `kind` · `lba` · `vendor`; output `lu_provenance.json`. `--family` gates vendor defaults and the `param` fallback (§3). `warning_medium` if no basis for medium type (UFS default = backward compatibility, not silent) |
| `run_round.sh` | One round → one `observation.json` |
| `run_full.sh` | QEMU run → fingerprint · output-source check · run-failure decision. With a memdump plan: exports `REHOST_MEMDUMP_REGION`, passes `kernel_task_regex.txt`; writes `host_N.txt` every round (§3). Shell surface without token file: `surface_not_credited`, no built-in banner |
| `uart_harness.py` | Injects console input from outside QEMU. No derived `input_plan.json` → no interrupt pattern, `source: "absent"`. `--surface none` → no input; emits `waiting_for_input` when console quiet while receive polling keeps growing |
| `memdump_observe.py` | Host reads guest-RAM kernel log, merges it (`memdump` channel): region derivation · loss detection · reset signal. Helpers `region` (plan → `<base>:<size>`) · `task-regex` (format check) |
| `trace_filter.py` | Streams trace, keeps what's needed (10 GB → few MB). Entry PCs count "seen" and "executed as instruction line" separately |
| `fingerprint_lib.sh` | First-exception extraction · distinct console lines · run-failure decision |
| `sync_machine.sh` | Syncs workspace sources into QEMU tree; sources gone from workspace leave `qemu_targets.txt` |
| `patch_qemu_core.py` | QEMU core patch (idempotent), per-family set (`--family`); logs touched files in the tree ledger |
| `check_change.sh` | Checks one change: diff + bypass-record 4 fields · side effect · table row correspondence + `hash_engine` row for a mark `F` hash bypass (§11). Specialist: one source file within `MAX_HUNKS` (default 3) hunks. `CHANGE_SCOPE=general` (`fixer-general` only) skips just those two (§4) |
| `check_release.sh` | Blocks a release without version bump (`pre-push` hook calls it) |
| `install_git_hooks.sh` | Enables the `pre-push` release check |
| `revert_change.sh` | Reverse-patches only that round's change for a refuted bypass |
| `stop_conditions.py` | Computes stop conditions |
| `verify.py` | Measures 3 gates + reference metrics + verification-bypass report (`hash_engine` row presence, address-window table). Gate logic in `verify_gates.py` |
| `verify_prep.py` | Prepares verification evidence (decompress · split big files · normalize console) |
| `make_negative_image.py` | Medium copy for the negative test (1 vbmeta bit corrupted); original untouched |
| `record.py` · `journal.sh` | Record measurements and history |
| `make_resume.py` | Handoff document on a stop |
| `analyze_run.py` | Time · cost · stall intervals · resolution history analysis |
| `wsl_bridge.sh` | Switches to WSL when the shell is Windows |

### Data

`fixers/registry.yaml` (stop point → owner) · `knowledge/faults_unified.md` (stop-point taxonomy) ·
`knowledge/faults_<family>.md` · `knowledge/runbook_<family>.md` (family knowledge table · runbook) · `profiles/*.yaml`
(SoC search hints: **where to look, not values**; keys `knowledge:` · `runbook:` point at the family kit) ·
`env_manifest.json` (required environment: `env_revision` · QEMU version · minimum pip versions).

**A new stop point is one taxonomy row.** A family table and runbook link through the profile's `knowledge:` ·
`runbook:` line, so prompts do not change. Widening an existing owner fixer's `handles`: edit `registry.yaml` only.

**A new fixer is not one file plus a few registration lines.** `KNOWN_FIXERS` in `workflows/pipeline.js` and the matching
assertion in `tests/smoke.sh` are hardcoded besides `registry.yaml` and must change together. First check whether an
existing fixer's `handles` can cover it. Shared rules are already in `FIXER_RULES`: a new fixer file holds only that
fixer's own content, copies nothing.

---

## 5. Flow

```
start → [version check] → [env check] → [unpack · sparse] → [detect family · pick kit]
        → [INPUT.md slot table · --detect-arch of the first container · .active]
   ↓
[Analyze] settle arch (input or derive) → load kernel assets (F2 and above, by the pipeline)
        → static-analyzer derivation
   ↓
[Build] restore QEMU tree → family core patch + generate machine source + synthesize medium + ninja
        → (stop if the build fails)
   ↓
┌── Round loop (per goal rung) ─────────────────────────────────┐
│ run_round.sh: run → fingerprint → source check → stop         │
│                conditions → observation.json                  │
│ supervisor: routing and layer judgement                       │
│   ├ goal reached → next rung                                  │
│   ├ structurally unreachable → stop                           │
│   ├ build-layer problem → regenerate the machine              │
│   ├ bypass refuted → revert only that round's change          │
│   └ fault-classifier → owner fixer makes 1 change             │
│        → check_change → sync_machine → ninja                  │
└───────────────────────────────────────────────────────────────┘
   ↓
verify.py 3 gates + verification-bypass report → verifier re-verification → VERIFIED or UNVERIFIED → reproduction kit
```

---

## 6. A derivation counts only if it is in the record

Per-firmware record: `STATIC.md`; static-analyzer **appends, never overwrites**.

```
pre-derivation → STATIC.md → Build reads it and generates the machine
re-derivation  → one row in the "## 도출된 정지점" table of STATIC.md
               → fault-classifier matches → fixer applies that row's remedy
```

**A fact that lives only in a response reaches no one**: classifier and fixers read the table, not an agent's answer.
Mechanism unconfirmed: write no row; a row without a basis sends a fixer the wrong way.

---

## 7. Honesty rules

| # | Rule | Enforced by |
|---|---|---|
| 1 | **No speculative stubs.** Adaptive toggles above all (e.g. "change the value after 12 reads"): they send the firmware down the wrong branch and end in an accidental pass | `fault-classifier` says `unknown` → re-derive |
| 2 | **A bypass is labelled a bypass.** Never describe a firmware patch as a normal model | `check_change.sh` |
| 3 | **Every address, structure and byte sequence is derived by analysis**: disassembly (capstone) or execution observation (`qemu -d exec,int,unimp,guest_errors`) | `static-analyzer` |
| 4 | **Never label a hardcode as analysis.** Mark the unconfirmed "미확정 — N단계에서 확정" | document review |
| 5 | **A point not reached is recorded as not reached** | `verify.py` |
| 6 | **Success is judged by execution evidence only**: trace · console · memory capture. A string regex alone is not accepted | `verify.py` + verifier |
| 7 | **The machine never creates input itself.** Strings we printed do not count as reached. The machine's host diagnostics (`info_report` etc., stderr) are not guest evidence either | `run_full.sh` output-source verification (every round) |

### Bypass record

Every bypass goes in `06_machine/bypasses.md` with **four fields**.

| Field | Content |
|---|---|
| `대상` | what was changed |
| `이유` | why it cannot behave as original in this environment |
| `방법` | how it was changed (address and encoding included) |
| `부작용` | what is no longer verified |

**`부작용` is the first thing consulted when later runs stall**; filled as a formality, it is useless when needed.
**A `부작용` that is empty or `(기록 없음)` is invalid and is rejected.**

- **1 bypass = 1 record.** Never group numbers. Put `#<id>` in the heading.
- Mark each patch-table row in machine source `/* bypass:<id> */`: rows and records correspond **one to one**; a row
  without a record, or a record without a row, is rejected.
- One optional line: `- 메타: 종류=P; 표지=F,L; 출처=A; 도출=semi` (add `근거=` free text if needed).

| Meta key | Values |
|---|---|
| `종류` (kind) | `M` model · `V` value · `S` security stub · `P` code/data patch · `I` image modification · `H` host circumstance |
| `표지` (mark) | `F` verification forged or neutralised · `K` kernel text patch · `L` LK text patch · `R` preloader code patch · `X` insufficient basis or unverified cause |
| `출처` (source) | `A` family-general · `B` SoC-specific · `C` this firmware only · `D` vendor-specific |
| `도출` (derivation) | `auto` · `semi` · `manual` · `none` · `n/a` |

`check_change.sh` checks the records **newly written or edited that round** (rejecting old records would reject every
round). A bypass with mark `F` is a **verification bypass**, reported under §11.

### False passes: more dangerous than a technical failure

| Trick | Why it looks like a pass | Why it is false |
|---|---|---|
| Adaptive toggle | the driver visibly advances | wrong branch; does not reproduce on other firmware (rule 1) |
| Machine prints a prompt string | the prompt is in the log | we printed it (rule 7) |
| Machine fills its own receive buffer | the shell responds | it talked to itself |
| Trampoline force-calls a handler | command output appears | the input → dispatcher path never held |

---

## 8. Run fingerprint

```
fingerprint = (first exception's ESR/FAR/ELR, milestone, console bytes, distinct console lines, exception-count magnitude)
              (+ kernel channel on: last kernel timestamp, distinct kernel lines)
```

A handler faulting again while saving its own context nests aborts: FAR rises 0x20 per iteration until the timeout cuts
it. So the trace's **last FAR is the recursion's position, not the cause**, and differs per round for the same stop
point. As fingerprint it makes the classifier name a nonexistent stop point and keeps the stall count at 0, so
exhaustion, re-derivation and layer review never fire.

- Cause: `origin` in `fingerprint.json` (full block in `07_logs/origin_N.txt`)
- Last FAR/ELR kept separately as `far`/`elr`: a record, not a diagnostic input
- Exception count compared by **order of magnitude** (2.86M and 2.88M are the same observation)

### Boot depth

With a one-rung goal, execution can advance while the milestone stays empty. `best_progress.uniq` (**distinct console
line count**) measures that depth; a retry loop prints hundreds of KB from one line, so bytes do not indicate progress.

`timeout_bound=true` = **running longer produced more console**. The limit is run time, not the firmware: assign no
fixer. Kernel-channel distinct line count follows the same rule.

**Stall is computed per channel.** UART fixed but kernel log advancing (last kernel timestamp or distinct line count up
about 10% or more over the previous best) is not a stall. Jitter near the best is not progress (`stop_conditions.py`,
`fp_klast` · `fp_kuniq`).

### A round that did not run is not a round

If QEMU cannot start, the fingerprint settles at all zeros, reads as a stall and becomes `EXHAUSTED` (structurally
unreachable) for a firmware that never ran. `run_full.sh` checks exit code and 0-byte trace/console to set `run_failed`;
the pipeline stops that round with `BLOCKED_ENV`.

---

## 9. Layers: what a round cannot fix

A fixer fixes **one place in existing machine source** (`fixer-general`: several places spanned by one mechanism, §4).
It cannot fix **what the machine was generated assuming**.

| Layer | Examples | Fixed by |
|---|---|---|
| **loop** | unmapped MemoryRegion, unhandled SMC id, polling that never ends, wrong branch | fixer (1 per round) |
| **build** | `has_el3`, entry EL, entry PC, stage load address, memory skeleton, CPU type, CPU creation order (GIC CPU numbers follow creation order), skip re-pointing | **machine regeneration** |

With a wrong premise a fixer only treats symptoms: NOPping an instruction that corrupts the vector base just leaves the
next symptom if the cause is entering the image at the wrong EL.

Ineffective changes (changed, fingerprint unchanged; a `fixer-general` change the check reverted counts too) past the
threshold raise `needs_layer_review`: before routing, the supervisor reads machine source and `stage_map.json` to judge
the layer.

**A stage decides its own entry EL.** The `vbar_el*` its entry stub writes is the EL it expects. Any default silently
enters at the wrong EL.

---

## 10. Stop conditions

**Round count and elapsed time are not stop reasons.** Continue while means to try remain.

| Code | Condition | Detected by |
|---|---|---|
| `BLOCKED_VERSION` | loaded plugin is not the latest | `check_version.sh` (first gate) |
| `BLOCKED_ENV` | runtime environment lacking (WSL·QEMU·ninja·capstone) or environment manifest mismatch. In `init`: apt install needed but sudo asks for a password | `check_env.sh` · `setup_env.sh` exit code 7 |
| `BLOCKED_ARCH` | Entry signature (GFH entry · vector table at payload start · crt0) not found | `stage_map.py` exit code 3 |
| `BLOCKED_CARVE` | container only partially extracted | static-analyzer derivation |
| `BLOCKED_NO_INPUT_PATH` | A round stopped waiting for input and no surface has an input path | round observation + static-analyzer derivation |
| `BLOCKED_ASSET` | F2 and above, kernel assets still missing **after** the pipeline loaded them (F1 would proceed) | `fw/` contents after loading (static-analyzer's `assets_ok`) |
| `BLOCKED_KO` | `.ko` absent and not built into the kernel | pipeline raises it at F2 and above when static-analyzer reports `storage_driver.form=absent` |
| `BLOCKED_BUILD` | ninja failed | build result |
| `BLOCKED_TEE` | secure world (TEE) | manual record; out of scope by design |
| `EXHAUSTED` | attempts exhausted | `stop_conditions.py` |

- **`BLOCKED_CARVE`** only when the carve verdict is `false`. Verdict `true` · `false` · `null`; `null` (the family
  `carve_disasm.py --family` names has no string/size criteria and the image has no container-header basis) is not a
  stop: log "carve undetermined" and the reason via `journal.sh decision`, continue. Reading an unmeasured thing as
  partial extraction blocks a run over a measurement not made.
- **`BLOCKED_ARCH`** only when **the deriver found no signature, never because of the architecture itself**: never
  raised merely because the image is arm32. It means "the tool did not find it", not "no stage"; blurring that turns a
  tool gap into a firmware verdict. A stage with a signature whose load base did not converge on two independent
  anchors (`state: unconfirmed`) is not `BLOCKED_ARCH`: **mark it non-runnable and re-derive** (exit code 0). `arch` is
  derived with `stage_map.py --detect-arch` (`start` records the first container in `INPUT.md` and passes it; the
  pipeline asks again if `unknown`). **Never substitute a default for `unknown`**: tentatively derive the map as arm64;
  no signature → stop with `BLOCKED_ARCH` and that basis. That too is a tool gap, not a firmware limit.
- **`BLOCKED_ASSET`**: kernel assets (`Image` · DTB · initrd · super) are never extracted by hand. Standard boot-image
  unpack: the pipeline loads them into `fw/` with `extract_boot_assets.sh` before Analyze; raised only when needed
  assets are still missing after loading. Only super failing to unpack (script exit code 4) is a partial load, not a
  stop.
- **`BLOCKED_NO_INPUT_PATH`** is not raised by static derivation alone (it would block surface-`none` bootloaders that
  reach the kernel without input): only when an input wait is observed and no input path exists. Input waits count
  **by measurement only**: surface `none` and `waiting_for_input` (console quiet while the machine's receive polling
  counter keeps growing; `uart_harness.py` measures it into `observation.json`) true for `input_wait_rounds` (default 2)
  consecutive rounds with no new rung. No polling report → `null`, which alone does not stop.
- **`BLOCKED_ENV`** compares `~/.sboot/env.json` (current) with the plugin's `env_manifest.json` (required). QEMU binary
  set directly by env var skips the comparison and **records the skip as `skipped` in the report** (tests, direct
  installs); `init`'s latest-environment guarantee then fails. `init` needing apt packages, not root, `sudo -n true`
  failing (password required) → exit code 7 `BLOCKED_ENV` before installing or deleting anything (§14).
- Early exit on an exception-count threshold (`MAX_EXCEPTIONS`) is **off by default**; when on, that round's observation
  ends there.
- A **strict mode** that stops where a verification bypass is needed exists in design only; its selection path and stop
  code name do not exist yet (§11).

### Attempt exhaustion

Not the round count but **exhaustion of possible attempts**, recognized only when all three hold:

```
(fingerprint stall or A↔B oscillation)
AND no new facts from static-analyzer re-derivation
AND every owner fixer answers "no change to try"
```

- Stall is judged over the **recent window (default 3 rounds)**, not the last round.
- "No new facts" is not the analyst's self-report: `derived_facts.py` **counts the lines added to the derivation table**.
- "Fixers exhausted" must be the answer of fixers **actually queried**.

**An agent cannot overturn a stop verdict.** `stop=true` with the supervisor ordering continue → the pipeline
force-stops and records the contradiction.

A stop auto-generates `RESUME.md`: reached point, last fingerprint and last round's log paths (`kernel_log` ·
`host_log` if present), attempted changes with effects, untried means, resume command. It omits the runbook step (resume
re-judges it from the rung list). **A stop is a handoff, not an abort; it is resumable.**

`runtime_round_cap` (default 120) is a runtime limit, not a goal verdict, and counts **only rounds run in this
execution**. On resume, round numbers continue after the workspace's highest (the larger of `rounds.jsonl` and
`07_logs`, excluding the negative test's 9000s): earlier console · kernel logs · traces are not overwritten and
`rounds.jsonl` never gets a number twice. Number unreadable → starts at 1, warns that overwriting may occur.

---

## 11. Verification: 3 gates

```
Step 1  verify.py        → verdict_script.json     (measurement)
Step 2  verifier agent   → re-verifies raw logs and bytes  (final verdict)
```

Only three things block the verdict. One purpose: **keep a console made up by the machine or an agent from reading as
a real boot.**

**The guest console that verification reads = UART console (`console_N.txt`) + memory-dump kernel log
(`kernel_N.log`).** QEMU host diagnostic lines (`qemu-system-…: `) are not guest evidence; `verify.py` filters them once
more. Input is **bound to the workspace and round**: never pick up other runs' traces in the home folder.

| # | Gate | Pass condition |
|---|---|---|
| 1 | **Source negative** | Strings the **actually built** machine source prints do not appear on the guest console. Lexer-based: sees escapes · adjacent literals · char lists · byte arrays · constants readable as ASCII. Fails on 2+ UART send call sites, code writing to stdout, or an integer constant pointing inside the memory-dump region (`memdump_plan.json`, pstore etc.) |
| 2 | **Output source** | **Fixed strings** on the guest console exist inside the firmware images |
| 3 | **Input source** | Machine does not fill its own receive buffer. Fails on receive-buffer writes outside the chardev callback (timer callbacks included), direct calls of its own receive callback, or monitor commands other than `pmemsave` |

Verdict: **`VERIFIED (출처 검증 통과)`** / **`UNVERIFIED (출처 검증 실패)`**.
With verification bypasses, **append the count to the verdict phrase** (see "Verification-bypass report").

**Source verification passing does not mean the boot completed**; reach is seen separately, by milestone.

### Reference metrics (not gates: measured and reported only)

Chain PC trace · verification both directions · storage dual drive · bypass record.
As pass conditions they would bury real progress under a single `FORCED`, so they are out of the verdict.

- Chain PC trace is watched and verified by **the single `entry_pc`** in `stage_map.json`.
- Verification both directions takes the console of one more round on a corrupted medium (`07_logs/avb_negative.txt`).
  Never run: report **"입증하지 못함"** (not proven), do not count it as a bypass.
- Bypass record is judged by **4 fields · side effect · patch-table row correspondence**, not line count (§7).
- Mixed-architecture machine (machine source has a handoff tick): the `STATIC.md` **주소 창 표** (`address windows`, ten
  columns) is only **reported** as `address_windows`: table present, columns missing, window count, rows with empty
  `security_effect`. The verdict and the gate count do not change.

### Scope of gate 2's comparison

**Runtime-assembled parts (`%d` · `%s` substitutions) are not compared**: console numbers are normally not in the
firmware, and counting them as not found fails a genuine console.
The console is printed by **every firmware component** sharing that UART (bootloader · other UART-sharing components ·
kernel), so comparison targets are all components in `02_unpacked/`. Compressed kernel and ramdisk are decompressed
first (`verify_prep.py`).

- **Bytes we made are not evidence.** Partitions `synthesized` or `forged` in `lu_provenance.json` and the synthesized
  medium image (it holds the command line we wrote into the plan-named partition) leave the reference set.
- Pass criterion is the word ratio; the **line-shape comparison's not-found list** (runtime assembly · format +
  function name · suspicious) is reported. Suspicious shapes are marked only, not gated. Shapes that could not be
  compared count as `unchecked`. English words are everywhere in a large image: **never claim "every line was checked
  line by line."**

### Verification-bypass report (not a gate: must be appended to the verdict phrase)

The gate answers "did this console come from the firmware"; this report answers **"was the firmware's verification
actually computed"**. As a gate, a hardware-engine-hash firmware would be `UNVERIFIED` forever and source verification
would lose its meaning. So it is a report, but **one that cannot be skipped.**

| Signal | Basis |
|---|---|
| verification-bypass rows in the bypass ledger | mark `F`, or rows containing `avb` · `digest` · `memcmp` · `unlock` · `verifiedboot` · `sbc` |
| forged medium | `forged` in `lu_provenance.json`, AVB footer magic |
| image modification | `modified` in `lu_provenance.json` |
| firmware's own status line | Security-state string on the guest console. May be a **value the machine chose by changing a branch**, so it goes in the report. Which string is a per-firmware fact: static-analyzer derives it into `status_tokens.txt`; scripts hold no vendor strings (file absent: the report says it was not looked for) |
| negative test | Verification not failing on a corrupted medium is a bypass (a stubbed verification always says "equal") |

`verify_bypass {count, signals[], status}` goes into `verdict_script.json`; `count` above 0 makes the verdict phrase:

```
VERIFIED (출처 검증 통과) · 검증 우회 N건 · verify_ok: reached_bypassed
```

That run's grade report is **"F2 (verify_ok 우회 N건)"**, and the first line of `VERIFICATION.md` states the same count
(§3). This does not lower the grade; it is a **rule that states the reach honestly.**

**The negative test is not free.** In an F2-or-above run where step 1 passed, the pipeline corrupts one bit of a medium
copy, runs a round **once more** (at most `run_timeout` seconds + the medium copy) and measures `verify.py` twice. Round
number in the 9000s, never overlapping a real round; console only in `07_logs/avb_negative.txt`. `negative_test: false`
turns it off; the report then says "펌웨어의 검증은 증명되지 않음" (the firmware's verification is not proven), which does not mean it passed.

### Kept even when relaxed

| Rule | Why |
|---|---|
| **No speculative stubs** | Adaptive toggles above all. Wrong branch; does not reproduce on other firmware |
| **A bypass is labelled a bypass** | `bypasses.md` 4 fields. `부작용` is consulted first when stalled. Empty = invalid |
| **A point not reached is recorded as not reached** | |
| **Never forge the verification result itself** | Status words may change; return values and failure output stay. **The only exception is below, and it is a provisional exception the user has not yet approved** |

### The only exception: firmware whose hash is computed by a hardware engine (provisional)

> **This exception relaxes a rule, and the user has not decided on it.** Releases before 0.28.0 had no exception. It
> went in only on the advice of a design document that existed before 0.29.1 (deleted; recoverable from git history
> after 1d47260); no explicit user answer is recorded. So it is **provisional**. If the user objects, delete this
> section and restore the exception wording in the table above: the rule returns to its original, exception-free form.
> The strict mode in (c) below also has no path to select until that decision.

"Keep the return value, change only the status word" assumes **image and verification code are both the vendor's, so
hash and signature pass unpatched in software**. For a firmware whose hash is computed in a hardware engine (SMC →
monitor → engine) that is false: without the engine every digest is wrong. Only then is a patch that changes the
comparison result (return value included) allowed, **in this order**:

| Order | Content |
|---|---|
| (a) | **Model the engine (M)** so digests are actually computed. The honest way. Feasibility **not yet tested** |
| (b) | Only if (a) fails **and only when the preconditions below are met**: comparison patch allowed, with **mark `F` · verification-bypass ledger · rung `reached_bypassed` · negative test** all in place |
| (c) | If neither (a) nor (b) can be done honestly, or in **strict mode**: stop. The path to choose strict mode is **unimplemented** |

**What opens (b) is a derived fact, not a fixer's judgement.** If the judge is also the fixer, it names a nonexistent
cause to create something to fix (§4).

| Precondition | Record | Machine-checked? |
|---|---|---|
| The hash is computed in a hardware engine | static-analyzer writes a `STATIC.md` table row whose first cell is `hash_engine` and second cell is `hardware`; the evidence cell gives where the hash path leaves via SMC or engine MMIO (function address · SMC id). **A fixer cannot write this row** | **Only row presence and shape are checked (implemented).** A bypass record newly written or edited this round with mark `F` that changes a hash · digest · signature comparison and is not kind `M`: `check_change.sh` (via the `verify_gates.py` ledger check, problem kind `hash_engine_row_missing`) rejects with exit code 2 when no usable `hash_engine` row exists, naming the record's number and the missing row shape. Usable row: value `hardware`, a `0x` address in the evidence cell (function address · SMC id), outside a code fence. The one-line form `hash_engine: hardware (evidence: ...)` is read too. `STATIC.md` is append-only: **the last usable row wins.** **Not checked:** who wrote the row (that a fixer cannot), whether (a) was really impossible, records lacking the words hash · digest · signature |
| (a) fails | a fixer writes in the bypass record's `이유` the modeling attempted (round number) and where it got stuck | **No.** A machine cannot judge that (a) is infeasible; the verifier reads `이유` and puts it in `VERIFICATION.md` |

**Who wrote the row** (a fixer cannot) and **whether (a) was really impossible** are enforced by the `fixer-secureboot`
prompt and the verifier. Every (b) bypass shows up in the **검증 우회 N건** on the first line of `VERIFICATION.md`; the
report (`verify_bypass.hash_engine`) carries whether the row that bypass relies on exists and the rowless records
(`unbacked`). Both conditions are **necessary, not sufficient**: meeting them does not prove the bypass justified.

- Applies **only to the hardware-hash path.** A software-hash firmware must still pass unpatched; if it does not, our
  input is wrong.
- Allowed: **changing the comparison result.** The machine printing a success string or erasing failure output is
  still a rule 7 violation.
- Fuse · lifecycle · lock values the firmware reads cannot be derived (real-device values). If one changes the
  verification path, record `security_effect: true` in `STATIC.md`. The firmware's own security-state log lines go in
  the report above.

---

## 12. Records

Record every run. **No completion report without records.** Timestamps come from the real `date` output.

### Human-readable record: `JOURNAL.md` (`scripts/journal.sh`, append-only)

| When | Command |
|---|---|
| command start / finish | `session-start` / `session-end` |
| round start / finish | `try-start` / `try-end` |
| phase boundary | `phase` |
| automatic decision | `decision` |
| **user input, verbatim** | `prompt` |
| **hypothesis before an attempt** | `hypothesis` |
| **stop-point resolution history** | `resolution` |

Record user input **verbatim, never summarized**: when a run stalls, the instruction that chose the direction is the
first thing lost, and a summarized instruction is not an instruction. Keep wrong hypotheses: what was ruled out is the
record.

### Machine-readable records (`scripts/record.py`, append-only)

| File | Content |
|---|---|
| `metrics.jsonl` | time · token measurement events |
| `rounds.jsonl` | 1 round = 1 line (fingerprint · classification · fixer · change key · effect · **change rationale**) |
| `blockers.jsonl` | hard blockers confirmed by observation |
| `prompts.jsonl` | user input, verbatim |
| `resolutions.jsonl` | stop-point resolution history |

**A round that assigns a fixer requires `rationale` (the change rationale).** Missing: flagged `rationale_missing`.
Without it nobody can later trace what was changed and why.

---

## 13. Autonomous execution

A run command is autonomous from start to end. Never call `AskUserQuestion`. Decide every branch automatically, record
it with `journal.sh decision`.

**No exceptions.** The grade comes only from `start`'s argument, default `F2`. Even the setup-time question is gone:
anything to ask makes the run wait for a person, and that wait defeats autonomous execution.

---

## 14. Commands

**Four commands; `start` is the only run command.**

| Command | Role |
|---|---|
| `/sboot-rehost:init [--clean] [--wipe-workspaces] [--replace-unmarked]` | **Once after install.** Clean old environment → QEMU 10.2.2 baseline build + dependencies + workspace root (about 18 min) |
| **`/sboot-rehost:start [F1\|F2\|F3]`** | **Run.** Recognize firmware → detect family → workspace → derive → medium → build machine → round loop → verify → reproduction kit, autonomously |
| `/sboot-rehost:status` | Progress · verification · stop summary (read-only) |
| `/sboot-rehost:export` | Regenerate the reproduction kit |

`init` **deletes the old environment first**, starting with old version caches (an old folder can get old skills or
agents loaded again). Deleting the cache does not change what the session already loaded: if an old version is loaded,
**stop there and require a restart**; reporting "cleaned" while running old code is the worst outcome.

Cleanup goes beyond the cache: an old **toolchain and derived artifacts** leave the user on an old QEMU. **Old is judged
by `env_revision` in `env_manifest.json`, not plugin version** (doc-only edits raise the version; no reason to spend 18
minutes).

| Layer | Target | Default | `--clean` |
|---|---|---|---|
| L1 plugin | old version folders in the cache, `__pycache__` | delete | same |
| L2 toolchain | trees and tarballs in `~/qemu-build`, `~/.sboot/env.json`, pip modules `init` installed | **delete and rebuild only if they differ from the manifest** | always |
| L3 temp · derived | `/tmp/sboot_*`, `~/rehost/_traces/run_*.log` | last modified over 1 hour ago | all |
| L4 workspace | `rehost_workspaces/<id>` | **kept**; only reports what old versions made | only with `--wipe-workspaces`, **moved to `_archive/<id>_<timestamp>`, not deleted** |

- **Delete only what carries a mark that this plugin made it.** Unmarked QEMU trees · tarballs · `env.json` are not
  deleted even with `--clean`; they are reported with the reason. `--replace-unmarked` does not delete such a tree: it
  **moves it aside** and builds a new one.
- `init` builds only the **pristine QEMU, no patches.** Core patches differ per family and Build applies them; start
  runs `qemu_tree.sh reset` to undo the previous firmware's additions. So the patch set is not a rebuild condition.
- Report the **path and size** of what was deleted and the **reason** for what was not. Announce the rebuild (about 18
  min) before starting. `check_env.sh` makes the same comparison; mismatch → `BLOCKED_ENV`, points to `init`.
- **sudo preflight.** `init` runs in the background; nobody can answer a password. Before installing or deleting
  anything, `setup_env.sh` checks: apt packages actually needed (`dpkg-query`) and not root → try `sudo -n true`. On
  failure: installs and deletes nothing, stops with exit code **7** (`BLOCKED_ENV`), prints
  `sudo apt-get update && sudo apt-get install -y …` with only the packages actually missing. The user runs it once in a
  terminal, then calls `init` again. It never asks. `--dry-run` runs the same check and reports it in the plan JSON's
  `apt` (`needed` · `checked` · `missing` · `sudo`).

`init` is separate because the **QEMU build takes 18 minutes**; inside the run command it would make a user who thinks
rehosting started wait. Build the environment once, however many firmwares.

`start` **reads the state and picks the next step itself.**

| State | Action |
|---|---|
| no workspace root or dependencies | stop with `BLOCKED_ENV` and **point to `init`** |
| `_inbox/` empty | tell the user to put firmware in, and **exit** |
| firmware present | recognize → detect family → workspace → unpack → `INPUT.md` slot table → proceed to the end |
| workspace already exists | continue (resume); do not write or overwrite `.sboot_version` |

The grade comes only as an argument, default **F2**. No questions.

A new workspace writes the creating plugin's version into the root `.sboot_version`. A workspace with no mark or a
different one is only **reported** by `init` as made by an old version (resume never fills it in).

Flow: `init` → put firmware in `_inbox/` → `start` → (if needed) `export`

> Old `rehost-*` commands are all deleted; one left in the command list means an old version is loaded.

## 15. Working directory

```
<cwd>/rehost_workspaces/
├── _inbox/                      where firmware is placed
├── .active                      default target id (start writes the workspace it is currently working on)
└── <id>/
    ├── .sboot_version           plugin version that made this workspace (mark)
    ├── INPUT.md                 input slot table (written by start: model · build · target · bootloader_path · has_super ·
    │                            arch · bl_surface · soc_family, each with its basis; every value has a source, unknown if none)
    ├── STATIC.md                derivation record (append-only)
    ├── stage_map.json           stage map (derived, schema v2)
    ├── PROGRESS.md              round history (human)
    ├── JOURNAL.md               session and history record (human, append-only)
    ├── RESUME.md                handoff document on a stop (auto-generated)
    ├── metrics/rounds/blockers/prompts/resolutions.jsonl
    ├── fingerprint.json         last round's fingerprint
    ├── observation.json         last round's observation document
    ├── verdict_script.json      3 gates + reference metrics + verification-bypass report measurement
    ├── VERIFICATION.md          verifier's final verdict
    ├── ANALYSIS.md              time · cost · resolution-history analysis
    ├── milestone_tokens.txt     observed string + channel per goal rung (derived)
    ├── memdump_plan.json        memdump channel region (derived, only when present)
    ├── kernel_task_regex.txt    kernel-line task-prefix format (derived, only for another format; first non-empty line = regex)
    ├── input_plan.json          input-gate pattern (derived; without it the harness sends no pattern)
    ├── lu_manifest.json         medium partition layout (derived)
    ├── stage_rungs.json         rung → stage → entry PC (pipeline writes it; lets a silent stage's entry count by an executed PC; first stage excluded: the machine places the CPU there)
    ├── status_tokens.txt        firmware's own security-state strings (derived; verification-bypass report searches it; absent = not searched)
    ├── kernel_patch_sites.json  kernel patch sites (derived; absent = no patching)
    ├── 06_machine/              machine source + bypasses.md
    ├── 07_logs/                 per-round logs: console_N (guest UART) · host_N (QEMU host lines, rounds that had lines) ·
    │                            kernel_N.log (memdump merge) · memdump_N.json · reset_N.json ·
    │                            summary · first exception · input log · avb_negative.txt (negative-test console)
    ├── 08_docs/                 analysis notes (incl. assets_staging.txt, kernel asset loading log)
    ├── fw/                      boot assets (F2+: pipeline loads them from 02_unpacked) + synthesized medium (lu0.img) +
    │                            lu_provenance.json (provenance kind per partition)
    └── 10_reproduce/            reproduction kit
```

Large writes (run copies · full traces · raw memdump snapshots) go to WSL ext4; documents the user reads stay local.
A session may start on either side; `wsl_bridge.sh` switches when needed.

---

## 16. Round record format (`PROGRESS.md`)

```
| run N | <정지점 신호> | <변경 1건> |
```

1 round = 1 change = 1 line; never bundle changes.

- Specialist fixer's one change: one source file · within `MAX_HUNKS` (default 3) hunks, counted from the diff by
  `check_change.sh`.
- The last resort `fixer-general` counts as one change when **one coherent mechanism** spans several places and files
  (`CHANGE_SCOPE=general`). File and hunk counts are specialist limits and do not apply to this fixer. Different
  mechanisms are never bundled either way; the fixer's rules enforce that, not the diff. PROGRESS.md still gets one
  line.
