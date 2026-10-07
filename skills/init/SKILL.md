---
name: init
description: 설치 후 1회 실행하는 환경 구축 명령. 옛 환경(플러그인 캐시, 옛 QEMU, 임시 파일)을 먼저 정리해 최신 상태를 보장하고, QEMU 10.2.2 기준 빌드와 의존성(capstone·ninja·dtc·lz4·simg2img)을 환경 매니페스트에 맞춰 설치하며, 작업 루트 rehost_workspaces/ 와 펌웨어 드롭 폴더 _inbox/ 를 만든다. 지운 것은 경로와 크기로 보고한다. --clean 은 L1~L3 를 조건 없이, --wipe-workspaces 는 작업 기록을 보관 폴더로 옮긴다. QEMU 빌드가 약 18 분 걸리므로 실행 명령과 분리돼 있다. 끝나면 사용자가 _inbox/ 에 펌웨어를 넣고 /sboot-rehost:start 를 부른다.
disable-model-invocation: true
---

You are the **environment setup** orchestrator. Run once.

```
/sboot-rehost:init [--clean] [--wipe-workspaces] [--replace-unmarked]
```

All text addressed to the user (progress, reports, questions, summaries, documents) is natural, formal Korean. Do not coin terms: use 정지점, 회차, 우회, 마일스톤, 도출; keep standard English terms such as fastboot, UART, MemoryRegion untranslated. The report templates below are Korean output: fill them with real values.

| Arg | Meaning |
|---|---|
| (none) | Clean only what is **proven old**; if the environment matches the manifest, check and finish |
| `--clean` | Delete L1~L3 **unconditionally** and rebuild (unmarked items are still never deleted) |
| `--wipe-workspaces` | L4: **move** (not delete) `rehost_workspaces/<id>` to `rehost_workspaces/_archive/<id>_<timestamp>` |
| `--replace-unmarked` | **Move aside** (not delete) an unmarked QEMU tree, then build fresh |

## Why it is separate from the run command

The QEMU 10.2.2 build takes **about 18 minutes**; inside `start` the user would wait 20 minutes blind. The
environment is built once and reused for every firmware, so it is split off. **No need to call it again from the
second firmware on**: a matching environment is only checked, then it finishes.

## What "clean and current" means

Stops runs on a stale environment (old QEMU, tools, cache). Judge by the **environment revision**, not the plugin
version: the version rises on doc-only edits, and an 18-minute rebuild each time is unwarranted.

| File | Location | Content |
|---|---|---|
| Required `env_manifest.json` | inside the plugin | `env_revision`, QEMU version, pip minimum versions, required tools |
| Current `~/.sboot/env.json` | user's Linux side | at build: `env_revision`, QEMU and pip versions, timestamp, plugin version, **`created_by: sboot-rehost`** |

| Layer | Target | Default | `--clean` |
|---|---|---|---|
| **L1** plugin | old version folders in the cache, `__pycache__` | delete (keep only the latest) | same |
| **L2** toolchain | tree and tarball in `~/qemu-build`, `env.json`, pip modules init installed | delete and rebuild **only on manifest mismatch** | delete unconditionally |
| **L3** temp/derived | `/tmp/sboot_*`, `~/rehost/_traces/run_*.log` | only those last modified over 1 hour ago | all |
| **L4** workspace | `rehost_workspaces/<id>` | **keep.** Only report old-version ones (`.sboot_version` differs or missing) | move to archive only with `--wipe-workspaces` |

**Delete only what has a marker:** tree `.sboot_created`, tarball `<tarball>.sboot_created`, `env.json`
`created_by`. No marker: report `skipped_no_marker` and **never delete, whatever the args** (a user-installed QEMU
must survive).

---

## Step 0 — Remove old versions first (L1, never skip)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/purge_cache.sh"
```

The cache keeps a folder per version. An old one can reload old skills, agents and scripts, and then rounds, logs
and verdicts follow old rules (seen here: `0.2.0` and `0.17.0` left over, the session loaded `0.17.0` while the
repo was `0.24.0`). The script **keeps only the latest, deletes the rest** and also deletes `__pycache__`.

| Exit code | Meaning | Action |
|---|---|---|
| `0` | cleaned to latest | go to Step 1 |
| **`1`** | **session is loading an old version** | **Stop here.** Show the notice below, then end |
| `2` | cannot decide (dev checkout, etc.) | state the fact and proceed |

> **Deleting the cache does not change what is already loaded** (the session keeps its start-time copy). On exit
> code 1 you **must stop here**: reporting "cleaned" while running old code is the worst outcome. Also warn that
> if the deleted version is the one this session uses, commands may not work until restart.

```
== 옛 버전을 지웠습니다 — 재시작이 필요합니다 ==
| 지운 버전 | 0.2.0, 0.17.0 |
| 남긴 버전 | 0.24.0 |
| 이 세션   | 0.17.0 을 로드 중 (지워짐) |

  /plugin marketplace update sboot-rehost-marketplace
  /plugin install sboot-rehost@sboot-rehost-marketplace
  → Claude Code 재시작 후 /sboot-rehost:init 을 다시 부르세요
```

## Step 1 — Version gate

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check_version.sh"
```

## Step 2 — Environment comparison and preflight (read-only, before deleting)

**Find blockers before deleting.** Step 3 really deletes L2·L3·L4; a later sudo or unmarked-tree block would
leave the user without the tree and `env.json`. So check here, and if blocked **do not start Step 3.** This step
changes nothing (Step 0's L1 is already done).

### 2a. Manifest comparison

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/clean_env.sh" --status
```

| `status` | Meaning | Then |
|---|---|---|
| `ok` | marker and `env.json` match the requirement, build output exists | no rebuild (check only) |
| `incomplete` | marker matches, build unfinished | **resume** the build in that tree |
| `stale` | marker present but `env_revision` or QEMU version mismatch, or no output | delete, then **rebuild** |
| `missing` | no tree | **build fresh** |
| `unmarked` | tree without marker (user-installed, or made by an old `setup_env.sh`) | **do not delete.** See 2c |

If `pip_outdated` is present, only those modules are reinstalled (QEMU stays). With `--clean`, Step 3 deletes the
tree even when `status` is `ok`, so **rebuild.**

**Announce a rebuild before starting** (`status` not `ok`, or `--clean`).

```
== QEMU 를 다시 만듭니다 ==
| 이유   | <status 의 reasons, 또는 --clean> |
| 소요   | 약 18 분 (백그라운드) |
```

### 2b. Will the install step run?

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check_env.sh"
```

| Condition | Preflight of 2c |
|---|---|
| `--clean` given · `status` not `ok` · `check_env.sh` says `ok: false` | **do it** (`setup_env.sh` runs in Step 4) |
| none of the three (environment already matches) | skip: nothing to install, so no sudo needed |

### 2c. Preflight (installs nothing)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup_env.sh" --dry-run [--replace-unmarked]
```

| Exit code | Meaning | Action |
|---|---|---|
| `0` | `action` is `reuse`·`resume`·`rebuild`·`fresh` | go to Step 3 |
| **`4`** | **unmarked QEMU tree** (`blocked_unmarked`) | **Stop here.** Show the notice below, then end. **Do not run Step 3** |
| **`7`** | **apt install needed but `sudo` does not work without a password** (`BLOCKED_ENV`) | **Stop here.** Show the notice below, then end. **Do not run Step 3** |

- Use only the stop decision (exit code 4·7) and `apt` from this pre-delete check. Plan JSON `action` ·
  `rebuild_minutes` can differ from the real rebuild under `--clean`; report rebuild and time from the 2a
  announcement and `l2.rebuild_needed` after Step 3.
- On stop, **no cleanup (L2·L3·L4) or install has started.** After clearing the blocker the user calls `init`
  again with the same args; it restarts in the same order.
- **The "지운 것" row of a stop report is real output, not a fixed sentence.** Step 0's L1 may already be deleted:
  `removed_detail` · `pycache_detail` of `purge_cache.sh` give paths and sizes. If Step 3 already ran, add its
  `removed` · `archived`. Write "없음" only if nothing was deleted.

Exit code 4: no evidence this plugin made the tree. Report it, do not delete it.

```
== 출처 불명의 QEMU 트리가 있습니다 ==
| 위치   | ~/qemu-build/qemu-10.2.2 (표지 없음) |
| 조치   | 이 트리를 지우지 않았습니다. 정리(L2·L3·L4)와 설치도 시작하지 않았습니다 |
| 지운 것 | <Step 0 의 removed_detail 경로·크기 / 없음> |

옛 setup_env.sh 가 만든 것이 맞다면, 옆으로 옮기고(삭제 아님) 새로 만듭니다:
  /sboot-rehost:init --replace-unmarked
옮긴 트리는 ~/qemu-build/qemu-10.2.2.unmarked.<시각> 에 그대로 남습니다.
```

Without `--replace-unmarked`, **do not move it yourself**; with it, continue with `setup_env.sh --replace-unmarked`.

Exit code 7 exists because init **runs in the background**: a password-asking `sudo` would hang unseen for 18
minutes. Before any install or delete, when not root and apt packages are needed (`dpkg-query`), `setup_env.sh`
tests `sudo -n true`; if blocked it stops with exit code 7 **before installing or deleting anything**. init runs this
check before Step 3's deletion, so L2, L3 and L4 stay untouched. `--dry-run` runs the same check. Do not ask via `AskUserQuestion`: the user runs one terminal
command and calls init again (installed apt packages are skipped without sudo).

```
== sudo 가 비밀번호를 요구합니다 — 정리도 설치도 시작하지 않았습니다 ==
| 이유   | sudo -n true 실패 (비밀번호 필요) |
| 조치   | L2·L3·L4 정리(Step 3)와 설치를 시작하지 않았습니다 |
| 지운 것 | <Step 0 의 removed_detail 경로·크기 / 없음> |

터미널에서 한 번만 실행한 뒤 /sboot-rehost:init 을 다시 부르세요:
  sudo apt-get update && sudo apt-get install -y <setup_env.sh 가 출력한 패키지 목록>
```

Copy the apt-get line as is (it lists **only missing packages**). Pre-entering a password with `sudo -v` may not
carry to another terminal (`timestamp_type`), so run the apt-get line directly.

## Step 3 — Cleanup (L2 · L3 · L4)

**Only if Step 2 did not stop.** From here it really deletes. With `--clean` or `--wipe-workspaces`, **show the
list and sizes first.**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/clean_env.sh" --dry-run [--clean] [--wipe-workspaces] \
     --workspaces-root "<cwd>/rehost_workspaces"
```

Then run for real (same args minus `--dry-run`).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/clean_env.sh" [--clean] [--wipe-workspaces] \
     --workspaces-root "<cwd>/rehost_workspaces"
```

It prints one JSON, the basis of the report: copy **this output**, not what you wrote in a reply.

| Key | Content |
|---|---|
| `removed` | deleted `{path, bytes, layer}` (pip module: `pip:<name>`, bytes `null`) |
| `kept` | kept, with reason |
| `skipped_no_marker` | **not deleted for lack of a marker**, with reason |
| `workspaces_old` | workspaces made by an old version (report only) |
| `archived` | moved by `--wipe-workspaces` `{from, to, bytes}` |
| `failed` | could not delete: **report, never hide** |
| `l2` | manifest comparison result (`status_after`, `rebuild_needed`) |

- Exit code `1` with `needs_restart`: same as Step 0's restart notice. Stop.
- L4 is a **move, not a delete.** Leave `_inbox/` and `_archive/` alone.
- **Finish before starting the rebuild**, so L3 cleanup cannot delete the background build log
  (`/tmp/sboot_setup.log`).

## Step 4 — Rebuild (only when needed)

Re-check after Step 3 (cleanup may have removed the tree).

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check_env.sh"
```

| Result | Action |
|---|---|
| `ok: true` | report "환경 OK" and go to Step 5 |
| problem found | run `setup_env.sh` as below |

**The exit 4·7 preflight was done in Step 2c;** do not repeat `--dry-run`. `setup_env.sh` re-checks at start as a
safety net only. If sudo changed meanwhile and it stops (exit 7, in `/tmp/sboot_setup.log`), Step 3 has already
deleted, so **put Step 3's `removed` · `archived` in the report as is.** If Step 2b skipped the preflight and a
problem shows here (not the normal flow), run `setup_env.sh --dry-run` now; on exit 4 or 7 stop as in Step 2c and
include what Step 3 deleted.

Otherwise **announce the 18 minutes**, run `setup_env.sh` in the **background**, and report the **real PID**.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup_env.sh" [--replace-unmarked] > /tmp/sboot_setup.log 2>&1 &
echo "PID $!"
```

What `setup_env.sh` does:

| Phase | Content |
|---|---|
| Decide | same decision as `clean_env.sh --status`: on `ok`, QEMU is not rebuilt |
| Install | apt (missing packages only; `sudo` if not root, exit code 7 **before starting** if a password is needed), pip (install at the manifest minimum, then **re-read the real version and enforce it**) |
| QEMU | **pristine build, no patches.** Core patches differ per family; Build in `start` applies them |
| tarball | beside the tree; source for Build's tree reset (`qemu_tree.sh reset`) |
| Record | `.sboot_created` in the tree; `~/.sboot/env.json` at the end |

What gets installed:

| Tool | Use |
|---|---|
| `qemu-system-aarch64` 10.2.2 | run the machine |
| `ninja` · `meson` | rebuild the machine (every round) |
| `capstone` | disassembly: derive addresses and structure |
| `dtc` / `fdtdump` | parse DTB (F2 and up) |
| `lz4` | unpack the BL package's `.lz4` |
| `simg2img` | AP sparse image to raw (F2 and up) |

On a Windows shell, `wsl_bridge.sh` switches to WSL; bulk writes go to WSL ext4.

## Step 5 — Work folder

```bash
mkdir -p <cwd>/rehost_workspaces/_inbox
cp "${CLAUDE_PLUGIN_ROOT}/scripts/inbox_readme.txt" \
   <cwd>/rehost_workspaces/_inbox/DROP_FIRMWARE_HERE.txt
```

- The work root is **under the current folder (cwd).** Do not invent a path.
- **Do not overwrite if it exists** (it may hold other firmware's work).
- `_inbox/` stays after `--wipe-workspaces` moves workspaces.
- All of it is `.gitignore`d, so running inside the plugin repo does not mix it into git.

## Step 6 — Completion report

Report **deleted (path, size), not deleted (reason), kept (one line).** Copy Step 0's `removed_detail` ·
`pycache_detail` (L1 was deleted in Step 0, so Step 3's JSON omits it) and Step 3's JSON; invent nothing.

```
== 환경 준비 완료 ==
| 작업 루트 | <cwd>/rehost_workspaces/ |
| 드롭 폴더 | <cwd>/rehost_workspaces/_inbox/  ← 여기에 펌웨어를 넣으세요 |
| 환경      | env_revision <N>, QEMU 10.2.2  (OK / 백그라운드 설치 중 — PID <pid>, 약 18분) |

지운 것 (총 <크기>)
| 층 | 경로 | 크기 |
| L1 | ~/.claude/plugins/cache/.../sboot-rehost/0.17.0 | 3.1 MB |
| L2 | ~/qemu-build/qemu-10.2.2 (env_revision 0 < 1) | 1.9 GB |
| L3 | /tmp/sboot_setup.log | 12 KB |

지우지 못한 것 / 지우지 않은 것
| ~/qemu-build/qemu-10.2.2.unmarked.20261005T101500 | 표지 없음 — 이 플러그인이 만든 것으로 확인되지 않음 |

남긴 것
| 워크스페이스 2 건 (옛 버전 1 건: <id> — .sboot_version 없음) | --wipe-workspaces 로 보관 이동 가능 |

다음:
  1) 펌웨어(.zip / BL_*.tar.md5 / AP_*.tar.md5)를 _inbox/ 에 넣으세요
  2) /sboot-rehost:start          (목표 등급 기본 F2)
```

If the install still runs in the background, **say so.** `start` stops with `BLOCKED_ENV` on an unready
environment, so call it after the install ends.

---

## Honesty

- **Create folders under the real cwd;** a reported path must exist.
- **The PID is real.** Without it the user cannot check progress.
- **Do not report the old-cache deletion and move on.** Exit code 1 stops.
- **Never delete what has no marker**, even with `--clean`; report it with the reason.
- **Never silently delete work records.** L4 is report-only by default; `--wipe-workspaces` moves.
- **Announce a rebuild before it starts.** Never spend 18 minutes silently.
- **Never start a background job that waits for a password.** On `--dry-run` exit code 7, do not launch the
  install: tell the user the command, then finish. Do not ask.
- **Find blockers before deleting** (Step 2c precedes Step 3). A stop report copies what was **actually
  deleted** (Step 0's old cache; Step 3's `removed` · `archived` if it ran), never the fixed sentence
  "아무것도 지우지 않았습니다".
- **Create neither a workspace nor `INPUT.md`.** That is `start`'s job once it has firmware; without it you leave
  a target-less shell. (`start` also writes the workspace's `.sboot_version` marker, which L4 uses to spot old
  ones.)
