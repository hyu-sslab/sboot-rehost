---
name: export
description: 완성된 리호스팅을 "빌드 없이 바로 실행" 가능한 공유 키트로 내보낸다. active(또는 workdir=<id>) 워크스페이스의 목표 등급 완료를 확인한 뒤, examples/ 구조처럼 프리빌트 QEMU + 펌웨어/디스크 이미지 + machine 소스 + 스크립트 + docs + evidence 를 rehost_exports/<model>_<build>/<target>/ 에 조립. 이 폴더는 항상 gitignore. 생성 위치를 사용자에게 안내.
disable-model-invocation: true
---

You are the **export** orchestrator. When the user runs `/sboot-rehost:export` after reaching the sboot/kernel
goal, build a kit that **runs without building**.

- Target: the active workspace (or `workdir=<id>`).
- Output: `<cwd>/rehost_exports/<model>_<build>/<target>/` (one folder per grade).
- **Always gitignored** (prebuilt QEMU and firmware: size, copyright).

All text addressed to the user (progress, reports, questions, summaries, documents) is natural, formal Korean. Do not coin terms: use 정지점, 회차, 우회, 마일스톤, 도출; keep standard English terms such as fastboot, UART, MemoryRegion untranslated. The Step 5 template is Korean output: fill it with real values.

---

## Step 0 — Completion check (★ no export if incomplete)

Read `target` from INPUT.md (written by `start`) and verify that grade's **goal was reached**. Old workspace without
the slot or file: read `목표 등급` in the `PROGRESS.md` header; if absent too, do not guess: say
"목표 등급을 알 수 없다 — export 불가" and stop. Export only if **all three** hold:
1. **Gates 3/3 passed.** `VERIFICATION.md` says `VERIFIED`(출처 검증 통과). `UNVERIFIED`: say
   "출처 검증 실패 — export 불가" and stop.
2. **Target milestone reached.** Final rung: **F1**=last stage entry (plus the surface, if any), **F2**=`kernel_alive`,
   **F3**=`rootfs` mounted. Confirm from console, kernel log, VERIFICATION. Not reached: say "미완 — export 불가"
   and stop. (`kernel_entry` is only the bootloader's jump declaration, not F2's final rung.)
3. **State the verification-bypass count.** Read the first line of `VERIFICATION.md` and `verify_bypass` in
   `verdict_script.json`. **A count above 0 does not block export**: write the count in every kit document so the
   reach is stated honestly ("F2 (verify_ok 우회 N건)"). A `VERIFICATION.md` without the count is not complete.

If complete: `bash <PLUGIN>/scripts/journal.sh <WS> session-start "/sboot-rehost:export" "키트 생성 <target>"`.

## Step 1 — Decide the destination

- `model`/`build` = INPUT.md slots (else the workspace name `<model>_<build>`). Firmware key = `<model>_<build>`
  (`<model>_<id>` if build is unknown).
- `DEST = <cwd>/rehost_exports/<firmware>/<target>/`. If it exists, confirm before updating (overwrite warning).

## Step 2 — Assemble the kit (mechanical)

Prebuilt QEMU: `~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64`. Call `scripts/make_export.sh` with env
parameters:

```
WS=<workspace> DEST=<dest> \
QEMU=~/qemu-build/qemu-10.2.2/build/qemu-system-aarch64 \
MACHINE=<machine name> \
FAMILY=<soc_family from INPUT.md> \
[SURFACE=shell|none] [INPUT_CMD=help] \
[RUN_TIMEOUT_S=<time limit in seconds the rounds used>] \
[EUFS_LU_IMAGE=<synthesized medium lu0.img> EUFS_LBS=4096] \
[BUNDLE_FIRMWARE=0] \
bash <PLUGIN>/scripts/make_export.sh
```

`MACHINE` is the name the rounds passed to `-M`: the pipeline's `<slug>-full` (slug = model lowercased, alphanumerics
only; the pipeline's `machine` constant). INPUT.md has no slot for it. A wrong name makes QEMU miss the machine:
check `qemu-system-aarch64 -M help | grep <name>`. Pass `SURFACE=none` when the surface the static-analyzer derived
in `STATIC.md` is `none` (INPUT.md `bl_surface` may still be the start-time `unknown`).

Generates: `bin/` (prebuilt QEMU), `firmware/` (bootloader container + **synthesized medium lu0.img**), `machine/`
(machine.c or machine_kernel.c, `<hci>.c/.h`, `bypasses.md`), `scripts/` (patch, build), `evidence/`, turnkey
`run.sh` · `setup.sh` · `.gitignore`.

- **`run.sh` passes the synthesized medium** (`-drive …,id=lu0,snapshot=on`). The bootloader reads the next stage
  from the medium, so a container-only kit cannot reproduce the rounds.
- **`run.sh` runs under the rounds' conditions.** Other conditions stop the same firmware at another rung.
  - Time limit = the rounds' value: `RUN_TIMEOUT_S`, else `timeout_s` in the workspace `input_summary.json`, else
    the `run_full.sh` default of 200 s. A short limit (e.g. 20 s) ends before the chain reaches the kernel, so
    `kernel_alive` is unobservable in the kit. The recipient may override: `RUN_TIMEOUT_S=<s> bash run.sh`.
  - Mixed-architecture machine (`06_machine` source has `handoff_tick`): `-accel tcg,thread=single`, as in
    `run_full.sh` (handoff-watcher safety under multi-thread TCG is unknown).
  - Do not pass `-cpu`; the rounds do not, and the machine's default CPU applies. QEMU rejects a type the machine
    disallows, and a mixed machine creates its two CPUs itself. Pass `CPU=<type>` only when you **know** it is
    needed; a mixed machine never forwards it.
- `SURFACE=none` (no surface): `run.sh` types no command. `FAMILY=mediatek`: `scripts/build.sh` applies
  `patch_qemu_core.py --family mediatek` (that family cannot create an AArch32 CPU without the one `cpu.c` patch).
  If `FAMILY` is not given: old behavior (exynos set).
- With `memdump_plan.json`, include the memory-dump observer and run it in `run.sh` as the rounds do; without it,
  `kernel_alive` of firmware whose kernel log never reaches UART is unconfirmable in the kit. As `run_full.sh` does,
  export the region the machine must not write as `REHOST_MEMDUMP_REGION=<base>:<size>` to QEMU's environment (read
  from the plan). If the workspace has `kernel_task_regex.txt`, copy it to the kit's `scripts/` and pass it as
  `KERNEL_TASK_REGEX` (an explicitly set environment value wins).
- **Firmware cannot go in the kit (`BUNDLE_FIRMWARE=0`)**: copyright or size (e.g. a 9 GB synthesized medium).
  `firmware/` holds only `README.txt` and `SHA256SUMS` (container and medium hashes of the run). The recipient
  builds the same files from their own firmware; `run.sh` runs only after the hashes match and stops otherwise
  (`SKIP_SUM_CHECK=1` skips the check, but never claim that run matches the kit's recorded run). `lu_manifest.json` and
  `lu_provenance.json` in the kit root are the basis for rebuilding the medium.

`evidence/` holds **human-readable records and machine-readable measurements**:
`VERIFICATION.md` `ANALYSIS.md` `PROGRESS.md` `JOURNAL.md` `STATIC.md` `stage_map.json` `RESUME.md` `INPUT.md`;
console and summary logs; harness input records (`input_*.txt`, `input_summary.json`); the other channel files
(`kernel_*.log` merged memory dump, `host_*.txt` QEMU host lines — **not evidence**, `memdump_*.json`,
`reset_*.json`, `avb_negative.txt`); **`metrics.jsonl`** (time, tokens); **`rounds.jsonl`** (per-round fingerprint,
classification, fixer, effect); `blockers.jsonl`; `verdict_script.json` (script pass 1: three gates + reference
metrics + verification-bypass report); `analysis.json`.

**`make_export.sh` builds `ANALYSIS.md` by running `analyze_run.py`.** Time and token totals alone would make the
recipient read the jsonl, so compute what the records yield:

| Section | Question it answers |
|---|---|
| 2 | Time and tokens per phase |
| 3 | Which rounds took long (re-analysis and regeneration time separated) |
| 4 | Which stop point took the most rounds |
| 5 | Where observation stalled and what ended each stall |
| 6 | Distribution by classification and owner; share of changes that altered observation |
| 7 | Which changes actually advanced boot |
| 10 | Why it took long, in three terms: observation, cost, evidence |
| 11 | Limits of the record itself (duplicate numbers, missing measurements) |

**Large images (super/disk)**: copy by hand into `firmware/` what make_export could not add. Too large or
impossible: reassemble with `BUNDLE_FIRMWARE=0`. A synthesized medium outside the workspace: give its path via
`EUFS_LU_IMAGE`.

## Step 3 — Generate documents (docs/ + README + HOW-TO-RUN)

From the workspace JOURNAL, PROGRESS, bypasses, VERIFICATION and `rounds.jsonl`/`metrics.jsonl`, write `DEST/docs/`:
- `01_what-was-built.md` — what was rehosted (grade, reached point).
- `02_boot-chain.md` — stages executed and skipped.
- `03_trial-and-error.md` — JOURNAL trials (cause/analysis/resolution) + `rounds.jsonl` classification distribution
  and list of attempted changes.
- `04_timeline.md` — JOURNAL session times + **`ANALYSIS.md` sections 2, 3** (time and cost per phase, long
  rounds). Quote `ANALYSIS.md`; do not re-estimate.
- `07_cost-analysis.md` — from **`ANALYSIS.md` sections 4, 5, 7, 10**: which stop point took the most rounds, what
  ended the stalls, which change advanced boot, why it took long. Write it so it can be pasted into a paper or
  report.
- `05_bypasses.md` — `06_machine/bypasses.md` (`[대상/이유/방법/부작용]`).
- `06_verification.md` — **two-stage verification** of the three gates: **both** script pass 1
  (`verdict_script.json`) and verifier pass 2 (`VERIFICATION.md`); if they differed, say which won and why (an
  upward override needs byte evidence). **Include the `verify_bypass` count and signals.** Count above 0: write the
  reach as "F2 (verify_ok 우회 N건)" in every document (README, 01, 06), never shortened to "F2 도달". No negative
  test run: write "입증하지 못함".

`DEST/README.md` (overview, one-line run, a **"실행 비용과 소요"** section summarizing run cost and duration; keep
this exact Korean heading) and `DEST/HOW-TO-RUN.md` (prerequisites, run, rebuild). Write only what the records
support: no fabrication.

### Document writing rules (all of docs/, README, HOW-TO-RUN)

- Write in Korean per the language rule at the top; also use 부팅 깊이 for boot depth. No colloquialisms,
  exclamations or exaggeration.
- **Itemize**, no prose paragraphs: table for two or more comparable values, numbered list for order, otherwise
  bullets with a bold lead term.
- Cite a source file for every figure: not "오래 걸렸다" but "1 시간 40 분 (`ANALYSIS.md` 5 절)".
- Mark what you could not confirm as unconfirmed; never fill a gap with a guess.

## Step 4 — Ensure gitignore (★ always)

Write `*` to `<cwd>/rehost_exports/.gitignore` so **all of exports is untracked**:
```
bash -c 'mkdir -p "<cwd>/rehost_exports"; printf "*\n" > "<cwd>/rehost_exports/.gitignore"'
```
(make_export also puts a `.gitignore` for bin/ firmware/ *.img inside the kit.)

## Step 5 — Notify (★ announce the created location)

Show the user:

```
== export 완료 ==
생성 위치:  <cwd>/rehost_exports/<firmware>/<target>/     (git 미추적)
포함:  bin/qemu-system-aarch64 (프리빌트) · firmware/ · machine/ · scripts/ · docs/ · evidence/ · run.sh
바로 실행(받는 사람):  cd <경로> && bash run.sh     (오류 시 bash setup.sh 먼저)
공유:  이 폴더를 zip/복사로 전달 (git 에는 안 올라감).
같은 펌웨어를 다른 등급으로:  그 워크스페이스를 active 로 두고 /sboot-rehost:export.
```

`journal.sh <WS> session-end "/sboot-rehost:export" "키트 -> rehost_exports/<firmware>/<target>"`.

---

## Honesty

- **No export if incomplete** (gates 3/3 not passed, target milestone not reached, or the bypass count missing from
  the records). Never disguise incomplete as complete.
- **Never present a run with verification bypasses as one without**: the count goes in every document.
- docs/evidence only from actual JOURNAL, VERIFICATION and console evidence; invent no results.
- The export folder is always gitignored (firmware copyright, size); always tell the user where it was created.
