/*
 * pipeline.js - unified sboot-rehost execution pipeline.
 *
 * One chain, one skeleton. What varies between firmwares is the derived stage
 * map: how many stages exist, which of them can execute, and where each loads.
 *
 *   [static-analyzer] derive facts
 *        |
 *   +-- LOOP (per goal) --------------------------------------------------+
 *   | (run_round.sh) snapshot + run + fingerprint + provenance gate +      |
 *   |                stop conditions, merged into ONE observation document |
 *   | [supervisor]            -> routing / stop                            |
 *   |   |- goal reached  -> next rung or verification                      |
 *   |   |- stop          -> structurally unreachable                       |
 *   |   |- escalate      -> [static-analyzer] re-derive                    |
 *   |   +- otherwise     -> [fault-classifier] -> [fixer] one change       |
 *   |                       -> (check_change verify) -> (ninja)            |
 *   +---------------------------------------------------------------------+
 *        |
 *   (verify_prep.py) -> (verify.py stage 1) -> [negative round on a damaged
 *   medium copy, F2+ and only after a passing stage 1] -> (verify.py again)
 *        |
 *   [verifier stage 2] -> VERIFIED | UNVERIFIED  (+ verification-bypass count)
 *
 * Goal advancement is decided by MEASUREMENT, not by the supervisor's claim:
 * only a milestone that the run script observed (and that passed the
 * provenance gate) moves the ladder forward.
 *
 * Round count and elapsed time are never stop reasons. runtime_round_cap is a
 * runtime limit, not a verdict, and the run resumes where it left off.
 *
 * One chain, one run. The container is loaded once and every stage after the
 * first is reached by the firmware's own code, so there is no track parameter:
 * `target` alone says how far up the chain to go (F1 / F2 / F3).
 *
 * Family kit. soc_family picks a profile, and the profile names the family's own
 * knowledge tables and run guide (scripts/family_kit.py, the only reader). Both
 * are put into EVERY delegated prompt as `Family knowledge:` and `Runbook:` - as ABSOLUTE
 * paths, because an agent's working directory is not the plugin root - so a new family
 * is a profile line, not a prompt edit.
 *
 * Family-neutral paths. The scripts that carry a per-family default (build_lu.py: the default
 * layout and the command-line fallback; carve_disasm.py: the string and size yardsticks) are always
 * told --family, narrowed to exynos | mediatek | generic (familyFlag), so a vendor default reaches
 * only the family it was derived for. The UFS storage skeleton is offered by medium and family, and
 * an undecided carve verdict (carve_is_full null) goes on, journaled as undetermined: only false stops.
 *
 * One apply step. A specialist's change and the last-resort fixer's both go through applyChange:
 * check_change.sh verify, restore on a violation, sync, ninja, record - a rejected change is rolled
 * back and recorded as reverted, never counted as a move. A fixer that cannot settle a question
 * answers no_new_change with the question in `rationale`; the next escalation is handed it as FOCUS.
 *
 * Goal ladder. Every rung has a state: reached / reached_bypassed / not_reached.
 * `reached_goals` lists only rungs the run observed; a rung the loop stepped over
 * because a higher one was observed is `passed_over`, not reached. The surface
 * rung is optional: a bootloader that boots on without input (surface "none")
 * gets no surface rung, and BLOCKED_NO_INPUT_PATH is raised only when a round is
 * OBSERVED waiting for input.
 *
 * args: {
 *   workdir, target (F1|F2|F3), model, plugin_dir,
 *   bootloader_path     (the bootloader container; bl3_path also accepted),
 *   soc_family, bl_surface (shell|fastboot|none), has_super,
 *   arch                (arm32|arm64 wins and is journaled as given; absent, "auto" or "unknown"
 *                        are derived with stage_map.py --detect-arch - see the Analyze phase),
 *   runtime_round_cap   (default 120 - runtime limit, not a stop reason; it counts the rounds
 *                        THIS invocation runs - a resumed workspace numbers its rounds on from
 *                        the highest one it already holds, so earlier logs are never overwritten),
 *   max_exceptions      (default 0 = off: cut a round once its trace holds this many exceptions),
 *   negative_test       (default true: after a passing verification, one more round on a
 *                        medium with a byte flipped - see Verify for the cost),
 *   input_wait_rounds / input_wait_min_polls   (see waitingForInput),
 *   invoked_with        (the user's own words, recorded verbatim; see Analyze),
 * }
 */

export const meta = {
  name: 'pipeline',
  description: 'sboot-rehost 통합 파이프라인 — 도출 → 빌드 → (실행·분류·수정)* → 출처 검증 → 재현 키트',
  phases: [
    { title: 'Analyze', detail: 'static-analyzer 사전 도출 (하드 블로커 검사)' },
    { title: 'Build',   detail: 'machine 소스 생성 + ninja' },
    { title: 'Loop',    detail: '목표 사다리마다 실행 → 분류 → 한 변경' },
    { title: 'Verify',  detail: 'verify.py 측정 → verifier 재검증' },
    { title: 'Package', detail: '재현 키트' },
  ],
}

// --- arguments ---------------------------------------------------------------
// Backslashes in a Windows path are escape characters to bash, so every path we
// interpolate into a command is normalised to forward slashes first. Both Git
// Bash and WSL accept that form, and wsl_bridge.sh translates C:/... to /mnt/c.
function posix(value) {
  return typeof value === 'string' ? value.replace(/\\/g, '/') : value
}

const workdir   = posix(args?.workdir)
const model     = args?.model
// bl3_path is the pre-0.10 name. BL3 is ARM/Exynos wording and reads wrong for a
// MediaTek LK image, so the slot is bootloader_path now; both are accepted.
const bootloader_path = posix(args?.bootloader_path ?? args?.bl3_path)
const target    = String(args?.target ?? 'F2').toUpperCase()
const socFamily = String(args?.soc_family ?? 'generic').toLowerCase()
// The architecture is DERIVED, never assumed (CLAUDE.md section 7, rules 3 and 4). An explicit
// `arch` wins and is journaled as given. Absent, "auto" or "unknown" mean "derive it": Analyze
// runs `stage_map.py --detect-arch` on the container, and an answer of "unknown" is not
// replaced by a default. The stage-map tool is then run under BOTH readings (arm32 and arm64)
// and the reading that finds an entry signature is used - PROVISIONALLY, because detect-arch
// itself could not decide. No signature under either reading, one under both, or a reading that
// could not be run at all is BLOCKED_ARCH (naming the detect-arch basis); no reading is ever
// chosen by default. The signature is read from the tool's exit code (arm32: 3 = none) and its
// entry_stubs list (arm64, which never exits 3), not from what an analyst reports.
const ARCHES    = ['arm32', 'arm64']
const archInput = String(args?.arch ?? '').trim().toLowerCase()
const archGiven = ARCHES.includes(archInput)
let arch        = archGiven ? archInput : 'arm64'   // provisional until Analyze has decided
let archUnresolved = false      // detect-arch could not decide: `arch` above is not a derivation of its
let archBasis   = []            // detect-arch's own evidence lines, for the log and BLOCKED_ARCH
let archProbe   = null          // what stage_map.py found under each reading, once detect-arch was unknown
const PLUGIN    = posix(args?.plugin_dir) ?? '${CLAUDE_PLUGIN_ROOT}'
// Agents do not run with the plugin root as their working directory, so a path they are
// told to READ (a knowledge table, the runbook, a template, the registry) is joined with the
// plugin root here. family_kit.py's own JSON stays plugin-relative; the join is this file's.
const PLUGIN_ROOT = String(PLUGIN).replace(/\/+$/, '')
const abs = rel => (/^([A-Za-z]:)?\//.test(String(rel)) ? String(rel) : `${PLUGIN_ROOT}/${rel}`)
// The cap counts the rounds run by THIS invocation (see the Loop): a resumed workspace
// numbers its rounds on from the earlier ones, and a cap on the absolute number would stop
// every re-run at once.
const ROUND_CAP = Number(args?.runtime_round_cap ?? 120)
// Wall-clock budget per round. It is a property of how long this firmware takes
// to walk to its surface, not a constant: on S921N the prompt landed between 5.2
// and 8.0 seconds of wall time, so the old fixed 8 made reaching it a coin flip.
const RUN_TIMEOUT = Number(args?.run_timeout_s ?? 200)
// A round is cut short once its trace holds this many exceptions. Off by default: a
// round then runs to its timeout, as it always did. The MediaTek kit spent three hours
// inside one exception storm, which is what this exists for - opt in with a number.
const MAX_EXCEPTIONS = Number.isFinite(Number(args?.max_exceptions))
  ? Math.max(0, Math.floor(Number(args?.max_exceptions))) : 0
// After a passing verification, one more round on a medium with a byte flipped (see
// Verify). It costs a round and a copy of the medium, so it can be switched off - and
// when it is, the report says the firmware's own verification is unproven.
const NEGATIVE_TEST = args?.negative_test !== false
// A negative round must never share a number with a real round: its files would
// overwrite that round's, and a verifier looking for "the latest round" would pick
// it. Far above ROUND_CAP, so the two cannot meet.
const NEGATIVE_RUN_BASE = 9000
// A round counts as "waiting for input" only after this many consecutive rounds did,
// and only when the firmware polled the console at least this many times. One poll
// at boot is a key check, not a wait - so the default errs towards going on: a false
// stop on "no input path" ends a run that a fixer could still have moved.
const INPUT_WAIT_ROUNDS = Math.max(1, Number(args?.input_wait_rounds ?? 2))
const INPUT_WAIT_MIN_POLLS = Math.max(1, Number(args?.input_wait_min_polls ?? 1000))
// What the user actually asked for, in their words. Recorded verbatim rather
// than summarised: when a run stalls weeks later, the direction someone gave and
// the reason they gave it are the first things missing from the log, and a
// paraphrase of a prompt is not the prompt.
const INVOKED_WITH = String(args?.invoked_with ?? '').trim()
// How many times a round may be re-run when the input path never reached the
// gate. That is a harness failure, so classifying it would spend a fixer on a
// fault that does not exist - but retrying forever is its own trap, so it is
// bounded and what was dropped gets logged.
const STARVED_RETRIES = Number(args?.starved_retries ?? 2)

// One accumulating record per firmware. The analyst appends to it, the
// classifier and the fixers read it. Everything derived about this target lives
// here so a finding made in round 5 is still available in round 40.
const staticDoc = `${workdir}/STATIC.md`
// The derived stage map: which stages exist, which can execute, where each one
// loads and where it starts. Build reads it to place the stages; the ladder is
// built from it; a build-layer stop point is corrected against it.
const stageMap  = `${workdir}/stage_map.json`

// The bootloader's interactive surface. A UART shell is only one kind: MediaTek
// LK has an output-only UART, so its reachable surface is fastboot over USB - or, on a
// phone image that logs and boots on, none at all. `none` is a legitimate answer
// (autoboot), not a blocker: the ladder simply has no surface rung.
// Undeclared means static-analyzer decides.
const SURFACES = ['shell', 'fastboot', 'none']
const declaredSurface = String(args?.bl_surface ?? '').toLowerCase()
const surface = SURFACES.includes(declaredSurface) ? declaredSurface : 'shell'
const surfaceDeclared = SURFACES.includes(declaredSurface)

if (!workdir || !model) {
  log('오류: pipeline.js 는 args.workdir 와 args.model 이 필요합니다.')
  return { error: 'missing_args' }
}
if (!bootloader_path) {
  log('오류: args.bootloader_path (구 bl3_path) 가 필요합니다 — 부트로더 컨테이너가 체인의 출발점입니다.')
  return { error: 'missing_bootloader_path' }
}

const slug = model.toLowerCase().replace(/[^a-z0-9]/g, '')
const machine = `${slug}-full`

// The ladder has as many stage rungs as this firmware has EXECUTABLE stages,
// and that count is derived - `stage_map.json` decides it, not this file. A
// container with three runnable stages gets three rungs; one with two gets two.
// Fixing the count here is what made the old design vendor-specific.
//
// Above the stage rungs the chain is the same everywhere, because each rung is
// defined by what the firmware DOES rather than by what it is called:
//   <surface>       the bootloader's interactive surface is reachable (optional:
//                   none for a bootloader that boots on without input)
//   medium_up       its own storage driver brought the boot medium up
//   partitions      it enumerated the partition table from that medium
//   verify_ok       its own verified boot passed on an intact image
//   kernel_entry    it loaded and jumped to the kernel
//   userspace       the kernel reached init
//   partitions_up   the kernel's driver enumerated partitions on the SAME model
//   super_mounted   only exists for firmware that ships a super image
const hasSuper = args?.has_super === true

// Replaced the moment the analyst reports the derived map. Until then one
// placeholder rung keeps the loop pointed at something rather than at nothing.
let stageRungs = ['stage_entry']

// The ladder is also a function of the surface, because static-analyzer may
// correct the surface after this point and the goals must follow that correction
// rather than force a re-run.
// `kernel_entry` is the bootloader announcing the jump; `kernel_alive` is the
// kernel showing itself - its banner first, else a line only a running kernel can
// print (see the milestone-token instructions). They are separate rungs because a
// kernel that never executes leaves `Starting kernel...` as the last line of the
// console - counting that as arrival reports a boot that did not happen.
// The surface rung is optional: with surface "none" the stage entries lead straight
// into the common tail, and `autoboot` is recorded instead (see autobootState).
function goalsFor(surfaceName) {
  const f1 = surfaceName === 'none' ? stageRungs.slice() : stageRungs.concat([surfaceName])
  const f2 = f1.concat(['medium_up', 'partitions', 'verify_ok',
                        'kernel_entry', 'kernel_alive'])
  const f3 = f2.concat(['userspace', 'partitions_up'],
                       hasSuper ? ['super_mounted'] : [])
  return ({ F1: f1, F2: f2, F3: f3 })[target] || f2
}

let activeSurface = surface
let goals = goalsFor(activeSurface)
let ladderArg = goals.join(',')

// One chain, one fixer set. The old split existed because a bootloader run had
// no storage model and a kernel run had no bootloader; here both are in the same
// image, so every specialist is reachable and filtering one out would leave a
// real stop point with no owner.
const KNOWN_FIXERS = ['fixer-memory', 'fixer-el3', 'fixer-bootflow',
                      'fixer-secureboot', 'fixer-storage', 'fixer-kernel']

// One classification table for the whole chain. Its 위치 column is what keeps a
// kernel class from being named while the run is still in the first stage.
// These three are common to every family; the family's own tables (the profile's
// `knowledge:` list, read through family_kit.py) are added once the family is known,
// so KNOWLEDGE is a value composed in Analyze rather than a constant.
const COMMON_KNOWLEDGE = ['knowledge/faults_unified.md', 'knowledge/faults_storage.md',
                          'knowledge/kernel_gates.md']
let KNOWLEDGE = COMMON_KNOWLEDGE.map(abs).join(', ')

// The family kit: what the profile names for this firmware's family. `family` is the
// profile that was actually read (an unknown name falls back to generic), and the two
// lists are put into every delegated prompt by familyContext(). Empty until Analyze
// has read the profile, and empty for a family whose profile names nothing.
let familyName = socFamily
let familyKnowledge = []
let familyRunbook = ''
let familyProfile = `profiles/${socFamily}.yaml`
// memdump_plan.json exists, so the memory-dump channel is on: once it does, nothing more is
// asked of the console. Until then it is derived from the first bootloader log that names
// the ring (a runtime artifact - no static analysis can see it). See the Loop.
let memdumpPlanKnown = false

// Last resort. Not in KNOWN_FIXERS: it is reached only after a specialist has
// declined, never by ranking, so that the widest scope stays the exception.
const GENERAL_FIXER = 'fixer-general'

// House style for every document a human reads. Appended to each prompt that
// writes one, so the rule lives in one place instead of being restated - and
// drifting - in five.
const DOC_STYLE =
  `\nDocument style (every document a human reads):\n` +
  `- All text addressed to the user (progress, reports, questions, summaries, documents) is natural, formal ` +
  `Korean, as in a report: no colloquial tone, no exclamations.\n` +
  `- **Do not coin terms.** Use standard industry terms or this repository's own: 정지점, 회차, 우회, ` +
  `마일스톤, 부팅 깊이, 도출. A coined term tells the reader nothing and names one thing differently in each ` +
  `document. Keep standard English terms such as fastboot, UART, MemoryRegion untranslated.\n` +
  `- **Itemize.** No runs of prose: use tables, lists, subheadings. Two or more values to compare: a table; ` +
  `a sequence: a numbered list; anything else: bullets with a bold lead.\n` +
  `- Cite the source file for every number: not "오래 걸렸다" but "1시간 40분 (rounds.jsonl)".\n` +
  `- Say what you could not confirm. Never fill a blank with a guess.\n`

/* The rules every fixer shares - the six specialists and the last-resort fixer - written ONCE and appended
 * to every fixer prompt (the specialist loop and runGeneralFixer), the way DOC_STYLE is appended to a prompt
 * that writes a document. agents/fixer-*.md keep only what is specific to one fixer, and each says so in one
 * line. The text is spelled out in full, never cited by number or by file: the plugin's CLAUDE.md is not
 * visible to a subagent, and a prompt is always read where a pointer to a file may be skipped. No value of
 * any firmware belongs in it (no address, no partition name). It is one run of single-quoted literals with
 * no blank line, so tests/pipeline_sim/fixer_rules.js can evaluate it alone: family_kit.sh and canon.sh pin
 * its wording through that, and scenarios_neutral.js (V6) checks that every fixer prompt carries it whole. */
const FIXER_RULES =
  '\nRules every fixer follows - the six specialists and the last-resort fixer share this one text, and your ' +
  'agent file keeps only what is specific to you. A change that breaks one of them is rolled back at the gate ' +
  'or does not count as a round.\n\n' +
  'Family knowledge and the runbook for this target\'s family are provided by the pipeline in this prompt ' +
  '(the `Family knowledge:` and `Runbook:` lines, as absolute paths - open them as given, from any working ' +
  'directory). **Read them before you act**: they hold the family\'s stop-point rows and the order of work, ' +
  'and they outrank an instinct carried over from another family. They hold shapes, never values for your ' +
  'target - the values are still derived.\n\n' +
  '1. **One change per round.** Never bundle two fixes; otherwise nobody can tell which one worked. Your ' +
  'agent file says what counts as one (one place, one wall, or one mechanism). `scripts/check_change.sh` ' +
  'checks your diff before it is built. A specialist\'s change is also limited to one source file and a few ' +
  'hunks; the last-resort fixer\'s is not (one mechanism may span several places), but the bypass-record ' +
  'checks bind both. A blocked change is rolled back and does not count as a round.\n' +
  '2. **No speculative stubs, no adaptive toggles.** Anything shaped like "return a different value after ' +
  'the Nth read" (twelve reads of zero, then all ones) sends the firmware down a wrong branch and produces ' +
  'an accidental-looking pass that reproduces on no other firmware. Model constants only.\n' +
  '3. **The machine never speaks for the firmware.** Do not make the machine print a string, fill its own ' +
  'receive buffer, or call a handler through a trampoline so that progress shows: what our own machine ' +
  'produces is not evidence that the guest reached anything, and verification marks such a run UNVERIFIED. ' +
  'The machine\'s own host diagnostics (info_report lines on stderr) are not guest evidence either.\n' +
  '4. **Record every change as a bypass** in `06_machine/bypasses.md` with `대상 / 이유 / 방법 / 부작용`. A ' +
  'patch of the firmware is written down as a patch, never described as a normal model of the hardware. ' +
  'The 부작용 is never empty and never `(기록 없음)`; the entry has a heading `#<id>`, may carry the line ' +
  '`- 메타: 종류=…; 표지=…; 출처=…; 도출=…`, and each patch-table row in the machine source is tagged ' +
  '`/* bypass:<id> */`. `check_change.sh` rejects a **new or edited** entry that breaks these (exit 2, ' +
  'naming the entry) and the change is rolled back; an entry from an earlier round is not held against ' +
  'you. The tag rows are cross-checked only when at least one tag exists in the machine sources (a tag ' +
  'with no entry, a repeated tag, a patch entry `종류=P` with no tagged row), so a row you leave untagged ' +
  'is **not** caught for you: tag every row.\n' +
  '5. **Never repeat a change.** Check `change_key` in the rounds.jsonl the prompt names: the same change ' +
  'twice is not a new move, and pretending otherwise makes exhaustion unreachable.\n' +
  '6. **If you do not know where a value comes from, do not fix it.** An open question you cannot settle ' +
  'yourself goes in "rationale", with no_new_change=true: state what you could not tell and what would ' +
  'decide it. The pipeline passes that text to the static-analyzer\'s next derivation; no other field of ' +
  'your answer carries a question.\n' +
  '7. **When stalling, suspect the previous bypass first.** When the prompt says the run is stalling, read ' +
  'the 부작용 field of the earlier entries in `bypasses.md` before you add anything new: one of them may ' +
  'be the cause of the current wall.\n' +
  '8. **When you have no untried change left, say so** (no_new_change=true). That value feeds the stop ' +
  'condition, so inflating it means the loop never ends; a change you expect to move nothing is not a ' +
  'move.\n' +
  '9. **Output language.** `bypasses.md`, `one_line_progress` and every other document the user reads ' +
  '(`fixer_candidates.md` for the last-resort fixer) are written in natural Korean. Keep addresses, ' +
  'symbols, register names, offsets, opcodes and encodings verbatim.\n'

// --- helpers -----------------------------------------------------------------

/* Quote arbitrary text for bash.
 * Agent-authored strings (rationale, descriptions) end up inside shell commands.
 * Interpolating them raw lets a backtick or $(...) execute, so everything goes
 * through single quotes with the only dangerous character escaped. */
function shq(value) {
  const text = String(value ?? '').replace(/[\r\n\t]+/g, ' ').slice(0, 400)
  return "'" + text.replace(/'/g, "'\\''") + "'"
}

/* shq without the 400-character cap, for text the PIPELINE composed and a person has to read
 * whole later: a journal decision, a blocker's detail. The cap suits strings an agent wrote. A
 * stop reason that names the detect-arch basis and says how to resume is longer than that, and a
 * record that ends mid-sentence has lost exactly the part that says what to do next. The quoting
 * is the same as shq's, so the two differ only in the length. */
function shqWhole(value) {
  const text = String(value ?? '').replace(/[\r\n\t]+/g, ' ')
  return "'" + text.replace(/'/g, "'\\''") + "'"
}

function shell(label, phaseName, command, schema) {
  return agent(
    'Run the following commands exactly as written and report their output ' +
    'against the schema.\n' +
    'Do not guess, do not repair, do not smooth over failures. If a command ' +
    'fails, report the failure verbatim.\n\n' +
    '```bash\n' + command + '\n```\n',
    { label, phase: phaseName, schema }
  )
}

/* A multi-line script that must run in bash whatever shell the relaying agent has: a
 * glob with no match, an array, `set --` all behave differently in zsh. The delimiter is
 * quoted, so nothing in the script is expanded before bash reads it. Only bash and the
 * plugin's own scripts are used inside - no inline python, because on a Windows shell
 * python is reachable only through scripts/py.sh (the WSL bridge). */
function inBash(script, orTrue = false) {
  return `bash <<'SBOOT_SH'${orTrue ? ' || true' : ''}\n${script}\nSBOOT_SH`
}

/* The family kit as every delegated prompt carries it. The two line names are the
 * ones the agent prompts refer to, so they are fixed text rather than a free-form
 * note. A family whose profile names nothing reads "(none)": the lines are still
 * there, so an agent can tell "nothing to read" from "the pipeline forgot".
 *
 * The paths are ABSOLUTE (the plugin root joined with what the profile names): an agent
 * does not run with the plugin root as its working directory, so a relative path would be
 * handed over as a string that resolves nowhere.
 *
 * Every agent() call that hands work to static-analyzer, supervisor, fault-classifier,
 * a fixer or the machine-building agent must put this in its prompt - the checklist is
 * the DELEGATION_SITES list in tests/pipeline_sim/scenarios_guide.js (block S). */
function familyContext() {
  return `Family knowledge: ${familyKnowledge.length ? familyKnowledge.map(abs).join(', ') : '(none)'}\n` +
         `Runbook: ${familyRunbook ? abs(familyRunbook) : '(none)'}\n`
}

/* The family as scripts/build_lu.py and scripts/carve_disasm.py take it (--family): the profile
 * family that was actually read, narrowed to the three values those scripts know - exynos,
 * mediatek, generic. A family with a profile of its own but no entry in the scripts (and an
 * unknown name, which family_kit.py already turns into generic) is `generic`: a vendor default
 * - a layout, a command-line fallback, a string yardstick - applies only to the family it was
 * derived for, never to "everything else". The pipeline always passes the flag; the scripts keep
 * their old behaviour only when a caller leaves it out. */
const SCRIPT_FAMILIES = ['exynos', 'mediatek']
function familyFlag() {
  const f = String(familyName ?? '').trim().toLowerCase()
  return SCRIPT_FAMILIES.includes(f) ? f : 'generic'
}

/* What family_kit.py printed, made safe to use. Never throws: a profile that cannot
 * be read costs the family's own tables, not the run - the common tables and every
 * prompt still work, and the warnings say what is missing. A file the profile names
 * but the plugin does not have is dropped from the lists: an agent told to read a
 * path that is not there learns nothing and may stop to ask. */
function readFamilyKit(kit) {
  if (!kit || typeof kit !== 'object') {
    return { family: socFamily, knowledge: [], runbook: '', profile: `profiles/${socFamily}.yaml`,
             warnings: ['family_kit.py 의 결과를 얻지 못했습니다 — 계열 자료 없이 진행합니다'] }
  }
  const warnings = []
  if (kit.error) warnings.push(`family_kit.py 가 프로필을 읽지 못했습니다: ${kit.error}`)
  if (kit.note) warnings.push(String(kit.note))
  const missing = (Array.isArray(kit.missing) ? kit.missing : []).filter(Boolean).map(String)
  if (missing.length) warnings.push(`프로필이 가리키지만 플러그인에 없는 파일(목록에서 뺍니다): ${missing.join(', ')}`)
  const strs = a => (Array.isArray(a) ? a : [])
    .filter(x => typeof x === 'string' && x.trim()).map(x => x.trim())
  const runbook = typeof kit.runbook === 'string' ? kit.runbook.trim() : ''
  return {
    family: String(kit.family || socFamily),
    // the profile family_kit.py actually read (generic when the named one does not exist)
    profile: typeof kit.profile === 'string' && kit.profile.trim() ? kit.profile.trim() : `profiles/${socFamily}.yaml`,
    knowledge: strs(kit.knowledge).filter(f => !missing.includes(f)),
    runbook: missing.includes(runbook) ? '' : runbook,
    warnings,
  }
}

/* The common tables plus the family's own, each once - as absolute paths (see abs()). */
function composeKnowledge(familyTables) {
  const all = []
  for (const f of COMMON_KNOWLEDGE.concat(familyTables)) if (!all.includes(f)) all.push(f)
  return all.map(abs).join(', ')
}

/* Which QEMU core patch set this firmware needs (scripts/patch_qemu_core.py --family).
 * `exynos` is the SMC-hook set every run got before families existed; `mediatek` is the set
 * that lets TCG create an AArch32 CPU; `all` is both. MediaTek takes its own. Any other
 * family keeps the SMC-hook set - and gets the AArch32 one as well when the chain it derived
 * has an AArch32 stage, because that patch is about the CPU, not the vendor. Until a profile
 * key carries the choice, the mapping lives here. */
function corePatchFamily() {
  if (familyName === 'mediatek') return 'mediatek'
  return mixedChain ? 'all' : 'exynos'
}

/* One rung per EXECUTABLE stage, named after the stage the analyst derived.
 * A stage whose rung name the common tail already owns gets none: the kernel is a
 * stage in the stage map's vocabulary while `kernel_entry` / `kernel_alive` are rungs
 * of the tail, and two rungs of one name would read as one - the milestone-token file
 * could only describe one of them. Characters a ladder cannot carry (it travels as a
 * comma-separated argument) are replaced; an ordinary name is left exactly as it was. */
const RESERVED_RUNGS = ['medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive',
                        'userspace', 'partitions_up', 'super_mounted', 'autoboot'].concat(SURFACES)
function buildStageRungs(stages) {
  const rungs = [], dropped = [], entries = []
  stages.forEach((x, i) => {
    const raw = String(x?.name || `stage${i}`).replace(/[^A-Za-z0-9_.-]+/g, '_')
    let rung = `${raw}_entry`
    if (RESERVED_RUNGS.includes(rung)) { dropped.push(`${x?.name ?? raw} → ${rung}`); return }
    if (rungs.includes(rung)) rung = `${raw}${i}_entry`
    rungs.push(rung)
    // Which stage a rung stands for, so a script can find the stage's entry PC in the
    // stage map without re-deriving the naming above.
    entries.push({ rung, stage: x?.name ?? raw, index: i, entry_pc: x?.entry_pc ?? null })
  })
  return { rungs, dropped, entries }
}

/* "name(arch/origin)" per stage, for the log and for the prompts. */
function stageSummary(stages) {
  return stages.map(x => `${x?.name ?? '?'}(${[x?.arch, x?.origin, x?.state !== 'exec' ? x?.state : null]
    .filter(Boolean).join('/')})`).join(', ')
}

/* State of every rung, for the report. `reached` means the run OBSERVED it. A rung the
 * loop stepped over because a higher one was observed is `not_reached`, and so is one
 * never seen. `reached_bypassed` is a verify_ok that was observed while the firmware's
 * verification was itself bypassed (verify_bypass.count > 0): the string appeared, but
 * it is not evidence that the check ran. */
function rungStates(goalList, observed, bypassCount) {
  const out = {}
  for (const g of goalList) {
    out[g] = !observed.has(g) ? 'not_reached'
      : (g === 'verify_ok' && bypassCount > 0) ? 'reached_bypassed' : 'reached'
  }
  return out
}

/* The grade as it is reported. A bypassed verify_ok is not hidden behind the grade, and
 * it does not lower it either - it changes what "reached" is claimed to mean. */
function gradeText(targetName, goalList, bypassCount) {
  return goalList.includes('verify_ok') && bypassCount > 0
    ? `${targetName} (verify_ok 우회 ${bypassCount}건)` : targetName
}

/* Is this round OBSERVED waiting for input? Only a measurement counts: run_round.sh's
 * own `waiting_for_input`, when it reports one; otherwise the firmware was seen
 * polling the console receive path many times (the machine reports its polls) in a
 * round with no exception and no growth to wait out. This is deliberately narrow.
 * A firmware that never reads the UART polls nothing, so an output-only bootloader is
 * never "waiting"; and a stall with exceptions or an unreported receive path is some
 * other stop point, which the loop keeps working on. */
function waitingForInput(obs) {
  if (typeof obs?.waiting_for_input === 'boolean') return obs.waiting_for_input
  return obs?.rx_reported === true &&
         Number(obs?.rx_polls ?? 0) >= INPUT_WAIT_MIN_POLLS &&
         obs?.input_starved !== true && obs?.timeout_bound !== true &&
         Number(obs?.exceptions ?? 0) === 0 &&
         String(obs?.origin_type ?? 'none') === 'none'
}

/* The last-resort fixer, reached two ways: the supervisor sends a stop point here
 * when no implemented fixer covers it, or a specialist it picked declined. Both
 * mean the same thing - the fault has no owner - so both carry the supervisor's
 * treatment plan, which is more useful here than anywhere else because this fixer
 * has no table telling it where to look. */
function runGeneralFixer(round, goal, why, plan, obs, cls, derivedTable, suspectPriorBypass = false) {
  return agent(
    `Round ${round}, goal ${goal}, target ${target}. You are the last resort.\n` +
    `${why}\n` +
    fixerContext(round, obs, cls, derivedTable, suspectPriorBypass) +
    (plan ? `Supervisor's treatment plan: ${plan}\n` : '') +
    `Build (BOTH commands, in this order - editing the workspace source alone ` +
    `leaves the QEMU tree compiling the previous version):\n` +
    `  bash "${PLUGIN}/scripts/sync_machine.sh" "${workdir}" ${machine}\n` +
    `  cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64\n\n` +
    `Treat ONE mechanism. You may touch several places only if they are parts of ` +
    `one cause, and you must say in one sentence why they are one.\n` +
    `Then rebuild, and report build failures verbatim.\n` +
    `Record what you did in ${workdir}/fixer_candidates.md so a real specialist can be ` +
    `written later - that record is half the job, not an afterthought.\n` +
    `The pipeline then runs scripts/check_change.sh on your change. The one-source-file and hunk ` +
    `limits that bind a specialist do NOT bind you (one mechanism may span several places and files); ` +
    `the bypass-record checks bind you exactly as they bind a specialist. What it rejects is rolled ` +
    `back and does not count as a round.\n` +
    `If the mechanism is not understood, do not guess: answer no_new_change=true ` +
    `and the run goes back to derivation. You have the widest scope here, so that ` +
    `answer is what stands between an honest stop and an endless run.\n` +
    FIXER_RULES,
    { agentType: GENERAL_FIXER, schema: GENERAL_SCHEMA, model: 'opus', effort: 'high',
      label: `general-${round}`, phase: 'Loop' })
}

/* The context every fixer prompt starts from: what stopped, what is known about it, and where the
 * sources and the record of earlier attempts are. The specialists and the last-resort fixer used to
 * build this twice and drift; it is one text now. What differs - the intro, the treatment plan,
 * how a change is to be made and how to decline - stays with each caller. */
function fixerContext(round, obs, cls, derivedTable, suspectPriorBypass) {
  return `Classification: ${cls?.category ?? 'unknown'}   Evidence: ${JSON.stringify(cls?.evidence ?? {})}\n` +
    `Fingerprint: ${fingerprintText(obs)}\n` +
    `Console: ${obs?.console}\nSummary: ${obs?.summary}\nFull trace: ${obs?.trace}\n` +
    `Derived facts: ${staticDoc}  (read it - the analyst appends there every round)\n` +
    `Stop points derived for this firmware:\n${derivedTable}\n` +
    familyContext() +
    channelsText(obs, round) +
    `Machine sources: ${workdir}/06_machine/   Bypass record: ${workdir}/06_machine/bypasses.md\n` +
    `Already attempted: ${workdir}/rounds.jsonl - never repeat an existing change_key\n` +
    (suspectPriorBypass
      ? `The run is stalling. Suspect the side effects of an earlier bypass before adding a new one.\n`
      : '')
}

/* The fingerprint as the classifier and the fixers should see it.
 * The originating exception comes first because it is the stop point; the last
 * FAR in the trace is only where a nested abort ran out of time, and leading
 * with it sent round after round chasing an address that was a symptom of the
 * recursion rather than its cause. */
function fingerprintText(obs) {
  return JSON.stringify({
    origin: { type: obs?.origin_type, esr: obs?.origin_esr,
              far: obs?.origin_far, elr: obs?.origin_elr },
    exceptions: obs?.exceptions,
    console_bytes: obs?.console_bytes, console_uniq: obs?.console_uniq,
    last_far_in_trace: obs?.far, last_elr_in_trace: obs?.elr,
    // The kernel's own log can arrive on a channel other than the UART. A silent UART
    // with a moving kernel log is a boot in progress, not a quiet failure.
    ...(obs?.kernel_uniq != null
      ? { kernel_uniq: obs.kernel_uniq, kernel_last_time: obs.kernel_last_time } : {}),
  }) + (obs?.origin_block ? `\nOrigin exception block: ${obs.origin_block}` : '') +
  `\n(last_far/last_elr are where the exception storm stopped. Diagnose from origin.)`
}

/* Which observation channels this run has. The memory-dump channel is on only when
 * memdump_plan.json exists: without it a kernel that logs only into RAM looks exactly like
 * a silent UART, and "nothing on the console" is then not evidence about the kernel. */
function channelStateText() {
  const files = `The round's own log files are named in observation.json as kernel_log and host_log ` +
                `(a path, or null when the round wrote none).\n`
  return (memdumpPlanKnown
    ? `Observation channels: UART + memory dump (${workdir}/memdump_plan.json is present, so the kernel log is read out of RAM).\n`
    : `Observation channels: UART only - there is no ${workdir}/memdump_plan.json, so a kernel that logs ` +
      `only into RAM is invisible here and a silent console is not evidence about it.\n`) + files
}

/* What a kernel_alive evidence record can say about the kernel banner. Only the memory-dump
 * scan measures it (`via`: banner | alternate, `banner`: was the banner line itself in the
 * log). A UART match is a plain string match: its record carries neither, so the banner is
 * neither observed nor missing there - it is NOT VERIFIED, and "observed" is never the
 * default for a record that does not say it. */
function aliveBanner(ev) {
  if (!ev) return 'unknown'
  if (ev.via === 'alternate' || ev.banner === false || /배너 미관측/.test(String(ev.note ?? ''))) return 'not_observed'
  if (ev.via === 'banner') return 'observed'
  return 'unverified'
}

/* What the observation says about channels beyond the UART, as prose for a prompt.
 * Empty when the round had only the UART. Host lines are named so that nobody mistakes
 * them for the guest's voice: the machine printed them. `n` is the round whose files
 * these are: the kernel log and the host log are per-round files (contract C1), and no
 * other prompt names where they are - a classifier that reads only the UART console
 * cannot see a kernel that logs into RAM. */
function channelsText(obs, n) {
  const ch = obs?.channels
  const parts = []
  if (ch && (ch.kernel_lines > 0 || ch.host_lines > 0)) {
    parts.push(`channels: uart_bytes=${ch.uart_bytes ?? 0}, kernel_lines=${ch.kernel_lines ?? 0} ` +
               `(memory-dump kernel log), host_lines=${ch.host_lines ?? 0} (our own machine - ` +
               `never evidence that the guest reached anything)`)
  }
  // run_round.sh names the round's own files in observation.json (`kernel_log`, `host_log`): a
  // path when the round wrote one, null when it did not. Those fields win. Only an observation
  // that does not carry the key at all (an older run_round.sh) falls back to the per-round
  // default path - and null is never turned back into a path the round did not write.
  const reported = k => obs != null && Object.prototype.hasOwnProperty.call(obs, k)
  const named = k => reported(k) && typeof obs[k] === 'string' && obs[k] !== ''
  const kernelLog = reported('kernel_log') ? (named('kernel_log') ? obs.kernel_log : null)
    : (n != null ? `${workdir}/07_logs/kernel_${n}.log` : null)
  const hostLog = reported('host_log') ? (named('host_log') ? obs.host_log : null)
    : (n != null ? `${workdir}/07_logs/host_${n}.txt` : null)
  if (kernelLog && (named('kernel_log') || memdumpPlanKnown || ch?.kernel_lines > 0)) {
    parts.push(`kernel log: ${kernelLog} - the memory-dump channel, GUEST evidence, one line per ` +
               `entry as "<kernel_seconds> <text>" (${ch?.kernel_lines ?? 0} lines this round). ` +
               `Read it: with a silent UART it is the only place the kernel's own text can be ` +
               `matched, and a stop point named from the UART console alone says nothing about it ` +
               `(observation.json field kernel_log)`)
  } else if (reported('kernel_log') && !kernelLog && memdumpPlanKnown) {
    parts.push(`kernel log: none - observation.json kernel_log is null, so this round wrote no kernel ` +
               `log file (the memory-dump channel is on); there is no file to look for`)
  }
  if (hostLog && (named('host_log') || ch?.host_lines > 0)) {
    parts.push(`host log: ${hostLog} - QEMU's own diagnostics (the machine speaking): context ` +
               `for what it modelled or refused, never evidence about the guest ` +
               `(observation.json field host_log)`)
  }
  const ev = obs?.kernel_alive_evidence
  if (ev) {
    const banner = aliveBanner(ev)
    parts.push(`kernel_alive evidence: ${JSON.stringify(ev)}` +
               (banner === 'not_observed'
                 ? ' — the kernel banner itself was NOT observed; report it as such'
                 : banner === 'unverified'
                   ? ' — whether the kernel banner was observed is NOT verified (a plain string ' +
                     'match; no kernel time, task or banner check on this channel); do not report ' +
                     'the banner as observed'
                   : ''))
  }
  const gaps = obs?.kernel?.gaps
  if (gaps && gaps.count > 0) {
    parts.push(`kernel log gaps: ${gaps.count} (total ${gaps.total_s}s of ${gaps.span_s}s) - ` +
               `suspected loss between memory dumps, not a statement about the guest`)
  }
  if (obs?.guest_reset_signal === true) {
    parts.push(`guest_reset_signal=true: a reset/watchdog block was touched right after the ` +
               `kernel jump (${JSON.stringify(obs?.guest_reset ?? {})}). It supports the ` +
               `HYPOTHESIS guest_reset_after_jump; it does not confirm it.`)
  }
  if (obs?.early_exit) parts.push(`early_exit: ${JSON.stringify(obs.early_exit)} (the round was cut short)`)
  return parts.length ? parts.map(p => `  ${p}`).join('\n') + '\n' : ''
}

function recordRoundCmd(round, goal, fp, category, fixer, changeKey, effect,
                       analystFacts, noNewChange, rationale) {
  const fields = [
    `round=${round}`,
    `goal=${shq(goal)}`,
    `fp_exc=${Number(fp?.exceptions ?? 0)}`,
    `fp_far=${shq(fp?.far ?? 'none')}`,
    `fp_elr=${shq(fp?.elr ?? 'none')}`,
    // Identity of the stop point. Recorded separately from the trailing FAR so
    // the stop conditions can compare rounds by what actually happened.
    `fp_origin_esr=${shq(fp?.origin_esr ?? 'none')}`,
    `fp_origin_far=${shq(fp?.origin_far ?? 'none')}`,
    `fp_origin_elr=${shq(fp?.origin_elr ?? 'none')}`,
    `fp_milestone=${shq(fp?.milestone ?? 'none')}`,
    `fp_bytes=${Number(fp?.console_bytes ?? 0)}`,
    `fp_uniq=${Number(fp?.console_uniq ?? 0)}`,
    // Depth of the kernel channel, recorded ONLY when the round had one: stop_conditions
    // reads these two to tell a boot that is moving in the kernel log from one that is
    // stalled while the UART sits still. Left out otherwise, so a row from a run with
    // no memory-dump channel keeps exactly the identity it always had.
    ...(fp?.kernel_uniq != null
      ? [`fp_klast=${Number(fp?.kernel_last_time ?? 0)}`, `fp_kuniq=${Number(fp.kernel_uniq)}`]
      : []),
    `category=${shq(category ?? 'none')}`,
    `fixer=${shq(fixer ?? 'none')}`,
    `change_key=${shq(changeKey ?? 'none')}`,
    `effect=${shq(effect)}`,
    `analyst_new_facts=${Number(analystFacts)}`,
    `fixer_no_new_change=${noNewChange === true}`,
    // Why that change. record.py flags a round that names a fixer without it,
    // because a round nobody can explain is a round nobody can build on.
    ...(rationale ? [`rationale=${shq(String(rationale).slice(0, 500))}`] : []),
    `tokens_total=${budget.spent()}`,
  ].join(' ')
  return `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" round ${fields}`
}

function journalTryEnd(round, cause, analysis, fix, evidence) {
  return `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" try-end ${round} ` +
         `${shq(cause)} ${shq(analysis)} ${shq(fix)} ${shq(evidence)}`
}

const OK_SCHEMA = { type: 'object', properties: { ok: { type: 'boolean' } } }

// --- schemas -----------------------------------------------------------------
const DERIVED_SCHEMA = {
  type: 'object',
  properties: {
    total: { type: 'integer' },
    new: { type: 'integer' },
    new_signatures: { type: 'array' },
    stop_points: { type: 'array' },
  },
  required: ['total', 'new'],
}

const ANALYST_SCHEMA = {
  type: 'object',
  properties: {
    mode: { type: 'string' },
    // carve_check's verdict as printed: true, false, or null (undetermined - a family with no yardstick
    // and no container-header evidence). Only false stops the run; carve_note says why it is null.
    carve_is_full: { type: ['boolean', 'null'] },
    carve_note: { type: ['string', 'null'] },
    assets_ok: { type: ['boolean', 'null'] },
    bl_surface: { type: ['string', 'null'] },
    // The derived stage map, as stage_map.json recorded it (schema v2): per stage
    // name, state (exec | encrypted | unconfirmed), arch (aarch32 | aarch64), origin
    // (container | medium | handoff), entry_pc, confidence, anchors. The ladder is
    // built from this, so a run that cannot report it cannot be sequenced.
    stages: { type: ['array', 'null'] },
    arch_supported: { type: ['boolean', 'null'] },
    storage_driver: { type: ['object', 'null'] },
    undetermined_count: { type: 'integer' },
    new_facts_count: { type: 'integer' },
    facts: { type: 'array' },
    escalation_answer: { type: ['object', 'null'] },
  },
  required: ['new_facts_count'],
}

const RUN_SCHEMA = {
  type: 'object',
  properties: {
    run_ok: { type: 'boolean' },
    run_fault: { type: 'boolean' },
    run_fault_line: { type: 'string' },
    run_error: { type: 'string' },
    milestone: { type: 'string' },
    milestones_reached: { type: 'array' },
    injected: { type: 'boolean' },
    exceptions: { type: 'integer' },
    console_bytes: { type: 'integer' },
    console_uniq: { type: 'integer' },
    origin_type: { type: 'string' },
    origin_esr: { type: 'string' },
    origin_far: { type: 'string' },
    origin_elr: { type: 'string' },
    origin_block: { type: 'string' },
    // null when the probe did not run. Distinct from false, which means it ran
    // and a longer budget produced nothing more.
    timeout_bound: { type: ['boolean', 'null'] },
    probe_console_bytes: { type: 'integer' },
    // What the input path did this round (scripts/uart_harness.py).
    input_offered: { type: 'boolean' },
    prompt_seen: { type: 'boolean' },
    command_sent: { type: 'boolean' },
    input_starved: { type: 'boolean' },
    rx_reported: { type: 'boolean' },
    rx_served: { type: ['integer', 'null'] },
    rx_polls: { type: ['integer', 'null'] },
    input_summary: { type: 'string' },
    // ok | missing | unknown - whether this run could read the boot medium's
    // partition table. Never inferred from silence.
    storage_partition_table: { type: 'string' },
    storage_token: { type: 'string' },
    far: { type: 'string' },
    elr: { type: 'string' },
    console: { type: 'string' },
    summary: { type: 'string' },
    trace: { type: 'string' },
    stop: { type: 'boolean' },
    stop_reason: { type: ['string', 'null'] },
    stall_count: { type: 'integer' },
    escalate_to_analyst: { type: 'boolean' },
    suspect_prior_bypass: { type: 'boolean' },
    best_milestone: { type: ['string', 'null'] },
    best_progress: { type: 'object' },
    tried_changes: { type: 'array' },
    futile_changes: { type: 'integer' },
    needs_layer_review: { type: 'boolean' },
    // Channels beyond the UART (run_round.sh, additive). A channel that is off reads 0,
    // and the kernel fields read null.
    channels: { type: ['object', 'null'] },
    // null: no evidence. An object: which line, from which channel, at which kernel
    // time, and whether the banner itself was seen (`via`: banner | alternate).
    kernel_alive_evidence: { type: ['object', 'null'] },
    // A reset/watchdog block was touched right after the kernel jump (host-line
    // patterns). False also when nothing was configured to look for it.
    guest_reset_signal: { type: 'boolean' },
    guest_reset: { type: ['object', 'null'] },
    kernel_last_time: { type: ['number', 'null'] },
    kernel_uniq: { type: ['integer', 'null'] },
    kernel: { type: ['object', 'null'] },
    early_exit: { type: ['object', 'string', 'null'] },
    kernel_moving: { type: 'boolean' },
    // The round's own log files (run_round.sh): 07_logs/kernel_<N>.log (the memory-dump kernel
    // log) and 07_logs/host_<N>.txt (QEMU's own diagnostic lines), each a path or null when
    // the round wrote none. null is an answer: it is relayed as null, never as a made-up path.
    kernel_log: { type: ['string', 'null'] },
    host_log: { type: ['string', 'null'] },
    // Optional: the firmware was seen parked on its console input (see waitingForInput).
    waiting_for_input: { type: ['boolean', 'null'] },
  },
  required: ['milestone', 'stop'],
}

const SUPERVISOR_SCHEMA = {
  type: 'object',
  properties: {
    route: { type: 'string' },
    layer: { type: ['string', 'null'] },
    build_change: { type: ['object', 'null'] },
    // { round, reason } - withdraw a bypass whose mechanism has been disproven
    revert: { type: ['object', 'null'] },
    treatment_plan: { type: ['string', 'null'] },
    prescribed_fixer: { type: ['string', 'null'] },
    progress: { type: 'boolean' },
    stop_reason: { type: ['string', 'null'] },
    suspect_prior_bypass: { type: 'boolean' },
    decision_note: { type: 'string' },
  },
  required: ['route'],
}

const CLASSIFIER_SCHEMA = {
  type: 'object',
  properties: {
    category: { type: 'string' },
    confidence: { type: 'string' },
    milestone_reached: { type: ['string', 'null'] },
    evidence: { type: 'object' },
    novelty: { type: 'object' },
    fixer_ranking: { type: 'array' },
    escalation_request: { type: 'object' },
    note: { type: ['string', 'null'] },
  },
  required: ['category'],
}

const GENERAL_SCHEMA = {
  type: 'object',
  properties: {
    fixer: { type: 'string' },
    no_new_change: { type: 'boolean' },
    mechanism: { type: ['string', 'null'] },
    change_key: { type: ['string', 'null'] },
    changes: { type: 'array' },
    build_ok: { type: ['boolean', 'null'] },
    build_error: { type: ['string', 'null'] },
    candidate_doc: { type: 'boolean' },
    one_line_progress: { type: ['string', 'null'] },
    rationale: { type: ['string', 'null'] },
  },
  required: ['no_new_change'],
}

// Only what the pipeline reads. A question a fixer cannot settle has no field of its own: it goes in
// `rationale` with no_new_change=true (rule 6 of FIXER_RULES), and escalationFocus() hands it on.
const FIXER_SCHEMA = {
  type: 'object',
  properties: {
    fixer: { type: 'string' },
    not_mine: { type: 'boolean' },
    no_new_change: { type: 'boolean' },
    change: { type: ['object', 'null'] },
    change_key: { type: ['string', 'null'] },
    rationale: { type: 'string' },
    one_line_progress: { type: 'string' },
  },
  required: ['fixer'],
}

const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    build_ok: { type: 'boolean' },
    build_error: { type: ['string', 'null'] },
    machine_registered: { type: 'boolean' },
    // build_lu.py's warning_* keys, verbatim (zero-size entry, duplicate names, an
    // undecided medium). The supervisor reads them: each is a premise nobody derived.
    build_warnings: { type: 'array' },
  },
  required: ['build_ok'],
}

const APPLY_SCHEMA = {
  type: 'object',
  properties: {
    gate_pass: { type: 'boolean' },
    gate_reason: { type: 'string' },
    // Did the edited source actually reach the tree ninja compiles?
    sync_ok: { type: 'boolean' },
    sync_reason: { type: ['string', 'null'] },
    build_ok: { type: 'boolean' },
    build_error: { type: ['string', 'null'] },
  },
  required: ['gate_pass', 'build_ok'],
}

const VERIFIER_SCHEMA = {
  type: 'object',
  properties: {
    script_passes: { type: 'integer' },
    final_passes: { type: 'integer' },
    final_verdict: { type: 'string' },
    override: { type: 'object' },
    failed_items: { type: 'array' },
    next_round_recommendation: { type: ['string', 'null'] },
    // The verification-bypass report, as the verifier counted it (it may find one the
    // script did not flag). `unproven`: the negative test never ran, so nothing shows
    // the firmware's own verification actually decided anything.
    verify_bypass: { type: ['object', 'null'] },
  },
  required: ['final_passes', 'final_verdict'],
}

// What stage 1 (verify.py) measured, relayed from verdict_script.json. The pipeline
// reads it itself - the rung state of verify_ok depends on verify_bypass.count, and an
// LLM's account of a number is not where that should come from.
const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string' },
    verdict_label: { type: 'string' },
    gates_passed: { type: 'integer' },
    gates_total: { type: 'integer' },
    verify_bypass: { type: ['object', 'null'] },
    // verdict_script.json's top-level address_windows (reference item 8, mixed-arch machines only)
    address_windows: { type: ['object', 'null'] },
  },
  required: ['verdict'],
}

// scripts/family_kit.py: the family's own tables and run guide, from the profile.
const FAMILY_KIT_SCHEMA = {
  type: 'object',
  properties: {
    family: { type: 'string' },
    profile: { type: 'string' },
    knowledge: { type: 'array' },
    runbook: { type: 'string' },
    note: { type: ['string', 'null'] },
    missing: { type: 'array' },
    error: { type: ['string', 'null'] },
  },
}

// scripts/stage_map.py --detect-arch: the architecture of the first container image, from
// evidence - or "unknown" (a legitimate answer; nothing defaults silently). `exit_code` is the
// script's own, read from the echoed `detect_arch_exit=` line.
const DETECT_ARCH_SCHEMA = {
  type: 'object',
  properties: {
    arch: { type: ['string', 'null'] },
    entry_signature: { type: ['string', 'null'] },
    basis: { type: 'array' },
    confidence: { type: ['string', 'null'] },
    exit_code: { type: 'integer' },
  },
  required: ['exit_code'],
}

// scripts/stage_map.py under each reading, when detect-arch could not decide (archProbeCmd):
// the exit code and the number of entry stubs the map lists. null = not reported (the run
// failed before it wrote its map, or the relay lost it) - never read as zero.
const ARCH_PROBE_SCHEMA = {
  type: 'object',
  properties: {
    arm32_exit: { type: ['integer', 'null'] },
    arm32_entry_stubs: { type: ['integer', 'null'] },
    arm64_exit: { type: ['integer', 'null'] },
    arm64_entry_stubs: { type: ['integer', 'null'] },
  },
}

// The kernel-side boot assets after scripts/extract_boot_assets.sh (stageAssetsCmd).
// `staging`: staged | partial (the kernel side is staged, the super image could not be) |
// no_boot_img | failed. `summary` is the script's own last line (`assets: image=.. dtb=.. ...`).
const ASSET_STAGE_SCHEMA = {
  type: 'object',
  properties: {
    staging: { type: 'string' },
    exit_code: { type: ['integer', 'null'] },
    image: { type: ['boolean', 'null'] },
    dtb: { type: ['boolean', 'null'] },
    initrd: { type: ['boolean', 'null'] },
    super: { type: ['boolean', 'null'] },
    super_source: { type: ['string', 'null'] },
    summary: { type: ['string', 'null'] },
    log: { type: ['string', 'null'] },
  },
  required: ['staging'],
}

// Where a resumed workspace left off (roundBaseCmd).
const ROUND_BASE_SCHEMA = {
  type: 'object',
  properties: {
    last_round: { type: 'integer' },
    rounds_jsonl: { type: ['integer', 'null'] },
    logs: { type: ['integer', 'null'] },
  },
  required: ['last_round'],
}

// scripts/qemu_tree.sh reset. `exit_code` comes from the echoed `qemu_tree_exit=` line,
// not from the relaying agent's reading of the output.
const TREE_SCHEMA = {
  type: 'object',
  properties: {
    exit_code: { type: 'integer' },
    noop: { type: ['boolean', 'null'] },
    restored: { type: 'array' },
    removed: { type: 'array' },
    error: { type: ['string', 'null'] },
  },
  required: ['exit_code'],
}

// scripts/detect_medium.py: eMMC or UFS, from evidence - or `unknown`.
const MEDIUM_SCHEMA = {
  type: 'object',
  properties: {
    hci_kind: { type: 'string' },
    basis: { type: 'string' },
    confidence: { type: 'string' },
    reason: { type: ['string', 'null'] },
    evidence: { type: 'array' },
    notes: { type: 'array' },
  },
  required: ['hci_kind'],
}

// scripts/memdump_observe.py derive: where the kernel log lives in RAM, from the
// bootloader's own log. `derived` is false when nothing (or something conflicting) was said.
const PLAN_SCHEMA = {
  type: 'object',
  properties: {
    present: { type: 'boolean' },
    derived: { type: 'boolean' },
    plan: { type: ['object', 'null'] },
    reason: { type: ['string', 'null'] },
  },
  required: ['present', 'derived'],
}

// The verification-bypass rows the ledger holds (ledgerBypassCmd): `f_rows` from the printed
// `f_rows=` line, `ledger` from `ledger=present|absent`.
const LEDGER_BYPASS_SCHEMA = {
  type: 'object',
  properties: {
    f_rows: { type: 'integer' },
    ledger: { type: ['string', 'null'] },
  },
  required: ['f_rows'],
}

// What milestone_tokens.txt says about the ladder (tokenCheckCmd): whether the file is
// there, which milestone names in it are no rung of the ladder, and whether the FIRST stage's
// rung has a token line (the one rung nothing else can credit).
const TOKEN_CHECK_SCHEMA = {
  type: 'object',
  properties: {
    tokens_file: { type: 'string' },
    unknown_rungs: { type: 'array' },
    first_rung_token: { type: ['boolean', 'null'] },
  },
  required: ['tokens_file'],
}

// =============================================================================
// Phase 1 - Analyze
// =============================================================================
phase('Analyze')
log(`[분석] 등급 ${target} — 목표 사다리: ${goals.join(' → ')} (스테이지 칸은 도출 후 확정)`)

// The plugin version that created this workspace, written ONCE and before anything
// else records into it (.sboot_version, C9). init's cleaning reads it to tell a
// workspace made by this release from one a long-gone release left behind.
//   - only a NEW workspace gets it: one that already holds a run's records was made by
//     whichever release ran then, and filling the marker in now would claim otherwise;
//   - it is never overwritten.
// The check is made before session-open below, which itself writes records.
await shell('workspace-marker', 'Analyze', inBash(
  `WS=${shq(workdir)}\n` +
  `if [ -e "$WS/.sboot_version" ]; then echo "workspace marker: present"; exit 0; fi\n` +
  `for f in STATIC.md rounds.jsonl stage_map.json metrics.jsonl observation.json fingerprint.json; do\n` +
  `  if [ -e "$WS/$f" ]; then\n` +
  `    echo "workspace marker: not written - this workspace already holds a run, made by an earlier release; it stays unmarked on purpose"\n` +
  `    exit 0\n` +
  `  fi\n` +
  `done\n` +
  `VER=$(grep -m1 '"version"' "${PLUGIN}/.claude-plugin/plugin.json" 2>/dev/null | ` +
  `sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/')\n` +
  `if [ -z "$VER" ]; then echo "workspace marker: not written - plugin.json has no version"; exit 0; fi\n` +
  `printf '%s\\n' "$VER" > "$WS/.sboot_version" && echo "workspace marker: wrote $VER"`, true),
  OK_SCHEMA)

// Open the record before anything can fail, so a run that stops in the first
// minute still says who asked for what.
await shell('session-open', 'Analyze',
  `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" session-start ` +
  `${shq('/sboot-rehost:start')} ${shq(`target=${target} soc=${socFamily} arch=${archGiven ? arch : 'auto (Analyze 에서 도출)'}`)} || true\n` +
  (INVOKED_WITH
    ? `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" prompt ${shq(INVOKED_WITH)} ` +
      `${shq('Analyze')} 0 || true\n` +
      `printf '%s' ${shq(INVOKED_WITH)} | bash "${PLUGIN}/scripts/py.sh" record.py ` +
      `"${workdir}" prompt --stdin=text phase=Analyze round=0 || true`
    : `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
      `${shq('사용자 입력 원문이 전달되지 않았습니다 (invoked_with 미지정) — ' +
             '이 실행의 지시 맥락은 기록되지 않습니다')} || true`),
  OK_SCHEMA)

// Precondition zero: is this even the current plugin?
//
// A session loads its skills and agents ONCE, at start. Pulling a newer plugin
// afterwards does not change what the running session uses, so a stale session
// runs old prompts against new scripts and the logs look entirely normal while
// the behaviour is a previous release's. That is worse than a crash: the user
// ends up debugging something that was fixed two versions ago.
//
// So this runs before anything else and refuses rather than warns.
const ver = await shell('check-version', 'Analyze',
  `bash "${PLUGIN}/scripts/check_version.sh" "${PLUGIN}"`,
  {
    type: 'object',
    properties: {
      ok: { type: 'boolean' },
      state: { type: 'string' },
      running: { type: ['string', 'null'] },
      registered: { type: ['string', 'null'] },
      available: { type: ['string', 'null'] },
      problems: { type: 'array' },
      notes: { type: 'array' },
      hint: { type: 'string' },
    },
    required: ['ok'],
  })

if (ver && ver.ok === false) {
  const problems = (ver.problems ?? []).join(' / ')
  await shell('record-version-blocker', 'Analyze',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_VERSION ` +
    `detail=${shq(problems)} 2>/dev/null || true\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
    `${shq(`버전 드리프트로 정지: ${problems}`)} 2>/dev/null || true`,
    OK_SCHEMA)
  log('★ 정지 — BLOCKED_VERSION: 이 세션이 최신 플러그인을 쓰고 있지 않습니다.')
  log(`    실행 중 ${ver.running ?? '?'} · 세션이 로드한 것 ${ver.registered ?? '?'} · ` +
      `이 컴퓨터의 최신 ${ver.available ?? '?'}`)
  ;(ver.problems ?? []).forEach(p => log(`    · ${p}`))
  log('')
  ;(ver.hint ?? '').split('\n').forEach(line => log(`    ${line}`))
  return {
    success: false, stopped: true, stop_reason: 'BLOCKED_VERSION',
    running: ver.running, registered: ver.registered, available: ver.available,
    problems: ver.problems ?? [],
    note: '옛 버전으로 실행하면 회차·로그·판정이 모두 옛 규칙을 따릅니다. ' +
          '위 순서대로 갱신한 뒤 같은 명령을 다시 실행하십시오 — ' +
          '워크스페이스와 INPUT.md 는 그대로 재사용됩니다.',
  }
}
if (ver && Array.isArray(ver.notes) && ver.notes.length) {
  ver.notes.forEach(t => log(`[버전] ${t}`))
}
if (ver && ver.state === 'dev') {
  log(`[버전] 작업 사본(${ver.running})으로 실행 중입니다 — 캐시가 아니라 체크아웃이 기준입니다.`)
}

// Precondition: can this shell run the work at all?
//
// On native Windows the agent's Bash tool is Git Bash, which cannot see /mnt/c
// or run a Linux QEMU. Every round would then fail for the same reason while
// the loop treats it as an ordinary stop point and burns its whole round
// budget. A shell that cannot execute the work is not a goal judgement - check
// it once, up front, and stop with something the user can act on.
const env = await shell('check-env', 'Analyze',
  `bash "${PLUGIN}/scripts/check_env.sh" "${workdir}" ${target}`,
  {
    type: 'object',
    properties: {
      ok: { type: 'boolean' },
      os: { type: 'string' },
      problems: { type: 'array' },
      hint: { type: 'string' },
    },
    required: ['ok'],
  })

if (!env || env.ok !== true) {
  const problems = (env?.problems ?? []).join(' / ')
  await shell('record-env-blocker', 'Analyze',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_ENV ` +
    `detail=${shq(problems)} 2>/dev/null || true\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
    `${shq(`환경 블로커: ${problems}`)} 2>/dev/null || true`,
    OK_SCHEMA)
  log(`★ 정지 — BLOCKED_ENV (${env?.os ?? '?'}): 실행 환경이 준비되지 않았습니다.`)
  ;(env?.problems ?? []).forEach(p => log(`    · ${p}`))
  return {
    success: false, stopped: true, stop_reason: 'BLOCKED_ENV',
    os: env?.os, problems: env?.problems ?? [],
    note: (env?.hint || '실행 환경을 갖춘 뒤 다시 시도하세요.') +
          ' 이것은 목표 도달 판정이 아니라 실행 환경 문제이며, 환경만 갖추면 ' +
          '같은 명령으로 그대로 재개됩니다 (워크스페이스·INPUT.md 재사용).',
  }
}

// The family's own material. soc_family was decided by the caller (the start skill reads
// the container's magic); what that family brings - knowledge tables and a run guide - is
// named by its profile, and family_kit.py is the only reader of that. The tables join the
// common ones, and both lists go into every delegated prompt (familyContext). A profile
// that cannot be read costs the family's tables, never the run: it is said out loud and
// the run goes on with the common ones.
const kitRaw = await shell('family-kit', 'Analyze',
  `bash "${PLUGIN}/scripts/py.sh" family_kit.py ${shq(socFamily)}`,
  FAMILY_KIT_SCHEMA)
const kit = readFamilyKit(kitRaw)
familyName = kit.family
familyKnowledge = kit.knowledge
familyRunbook = kit.runbook
familyProfile = kit.profile
KNOWLEDGE = composeKnowledge(familyKnowledge)
kit.warnings.forEach(w => log(`[계열] ⚠ ${w}`))
log(`[계열] ${familyName} — 지식표 ${KNOWLEDGE.split(', ').length}개 ` +
    `(계열 전용 ${familyKnowledge.length}개), 진행 가이드 ${familyRunbook || '없음'}`)
await shell('family-decision', 'Analyze',
  `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('계열 자료')} ` +
  `${shqWhole(`${familyName}: 계열 지식표 ${familyKnowledge.join(', ') || '없음'} · ` +
         `진행 가이드 ${familyRunbook || '없음'}`)} ` +
  `${shqWhole(`soc_family=${socFamily} 의 프로필(family_kit.py)` +
         (kit.warnings.length ? ` — 주의: ${kit.warnings.join(' / ')}` : ''))} || true`,
  OK_SCHEMA)

// The architecture of the first stage. An explicit `arch` input wins and is journaled as given.
// Otherwise it is DERIVED from the container (stage_map.py --detect-arch: a header-declared
// entry, a vector table, a start-up stub). "unknown" is a legitimate answer and nothing
// defaults silently: the stage map is then drawn under BOTH readings (archProbeCmd) and the
// reading that finds an entry signature is used, PROVISIONALLY - or BLOCKED_ARCH, naming this
// basis, when no reading or both readings have one, or one could not be run (see below).
function detectArchCmd() {
  return `bash "${PLUGIN}/scripts/py.sh" stage_map.py --detect-arch ${shq(bootloader_path)}; RC=$?\n` +
         `echo "detect_arch_exit=$RC"\n` +
         `# Report exit_code from the detect_arch_exit= line, and arch, entry_signature, basis and\n` +
         `# confidence from the ONE JSON object it printed on stdout (leave them out when it printed none).`
}
// The decision text is the pipeline's own and carries the detect-arch basis, so it goes in whole
// (shqWhole): a journal line cut at 400 characters loses the reason and the way to resume.
const archDecisionCmd = (what, why) =>
  `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('아키텍처')} ${shqWhole(what)} ${shqWhole(why)} || true`

/* The two readings of the container, drawn by the stage-map tool itself. detect-arch could not
 * name an architecture, and the tool has two different ways to say "no entry signature": arm32
 * exits 3 (arch_supported=false); arm64 NEVER exits 3 - its map always succeeds, with an `exec`
 * stage even for random bytes - so there the signature is the map's `entry_stubs` list (a
 * CurrentEL read with a vector-base write beside it), which is also the only AArch64 signature
 * detect-arch knows. The maps go to 08_docs/arch_probe_<arch>.json, never to stage_map.json: they
 * are evidence for the choice, not the analyst's map. The count is taken out of the JSON with awk
 * (json.dump's two-space layout: a stub is a line of four spaces and an opening brace inside the
 * top-level key), and a map with no such key prints "-", which the verdict reads as "could not
 * tell", not as zero. */
function archProbeCmd() {
  return inBash(
    `IMG=${shq(bootloader_path)}\n` +
    `OUT=${shq(`${workdir}/08_docs`)}\n` +
    `mkdir -p "$OUT"\n` +
    `for A in arm32 arm64; do\n` +
    `  F="$OUT/arch_probe_$A.json"; rm -f "$F"\n` +
    `  bash "${PLUGIN}/scripts/py.sh" stage_map.py "$IMG" --arch "$A" --quiet --out "$F" >/dev/null 2>"$OUT/arch_probe_$A.err"; RC=$?\n` +
    `  N=-\n` +
    `  if [ -s "$F" ]; then\n` +
    `    N=$(awk '/^  "entry_stubs":/ { seen = 1; if ($0 ~ /\\[\\],?[ ]*$/) { inb = 0 } else { inb = 1 }; next }\n` +
    `             inb && /^  "/ { inb = 0 }\n` +
    `             inb && /^    \\{/ { n++ }\n` +
    `             END { if (seen) print n + 0; else print "-" }' "$F")\n` +
    `  fi\n` +
    `  echo "probe_$A exit=$RC entry_stubs=$N"\n` +
    `done\n` +
    `# Report arm32_exit and arm64_exit from the exit= values, arm32_entry_stubs and arm64_entry_stubs\n` +
    `# from the entry_stubs= values (null where it printed -). Do not read the JSON files yourself.`)
}

/* What the two readings found. Pure, so a test can feed it the real tool's output. Outcomes:
 *   one            exactly one reading has an entry signature -> `arch` is that reading (provisional)
 *   none           neither does                               -> BLOCKED_ARCH
 *   both           both do                                    -> BLOCKED_ARCH (not decided; no default)
 *   unconfirmable  a reading could not be run or read         -> BLOCKED_ARCH (an absent answer is
 *                  not "no signature": the tool may have failed, so nothing is concluded from it) */
function archProbeVerdict(p) {
  const num = v => (v === null || v === undefined || v === '' || !Number.isFinite(Number(v))) ? null : Number(v)
  const r32 = { exit: num(p?.arm32_exit), stubs: num(p?.arm32_entry_stubs) }
  const r64 = { exit: num(p?.arm64_exit), stubs: num(p?.arm64_entry_stubs) }
  // arm32: 0 = an entry signature (GFH entry, vector table, crt0), 3 = none, anything else = the run failed
  const s32 = r32.exit === 0 ? 'found' : r32.exit === 3 ? 'none' : 'failed'
  // arm64: no signature gate of its own (never exits 3), so a signature is a non-empty entry_stubs list
  const s64 = r64.exit === 3 ? 'none'
    : r64.exit !== 0 || r64.stubs === null ? 'failed'
    : r64.stubs > 0 ? 'found' : 'none'
  const say = [
    s32 === 'found' ? 'arm32 해석: 종료코드 0 — 진입 시그니처 있음'
      : s32 === 'none' ? 'arm32 해석: 종료코드 3 — 진입 시그니처 없음'
      : `arm32 해석: 실행하지 못했거나 결과를 읽지 못함 (종료코드 ${r32.exit ?? '보고 없음'})`,
    s64 === 'found' ? `arm64 해석: 종료코드 0, 진입 스텁 ${r64.stubs}개 — 진입 시그니처 있음`
      : s64 === 'none' ? `arm64 해석: 종료코드 ${r64.exit}, 진입 스텁 0개 — 진입 시그니처 없음 ` +
                         '(이 모드는 종료코드 3 을 내지 않아 스텁 수로 판단)'
      : `arm64 해석: 실행하지 못했거나 결과를 읽지 못함 (종료코드 ${r64.exit ?? '보고 없음'}, 스텁 수 ${r64.stubs ?? '보고 없음'})`,
  ]
  const states = { arm32: s32, arm64: s64 }
  if (s32 === 'failed' || s64 === 'failed') return { outcome: 'unconfirmable', arch: null, say, states }
  if (s32 === 'found' && s64 === 'found') return { outcome: 'both', arch: null, say, states }
  if (s32 === 'none' && s64 === 'none') return { outcome: 'none', arch: null, say, states }
  return { outcome: 'one', arch: s32 === 'found' ? 'arm32' : 'arm64', say, states }
}

/* The BLOCKED_ARCH text for a probe that did not name exactly one reading. */
function archProbeBlocker(v) {
  const head = `아키텍처를 도출하지 못했고(stage_map.py --detect-arch: unknown — 근거 ${archBasis.join(' / ') || '없음'}) ` +
               `스테이지 도출기를 arm32 · arm64 두 해석으로 돌려 봤으나 `
  const resume = 'arch 입력으로 arm32 또는 arm64 를 명시하면 그 해석으로 이어서 진행합니다'
  if (v.outcome === 'none') {
    return head + `어느 쪽에서도 진입 시그니처(컨테이너 헤더가 선언한 진입점 · 페이로드 선두의 벡터 테이블 · 시작 코드 · ` +
      `AArch64 CurrentEL/VBAR 스텁)를 찾지 못했습니다 — ${v.say.join('; ')}. arm64 를 기본값으로 삼지 않으므로 어느 쪽으로도 ` +
      `진행하지 않고 정지합니다. 펌웨어의 한계가 아니라 도구의 결손입니다 — ${resume}`
  }
  if (v.outcome === 'both') {
    return head + `양쪽 모두에서 진입 시그니처가 나와 어느 쪽인지 정하지 못했습니다 — ${v.say.join('; ')}. ` +
      `기본값을 고르지 않고 정지합니다. 도출기가 정하지 못한 것이지 펌웨어가 실행 불가라는 판정이 아닙니다 — ${resume}`
  }
  return head + `그 결과를 확인하지 못했습니다 — ${v.say.join('; ')}. 이미지를 읽지 못했거나 도구가 실패한 경우라 ` +
    `시그니처가 없다고 판단할 수 없어 정지합니다 (08_docs/arch_probe_<arch>.err 가 도구의 stderr 입니다). ${resume}`
}

if (archGiven) {
  log(`[분석] 아키텍처 ${arch} — arch 입력으로 지정됨 (도출하지 않습니다)`)
  await shell('arch-decision', 'Analyze',
    archDecisionCmd(`${arch} (입력으로 지정)`,
      'arch 입력이 명시되어 그대로 따릅니다 — stage_map.py --detect-arch 는 돌리지 않았습니다'), OK_SCHEMA)
} else {
  if (archInput && archInput !== 'auto' && archInput !== 'unknown') {
    log(`[분석] ⚠ arch 입력 "${archInput}" 은 arm32 · arm64 가 아니어서 쓰지 않고 도출합니다`)
  }
  const det = await shell('detect-arch', 'Analyze', detectArchCmd(), DETECT_ARCH_SCHEMA)
  const found = String(det?.arch ?? '').trim().toLowerCase()
  const exitOk = !!det && Number(det.exit_code ?? 0) === 0
  archBasis = (Array.isArray(det?.basis) ? det.basis : []).map(x => String(x).trim()).filter(Boolean)
  const signature = det?.entry_signature ?? 'none'
  if (exitOk && ARCHES.includes(found)) {
    arch = found
    log(`[분석] 아키텍처 ${arch} — stage_map.py --detect-arch 도출 (진입 시그니처 ${signature}, ` +
        `확신 ${det?.confidence ?? '?'}): ${archBasis.join(' / ') || '(근거 줄 없음)'}`)
    await shell('arch-decision', 'Analyze',
      archDecisionCmd(`${arch} (도출 — 진입 시그니처 ${signature}, 확신 ${det?.confidence ?? '?'})`,
                      archBasis.join(' / ') || '근거 줄 없음 (detect-arch 가 basis 를 주지 않았습니다)'), OK_SCHEMA)
  } else {
    archUnresolved = true
    const reason = !det ? 'stage_map.py --detect-arch 의 결과를 얻지 못했습니다'
      : !exitOk ? `stage_map.py --detect-arch 가 종료코드 ${det.exit_code} 로 끝났습니다 (이미지를 읽지 못했습니다)`
      : found === 'unknown' ? 'detect-arch 의 답이 unknown 입니다'
      : `detect-arch 의 답 "${det.arch}" 은 arm32 · arm64 · unknown 중 하나가 아닙니다`
    // detect-arch's own basis lines explain a clean "unknown"; any other failure adds its own reason first
    if (!archBasis.length || !exitOk || found !== 'unknown') archBasis.unshift(reason)
    log(`[분석] ★ 아키텍처를 도출하지 못했습니다 — ${reason}. 근거: ${archBasis.join(' / ')}. ` +
        `arm64 를 기본값으로 삼지 않습니다: stage_map.py 를 arm32 · arm64 두 해석으로 돌려 진입 시그니처가 ` +
        `나온 쪽만 임시로 따르고, 어느 쪽에도 없거나 양쪽에 다 있거나 돌리지 못하면 BLOCKED_ARCH 로 정지합니다.`)
    await shell('arch-decision', 'Analyze',
      archDecisionCmd('unknown — 기본값 없음, 스테이지 도출기의 두 해석(arm32 · arm64) 비교로 정함',
                      `${reason}. 근거: ${archBasis.join(' / ')}`), OK_SCHEMA)
  }
}

// detect-arch could not decide, so the container's reading is open - and it is closed by the
// stage-map tool's own output under both readings, not by drawing an arm64 map and calling it a
// success: that map succeeds (exit 0, an `exec` stage) for an AArch32 image and for random bytes
// alike. Exactly one reading with an entry signature is used (still PROVISIONAL: detect-arch
// did not confirm it, and the analyst is told so); anything else stops here as BLOCKED_ARCH,
// before the analyst and before any build, with the detect-arch basis and what each reading found.
if (archUnresolved) {
  const probeRaw = await shell('arch-probe', 'Analyze', archProbeCmd(), ARCH_PROBE_SCHEMA)
  archProbe = archProbeVerdict(probeRaw)
  log(`[분석] 두 해석으로 스테이지 지도를 그려 봤습니다 — ${archProbe.say.join('; ')}`)
  if (archProbe.outcome !== 'one') {
    const detail = archProbeBlocker(archProbe)
    await shell('arch-probe-decision', 'Analyze',
      archDecisionCmd(`정하지 못함 (${archProbe.outcome}) — BLOCKED_ARCH`, detail), OK_SCHEMA)
    return await stopForBlocker('BLOCKED_ARCH', detail,
      archProbe.outcome === 'both'
        ? '두 해석 모두에서 진입 시그니처가 나와 도출기가 어느 쪽인지 정하지 못했습니다. 펌웨어가 실행 불가하다는 판정이 아닙니다. ' +
          'arch 입력으로 arm32 또는 arm64 를 명시한 뒤 같은 명령을 다시 실행하면 그 해석으로 이어서 진행됩니다.'
        : null)
  }
  arch = archProbe.arch
  log(`[분석] 진입 시그니처는 ${arch} 해석에서만 나왔습니다 — ${arch} 로 진행합니다. detect-arch 가 확인한 것이 ` +
      `아니므로 임시입니다 (분석가의 스테이지 도출이 같은 해석으로 성공하는지 다시 봅니다).`)
  await shell('arch-probe-decision', 'Analyze',
    archDecisionCmd(`${arch} 임시 — 두 해석 중 ${arch} 에서만 진입 시그니처가 나옴`,
      `detect-arch 는 unknown 이었음 (${archBasis.join(' / ')}). stage_map.py 를 두 해석으로 돌린 결과: ` +
      `${archProbe.say.join('; ')}. 시그니처 유무는 종료코드와 진입 스텁 수로 읽었고 분석가의 응답이 아닙니다 ` +
      `(지도는 08_docs/arch_probe_arm32.json · arch_probe_arm64.json). detect-arch 가 확인한 값이 아니므로 임시입니다`),
    OK_SCHEMA)
}

// The kernel-side boot assets (Image, DTB, initrd, super). Staging them is mechanical - a
// standard Android boot image unpack, "도출 아님" in the script's own words - so the PIPELINE
// does it before the analyst looks, and the analyst judges assets_ok on what is staged. It
// used to be left to a person ("point the user at extract_boot_assets.sh"), which turned every
// default F2 run into a BLOCKED_ASSET that waited for a human. The script is idempotent and
// non-interactive (it leaves fw/ as it was when it fails, and does not unpack a multi-GB super
// that fw/ already holds), so the pipeline simply runs it each time. F1 needs no kernel side,
// so it stages nothing. Exit codes (the script's own header): 0 staged; 4 the super could not be
// unpacked (the boot side is already in fw/, so it is `partial`, not a failure); 1 usage, 2 an input
// missing, 3 boot.img unparseable - all `failed`, with fw/ left as it was (ASSET_EXIT_MEANING says
// which). The result is read from fw/ itself, not from the exit code alone.
function stageAssetsCmd() {
  return inBash(
    `WD=${shq(workdir)}\n` +
    `UP="$WD/02_unpacked"; FW="$WD/fw"; LOG="$WD/08_docs/assets_staging.txt"\n` +
    `BOOT="$UP/boot.img"\n` +
    `SUPER=""; for f in "$UP/super.img" "$UP/super.img.lz4"; do if [ -f "$f" ]; then SUPER="$f"; break; fi; done\n` +
    `DTB=""; for f in "$UP"/*.dtb; do if [ -f "$f" ]; then DTB="$f"; break; fi; done\n` +
    `STATE=""; RC=""; SUM=""\n` +
    `if [ ! -f "$BOOT" ]; then\n` +
    `  STATE="no_boot_img"\n` +
    `else\n` +
    `  mkdir -p "$FW" "$WD/08_docs"\n` +
    `  bash "${PLUGIN}/scripts/extract_boot_assets.sh" "$WD" "$BOOT" "$SUPER" "$DTB" > "$LOG" 2>&1; RC=$?\n` +
    `  case "$RC" in 0) STATE="staged";; 4) STATE="partial";; *) STATE="failed";; esac\n` +
    `  if [ "$STATE" != "staged" ]; then tail -n 5 "$LOG" >&2; fi\n` +
    `  SUM=$(grep '^assets: ' "$LOG" 2>/dev/null | tail -n 1)\n` +
    `fi\n` +
    `echo "assets_staging=$STATE"\n` +
    `if [ -n "$RC" ]; then echo "assets_exit=$RC"; fi\n` +
    `yn() { if [ -s "$1" ]; then echo yes; else echo no; fi; }\n` +
    `echo "staged_image=$(yn "$FW/Image")"\n` +
    `DT=no; for f in "$FW"/*.dtb "$FW/dtb"; do if [ -s "$f" ]; then DT=yes; break; fi; done\n` +
    `echo "staged_dtb=$DT"\n` +
    `echo "staged_initrd=$(yn "$FW/initramfs.cpio.gz")"\n` +
    `echo "staged_super=$(yn "$FW/super.img")"\n` +
    `echo "super_source=\${SUPER:-none}"\n` +
    `echo "script_summary=$SUM"\n` +
    `echo "staging_log=$LOG"\n` +
    `# Report staging from assets_staging=, exit_code from assets_exit= (null when absent), image / dtb /\n` +
    `# initrd / super as true for yes and false for no, super_source, summary and log from their lines.`)
}

/* What each exit code of scripts/extract_boot_assets.sh means (documented in its header).
 * 0 staged; 4 is the PARTIAL case, handled by the `partial` state. An exit the header does not
 * list gets no explanation - it is reported by its number and its log, not guessed at. */
const ASSET_EXIT_MEANING = {
  1: 'the script was called with too few arguments (a pipeline fault, not the package)',
  2: 'an input file is missing or unreadable (boot.img, or the super image it was given)',
  3: 'boot.img could not be parsed (not an Android boot image, truncated, no kernel in it, or a corrupt gzip kernel) - fw/ keeps what it held before',
  4: 'the super image could not be unpacked (lz4 missing, or the unpack failed)',
}
const assetExitText = code => (ASSET_EXIT_MEANING[Number(code)] ? `: ${ASSET_EXIT_MEANING[Number(code)]}` : '')

/* What staging left, for the analyst's prompt, the journal and the log. */
function assetStagingText(st) {
  if (!st) return 'the pipeline could not report the staging result - look at what is in fw/ yourself'
  if (st.staging === 'skipped_f1') return 'not staged: the target is F1, which needs no kernel side'
  const have = `Image ${st.image ? 'yes' : 'no'}, dtb ${st.dtb ? 'yes' : 'no'}, ` +
               `initrd ${st.initrd ? 'yes' : 'no'}, super ${st.super ? 'yes' : 'no'}`
  // The script's last line says what kind of super it left: a sparse one that was not converted
  // to raw is still not a usable rootfs source, and the analyst must not read "super yes" as ready.
  const sparse = /super=sparse\b/.test(st.summary ?? '')
    ? '; the super image is still SPARSE, not converted to raw (the script retries on the next run)' : ''
  return ({
    staged: `staged from 02_unpacked/boot.img by scripts/extract_boot_assets.sh (${have}${st.summary ? `; script: ${st.summary}` : ''}${sparse})`,
    partial: `staged PARTIALLY: the kernel side is in fw/ but the super image could not be unpacked ` +
             `(exit ${st.exit_code ?? 4}${assetExitText(st.exit_code ?? 4)}; log ${st.log ?? '08_docs/assets_staging.txt'}) (${have})`,
    no_boot_img: `NOT staged: the package has no 02_unpacked/boot.img (${have})`,
    failed: `staging FAILED (exit ${st.exit_code ?? '?'}${assetExitText(st.exit_code)}; log ${st.log ?? '08_docs/assets_staging.txt'}) (${have})`,
  })[st.staging] ?? `staging reported "${st.staging}" (${have})`
}

let assetStaging = target === 'F1' ? { staging: 'skipped_f1' } : null
if (target !== 'F1') {
  assetStaging = await shell('stage-assets', 'Analyze', stageAssetsCmd(), ASSET_STAGE_SCHEMA)
  if (!assetStaging) log('[분석] ⚠ 커널 자산 적재 결과를 얻지 못했습니다 — analyst 가 fw/ 의 실제 내용으로 판정합니다.')
}
log(`[분석] 커널 자산: ${assetStagingText(assetStaging)}`)
await shell('assets-decision', 'Analyze',
  `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('커널 자산 적재')} ` +
  `${shqWhole(assetStagingText(assetStaging))} ` +
  `${shq('표준 boot image 언팩이라 도출이 아니며 파이프라인이 합니다 (scripts/extract_boot_assets.sh). ' +
         'assets_ok 판정은 적재된 fw/ 의 실제 내용으로 analyst 가 합니다')} || true`,
  OK_SCHEMA)

// The ladder past the stage rungs and the surface, which does not depend on the map. The
// stage rungs are named from the map the analyst is about to derive, so the prompt gives their
// naming rule and the pipeline checks the token file against the exact names afterwards.
const tailRungs = goalsFor('none').slice(stageRungs.length)

/* Where the architecture in this run's prompts came from, so an agent never reads a guess as a fact. */
function archPromptNote() {
  if (archGiven) return `   (${arch} was given as an input and is used as given - it was not derived.)\n`
  if (archUnresolved) {
    return `   ★ ${arch} is PROVISIONAL: stage_map.py --detect-arch could not decide (${archBasis.join(' / ')}).\n` +
           `   So the caller ran the stage map under BOTH readings (maps: ${workdir}/08_docs/arch_probe_arm32.json and\n` +
           `   arch_probe_arm64.json) and read the entry signature from the tool's own output: ${(archProbe?.say ?? []).join('; ')}.\n` +
           `   Only ${arch} has one, which is why you are told to use it - a reading the tool supports, not a default.\n` +
           `   Run the stage map with it as asked, do not switch to another --arch on your own and do not invent a\n` +
           `   stage. If YOUR run contradicts the probe (arm32: exit 3; arm64: an empty "entry_stubs" list in the\n` +
           `   JSON - that mode never exits 3), report arch_supported=false and say what you saw: the caller then\n` +
           `   stops with BLOCKED_ARCH and names that basis. If it agrees, say in STATIC.md that the architecture was\n` +
           `   settled by the two-reading stage map and not by detect-arch, and copy the probe lines above.\n`
  }
  return `   (${arch} was derived by stage_map.py --detect-arch: ${archBasis.join(' / ') || 'no basis lines given'}.\n` +
         `   Write those basis lines into STATIC.md: the pipeline journals the decision, but the classifier and the\n` +
         `   fixers read STATIC.md, and a fact only in this prompt reaches nobody.)\n`
}

const prior = await agent(
  `Run in mode=prior: derive every fact needed to build the machine model.\n` +
  `target=${target}, soc_family=${socFamily}, arch=${arch}\n` +
  `Input: ${workdir}/INPUT.md\n` +
  `Bootloader container: ${bootloader_path}\n` +
  `Boot assets (kernel side): ${workdir}/fw/ - ${assetStagingText(assetStaging)}\n` +
  `   The PIPELINE staged them (scripts/extract_boot_assets.sh, from 02_unpacked), so there is nothing\n` +
  `   left for a person to extract and you never tell the user to run that script. Judge assets_ok\n` +
  `   (checklist K1) on what is IN fw/: report assets_ok=false only when a needed asset is truly absent\n` +
  `   after staging, and say which one and why (the package has no such member / the staging failed -\n` +
  `   read its log).\n` +
  `Profile hints: ${abs(familyProfile)} (hints about WHERE to look, never values)\n` +
  familyContext() +
  `Architecture and family: pass --arch ${arch} --family ${familyFlag()} to EVERY carve_disasm.py call, and\n` +
  `--arch ${arch} to stage_map.py - the carve yardstick and the disassembler mode depend on them, and the\n` +
  `default (arm64) judges an AArch32 image wrongly. A stage whose own derived arch differs gets that arch.\n` +
  `--family selects the string and size yardsticks carve_check measures against; a family with no\n` +
  `yardstick of its own gets none, and with no container-header evidence either carve_check answers\n` +
  `is_full null (undetermined) with a note. Report carve_check's answer as it is - carve_is_full true,\n` +
  `false or null, and for null the note as carve_note; never turn null into true or false. The caller\n` +
  `stops with BLOCKED_CARVE on false only; null goes on and is journaled as undetermined.\n` +
  archPromptNote() +
  `\nThis run rehosts ONE chain: the container is loaded once and every stage after\n` +
  `the first is reached by the firmware's own code. Derive it in this order.\n\n` +

  `1. STAGE MAP - run it, do not eyeball it. The tool maps ONE image per run:\n` +
  `     bash "${PLUGIN}/scripts/py.sh" stage_map.py ${shq(bootloader_path)} \\\n` +
  `       --arch ${arch} --profile ${socFamily} --origin container --out ${stageMap}\n` +
  `   A chain does not always live in one container. An image the first stage loads\n` +
  `   from the MEDIUM (a later bootloader's partition) gets its own run:\n` +
  `     ... stage_map.py <that image> --arch <its arch> --profile ${socFamily} \\\n` +
  `       --origin medium --partition <name> --out ${workdir}/08_docs/stage_map_<name>.json\n` +
  `   The architecture belongs to the IMAGE, not to the run: a chain can mix ISAs, so one --arch for\n` +
  `   every image is wrong. The Architecture line above is the CONTAINER's. For each LATER image ask\n` +
  `   the tool for that image's own, and pass the answer to that image's stage_map.py --arch (and to\n` +
  `   its carve_disasm.py calls):\n` +
  `     bash "${PLUGIN}/scripts/py.sh" stage_map.py --detect-arch <that image>\n` +
  `   It prints ONE JSON object {arch, entry_signature, basis, confidence} and exits 0, "unknown"\n` +
  `   included. Exit 2 = the file cannot be read; exit 64 = you combined the flag with an image or\n` +
  `   --merge (your own mistake). Write the basis lines into STATIC.md. "unknown" is an answer, not a\n` +
  `   default, and for a later image nobody else can decide it: run the stage map on it with\n` +
  `   --arch arm32 and with --arch arm64 and read the ENTRY SIGNATURE out of each - the two modes do\n` +
  `   not say "none" the same way. Under arm32 exit 3 = no entry signature. Under arm64 the tool NEVER\n` +
  `   exits 3 (its map succeeds for an AArch32 image and for random bytes alike, with an exec stage), so\n` +
  `   there a signature is a non-empty "entry_stubs" list in the JSON it wrote; an empty list is none.\n` +
  `   Keep the reading that has a signature. If neither has one, report arch_supported=false; if both\n` +
  `   do, do not pick one silently - record both in STATIC.md and leave that image's stages unconfirmed.\n` +
  `   Say in STATIC.md how each image's arch was decided (detect-arch, or the reading that had a signature).\n` +
  `   (The CONTAINER is different: its reading, provisional or not, is the caller's call and you never\n` +
  `   swap it for another one yourself.)\n` +
  `   Each run numbers its stages from 0. With several images, write the first run to\n` +
  `   ${workdir}/08_docs/stage_map_container.json instead of ${stageMap}, then combine\n` +
  `   them in chain order with the tool (it renumbers the stages, records the image\n` +
  `   each came from, and re-derives nothing):\n` +
  `     bash "${PLUGIN}/scripts/py.sh" stage_map.py --merge <first.json> <second.json> ... \\\n` +
  `       --out ${stageMap}\n` +
  `   A stage that\n` +
  `   no image carries (an EL3 monitor, a TEE, the kernel) is not derived by the tool;\n` +
  `   add one only with evidence you can cite (a load address read from a log, a\n` +
  `   trace PC) and mark its confidence honestly.\n` +
  `   Read the exit code. Exit 3 means NO entry signature was found in the image (a\n` +
  `   header-declared entry, a vector table at the payload start, a start-up stub).\n` +
  `   That is NOT "no stages": report arch_supported=false and stop - the caller\n` +
  `   raises BLOCKED_ARCH, and says it is a gap in the tool, not a limit of the\n` +
  `   firmware. Exit 0 is never arch_supported=false, even when a stage comes back\n` +
  `   unconfirmed. Only arm32 mode has this gate: --arch arm64 never exits 3, so its exit\n` +
  `   code says nothing about a signature (the "entry_stubs" list does - see above).\n` +
  `   Then READ the JSON (schema v2: every stage has arch, origin, entered_by, entry_pc,\n` +
  `   anchors, confidence, container) and confirm each stage against the binary.\n` +
  `   state is "exec" (runnable), "encrypted" (skipped, needs a skip plan) or\n` +
  `   "unconfirmed" (the anchors did not converge: the candidates and the rejected\n` +
  `   anchors with their reasons are listed, and the stage is NOT runnable - it is not\n` +
  `   encrypted either, so it gets no skip plan; derive its base or leave it\n` +
  `   unconfirmed). confidence "derived" (one anchor, AArch64) and "cross_checked" (two\n` +
  `   independent anchors, AArch32) both count as confirmed; "unconfirmed" does not.\n` +
  `   For a stage that is not confirmed either find the literal anchor yourself or\n` +
  `   report its base as 미확정. A base with no anchor is a candidate, and building on a\n` +
  `   candidate costs a rebuild. Copy the container evidence and the anchors into\n` +
  `   STATIC.md (honesty rule 6): a value only in your answer reaches nobody.\n` +
  `   Return the confirmed list as "stages": each entry needs\n` +
  `   {name, arch: "aarch32"|"aarch64", origin: "container"|"medium"|"handoff", partition,\n` +
  `    file_range, state: "exec"|"encrypted"|"unconfirmed", load_base, entry_pc, confidence}.\n` +
  `   The goal ladder is built from this, so a stage you cannot place is a\n` +
  `   stage the loop cannot aim at.\n\n` +

  `2. SKIP PLAN. For each ENCRYPTED stage (not an unconfirmed one), say which executable stage the\n` +
  `   previous one must be redirected to, and PROVE the skip is safe: list the\n` +
  `   absolute addresses the next stage reads before it writes anything, and\n` +
  `   classify each as a hardware register (fine - the machine models it) or a\n` +
  `   word the skipped stage wrote (a handoff that must be supplied, and that\n` +
  `   supply is a documented bypass). If you cannot classify one, say 미확정 -\n` +
  `   do not assume it is a register.\n\n` +

  `3. HANDOFF SURFACE of the FIRST stage. It has no predecessor here, so\n` +
  `   whatever the boot ROM left it must be modelled. Find the slots it calls\n` +
  `   through (a constant address loaded, then an indirect call) and, for each,\n` +
  `   derive the contract from the ARGUMENT SETUP at the call sites - not from\n` +
  `   what the slot's position suggests. Report the count and each slot's\n` +
  `   evidence. The count is small and bounded; modelling the whole boot ROM is\n` +
  `   neither necessary nor possible.\n\n` +

  `4. INTERACTIVE SURFACE` +
  (surfaceDeclared ? ` (setup's hint: ${surface} - confirm or correct it)` : ' (no hint given)') +
  `.\n   A command table existing in the binary does NOT mean it is reachable:\n` +
  `   - UART: does the driver have a receive path (RBR read / rx polling)?\n` +
  `   - USB: which dispatchers exist, and do any reference the command table?\n` +
  `   Report bl_surface as "shell", "fastboot", or "none". "none" is a legitimate\n` +
  `   result, not a blocker: it means the bootloader logs and boots on without\n` +
  `   input (autoboot). The pipeline then drops the surface rung from the ladder\n` +
  `   and the run OBSERVES whether the firmware really waits for input; it stops\n` +
  `   on that observation, never on your derivation. Say "none" when nothing has an\n` +
  `   input path, and do not invent a route to avoid it.\n\n` +

  `5. AUTOBOOT GATE INPUT PATTERN. The gate polls the console and counts a run\n` +
  `   of one byte (usually CR, 0x0d) before handing over; miss it and the\n` +
  `   surface is unreachable no matter what else is right. Disassemble the gate\n` +
  `   (the shell function's first bl) and write ${workdir}/input_plan.json.\n` +
  `   A bootloader with no surface has no such gate: write no file then.\n` +
  `     {"autoboot_interrupt": {"bytes": "\\r", "count": <N>,\n` +
  `      "contiguous": <bool>, "empty_poll_budget": <N>, "one_shot": <bool>,\n` +
  `      "gate_addr": "0x...", "evidence": "<disassembly line + bytes>"}}\n` +
  `   Every property the harness needs must be its OWN FIELD. If you cannot\n` +
  `   derive N, write no file - the harness then sends NO interrupt pattern at all (it has no\n` +
  `   built-in default to fall back on) and records the plan source as absent. Say 미확정 in\n` +
  `   STATIC.md and what would decide it: a gate that needs an interrupt then stays unreachable,\n` +
  `   which is an observation to report, not a gap to fill with a guessed pattern.\n\n` +

  `6. BOOT MEDIUM. The bootloader reads the next stage from it, so the model\n` +
  `   must answer. Derive from the DTB (authoritative) the controller register\n` +
  `   bases and its interrupt. Derive from the bootloader's own strings the\n` +
  `   PARTITION NAMES it looks up - build_lu.py must synthesise the medium under\n` +
  `   those names.\n` +
  `   ⚠ Do NOT scan for 4-byte literals to find MMIO bases: AArch64 builds\n` +
  `   constants with MOVZ/MOVK, so a literal scan finds coincidental byte\n` +
  `   sequences and misses the real base. Confirm against the DTB.\n` +
  `   The KIND of medium (eMMC or UFS) is derived, never assumed: a device tree carries\n` +
  `   a UFS host node whether or not the board uses it. The pipeline runs\n` +
  `   ${PLUGIN}/scripts/detect_medium.py before Build and again on the first bootloader log, and\n` +
  `   records its answer in STATIC.md; you may run it yourself. "unknown" is an answer:\n` +
  `   record 미확정 and let the first bootloader log decide. ${workdir}/lu_manifest.json\n` +
  `   entries take kind (firmware|zero|synthesized|forged|modified; absent = firmware),\n` +
  `   size (bytes; a zero entry needs it), lba (a FIXED start, in blocks of this medium,\n` +
  `   derived from the bootloader) and vendor (a label), and the top level takes\n` +
  `   medium ("emmc"|"ufs", left out while unknown). A structure the firmware expects\n` +
  `   that no firmware image carries (a partition table of its own, boot parameters, a\n` +
  `   forged AVB chain) is written by you per firmware into fw/ and passed in as\n` +
  `   synthesized or forged - build_lu.py never builds vendor structures. A firmware\n` +
  `   partition whose bytes we edit is kind modified, and bypasses.md records it (type I).\n` +
  `   A medium you cannot decide is not guessed: write 미확정 and say what would decide it.\n\n` +

  `7. VERIFIED BOOT. Locate the bootloader's own verification (AVB or vendor):\n` +
  `   where the key store lives, what the vbmeta partition is called, whether\n` +
  `   hash/RSA are software in the image (then TCG runs them and no accelerator\n` +
  `   model is needed) or a hardware block (a crypto engine reached through a monitor\n` +
  `   call or MMIO). Report where the rollback index is read from.\n` +
  `   When the digest and signature code is SOFTWARE, the images are genuinely signed\n` +
  `   and verification is expected to PASS unpatched - anything suggesting otherwise is\n` +
  `   a finding, not a licence to patch. When the engine is HARDWARE, that premise is\n` +
  `   false and "pass unpatched" is not on offer. The honest order is: (a) model the\n` +
  `   engine so the digest is really computed; only if that is not feasible, (b) a\n` +
  `   labelled bypass - every one carries the F mark in bypasses.md and the run reports\n` +
  `   verify_ok as reached_bypassed with the count. Never describe a stubbed comparison as a\n` +
  `   passed verification.\n` +
  `   RECORD WHICH CASE THIS IS as the \`hash_engine\` row in STATIC.md - the shape and the rules are\n` +
  `   step 14d of ${abs('agents/static-analyzer.md')}: a table row \`| hash_engine | hardware or\n` +
  `   software | <evidence> |\` (the one-line form \`hash_engine: hardware (evidence: ...)\` is also read)\n` +
  `   whose evidence cell holds a 0x function address or SMC id of the digest path. While it is\n` +
  `   undecided write NO row (미확정 in the prose, and what would decide it): a row without a hex\n` +
  `   address does not count. STATIC.md is append-only, so a corrected answer is a LATER row and the last\n` +
  `   one wins; never put the row inside a code fence. Only you write this row - a fixer must not.\n` +
  `   Without it fixer-secureboot and verify.py's hash_engine state never see an answer, and\n` +
  `   check_change.sh rejects a labelled (F) hash, digest or signature bypass that has no hardware row.\n` +
  `   Also write ${workdir}/status_tokens.txt - the firmware's OWN status lines about secure-boot\n` +
  `   enablement, device lock state and hash/signature mismatch, one string per line, each\n` +
  `   located at a file offset in this firmware. The verification report looks them up in the\n` +
  `   guest console and no script carries any; none located means no file.\n\n` +

  `8. MILESTONE TOKENS. The ladder is one rung per EXECUTABLE stage of the map you derive in\n` +
  `   item 1, then the surface rung (named after bl_surface - "shell" or "fastboot"; none when it\n` +
  `   is "none"), then ${tailRungs.length ? tailRungs.join(', ') : `(nothing further at target ${target})`}.\n` +
  `   A stage's rung is named \`<stage name>_entry\`: the stage's "name" in stage_map.json, each\n` +
  `   character outside [A-Za-z0-9_.-] replaced by "_"; a name that repeats takes its stage index\n` +
  `   before the suffix ("<name><index>_entry"); a stage whose rung would carry one of the tail's\n` +
  `   names gets no rung (the kernel is a stage in the map, but kernel_entry and kernel_alive are\n` +
  `   the tail's). The pipeline checks milestone_tokens.txt against the exact ladder once you\n` +
  `   answer and sends back what does not match, so use these names and no others. Write\n` +
  `   ${workdir}/milestone_tokens.txt as "<milestone>\\t<token>[\\t<channel>]" lines,\n` +
  `   channel being "uart" (the default when the column is absent - a two-column file\n` +
  `   keeps its old meaning) or "memdump" (the kernel log read out of guest RAM, see\n` +
  `   item 11). Use ONLY strings you located at a file offset in this firmware. The\n` +
  `   run script checks each against the machine source, and anything the machine\n` +
  `   also contains is treated as self-injection.\n` +
  `   A stage AFTER THE FIRST with no console string of its own (an EL3 monitor that prints\n` +
  `   nothing) gets NO token line: its entry is observed by its entry PC in the trace, and\n` +
  `   inventing a token for it is a guess. Say so in STATIC.md. The FIRST stage is different:\n` +
  `   its entry is where the machine itself puts the CPU, so seeing it execute proves nothing\n` +
  `   about the firmware - derive a token for it (its own first log line) or its rung stays\n` +
  `   unobserved.\n\n` +

  `   \`kernel_entry\` and \`kernel_alive\` must NOT share a token. The bootloader\n` +
  `   printing "Starting kernel..." proves it reached the handoff, not that the\n` +
  `   kernel ran - a kernel that never executes leaves that line as the LAST line\n` +
  `   of the console. Derive \`kernel_alive\` from the kernel image itself, banner\n` +
  `   first ("Linux version"), then alternates a running kernel prints (a line about\n` +
  `   freeing unused memory, the command line it received, ...) - each from a string\n` +
  `   in the KERNEL image. The two channels hold an alternate to different bars:\n` +
  `   - memdump: an alternate counts only when its line carries a kernel timestamp and the\n` +
  `     task that printed it (the scan enforces that); when only an alternate is seen the run\n` +
  `     records that the banner was not observed.\n` +
  `   - uart: a plain string match - nothing checks a kernel timestamp or a task. Whatever the\n` +
  `     token, the run records the banner as NOT VERIFIED on this channel (never as observed),\n` +
  `     so prefer the banner itself and do not expect an alternate to be held to the memdump bar.\n` +
  `   Put the channel the kernel's text actually arrives on in the third column: a kernel whose\n` +
  `   log goes to a RAM ring is "memdump", not "uart".\n\n` +

  `9. KERNEL COMMAND LINE. Write ${workdir}/cmdline_plan.json.\n` +
  `   A kernel booting perfectly can print NOTHING: if the bootloader selects\n` +
  `   \`console=ram\`, its output goes to a RAM buffer and the console ends at\n` +
  `   "Starting kernel..." exactly as it would if the jump had failed. Silence is\n` +
  `   then not evidence of failure, and treating it as a stop point sends fixers\n` +
  `   after a fault that does not exist.\n` +
  `     strings <bootloader> | grep -E 'console=|earlycon|bootargs'\n` +
  `   {"default": "<the one it selects>", "uart": "<console= plus earlycon= that\n` +
  `   reach the UART>", "partition": "<the partition the bootloader reads the command line\n` +
  `   from, exactly as lu_manifest.json names it>", "source": "<free-text evidence: where the\n` +
  `   command line comes from>", "evidence": "<addresses>"}\n` +
  `   plus an optional "offset": <bytes from the start of that partition, default 0>.\n` +
  `   build_lu.py writes the "uart" line into the partition the plan names - or into the one\n` +
  `   "source" names, only when that text is exactly a partition name. This is NOT a bypass - it\n` +
  `   uses the bootloader's own path and both strings already exist in the firmware.\n` +
  `   If the command line does not come from a partition on this firmware (built into the\n` +
  `   bootloader, or carried by the boot image header), write NO "partition" and put the real\n` +
  `   origin in "source": build_lu.py then writes nothing and prints warning_cmdline. ` +
  (familyFlag() === 'exynos'
    ? `A plan that\n` +
      `   names no partition at all (no "partition", no "source") falls back to a partition literally\n` +
      `   called param and prints warning_cmdline_target - that name is a guess, so name the partition.\n` +
      `   Both are warning_* keys: the Build step reports them to the supervisor. Do not guess.\n\n`
    : `A plan that\n` +
      `   names no partition at all (no "partition", no "source") writes nothing for this family either:\n` +
      `   the param fallback belongs to one family's layout and build_lu.py is told --family ${familyFlag()}, so it\n` +
      `   never guesses a partition name here. Name the partition. warning_cmdline is a warning_* key:\n` +
      `   the Build step reports it to the supervisor. Do not guess.\n\n`) +

  `10. KERNEL SIDE (needed for the upper rungs): boot image layout, whether a\n` +
  `   ramdisk exists (ramdisk_size=0 means system-as-root - there is no\n` +
  `   initramfs and userspace does not exist until storage works), DTB skeleton\n` +
  `   (cpu / memory / GIC / UART / storage node), and the security gate sites.\n` +
  (target === 'F1' ? '' :
  `   Report storage_driver {form: "module" | "builtin" | "absent", evidence} (checklist K4 of your\n` +
  `   instructions): only "absent" - no vendor .ko AND no driver in the kernel image - stops the run, and\n` +
  `   the caller then records BLOCKED_KO from your answer, so quote the evidence that decides it.\n` +
  `   Search for the drivers of THE MEDIUM THIS BOARD BOOTS FROM, not of one kind by habit: decide the kind first\n` +
  `   (item 6: the DTB's storage node, detect_medium.py; "unknown" is an answer) and grep the names that kind\n` +
  `   uses - eMMC: the mmc block and sdhci / dw_mmc host-controller drivers and the host driver the DTB node's\n` +
  `   compatible string names; UFS: ufshcd and the host driver the DTB node names. A search that tries only the\n` +
  `   other kind's names finds nothing and would read as "absent", which stops a run that can reach rootfs.\n` +
  `   "absent" needs evidence that names each command you ran (find over the .ko files, strings | grep over\n` +
  `   the kernel image) and its hit count. Without that - no evidence, or no count - the caller treats it as\n` +
  `   unconfirmed and does NOT stop: when you could not run the search or the medium kind is open, leave\n` +
  `   storage_driver out, write 미확정 in STATIC.md and say what would decide it.\n`) +
  `   Kernel patch sites, if the kernel genuinely needs any, go into\n` +
  `   ${workdir}/kernel_patch_sites.json as patch_kernel.py reads them\n` +
  `   ([{"off","expected","new","why"}], each derived from the kernel image and\n` +
  `   pre-image checked). No sites derived means no file: Build then skips the patch.\n\n` +

  `11. MEMORY-DUMP CHANNEL. If the kernel's log cannot reach the UART (a RAM console:\n` +
  `   pstore / ramoops), the UART stays silent while the kernel runs - silence is then\n` +
  `   not failure, and the kernel log is read out of guest RAM by the host instead.\n` +
  `   Where that ring lives is DERIVED, never typed: from the bootloader's reserved\n` +
  `   memory table or the kernel command line it builds (ramoops.mem_address / mem_size /\n` +
  `   console_size), or the device tree. Write ${workdir}/memdump_plan.json:\n` +
  `     {"channel": "memdump", "region_base": "0x..", "region_size": <N>,\n` +
  `      "console_size": <N or 0>, "source": "lk_log|cmdline|dtb", "evidence": "<the line>"}\n` +
  `   ONLY when region_base AND region_size are derived; otherwise write no file. console_size is\n` +
  `   the ring's own size when a source gives it, and 0 when none does (what\n` +
  `   memdump_observe.py derive writes): the scan then assumes the whole region is the ring, which\n` +
  `   lengthens the interval between dumps - say console_size is 미확정 in STATIC.md, never invent one.\n` +
  `   Prefer the tool over typing the region (it refuses conflicting sources and prints the evidence line):\n` +
  `     bash "${PLUGIN}/scripts/py.sh" memdump_observe.py derive --bootloader-log <console> \\\n` +
  `       [--cmdline <text>] --out ${workdir}/memdump_plan.json\n` +
  `   The one source it cannot read is a DTB reserved-memory node - a region read from one is written\n` +
  `   by hand with the node path as its evidence and flagged in STATIC.md as hand-read. The bootloader's\n` +
  `   own log is a runtime artifact, so the pipeline also tries that derivation on the first rounds'\n` +
  `   console (it writes a plan only when it finds console_size as well) - not finding the plan here is\n` +
  `   not an error. Record the evidence line in STATIC.md.\n` +
  `   The scan accepts a kernel log line as running-kernel evidence only with a kernel timestamp and\n` +
  `   the TASK that printed it, read from a \`[pid:comm]\` prefix - a shape confirmed on ONE kernel\n` +
  `   only. If this kernel's ring lines carry the task in another shape, derive that shape from the\n` +
  `   ring's own lines (quote them in STATIC.md) and write ${workdir}/kernel_task_regex.txt: its first\n` +
  `   non-empty line is ONE regular expression (the subset ERE and Python re share) whose first\n` +
  `   capture group is the task name (without a group the whole match is the name). It is SEARCHED,\n` +
  `   not anchored, in the first 64 characters of each kernel line's text (the part after the\n` +
  `   timestamp); a regex that does not compile is reported on the round's stderr and the default\n` +
  `   shape applies. The round script hands it to the scan. Do NOT set an\n` +
  `   environment variable for it - the round command carries none, so a variable you set never\n` +
  `   reaches the scan. No file means the default shape.\n\n` +

  `First record the phase:\n` +
  `  bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase "Analyze (static-analyzer prior)"\n` +
  `  bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" start analyze\n\n` +
  `Work through the eleven items above and append everything to STATIC.md - one\n` +
  `accumulating record for this firmware, never overwritten.\n` +
  `Anything you cannot derive stays "미확정" with a confirm plan. Never borrow ` +
  `values from another device or build.\n\n` +
  `Write STATIC.md in natural Korean - the user reads it.\n` +
  DOC_STYLE + `\n` +
  `When finished:\n` +
  `  bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" metric phase=Analyze ` +
  `event=analyze_end timer=analyze tokens_total=${budget.spent()}`,
  { agentType: 'static-analyzer', schema: ANALYST_SCHEMA, label: 'analyze', phase: 'Analyze' }
)

// stage_map.py exits 3 only when NO entry signature was found in the image (a
// header-declared entry, a vector table at the payload start, a start-up stub). An
// architecture is no longer a reason to stop: arm32 has a derivation of its own, and a
// stage whose base did not converge comes back `unconfirmed` with exit 0. So this is the
// one BLOCKED_ARCH, and it says what it is - a gap in the tool, not a fact about the
// firmware - because reporting it as "no stages" would turn a missing tool into a
// statement about the image.
//
// When the architecture itself could not be derived (archUnresolved), the reading in `arch` was
// only provisional - chosen because the stage-map tool found an entry signature under it and
// not under the other (archProbe), which the analyst's own run has now contradicted - so the
// blocker says that, and names what detect-arch based its "unknown" on: the person reading it
// needs to know it is the architecture that is open, not the firmware that is unrunnable.
// Passing `arch: 'arm32'` or `'arm64'` resumes with that reading. (The cases where the tool's
// two readings already told nothing - no signature, both, a reading that failed - stop earlier,
// in archProbeBlocker, before the analyst runs.)
const archBlocker = why => ['BLOCKED_ARCH',
  archUnresolved
    ? `아키텍처를 도출하지 못해(stage_map.py --detect-arch: unknown — 근거 ${archBasis.join(' / ') || '없음'}) ` +
      `${arch} 로 임시 진행했으나 ${why || '진입 시그니처(컨테이너 헤더가 선언한 진입점 · 페이로드 선두의 벡터 테이블 · 시작 코드)를 찾지 못했습니다'}. ` +
      '펌웨어의 한계가 아니라 도구의 결손입니다 — arch 입력으로 arm32 또는 arm64 를 명시하면 그 해석으로 이어서 진행합니다'
    : `${arch} 이미지에서 진입 시그니처(컨테이너 헤더가 선언한 진입점 · 페이로드 선두의 벡터 ` +
      '테이블 · 시작 코드)를 찾지 못했습니다 — 스테이지를 도출할 수단이 없습니다. ' +
      '펌웨어의 한계가 아니라 도구의 결손입니다' +
      (archBasis.length ? ` (detect-arch 근거: ${archBasis.join(' / ')})` : '')]

const blockers = []
// An architecture that was NOT derived is only a guess, and every verdict below was reached
// under it (the carve yardstick and the disassembler mode depend on the architecture). So when
// the guess did not carry the stage-map derivation - no entry signature, a carve verdict, no
// map at all - the stop is BLOCKED_ARCH, listed first: it is the premise that is open, and
// reporting a carve or a missing map for it would put the blame on the firmware.
if (archUnresolved) {
  const why = !prior
      ? '분석가의 답을 얻지 못해 스테이지 도출이 성공했는지 확인할 수 없습니다'
    : prior.arch_supported === false
      ? '스테이지 도출이 진입 시그니처를 찾지 못했습니다 (arch_supported=false)'
    : prior.carve_is_full === false
      ? `carve 판정이 부분 추출로 나왔습니다 (${arch} 기준자가 이미지에 맞지 않았을 수 있습니다)`
    : (prior.stages ?? []).filter(Boolean).length === 0
      ? '스테이지 지도가 비어 있습니다 (stage_map.py 가 지도를 내지 못했습니다)'
    : null
  if (why) blockers.push(archBlocker(why))
}
if (prior?.carve_is_full === false && !blockers.length) {
  blockers.push(['BLOCKED_CARVE', '부트로더 컨테이너가 carve 로 판정됨 (알려진 ASCII 부족)'])
}
// bl_surface "none" is NOT a blocker here. It used to stop the run before a single round,
// which for a bootloader that logs and boots on (no input at all) meant it never ran.
// Whether the firmware really waits for input is decided by a round that is observed
// waiting (waitingForInput), and only then does BLOCKED_NO_INPUT_PATH stand.
if (prior?.arch_supported === false) blockers.push(archBlocker())
// The upper rungs need the kernel side. Missing assets do not block F1, so this
// is only fatal when the target actually asks for them.
// Staging has already run by now (stageAssetsCmd), so assets_ok=false means the assets are truly
// absent AFTER staging - and the stop says what staging did, instead of asking for a manual step.
if (target !== 'F1' && prior?.assets_ok === false) {
  blockers.push(['BLOCKED_ASSET',
                 `목표 ${target} 은 커널 자산이 필요한데 적재한 뒤에도 없습니다 (Image/DTB). ` +
                 `적재 결과: ${assetStagingText(assetStaging)}. ` +
                 'F1 로 낮추면 부트로더 체인까지는 그대로 진행됩니다'])
}
// BLOCKED_KO: the kernel has no storage driver at all - no vendor .ko, and none built into the
// image either (static-analyzer checklist K4, `storage_driver.form == "absent"`). Only "absent"
// is a blocker: a missing module with a built-in driver is a reachable run. K4 belongs to the
// kernel-side checklist, which is needed from F2 up and not for F1.
// An "absent" with nothing behind it is a claim, not a finding: the recipe the analyst follows can
// miss a driver (a search that names only one medium kind's drivers finds none on the other), so
// the stop is raised only when the answer carries evidence - non-empty and with a hit count in it.
// Anything less is UNCONFIRMED: the run goes on, and says so (koUnconfirmed, journaled below).
// This is a floor, not a proof: that the commands named are the right ones is for a reader of the
// evidence quoted in the stop message, and the emitter has been run against scripted agents only.
function storageEvidenceText(ev) {
  if (ev === null || ev === undefined) return ''
  const t = String(typeof ev === 'string' ? ev : JSON.stringify(ev) ?? '').trim()
  return ['', '{}', '[]', 'null', '""', "''"].includes(t) ? '' : t
}
let koUnconfirmed = null
if (target !== 'F1' && String(prior?.storage_driver?.form ?? '').toLowerCase() === 'absent') {
  const ev = storageEvidenceText(prior.storage_driver.evidence)
  if (ev && /\d/.test(ev)) {
    blockers.push(['BLOCKED_KO',
                   `커널에 저장 매체 드라이버가 없습니다 — 벤더 .ko 가 없고 커널 이미지에 빌트인으로도 없습니다 ` +
                   `(storage_driver.form=absent, 근거: ${ev.slice(0, 300)}). ` +
                   'F1 로 낮추면 부트로더 체인까지는 그대로 진행됩니다'])
  } else {
    koUnconfirmed = ev
      ? `storage_driver.form=absent 로 보고됐으나 근거에 적중 수가 없습니다 (근거: ${ev.slice(0, 200)})`
      : 'storage_driver.form=absent 로 보고됐으나 근거가 없습니다'
  }
}

// The stages the analyst confirmed. A stage is `exec` (runnable), `encrypted` (skipped
// by redirecting to the next runnable one) or `unconfirmed` (its anchors did not
// converge - it is neither runnable nor encrypted, and a skip plan for it would be a
// bypass invented for a stage nobody understood).
let stagesNow = (prior?.stages ?? []).filter(Boolean)
const isExec = x => x.state === 'exec'
const isUnconfirmed = x => x.state === 'unconfirmed'

// Nothing runnable but something unconfirmed: one more derivation, aimed at exactly that.
// Bounded to one attempt - the tool lists its candidates and the anchors it rejected,
// and a second pass over the same evidence would only say the same thing. If it is
// still unconfirmed Build is told so and refuses to guess an entry.
if (!blockers.length && !stagesNow.some(isExec) && stagesNow.some(isUnconfirmed)) {
  const open = stagesNow.filter(isUnconfirmed)
  log(`[분석] 기점이 확정된 스테이지가 없고 unconfirmed ${open.length}개(${open.map(x => x.name).join(', ')})가 ` +
      `있습니다 — 후보와 거부된 앵커를 근거로 한 번 다시 도출합니다.`)
  const redo = await agent(
    `Run in mode=prior, but re-derive ONLY the stage map.\n` +
    `The first pass left ${open.length} stage(s) unconfirmed: ${stageSummary(open)}.\n` +
    `target=${target}, soc_family=${socFamily}, arch=${arch}\n` +
    `Stage map: ${stageMap} - for each unconfirmed stage read base.candidates and\n` +
    `base.rejected_anchors (each rejected anchor carries its reason). Container: ${bootloader_path}\n` +
    familyContext() +
    `Do not accept a candidate because it is the only one: a base is confirmed only when TWO\n` +
    `independent anchors land on the same value. Look for the anchor that was missing - the\n` +
    `header's own load address, the literal a self-relocating stub compares against, pointers\n` +
    `into strings - and say which one you found. If none exists, leave the stage unconfirmed\n` +
    `and say what evidence would decide it; do not report a value you did not derive.\n` +
    `Append what you found to STATIC.md (never overwrite it). Return the full "stages" list as\n` +
    `before, plus arch_supported (false only if no entry signature exists at all).\n` +
    DOC_STYLE,
    { agentType: 'static-analyzer', schema: ANALYST_SCHEMA, label: 'analyze-rederive', phase: 'Analyze' })
  if (redo?.arch_supported === false) {
    blockers.push(archBlocker())
  } else if (Array.isArray(redo?.stages) && redo.stages.length) {
    stagesNow = redo.stages.filter(Boolean)
  }
}

// The ladder is built from the derived map, so it can only be built now. Until
// this point the loop was aimed at a placeholder rung.
const execStages = stagesNow.filter(isExec)
// A chain with an AArch32 stage cannot be built from the AArch64-only template, and needs the
// QEMU core patch that lets TCG create an AArch32 CPU.
const mixedChain = arch === 'arm32' || execStages.some(x => x.arch === 'aarch32')
const unconfirmedStages = stagesNow.filter(isUnconfirmed)
const skippedStages = stagesNow.filter(x => !isExec(x) && !isUnconfirmed(x))
// Which rung stands for which executable stage, kept past the block below: the token file the
// analyst wrote is checked against it once the ladder is final.
let stageRungEntries = [], stagesWithoutRung = []
if (execStages.length) {
  const built = buildStageRungs(execStages)
  if (built.rungs.length) stageRungs = built.rungs
  stageRungEntries = built.entries
  stagesWithoutRung = built.dropped
  goals = goalsFor(activeSurface)
  ladderArg = goals.join(',')
  log(`[분석] 실행 가능 스테이지 ${execStages.length}개 (${stageSummary(execStages)}) → ` +
      `사다리 ${goals.join(' → ')}`)
  if (built.dropped.length) {
    log(`[분석] 칸을 만들지 않은 스테이지: ${built.dropped.join(', ')} — 공통 후단의 칸 이름과 겹칩니다 ` +
        `(커널은 kernel_entry / kernel_alive 가 맡습니다).`)
  }
  // The rung -> stage mapping, for the run script. A stage with no console string of its
  // own (an EL3 monitor that prints nothing) is seen only by its entry PC in the trace, and
  // the script that reads the trace needs to know which rung that PC stands for.
  if (built.entries.length) {
    await shell('stage-rungs', 'Analyze', inBash(
      `cat > ${shq(`${workdir}/stage_rungs.json`)} <<'SBOOT_JSON'\n` +
      `${JSON.stringify({ schema: 1, rungs: built.entries }, null, 2)}\n` +
      `SBOOT_JSON`, true), OK_SCHEMA)
  }
} else if (!blockers.length) {
  log(unconfirmedStages.length
    ? `[분석] ⚠ 실행 가능 스테이지가 없고 unconfirmed ${unconfirmedStages.length}개만 남았습니다 ` +
      `(${stageSummary(unconfirmedStages)}). 사다리는 자리표시자 한 칸이며, Build 는 진입점이 ` +
      `확정되지 않았다고 보고해야 합니다 — 추측으로 진입하지 않습니다.`
    : '[분석] ⚠ 실행 가능 스테이지를 하나도 도출하지 못했습니다. ' +
      '사다리가 자리표시자 한 칸으로 남습니다 — 첫 회차 지문으로 다시 판단하십시오.')
}
// An unconfirmed stage is not a bypass candidate - it is a stage nobody has understood yet.
// Only an encrypted one is skipped, and a skip is documented as the bypass it is.
if (unconfirmedStages.length && execStages.length) {
  log(`[분석] 기점 미확정 스테이지 ${unconfirmedStages.length}개: ` +
      `${unconfirmedStages.map(x => `${x.name}(${x.arch ?? '?'}/${x.origin ?? '?'})`).join(', ')} ` +
      `— 실행 불가로 두고 재도출 대상입니다. 우회로 문서화하지 않습니다.`)
}
if (skippedStages.length) {
  log(`[분석] 건너뛰는 스테이지 ${skippedStages.length}개: ` +
      skippedStages.map(x => `${x.name}(${x.state})`).join(', ') +
      ` — 각각 우회로 문서화되어야 합니다.`)
}

// static-analyzer may correct setup's surface hint; measurement wins over the hint.
// Adopt the derived surface and keep going - stopping to ask the user to edit
// INPUT.md would break the autonomy contract, and a corrected goal is a derived
// fact, not a structural impossibility.
const derivedSurface = String(prior?.bl_surface ?? '').toLowerCase()
if (SURFACES.includes(derivedSurface) && derivedSurface !== activeSurface) {
  const before = activeSurface
  activeSurface = derivedSurface
  goals = goalsFor(activeSurface)
  ladderArg = goals.join(',')
  log(`[분석] 표면 정정: 힌트 "${before}" → 도출 "${activeSurface}". ` +
      `목표 사다리를 ${goals.join(' → ')} 로 바꿔 계속합니다.`)
  await shell('surface-correction', 'Analyze',
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
    `${shq('부트로더 인터랙티브 표면')} ${shq(activeSurface)} ` +
    `${shq(`setup 힌트는 ${before} 였으나 static-analyzer 가 입력 경로를 도출해 정정`)}`,
    OK_SCHEMA)
}

// No surface: the rung is dropped and `autoboot` is what gets recorded - pending until a
// round actually reaches the kernel jump without any input of ours, then observed. It is a
// state of the run, not a rung, so it never enters the ladder.
let autobootState = activeSurface === 'none' ? 'pending' : 'not_applicable'
if (activeSurface === 'none') {
  log('[분석] 표면 없음(none) — 표면 칸을 사다리에서 빼고 autoboot 를 pending 으로 기록합니다. ' +
      '입력을 기다리며 멈춘 회차가 관측될 때만 BLOCKED_NO_INPUT_PATH 로 정지합니다.')
  await shell('autoboot-pending', 'Analyze',
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
    `${shq('부트로더 표면')} ${shq('none — 표면 칸 제외, autoboot: pending')} ` +
    `${shq('입력 경로가 없다는 도출만으로는 정지하지 않음 (실행해 봐야 입력을 기다리는지 안다)')} || true`,
    OK_SCHEMA)
}

/* A hard blocker found while analysing: record it (blockers.jsonl and the journal), say it, and
 * return the stop. The detail goes in WHOLE (shqWhole): it names the detect-arch basis, what each
 * reading found, the evidence and the way to resume, and the 400-character cap of shq cut it in
 * the middle of the sentence that says what to do. `noteOverride` replaces the code's default note. */
async function stopForBlocker(code, detail, noteOverride = null) {
  await shell('record-blocker', 'Analyze',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=${code} detail=${shqWhole(detail)}\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ${shqWhole(`하드 블로커 ${code}: ${detail}`)}`,
    OK_SCHEMA)
  log(`★ 정지 — ${code}: ${detail}`)
  return {
    success: false, stopped: true, stop_reason: code, detail,
    note: noteOverride ?? (code === 'BLOCKED_ARCH'
      ? '도구의 결손입니다 — 이 이미지에서 진입 시그니처를 찾는 도출기가 해당 모양을 아직 모릅니다. ' +
        '펌웨어가 실행 불가하다는 판정이 아닙니다. 도출기를 보강한 뒤 같은 명령을 다시 실행하면 이어서 진행됩니다.'
      : code === 'BLOCKED_ASSET'
        ? '커널 자산은 파이프라인이 02_unpacked 에서 적재했고(위 적재 결과), 그래도 없어서 멈췄습니다. ' +
          '패키지에 boot.img 가 없거나 추출이 실패한 것입니다. 자산을 02_unpacked 에 둔 뒤 같은 명령을 다시 실행하면 ' +
          '이어서 진행됩니다 (F1 은 자산 없이 진행됩니다).'
      : code === 'BLOCKED_KO'
        ? '이 커널은 저장 매체를 다룰 드라이버가 모듈로도 빌트인으로도 없어 rootfs 까지의 칸에 도달할 수 없습니다. ' +
          'static-analyzer 의 도출(STATIC.md 의 근거)이 틀렸다면 바로잡은 뒤 같은 명령을 다시 실행하면 이어서 진행됩니다.'
      : '구조상 목표에 도달할 수 없습니다. 자산을 확보한 뒤 같은 명령을 다시 실행하면 이어서 진행됩니다.'),
  }
}

if (blockers.length) {
  const [code, detail] = blockers[0]
  return await stopForBlocker(code, detail)
}

// An absent storage_driver answer that could not stop the run: say why it did not, so the
// analyst's claim is neither acted on nor silently dropped (it stays in STATIC.md and the journal).
if (koUnconfirmed) {
  log(`[분석] ⚠ ${koUnconfirmed} — 미확정으로 두고 BLOCKED_KO 로 정지하지 않습니다. 저장 매체 드라이버가 정말 없는지는 ` +
      `실행이 매체 칸에서 멈추는지로 다시 드러납니다.`)
  await shell('ko-unconfirmed', 'Analyze',
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('BLOCKED_KO')} ` +
    `${shqWhole(`미확정 — ${koUnconfirmed}. 정지하지 않고 계속합니다`)} ` +
    `${shqWhole('absent 가 정지가 되려면 근거에 실행한 명령과 적중 수가 있어야 합니다. 이 매체 종류의 드라이버 이름으로 찾았는지도 확인되지 않았습니다')} || true`,
    OK_SCHEMA)
}

// carve_check could not decide (is_full null: the family has no yardstick and the container carries no
// header evidence of its size). Undetermined is not "partial": only a false verdict stops the run
// (BLOCKED_CARVE above), and a null goes on - but it is said, with the analyst's reason, instead of
// reading as a pass. An answer that carries no verdict at all is the same case (nothing was judged).
if (prior && typeof prior.carve_is_full !== 'boolean') {
  const why = String(prior.carve_note ?? '').replace(/\s+/g, ' ').trim() ||
    (prior.carve_is_full === null ? 'carve_check printed is_full null and no note was reported'
                                  : 'the analyst reported no carve verdict')
  log(`[분석] carve 판정 불가(undetermined) — ${why}. BLOCKED_CARVE 는 false 일 때만 서므로 계속합니다.`)
  await shell('carve-undetermined', 'Analyze',
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('carve 판정')} ` +
    `${shqWhole(`미확정 (carve undetermined) — 계속합니다. 이유: ${why}`)} ` +
    `${shqWhole(`BLOCKED_CARVE 는 판정이 false 일 때만 선다 (--family ${familyFlag()} 의 기준자가 없고 컨테이너 헤더 근거도 없으면 null)`)} || true`,
    OK_SCHEMA)
}

// The architecture was not derived by detect-arch, so the reading in `arch` stood in for it on the
// strength of the two-reading stage map (archProbe). The analyst's own derivation went through, so the run goes
// on - and the journal says what was checked and by whom, instead of letting a working guess read
// as a derivation. (The signature itself was found before the analyst ran, by the tool's output
// under both readings; the analyst's answer only adds that its map was not empty and not refuted.)
if (archUnresolved) {
  log(`[분석] 아키텍처는 detect-arch 가 도출하지 못했고 ${arch} 는 임시였습니다 — 두 해석 비교에서 진입 시그니처가 ` +
      `${arch} 에서만 나왔고 분석가의 스테이지 도출도 ${arch} 로 반박 없이 끝나 계속합니다 ` +
      `(${stageSummary(stagesNow) || '스테이지 없음'}). 스테이지별 arch 는 지도가 정합니다.`)
  await shell('arch-provisional-kept', 'Analyze',
    archDecisionCmd(`${arch} 임시 유지 — 두 해석 비교로 정했고 분석가의 스테이지 도출이 반박하지 않음`,
                    `detect-arch 는 unknown 이었음. 확인한 것: ${(archProbe?.say ?? ['두 해석 비교 결과 없음']).join('; ')} ` +
                    `(진입 시그니처는 종료코드와 진입 스텁 수로 읽음). 분석가의 스테이지 도출: ` +
                    `${stageSummary(stagesNow) || '스테이지 없음'} (arch_supported 가 false 가 아니고 carve 판정이 부분 추출이 아님). ` +
                    `이후 아키텍처는 stage_map.json 의 스테이지별 arch 를 따릅니다`),
    OK_SCHEMA)
}

// The analyst wrote milestone_tokens.txt BEFORE the stage rungs had names: they come from the
// map it derived in the same answer (buildStageRungs), and the prompt could only state the
// rule. A token file whose milestone names are not the rungs of this ladder observes nothing -
// the run script credits whatever name the file carries, but the loop counts only the ladder's
// - and the FIRST stage's rung has no other way to be credited (its entry PC is where the
// machine itself put the CPU). So the file is compared with the exact ladder now; one
// correction is asked for, and what is still wrong afterwards is said, not assumed fine.
const firstStageEntry = stageRungEntries.find(e => e.index === 0) ?? null

/* What milestone_tokens.txt says about the ladder. A line with no tab is a token for the
 * surface rung and is not a milestone name. The names a run could legitimately carry past
 * the ladder (the tail's own, for a target that stops lower) are not "unknown". */
function tokenCheckCmd() {
  const valid = [...new Set(goals.concat(RESERVED_RUNGS))].join(',')
  return inBash(
    `TOK=${shq(`${workdir}/milestone_tokens.txt`)}\n` +
    `if [ ! -s "$TOK" ]; then echo "tokens_file=missing"; exit 0; fi\n` +
    `echo "tokens_file=present"\n` +
    `awk -F'\\t' -v valid=${shq(`,${valid},`)} -v first=${shq(firstStageEntry?.rung ?? '')} '\n` +
    `{ sub(/\\r$/, "") }\n` +
    `NF >= 2 && $1 != "" {\n` +
    `  if (index(valid, "," $1 ",") == 0 && !(seen[$1]++)) print "unknown_rung=" $1\n` +
    `  if (first != "" && $1 == first && $2 != "") has_first = 1\n` +
    `}\n` +
    `END { if (first != "") print "first_rung_token=" (has_first ? "yes" : "no") }\n` +
    `' "$TOK"\n` +
    `# Report tokens_file from the tokens_file= line, unknown_rungs as the list of every unknown_rung=\n` +
    `# value (empty when there is none), and first_rung_token as true for first_rung_token=yes, false\n` +
    `# for first_rung_token=no and null when that line is not printed.`)
}

/* The problems of a check answer, as sentences - null when the check could not be made. */
function tokenProblemsOf(r) {
  if (!r || typeof r.tokens_file !== 'string') return null
  if (r.tokens_file !== 'present') return ['milestone_tokens.txt 가 없거나 비어 있습니다']
  const out = []
  const unknown = (Array.isArray(r.unknown_rungs) ? r.unknown_rungs : []).filter(Boolean)
  if (unknown.length) out.push(`사다리에 없는 칸 이름: ${unknown.join(', ')}`)
  if (firstStageEntry && r.first_rung_token === false) {
    out.push(`첫 스테이지 칸 ${firstStageEntry.rung} 의 토큰 줄이 없습니다 (이 칸은 진입 PC 로 인정되지 않습니다)`)
  }
  return out
}

let tokenProblems = []
if (stageRungEntries.length) {
  let tokenAnswer = await shell('milestone-token-check', 'Analyze', tokenCheckCmd(), TOKEN_CHECK_SCHEMA)
  let found = tokenProblemsOf(tokenAnswer)
  if (found === null) {
    log('[분석] ⚠ milestone_tokens.txt 를 사다리와 대조하지 못했습니다 — 칸 이름이 맞는지 확인되지 않았습니다.')
  } else if (found.length) {
    log(`[분석] 마일스톤 토큰 파일이 사다리와 맞지 않습니다 — ${found.join(' / ')}. 정확한 칸 이름을 주고 한 번 고치게 합니다.`)
    await agent(
      `Run in mode=prior, but ONLY correct ${workdir}/milestone_tokens.txt against the exact ladder.\n` +
      `target=${target}, soc_family=${socFamily}\n` +
      `The loop counts exactly these rung names: ${goals.join(', ')}\n` +
      `Stage rungs, and the stage of ${stageMap} each one stands for:\n` +
      stageRungEntries.map(e => `  ${e.rung}  <- stage "${e.stage}" (index ${e.index}${e.entry_pc ? `, entry ${e.entry_pc}` : ''})`).join('\n') + '\n' +
      (stagesWithoutRung.length
        ? `Stages that have NO rung (the common tail owns the name): ${stagesWithoutRung.join(', ')}\n` : '') +
      `What the pipeline found wrong: ${found.join(' / ')}\n` +
      familyContext() +
      `Rules:\n` +
      `- A line whose milestone is a stage's name (or any spelling of it) becomes that stage's exact rung\n` +
      `  name above. Never move a token to a different stage: the string stays with the stage it was\n` +
      `  located in.\n` +
      `- A line naming no rung of the ladder and no stage is dropped.\n` +
      `- ${firstStageEntry ? `The first stage's rung ${firstStageEntry.rung}` : 'The first stage'} needs a token of its own: its first\n` +
      `  console line, a string you located at a file offset in this firmware. If it prints none, write\n` +
      `  NO line and say so as 미확정 in STATIC.md - never invent one, and do not borrow another stage's.\n` +
      `- Change no other file except STATIC.md, where you append (never overwrite) what you changed.\n` +
      DOC_STYLE,
      { agentType: 'static-analyzer', schema: ANALYST_SCHEMA, label: 'analyze-tokens', phase: 'Analyze' })
    tokenAnswer = await shell('milestone-token-recheck', 'Analyze', tokenCheckCmd(), TOKEN_CHECK_SCHEMA)
    found = tokenProblemsOf(tokenAnswer)
  }
  tokenProblems = found ?? []
  if (tokenProblems.length) {
    log(`[분석] ★ 경고 — 정정 뒤에도 마일스톤 토큰이 사다리와 맞지 않습니다: ${tokenProblems.join(' / ')}. ` +
        '맞지 않는 칸은 관측되지 않은 채로 남습니다 (도달 불가 판정이 아니라 관측 수단이 없는 것입니다).')
    await shell('token-mismatch-decision', 'Analyze',
      `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('마일스톤 토큰 불일치')} ` +
      `${shq(tokenProblems.join(' / '))} ` +
      `${shq('사다리의 칸 이름과 milestone_tokens.txt 가 정정 요청 뒤에도 맞지 않음 — 해당 칸은 관측되지 않은 채 진행')} || true`,
      OK_SCHEMA)
  }
}

log(`[분석] 완료 — 새로 확정한 사실 ${prior?.new_facts_count ?? 0} 개, 미확정 ${prior?.undetermined_count ?? 0} 개`)

// =============================================================================
// Phase 2 - Build
// =============================================================================
phase('Build')

// The QEMU tree starts every firmware from the state `init` left it in. A first Build
// runs on a tree the PREVIOUS firmware may have left behind: its machine copy still
// registered in hw/arm/, and - worse - one family's core patch still in target/arm when
// the next family does not want it. qemu_tree.sh reset puts back exactly what the
// manifest says was touched (never a file it did not record), and everything this
// firmware needs is applied again below: this family's core patch set, this firmware's
// machine. A tree that cannot be proven clean is not built on - a build on an unknown
// base is a result nobody can reproduce.
const treeReset = await shell('qemu-tree-reset', 'Build',
  `bash "${PLUGIN}/scripts/qemu_tree.sh" reset; RC=$?\n` +
  `echo "qemu_tree_exit=$RC"\n` +
  `# Report exit_code from the qemu_tree_exit= line, noop/restored/removed from the JSON\n` +
  `# on stdout, and the sentence qemu_tree.sh printed on stderr as error.`,
  TREE_SCHEMA)
if (!treeReset || treeReset.exit_code !== 0) {
  const why = treeReset?.error ||
    (treeReset ? `qemu_tree.sh reset 가 종료코드 ${treeReset.exit_code} 로 끝났습니다`
               : 'qemu_tree.sh reset 의 결과를 얻지 못했습니다')
  await shell('record-tree-blocker', 'Build',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_ENV ` +
    `detail=${shq(`QEMU 트리를 되돌리지 못했습니다: ${why}`)} 2>/dev/null || true\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
    `${shq(`QEMU 트리 복원 실패로 정지: ${why}`)} 2>/dev/null || true`,
    OK_SCHEMA)
  log(`★ 정지 — BLOCKED_ENV: QEMU 트리를 pristine 상태로 되돌리지 못했습니다 — ${why}`)
  log('    /sboot-rehost:init 으로 환경을 다시 만든 뒤 같은 명령을 다시 실행하십시오 ' +
      '(워크스페이스는 그대로 재사용됩니다).')
  return {
    success: false, stopped: true, stop_reason: 'BLOCKED_ENV', detail: why,
    note: '이전 펌웨어가 QEMU 트리에 남긴 것을 되돌릴 수 없어, 이 트리 위에 빌드하지 않았습니다. ' +
          '실행 환경 문제이며 펌웨어 판정이 아닙니다. /sboot-rehost:init 후 같은 명령으로 재개됩니다.',
  }
}
if (treeReset.noop !== true) {
  log(`[빌드] QEMU 트리 복원 — 되돌림 ${(treeReset.restored ?? []).length}개, ` +
      `제거 ${(treeReset.removed ?? []).length}개`)
}

// This family's core patch set, on the tree reset left. Applied here, once, rather than
// inside the build agent's prompt: it is deterministic, it is idempotent, and a patch that
// no longer finds its anchor (the QEMU source moved) must stop the run, not be worked
// around by an agent. The script records each file it touches for the next reset.
const coreFamily = corePatchFamily()
const corePatch = await shell('core-patch', 'Build',
  `bash "${PLUGIN}/scripts/py.sh" patch_qemu_core.py --family ${coreFamily}; RC=$?\n` +
  `echo "patch_exit=$RC"\n` +
  `# Report exit_code from the patch_exit= line and the script's own output as output.`,
  { type: 'object',
    properties: { exit_code: { type: 'integer' }, output: { type: ['string', 'null'] } },
    required: ['exit_code'] })
if (!corePatch || corePatch.exit_code !== 0) {
  const why = corePatch ? `종료코드 ${corePatch.exit_code}: ${String(corePatch.output ?? '').slice(0, 300)}`
                        : '결과를 얻지 못했습니다'
  await shell('record-core-blocker', 'Build',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
    `detail=${shq(`patch_qemu_core.py --family ${coreFamily} 실패: ${why}`)} 2>/dev/null || true`,
    OK_SCHEMA)
  log(`★ 정지 — BLOCKED_BUILD: QEMU 코어 패치(${coreFamily})를 적용하지 못했습니다 — ${why}`)
  return {
    success: false, stopped: true, stop_reason: 'BLOCKED_BUILD', detail: why,
    note: '코어 패치는 앵커가 정확히 하나일 때만 적용됩니다 (QEMU 소스가 달라졌을 수 있습니다). ' +
          '추측으로 고치지 않습니다. 원문 그대로 확인해 주세요.',
  }
}
log(`[빌드] QEMU 코어 패치 세트 ${coreFamily} 적용 (계열 ${familyName})`)

// What the boot medium is. The profile used to say UFS for every device of a family, and
// that is a guess - a device tree carries a UFS host node whether or not the board uses
// one. Before the first round only the device trees are evidence (the container embeds
// one); the first bootloader log decides, and the loop asks again then.
let mediumKind = 'unknown'      // what the medium and the machine were last built for
let mediumBasis = 'none'
let mediumTried = 0             // log-based detections attempted so far
const HOST_LINE_RE = '^([0-9]+(\\.[0-9]+)?[[:space:]]+)?qemu-system-[A-Za-z0-9_-]+: '

/* The shell lines that cut a console down to the guest's own lines, QEMU's host diagnostics
 * removed. `-a`: a console is not text - a guest prints NULs and bytes that are not UTF-8,
 * and grep without it either prints nothing (the invoked grep skips binary input) or a
 * "Binary file matches" notice instead of the lines. Either way the filtered copy would be
 * empty or a notice, and the next step would read that as "the bootloader said nothing":
 * medium detection would fall back to the device tree and the memory-dump plan would never
 * be found, with no sign that the filter was the failure. LC_ALL=C keeps every byte a
 * character, so an invalid sequence cannot make the match itself fail. Exit 1 (no line
 * left: the console was all host lines) is an answer; above 1 is the filter failing, and
 * that is said, never swallowed. `$GRC` is the filter's exit code, for the caller. */
function guestLinesCmd(src, dst) {
  return `LC_ALL=C grep -a -v -E ${shq(HOST_LINE_RE)} "${src}" > "${dst}"; GRC=$?\n` +
         `if [ "$GRC" -gt 1 ]; then : > "${dst}"; echo "guest_filter=failed grep_exit=$GRC (콘솔에서 게스트 줄을 가려내지 못했습니다)" >&2; fi\n`
}

/* detect_medium.py over every device tree we have (a staged *.dtb, or the container
 * itself, which carries one) and, when asked, a bootloader console: a given file, or
 * 'latest' for the newest console an earlier run of this workspace left behind (a
 * resumed workspace need not forget what its last log said). QEMU host lines are taken
 * out first: we printed them, and a line of ours naming a storage kind would be evidence
 * about our own machine. */
function detectMediumCmd(consoleSpec) {
  return inBash(
    `WD=${shq(workdir)}\n` +
    `set -- --dtb ${shq(bootloader_path)}\n` +
    `for f in "$WD"/fw/*.dtb "$WD"/02_unpacked/*.dtb; do [ -f "$f" ] && set -- "$@" --dtb "$f"; done\n` +
    (consoleSpec
      ? (consoleSpec === 'latest'
          ? `CON=$(ls -t "$WD"/07_logs/console_[0-9]*.txt 2>/dev/null | head -n 1)\n`
          : `CON=${shq(consoleSpec)}\n`) +
        `GUEST="$WD/07_logs/.guest_for_detect.txt"\n` +
        `if [ -n "$CON" ] && [ -s "$CON" ]; then\n` +
        guestLinesCmd('$CON', '$GUEST') +
        // The medium is then decided from the device tree alone: that is a weaker basis than
        // the bootloader's own log, and it is said here rather than left to look like "the
        // log had nothing" (the answer's `basis` says it too).
        `  if [ ! -s "$GUEST" ]; then echo "guest_filter=empty: $CON 에서 게스트 줄이 남지 않았습니다 — 부트로더 로그 없이 장치 트리만으로 판정합니다" >&2; fi\n` +
        `  set -- "$@" --bootloader-log "$GUEST"\n` +
        `fi\n`
      : '') +
    `bash "${PLUGIN}/scripts/py.sh" detect_medium.py "$@"\n` +
    (consoleSpec ? `rm -f "$GUEST"\n` : ''))
}

/* The detection, as a derived fact in STATIC.md (honesty rule 6: a fact only in an
 * answer reaches nobody). Appended, never rewritten; the time is the shell's own. */
function recordMediumCmd(label, m) {
  const lines = [
    '', `### 부팅 매체 판정 (${label}) — detect_medium.py`, '',
    `- hci_kind: ${m.hci_kind} (근거 ${m.basis ?? '?'}, 확신 ${m.confidence ?? '?'})`,
    `- 이유: ${m.reason ?? ''}`,
    ...(m.evidence ?? []).slice(0, 20).map(e => `  - ${e}`),
    ...(m.notes ?? []).map(n => `- 비고: ${n}`),
  ]
  return `printf '%s\\n' ${lines.map(shq).join(' ')} "- 시각: $(date +%Y-%m-%dT%H:%M:%S%z)" ` +
         `>> "${staticDoc}"`
}

const medium0 = await shell('detect-medium', 'Build', detectMediumCmd('latest'), MEDIUM_SCHEMA)
if (medium0?.hci_kind) {
  mediumKind = medium0.hci_kind
  mediumBasis = medium0.basis ?? 'none'
  if (mediumBasis === 'bootloader_log') mediumTried = 1
  await shell('record-medium', 'Build', recordMediumCmd(
    mediumBasis === 'bootloader_log' ? 'Build 전 — 이전 실행의 부트로더 로그' : 'Build 전 — 장치 트리',
    medium0), OK_SCHEMA)
  log(`[빌드] 부팅 매체 ${mediumKind} (근거 ${mediumBasis}, 확신 ${medium0.confidence ?? '?'})` +
      (mediumKind === 'unknown' ? ' — 미확정: 첫 부트로더 로그가 정합니다' : ''))
} else {
  log('[빌드] ⚠ detect_medium.py 의 결과를 얻지 못했습니다 — 매체 종류를 미확정으로 둡니다.')
}

// Warnings build_lu.py raised on the last build (an undecided medium, a zero entry with
// no size, duplicate names). Each is a premise nobody derived; the supervisor reads them.
let buildWarnings = []

/* Build the machine. Called once before the loop, and again when the supervisor
 * judges that the stop point lives in this layer rather than in the loop.
 *
 * A fixer may only change one place in the existing machine sources, so a wrong
 * machine-level premise (entry EL, has_el3, load address, memory skeleton)
 * cannot be repaired from inside the loop - the loop can only stack band-aids on
 * the symptom. `diagnosis` is the supervisor's finding that sends us back here. */
async function buildMachine(diagnosis) {
  const again = diagnosis != null
  const mediumFlag = mediumKind === 'emmc' || mediumKind === 'ufs' ? ` --medium ${mediumKind}` : ''
  // The UFS host-controller skeleton is offered for a UFS medium, and for an undecided one only when
  // the family is the one it was written for. It is never offered for eMMC, and never guessed at for an
  // undecided medium of another family: a skeleton carries one vendor's window names and answers.
  const mediumUndecided = mediumKind !== 'emmc' && mediumKind !== 'ufs'
  const offerStorageHci = mediumKind === 'ufs' || (mediumUndecided && familyFlag() === 'exynos')
  const machineFile = `hw/arm/${machine.replace(/-/g, '_')}.c`
  return agent(
  (again
    ? `REBUILD. The loop could not fix this from inside, so the machine premise ` +
      `itself is under review.\n` +
      `Supervisor diagnosis: ${diagnosis.reason}\n` +
      `Machine-level change to make: ${diagnosis.change}\n` +
      `Apply exactly that change and rebuild. Keep every other derived value as ` +
      `it is - this is a premise correction, not a rewrite. Append the four-field ` +
      `bypass entry to bypasses.md if the change is a bypass.\n\n`
    : '') +
  `Generate the machine source, integrate it into QEMU and build.\n` +
  `model=${model}, machine name=${machine}, target=${target}\n` +
  `Stages (${stageMap}, schema v2): ${stageSummary(stagesNow) || '(none derived)'}\n` +
  `Boot medium: ${mediumKind} (basis ${mediumBasis})\n` +
  familyContext() + `\n` +
  `READ FIRST. Before you write or change anything, open every file named on the "Family knowledge:"\n` +
  `and "Runbook:" lines above (absolute paths; "(none)" means there is nothing to read for that\n` +
  `line). They hold shapes, the order a machine of this kind is brought up in, and the failure\n` +
  `signatures - never values. A machine built without reading them repeats what they already\n` +
  `explain, and the chip values still come only from STATIC.md and ${stageMap}.\n\n` +
  `1. Record the phase: bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase ${again ? '"Rebuild"' : '"Build"'}\n` +
  (mixedChain
    ? `★ This chain has AArch32 stages. ${abs('templates/machine_full.c.tmpl')} models ONE AArch64 CPU\n` +
      `   and would produce a wrong machine rather than a failure, so do NOT use it. Start\n` +
      `   from ${abs('templates/machine_mixed_arch.c.tmpl')}: it is STRUCTURE ONLY (which CPU is\n` +
      `   created first, the interrupt controller, the handoff between the AArch32 and the\n` +
      `   AArch64 CPU, memory, shadow windows over the peripherals, a patch-ledger engine)\n` +
      `   and every chip value in it is a {{PLACEHOLDER}}. Fill each one from STATIC.md and\n` +
      `   stage_map.json - and ONLY from those. A value not derived yet stays a comment\n` +
      `   ("undetermined - confirmed at step N"), never a plausible number.\n` +
      `   ${abs('examples/a136u-mt6833/')} shows what a filled machine looked like for ONE device.\n` +
      `   Read it for structure; its values are not borrowable - not an address, not an\n` +
      `   offset, not a patch. The family runbook above says in what order to bring a\n` +
      `   machine of this kind up. The core patch it needs (an AArch32 CPU under TCG) is\n` +
      `   already applied by the pipeline (--family ${coreFamily}); do not apply it again.\n` +
      `   ★ ADDRESS WINDOWS TABLE. Every window the machine opens, every read override and every\n` +
      `   injected or assumed value is also one row of a table headed "address windows" in\n` +
      `   ${staticDoc}: the classifier and the fixers read STATIC.md, not the machine source, so a\n` +
      `   fact only in the source reaches nobody. Its columns are defined once, in the Conventions\n` +
      `   block at the top of ${abs('templates/machine_mixed_arch.c.tmpl')} - read them there and use\n` +
      `   them exactly; they are not repeated here. Append the rows (STATIC.md is never overwritten),\n` +
      `   one per window, override and assumed value, and write 미확정 in a cell you cannot derive.\n` +
      `   If you cannot fill the template from derived facts alone, report build_ok=false\n` +
      `   saying which values are missing - do not guess.\n`
    : `★ Single-architecture chain: ${abs('templates/machine_full.c.tmpl')} models it. The core patch\n` +
      `   set is already applied by the pipeline (--family ${coreFamily}).\n`) +
  `★ STAGE PLACEMENT. Place each executable stage as ${stageMap} records it, by its origin:\n` +
  `   - origin "container": load the container ONCE and memcpy the stage to its load base.\n` +
  `     Do not carve the file, and do not load a stage the map marked encrypted or unconfirmed.\n` +
  `   - origin "medium": the machine does NOT place it. An earlier stage reads it from the\n` +
  `     boot medium and loads it itself; copying it in would skip the firmware's own read.\n` +
  `   - origin "handoff": entered by the previous stage's own code (a monitor call, a warm\n` +
  `     reset). The machine neither loads it nor jumps to it; it models what that code needs.\n` +
  `   Do not assume the chain lives in one container - the map says where each stage is.\n` +
  `★ ENTRY_PC is not LOAD_BASE. File offset 0 is the container header: entering\n` +
  `   there executes header bytes as instructions and traps on the first word.\n` +
  `   Use the first stage's derived entry_pc (absolute, in the map). If it is\n` +
  `   undetermined (the stage is unconfirmed, entry_pc is null), report build_ok=false and\n` +
  `   say so - do NOT fall back to the load address, which costs several rounds and two\n` +
  `   rebuilds to undo.\n` +
  `★ CPU STATE comes from the stage itself, per stage arch. An AArch64 stage: whichever\n` +
  `   vbar_el* its entry stub writes is the exception level it expects, and stage_map.json\n` +
  `   records that; set has_el3 from it. An AArch32 stage: its arch and entry instruction\n` +
  `   set (entry_isa) are in the map, and the mode its start-up code sets is in STATIC.md;\n` +
  `   if entry_isa is null do not set the Thumb bit by assumption. Do NOT default either\n` +
  `   way - a first stage that writes vbar_el3 needs EL3, and the opposite default breaks\n` +
  `   it silently.\n` +
  `★ SKIP REDIRECT. For each ENCRYPTED stage, redirect the previous stage's\n` +
  `   entry to the next executable stage's entry, per the skip plan in STATIC.md.\n` +
  `   Record each as a four-field bypass. Never synthesise a value to stand in\n` +
  `   for a skipped stage - if a later stage needs one, that is a finding.\n` +
  `★ The machine must not create console input, and must not create console TEXT. No\n` +
  `   function may fill the RX buffer except the chardev receive callback; the interrupt\n` +
  `   pattern and the command come from scripts/uart_harness.py outside QEMU. The one\n` +
  `   place the machine writes to the UART is the single TX path; QEMU's own diagnostics\n` +
  `   go through info_report / warn_report (stderr), never printf.\n` +
  `2. Fill ` +
  `${mixedChain ? abs('templates/machine_mixed_arch.c.tmpl')
                : abs('templates/machine_full.c.tmpl') +
                  (offerStorageHci ? ` plus ${abs('templates/storage_hci.c.tmpl')}` : '')} ` +
  `with values derived in STATIC.md and write ` +
  `${workdir}/06_machine/machine_full.c.\n` +
  `   Never invent a value that was not derived. Mark undetermined slots with a ` +
  `   comment instead of guessing.\n` +
  `   The storage model follows the MEDIUM: ${mediumKind === 'emmc'
      ? 'eMMC, so model the eMMC controller (the SD/MMC host controller the DTB node names) and do ' +
        'NOT use storage_hci.c.tmpl, which is a UFS host controller'
      : mediumKind === 'ufs'
        ? 'UFS, so storage_hci.c.tmpl applies - as a skeleton: its window names and return values are ' +
          'examples to be derived from STATIC.md, not values to keep'
      : offerStorageHci
        ? 'undecided - storage_hci.c.tmpl is offered for this family but is only a skeleton (its window ' +
          'names and return values are examples to be derived); model nothing the evidence does not ' +
          'support, and say 미확정'
        : 'undecided - no storage template is offered while the medium is open (storage_hci.c.tmpl is ' +
          'a UFS skeleton written for one family); model nothing the evidence does not support, and say 미확정'}.\n` +
  `3. Synthesise the boot medium the bootloader reads the next stage from:\n` +
  `   bash "${PLUGIN}/scripts/py.sh" build_lu.py "${workdir}" --out ${workdir}/fw/lu0.img${mediumFlag} --family ${familyFlag()}\n` +
  `   --family ${familyFlag()} picks the default layout and the command-line fallback this family has; a family\n` +
  `   that has none gets a neutral layout and a command line written only to the partition the plan or\n` +
  `   the manifest names (otherwise warning_cmdline).\n` +
  `   Its GPT partition names must be the ones derived from the bootloader's own\n` +
  `   strings. A name we invented is a partition the firmware will never find.\n` +
  `   Set "medium" in ${workdir}/lu_manifest.json to ${mediumKind === 'emmc' || mediumKind === 'ufs'
      ? `"${mediumKind}"` : 'nothing (leave the key out while it is undecided)'}. The image keeps the\n` +
  `   name fw/lu0.img whatever the medium: the run script and the machine look it up by that.\n` +
  `   Report every warning_* key build_lu.py prints (an undecided medium, a zero entry with\n` +
  `   no size, duplicate names) in build_warnings, verbatim.\n` +
  (target === 'F1' ? ''
    : `   Kernel patch sites exist only if the analyst derived them (${workdir}/kernel_patch_sites.json).\n` +
      `   If that file is there:\n` +
      `   bash "${PLUGIN}/scripts/py.sh" patch_kernel.py ${workdir}/fw/Image ${workdir}/fw/Image.patched ` +
      `${workdir}/kernel_patch_sites.json\n` +
      `   patch_kernel.py refuses to apply on a pre-image mismatch - report that as is. If the\n` +
      `   file is not there there is nothing to patch: do not call it, and do not write an\n` +
      `   empty table. The bootloader reads the kernel from the MEDIUM, so a patched file only\n` +
      `   reaches the boot if the medium is built from it - that is an image modification\n` +
      `   (kind modified, bypass type I) and bypasses.md must say so.\n`) +
  `4. Copy it into the QEMU tree as ${machineFile} and register\n` +
  `   it in hw/arm/meson.build. That exact name matters: every later round syncs\n` +
  `   the workspace source to the tree with scripts/sync_machine.sh, which finds\n` +
  `   the target by that name. Record what you touched, so the next firmware's Build can\n` +
  `   put the tree back (only the files you actually edited or added; the script decides\n` +
  `   modified-or-added from the pristine tarball and exits 3 if it cannot - report that):\n` +
  `   bash "${PLUGIN}/scripts/qemu_tree.sh" record hw/arm/meson.build ${machineFile}\n` +
  `   (add hw/arm/Kconfig if you edited it). Then\n` +
  `   bash "${PLUGIN}/scripts/sync_machine.sh" "${workdir}" ${machine}\n` +
  `   cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64\n` +
  `5. A build error must be reported verbatim with build_ok=false. Never guess a fix.\n` +
  `6. Confirm registration: qemu-system-aarch64 -M help | grep ${machine}\n` +
  `7. Ensure ${workdir}/06_machine/bypasses.md exists (header only is fine).\n` +
  `   That file is user-facing.\n` + DOC_STYLE +
  `8. bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" metric phase=Build ` +
  `event=build_end tokens_total=${budget.spent()}`,
  { schema: BUILD_SCHEMA, label: again ? `rebuild-${diagnosis.round}` : 'build',
    phase: again ? 'Loop' : 'Build' }
  )
}

const built = await buildMachine(null)
buildWarnings = Array.isArray(built?.build_warnings) ? built.build_warnings : []
if (buildWarnings.length) {
  log(`[빌드] 매체 합성 경고 ${buildWarnings.length}건: ${buildWarnings.join(' / ')}`)
}

if (built && built.build_ok === false) {
  await shell('record-build-blocker', 'Build',
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD detail=${shq('ninja 빌드 실패')}`,
    OK_SCHEMA)
  log(`★ 정지 — BLOCKED_BUILD: ${built.build_error ?? '빌드 실패'}`)
  return {
    success: false, stopped: true, stop_reason: 'BLOCKED_BUILD',
    detail: built.build_error,
    note: '빌드 에러는 추측으로 고치지 않습니다. 원문 그대로 확인해 주세요.',
  }
}

/* Where the kernel log lives in RAM, from the bootloader's OWN console of round `n`.
 * The reservation is printed at run time (a table of reserved ranges, the kernel
 * command line it builds), so no static analysis sees it - and the number is never typed
 * here or anywhere: memdump_observe.py derive takes it from the line and a conflict
 * between sources is refused, not guessed at. Our own host lines are taken out first (a
 * line of ours naming a range is not the bootloader saying it). A plan without a ring
 * capacity is not written: the sampling interval is derived from it, and "assume the
 * whole region" would stretch it past what the ring can hold. */
function derivePlanCmd(n) {
  return inBash(
    `WD=${shq(workdir)}\n` +
    `PLAN="$WD/memdump_plan.json"\n` +
    `if [ -s "$PLAN" ]; then echo "plan_status=present"; cat "$PLAN"; exit 0; fi\n` +
    `CON="$WD/07_logs/console_${n}.txt"\n` +
    `if [ ! -s "$CON" ]; then echo "plan_status=none"; echo "reason: console_${n}.txt is not there"; exit 0; fi\n` +
    `GUEST="$WD/.memdump_guest.tmp"; CAND="$WD/.memdump_plan.candidate.json"; ERR="$WD/.memdump_derive.err"\n` +
    guestLinesCmd('$CON', '$GUEST') +
    // A filter that failed, or left nothing, is not "this console names no ring": the plan
    // stays off either way, but the reason says which it was.
    `if [ "$GRC" -gt 1 ]; then echo "plan_status=none"; echo "reason: 콘솔에서 게스트 줄을 가려내지 못했습니다 (grep 종료코드 $GRC)"; rm -f "$GUEST"; exit 0; fi\n` +
    `if [ ! -s "$GUEST" ]; then echo "plan_status=none"; echo "reason: console_${n}.txt 에 게스트 줄이 없습니다 (전부 QEMU 호스트 줄)"; rm -f "$GUEST"; exit 0; fi\n` +
    `rm -f "$CAND"\n` +
    `if bash "${PLUGIN}/scripts/py.sh" memdump_observe.py derive --bootloader-log "$GUEST" ` +
    `--cmdline-file "$GUEST" --out "$CAND" >/dev/null 2>"$ERR"; then\n` +
    `  if grep -Eq '"region_size": *[1-9]' "$CAND" && grep -Eq '"console_size": *[1-9]' "$CAND"; then\n` +
    `    mv "$CAND" "$PLAN"; echo "plan_status=derived"; cat "$PLAN"\n` +
    `  else\n` +
    `    echo "plan_status=none"\n` +
    `    echo "reason: a region was found but not its console_size - no plan written (the ring capacity is not guessed)"\n` +
    `  fi\n` +
    `else\n` +
    `  echo "plan_status=none"; echo "reason: $(tail -n 1 "$ERR" 2>/dev/null)"\n` +
    `fi\n` +
    `rm -f "$GUEST" "$CAND" "$ERR"\n` +
    `# Report present=true for plan_status=present or derived, derived=true only for\n` +
    `# derived, plan = the JSON printed (null when none), reason = the reason line.`)
}

/* Questions a declining fixer left behind (rule 6 of FIXER_RULES): each is a fixer's own "rationale" for
 * answering not_mine or no_new_change. They wait here until a derivation is asked for - the next
 * escalation takes all of them as part of its FOCUS and the list starts empty again - so a question a
 * fixer could not settle is not lost when the round ends with no change. Only the most recent few are
 * kept (an old one has probably been overtaken), and each is cut to a length a prompt can carry. */
const openQuestions = []
function noteDecline(round, fixerName, answer) {
  const why = String(answer?.rationale ?? '').replace(/\s+/g, ' ').trim()
  if (!why) return
  openQuestions.push({ round, fixer: fixerName, kind: answer?.not_mine ? 'not_mine' : 'no_new_change', why: why.slice(0, 500) })
  if (openQuestions.length > 5) openQuestions.splice(0, openQuestions.length - 5)
}

/* `base` is the escalation's own focus (or null); the waiting questions are added after it and taken out. */
function escalationFocus(base) {
  if (!openQuestions.length) return base ?? null
  const lines = openQuestions.splice(0).map(q => `  - round ${q.round}, ${q.fixer} (${q.kind}): ${q.why}`)
  return (base ? `${base}\n\n` : '') +
    `Open questions from fixers that declined (each answered no_new_change or not_mine and wrote what it ` +
    `could not settle). Answer them from the binary or the trace; write a derived-stop-point row only for a ` +
    `mechanism you can establish - an answer that is a guess is not a row:\n${lines.join('\n')}`
}

/* The static-analyzer's escalation: derive what is actually executing at the originating
 * exception, and WRITE IT DOWN in STATIC.md - the classifier and the fixers read that
 * table, not the analyst's answer. `focus` narrows the question (a hypothesis that needs
 * deriving rather than fixing); `tag` keeps the labels of a second escalation in the
 * same round apart from the first. Returns the analyst's answer and the table as the
 * script measured it - the number of rows it ADDED, not the number the analyst claims. */
async function runEscalation(round, goal, obs, tag, focus) {
  focus = escalationFocus(focus)
  const esc = await agent(
    `Run in mode=escalation. Round ${round}, goal ${goal}.\n` +
    `The run is stalled or the stop point is unrecognised.\n` +
    `Fingerprint: ${fingerprintText(obs)}\n` +
    `Originating exception block: ${obs?.origin_block}\n` +
    `Summary log: ${obs?.summary}\nFull trace: ${obs?.trace}\n` +
    channelsText(obs, round) +
    familyContext() + `\n` +
    (focus ? `FOCUS: ${focus}\n\n` : '') +
    `Start from the ORIGINATING exception, not from the last FAR in the trace. ` +
    `Under a nested abort the handler faults on its own context save and FAR ` +
    `walks for millions of iterations; that address is a consequence of the ` +
    `recursion, and deriving a mechanism for it produces a stop point that ` +
    `cannot be fixed because it was never the cause.\n` +
    `Derive what is actually executing at that address, who called it, or where ` +
    `the value comes from. Disassemble; do not guess.\n\n` +
    `THEN WRITE WHAT YOU FOUND DOWN. Append a row to the "## 도출된 정지점" table ` +
    `in ${staticDoc} - one accumulating record for this firmware. A finding that ` +
    `stays in your answer reaches nobody: the classifier and the fixers read that ` +
    `table, so an unwritten fact is the same as no fact.\n` +
    `Columns: signature | observation | mechanism with evidence | owning fixer | ` +
    `change to try.\n` +
    `The owning-fixer column holds one of the six fixer names (${KNOWN_FIXERS.join(', ')}) or the ` +
    `literal word build. build is a build-layer row: the mechanism is a premise the machine was ` +
    `built on (entry level, entry PC, load address, CPU creation order) and no fixer can reach ` +
    `it, so no fixer is named - a fixer is never named for a premise only a rebuild can change.\n` +
    `If the question is WHERE THE DIGEST IS COMPUTED (the stall sits at a verified-boot comparison, an SMC to a ` +
    `monitor, a crypto engine's registers), the answer is one more row, not a stop-point row: the ` +
    `\`hash_engine\` row of STATIC.md, in the shape step 14d of ${abs('agents/static-analyzer.md')} defines ` +
    `(\`| hash_engine | hardware or software | <evidence with a 0x function address or SMC id> |\`). Write it ` +
    `only when the digest path is read and decided; undecided means NO row. Only you write it - a fixer ` +
    `must not, and without a hardware row check_change.sh rejects a labelled hash bypass.\n` +
    `If the mechanism is still undetermined, write no row. A row without a ` +
    `derived mechanism is a guess, and a guessed row sends a fixer down a wrong ` +
    `branch - honesty rule 1.`,
    { agentType: 'static-analyzer', schema: ANALYST_SCHEMA,
      label: `escalate-${round}${tag}`, phase: 'Loop' }
  )
  // Measure what was actually written rather than trusting the reported count.
  // A self-reported number cannot be contradicted, so re-deriving the same
  // address would count as "new" every round and exhaustion never arrives.
  const measured = await shell(`derived-${round}${tag}`, 'Loop',
    `bash "${PLUGIN}/scripts/py.sh" derived_facts.py "${workdir}"\n` +
    `# Move old evidence prose to 08_docs/ once the record gets large, keeping\n` +
    `# every derived ROW in the table. The analyst re-reads this file each\n` +
    `# escalation, so unbounded growth makes every later round cost more.\n` +
    `bash "${PLUGIN}/scripts/py.sh" static_rotate.py "${workdir}" >/dev/null 2>&1 || true`,
    DERIVED_SCHEMA)
  return { esc, measured }
}

// =============================================================================
// Phase 3 - Loop
// =============================================================================
/* The highest round number this workspace already holds, below the negative-test range. A
 * resumed run used to start at 1 again: its console_N / kernel_N / host_N / trace files
 * overwrote the earlier rounds' and rounds.jsonl got the same number twice, so what an
 * earlier session saw was lost. Two sources, because a round that died before it was
 * recorded still left its logs: rounds.jsonl ("round": N rows) and 07_logs (<kind>_N.<ext>).
 * Plain shell tools only, no inline python. */
function roundBaseCmd() {
  return inBash(
    `WD=${shq(workdir)}\n` +
    `LIM=${NEGATIVE_RUN_BASE}\n` +
    `RJ=0; LG=0\n` +
    `if [ -f "$WD/rounds.jsonl" ]; then\n` +
    `  RJ=$(grep -o '"round": *[0-9][0-9]*' "$WD/rounds.jsonl" 2>/dev/null | sed -E 's/[^0-9]//g' | ` +
    `awk -v lim="$LIM" '$1 + 0 < lim && $1 + 0 > m { m = $1 + 0 } END { print m + 0 }')\n` +
    `fi\n` +
    `if [ -d "$WD/07_logs" ]; then\n` +
    `  LG=$(ls "$WD/07_logs" 2>/dev/null | sed -nE 's/^[A-Za-z_]+_([0-9]+)[._].*$/\\1/p' | ` +
    `awk -v lim="$LIM" '$1 + 0 < lim && $1 + 0 > m { m = $1 + 0 } END { print m + 0 }')\n` +
    `fi\n` +
    `echo "rounds_jsonl=$RJ"; echo "logs=$LG"\n` +
    `if [ "$RJ" -gt "$LG" ]; then echo "last_round=$RJ"; else echo "last_round=$LG"; fi\n` +
    `# Report last_round, rounds_jsonl and logs from those three lines, as integers.`)
}

phase('Loop')

const roundBaseAnswer = await shell('round-base', 'Loop', roundBaseCmd(), ROUND_BASE_SCHEMA)
// A null or missing number is "could not read it", never round 0.
const lastRoundRaw = roundBaseAnswer?.last_round
const lastRound = lastRoundRaw == null || lastRoundRaw === '' ? NaN : Number(lastRoundRaw)
const roundBaseOk = Number.isInteger(lastRound) && lastRound >= 0 && lastRound < NEGATIVE_RUN_BASE
const roundBase = roundBaseOk ? lastRound : 0
if (!roundBaseOk) {
  log('[루프] ⚠ 이 작업 폴더의 마지막 회차 번호를 읽지 못했습니다 — 1 회차부터 시작합니다. 이전 실행의 ' +
      '회차 로그가 있다면 같은 번호의 파일이 덮일 수 있습니다.')
} else if (roundBase > 0) {
  log(`[루프] 재개 — 이 작업 폴더에 회차 ${roundBase} 까지의 기록이 있어 회차 ${roundBase + 1} 부터 이어서 번호를 매깁니다 ` +
      `(rounds.jsonl ${roundBaseAnswer.rounds_jsonl ?? '?'} · 07_logs ${roundBaseAnswer.logs ?? '?'}). ` +
      `런타임 회차 한계 ${ROUND_CAP} 는 이번 실행에서 도는 회차에만 적용됩니다.`)
  await shell('round-base-decision', 'Loop',
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('회차 번호')} ` +
    `${shq(`${roundBase + 1} 부터 이어서`)} ` +
    `${shq(`이전 실행이 회차 ${roundBase} 까지 남겼습니다 — 1 부터 다시 매기면 이전 회차의 콘솔·커널 로그·트레이스를 ` +
           `덮고 rounds.jsonl 에 같은 번호가 두 번 생깁니다`)} || true`,
    OK_SCHEMA)
}

const roundLog = []
let round = roundBase            // the number of the round being run; the loop head adds one
let goalIndex = 0
let stopped = false
let stopReason = null
// Consecutive re-runs spent because the input never reached the gate. Reset by
// any round whose input path did work, so a single bad moment does not use up
// the allowance for the rest of the run.
let starvedRetries = 0
// The last DEFINITE reading of whether the boot medium's partition table could
// be read. "unknown" never overwrites it: a round that died early tells us
// nothing about storage, and letting it erase a real observation would make the
// gate below flicker.
let storageVerdict = 'unknown'
let storageSeenAt = null
// Rungs the run actually OBSERVED - a milestone the run script credited after the
// provenance gate - across every round. `reached_goals` is this and nothing else. It used
// to be "everything below the goal index", which reports a rung nobody saw: the loop may
// step over one whose evidence it cannot see (a stage with no console string of its own
// is seen only by its entry PC) as soon as a higher rung is observed. Those are listed
// apart, as passed over.
const observedRungs = new Set()
const passedOverRungs = new Set()
// The round that cleared the last rung and its observation: what Verify measures (its
// trace, its console, its kernel log).
let reachedObs = null
let reachedRound = 0
// What kernel_alive rests on, as the record of the round that cleared it: the channel, and
// whether the kernel banner was observed / not observed / not verified (see aliveBanner).
let kernelAliveBasis = null
// Consecutive rounds observed waiting for input while no input path is known.
let inputWaitRounds = 0
// How many times the region has been tried (see memdumpPlanKnown).
let memdumpAttempts = 0

/* The bash that puts ONE fixer change through the gate, into the tree that is compiled, and on the
 * record - the same for a specialist's change and for the last-resort fixer's, so that nothing a fixer
 * can do skips the check. `c`: round, goal, obs, category, fixer, changeKey, rationale, progress (the
 * PROGRESS.md line), cause and fixText (the journal's words), newFacts. */
function applyChangeCmd(c) {
  // The last-resort fixer exists because not every stop point has a specialist: one mechanism may span
  // several places and files, so for it check_change.sh skips ONLY the one-file and hunk limits
  // (CHANGE_SCOPE=general). The bypass-record checks apply to every fixer.
  const gateScope = c.fixer === GENERAL_FIXER ? 'CHANGE_SCOPE=general ' : ''
  return `# 1) Change gate. On violation the edit is rolled back and the round is void.\n` +
    `${gateScope}bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" verify; GATE=$?\n` +
    `if [ $GATE -ne 0 ]; then bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" restore; fi\n` +
    `# 2) Carry the edit into the tree ninja compiles. The fixer edits\n` +
    `#    06_machine/machine.c; hw/arm/ holds the copy that is actually built.\n` +
    `#    Without this the round rebuilds and runs the PREVIOUS binary, the\n` +
    `#    fingerprint does not move, and a fix that was never in the image is\n` +
    `#    recorded as futile.\n` +
    `bash "${PLUGIN}/scripts/sync_machine.sh" "${workdir}" ${machine}; SYNC=$?\n` +
    `# 3) Rebuild. Report build errors verbatim; never guess a fix.\n` +
    `if [ $SYNC -eq 0 ]; then cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64; ` +
    `else echo "SYNC FAILED - build skipped (report sync_ok=false)"; fi\n` +
    `# 4) Human-readable one-line history\n` +
    `echo ${shq(c.progress ?? '')} >> "${workdir}/PROGRESS.md"\n` +
    `# 5) Journal entry\n` +
    journalTryEnd(c.round, c.category ?? 'unknown', c.cause ?? '', c.fixText ?? '', c.obs?.summary ?? '') + `\n` +
    `# 6) Machine-readable round record - exactly one line per round.\n` +
    `#    The branch is bash, not a judgement call: recording both would put two\n` +
    `#    identical fingerprints in rounds.jsonl and fake a stall.\n` +
    `if [ $GATE -eq 0 ]; then\n` +
    `  ` + recordRoundCmd(c.round, c.goal, c.obs, c.category, c.fixer, c.changeKey,
                          'applied', c.newFacts, false, c.rationale) + `\n` +
    `else\n` +
    `  ` + recordRoundCmd(c.round, c.goal, c.obs, c.category, c.fixer, c.changeKey,
                          'reverted', c.newFacts, false, c.rationale) + `\n` +
    `fi\n` +
    `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" metric phase=Loop round=${c.round} ` +
    `event=apply_end tokens_total=${budget.spent()}\n` +
    `\n# Report gate_pass from the check_change JSON, sync_ok from the ` +
    `sync_machine.sh JSON (synced/unmapped), and build_ok from ninja.`
}

/* Apply one fixer change and say what became of it: 'continue' (the round is done - applied, or
 * rolled back by the gate and recorded as reverted) or 'break' (the tree could not be built, the run
 * stops). `c.builtOk` is the fixer's own report of its build, when it gave one: the build measured
 * here wins, and a fixer's "false" stands only when this measurement did not contradict it. */
async function applyChange(c) {
  const applied = await shell(`apply-${c.round}`, 'Loop', applyChangeCmd(c), APPLY_SCHEMA)
  const general = c.fixer === GENERAL_FIXER
  if (applied && applied.gate_pass === false) {
    log(`[루프] 회차 ${c.round}: ★ 한 변경 검문 불통과 — ${applied.gate_reason ?? ''} (되돌렸습니다)`)
  }
  if (applied && applied.sync_ok === false) {
    // The edit never reached the tree that gets compiled, so the next round
    // would measure the previous binary and read the fix as futile. That is a
    // setup fault, not a firmware verdict - stop and say so.
    await shell(`sync-blocker-${c.round}`, 'Loop',
      `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
      `detail=${shq(`회차 ${c.round} 머신 소스를 QEMU 트리로 반영하지 못했습니다: ${applied.sync_reason ?? ''}`)}`,
      OK_SCHEMA)
    log(`★ 정지 — 머신 소스가 QEMU 트리에 반영되지 않았습니다 (${applied.sync_reason ?? ''}). ` +
        `이 상태로 계속하면 고쳐도 이전 바이너리를 측정합니다.`)
    stopped = true; stopReason = 'BLOCKED_BUILD'
    return 'break'
  }
  if ((applied && applied.build_ok === false) || (c.builtOk === false && applied?.build_ok !== true)) {
    await shell(`${general ? 'general-' : ''}build-blocker-${c.round}`, 'Loop',
      `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
      `detail=${shq(`회차 ${c.round} ${general ? 'fixer-general ' : ''}재빌드 실패`)}`,
      OK_SCHEMA)
    stopped = true; stopReason = 'BLOCKED_BUILD'
    return 'break'
  }
  roundLog.push({ round: c.round, goal: c.goal, category: c.category, fixer: c.fixer,
                  change_key: c.changeKey, rationale: c.rationale })
  return 'continue'
}

/* The last-resort fixer's answer, settled. It is reached three ways - the supervisor sends a stop
 * point straight to it, every ranked specialist declined, or QEMU aborted after the guest had printed
 * - and all three end the same: it declines (and the round is recorded as a stall), or its change goes
 * through applyChange (the same gate as a specialist's: check_change.sh, rollback, rebuild, record).
 * Returns 'continue' or 'break'. `o`: declineLabel (the shell label's stem), declineNote (the journal's
 * words), newFacts (analyst facts counted this round), cause (the journal's cause for an applied change,
 * when it is not the fixer's own rationale), stopOnDecline (a decline ends the run as BLOCKED_BUILD - for a
 * QEMU abort, where nothing is left to derive from). */
async function settleGeneral(gen, round, goal, obs, category, o) {
  if (!gen || gen.no_new_change || !gen.change_key) {
    log(`[루프] 회차 ${round}: fixer-general 도 새로 시도할 변경이 없습니다.`)
    noteDecline(round, GENERAL_FIXER, gen)
    await shell(`${o.declineLabel}-${round}`, 'Loop',
      journalTryEnd(round, category, `${o.declineNote}${gen?.rationale ? ` — ${gen.rationale}` : ''}`,
                    o.stopOnDecline ? '시도할 변경 없음' : '도출로 이관', obs?.summary ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, category, GENERAL_FIXER, null, 'stall', o.newFacts, true),
      OK_SCHEMA)
    if (o.stopOnDecline) { stopped = true; stopReason = 'BLOCKED_BUILD'; return 'break' }
    return 'continue'
  }
  log(`[루프] 회차 ${round}: ★ fixer-general 이 처리 — ${gen.mechanism ?? ''}`)
  return await applyChange({
    round, goal, obs, category, fixer: GENERAL_FIXER, changeKey: gen.change_key,
    rationale: gen.rationale, progress: gen.one_line_progress ?? '',
    cause: o.cause ?? gen.rationale ?? gen.mechanism ?? '',
    fixText: (gen.changes ?? []).map(x => `${x.file}: ${x.what}`).join(' / '),
    newFacts: o.newFacts, builtOk: gen.build_ok,
  })
}

while (goalIndex < goals.length && !stopped && round - roundBase < ROUND_CAP) {
  const goal = goals[goalIndex]
  round += 1

  // run_round.sh performs the journal entry, the change snapshot, the run and the
  // stop-condition computation, then merges them into one document. The agent only
  // relays that document: it never assembles `stop` itself, so the stop backstop
  // cannot be weakened by a transcription slip.
  const obs = await shell(`run-${round}`, 'Loop',
    `${MAX_EXCEPTIONS > 0 ? `MAX_EXCEPTIONS=${MAX_EXCEPTIONS} ` : ''}TIMEOUT=${RUN_TIMEOUT} ` +
    `bash "${PLUGIN}/scripts/run_round.sh" "${workdir}" ${machine} ${round} ` +
    `${shq(goal)} ${shq(ladderArg)} ${shq(bootloader_path)} help ${shq(activeSurface)}\n` +
    `\n# This prints ONE observation document, also saved to ${workdir}/observation.json.\n` +
    `# Relay it as-is. Do not merge, re-derive or adjust any field - above all\n` +
    `# stop and stop_reason, which the pipeline enforces against your route.\n` +
    `# kernel_log and host_log are file paths or null: relay a null as null, never as a path you made up.`,
    RUN_SCHEMA)

  // What this round observed. A round that did not run observed nothing; a console the
  // provenance gate voided (injected) arrives with an empty list, so nothing is credited
  // for text we printed ourselves.
  const newlyObserved = []
  if (obs && obs.run_ok !== false) {
    const seen = obs.milestones_reached?.length ? obs.milestones_reached : [obs.milestone ?? 'none']
    for (const g of seen) {
      if (goals.includes(g) && !observedRungs.has(g)) { observedRungs.add(g); newlyObserved.push(g) }
    }
  }
  // A round that did not actually run is not evidence about the firmware. Left
  // as an ordinary round it produces a perfectly stable all-zero fingerprint,
  // which the stop conditions correctly read as a stall and then as EXHAUSTED -
  // "structurally unreachable" - about a QEMU that never started. Eight rounds
  // of the S921N log died exactly this way, so this is a stop, not a log line.
  // QEMU died, but the guest had already printed. That is a defect in the machine
  // we wrote, not a missing dependency - and the assert names the file and the
  // function, so the place is already located. Sending it to BLOCKED_ENV stops
  // the run and assigns nobody, which is how a blk_set_perm() omission ended up
  // being repaired by hand outside the loop.
  if (obs?.run_fault === true) {
    log(`[루프] 회차 ${round}: QEMU 비정상 종료 — 콘솔이 나온 뒤이므로 머신 결함입니다 (qemu_abort)`)
    await shell(`run-fault-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
      `${shq(`회차 ${round} qemu_abort: ${obs?.run_fault_line ?? ''}`)}`,
      OK_SCHEMA)
    const fix = await runGeneralFixer(round, goal,
      'QEMU aborted after the guest had already printed: a machine-source defect, not an environment ' +
      'problem. The assert line names the QEMU source file and function, so the place is already located.\n' +
      `assert: ${obs?.run_fault_line ?? '(not in stderr)'}\n` +
      'Typical case: a BlockBackend borrowed with blk_by_name() and never given blk_set_perm() - reads ' +
      'work, the first write dies on the assert.',
      null, obs, { category: 'qemu_abort', evidence: { assert: obs?.run_fault_line } }, '')

    // A decline ends the run here (nothing is left to derive a QEMU abort from); a change goes through
    // the same gate as every fixer's - check_change.sh, rollback, rebuild, record.
    if (await settleGeneral(fix, round, goal, obs, 'qemu_abort', {
          declineLabel: 'abort-decline', declineNote: String(obs?.run_fault_line ?? ''),
          cause: String(obs?.run_fault_line ?? ''), newFacts: 0, stopOnDecline: true }) === 'break') break
    // No `round++` here: the loop head advances the counter. Incrementing it as well
    // skipped a number after every qemu_abort - the round log read 4, 6, 7 - and a
    // number nobody ran is a snapshot and a log file that do not exist.
    continue
  }

  if (obs?.run_ok === false) {
    log(`[루프] 회차 ${round}: ★ 실행 자체가 실패했습니다 — ${obs?.run_error ?? 'fingerprint.json 없음'}`)
    await shell(`run-blocker-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_ENV ` +
      `detail=${shq(`회차 ${round} QEMU 실행 실패: ${obs?.run_error ?? 'fingerprint.json 미생성'}`)}\n` +
      `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
      `${shq(`실행 실패로 정지 (회차 ${round}) — 펌웨어 판정이 아니라 하네스/환경 문제입니다`)}`,
      OK_SCHEMA)
    stopped = true; stopReason = 'BLOCKED_ENV'
    break
  }

  // The gate polled the console and never got a byte of ours. That is the input
  // path failing, not the firmware deciding anything, and classifying it spends
  // a fixer round on a fault that does not exist. Re-run instead - and say so
  // when the retries are used up, rather than letting it pass as an observation.
  if (obs?.input_starved === true) {
    if (starvedRetries < STARVED_RETRIES) {
      starvedRetries += 1
      log(`[루프] 회차 ${round}: ★ 입력이 게이트에 닿지 않았습니다 ` +
          `(폴링 ${obs?.rx_polls ?? '?'} 회, 읽힌 바이트 0). 펌웨어 판정이 아니므로 ` +
          `분류하지 않고 재실행합니다 (${starvedRetries}/${STARVED_RETRIES}).`)
      await shell(`starved-${round}`, 'Loop',
        `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
        `${shq(`회차 ${round}`)} ${shq('입력 굶음 — 재실행')} ` +
        `${shq(`uart_harness 가 보낸 바이트를 펌웨어가 한 번도 읽지 않았습니다 ` +
               `(${obs?.input_summary ?? ''})`)}`,
        OK_SCHEMA)
      round -= 1            // this was not a round about the firmware
      continue
    }
    // Out of retries. Say what is being carried forward as an observation and
    // why it is suspect, instead of letting it pass silently as one.
    log(`[루프] 회차 ${round}: 입력 굶음이 재실행 ${STARVED_RETRIES} 회 뒤에도 계속됩니다 — ` +
        `관측으로 취급하고 분류를 진행하지만, input_plan 의 contiguous/empty_poll_budget 과 ` +
        `게이트 공급 창을 함께 의심하세요.`)
  } else {
    starvedRetries = 0
  }

  // Did this run get far enough to say anything about the boot medium?
  if (obs?.storage_partition_table === 'missing' || obs?.storage_partition_table === 'ok') {
    if (storageVerdict !== obs.storage_partition_table) {
      storageVerdict = obs.storage_partition_table
      storageSeenAt = round
      if (storageVerdict === 'missing') {
        log(`[루프] 회차 ${round}: 펌웨어가 파티션표를 읽지 못했다고 보고했습니다 ` +
            `(${obs?.storage_token ?? ''}). 이 플로우는 매체를 직접 모델하므로 이것은 ` +
            `트랙 경계가 아니라 **우리가 합성한 매체의 결함**입니다 — ` +
            `fixer-storage 가 담당합니다 (partition_table_unavailable).`)
      }
    }
  }

  // A missing partition table used to stop the run here, because a bootloader
  // track had no storage model and nothing could have fixed it. This flow models
  // the medium, so the same report now means the image WE synthesised is wrong -
  // a fault with an owner, not a boundary. It goes to the classifier like any
  // other observation, and BLOCKED_STORAGE no longer exists.

  log(`[루프] 회차 ${round} (목표 ${goal}) — 마일스톤 ${obs?.milestone ?? '?'}, ` +
      `콘솔 고유 ${obs?.console_uniq ?? 0} 줄, 예외 ${obs?.exceptions ?? '?'} 건, ` +
      `최초 ${obs?.origin_type ?? 'none'}@${obs?.origin_elr ?? 'none'}, ` +
      `정체 ${obs?.stall_count ?? 0} 회` +
      (obs?.injected ? ' ★ 자가주입 감지' : '') +
      ` · 입력: ${obs?.prompt_seen ? '프롬프트 관측' : '프롬프트 미관측'}` +
      `${obs?.rx_reported ? `, 펌웨어가 읽은 바이트 ${obs?.rx_served ?? '?'}` : ''}` +
      (obs?.timeout_bound === true ? ' ★ 타임아웃 한계 (더 돌리면 더 나옴)' : '') +
      (obs?.channels?.kernel_lines > 0
        ? ` · 커널 채널 ${obs.channels.kernel_lines} 줄(마지막 커널 시각 ${obs?.kernel_last_time ?? '?'}s, ` +
          `고유 ${obs?.kernel_uniq ?? '?'} 줄)`
        : '') +
      (obs?.early_exit ? ' ★ 예외 수 한계로 조기 종료' : ''))
  // Loss between memory dumps is reported, not hidden: a gap in the kernel log is a gap
  // in what we saw, and a rung that depends on a line in it may have been missed.
  if (obs?.kernel?.gaps?.count > 0) {
    log(`[루프] 회차 ${round}: 커널 로그 유실 의심 ${obs.kernel.gaps.count} 구간, ` +
        `합 ${obs.kernel.gaps.total_s}s / ${obs.kernel.gaps.span_s}s (메모리 덤프 사이의 공백 — ` +
        `게스트가 한 말이 아니라 우리가 못 본 구간입니다)`)
  }
  if (obs?.guest_reset_signal === true) {
    log(`[루프] 회차 ${round}: ★ 커널 점프 직후 리셋/워치독 블록 접근 신호 — 가설 guest_reset_after_jump ` +
        `(미확정). 분류기에 후보로 넘깁니다.`)
  }

  // --- derived from this round, not from the firmware image ---------------------------
  // The bootloader's own console says things no static analysis can: whether the storage
  // it initialised is eMMC or UFS, and where it reserved the ring the kernel logs into.

  // (1) Waiting for input with no input path. With no surface derived the run goes on
  // regardless; only a round OBSERVED parked on the console, with nothing new reached, round
  // after round, ends it - and then the stop is a measurement, not a derivation.
  if (activeSurface === 'none' && !observedRungs.has('kernel_entry')) {
    if (newlyObserved.length === 0 && waitingForInput(obs)) inputWaitRounds += 1
    else inputWaitRounds = 0
    if (inputWaitRounds >= INPUT_WAIT_ROUNDS) {
      const detail =
        `입력 경로가 없다고 도출된 부트로더(autoboot)가 ${inputWaitRounds} 회차 연속으로 입력을 기다리는 ` +
        `것이 관측됨 — 콘솔 수신 경로 폴링 ${obs?.rx_polls ?? '?'} 회, 예외 ${obs?.exceptions ?? '?'}건, ` +
        `새로 도달한 칸 없음. ` +
        `표면이 없다는 도출이 틀렸거나, 입력이 필요한 단계에서 멈춘 것입니다`
      await shell(`record-input-blocker-${round}`, 'Loop',
        `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_NO_INPUT_PATH ` +
        `detail=${shq(detail)}\n` +
        `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ${shq(`하드 블로커 BLOCKED_NO_INPUT_PATH: ${detail}`)}`,
        OK_SCHEMA)
      log(`★ 정지 — BLOCKED_NO_INPUT_PATH (회차 ${round}): ${detail}`)
      stopped = true; stopReason = 'BLOCKED_NO_INPUT_PATH'
      break
    }
  } else {
    inputWaitRounds = 0
  }

  // (2) Autoboot is observed the moment a round reaches the kernel jump with no command of
  // ours having been sent: the surface was never needed. Until then it stays pending.
  if (autobootState === 'pending' && observedRungs.has('kernel_entry')) {
    autobootState = 'observed'
    log(`[루프] 회차 ${round}: autoboot 관측 — 입력 명령 없이 커널 점프(kernel_entry)에 도달했습니다.` +
        (obs?.rx_reported && Number(obs?.rx_served ?? 0) > 0
          ? ` 단, 펌웨어가 하니스가 보낸 바이트 ${obs.rx_served}개를 읽었습니다 — 입력이 전혀 없었다는 뜻은 아닙니다.`
          : ''))
    await shell(`autoboot-observed-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('autoboot')} ` +
      `${shq('pending → observed')} ` +
      `${shq(`회차 ${round} 에서 kernel_entry 도달 (보낸 명령 ${obs?.command_sent ? '있음' : '없음'}` +
             `${obs?.rx_reported ? `, 펌웨어가 읽은 하니스 바이트 ${obs?.rx_served ?? '?'}` : ''})`)} || true`,
      OK_SCHEMA)
  }

  // (3) The memory-dump region. Tried when a round brought something new (the reservation
  // is printed on the way to the kernel jump) and never once a plan exists. A kernel that
  // logs only into RAM looks like a silent UART, and without the plan the channel that
  // can see it stays off.
  if (!memdumpPlanKnown && target !== 'F1' && Number(obs?.console_bytes ?? 0) > 0 &&
      (memdumpAttempts === 0 || newlyObserved.length > 0)) {
    memdumpAttempts += 1
    const plan = await shell(`memdump-plan-${round}`, 'Loop', derivePlanCmd(round), PLAN_SCHEMA)
    if (plan?.present === true) memdumpPlanKnown = true
    if (plan?.derived === true) {
      log(`[루프] 회차 ${round}: 메모리 덤프 영역 도출 — ${JSON.stringify(plan.plan ?? {})} ` +
          `(다음 회차부터 커널 로그를 RAM 에서 읽습니다)`)
      await agent(
        `Record a derived fact. ${workdir}/memdump_plan.json was just written by ` +
        `scripts/memdump_observe.py derive from the bootloader's own console of round ${round}.\n` +
        `Plan: ${JSON.stringify(plan.plan ?? {})}\n` +
        `Append to ${staticDoc} (never overwrite it) a short section "메모리 덤프 채널": where the ` +
        `kernel log lives in RAM (region, size, ring capacity), the evidence line it came from ` +
        `QUOTED VERBATIM (it is in the plan's "evidence" field), and what follows from it - the ` +
        `UART may stay silent while the kernel runs, the host reads the ring out of RAM instead, ` +
        `and silence is not failure. Do not re-derive and do not change the plan file; if the ` +
        `evidence line does not support the numbers, say so in the section and in your answer.\n` +
        familyContext() + DOC_STYLE,
        { agentType: 'static-analyzer', schema: OK_SCHEMA, label: `memdump-evidence-${round}`, phase: 'Loop' })
    } else if (plan && plan.present !== true && plan.reason) {
      log(`[루프] 회차 ${round}: 메모리 덤프 영역을 아직 도출하지 못했습니다 — ${plan.reason}`)
    }
  }

  // (4) The boot medium, once the bootloader's log can speak to it. The first answer came
  // from device trees alone and the log outranks them: a DTB-only answer, or "unknown", that
  // the log then contradicts means the machine and the medium were BUILT on a wrong premise.
  // That is the build layer, so it is rebuilt - not patched by a fixer.
  if (mediumBasis !== 'bootloader_log' && Number(obs?.console_bytes ?? 0) > 0 &&
      (mediumTried === 0 || newlyObserved.length > 0)) {
    mediumTried += 1
    const m = await shell(`detect-medium-${round}`, 'Loop',
      detectMediumCmd(`${workdir}/07_logs/console_${round}.txt`), MEDIUM_SCHEMA)
    if (m?.hci_kind && m.basis === 'bootloader_log') {
      await shell(`record-medium-${round}`, 'Loop',
        recordMediumCmd(`회차 ${round} — 부트로더 로그`, m), OK_SCHEMA)
      const before = mediumKind
      mediumKind = m.hci_kind
      mediumBasis = 'bootloader_log'
      log(`[루프] 회차 ${round}: 부팅 매체 판정 ${before} → ${mediumKind} (부트로더 로그, 확신 ${m.confidence ?? '?'})`)
      const key = `medium:${before}->${mediumKind}`
      if (before !== mediumKind && !(obs?.tried_changes ?? []).includes(key)) {
        const why = `머신과 매체는 부팅 매체를 ${before} 로 보고 지었는데 부트로더 자신의 로그가 ` +
                    `${mediumKind} 라고 말합니다: ${(m.evidence ?? [])[0] ?? m.reason ?? ''}`
        log(`[루프] 회차 ${round}: ★ 층 판정 — 빌드 계층 전제(부팅 매체) 정정, 머신과 매체를 다시 만듭니다`)
        await shell(`medium-decision-${round}`, 'Loop',
          `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
          `${shq(`회차 ${round}`)} ${shq(`머신 재생성 (${key})`)} ${shq(why)} || true`,
          OK_SCHEMA)
        const rebuilt = await buildMachine({
          round, reason: why,
          change: `Rebuild the boot medium for ${mediumKind} (build_lu.py --family ${familyFlag()} --medium ${mediumKind}, and ` +
                  `"medium" in lu_manifest.json) and use the storage model that matches: ` +
                  (mediumKind === 'emmc'
                    ? 'the eMMC controller model - not the UFS host controller of storage_hci.c.tmpl'
                    : 'the UFS host controller model') +
                  `. Keep every other derived value as it is.`,
        })
        buildWarnings = Array.isArray(rebuilt?.build_warnings) ? rebuilt.build_warnings : buildWarnings
        if (rebuilt && rebuilt.build_ok === false) {
          await shell(`medium-rebuild-blocker-${round}`, 'Loop',
            `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
            `detail=${shq(`회차 ${round} 부팅 매체 정정 후 머신 재생성 실패`)}`,
            OK_SCHEMA)
          stopped = true; stopReason = 'BLOCKED_BUILD'
          break
        }
        await shell(`medium-rebuild-record-${round}`, 'Loop',
          journalTryEnd(round, 'build_layer', why, `부팅 매체 ${before} → ${mediumKind}`, obs?.summary ?? '') + `\n` +
          recordRoundCmd(round, goal, obs, 'build_layer', 'build', key, 'applied', -1, false,
                         `부팅 매체 판정이 부트로더 로그로 ${mediumKind} 로 확정됨`),
          OK_SCHEMA)
        roundLog.push({ round, goal, category: 'build_layer', fixer: 'build', change_key: key,
                        rationale: `boot medium ${before} -> ${mediumKind}` })
        continue
      }
    }
  }

  // Everything derived about this firmware so far. Read before the supervisor,
  // because judging the layer means comparing the machine's premises against the
  // derived facts - and read again after an escalation, which may add rows.
  let analystNewFacts = -1
  let derived = await shell(`derived-peek-${round}`, 'Loop',
    `bash "${PLUGIN}/scripts/py.sh" derived_facts.py "${workdir}" --peek`,
    DERIVED_SCHEMA)
  let derivedRows = (derived?.stop_points ?? [])
  const renderDerived = rows => rows.length
    ? rows.map(r => `- ${r.signature}: ${r.observation} → ${r.mechanism} ` +
                    `[owner ${r.fixer}] try: ${r.treatment}`).join('\n')
    : '(no stop points derived yet)'
  let derivedTable = renderDerived(derivedRows)

  // The mechanical routes (stop / verify / next_goal) are already decided by
  // measurement, and the pipeline enforces them below. What is genuinely left to
  // judgement is the LAYER question: can this stop point be fixed by one change
  // inside the machine sources, or is a machine-level premise wrong? A script
  // cannot answer that - it needs someone to read the sources against the
  // derived facts. So the supervisor gets the evidence and a stronger model
  // rather than a lookup table.
  const recent = roundLog.slice(-6)
  const sup = await agent(
    `Round ${round}, current goal "${goal}" (ladder: ${ladderArg}).\n` +
    `Fingerprint file: ${workdir}/fingerprint.json\n` +
    `Fingerprint: ${fingerprintText(obs)}\n` +
    `Stop conditions: ${JSON.stringify({
      stop: obs?.stop, stop_reason: obs?.stop_reason, stall_count: obs?.stall_count,
      escalate_to_analyst: obs?.escalate_to_analyst,
      suspect_prior_bypass: obs?.suspect_prior_bypass,
      best_milestone: obs?.best_milestone,
      best_progress: obs?.best_progress,
      futile_changes: obs?.futile_changes,
      needs_layer_review: obs?.needs_layer_review,
    })}\n` +
    `Observed milestone: ${obs?.milestone}, provenance gate injected: ${obs?.injected}\n` +
    `Rungs observed so far: ${[...observedRungs].join(', ') || '(none)'}\n` +
    (activeSurface === 'none'
      ? `Surface: none - the ladder has NO surface rung; autoboot is ${autobootState}. Only a round ` +
        `OBSERVED parked on the console (polling it, nothing new reached, round after round) counts ` +
        `as "waiting for input"; the pipeline stops on that measurement alone, never on the ` +
        `derivation that there is no surface.\n`
      : '') +
    familyContext() +
    channelStateText() +
    `Boot depth this round: ${obs?.console_uniq ?? 0} distinct console lines ` +
    `(best so far ${obs?.best_progress?.uniq ?? 0} in round ${obs?.best_progress?.round ?? '-'}). ` +
    `On a one-rung ladder this is the only measure of forward motion - a milestone ` +
    `of "none" does not mean the boot went nowhere.\n` +
    channelsText(obs, round) +
    (obs?.kernel_moving === true
      ? `The kernel log is moving (deeper than ever before) while the UART may sit still: ` +
        `that is a boot in progress, not a stall.\n`
      : '') +
    (obs?.timeout_bound === true
      ? `★ A longer run produced MORE console (${obs?.console_bytes}B → ` +
        `${obs?.probe_console_bytes}B). This wall is the run timeout, not the ` +
        `firmware. Do not send a fixer after a stop point that is our own clock.\n`
      : obs?.timeout_bound === null || obs?.timeout_bound === undefined
        ? `timeout_bound is null: the longer-run probe did NOT run this round, so ` +
          `nothing is known about whether the wall is our clock. Treat it as ` +
          `unmeasured, not as "measured and it is the firmware".\n`
        : '') +
    // Before naming a stop point at all: did our input ever reach the gate? On
    // S921N the harness fired the command without ever seeing the prompt in every
    // single round, including the two that reached the shell, and no artifact
    // said so. A surface that was never offered its input is not a firmware fact.
    (`INPUT PATH THIS ROUND - check this BEFORE naming a stop point.\n` +
        `  prompt observed: ${obs?.prompt_seen}   command sent: ${obs?.command_sent}\n` +
        (obs?.rx_reported
          ? `  the firmware read ${obs?.rx_served} of our bytes across ` +
            `${obs?.rx_polls} console polls\n`
          : `  the machine does not report RX consumption, so how much of our ` +
            `input the firmware actually took is unknown (rebuild picks up the ` +
            `counters from ${abs('templates/machine_full.c.tmpl')})\n`) +
        (obs?.input_starved
          ? `  ★ STARVED: the gate polled and got none of our bytes. This is the ` +
            `harness, not the firmware. Do not prescribe a fixer for it.\n`
          : '') +
        `  Details: ${obs?.input_summary ?? '(none)'}\n` +
        `BOOT MEDIUM: partition table = ${obs?.storage_partition_table ?? 'unknown'}` +
        (obs?.storage_partition_table === 'missing'
          ? ` (${obs?.storage_token ?? ''})\n` +
            `  The medium is MODELLED here, so this is not a boundary: the image ` +
            `we synthesised is wrong. Route it to fixer-storage as ` +
            `partition_table_unavailable and check the GPT signature offset ` +
            `against the block size the controller reports. Every downstream ` +
            `failure - partition lookups, environment, loading the next stage - ` +
            `follows from this one, so do not name them separately.\n`
          : `\n`)) +
    `Recent rounds: ${JSON.stringify(recent)}\n` +
    `Derived stop points (${staticDoc}):\n${derivedTable}\n` +
    `Machine sources: ${workdir}/06_machine/   Bypasses: ${workdir}/06_machine/bypasses.md\n` +
    `Machine premises in force: has_el3, entry EL / CPU mode per stage, entry PC, load ` +
    `address, memory skeleton, the CPU types and the order they are created in, the boot ` +
    `medium kind (${mediumKind}, basis ${mediumBasis}) - all set at Build time, none of them ` +
    `reachable by a fixer.\n` +
    (buildWarnings.length
      ? `Build warnings (each is a premise nobody derived): ${buildWarnings.join(' / ')}\n`
      : '') +
    `Fixers implemented: ${KNOWN_FIXERS.join(', ')} ` +
    `(domains in ${abs('fixers/registry.yaml')} - read it before prescribing).\n` +
    `If the mechanism is understood but no implemented fixer covers it, route ` +
    `"${GENERAL_FIXER}" with a treatment_plan; it has no domain boundary and may ` +
    `edit, build and run. Do not force a fit onto a specialist whose domain does ` +
    `not contain the fault - that produces a decline and wastes the round.\n\n` +
    (obs?.needs_layer_review
      ? `★ ${obs?.futile_changes} changes have been tried (applied, or rolled back by the gate) ` +
        `and the fingerprint did not move. Treating the symptom is not working. READ the machine sources ` +
        `and the derived facts and judge the layer before routing anywhere.\n`
      : '') +
    `A bypass is a hypothesis about the hardware, and some of them turn out to be ` +
    `wrong. When a round's evidence CONTRADICTS the mechanism an earlier bypass ` +
    `assumed - not merely "it did not help" - route "revert" with ` +
    `revert={round, reason}. Everything after that round stays; only that change ` +
    `comes out. Leaving a disproven bypass in place makes every later change rest ` +
    `on a model you know is false, and it corrupts the bypass list that ` +
    `verification reports.\n` +
    `Choose a route. If stop is true you may only answer route="stop".\n` +
    `Round count and elapsed time are not stop reasons: when stop is false, keep going.`,
    { agentType: 'supervisor', schema: SUPERVISOR_SCHEMA, label: `supervisor-${round}`,
      phase: 'Loop', model: 'opus', effort: obs?.needs_layer_review ? 'high' : 'medium' }
  )

  // Honesty backstop: a measured stop cannot be routed around.
  let route = sup?.route ?? 'fault-classifier'
  if (obs?.stop === true && route !== 'stop') {
    await shell(`force-stop-${round}`, 'Loop',
      `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
      `${shq(`supervisor 회차 ${round}`)} ${shq('강제 정지')} ` +
      `${shq(`정지 조건이 stop=true(${obs?.stop_reason}) 인데 supervisor 가 ${route} 로 우회하려 해서 사실을 우선했습니다`)}`,
      OK_SCHEMA)
    log(`★ supervisor 가 정지를 우회하려 해서 강제로 멈춥니다 (${obs?.stop_reason})`)
    route = 'stop'
  }

  if (route === 'stop') {
    stopped = true
    stopReason = obs?.stop_reason ?? 'EXHAUSTED'
    break
  }

  // The kernel was jumped to, nothing of it was seen, and the guest touched its reset block
  // right afterwards. That is a stop-point SIGNAL, and the family table has a name for the
  // hypothesis it supports - so it goes to the classifier, which names it (or refuses to),
  // rather than straight to a fixer with no domain: a hypothesis nobody has confirmed is
  // not something a round should "fix".
  const guestResetNoKernel = obs?.guest_reset_signal === true &&
    !(obs?.milestones_reached ?? []).includes('kernel_alive')
  if (guestResetNoKernel && route === GENERAL_FIXER) {
    log(`[루프] 회차 ${round}: guest_reset_signal — fixer-general 직행 대신 분류기로 보냅니다 ` +
        `(후보 guest_reset_after_jump).`)
    route = 'fault-classifier'
  }

  // The supervisor judged that no implemented fixer covers this mechanism, so it
  // goes straight to the fixer with no domain boundary. Skipping classification
  // is the point: naming a category no fixer owns only spends a round.
  if (route === GENERAL_FIXER) {
    log(`[루프] 회차 ${round}: supervisor 판단 — 담당 fixer 없음, fixer-general 로 직행`)
    const gen = await runGeneralFixer(round, goal,
      `The supervisor found no implemented fixer whose domain contains this stop point.`,
      sup?.treatment_plan, obs, null, derivedTable, sup?.suspect_prior_bypass)
    if (await settleGeneral(gen, round, goal, obs, 'unowned', {
          declineLabel: 'general-decline', declineNote: 'fixer-general 도 시도할 변경 없음',
          newFacts: analystNewFacts }) === 'break') break
    continue
  }

  // Withdraw a bypass whose mechanism this round disproved. Until now the loop
  // could only add: `suspect_prior_bypass` asked the classifier to be
  // suspicious, but nothing could take the wrong model back out, so later
  // changes kept stacking on top of it and the bypass list stopped being an
  // honest account of the machine.
  if (route === 'revert') {
    const target = Number(sup?.revert?.round ?? 0)
    const key = `revert:${target}`
    if (!target || (obs?.tried_changes ?? []).includes(key)) {
      log(`[루프] 회차 ${round}: 되돌리기 대상이 없거나 이미 되돌린 회차라 분류로 보냅니다.`)
      route = 'fault-classifier'
    } else {
      log(`[루프] 회차 ${round}: ★ 회차 ${target} 우회 철회 — ${sup?.revert?.reason ?? ''}`)
      const rev = await shell(`revert-${round}`, 'Loop',
        `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
        `${shq(`supervisor 회차 ${round}`)} ${shq(`회차 ${target} 우회 철회`)} ` +
        `${shq(sup?.revert?.reason ?? '')}\n` +
        `bash "${PLUGIN}/scripts/revert_change.sh" "${workdir}" ${target} ` +
        `${shq(sup?.revert?.reason ?? '')}; REV=$?\n` +
        `if [ $REV -eq 0 ]; then\n` +
        `  bash "${PLUGIN}/scripts/sync_machine.sh" "${workdir}" ${machine} && ` +
        `(cd ~/qemu-build/qemu-10.2.2/build && ninja qemu-system-aarch64)\n` +
        `fi\n` +
        `# Report reverted/reason from the revert_change.sh JSON, build_ok from ninja.`,
        {
          type: 'object',
          properties: {
            reverted: { type: 'boolean' },
            reason: { type: ['string', 'null'] },
            build_ok: { type: ['boolean', 'null'] },
          },
          required: ['reverted'],
        })

      if (!rev || rev.reverted !== true) {
        // A refusal is a real answer: a later round edited the same place, so
        // the two changes interact and the interaction is what needs treating.
        log(`[루프] 회차 ${round}: 되돌리기 불가 — ${rev?.reason ?? ''} · 분류를 계속합니다.`)
        route = 'fault-classifier'
      } else {
        if (rev.build_ok === false) {
          await shell(`revert-build-blocker-${round}`, 'Loop',
            `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
            `detail=${shq(`회차 ${round} 우회 철회 후 재빌드 실패`)}`,
            OK_SCHEMA)
          stopped = true; stopReason = 'BLOCKED_BUILD'
          break
        }
        await shell(`revert-record-${round}`, 'Loop',
          `echo ${shq(`| run ${round} | 회차 ${target} 우회 철회 | ${sup?.revert?.reason ?? ''} |`)} ` +
          `>> "${workdir}/PROGRESS.md"\n` +
          journalTryEnd(round, 'bypass_revert', sup?.revert?.reason ?? '',
                        `회차 ${target} 변경 제거`, obs?.summary ?? '') + `\n` +
          recordRoundCmd(round, goal, obs, 'bypass_revert', 'supervisor', key,
                         'applied', analystNewFacts, false),
          OK_SCHEMA)
        roundLog.push({ round, goal, category: 'bypass_revert', fixer: 'supervisor',
                        change_key: key })
        continue
      }
    }
  }

  // The loop's own exit for stop points it cannot reach. A fixer edits one place
  // in an existing machine; it cannot correct a premise the machine was built on
  // (has_el3, entry EL, entry PC, load address, memory skeleton). Without this
  // route a wrong premise can only ever collect band-aids, which is exactly how a
  // run spends sixty rounds on one unchanging fingerprint.
  if (route === 'rebuild') {
    const key = sup?.build_change?.change_key
    const tried = (obs?.tried_changes ?? [])
    if (!key || !sup?.build_change?.change) {
      log(`[루프] 회차 ${round}: rebuild 를 요청했지만 구체적 변경이 없어 분류로 되돌립니다.`)
      route = 'fault-classifier'
    } else if (tried.includes(key)) {
      // Same rebuild twice is not a new move. Letting it through would make
      // "rebuild" an unlimited supply of moves and exhaustion unreachable.
      log(`[루프] 회차 ${round}: rebuild ${key} 는 이미 시도한 변경이라 거부하고 분류로 보냅니다.`)
      route = 'fault-classifier'
    } else {
      log(`[루프] 회차 ${round}: ★ 층 판정 — ${sup?.layer ?? 'build'} 층 문제로 판단, 머신 재생성`)
      log(`         근거: ${sup?.build_change?.reason ?? sup?.decision_note ?? ''}`)
      await shell(`rebuild-decision-${round}`, 'Loop',
        `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ` +
        `${shq(`supervisor 회차 ${round}`)} ${shq(`머신 재생성 (${key})`)} ` +
        `${shq(sup?.build_change?.reason ?? '')}`,
        OK_SCHEMA)

      const rebuilt = await buildMachine({
        round, reason: sup?.build_change?.reason ?? sup?.decision_note ?? '',
        change: sup?.build_change?.change,
      })
      if (Array.isArray(rebuilt?.build_warnings)) buildWarnings = rebuilt.build_warnings

      if (rebuilt && rebuilt.build_ok === false) {
        await shell(`rebuild-blocker-${round}`, 'Loop',
          `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" blocker code=BLOCKED_BUILD ` +
          `detail=${shq(`회차 ${round} 머신 재생성 실패`)}`,
          OK_SCHEMA)
        stopped = true; stopReason = 'BLOCKED_BUILD'
        break
      }

      await shell(`rebuild-record-${round}`, 'Loop',
        journalTryEnd(round, 'build_layer',
                      sup?.build_change?.reason ?? '',
                      sup?.build_change?.change ?? '', obs?.summary ?? '') + `\n` +
        recordRoundCmd(round, goal, obs, 'build_layer', 'build', key,
                       'applied', analystNewFacts, false),
        OK_SCHEMA)
      roundLog.push({ round, goal, category: 'build_layer', fixer: 'build',
                      change_key: key })
      continue
    }
  }

  // Goal advancement is decided by measurement, never by the supervisor's claim.
  // The run script already dropped any milestone that failed the provenance gate.
  //
  // Use every rung the run cleared, not just the highest. A ladder may skip rungs
  // (a raw-partition firmware has no `super_mounted`), so a top milestone outside
  // the ladder would otherwise
  // hide a lower rung inside it and strand the loop on a goal already met.
  const reachedList = (obs?.milestones_reached?.length ? obs.milestones_reached
                                                       : [obs?.milestone ?? 'none'])
  const reachedIndex = reachedList.reduce(
    (best, name) => Math.max(best, goals.indexOf(name)), -1)
  const goalMet = reachedIndex >= goalIndex

  if (goalMet) {
    const cleared = goals.slice(goalIndex, reachedIndex + 1)
    // The loop advances over every rung up to the highest observed one, but only the
    // OBSERVED ones are reached. A rung stepped over has no evidence of its own - say so
    // here and keep it out of reached_goals, rather than reporting what nobody saw.
    const clearedSeen = cleared.filter(g => observedRungs.has(g))
    const clearedPassed = cleared.filter(g => !observedRungs.has(g))
    clearedPassed.forEach(g => passedOverRungs.add(g))
    goalIndex = reachedIndex + 1
    reachedObs = obs
    reachedRound = round
    log(`[루프] ★ 목표 ${clearedSeen.map(g => `"${g}"`).join(', ')} 도달` +
        (clearedPassed.length
          ? ` (관측 없이 건너뜀: ${clearedPassed.map(g => `"${g}"`).join(', ')} — 더 높은 칸이 관측되어 ` +
            `다음으로 진행했을 뿐, 도달로 세지 않습니다)`
          : '') + ' — ' +
        (goalIndex >= goals.length ? '사다리를 모두 통과했습니다.' : `다음 목표는 "${goals[goalIndex]}" 입니다.`))
    // kernel_alive says what it rests on. The banner is the strongest evidence; a kernel
    // line that carries a kernel timestamp and the task that printed it is accepted when
    // the banner is not on record, and then the record says the banner was NOT observed.
    let aliveNote = null
    if (cleared.includes('kernel_alive')) {
      const ev = obs?.kernel_alive_evidence
      if (ev) {
        // "Banner observed" is written only when the evidence says so (aliveBanner): a UART
        // match carries no `via`, so for it the honest line is "not verified" - the record
        // must not claim a measurement nobody made.
        const banner = aliveBanner(ev)
        if (observedRungs.has('kernel_alive')) kernelAliveBasis = { channel: ev.channel ?? null, banner, round }
        aliveNote = `kernel_alive 근거: 채널 ${ev.channel ?? '?'}` +
          (ev.token ? `, 토큰 "${ev.token}"` : '') +
          (ev.kernel_time != null ? `, 커널 시각 ${ev.kernel_time}s` : '') +
          (ev.task ? `, 태스크 ${ev.task}` : '') +
          (banner === 'not_observed' ? ' — 배너 미관측 (대체 토큰으로 판정)'
            : banner === 'observed' ? ' — 배너 관측'
            : ' — 배너 관측 여부 미검증 (문자열 일치만 확인)')
        if (ev.note && banner !== 'not_observed') aliveNote += ` (${ev.note})`
      } else {
        if (observedRungs.has('kernel_alive')) kernelAliveBasis = { channel: null, banner: 'unknown', round }
        aliveNote = 'kernel_alive 근거 기록 없음 — 관측 문서에 kernel_alive_evidence 가 없습니다'
      }
      log(`[루프] ${aliveNote}`)
    }
    // How this goal was actually cleared. Nothing else writes this: rounds.jsonl
    // says what ran, but not which sequence of attempts ended at the milestone,
    // and that is the part a later run - or another firmware - can reuse.
    const spent = roundLog.filter(r => r.goal === goal)
    const last = spent[spent.length - 1]
    const tried = spent.length
      ? spent.map(r => `${r.category ?? '?'}→${r.change_key ?? '-'}`).join(' · ')
      : '변경 없이 도달 (이전 회차의 변경이 이 칸까지 열었습니다)'
    const rangeText = spent.length
      ? `${spent[0].round}-${spent[spent.length - 1].round}` : String(round)
    const fixText = last?.change_key
      ? `${last.change_key}${last.rationale ? ` — ${last.rationale}` : ''}`
      : '직전 회차까지의 변경이 누적되어 도달'

    await shell(`goal-${round}`, 'Loop',
      journalTryEnd(round, '목표 도달', `${obs?.milestone} 마일스톤을 펌웨어 출력에서 확인`,
                    '다음 목표로 진행', obs?.console ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, 'reached', null, null, 'progress', -1, false) + `\n` +
      (aliveNote
        ? `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('kernel_alive 판정 근거')} ` +
          `${shq(aliveNote)} ${shq(`회차 ${round}`)} || true\n`
        : '') +
      (clearedPassed.length
        ? `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
          `${shq(`회차 ${round}: 관측 없이 건너뛴 칸 ${clearedPassed.join(', ')} (더 높은 칸이 관측됨)`)} || true\n`
        : '') +
      `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" resolution ` +
      `${shq(goal)} ${shq(tried)} ${shq(fixText)} ${shq(obs?.console ?? '')} || true\n` +
      `bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" resolution ` +
      `stop=${shq(goal)} tried=${shq(tried)} fix=${shq(fixText)} ` +
      `rounds=${shq(rangeText)} evidence=${shq(obs?.console ?? '')} || true`,
      OK_SCHEMA)
    continue
  }

  if (route === 'verify' || route === 'next_goal') {
    // The supervisor claims the goal without an observed milestone to back it.
    log(`[루프] supervisor 가 목표 도달(${route})을 주장했지만 관측된 마일스톤이 ` +
        `"${obs?.milestone}" 이라 인정하지 않고 분류를 계속합니다.`)
  }

  // Escalation is asked once per round at most. The post-classification case below (a
  // hypothesis that needs deriving, not fixing) is skipped when this already ran.
  let escalatedThisRound = false
  if (route === 'static-analyzer' || obs?.escalate_to_analyst) {
    const { esc, measured } = await runEscalation(round, goal, obs, '', null)
    escalatedThisRound = true
    derived = measured
    derivedRows = (measured?.stop_points ?? derivedRows)
    derivedTable = renderDerived(derivedRows)
    analystNewFacts = measured?.new ?? 0
    log(`[루프] 도출 에스컬레이션 — 기록된 새 정지점 ${analystNewFacts} 개 ` +
        `(누적 ${measured?.total ?? 0}개)` +
        (esc?.new_facts_count > 0 && analystNewFacts === 0
          ? ' · 분석가는 새 사실을 주장했지만 표에 추가된 줄이 없어 0 으로 셉니다'
          : ''))
  }

  // Accumulated stop points for this firmware, whether or not we escalated this
  // round. This is the wiring that was missing: derivation used to end in a
  // counter, so the classifier saw identical input every round and answered
  // "unknown" every round.
  const cls = await agent(
    `Round ${round}, goal ${goal}, target ${target}.\n` +
    `Fingerprint: ${fingerprintText(obs)}\n` +
    `(full file: ${workdir}/fingerprint.json, provenance gate injected=${obs?.injected})\n` +
    `Originating exception block: ${obs?.origin_block}\n` +
    `Match on the ORIGIN. A storm's trailing FAR walks with every run and is not ` +
    `the stop point; naming it produces a category no fixer can act on.\n` +
    `Console: ${obs?.console}\nSummary: ${obs?.summary}\nFull trace if needed: ${obs?.trace}\n` +
    `Registry: ${abs('fixers/registry.yaml')} - only these fixers exist: ` +
    `${KNOWN_FIXERS.join(', ')}\n` +
    `Knowledge tables: ${KNOWLEDGE}. Do not match ` +
    `a class from a chain position this run has not reached yet; a stop point ` +
    `named ahead of where the run actually is is ` +
    `not this run's fault.\n` +
    familyContext() +
    channelStateText() +
    channelsText(obs, round) +
    (guestResetNoKernel
      ? `★ guest_reset_signal is true and kernel_alive was NOT reached: a reset or watchdog ` +
        `block was touched right after the kernel jump. Candidate stop point: ` +
        `guest_reset_after_jump - a HYPOTHESIS from the family table, no fixer owns it yet. ` +
        `Name it with low confidence if the rest of the observation fits, and say it is ` +
        `unconfirmed; do not rank a fixer for it.\n`
      : '') +
    (activeSurface === 'none'
      ? `Surface: none - this ladder has no surface rung (autoboot ${autobootState}). A stop ` +
        `at a console prompt is not a missing surface rung.\n`
      : '') +
    `Derived stop points for THIS firmware (accumulated in ${staticDoc}):\n` +
    `${derivedTable}\n` +
    `Match against these as well as the knowledge tables - they were derived from ` +
    `this exact target, so they outrank a generic signature.\n` +
    `Already attempted changes: read change_key values from ${workdir}/rounds.jsonl\n` +
    (sup?.suspect_prior_bypass || obs?.suspect_prior_bypass
      ? `The run is stalling. Before blaming anything new, suspect the side effects ` +
        `already recorded in 06_machine/bypasses.md.\n`
      : '') +
    `Name the stop point and rank the fixers that own it. ` +
    `"unknown" is a correct answer when nothing matches - do not force a fit.`,
    { agentType: 'fault-classifier', schema: CLASSIFIER_SCHEMA, label: `classify-${round}`, phase: 'Loop' }
  )

  const ranked = (cls?.fixer_ranking ?? [])
    .filter(f => KNOWN_FIXERS.includes(f?.fixer))
    .sort((a, b) => (a?.rank ?? 99) - (b?.rank ?? 99))

  // A hypothesis the family table says to DERIVE, not fix: the guest touched its reset
  // block right after the kernel jump. No fixer owns it, and a round with no change is a
  // round that learns nothing - so the analyst is asked to pin it down now, with the
  // table's own steps, and what it writes joins the derived rows the owner lookup below
  // reads. Once per round, and not when the escalation above already ran.
  if (cls?.category === 'guest_reset_after_jump' && ranked.length === 0 && !escalatedThisRound) {
    log(`[루프] 회차 ${round}: 분류 guest_reset_after_jump (가설) — 담당 fixer 가 없어 도출을 요청합니다.`)
    const { esc, measured } = await runEscalation(round, goal, obs, '-reset',
      'the classifier named guest_reset_after_jump, a hypothesis in the family table (see ' +
      '"Family knowledge"). Do NOT fix it and do not name a cause in advance: follow the ' +
      "row's own steps - when the reset/watchdog access appears after the jump, the guest PC " +
      'that performs it (a narrow trace), and the call path of that function. If no access ' +
      'appears after the jump, drop the hypothesis and say so. Write a derived-stop-point row ' +
      'only once a mechanism is established.')
    escalatedThisRound = true
    derived = measured
    derivedRows = (measured?.stop_points ?? derivedRows)
    derivedTable = renderDerived(derivedRows)
    analystNewFacts = measured?.new ?? 0
    log(`[루프] 도출 에스컬레이션(guest_reset_after_jump) — 기록된 새 정지점 ${analystNewFacts} 개 ` +
        `(누적 ${measured?.total ?? 0}개)` +
        (esc?.new_facts_count > 0 && analystNewFacts === 0
          ? ' · 분석가는 새 사실을 주장했지만 표에 추가된 줄이 없어 0 으로 셉니다' : ''))
  }

  // A stop point the analyst already derived for this firmware names its own
  // owner, so an unrecognised category is not automatically a dead end.
  const derivedOwner = derivedRows
    .map(r => r.fixer)
    .find(f => KNOWN_FIXERS.includes(f))

  if (ranked.length === 0 && !derivedOwner) {
    // Nobody to ask. Record that honestly - and do NOT claim the fixers are out
    // of moves, because none of them was asked. fixer_no_new_change is an input
    // to the exhaustion condition; asserting it here would let a round where no
    // fixer ran count as a round where every fixer gave up.
    log(`[루프] 회차 ${round}: 분류 불가(unknown)이고 도출된 담당도 없습니다 — 재도출로 넘깁니다.`)
    await shell(`unknown-${round}`, 'Loop',
      journalTryEnd(round, 'unknown',
                    cls?.novelty?.why ?? '기존 분류와 시그니처가 맞지 않음',
                    'static-analyzer 재도출로 이관', obs?.summary ?? '') + `\n` +
      recordRoundCmd(round, goal, obs, cls?.category ?? 'unknown', null, null,
                     'stall', analystNewFacts, false),
      OK_SCHEMA)
    continue
  }

  // Prefer the classifier's ranking; fall back to the owner named in the derived
  // table. An unknown category with a derived owner still gets a real attempt -
  // the fixer can answer not_mine, and that answer is a fact we can record,
  // unlike a round where nobody was asked at all.
  // The supervisor prescribes first: it read the machine sources and the derived
  // facts this round, which the classifier does not do. Its pick only counts if
  // the fixer exists.
  const prescribed = KNOWN_FIXERS.includes(sup?.prescribed_fixer)
    ? sup.prescribed_fixer : null

  // Naming a stop point is a claim that can be wrong, and the next round is the
  // test: apply the owner's treatment and see whether the fingerprint moves.
  // Recorded before the attempt so a claim that turns out wrong still leaves a
  // trace - what was ruled out is as much a result as what worked.
  await shell(`hypothesis-${round}`, 'Loop',
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" hypothesis ` +
    `${shq(`회차 ${round}: 정지점은 "${cls?.category ?? 'unknown'}" 이다` +
           (cls?.why ? ` — ${cls.why}` : ''))} ` +
    `${shq(`${prescribed ?? ranked[0]?.fixer ?? derivedOwner ?? 'fixer 미정'} 의 처방을 ` +
           `적용한 뒤 다음 회차 지문이 움직이는지로 판정`)} || true`,
    OK_SCHEMA)

  // The whole candidate list, in order of authority: the supervisor's
  // prescription (it read the sources and the derived facts this round), then
  // the classifier's ranking, then the owner named in the derived table.
  // Only rank 1 used to be asked, so a ranking of three was decoration and one
  // decline ended the round. Ranks 2 and 3 exist precisely because the first
  // guess about ownership can be wrong.
  const candidates = []
  const addCandidate = f => {
    if (f && KNOWN_FIXERS.includes(f) && !candidates.includes(f)) candidates.push(f)
  }
  addCandidate(prescribed)
  ranked.forEach(r => addCandidate(r?.fixer))
  addCandidate(derivedOwner)

  if (prescribed) {
    log(`[루프] 회차 ${round}: supervisor 처방 — ${prescribed}`)
  } else if (!ranked.length) {
    log(`[루프] 회차 ${round}: 분류는 unknown 이지만 도출표가 ${candidates[0]} 를 담당으로 지목 — 넘깁니다.`)
  }

  let fix = null
  let chosen = candidates[0]
  const declined = []
  for (const candidate of candidates.slice(0, 3)) {
    chosen = candidate
    const attempt = await agent(
      `Round ${round}, goal ${goal}.\n` +
      fixerContext(round, obs, cls, derivedTable, sup?.suspect_prior_bypass) +
      `If one of these matches the fingerprint, apply its "시도할 변경" - it was ` +
      `derived from this exact target with evidence attached.\n` +
      (declined.length
        ? `Already declined this round: ${declined.join('; ')}. You are next in the ` +
          `ranking, so read the mechanism yourself before assuming it is not yours.\n`
        : '') +
      (sup?.treatment_plan
        ? `Supervisor's treatment plan: ${sup.treatment_plan}\n` +
          `That is a direction, not a patch. If it does not hold up against what you ` +
          `read, say so - you own this change, and you are the one who answers ` +
          `no_new_change.\n`
        : '') +
      `\nMake your one change now, or decline: not_mine=true when this is not your area (do not ` +
      `force a fix), no_new_change=true when you have no untried change left.\n` +
      `Answer with fixer, change (type, target, description; encoding and pre_image only for a ` +
      `byte patch, otherwise null), change_key, rationale and one_line_progress. Set not_mine or ` +
      `no_new_change only to decline.\n` + DOC_STYLE +
      FIXER_RULES,
      { agentType: candidate, schema: FIXER_SCHEMA, label: `${candidate}-${round}`, phase: 'Loop' }
    )
    if (attempt && !attempt.not_mine && !attempt.no_new_change && attempt.change) {
      fix = attempt
      break
    }
    declined.push(`${candidate}(not_mine=${attempt?.not_mine === true}, ` +
                  `no_new_change=${attempt?.no_new_change === true})`)
    noteDecline(round, candidate, attempt)
    log(`[루프] 회차 ${round}: ${candidate} 반려 ` +
        `(담당아님=${attempt?.not_mine === true}, 새 시도 없음=${attempt?.no_new_change === true})`)
  }

  if (!fix) {
    // Every ranked specialist declined, so the fault has no owner among the
    // domains. The general fixer takes it instead: it has no domain boundary and
    // may edit, build and run, so a mechanism that crosses what the domains
    // split apart can be treated in one round.
    //
    // It is reached only here, never by ranking, so the widest scope stays the
    // exception rather than the default.
    const gen = await runGeneralFixer(round, goal,
      `Every ranked specialist declined this stop point (${declined.join('; ')}), ` +
      `so it has no owner among the specialists.`,
      sup?.treatment_plan, obs, cls, derivedTable, sup?.suspect_prior_bypass)
    if (await settleGeneral(gen, round, goal, obs, cls?.category ?? 'unknown', {
          declineLabel: 'decline',
          declineNote: `전문가 전원 반려(${declined.join('; ')}) 후 fixer-general 도 시도할 변경 없음`,
          newFacts: analystNewFacts }) === 'break') break
    continue
  }

  // The gate, the tree, the record - the same step the last-resort fixer's change goes through.
  if (await applyChange({
        round, goal, obs, category: cls?.category, fixer: chosen, changeKey: fix?.change_key,
        rationale: fix?.rationale, progress: fix?.one_line_progress ?? '',
        cause: fix?.rationale ?? '', fixText: fix?.change?.description ?? '',
        newFacts: analystNewFacts }) === 'break') break
}

const reachedAll = goalIndex >= goals.length
// Only what the run observed. `goalIndex` says how far the loop ADVANCED, which can be past
// a rung nobody saw; reporting everything below it as reached is what this replaces.
const reachedGoals = () => goals.filter(g => observedRungs.has(g))
const observedCount = () => reachedGoals().length

/* The verification bypasses the ledger already holds, counted by the F mark: one per ledger
 * entry whose "메타" line lists 표지 F (bypass-policy section 3: a change to the verification
 * path). That is verify_gates.bypass_report's ledger rule for the mark - the Verify phase
 * adds what only a console can show (forged and modified media, the firmware's own status
 * lines, a corrupted image that was not rejected) and the words-in-the-row heuristic for
 * legacy ledgers without a mark, so this is a floor, never more than the final count.
 * A stop cannot wait for that phase: the ledger is written by the fixers DURING the loop,
 * so by the time the run stops it knows whether the verify_ok it observed stands on one.
 * Fenced blocks are skipped and a heading starts an entry, as in verify_gates.parse_ledger;
 * tests/pipeline_sim/scenarios_flow.js (block Q) compares the two on the same ledgers. */
function ledgerBypassCmd() {
  return inBash(
    `LEDGER=${shq(`${workdir}/06_machine/bypasses.md`)}\n` +
    `if [ ! -f "$LEDGER" ]; then echo "ledger=absent"; echo "f_rows=0"; exit 0; fi\n` +
    `echo "ledger=present"\n` +
    `awk '\n` +
    `/^[[:space:]]*[\`][\`][\`]/ { fence = !fence; next }\n` +
    `fence { next }\n` +
    `/^[[:space:]]*#+[[:space:]]/ { flagged = 0; next }\n` +
    `/^[[:space:]>*+-]*메타[[:space:]]*[*]*[[:space:]]*(:|：)/ {\n` +
    `  if (flagged || !match($0, /표지[[:space:]]*=[[:space:]]*[A-Za-z, ]*/)) next\n` +
    `  marks = substr($0, RSTART, RLENGTH); sub(/^표지[[:space:]]*=[[:space:]]*/, "", marks)\n` +
    `  if (marks ~ /(^|,)[[:space:]]*F[[:space:]]*(,|$)/) { flagged = 1; rows++ }\n` +
    `}\n` +
    `END { print "f_rows=" rows + 0 }\n` +
    `' "$LEDGER"\n` +
    `# Report f_rows from the f_rows= line and ledger from the ledger= line.`)
}

/* The verification-bypass state a stop reports: the count behind a verify_ok the run
 * observed, or "not assessed" when the ledger could not be read - which is never the same
 * as zero. Nothing is asked when verify_ok was not observed: there is nothing for a bypass
 * to qualify. */
async function stopBypassState() {
  if (!observedRungs.has('verify_ok')) return { count: 0, assessed: true, basis: 'verify_ok 를 관측하지 못함' }
  const r = await shell('stop-bypass-count', 'Loop', ledgerBypassCmd(), LEDGER_BYPASS_SCHEMA)
  const n = Number(r?.f_rows)
  if (!r || !Number.isInteger(n) || n < 0) {
    log('[정지] ⚠ 우회 장부를 읽지 못해 verify_ok 에 검증 우회가 걸려 있는지 판정하지 못했습니다 — ' +
        "rung_states 의 'reached' 는 우회가 없다는 뜻이 아닙니다 (검증 단계를 거치지 않았습니다).")
    return { count: null, assessed: false, basis: '우회 장부를 읽지 못함' }
  }
  const basis = r.ledger === 'absent' ? '우회 장부 없음' : '장부 표지 F 행 (정지 시점의 하한 — 최종 건수는 검증 단계가 정함)'
  if (n > 0) {
    log(`[정지] verify_ok 는 관측됐으나 장부에 검증 우회(표지 F) ${n}건이 있어 reached_bypassed 로 보고합니다.`)
  }
  return { count: n, assessed: true, basis }
}

if (round - roundBase >= ROUND_CAP && !reachedAll && !stopped) {
  log(`[루프] 런타임 회차 한계 ${ROUND_CAP} 에 도달했습니다 (이번 실행의 회차 ${roundBase + 1}-${round}). 목표 도달 불가 판정이 아니라 ` +
      `런타임 한계이며, 같은 명령을 다시 실행하면 이어서 진행됩니다.`)
}

// --- structurally unreachable: honest incomplete result -----------------------
if (stopped) {
  const summary = await shell('stop-report', 'Loop',
    `bash "${PLUGIN}/scripts/py.sh" stop_conditions.py "${workdir}" --ladder "${ladderArg}"\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
    `${shq(`정지: ${stopReason} — 구조상 목표 도달 불가. 재개 가능합니다.`)}`,
    {
      type: 'object',
      properties: {
        best_milestone: { type: ['string', 'null'] },
        best_progress: { type: 'object' },
        tried_changes: { type: 'array' },
      },
    })
  // A one-rung ladder leaves best_milestone null even after the boot walked a
  // long way, so the depth measure is reported alongside it. Saying only "최고
  // 마일스톤: 없음" about a run that got the firmware through PMIC and into
  // storage init is accurate and still misleading.
  const depth = summary?.best_progress ?? {}
  log(`★ 정지 — ${stopReason}. 도달한 최고 마일스톤: ${summary?.best_milestone ?? '없음'}` +
      (depth?.uniq ? ` · 최고 부팅 깊이: 콘솔 고유 ${depth.uniq} 줄 (회차 ${depth.round ?? '-'})` : ''))

  // A stop is a handover. What makes it one is that the next session can see
  // where this got to, what was already tried and what is left - none of which
  // survives in a log the reader has to reconstruct by hand.
  await shell('write-resume', 'Loop',
    `bash "${PLUGIN}/scripts/py.sh" make_resume.py "${workdir}" ` +
    `--ladder ${shq(ladderArg)} ` +
    `--command ${shq(`/sboot-rehost:start ${target}`)} || true\n` +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
    `${shq(`정지(${stopReason}) — RESUME.md 생성. 재개 전에 "지문 이동=불변" 행을 먼저 보십시오.`)} || true`,
    OK_SCHEMA)
  // The verification-bypass count behind a verify_ok the run observed. The ledger is already
  // written (the fixers write it during the loop), so a stop can say "reached, behind a
  // bypass" - reporting a plain "reached" here is the over-claim reached_bypassed exists for.
  const stopBypass = await stopBypassState()
  await shell('session-close-stop', 'Loop',
    (stopBypass.count > 0
      ? `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
        `${shq(`정지(${stopReason}) 시점: verify_ok 관측, 장부의 검증 우회(표지 F) ${stopBypass.count}건 — reached_bypassed`)} || true\n`
      : '') +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" session-end ` +
    `${shq('/sboot-rehost:start')} ` +
    // Observed rungs, not the index the loop advanced to: it steps over a rung it never saw.
    `${shq(`정지 ${stopReason} · 도달 ${observedCount()}/${goals.length} · 회차 ${round}`)} || true`,
    OK_SCHEMA)
  log(`[정지] ${workdir}/RESUME.md 에 인계 내용을 적었습니다.`)

  return {
    success: false, stopped: true, stop_reason: stopReason,
    rounds_run: round, rounds_this_invocation: round - roundBase, round_start: roundBase + 1,
    goals, reached_goals: reachedGoals(),
    passed_over: goals.filter(g => passedOverRungs.has(g)),
    rung_states: rungStates(goals, observedRungs, stopBypass.count ?? 0), autoboot: autobootState,
    verify_bypass: stopBypass,
    milestone_token_problems: tokenProblems,
    kernel_alive_basis: kernelAliveBasis,
    best_milestone: summary?.best_milestone ?? null,
    best_progress: depth,
    tried_changes: summary?.tried_changes ?? [],
    resume_file: `${workdir}/RESUME.md`,
    note: '검증됨으로 표기하지 마세요. 정직한 미완이며 같은 명령으로 재실행하면 이어서 ' +
          `진행됩니다. 무엇을 시도했고 무엇이 남았는지는 ${workdir}/RESUME.md 에 있습니다.`,
  }
}

if (!reachedAll) {
  // The round cap is where a handover matters most: the run ended without
  // reaching the goal and with no stop reason to explain it, so without a resume
  // document the next session starts by reconstructing what already happened.
  const capBypass = await stopBypassState()
  await shell('resume-round-cap', 'Loop',
    `bash "${PLUGIN}/scripts/py.sh" make_resume.py "${workdir}" ` +
    `--ladder ${shq(ladderArg)} ` +
    `--command ${shq(`/sboot-rehost:start ${target}`)} || true\n` +
    (capBypass.count > 0
      ? `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" note ` +
        `${shq(`회차 한계 시점: verify_ok 관측, 장부의 검증 우회(표지 F) ${capBypass.count}건 — reached_bypassed`)} || true\n`
      : '') +
    `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" session-end ` +
    `${shq('/sboot-rehost:start')} ` +
    `${shq(`런타임 회차 한계(${ROUND_CAP}) · 도달 ${observedCount()}/${goals.length}`)} || true`,
    OK_SCHEMA)
  log(`[정지] 회차 한계 — ${workdir}/RESUME.md 에 인계 내용을 적었습니다.`)
  return {
    success: false, stopped: false, stop_reason: 'RUNTIME_ROUND_CAP',
    rounds_run: round, rounds_this_invocation: round - roundBase, round_start: roundBase + 1,
    goals, reached_goals: reachedGoals(),
    passed_over: goals.filter(g => passedOverRungs.has(g)),
    rung_states: rungStates(goals, observedRungs, capBypass.count ?? 0), autoboot: autobootState,
    verify_bypass: capBypass,
    milestone_token_problems: tokenProblems,
    kernel_alive_basis: kernelAliveBasis,
    resume_file: `${workdir}/RESUME.md`,
    note: `런타임 회차 한계(${ROUND_CAP})입니다. 목표 도달 불가 판정이 아니며 재실행하면 ` +
          `이어집니다. 무엇을 시도했는지는 ${workdir}/RESUME.md 에 있습니다.`,
  }
}

// =============================================================================
// Phase 4 - Verify
// =============================================================================
phase('Verify')

await shell('verify-phase', 'Verify',
  `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase "Verify" || true`, OK_SCHEMA)

// Verification is bound to ONE round: the one that cleared the last rung. verify.py reads
// that round's console, its kernel log (the memory-dump channel) and its trace. The trace
// is written outside the workspace (large writes go to the ext4 area) and verify.py no
// longer goes looking in the home folder - another run's trace is not evidence - so its
// path is handed over from the observation instead of being found.
const vRound = reachedRound || round
const vTrace = reachedObs?.trace ?? ''
const VERIFY_GATES = 3

// The comparison material the origin gates need: the gzip kernel and ramdisk unpacked,
// big files packed into pieces below the loader's size cap, and a normalised console
// (deletion and substitution only; the raw console is kept and is what gate 1 reads).
// A failure here costs coverage, not the run - gate 2 then compares against less - and
// is said so rather than passed over.
const prep = await shell('verify-prep', 'Verify',
  `bash "${PLUGIN}/scripts/py.sh" verify_prep.py "${workdir}" --round ${vRound} ` +
  `--flatten "${workdir}/02_unpacked" --label unpacked || true\n` +
  `# Report the "ok" field of the JSON it printed (false when it printed none).`,
  { type: 'object', properties: { ok: { type: 'boolean' }, notes: { type: 'array' } }, required: ['ok'] })
if (!prep || prep.ok !== true) {
  log('[검증] ⚠ verify_prep.py 가 비교 자료를 모두 준비하지 못했습니다 — 게이트 2 는 준비된 범위에서만 ' +
      '비교합니다. 이것은 통과가 아니라 비교 범위의 축소입니다.')
}

/* Stage 1 - the script measurement, as one command. Every input is bound explicitly:
 * the round, the trace, the memory-dump log, the stage map, the bypass ledger, the
 * negative-test console and the token that means verified boot passed. Flags verify.py
 * reads and that carry a value this run does not have (no kernel image unpacked, no
 * memory-dump log, no input surface) are left out rather than passed empty. */
function verifyCommand() {
  const surfaceArgs = activeSurface === 'none'
    ? ''
    // The command the harness types. The input item fails if the machine sources contain
    // it, on either surface: a machine that supplies its own input is verifying itself.
    : `set -- "$@" --surface ${activeSurface} ` +
      `--input-token ${shq(activeSurface === 'fastboot' ? 'getvar:' : 'help')}\n`
  return inBash(
    `WD=${shq(workdir)}\n` +
    `set -- "$WD" --target ${target} --container ${shq(bootloader_path)} --round ${vRound} \\\n` +
    `  --shape-budget 120 --stage-map "$WD/stage_map.json" \\\n` +
    `  --bypass-ledger "$WD/06_machine/bypasses.md" \\\n` +
    `  --negative-console "$WD/07_logs/avb_negative.txt"\n` +
    `TRACE=${shq(vTrace)}\n` +
    `if [ -n "$TRACE" ]; then set -- "$@" --trace "$TRACE"; fi\n` +
    `if [ -s "$WD/07_logs/kernel_${vRound}.log" ]; then set -- "$@" --memdump-log "$WD/07_logs/kernel_${vRound}.log"; fi\n` +
    `if [ -f "$WD/verify_ref/kernel_Image.img" ]; then set -- "$@" --kernel "$WD/verify_ref/kernel_Image.img"; fi\n` +
    `VOK=$(awk -F'\\t' '{ gsub(/\\r/, "") } $1=="verify_ok" { print $2; exit }' "$WD/milestone_tokens.txt" 2>/dev/null)\n` +
    `if [ -n "$VOK" ]; then set -- "$@" --verify-ok-token "$VOK"; fi\n` +
    surfaceArgs +
    `bash "${PLUGIN}/scripts/py.sh" verify.py "$@"\n` +
    `# Report verdict, verdict_label, gates_passed, gates_total, verify_bypass and address_windows from the JSON.`)
}

/* verify.py's verify_bypass.hash_engine, kept only when a ledger entry leans on it. It answers one
 * question - does STATIC.md carry the `hash_engine` row the hardware-hash exception hangs on - and
 * adds nothing to the count. `needed_by` are the labelled hash / digest / signature entries,
 * `unbacked` the ones among them with no hardware row. null when nothing leans on the row (a run
 * without such an entry has nothing to report), or when the measurement carried no such object. */
function hashEngineSummary(vb) {
  const he = vb && typeof vb === 'object' ? vb.hash_engine : null
  if (!he || typeof he !== 'object') return null
  const idOf = n => String(n && typeof n === 'object' ? (n.id ?? n.heading ?? '?') : n)
  const needed = (Array.isArray(he.needed_by) ? he.needed_by : []).map(idOf)
  const unbacked = (Array.isArray(he.unbacked) ? he.unbacked : []).map(idOf)
  if (!needed.length && !unbacked.length) return null
  return { row: he.row === true, status: he.status ?? null, value: he.value ?? null,
           line: he.line ?? null, needed_by: needed, unbacked }
}
const hashEngineText = h =>
  `hash_engine 행: ${h.row ? `있음 (${h.value ?? 'hardware'}, STATIC.md ${h.line ?? '?'}줄)` : `없음 (상태 ${h.status ?? '?'})`}` +
  ` · 이 행에 기대는 기록: ${h.needed_by.join(', ') || '없음'}` +
  ` · 근거 없는 기록: ${h.unbacked.join(', ') || '없음'}` +
  (h.unbacked.length ? ' — 전제 없이 쓰인 해시 우회입니다 (하드웨어 해시 경로가 정당하다고 서술하지 마십시오)' : '')

/* verify.py's address_windows (reference item 8): only a mixed-architecture machine is asked for the
 * STATIC.md table, so anything else is null here. A reference indicator, never a gate. */
function addressWindowsText(w) {
  if (!w || typeof w !== 'object' || w.applicable !== true) return null
  const missing = Array.isArray(w.missing_columns) && w.missing_columns.length
    ? ` · 빠진 열 ${w.missing_columns.join(', ')}` : ''
  return `주소 창 표 (혼합 아키텍처 머신, 참고): ${w.status ?? '?'} · 창 ${w.windows ?? '?'}행 · ` +
         `보안 영향 칸이 빈 행 ${w.security_effect_empty ?? '?'}${missing}`
}

// A negative console from an EARLIER run belongs to an earlier machine and medium. Reading
// it now would present that run's answer as this one's, so it goes before anything is
// measured: the first measurement then says "unproven", which is what is true.
await shell('verify-clear-negative', 'Verify',
  `rm -f "${workdir}/07_logs/avb_negative.txt" || true`, OK_SCHEMA)

let stage1 = await shell('verify-stage1', 'Verify', verifyCommand(), VERIFY_SCHEMA)
if (!stage1) {
  log('[검증] ⚠ 1 단계(verify.py) 결과를 얻지 못했습니다 — verifier 가 직접 실행합니다.')
}

// The negative test (verification.md section 6, item 5). A verifier that is stubbed to
// answer "equal" to everything prints "verification succeeded" on an intact image too, so
// a pass proves nothing by itself. One more round on a copy of the medium with ONE bit
// flipped inside the signed metadata: the firmware's own verification either says no, or
// it never decided anything. verify.py compares that console against the intact one.
//
// When: after a passing stage 1 (an unverified console needs no second opinion), and only
// when the target includes the verification rung (F2 and above). Never on the original
// medium - make_negative_image.py copies it. The cost is real and is reported: one more
// round of up to RUN_TIMEOUT seconds plus a copy of the whole medium (multi-GB on a phone
// image), and verify.py is run a second time. `negative_test: false` switches it off, and
// the verdict then says the firmware's own verification is UNPROVEN - it does not say it
// passed.
const NEG_RUN = NEGATIVE_RUN_BASE + vRound
let negative = { performed: false, reason: !NEGATIVE_TEST
  ? 'negative_test=false 로 꺼져 있습니다'
  : target === 'F1' ? '목표 F1 에는 검증 칸(verify_ok)이 없습니다'
  : !stage1 ? '1 단계(verify.py) 결과를 얻지 못해 음성 시험을 하지 않았습니다'
  : '1 단계 판정이 VERIFIED 가 아니어서 음성 시험을 하지 않았습니다' }
if (NEGATIVE_TEST && target !== 'F1' && stage1?.verdict === 'VERIFIED') {
  log(`[검증] 음성 시험 — 매체 사본의 1 비트를 훼손해 회차를 한 번 더 돌립니다 ` +
      `(최대 ${RUN_TIMEOUT}초 + 매체 복사; 원본 fw/lu0.img 는 건드리지 않습니다).`)
  const neg = await shell('verify-negative-round', 'Verify', inBash(
    `WD=${shq(workdir)}\n` +
    `N=${NEG_RUN}\n` +
    `bash "${PLUGIN}/scripts/py.sh" make_negative_image.py "$WD" > "$WD/.negative_image.json"; MK=$?\n` +
    `cat "$WD/.negative_image.json"; rm -f "$WD/.negative_image.json"\n` +
    `if [ $MK -ne 0 ]; then echo "negative_round=skipped make_negative_image.py exit=$MK"; exit 0; fi\n` +
    `# run_full.sh overwrites these at the workspace root: put them back afterwards, so the\n` +
    `# damaged-medium run never reads as the last real round.\n` +
    `for f in fingerprint.json fingerprint.prev.json input_summary.json; do\n` +
    `  [ -f "$WD/$f" ] && cp "$WD/$f" "$WD/$f.pre_negative"\n` +
    `done\n` +
    `MEDIUM="$WD/fw/lu0_negative.img" TIMEOUT=${RUN_TIMEOUT} TIMEOUT_PROBE=0 \\\n` +
    `  bash "${PLUGIN}/scripts/run_full.sh" "$WD" ${machine} ${shq(bootloader_path)} help $N ` +
    `${shq(activeSurface)} ${shq(ladderArg)} >/dev/null 2>"$WD/07_logs/qemu_negative.stderr.txt"; RC=$?\n` +
    `# The guest console of that round: the UART plus the kernel log, as everywhere else.\n` +
    `# Saved as avb_negative.txt and NOT as console_$N.txt - the verifier would take that for\n` +
    `# the latest round.\n` +
    `# kernel_N.log holds "<kernel_seconds> <text>" lines and only the text is the guest's: the\n` +
    `# intact round is judged with that prefix taken off (verify_gates.read_guest_console), so it\n` +
    `# comes off here too. Left on, one and the same line is a different shape in the two runs and\n` +
    `# every failure line the intact run printed as well reads as NEW - a corrupted image the\n` +
    `# firmware never rejected would be reported as rejected. (The sed is that function's _KLINE.)\n` +
    `# A UART console with no final newline would otherwise swallow the first kernel line.\n` +
    `{ cat "$WD/07_logs/console_$N.txt" 2>/dev/null\n` +
    `  [ -n "$(tail -c 1 "$WD/07_logs/console_$N.txt" 2>/dev/null)" ] && echo\n` +
    `  LC_ALL=C sed -E 's/^[[:space:]]*[0-9]+(\\.[0-9]+)?[[:space:]]//' "$WD/07_logs/kernel_$N.log" 2>/dev/null; } ` +
    `> "$WD/07_logs/avb_negative.txt"\n` +
    `for f in fingerprint.json fingerprint.prev.json input_summary.json; do\n` +
    `  if [ -f "$WD/$f.pre_negative" ]; then mv "$WD/$f.pre_negative" "$WD/$f"; else rm -f "$WD/$f"; fi\n` +
    `done\n` +
    `rm -f "$WD"/07_logs/*_$N.*\n` +
    `rm -f "\${TRACE_DIR:-$HOME/rehost/_traces}/run_$N.log"; rm -rf "\${TRACE_DIR:-$HOME/rehost/_traces}/memdump_$N"\n` +
    `echo "negative_round=done exit=$RC console_bytes=$(wc -c < "$WD/07_logs/avb_negative.txt" | tr -d ' ')"\n` +
    `# Report performed=true for negative_round=done, run_exit and console_bytes from that\n` +
    `# line, and skipped_reason for negative_round=skipped.`),
    { type: 'object',
      properties: {
        performed: { type: 'boolean' }, run_exit: { type: ['integer', 'null'] },
        console_bytes: { type: ['integer', 'null'] }, skipped_reason: { type: ['string', 'null'] },
      },
      required: ['performed'] })
  // An empty console proves nothing: the round may not have reached the verifier at all.
  negative = neg?.performed === true && Number(neg?.console_bytes ?? 0) > 0
    ? { performed: true, run_exit: neg.run_exit ?? null, console_bytes: neg.console_bytes }
    : { performed: false,
        reason: neg?.performed === true
          ? '훼손한 매체의 회차가 콘솔을 내지 못했습니다 (검증 단계까지 가지 못함)'
          : (neg?.skipped_reason || '훼손 이미지를 만들지 못했습니다') }
  if (negative.performed) {
    // The first measurement could not know this: measure again so the report carries it.
    stage1 = await shell('verify-stage1-final', 'Verify', verifyCommand(), VERIFY_SCHEMA) ?? stage1
  }
}
if (!negative.performed) {
  log(`[검증] 음성 시험 미실시 — ${negative.reason}. 펌웨어 자신의 검증이 실제로 도는지는 ` +
      `증명되지 않았습니다 (통과했다는 뜻이 아닙니다).`)
}
await shell('verify-negative-record', 'Verify',
  `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" decision ${shq('음성 시험')} ` +
  `${shq(negative.performed ? `실시 (회차 번호 ${NEG_RUN}, 콘솔 ${negative.console_bytes} 바이트)` : '미실시')} ` +
  `${shq(negative.performed
          ? `검증 후단에서 매체 사본 1 비트를 훼손해 한 번 더 실행 — 비용: 회차 1회 + 매체 복사 + verify.py 재측정`
          : negative.reason)} || true`,
  OK_SCHEMA)

// What the script itself measured about the hardware-hash precondition, handed to the verifier
// so it reports on the same row (null when no ledger entry leans on one).
const hashEngineMeasured = hashEngineSummary(stage1?.verify_bypass)

const verifier = await agent(
  `This is stage 2 of the origin verification (3 gates).\n\n` +
  `1. Stage 1 (the script measurement) was already run by the pipeline` +
  `${negative.performed ? ', a second time after the negative round' : ''}; ` +
  `${workdir}/verdict_script.json is current` +
  `${stage1 ? ` (script verdict ${stage1.verdict}, gates ${stage1.gates_passed ?? '?'}/${stage1.gates_total ?? VERIFY_GATES}` +
             `, verify_bypass.count ${stage1.verify_bypass?.count ?? '?'})` : ''}.\n` +
  `   ${stage1 ? 'Read it; re-run the command below only if it looks stale.'
                : 'The pipeline could NOT obtain it - run the command below yourself first.'}\n` +
  `\`\`\`bash\n${verifyCommand()}\n\`\`\`\n` +
  `   It writes ${workdir}/verdict_script.json. The comparison material (verify_ref/, the\n` +
  `   normalised console) was prepared by scripts/verify_prep.py${prep?.ok === true ? '' : ' - which reported a problem: read its output'}.\n` +
  `   The round measured is ${vRound}: console_${vRound}.txt, kernel_${vRound}.log (the memory-dump\n` +
  `   channel, when the run had one) and the trace ${vTrace || '(none recorded)'}.\n` +
  `   For the chain-trace item the script reads the stage entry PCs from stage_map.json (v2\n` +
  `   entry_pc); if it reports it could not find them, that item is not measured: say so in\n` +
  `   VERIFICATION.md.\n\n` +
  `2. Re-verify that measurement against the raw logs and bytes.\n` +
  `   - Lowering the verdict (VERIFIED -> UNVERIFIED) is always yours to make. When in doubt, lower it.\n` +
  `   - Raising it (UNVERIFIED -> VERIFIED) is only valid with byte-level evidence. Without ` +
  `     that evidence the script verdict stands and your override is void.\n` +
  `   - The negative test: ${negative.performed
      ? `performed (07_logs/avb_negative.txt, ${negative.console_bytes} bytes). Read what the corrupted run printed that the intact one did not.`
      : `NOT performed - ${negative.reason}. Say the firmware's own verification is UNPROVEN; never describe it as passed.`}\n\n` +
  `3. Write ${workdir}/VERIFICATION.md - the user reads it. ` +
  `   Show both the script verdict and yours, and when they differ say which won and why.\n` +
  `   Put the verification-bypass count (verify_bypass.count, plus any bypass you found that the\n` +
  `   script did not flag) in the FIRST lines, with the label\n` +
  `   "VERIFIED (출처 검증 통과) · 검증 우회 N건 · verify_ok: reached_bypassed" when it is above\n` +
  `   zero. Report the same count as verify_bypass {count, unproven} in your answer.\n` +
  `   When a ledger entry changes a hash, digest or signature comparison, say whether STATIC.md carries\n` +
  `   the \`hash_engine\` row it leans on (verdict_script.json verify_bypass.hash_engine: row, line, evidence,\n` +
  `   needed_by, unbacked - rule 5 of agents/verifier.md) and report it as verify_bypass.hash_engine {row,\n` +
  `   unbacked} in your answer. The row is a necessary condition, not a proof.\n` +
  `${hashEngineMeasured ? `   The script measured: ${hashEngineText(hashEngineMeasured)}.\n` : ''}` +
  `${mixedChain ? `   This machine is mixed-architecture: also give the address-window table in one line ` +
    `(verdict_script.json address_windows: status, windows, security_effect_empty) - a reference item, not a gate` +
    `${addressWindowsText(stage1?.address_windows) ? `; the script measured: ${addressWindowsText(stage1.address_windows)}` : ''}.\n` : ''}` +
  `\n` +
  `4. Finally record:\n` +
  `   bash "${PLUGIN}/scripts/py.sh" record.py "${workdir}" metric phase=Verify ` +
  `event=verify_end tokens_total=${budget.spent()}` +
  DOC_STYLE,
  { agentType: 'verifier', schema: VERIFIER_SCHEMA, label: 'verify', phase: 'Verify' }
)

const passes = verifier?.final_passes ?? 0
// The verification has three gates. Written once so the log, the README and the
// session record cannot drift apart from each other.
const verdict = verifier?.final_verdict ?? 'UNVERIFIED'
// How many verification bypasses stand behind a `verify_ok`. The script's count is the
// floor; the verifier reads the sources and may find one the script could not flag, and
// a bypass someone found is not unfound because a script missed it.
const bypassCount = Math.max(Number(stage1?.verify_bypass?.count ?? 0),
                             Number(verifier?.verify_bypass?.count ?? 0))
const unproven = verifier?.verify_bypass?.unproven ?? stage1?.verify_bypass?.unproven ?? !negative.performed
const finalStates = rungStates(goals, observedRungs, bypassCount)
const grade = gradeText(target, goals, bypassCount)
log(`[검증] 스크립트 ${verifier?.script_passes ?? stage1?.gates_passed ?? '?'}/${VERIFY_GATES} → ` +
    `최종 ${passes}/${VERIFY_GATES} (${verdict}) · 검증 우회 ${bypassCount}건` +
    (unproven ? ' · 음성 시험 미실시 — 펌웨어의 검증은 증명되지 않음' : ''))
if (bypassCount > 0) {
  log(`[검증] ${stage1?.verdict_label ?? `${verdict} · 검증 우회 ${bypassCount}건 · verify_ok: reached_bypassed`}`)
}
// The hardware-hash precondition (CLAUDE.md section 11) and the address-window table, as verify.py
// measured them. Neither adds to the count and neither is a gate; they are said out loud so a
// labelled hash bypass without its STATIC.md row, or a mixed-arch machine whose window table was
// never written, cannot pass unnoticed. The pipeline reads the script's own JSON, not the verifier's account.
const hashEngine = hashEngineMeasured ?? hashEngineSummary(verifier?.verify_bypass)
if (hashEngine) log(`[검증] ${hashEngineText(hashEngine)}`)
const windowsLine = addressWindowsText(stage1?.address_windows)
if (windowsLine) log(`[검증] ${windowsLine}`)
log(`[검증] 등급 보고: ${grade}` +
    (finalStates.verify_ok === 'reached_bypassed'
      ? ' — verify_ok 는 도달했으나 검증이 우회된 상태입니다 (reached_bypassed)' : ''))

// =============================================================================
// Phase 5 - Package
// =============================================================================
phase('Package')

// The run analysis, before the kit is written. It is computed from the recorded
// measurements, so it is a script's job, not something to ask an agent to
// estimate: which stop point cost the most rounds, which changes moved nothing,
// and where the time went are all arithmetic on rounds.jsonl / metrics.jsonl.
const analysis = await shell('analyze-run', 'Package',
  `bash "${PLUGIN}/scripts/py.sh" analyze_run.py "${workdir}"\n` +
  `# Writes ${workdir}/ANALYSIS.md (for people) and analysis.json (numbers).\n` +
  `# Report the JSON it prints.`,
  {
    type: 'object',
    properties: {
      rounds: { type: 'integer' },
      series: { type: 'integer' },
      total_seconds: { type: 'integer' },
      total_tokens: { type: 'integer' },
      stall_stretches: { type: 'integer' },
      findings: { type: 'integer' },
    },
  })
log(`[분석] 회차 ${analysis?.rounds ?? '?'}건 · 정체 구간 ${analysis?.stall_stretches ?? '?'}개 · ` +
    `원인 항목 ${analysis?.findings ?? '?'}건 → ${workdir}/ANALYSIS.md`)

await agent(
  `Assemble the reproduction kit in ${workdir}/10_reproduce/.\n\n` +
  `Include:\n` +
  `- README.md (INPUT.md summary, build and run steps, grade "${grade}", verdict ${passes}/${VERIFY_GATES} ${verdict})\n` +
  `- bootloader/ (copy of ${bootloader_path} - the whole container, not a carve)\n` +
  `- fw/ (the synthesised boot medium lu0.img, plus Image.patched and *.dtb if staged;\n` +
  `  lu_manifest.json and fw/lu_provenance.json with it - they say which bytes are ours).\n` +
  `  NOT fw/lu0_negative.img: it is a multi-GB scratch copy made for the negative test.\n` +
  `- stage_map.json (which stages ran, which were skipped and why), memdump_plan.json when there is one\n` +
  `- machine/ (sources from 06_machine plus bypasses.md)\n` +
  `- scripts/ (setup_env.sh, build and run scripts, uart_harness.py, input_plan.json)\n` +
  `- evidence/ (latest console and summary, kernel_<N>.log when there is one, input log and\n` +
  `  input_summary.json, VERIFICATION.md, ANALYSIS.md, PROGRESS.md, JOURNAL.md,\n` +
  `  metrics.jsonl, rounds.jsonl, verdict_script.json, analysis.json,\n` +
  `  07_logs/avb_negative.txt when the negative test ran)\n\n` +
  `README.md must carry a "실행 비용과 소요" section built FROM ${workdir}/ANALYSIS.md -\n` +
  `not a re-estimate. Quote its figures and point to it for the detail:\n` +
  `  - total rounds (${analysis?.rounds ?? '?'}), total elapsed time, total tokens\n` +
  `  - the stop point that held longest, and its cost (ANALYSIS.md section 4)\n` +
  `  - the ${analysis?.stall_stretches ?? '?'} stall stretches and what ended each (section 5)\n` +
  `  - the changes that actually moved the boot forward (section 7)\n` +
  `Do not restate a number ANALYSIS.md does not contain, and do not soften one it does.\n` +
  `The section also states the cost of the verification itself: ${negative.performed
      ? `the negative test ran one extra round (round number ${NEG_RUN}, up to ${RUN_TIMEOUT}s) on a copy of the medium and verify.py was measured twice`
      : `the negative test did not run (${negative.reason})`}.\n\n` +
  `The grade is "${grade}" and it is stated exactly so. Reached rungs: ` +
  `${goals.filter(g => observedRungs.has(g)).join(', ') || '(none)'}` +
  `${goals.some(g => !observedRungs.has(g)) ? `; NOT observed: ${goals.filter(g => !observedRungs.has(g)).join(', ')}` : ''}. ` +
  `A rung the loop stepped over without observing it is not reached - list it as not reached.\n` +
  (kernelAliveBasis
    ? `kernel_alive rests on the ${kernelAliveBasis.channel ?? 'unrecorded'} channel and the kernel banner is ` +
      `${({ observed: 'OBSERVED', not_observed: 'NOT observed (an alternate line decided it)',
           unverified: 'NOT VERIFIED (a plain UART string match: no kernel time, task or banner check)',
           unknown: 'unrecorded (the observation carried no kernel_alive evidence)' })[kernelAliveBasis.banner] ?? kernelAliveBasis.banner} - say exactly that.\n`
    : '') +
  (bypassCount > 0
    ? `Verification was bypassed ${bypassCount} time(s): write the label ` +
      `"VERIFIED (출처 검증 통과) · 검증 우회 ${bypassCount}건 · verify_ok: reached_bypassed" ` +
      `(or UNVERIFIED if that is the verdict) near the top, never "F2 도달" alone.\n`
    : unproven
      ? `The negative test did not run: say the firmware's own verification is UNPROVEN - it is not the same as passed.\n`
      : '') +
  (verdict === 'VERIFIED'
    ? `The verdict is VERIFIED. State it as "출처 검증 통과" and nothing stronger — it does NOT mean the boot completed.\n`
    : `The verdict is UNVERIFIED. Do not write "검증됨" or "성공" anywhere in the README.\n`) +
  DOC_STYLE +
  `\nFinally: bash "${PLUGIN}/scripts/journal.sh" "${workdir}" phase "Package 완료"`,
  { label: 'package', phase: 'Package' }
)

// Close the session block. Without this every JOURNAL session stays open and the
// elapsed time is never computed, so a finished run reads like an abandoned one.
await shell('session-close', 'Package',
  `bash "${PLUGIN}/scripts/journal.sh" "${workdir}" session-end ` +
  `${shq('/sboot-rehost:start')} ` +
  `${shq(`${verdict} (${passes}/${VERIFY_GATES}) · ${grade} · 검증 우회 ${bypassCount}건 · ` +
         `도달 ${goals.filter(g => observedRungs.has(g)).length}/${goals.length} · 회차 ${round}`)} || true`,
  OK_SCHEMA)

return {
  success: verdict === 'VERIFIED',
  verdict,
  passes,
  target, grade, goals, stages: stagesNow,
  reached_goals: goals.filter(g => observedRungs.has(g)),
  passed_over: goals.filter(g => passedOverRungs.has(g)),
  rung_states: finalStates,
  autoboot: autobootState,
  kernel_alive_basis: kernelAliveBasis,
  verify_bypass: { count: bypassCount, unproven, hash_engine: hashEngine },
  milestone_token_problems: tokenProblems,
  negative_test: negative,
  rounds_run: round, rounds_this_invocation: round - roundBase, round_start: roundBase + 1,
  rounds_detail: roundLog,
  failed_items: verifier?.failed_items ?? [],
  override: verifier?.override ?? null,
  next_recommendation: verifier?.next_round_recommendation ?? null,
  reproduce_dir: `${workdir}/10_reproduce/`,
  records: {
    metrics: `${workdir}/metrics.jsonl`,
    rounds: `${workdir}/rounds.jsonl`,
    blockers: `${workdir}/blockers.jsonl`,
  },
  note: verdict === 'VERIFIED'
    ? (bypassCount > 0
        ? `출처 검증 통과이나 검증 우회 ${bypassCount}건이 있습니다 (verify_ok: reached_bypassed). ` +
          '도달 여부는 마일스톤으로 따로 봅니다.'
        : '출처 검증 통과입니다. 도달 여부는 마일스톤으로 따로 봅니다.') +
      (unproven ? ' 음성 시험을 하지 않아 펌웨어 자신의 검증이 동작했는지는 증명되지 않았습니다.' : '')
    : 'UNVERIFIED 입니다. 출처 검증에 미달했으므로 검증됨·성공으로 표기하지 마세요.',
}
