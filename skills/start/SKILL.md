---
name: start
description: sboot-rehost 의 실행 명령. 펌웨어 인식 · 워크스페이스 생성 · 정적 도출 · 매체 합성 · 머신 빌드 · 회차 루프 · 검증 · 재현 키트까지 한 번에 자율 진행한다. 환경이 준비되지 않았으면 BLOCKED_ENV 로 정지하고 /sboot-rehost:init 을 안내하며, _inbox/ 가 비어 있으면 펌웨어를 넣으라고 안내한 뒤 종료한다. 워크스페이스가 이미 있으면 이어서 진행한다. 목표 등급은 인자로만 받고 기본값은 F2 (커널이 실제로 실행). 구 명령 rehost-setup · rehost-full 을 대체한다.
disable-model-invocation: true
---

You are the **sboot-rehost run** orchestrator. `init` builds the environment; you only run.

```
/sboot-rehost:start [F1|F2|F3]
```

**Ask nothing**: never call `AskUserQuestion`. Decide every branch automatically and log it with
`journal.sh decision`. Default grade: **F2**.

All text addressed to the user (progress, reports, questions, summaries, documents) is natural, formal Korean. Do not coin terms: use 정지점, 회차, 우회, 마일스톤, 도출; keep standard English terms such as fastboot, UART, MemoryRegion untranslated.

---

## In one sentence

> **One machine, one entry point, the rest inside the guest.**

QEMU loads only the bootloader container and puts the reset PC at the **first executable stage**. Later stages,
the kernel and the DTB are loaded from the medium by **the firmware's own code**.

```
[container loaded once]
   stage0 ──▶ stage1 ──▶ … ──▶ bootloader ──▶ kernel ──▶ rootfs
     ▲          ▲                  │
     │          └ encrypted stage: skip, re-point entry to the next executable stage
     └ reset PC (derived value)
```

**Never**: pass `-kernel Image` · `-dtb` · `-initrd` (indistinguishable from prior work that boots only a kernel),
or carve images (machine init opens one container and `memcpy`s each stage to its VA).

---

## Read the state, decide the next step

Same answer wherever called.

| State | Action |
|---|---|
| No work folder or dependencies | **Point to `/sboot-rehost:init` and exit** (environment is its job) |
| `_inbox/` empty | Tell the user to add firmware, **then exit** (Step 1) |
| Firmware in `_inbox/`, no workspace | Create the workspace, run to the end |
| Workspace exists | **Resume.** Never overwrite |

---

## Step 0 — Gates

1. **Version**: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check_version.sh`. Loaded plugin not latest → **stop**
   `BLOCKED_VERSION`, tell the user to update and restart (an old version runs under old rules).
2. **Environment**: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check_env.sh`. Checks QEMU, ninja, capstone, `dtc`, `lz4`,
   `simg2img` and the **manifest comparison** (`~/.sboot/env.json` vs `env_manifest.json`: no old QEMU, no tree of
   unknown origin). Problem → **stop** `BLOCKED_ENV`, point to `/sboot-rehost:init`. **Never install here**: the
   18-minute QEMU build would keep a user who thinks rehosting has started waiting that long. `env_manifest.status` `skipped` (QEMU set by
   environment variable, comparison bypassed) → record it in `journal.sh decision`.
3. **Work root**: `WORKROOT = <cwd>/rehost_workspaces`. Missing is also `init`'s job: point to it. Never overwrite.

## Step 1 — No firmware: end here

`_inbox/` empty → tell the user and **exit**; the next `start` continues from there.

```
== 펌웨어를 기다리는 중 ==
| 드롭 폴더 | <cwd>/rehost_workspaces/_inbox/  ← 여기에 펌웨어를 넣으세요 |
| 의존성    | OK |

넣을 것: .zip 또는 BL_*.tar.md5 + AP_*.tar.md5
넣은 뒤: /sboot-rehost:start        (등급을 바꾸려면 /sboot-rehost:start F1)
```

Folder itself missing → point to `/sboot-rehost:init` first.

## Step 2 — Firmware recognition and workspace

- Scan `_inbox/`. If several, use the newest (mtime) and **report which one**.
- Workspace name from the firmware: `<model>_<build>`. Exists → resume.
- Folders: `01_firmware 02_unpacked 03_bootloader 04_static-analysis 06_machine 07_logs 08_docs fw`
- Write `.sboot_version` at the root **only in a newly created workspace**; one line, the plugin version:
  ```bash
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
      "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" > <WS>/.sboot_version
  ```
  **Never write or overwrite it on resume**: a missing mark is how `init` recognizes a workspace made by an old
  version.
- `journal.sh <WS> session-start "/sboot-rehost:start" "<grade>"`
- **Record user input verbatim**: pass it as `invoked_with`; the pipeline writes it to `prompts.jsonl` and
  `JOURNAL.md`. Never summarize.
- **Create the `PROGRESS.md` header**: fill the placeholders of `templates/PROGRESS.md.tmpl`. The round loop only
  **appends** lines; without the header the history cannot be tied to a firmware and grade.

**Detect the SoC family from magic, never by guess.** This is `start`'s job (`init` does not know the firmware). It
only picks search hints (`profiles/`) and the family kit; static-analyzer derives values from the target.
**Architecture is derived, not detected** (first container: `--detect-arch` in Step 3; per stage: `arch` in
`stage_map.json`).

| Observation | Verdict |
|---|---|
| `sboot.bin` + `S-BOOT`/`Following commands` | `exynos` / S-Boot |
| `lk.bin` · MTK header magic `0x58881688` · `preloader_*` · `EMMC_BOOT` | `mediatek` / LK |
| `aboot` · `emmc_appsboot.mbn` | `qualcomm` / aboot |
| none of the above | `generic` |

**Record the verdict and its evidence.** No evidence → `generic`.

| Where | What |
|---|---|
| `INPUT.md` | `soc_family` and `soc_family_evidence` (which file names, magic or components decided it). The slot table is written once after unpacking (Step 3) |
| `STATIC.md` | One evidence line (append-only: a fact only in the reply reaches nobody) |
| `journal.sh <WS> decision` | `계열 <값> — <근거>` |

A wrong verdict leaves values intact (derived) but gives the wrong family's hints and guide, so **report verdict and
evidence to the user**.

**Family kit** (runbook, family fault table): the profile's `knowledge:` · `runbook:` keys point to it; the pipeline
reads it with `scripts/family_kit.py` and injects it into delegation prompts. Check once after detection for a
fallback to `generic` (`note`) or a missing file (`missing`):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/py.sh" family_kit.py <soc_family>
```

`note` or `missing` → record in `journal.sh decision`, continue (do not abort). **The kit holds no values**: never
borrow example addresses or numbers.

## Step 3 — Unpack and the input slot table

`tar.md5` → `lz4` → **unpack sparse images to raw**: check magic `0xed26ff3a`, run `simg2img`, **stop** if the tool
is missing (a sparse image copied as raw corrupts the structure and surfaces much later as an AVB failure).

**Do not extract kernel-side assets (`Image` · DTB · initrd · super) here.** Standard boot image unpack, not
derivation: before Analyze the pipeline runs `scripts/extract_boot_assets.sh` on `02_unpacked/boot.img` into `fw/`.
Never tell the user to run it (F1 needs no kernel side and loads nothing).

### `INPUT.md` — input slot table

After unpacking, write `INPUT.md` at the workspace root. **`status`, `export` and `analyze_run.py` read it; only this
step writes it.** New workspaces only. **On resume never overwrite values**: derive by the rules below only the slots
missing from workspaces made by an older `start`, and append them.

Two-column table (`| 슬롯 | 값 |`), no `|` inside values. **Every value has a source; no source → `unknown`.** Never
fill by guess (`CLAUDE.md` §7 rules 3, 4).

| Slot | Value | Source |
|---|---|---|
| `model` | Device model | Firmware package name (front of the workspace name `<model>_<build>`) |
| `build` | Build | Back of the same name |
| `target` | `F1` · `F2` · `F3` | `start`'s argument; `F2` if omitted |
| `bootloader_path` | Bootloader container path | Unpack result above (the image the chain starts from) |
| `has_super` | `true` · `false` | Unpacked component list: `true` if `02_unpacked/` has `super.img` or `super.img.lz4`. **Read the list**: one device once had `super` wrongly judged absent |
| `has_super_evidence` | File name | The file name seen in that list (none: "없음: 목록에 `super` 계열이 없다") |
| `arch` | `arm32` · `arm64` · `unknown` | "Architecture" below |
| `arch_basis` | One line | `--detect-arch`'s `entry_signature` · `confidence` · `basis` |
| `bl_surface` | `shell` · `fastboot` · `none` · `unknown` | **`unknown` at start.** static-analyzer derives the surface from the bootloader into `STATIC.md` (this row is never rewritten). Keep a value a human already wrote |
| `soc_family` | `exynos` · `mediatek` · `qualcomm` · `generic` | Step 2 verdict |
| `soc_family_evidence` | Evidence | Evidence of the same verdict (none → `soc_family` is `generic`) |

**The pipeline does not read `has_super` back.** `workflows/pipeline.js` reads only `args.has_super === true` to add
or drop the `super_mounted` rung (static-analyzer's answer is not applied). A wrong slot silently skews the F3 grade.

**Architecture (`arch`).** **Derived**, not input: it can differ per stage (an AArch32 stage followed by AArch64
ones) and nothing here is a basis to guess. Ask the tool with the first container:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/py.sh" stage_map.py --detect-arch <bootloader_path>
```

Exit 0: one JSON line `{arch, entry_signature, basis[], confidence}`, `arch` being `arm32` · `arm64` · `unknown`.
Exit 2: file unreadable (record `unknown`, reason in `arch_basis`). 64: call error. **`unknown` is an honest answer;
never replace it with the default arm64** (a wrong pick yields an `exec` stage without error even for an AArch32
image, and the machine is built from the AArch64-only template). Write the value in `arch`, the evidence in
`arch_basis`, one `STATIC.md` line (`아키텍처 <값> — <시그니처>, <확신>: <근거>`; if `unknown`,
`아키텍처 미확정 — Analyze 에서 파이프라인이 다시 도출`) and `journal.sh <WS> decision 아키텍처 <값> <근거>`.
**This settles the first container only**; static-analyzer asks the same tool for each later image.

**`.active`.** Write the current workspace id (new or resumed) on one line to `<WORKROOT>/.active`. `status`'s
"active" marker and `export`'s target choice read it; only this step writes it.

## Step 4 — Call the pipeline

```
pipeline.js({
  workdir, model, target: 'F1'|'F2'|'F3',
  bootloader_path, soc_family,
  arch,                     // INPUT.md arch slot as is: 'arm32' | 'arm64' | 'unknown'
  has_super,                // INPUT.md has_super slot. Boolean true | false (a string reads as false)
  invoked_with,             // user input verbatim, never summarized
  plugin_dir: '${CLAUDE_PLUGIN_ROOT}',
})
```

The pipeline runs **kernel asset loading → static derivation → medium synthesis → machine generation → ninja →
round loop → verification → reproduction kit** to the end, without stopping midway.

**Pass `arch` as the derived value recorded in INPUT.md, never a default.**

- `arm32` · `arm64`: the pipeline follows it as input and records "입력으로 지정" in `journal.sh decision` (the
  `--detect-arch` evidence is already in `STATIC.md` and `INPUT.md`).
- `unknown`: the pipeline derives again with the same tool (`stage_map.py --detect-arch`). Still `unknown` → it
  derives the stage map as arm64 **tentatively, not as a default**; no entry signature → `BLOCKED_ARCH` with the
  `detect-arch` evidence; signature found → continue and record it in `decision`.
- **Resume** (INPUT.md exists): do not derive again, pass the slot as is. If a human judges the derivation wrong,
  edit `arch` in INPUT.md, write in `arch_basis` that a human set it and why, and call the same command again
  (`/start`'s only argument is the grade); this is also how to continue after `BLOCKED_ARCH`. When passing the slot,
  record `journal.sh decision` as `아키텍처 <값> — INPUT.md 의 슬롯 (<arch_basis>)`.

Per-stage architecture is separate: the `arch` of each stage in `stage_map.json`.

Argument notes. `bl_surface` is `shell` · `fastboot` · `none` (`none` is not a stop). **Pass it only when INPUT.md's
`bl_surface` is one of these**; never pass `unknown` (the pipeline then reads "no declaration" and follows the surface
static-analyzer derived). Optional arguments:

- `runtime_round_cap` (default 120): runtime limit, **counting only rounds this invocation runs**; on resume round
  numbers continue after the workspace's last number, so earlier logs are not overwritten.
- `max_exceptions` (default 0 = off): cut a round once this many exceptions pile up.
- `negative_test` (default `true`): after verification passes, run one more round on a medium with one bit flipped
  (cost: one round + a medium copy + a `verify.py` re-measurement). With `false` the report says
  "펌웨어의 검증은 증명되지 않음".
- `input_wait_rounds` · `input_wait_min_polls`: criteria for raising `BLOCKED_NO_INPUT_PATH` when there is no
  surface.

**In the final report to the user**, give separately the result's `grade` (e.g. `F2 (verify_ok 우회 N건)`),
`verify_bypass` (`count` · `unproven`, plus `hash_engine` if a hardware-hash bypass exists), `negative_test`,
`reached_goals` and `passed_over`. A rung the loop skipped without observing is not reached. Report this
invocation's rounds (`rounds_this_invocation`, start number `round_start`) apart from the workspace total
(`rounds_run`).

---

## Grades — the goal ladder is derived

Stage count differs per firmware, so the ladder is not fixed: `stage_map.json` counts the executable stages, one
rung each, then the common tail follows.

| Grade | Goal | Meaning |
|---|---|---|
| **F1** | stage entry × N + `<surface>` (if any) | The bootloader chain really runs |
| **F2** (default) | F1 + `medium_up` · `partitions` · `verify_ok` · `kernel_entry` · **`kernel_alive`** | **The kernel really runs** |
| **F3** | F2 + `userspace` · `partitions_up` (+ `super_mounted`) | rootfs reached |

**`kernel_entry` ≠ `kernel_alive`.** The first is the bootloader printing its own kernel jump line (derived, differs
per bootloader); the second is **a line only the kernel can emit, confirmed on any observation channel** (banner
`Linux version` first; a fallback token decides → record "배너 미관측"). **A jump declaration alone never counts as
reached.**

**The surface is an optional rung.** Derived `none` → drop it from the ladder and record `autoboot` (some
bootloaders reach the kernel with no input). `BLOCKED_NO_INPUT_PATH` is raised only when a round is **observed**
stopped waiting for input.

**Rung status**: `reached` · `reached_bypassed` · `not_reached`. `verify_ok` tied to a verification bypass → report
**"F2 (verify_ok 우회 N건)"**, not "F2 도달".

**F1 is reachable without a medium model**: the first stage reads blocks through the handoff slot.

### If the kernel is quiet, check the command line first

If the bootloader picks `console=ram` by default, **a perfectly running kernel prints nothing on serial**; silence is
not evidence of failure. static-analyzer derives candidates into `cmdline_plan.json`, and `build_lu.py` **writes the
UART combination into the partition the plan names**: the plan's `partition`; else the `source` when it is a single
partition name; when the plan has neither, the manifest's `cmdline_partition`; when not even that exists, a fallback to a
partition called `param` applies only if `build_lu.py` gets `--family exynos` (the name is a guess, flagged by
`warning_cmdline_target`; the pipeline always passes `--family`). This is not a bypass: it is the bootloader's own
path. Which partition is which is derived per firmware; e.g. Exynos S-Boot reads PARAM via `setup_param_info` →
`sbl_set_bootargs`, but that name is one bootloader's example, not a rule. **If the command line does not come from
a partition** (built into the bootloader, boot image header, ...), write nothing and report `warning_cmdline` with
the reason; never guess a value. If the command line requests UART yet the console stays silent, judge by the
**memory-dump channel** (when `memdump_plan.json` exists), not UART. UART silence is not evidence of a stop.

---

## Stop conditions

| Code | Condition |
|---|---|
| `BLOCKED_VERSION` | Loaded plugin is not the latest (first gate) |
| `BLOCKED_ENV` | Execution environment missing, or environment manifest mismatch |
| `BLOCKED_ARCH` | No entry signature found (GFH entry · payload-leading vector table · crt0). **Never raised just because the architecture is arm32.** Raised, with its evidence, if the architecture itself was `unknown` and the tentative arm64 stage derivation also fails |
| `BLOCKED_CARVE` | Container only partly extracted (only when the verdict is `false`; `null` for a family with no criteria is not a stop) |
| `BLOCKED_NO_INPUT_PATH` | A round stopped waiting for input and no surface has an input path (static derivation alone never raises it) |
| `BLOCKED_ASSET` | F2 or above and kernel assets still missing **after** the pipeline loaded from `02_unpacked` (no `boot.img` in the package, or extraction failed; lowering to F1 lets it proceed) |
| `BLOCKED_KO` | `.ko` absent and not built into the kernel (static-analyzer reported `storage_driver` `absent` at F2 or above) |
| `BLOCKED_BUILD` | ninja failed |
| `BLOCKED_TEE` | Secure world: out of scope by design |
| `EXHAUSTED` | Attempts exhausted. **Round count and elapsed time are not stop reasons** |

A stop auto-generates **`RESUME.md`**: how far it got (per rung), what was tried and whether each moved the
fingerprint, means not yet tried, the last round's log paths (console · kernel log · host lines), the resume command.
It does **not** name the runbook step: after resume the runbook's rule 1 re-judges from the rungs. **A stop is a
handoff, not giving up, and is resumable.** After resume, round numbers continue after the last number.

---

## Verification — the three gates

Only three things block the verdict. One purpose: **keep a console fabricated by the machine or an agent from
reading as a real boot.** The guest console verification reads is the **UART console + the memory-dump kernel log**;
QEMU host diagnostic lines are not evidence.

| # | Gate | What it blocks |
|---|---|---|
| 1 | Source negative | Fails if a string the built machine source prints appears on the console |
| 2 | Output source | The console's **fixed strings** must exist in the firmware images |
| 3 | Input source | Fails if the machine fills its own receive buffer (also any monitor command other than `pmemsave`) |

Chain PC trace · verification both ways · storage dual drive · bypass records are **measured and reported only**;
they never block reaching.

Verdict: **`VERIFIED`(출처 검증 통과)** / **`UNVERIFIED`(출처 검증 실패)**.

**The verification-bypass report is not a gate, but the verdict line must always carry it.** A bypass that changes
the firmware's verification result (mark F), a forged medium or an image modification adds:

```
VERIFIED (출처 검증 통과) · 검증 우회 N건 · verify_ok: reached_bypassed
```

### Rules that still hold

- **No speculative stubs**, above all adaptive toggles (change a value after N reads): they send the firmware down a wrong
  branch and do not reproduce on other firmware.
- **A bypass is labelled a bypass**: `06_machine/bypasses.md` with 대상 · 이유 · 방법 · **부작용**. 부작용 is the first
  thing consulted when later runs stall.
- **Record a point not reached as not reached.**
- **Never forge the verification result itself**: status words may be changed, but the return value and the failure
  output stay. **One exception only, a provisional one the user has not yet approved:** for firmware whose hash is
  computed by a hardware engine (static-analyzer derived it as `hash_engine` in `STATIC.md`), a comparison patch is
  allowed when engine modelling is not possible. It needs mark F · the verification-bypass ledger · `reached_bypassed`
  · the negative test all in place, and never applies to software-hash firmware (`CLAUDE.md` §11).
- **Never leave a bypass record's 부작용 empty.** `(기록 없음)` is invalid too.

---

## Old commands

This **replaces** `rehost-setup` and `rehost-full`. They were split because recognition and execution each needed a
user decision; both are now derived from state. **Only environment setup (`init`) stays separate**: the 18-minute QEMU
build differs in nature from a run and is done once however many firmware you process.

Four commands: **`init`** (environment, once) · **`start`** (run) · **`status`** (query) · **`export`** (kit).
