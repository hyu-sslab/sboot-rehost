// common.js - what the scenario files in this folder share: the pipeline compiled (with the mutation named by
// SBOOT_MUTATE applied), the scripted-agent responder, the observation builder and the small helpers.
// Not run by itself: scenarios_flow.js and scenarios_guide.js require it. tests/parts/pipeline_family.sh runs them.
const path = require('path')
const { load, run, realKit } = require('./harness.js')

const repo = process.argv[2]
const PJ = process.env.PIPELINE_JS || path.join(repo, 'workflows', 'pipeline.js')
const MUT = process.env.SBOOT_MUTATE || ''
// Each mutation breaks ONE promise of the pipeline; the scenarios below must notice.
const MUTATIONS = {
  'classifier-without-family-kit': [["familyContext() +\n    channelStateText() +\n    channelsText(obs, round) +\n    (guestResetNoKernel", "channelStateText() +\n    channelsText(obs, round) +\n    (guestResetNoKernel"]],
  'abort-round-counted-twice': [["    // No `round++` here:", "    round++\n    // No `round++` here:"]],
  'reached-goals-overreports': [["reached_goals: goals.filter(g => observedRungs.has(g)),\n  passed_over", "reached_goals: goals.slice(0, goalIndex),\n  passed_over"]],
  'surface-none-is-a-static-blocker': [["if (prior?.arch_supported === false) blockers.push(archBlocker())", "if (prior?.arch_supported === false) blockers.push(archBlocker())\nif (String(prior?.bl_surface ?? '').toLowerCase() === 'none') blockers.push(['BLOCKED_NO_INPUT_PATH', 'x'])"]],
  'arm32-alone-blocks': [["if (prior?.arch_supported === false) blockers.push(archBlocker())", "if (prior?.arch_supported === false || arch === 'arm32') blockers.push(archBlocker())"]],
  'negative-console-saved-as-a-round': [['> "$WD/07_logs/avb_negative.txt"', '> "$WD/07_logs/console_$N.txt"']],
  'script-bypass-count-ignored': [["Math.max(Number(stage1?.verify_bypass?.count ?? 0),", "Math.max(0 * Number(stage1?.verify_bypass?.count ?? 0),"]],
  'unprovable-tree-is-built-on': [["if (!treeReset || treeReset.exit_code !== 0) {", "if (false) {"]],
  'host-lines-read-as-bootloader': [src => { const i = src.indexOf('function derivePlanCmd'); const t = "guestLinesCmd('$CON', '$GUEST')"; const j = src.indexOf(t, i); return j < 0 ? src : src.slice(0, j) + "'cp \"$CON\" \"$GUEST\"; GRC=0\\n'" + src.slice(j + t.length) }],
  'kernel-metrics-always-recorded': [["...(fp?.kernel_uniq != null\n      ? [`fp_klast", "...(true\n      ? [`fp_klast"]],
  'negative-test-before-a-passing-stage-1': [["stage1?.verdict === 'VERIFIED') {\n  log(`[검증] 음성 시험", "true) {\n  log(`[검증] 음성 시험"]],
  'verify-trace-not-passed': [['if [ -n "$TRACE" ]; then set -- "$@" --trace "$TRACE"; fi', ':']],
  // fix stage: one promise each of the findings that were confirmed
  'uart-alive-reads-as-banner-observed': [["  if (ev.via === 'banner') return 'observed'\n  return 'unverified'", "  return 'observed'"]],
  'stop-reports-no-verification-bypass': [['rung_states: rungStates(goals, observedRungs, stopBypass.count ?? 0)', 'rung_states: rungStates(goals, observedRungs, 0)']],
  'round-cap-reports-no-verification-bypass': [['rung_states: rungStates(goals, observedRungs, capBypass.count ?? 0)', 'rung_states: rungStates(goals, observedRungs, 0)']],
  'stop-journal-counts-the-advanced-index': [['도달 ${observedCount()}/${goals.length} · 회차 ${round}', '도달 ${goalIndex}/${goals.length} · 회차 ${round}']],
  'kernel-log-path-not-given': [["if (kernelLog && (named('kernel_log') || memdumpPlanKnown || ch?.kernel_lines > 0)) {", "if (false) {"]],
  'guest-filter-reads-console-as-text': [['LC_ALL=C grep -a -v -E', 'grep -v -E']],
  'negative-console-keeps-kernel-timestamps': [src => src.replace(/LC_ALL=C sed -E '[^']*' "\$WD\/07_logs\/kernel_\$N\.log"/, 'cat "$WD/07_logs/kernel_$N.log"')],
  'token-names-never-checked': [["if (stageRungEntries.length) {\n  let tokenAnswer", "if (false) {\n  let tokenAnswer"]],
  // the guide pass: one promise each of P1-P9
  'family-lines-relative': [["familyKnowledge.map(abs).join(', ')", "familyKnowledge.join(', ')"]],
  'detected-arch-ignored': [["if (exitOk && ARCHES.includes(found)) {", "if (false) {"]],
  'unknown-arch-never-blocks': [["if (why) blockers.push(archBlocker(why))", "if (false) blockers.push(archBlocker(why))"]],
  'explicit-arch-derived-anyway': [["const archGiven = ARCHES.includes(archInput)", "const archGiven = false"]],
  'kernel-assets-never-staged': [["if (target !== 'F1') {\n  assetStaging = await shell(", "if (false) {\n  assetStaging = await shell("]],
  'staging-exit-4-reads-as-failure': [['4) STATE="partial";;', '4) STATE="failed";;']],
  'provisional-arch-kept-silently': [["if (archUnresolved) {\n  log(`[분석] 아키텍처는 detect-arch 가 도출하지 못했고", "if (false) {\n  log(`[분석] 아키텍처는 detect-arch 가 도출하지 못했고"]],
  'round-restarts-at-one': [["let round = roundBase ", "let round = 0 "]],
  'round-cap-counts-the-absolute-number': [["round - roundBase < ROUND_CAP) {", "round < ROUND_CAP) {"]],
  'round-base-ignores-the-logs': [['if [ -d "$WD/07_logs" ]; then', 'if false; then']],
  'round-base-counts-the-negative-range': [['LIM=${NEGATIVE_RUN_BASE}', 'LIM=99999']],
  'null-kernel-log-becomes-a-path': [["const kernelLog = reported('kernel_log') ?", "const kernelLog = false ?"]],
  'kernel-task-regex-by-environment': [["write ${workdir}/kernel_task_regex.txt: its first", "set the KERNEL_TASK_REGEX environment variable: its first"]],
  'owner-column-excludes-build': [["literal word build. build is", "literal word none. none is"]],
  'ko-without-an-emitter': [["if (target !== 'F1' && String(prior?.storage_driver?.form ?? '').toLowerCase() === 'absent') {", "if (false) {"]],
  'build-prompt-not-told-to-read': [["READ FIRST. Before you write", "NOTE. Before you write"]],
  'run-schema-lacks-the-log-fields': [["    kernel_log: { type: ['string', 'null'] },\n", ""]],
  'plugin-root-trailing-slash-kept': [["String(PLUGIN).replace(/\\/+$/, '')", "String(PLUGIN)"]],
  'registry-and-templates-relative': [src => src.split("abs('fixers/registry.yaml')").join("'fixers/registry.yaml'").split("abs('templates/machine_mixed_arch.c.tmpl')").join("'templates/machine_mixed_arch.c.tmpl'")],
  'blocked-asset-hides-the-staging': [["`적재 결과: ${assetStagingText(assetStaging)}. ` +\n", ""]],
  // the handoff pass: one promise each
  'later-images-share-one-arch': [["stage_map.py --detect-arch <that image>", "stage_map.py <that image>"]],
  'asset-exit-codes-unexplained': [["const assetExitText = code => (ASSET_EXIT_MEANING[Number(code)] ?", "const assetExitText = code => (false ?"]],
  'sparse-super-reads-as-ready': [["const sparse = /super=sparse\\b/.test(st.summary ?? '')", "const sparse = false"]],
  'memdump-plan-demands-the-ring': [["ONLY when region_base AND region_size are derived; otherwise write no file.", "ONLY when region_base, region_size AND console_size are all derived; otherwise write no file."]],
  'hash-engine-evidence-unspecified': [["whose evidence cell holds a 0x function address or SMC id of the digest path.", "whose evidence cell holds a description of the digest path."]],
  'cmdline-plan-without-partition': [['"partition": "<the partition the bootloader', '"x": "<the partition the bootloader']],
  'address-windows-never-requested': [["★ ADDRESS WINDOWS TABLE.", "★ NOTE."]],
  'hash-engine-silent-in-verify': [["if (hashEngine) log(`[검증] ${hashEngineText(hashEngine)}`)", "if (false) log(`[검증] ${hashEngineText(hashEngine)}`)"]],
  'hash-engine-unbacked-not-reported': [["  if (!needed.length && !unbacked.length) return null\n", "  return null\n"]],
  'address-windows-silent-in-verify': [["const windowsLine = addressWindowsText(stage1?.address_windows)", "const windowsLine = null"]],
  'verifier-not-told-the-hash-row': [["When a ledger entry changes a hash, digest or signature comparison, say whether STATIC.md carries", "NOTE: a ledger entry may change a comparison; say whether STATIC.md carries"]],
  'escalation-never-asks-for-the-digest-row': [["If the question is WHERE THE DIGEST IS COMPUTED", "If the question is something else"]],
  'task-regex-said-to-be-anchored': [["It is SEARCHED,", "It is MATCHED at the start,"]],
  'derived-arch-basis-not-asked-for-in-static': [["Write those basis lines into STATIC.md", "Those basis lines are for your information"]],
  'analyst-not-asked-for-the-storage-driver': [['Report storage_driver {form: "module"', 'Note storage_driver {form: "module"']],
  // the repair pass: the unknown-architecture probe, the whole-text records, the K4 floor
  'arch-probe-never-run': [["if (archUnresolved) {\n  const probeRaw = await shell('arch-probe'", "if (false) {\n  const probeRaw = await shell('arch-probe'"]],
  'arm64-exit-zero-is-a-signature': [["    : r64.stubs > 0 ? 'found' : 'none'", "    : 'found'"]],
  'probe-stub-count-never-read': [['END { if (seen) print n + 0; else print "-" }', 'END { print 0 }']],
  'probe-failure-reads-as-no-signature': [["  if (s32 === 'failed' || s64 === 'failed') return { outcome: 'unconfirmable', arch: null, say, states }\n", ""]],
  'both-signatures-pick-a-reading': [["  if (s32 === 'found' && s64 === 'found') return { outcome: 'both', arch: null, say, states }\n", ""]],
  'probe-always-answers-arm64': [["return { outcome: 'one', arch: s32 === 'found' ? 'arm32' : 'arm64', say, states }", "return { outcome: 'one', arch: 'arm64', say, states }"]],
  'blocker-text-capped-at-400': [['detail=${shqWhole(detail)}', 'detail=${shq(detail)}']],
  'arch-decision-text-capped-at-400': [["${shq('아키텍처')} ${shqWhole(what)} ${shqWhole(why)}", "${shq('아키텍처')} ${shq(what)} ${shq(why)}"]],
  'provisional-journal-hides-the-probe': [["`detect-arch 는 unknown 이었음. 확인한 것: ${(archProbe?.say ?? ['두 해석 비교 결과 없음']).join('; ')} ` +", "`detect-arch 는 unknown 이었음. 확인한 것: 없음 ` +"]],
  'absent-without-evidence-stops': [['if (ev && /\\d/.test(ev)) {', 'if (true) {']],
  'ko-search-not-medium-aware': [['Search for the drivers of THE MEDIUM THIS BOARD BOOTS FROM', 'Search for the drivers']],
  'later-image-trusts-the-arm64-exit-code': [['Under arm64 the tool NEVER', 'Under arm64 the tool rarely']],
  // the neutral pass (scenarios_neutral.js): one promise each of V1-V5. tests/parts/pipeline_family.sh lists these as NEUTRAL_MUTS.
  'build-lu-without-family': [["${mediumFlag} --family ${familyFlag()}\\n`", "${mediumFlag}\\n`"]],
  'carve-without-family': [['--arch ${arch} --family ${familyFlag()} to EVERY carve_disasm.py call', '--arch ${arch} to EVERY carve_disasm.py call']],
  'family-flag-passes-any-family': [["return SCRIPT_FAMILIES.includes(f) ? f : 'generic'", "return f || 'generic'"]],
  'carve-null-blocks': [["if (prior?.carve_is_full === false && !blockers.length) {", "if (prior && prior.carve_is_full !== true && !blockers.length) {"]],
  'carve-undetermined-silent': [["if (prior && typeof prior.carve_is_full !== 'boolean') {", "if (false) {"]],
  'carve-note-not-in-schema': [["    carve_note: { type: ['string', 'null'] },\n", ""]],
  'param-fallback-told-to-every-family': [["(familyFlag() === 'exynos'\n    ? `A plan that", "(true\n    ? `A plan that"]],
  'interrupt-default-promised': [['the harness then sends NO interrupt pattern at all (it has no', 'the harness then uses a documented default (it has no']],
  'storage-template-for-every-undecided-medium': [["(mediumUndecided && familyFlag() === 'exynos')", 'mediumUndecided']],
  'storage-template-for-emmc': [["const offerStorageHci = mediumKind === 'ufs' ||", 'const offerStorageHci = true ||']],
  'storage-template-ufs-needs-exynos': [["mediumKind === 'ufs' || (mediumUndecided", "(mediumKind === 'ufs' && familyFlag() === 'exynos') || (mediumUndecided"]],
  'general-fixer-bypasses-the-gate': [['`${gateScope}bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" verify; GATE=$?\\n` +', '(c.fixer === GENERAL_FIXER ? `GATE=0\\n` : `${gateScope}bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" verify; GATE=$?\\n`) +']],
  'general-fixer-gets-the-specialist-limits': [["const gateScope = c.fixer === GENERAL_FIXER ? 'CHANGE_SCOPE=general ' : ''", "const gateScope = ''"]],
  'specialist-gets-the-general-scope': [["const gateScope = c.fixer === GENERAL_FIXER ? 'CHANGE_SCOPE=general ' : ''", "const gateScope = 'CHANGE_SCOPE=general '"]],
  'rejected-change-not-rolled-back': [['`if [ $GATE -ne 0 ]; then bash "${PLUGIN}/scripts/check_change.sh" "${workdir}" restore; fi\\n` +', '`:\\n` +']],
  'rejected-change-recorded-as-applied': [["'reverted', c.newFacts, false, c.rationale", "'applied', c.newFacts, false, c.rationale"]],
  'general-build-claim-ignored': [['(c.builtOk === false && applied?.build_ok !== true)', 'false']],
  'general-build-claim-beats-measurement': [['(c.builtOk === false && applied?.build_ok !== true)', '(c.builtOk === false)']],
  'general-abort-decline-continues': [["if (o.stopOnDecline) { stopped = true; stopReason = 'BLOCKED_BUILD'; return 'break' }\n", '']],
  'general-context-forked': [["fixerContext(round, obs, cls, derivedTable, suspectPriorBypass) +\n    (plan ?", "`Classification: ${cls?.category ?? 'unknown'}\\n` +\n    (plan ?"]],
  'specialist-context-forked': [["fixerContext(round, obs, cls, derivedTable, sup?.suspect_prior_bypass) +\n      `If one of these", "`Classification: ${cls?.category}\\n` +\n      `If one of these"]],
  'fixer-schema-keeps-escalate': [["    one_line_progress: { type: 'string' },\n  },\n  required: ['fixer'],", "    one_line_progress: { type: 'string' },\n    escalate: { type: ['object', 'null'] },\n  },\n  required: ['fixer'],"]],
  'general-schema-keeps-bypass-doc': [["    build_error: { type: ['string', 'null'] },\n    candidate_doc:", "    build_error: { type: ['string', 'null'] },\n    bypass_doc: { type: 'boolean' },\n    candidate_doc:"]],
  // FIXER_RULES (V6): the one text every fixer prompt carries. Missing from a site, a rule weakened or cited instead of written out, a second copy
  'fixer-rules-missing-for-specialists': [['FIXER_RULES,\n      { agentType: candidate', "'',\n      { agentType: candidate"]],
  'fixer-rules-missing-for-general': [["`answer is what stands between an honest stop and an endless run.\\n` +\n    FIXER_RULES,", "`answer is what stands between an honest stop and an endless run.\\n`,"]],
  'fixer-rules-twice-in-the-specialist-prompt': [['FIXER_RULES,\n      { agentType: candidate', 'FIXER_RULES + FIXER_RULES,\n      { agentType: candidate']],
  'fixer-rules-open-question-gone': [['goes in "rationale", with no_new_change=true: state', 'goes in "rationale": state']],
  'fixer-rules-ledger-rule-weakened': [['is **not** caught for you: tag every row.', 'is **not** caught for you: tag what you like.']],
  'fixer-rules-family-paragraph-gone': [['**Read them before you act**: they hold', 'They hold']],
  'fixer-rules-allow-adaptive-toggles': [['**No speculative stubs, no adaptive toggles.**', '**Prefer constants.**']],
  'fixer-rules-cite-honesty-by-number': [['Model constants only.\\n', 'Model constants only (honesty rule 1).\\n']],
  'verifier-prompt-offers-dead-pc-option': [['re-run the command below only if it looks stale.', 'ONLY if you need explicit --pc values or it looks stale.']],
  'fixer-rules-machine-may-speak': [['**The machine never speaks for the firmware.**', '**The machine may help.**']],
  'declined-questions-dropped': [["  if (!why) return\n  openQuestions.push", "  return\n  openQuestions.push"]],
  'declined-questions-never-cleared': [['const lines = openQuestions.splice(0).map(', 'const lines = openQuestions.slice(0).map(']],
  'declined-questions-kept-forever': [['  if (openQuestions.length > 5) openQuestions.splice(0, openQuestions.length - 5)\n', '']],
  'escalation-focus-ignores-its-own': [["return (base ? `${base}\\n\\n` : '') +", "return '' +"]],
  'escalation-never-takes-the-questions': [['  focus = escalationFocus(focus)\n', '']],
}
const fn = load(PJ, MUTATIONS[MUT] || null)
if (MUT && !MUTATIONS[MUT]) { console.log('FAIL unknown mutation ' + MUT); process.exit(0) }
const out = []
const check = (what, ok, detail) => out.push((ok ? 'PASS ' : 'FAIL ') + what + (ok ? '' : ' :: ' + String(detail ?? '').replace(/\s*\n\s*/g, ' / ').slice(0, 300)))
const has = (s, t) => typeof s === 'string' && s.includes(t)


const fs = require('fs')
const os = require('os')
const { spawnSync } = require('child_process')
const TMPROOT = process.env.SBOOT_TEST_TMP || os.tmpdir()
const tmpdirs = []
const mktmp = name => { const d = fs.mkdtempSync(path.join(TMPROOT, name + '.')); tmpdirs.push(d); return d }
const W = (f, t) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, t) }
/* the command a shell() call asked an agent to run: the ```bash block of its prompt */
const cmdOf = call => { const a = call.prompt.indexOf('```bash\n') + 8, b = call.prompt.lastIndexOf('\n```'); return call.prompt.slice(a, b) }
const sh = (cmd, cwd, env) => spawnSync('bash', ['-c', cmd], { cwd, encoding: 'utf8', env: Object.assign({}, process.env, env || {}) })
/* every shell command the pipeline emitted must at least parse as bash - and so must the
 * script inside each heredoc the command wraps */
function bashSyntax(call) {
  const cmd = cmdOf(call)
  const errs = []
  let r = spawnSync('bash', ['-n'], { input: cmd, encoding: 'utf8' })
  if (r.status !== 0) errs.push(r.stderr)
  const m = /<<'SBOOT_SH'[^\n]*\n([\s\S]*)\nSBOOT_SH/.exec(cmd)
  if (m) { r = spawnSync('bash', ['-n'], { input: m[1], encoding: 'utf8' }); if (r.status !== 0) errs.push(r.stderr) }
  return errs.join('\n')
}
/* a plugin tree with the REAL py.sh / wsl_bridge.sh and stand-in scripts, so a command the
 * pipeline emitted can be executed for real without a QEMU */
function fakePlugin(extra) {
  const d = mktmp('plug')
  fs.mkdirSync(path.join(d, 'scripts'), { recursive: true })
  fs.mkdirSync(path.join(d, '.claude-plugin'), { recursive: true })
  for (const f of ['py.sh', 'wsl_bridge.sh']) fs.copyFileSync(path.join(repo, 'scripts', f), path.join(d, 'scripts', f))
  W(path.join(d, '.claude-plugin', 'plugin.json'), '{\n  "name": "x",\n  "version": "9.9.9"\n}\n')
  for (const [f, t] of Object.entries(extra || {})) { W(path.join(d, 'scripts', f), t); fs.chmodSync(path.join(d, 'scripts', f), 0o755) }
  return d
}

const KIT = realKit(repo, 'mediatek')
// the pipeline hands agents ABSOLUTE paths (the plugin root joined with family_kit.py's relative ones);
// BASE_ARGS names '/plug' as the plugin root
const plugAbs = p => '/plug/' + p
const FAM_LINE = 'Family knowledge: ' + (KIT.knowledge || []).map(plugAbs).join(', ')
const RB_LINE = 'Runbook: ' + (KIT.runbook ? plugAbs(KIT.runbook) : '(none)')
const COMMON = ['knowledge/faults_unified.md', 'knowledge/faults_storage.md', 'knowledge/kernel_gates.md']
const OK = { ok: true }
function mkObs(o = {}) {
  return Object.assign({
    run_ok: true, run_fault: false, milestone: 'none', milestones_reached: [], injected: false,
    exceptions: 0, console_bytes: 500, console_uniq: 10, origin_type: 'none', origin_esr: 'none',
    origin_far: 'none', origin_elr: 'none', origin_block: '', timeout_bound: false,
    input_starved: false, rx_reported: false, rx_served: null, rx_polls: null,
    storage_partition_table: 'unknown', console: '/c', summary: '/s', trace: '/trace/run.log',
    stop: false, stop_reason: null, stall_count: 0, escalate_to_analyst: false,
    suspect_prior_bypass: false, best_milestone: null, best_progress: {}, tried_changes: [],
    futile_changes: 0, needs_layer_review: false, channels: { uart_bytes: 500, kernel_lines: 0, host_lines: 0 },
    kernel_alive_evidence: null, guest_reset_signal: false, kernel_uniq: null, kernel_last_time: null,
  }, o)
}
const MT_STAGES = [
  { name: 'preloader', arch: 'aarch32', origin: 'container', state: 'exec', entry_pc: '0x201004', confidence: 'cross_checked' },
  { name: 'bl31', arch: 'aarch64', origin: 'handoff', state: 'exec', entry_pc: '0x48c03000', confidence: 'observed' },
  { name: 'lk', arch: 'aarch32', origin: 'medium', state: 'exec', entry_pc: '0x48200000', confidence: 'cross_checked' },
]
const A64_STAGE = { name: 'preloader', arch: 'aarch64', origin: 'container', state: 'exec', entry_pc: '0x100', confidence: 'derived' }
const MT_PRIOR = { new_facts_count: 3, undetermined_count: 0, carve_is_full: true, assets_ok: true,
  arch_supported: true, bl_surface: 'none', stages: MT_STAGES }

function responder(cfg) {
  const family = cfg.family ?? 'mediatek'
  return async (call) => {
    const L = call.label
    let m
    if (cfg.override) { const r = await cfg.override(call); if (r !== undefined) return r }
    if (L === 'check-version') return { ok: true, state: 'ok' }
    if (L === 'check-env') return { ok: true, os: 'darwin' }
    if (L === 'family-kit') return ('kit' in cfg) ? cfg.kit : realKit(repo, family)
    // P2: stage_map.py --detect-arch; P3: extract_boot_assets.sh staging; P4: where a resumed workspace left off
    if (L === 'detect-arch') return ('detect' in cfg) ? cfg.detect : { arch: 'arm32', entry_signature: 'gfh', basis: ['synthetic basis line'], confidence: 'derived', exit_code: 0 }
    // the two-reading stage map of an unknown container: by default the signature is under arm64 only (the old "arm64 provisional" shape)
    if (L === 'arch-probe') return ('probe' in cfg) ? cfg.probe : { arm32_exit: 3, arm32_entry_stubs: 0, arm64_exit: 0, arm64_entry_stubs: 1 }
    if (L === 'stage-assets') return ('assets' in cfg) ? cfg.assets : { staging: 'staged', exit_code: 0, image: true, dtb: true, initrd: true, super: false, super_source: 'none' }
    if (L === 'round-base') return ('roundBase' in cfg) ? (typeof cfg.roundBase === 'function' ? cfg.roundBase() : cfg.roundBase) : { last_round: 0, rounds_jsonl: 0, logs: 0 }
    if (L === 'analyze') return cfg.prior ?? MT_PRIOR
    if (L === 'milestone-token-check' || L === 'milestone-token-recheck') return (typeof cfg.tokens === 'function' ? cfg.tokens(L) : cfg.tokens) ?? { tokens_file: 'present', unknown_rungs: [], first_rung_token: true }
    if (L === 'stop-bypass-count') return cfg.stopBypass ?? { f_rows: 0, ledger: 'present' }
    if (L === 'qemu-tree-reset') return cfg.tree ?? { exit_code: 0, noop: true, restored: [], removed: [] }
    if (L === 'core-patch') return cfg.core ?? { exit_code: 0, output: 'ok' }
    if (L === 'detect-medium') return cfg.medium0 ?? { hci_kind: 'unknown', basis: 'none', confidence: 'none', reason: 'x', evidence: [], notes: [] }
    if ((m = /^detect-medium-(\d+)$/.exec(L))) return cfg.mediumLog ? cfg.mediumLog(Number(m[1])) : { hci_kind: 'unknown', basis: 'none', confidence: 'none' }
    if (L === 'build') return cfg.build ?? { build_ok: true, build_warnings: [] }
    if (/^rebuild-/.test(L)) return cfg.rebuild ?? { build_ok: true, build_warnings: [] }
    if ((m = /^run-(\d+)$/.exec(L))) return cfg.obs(Number(m[1]))
    if (/^derived-peek-/.test(L)) return { total: 0, new: 0, stop_points: [] }
    if (/^derived-\d+/.test(L)) return { total: 1, new: cfg.newRows ?? 1, stop_points: [] }
    if (L.startsWith('supervisor-')) return (cfg.supervisor && cfg.supervisor(Number(L.split('-')[1]))) ?? { route: 'fault-classifier' }
    if (L.startsWith('classify-')) return (cfg.classify && cfg.classify(Number(L.split('-')[1]))) ?? { category: 'unknown', fixer_ranking: [{ fixer: 'fixer-bootflow', rank: 1 }] }
    if (/^escalate-/.test(L)) return { new_facts_count: 0 }
    if ((m = /^memdump-plan-(\d+)$/.exec(L))) return typeof cfg.plan === 'function' ? cfg.plan(Number(m[1])) : (cfg.plan ?? { present: false, derived: false, plan: null, reason: 'no ring named' })
    if (/^general-\d+$/.test(L)) return cfg.general ?? { fixer: 'fixer-general', no_new_change: false, change_key: 'g' + call.n, mechanism: 'm', changes: [], build_ok: true, rationale: 'r', one_line_progress: 'p' }
    if (/^fixer-[a-z]+-\d+$/.test(L)) return cfg.fixer ?? { fixer: call.agentType, change: { description: 'd' }, change_key: 'k' + call.n, rationale: 'r', one_line_progress: 'p' }
    if (/^apply-/.test(L)) return { gate_pass: true, sync_ok: true, build_ok: true }
    if (L === 'verify-prep') return { ok: true }
    if (L === 'verify-stage1') return cfg.stage1 ?? { verdict: 'VERIFIED', verdict_label: 'VERIFIED (출처 검증 통과)', gates_passed: 3, gates_total: 3, verify_bypass: { count: 0, status: 'none', unproven: true } }
    if (L === 'verify-negative-round') return cfg.neg ?? { performed: true, run_exit: 124, console_bytes: 321 }
    if (L === 'verify-stage1-final') return cfg.stage1final ?? cfg.stage1 ?? { verdict: 'VERIFIED', gates_passed: 3, gates_total: 3, verify_bypass: { count: 0, unproven: false } }
    if (L === 'verify') return cfg.verifier ?? { script_passes: 3, final_passes: 3, final_verdict: 'VERIFIED', verify_bypass: null }
    if (L === 'analyze-run') return { rounds: 4, stall_stretches: 0, findings: 0 }
    return OK
  }
}

const BASE_ARGS = { workdir: '/wd', model: 'SM-X', bootloader_path: '/fw/pre.img', target: 'F2',
  soc_family: 'mediatek', arch: 'arm32', plugin_dir: '/plug', runtime_round_cap: 12 }
const prompts = (r, pred) => r.calls.filter(pred)
const delegated = r => r.calls.filter(c => !c.isShell)
const byLabel = (r, re) => r.calls.filter(c => re.test(c.label))

async function block(name, f) {
  try { await f() } catch (e) { check(name + ': the scenario ran to its end', false, e && e.stack) }
}


// Writes what the scenarios found (one PASS|FAIL line each) after removing the temporary folders they made.
function finish() {
  tmpdirs.forEach(d => fs.rmSync(d, { recursive: true, force: true }))
  console.log(out.join('\n'))
}

module.exports = {
  path, load, run, realKit, repo, PJ, MUT, MUTATIONS,
  fn, out, check, has, fs, os, spawnSync, TMPROOT,
  tmpdirs, mktmp, W, cmdOf, sh, bashSyntax, fakePlugin, KIT,
  plugAbs, FAM_LINE, RB_LINE, COMMON, OK, mkObs, MT_STAGES, A64_STAGE,
  MT_PRIOR, responder, BASE_ARGS, prompts, delegated, byLabel, block,
  finish,
}
