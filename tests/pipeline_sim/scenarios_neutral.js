// scenarios_neutral.js <repo> - the neutral-pipeline pass: what the pipeline hands the scripts and the agents so that no
// family's vendor default sits in a family-neutral path (V1 --family and the carve verdict, V2 the storage skeleton), and how a
// fixer's change is gated and settled (V3 the last-resort fixer goes through check_change.sh, V4 the fields a fixer answers with and
// the question it leaves behind, V5 the one context every fixer prompt starts from, V6 the one rule text, FIXER_RULES, that every fixer
// prompt - the six specialists and the last-resort fixer - ends with).
// Prints "PASS|FAIL <what>" lines. The shared setup is in common.js; tests/parts/pipeline_family.sh runs this file once as it is
// and once per mutation named in its NEUTRAL_MUTS list (SBOOT_MUTATE), and counts what it prints.
const C = require('./common.js')
const { extractFixerRules } = require('./fixer_rules.js')
const {
  path, run, repo, fn, check, has, fs, spawnSync,
  mktmp, W, cmdOf, sh, bashSyntax,
  MT_STAGES, A64_STAGE, MT_PRIOR, mkObs, responder, BASE_ARGS, byLabel, block, delegated,
} = C

const EX_ARGS = { ...BASE_ARGS, soc_family: 'exynos', arch: 'arm64', bl_surface: 'shell' }
const EX_PRIOR = { ...MT_PRIOR, bl_surface: 'shell', stages: [A64_STAGE] }
const labels = r => r.calls.map(c => c.label)
const buildOf = r => (byLabel(r, /^build$/)[0] || {}).prompt || ''
const analystOf = r => (byLabel(r, /^analyze$/)[0] || {}).prompt || ''

async function main() {
  // ---------------------------------------------------------------- V1: the family the scripts are told, and the carve verdict
  await block('V1', async () => {
    // one build prompt per family: what build_lu.py and carve_disasm.py are told is the family that was read, narrowed to the
    // three the scripts know - a family with a profile of its own but no entry in the scripts is `generic`, never passed through
    const cases = [
      ['mediatek', { ...BASE_ARGS, runtime_round_cap: 1 }, { prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }, 'mediatek'],
      ['exynos', { ...EX_ARGS, runtime_round_cap: 1 }, { family: 'exynos', prior: EX_PRIOR }, 'exynos'],
      ['generic', { ...BASE_ARGS, soc_family: 'generic', runtime_round_cap: 1 }, { family: 'generic', prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }, 'generic'],
      ['a family only the profile knows', { ...BASE_ARGS, soc_family: 'qualcomm', runtime_round_cap: 1 },
        { kit: { family: 'qualcomm', profile: 'profiles/qualcomm.yaml', knowledge: [], runbook: '' }, prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }, 'generic'],
    ]
    for (const [name, args, cfg, want] of cases) {
      const r = await run(fn, args, responder({ obs: () => mkObs(), ...cfg }))
      const b = buildOf(r), an = analystOf(r)
      const others = ['exynos', 'mediatek', 'generic', 'qualcomm'].filter(f => f !== want)
      check('V1: ' + name + ' run: build_lu.py is told --family ' + want + ' (and only that one)', has(b, 'build_lu.py "/wd" --out /wd/fw/lu0.img --family ' + want + '\n') && !others.some(f => has(b, '--family ' + f)), b.slice(b.indexOf('3. Synthesise'), b.indexOf('3. Synthesise') + 300))
      check('V1: ' + name + ' run: every carve_disasm.py call gets --arch AND --family ' + want, has(an, 'pass --arch ' + args.arch + ' --family ' + want + ' to EVERY carve_disasm.py call') && !others.some(f => has(an, '--family ' + f)), an.slice(an.indexOf('Architecture and family'), an.indexOf('Architecture and family') + 300))
    }
    const rx = await run(fn, { ...EX_ARGS, runtime_round_cap: 1 }, responder({ family: 'exynos', prior: EX_PRIOR, obs: () => mkObs() }))
    check('V1: stage_map.py keeps only --arch (it has no --family)', has(analystOf(rx), '--arch arm64 --profile exynos --origin container') && !/--arch arm64 --family [a-z]+ --profile/.test(analystOf(rx)), '')
    // the medium-correction rebuild is a build_lu.py call too
    const rr = n => mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] })
    const rb = await run(fn, { ...BASE_ARGS, target: 'F1', runtime_round_cap: 2 }, responder({ obs: rr, prior: { ...MT_PRIOR, stages: [MT_STAGES[0], MT_STAGES[2]] },
      medium0: { hci_kind: 'unknown', basis: 'none', confidence: 'none', evidence: [], notes: [] },
      mediumLog: () => ({ hci_kind: 'emmc', basis: 'bootloader_log', confidence: 'high', evidence: ['[SD0] x'] }) }))
    const rb1 = byLabel(rb, /^rebuild-1$/)[0]
    check('V1: the medium-correction rebuild names build_lu.py --family mediatek --medium emmc, and the build command carries both flags', rb1 && has(rb1.prompt, 'build_lu.py --family mediatek --medium emmc') && has(rb1.prompt, '--out /wd/fw/lu0.img --medium emmc --family mediatek'), rb1 && rb1.prompt.slice(0, 400))
    // the analyst's item 9: the param fallback is described only to the family it belongs to
    const c9 = p => p.slice(p.indexOf('9. KERNEL COMMAND LINE'), p.indexOf('10. KERNEL SIDE'))
    check('V1: item 9 for a non-Exynos family says a plan naming nothing writes nothing - the param fallback is not offered', has(c9(analystOf(rb)), 'writes nothing for this family either') && !has(c9(analystOf(rb)), 'falls back to a partition literally') && !has(c9(analystOf(rb)), 'warning_cmdline_target'), c9(analystOf(rb)).slice(300))
    check('V1: ... and for an Exynos run it still says so, with the guess warning', has(c9(analystOf(rx)), 'falls back to a partition literally') && has(c9(analystOf(rx)), 'warning_cmdline_target - that name is a guess'), '')
    // CC4: no input plan means no interrupt pattern - the analyst is not promised a default
    const an = analystOf(rx)
    const i5 = an.slice(an.indexOf('5. AUTOBOOT GATE INPUT PATTERN'), an.indexOf('6. BOOT MEDIUM'))
    check('V1: item 5 says no input_plan.json means NO interrupt pattern and an absent plan source - not a documented default', has(i5, 'sends NO interrupt pattern at all') && has(i5, 'records the plan source as absent') && !has(i5, 'documented default'), i5.slice(-500))
    // the carve verdict: only false stops; null (undetermined) goes on and is journaled with its reason
    const go = prior => run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]], ...prior } }))
    const rN = await go({ carve_is_full: null, carve_note: 'no yardstick for this family and no header evidence' })
    const cu = byLabel(rN, /^carve-undetermined$/)[0]
    check('V1: carve_is_full null does not stop (no BLOCKED_CARVE, the run builds)', rN.result?.stop_reason !== 'BLOCKED_CARVE' && rN.calls.some(c => c.label === 'build'), JSON.stringify(rN.result?.stop_reason))
    check('V1: ... and is journaled as "carve undetermined" with the analyst\'s reason and the family it was asked for', !!cu && has(cu.prompt, 'journal.sh') && has(cu.prompt, 'decision') && has(cu.prompt, 'carve undetermined') && has(cu.prompt, 'no yardstick for this family and no header evidence') && has(cu.prompt, '--family mediatek') && rN.logs.some(l => has(l, 'carve 판정 불가') && has(l, 'no yardstick')), cu && cu.prompt)
    check('V1: ... after the blockers were weighed and before Build', cu && labels(rN).indexOf('carve-undetermined') > labels(rN).indexOf('analyze') && labels(rN).indexOf('carve-undetermined') < labels(rN).indexOf('qemu-tree-reset'), labels(rN).slice(0, 24).join(' '))
    const rNn = await go({ carve_is_full: null })
    check('V1: a null with no note says so in the journal (no reason invented)', has((byLabel(rNn, /^carve-undetermined$/)[0] || {}).prompt, 'no note was reported'), '')
    const rNone = await go({ carve_is_full: undefined })
    check('V1: an answer with no carve verdict at all is the same undetermined case, with its own reason', has((byLabel(rNone, /^carve-undetermined$/)[0] || {}).prompt, 'reported no carve verdict'), '')
    const rT = await go({ carve_is_full: true }), rF = await go({ carve_is_full: false })
    check('V1: true journals nothing about carve; false is still BLOCKED_CARVE (and journals no "undetermined")', byLabel(rT, /^carve-undetermined$/).length === 0 && rF.result?.stop_reason === 'BLOCKED_CARVE' && byLabel(rF, /^carve-undetermined$/).length === 0, JSON.stringify([rT.calls.length, rF.result?.stop_reason]))
    check('V1: the analyst is told to report null as null with a carve_note, and that only false stops', has(analystOf(rN), 'carve_is_full true,') && has(analystOf(rN), 'never turn null into true or false') && has(analystOf(rN), 'BLOCKED_CARVE on false only'), '')
    check('V1: ANALYST_SCHEMA carries carve_note next to carve_is_full', /carve_is_full: \{ type: \['boolean', 'null'\] \},\n\s+carve_note: \{ type: \['string', 'null'\] \}/.test(fn.source), '')
  })

  // ---------------------------------------------------------------- V2: the storage skeleton is offered by medium and family
  await block('V2', async () => {
    const KIND = (k) => ({ hci_kind: k, basis: k === 'unknown' ? 'none' : 'dtb', confidence: 'medium', reason: 'r', evidence: [], notes: [] })
    const offered = async (famArgs, famCfg, kind) => {
      const r = await run(fn, { ...famArgs, target: 'F1', runtime_round_cap: 1 }, responder({ obs: () => mkObs(), medium0: KIND(kind), ...famCfg }))
      const b = buildOf(r)
      return { b, plus: has(b, 'machine_full.c.tmpl plus /plug/templates/storage_hci.c.tmpl'), r }
    }
    const EX = [EX_ARGS, { family: 'exynos', prior: EX_PRIOR }]
    const MT = [{ ...BASE_ARGS, arch: 'arm64' }, { prior: { ...MT_PRIOR, stages: [A64_STAGE] } }]
    const GE = [{ ...BASE_ARGS, soc_family: 'generic', arch: 'arm64' }, { family: 'generic', prior: { ...MT_PRIOR, stages: [A64_STAGE] } }]
    const matrix = [
      ['ufs', 'exynos', EX, true], ['ufs', 'mediatek', MT, true], ['ufs', 'generic', GE, true],
      ['emmc', 'exynos', EX, false], ['emmc', 'mediatek', MT, false], ['emmc', 'generic', GE, false],
      ['unknown', 'exynos', EX, true], ['unknown', 'mediatek', MT, false], ['unknown', 'generic', GE, false],
    ]
    for (const [kind, fam, [a, c], want] of matrix) {
      const o = await offered(a, c, kind)
      check('V2: medium ' + kind + ' + ' + fam + ' -> storage_hci.c.tmpl ' + (want ? 'offered' : 'NOT offered'), o.plus === want, o.b.slice(o.b.indexOf('2. Fill'), o.b.indexOf('2. Fill') + 260))
    }
    const u = await offered(...MT, 'unknown'), ux = await offered(...EX, 'unknown'), uf = await offered(...MT, 'ufs'), em = await offered(...EX, 'emmc')
    check('V2: an undecided medium of another family says no storage template is offered while it is open, and still says 미확정', has(u.b, 'no storage template is offered while the medium is open') && has(u.b, '미확정') && !has(u.b, 'plus /plug/templates/storage_hci.c.tmpl'), u.b.slice(u.b.indexOf('The storage model follows'), u.b.indexOf('The storage model follows') + 400))
    check('V2: an undecided Exynos medium keeps the skeleton but calls it one (names and answers are examples to derive)', has(ux.b, 'storage_hci.c.tmpl is offered for this family but is only a skeleton') && has(ux.b, 'examples to be derived'), ux.b.slice(ux.b.indexOf('The storage model follows'), ux.b.indexOf('The storage model follows') + 400))
    check('V2: a UFS medium says the skeleton\'s window names and return values are examples to derive, not values to keep', has(uf.b, 'storage_hci.c.tmpl applies - as a skeleton') && has(uf.b, 'examples to be derived from STATIC.md'), '')
    check('V2: eMMC still says model the eMMC controller and do NOT use the UFS template - without a vendor controller name', has(em.b, 'do NOT use storage_hci.c.tmpl') && !/MSDC|SDHCI/.test(em.b), '')
    // a mixed-architecture chain never lists the AArch64 skeleton in its Fill line, whatever the medium
    const mx = await run(fn, { ...BASE_ARGS, target: 'F1', runtime_round_cap: 1 }, responder({ obs: () => mkObs(), medium0: KIND('ufs'), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    check('V2: a mixed-architecture chain lists only its own template in the Fill line (unchanged)', has(buildOf(mx), '2. Fill /plug/templates/machine_mixed_arch.c.tmpl with values') && !has(buildOf(mx), 'machine_full.c.tmpl plus'), '')
    // the offer follows the medium when the log corrects it: a rebuild for UFS after an unknown start (Exynos) carries the template
    const rr = n => mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] })
    const rb = await run(fn, { ...EX_ARGS, target: 'F1', runtime_round_cap: 2 }, responder({ family: 'exynos', obs: rr, prior: { ...EX_PRIOR, stages: [A64_STAGE] },
      medium0: KIND('unknown'), mediumLog: () => ({ hci_kind: 'emmc', basis: 'bootloader_log', confidence: 'high', evidence: ['l'] }) }))
    const rb1 = byLabel(rb, /^rebuild-1$/)[0]
    check('V2: the rebuild after the log decided eMMC no longer offers the skeleton', rb1 && !has(rb1.prompt, 'machine_full.c.tmpl plus /plug/templates/storage_hci.c.tmpl') && has(rb1.prompt, 'do NOT use storage_hci.c.tmpl'), rb1 && rb1.prompt.slice(0, 200))
  })

  // ---------------------------------------------------------------- V3: the last-resort fixer's change goes through the same gate
  await block('V3', async () => {
    const GEN = { fixer: 'fixer-general', no_new_change: false, change_key: 'gk1', mechanism: 'one mechanism', changes: [{ file: 'machine_full.c', what: 'the window' }], build_ok: true, rationale: 'why', one_line_progress: '| run 1 | x | y |' }
    const base = { prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }
    const direct = { ...base, supervisor: () => ({ route: 'fixer-general', treatment_plan: 'tp' }), general: GEN }
    const declineAll = { ...base, classify: () => ({ category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }] }), fixer: { fixer: 'x', not_mine: true }, general: GEN }
    const abort = { prior: base.prior, obs: n => (n === 1 ? mkObs({ run_fault: true, run_fault_line: 'assert x' }) : mkObs()), general: GEN }
    const A2 = { ...BASE_ARGS, runtime_round_cap: 2 }
    const routes = [['the supervisor sends it straight to the general fixer', await run(fn, A2, responder(direct)), 'unowned'],
                    ['every specialist declined and the general fixer takes it', await run(fn, A2, responder(declineAll)), 'mmc_partition_scan_failed'],
                    ['QEMU aborted after the guest printed', await run(fn, A2, responder(abort)), 'qemu_abort']]
    for (const [name, r, cat] of routes) {
      const ap = byLabel(r, /^apply-1$/)[0], gl = labels(r)
      const cmd = ap ? cmdOf(ap) : ''
      check('V3: ' + name + ' -> its change is applied by the same apply step as a specialist\'s (apply-1 after general-1, before the next round)', !!ap && gl.indexOf('general-1') < gl.indexOf('apply-1') && gl.indexOf('apply-1') < gl.indexOf('run-2'), gl.join(' '))
      check('V3: ... and the general fixer\'s gate runs in the general scope (CHANGE_SCOPE=general: the one-file and hunk limits do not bind it, the bypass-record checks do)', has(cmd, 'CHANGE_SCOPE=general bash "/plug/scripts/check_change.sh" "/wd" verify; GATE=$?'), cmd.slice(0, 300))
      check('V3: ... that step runs check_change.sh verify, restores on a failure, then syncs and rebuilds - in that order', has(cmd, 'check_change.sh" "/wd" verify; GATE=$?') && has(cmd, 'if [ $GATE -ne 0 ]; then bash "/plug/scripts/check_change.sh" "/wd" restore; fi') && cmd.indexOf('verify; GATE') < cmd.indexOf('restore') && cmd.indexOf('restore') < cmd.indexOf('sync_machine.sh') && cmd.indexOf('sync_machine.sh') < cmd.indexOf('ninja qemu-system-aarch64'), cmd.slice(0, 500))
      check('V3: ... the round is recorded as applied or reverted by bash (never both), for the general fixer, with its change_key and the category ' + cat, has(cmd, 'if [ $GATE -eq 0 ]; then') && has(cmd, "effect='applied'") && has(cmd, "effect='reverted'") && has(cmd, "fixer='fixer-general'") && has(cmd, "change_key='gk1'") && has(cmd, "category='" + cat + "'"), cmd.slice(-900))
      check('V3: ... and parses as bash; no separate "record without a gate" step is left (general-record / abort-record)', bashSyntax(ap) === '' && !gl.some(l => /^(general-record|abort-record)-/.test(l)), gl.join(' '))
    }
    // a rejected change: said, rolled back (the gate script did it), not a stop
    const rj = await run(fn, A2, responder({ ...direct, override: async c => /^apply-1$/.test(c.label) ? { gate_pass: false, gate_reason: '소스 파일 2 개를 동시에 고쳤습니다', sync_ok: true, build_ok: true } : undefined }))
    check('V3: a change the gate rejects is reported as rolled back and the run goes on (no stop)', rj.logs.some(l => has(l, '한 변경 검문 불통과') && has(l, '소스 파일 2 개를 동시에 고쳤습니다') && has(l, '되돌렸습니다')) && labels(rj).includes('run-2') && rj.result?.stop_reason !== 'BLOCKED_BUILD', rj.logs.join('\n'))
    // the build: the pipeline's own measurement decides; the fixer's claim stands only when nothing contradicts it
    const bb = (applyAns, general) => run(fn, A2, responder({ ...direct, general: { ...GEN, ...general }, override: async c => /^apply-1$/.test(c.label) ? applyAns : undefined }))
    const rBad = await bb({ gate_pass: true, sync_ok: true, build_ok: false }, {})
    check('V3: a build that fails when the pipeline rebuilds is BLOCKED_BUILD, recorded with the fixer named', rBad.result?.stop_reason === 'BLOCKED_BUILD' && rBad.calls.some(c => c.label === 'general-build-blocker-1' && has(c.prompt, 'fixer-general')) && !labels(rBad).includes('run-2'), JSON.stringify(rBad.result?.stop_reason))
    const rSync = await bb({ gate_pass: true, sync_ok: false, sync_reason: 'unmapped', build_ok: false }, {})
    check('V3: a sync that did not reach the QEMU tree is BLOCKED_BUILD (the next round would measure the old binary)', rSync.result?.stop_reason === 'BLOCKED_BUILD' && rSync.calls.some(c => c.label === 'sync-blocker-1' && has(c.prompt, 'unmapped')), JSON.stringify(rSync.result?.stop_reason))
    const rClaim = await bb({}, { build_ok: false })
    check('V3: the fixer\'s own build_ok=false stands when the apply step reports no build result', rClaim.result?.stop_reason === 'BLOCKED_BUILD', JSON.stringify(rClaim.result?.stop_reason))
    const rOver = await bb({ gate_pass: false, sync_ok: true, build_ok: true }, { build_ok: false })
    check('V3: ... but a rejected change is rolled back and rebuilt: the measured build_ok=true wins over the fixer\'s "false", so the run goes on', rOver.result?.stop_reason !== 'BLOCKED_BUILD' && labels(rOver).includes('run-2'), JSON.stringify(rOver.result?.stop_reason))
    // a decline: recorded as a stall (the round is not a change), no apply step; a QEMU abort ends the run
    const dd = await run(fn, A2, responder({ ...direct, general: { fixer: 'fixer-general', no_new_change: true, rationale: 'what writes this register is unknown' } }))
    const dec = byLabel(dd, /^general-decline-1$/)[0]
    check('V3: a general fixer with no untried change is a recorded stall (no_new_change), with its question in the journal, and no apply step runs', !!dec && has(dec.prompt, 'try-end') && has(dec.prompt, 'what writes this register is unknown') && has(dec.prompt, 'fixer_no_new_change=true') && has(dec.prompt, "effect='stall'") && !labels(dd).some(l => /^apply-/.test(l)), dec && dec.prompt)
    const da = await run(fn, A2, responder({ ...abort, general: { fixer: 'fixer-general', no_new_change: true } }))
    check('V3: a QEMU abort the general fixer cannot treat ends the run as BLOCKED_BUILD', da.result?.stop_reason === 'BLOCKED_BUILD' && byLabel(da, /^abort-decline-1$/).length === 1 && !labels(da).includes('run-2'), JSON.stringify(da.result?.stop_reason))
    const dx = await run(fn, A2, responder({ ...declineAll, general: { fixer: 'fixer-general', no_new_change: true } }))
    check('V3: when every specialist and the general fixer decline the round is a stall and the run goes on', byLabel(dx, /^decline-1$/).length === 1 && labels(dx).includes('run-2') && dx.result?.stop_reason !== 'BLOCKED_BUILD', JSON.stringify(dx.result?.stop_reason))
    // a specialist's change goes through the same apply step WITHOUT the general scope
    const spCfg = { ...base, classify: () => ({ category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }] }), fixer: { fixer: 'fixer-storage', not_mine: false, no_new_change: false, change: 'c', change_key: 'sk1', rationale: 'r', one_line_progress: '| run 1 | s | c |' } }
    const spRun = await run(fn, A2, responder(spCfg))
    const spApply = byLabel(spRun, /^apply-1$/)[0]
    check('V3: a specialist\'s change is gated by the same apply step with NO general scope (the one-file and hunk limits keep binding it)', !!spApply && has(cmdOf(spApply), 'bash "/plug/scripts/check_change.sh" "/wd" verify; GATE=$?') && !has(cmdOf(spApply), 'CHANGE_SCOPE'), spApply ? cmdOf(spApply).slice(0, 300) : 'no apply-1: ' + labels(spRun).join(' '))
    const gp = (byLabel(routes[0][1], /^general-1$/)[0] || {}).prompt
    check('V3: the general fixer is told the one-file and hunk limits do NOT bind it, while the bypass-record checks bind it exactly as they bind a specialist', has(gp, 'limits that bind a specialist do NOT bind you') && has(gp, 'the bypass-record checks bind you exactly as they bind a specialist'), '')
    check('V3: the shared rules say a specialist is limited to one source file and a few hunks and the last-resort fixer is not', has(gp, "A specialist's change is also limited to one source file and a few hunks; the last-resort fixer's is not"), '')
  })

  // ---------------------------------------------------------------- V3x: the emitted apply step, executed against the REAL check_change.sh
  await block('V3x', async () => {
    const GEN = { fixer: 'fixer-general', no_new_change: false, change_key: 'real-gate', mechanism: 'm', changes: [{ file: 'machine_full.c', what: 'one window' }], build_ok: true, rationale: 'r', one_line_progress: '| run 1 | x | y |' }
    const ENTRY = (side) => `\n### #1 타이머 창\n- 대상: 타이머 레지스터 창\n- 이유: 이 환경에 모델이 없다\n- 방법: 읽기 값을 고정한다\n- 부작용: ${side}\n`
    const setup = (side) => {
      const wd = mktmp('ws'), home = mktmp('home'), stub = mktmp('stub')
      W(path.join(wd, '06_machine', 'machine_full.c'), 'int a;\nint b;\nint c;\n')
      W(path.join(wd, '06_machine', 'bypasses.md'), '# 우회 기록\n')
      W(path.join(home, 'qemu-build', 'qemu-10.2.2', 'hw', 'arm', 'smx_full.c'), 'int old;\n')
      fs.mkdirSync(path.join(home, 'qemu-build', 'qemu-10.2.2', 'build'), { recursive: true })
      W(path.join(stub, 'ninja'), '#!/bin/sh\necho ninja >> "$NINJA_LOG"\nexit 0\n'); fs.chmodSync(path.join(stub, 'ninja'), 0o755)
      const snap = spawnSync('bash', [path.join(repo, 'scripts', 'check_change.sh'), wd, 'snapshot', '1'], { encoding: 'utf8' })
      // what the fixer then did: one change in one file, and an entry in the record
      W(path.join(wd, '06_machine', 'machine_full.c'), 'int a;\nint b2;\nint c;\n')
      fs.appendFileSync(path.join(wd, '06_machine', 'bypasses.md'), ENTRY(side))
      return { wd, home, stub, snap }
    }
    const emitted = async (wd, cfg) => {
      const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: repo, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(), supervisor: () => ({ route: 'fixer-general' }), general: GEN, ...cfg }))
      return cmdOf(byLabel(r, /^apply-1$/)[0])
    }
    const exec = (cmd, s) => sh(cmd, s.wd, { HOME: s.home, PATH: s.stub + path.delimiter + process.env.PATH, NINJA_LOG: path.join(s.wd, 'ninja.log'), PYTHONDONTWRITEBYTECODE: '1' })
    const rows = wd => { try { return fs.readFileSync(path.join(wd, 'rounds.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(l => JSON.parse(l)) } catch (e) { return [] } }
    const rd = (wd, f) => fs.readFileSync(path.join(wd, '06_machine', f), 'utf8')
    // a sound change: one file, one hunk, a four-field entry with a side effect
    const ok = setup('이 창이 읽는 값은 실제 하드웨어의 값이 아니다')
    check('V3x: the stand-in setup holds a snapshot of the round', has(ok.snap.stdout, 'snapshot'), ok.snap.stdout + ok.snap.stderr)
    const okOut = exec(await emitted(ok.wd), ok)
    check('V3x: a change that passes check_change.sh is kept, rebuilt, and recorded as applied for fixer-general', okOut.status === 0 && has(okOut.stdout, '"pass":true') && rd(ok.wd, 'machine_full.c') === 'int a;\nint b2;\nint c;\n' && fs.existsSync(path.join(ok.wd, 'ninja.log')) && rows(ok.wd).length === 1 && rows(ok.wd)[0].effect === 'applied' && rows(ok.wd)[0].fixer === 'fixer-general' && rows(ok.wd)[0].change_key === 'real-gate', okOut.stdout.slice(-400) + okOut.stderr.slice(-300) + JSON.stringify(rows(ok.wd)))
    // an entry whose 부작용 is empty: the real gate rejects it, the change and the entry are rolled back, the tree is rebuilt from the restored source
    const bad = setup('(기록 없음)')
    const badOut = exec(await emitted(bad.wd), bad)
    check('V3x: a change whose bypass entry says "(기록 없음)" for 부작용 is rejected by the REAL gate (exit 2, named reason)', has(badOut.stdout, '"pass":false') && has(badOut.stdout, '부작용'), badOut.stdout.slice(-500) + badOut.stderr.slice(-300))
    check('V3x: ... the source is back to the snapshot and the rejected entry is gone from the record', rd(bad.wd, 'machine_full.c') === 'int a;\nint b;\nint c;\n' && rd(bad.wd, 'bypasses.md') === '# 우회 기록\n', rd(bad.wd, 'machine_full.c') + '|' + rd(bad.wd, 'bypasses.md'))
    check('V3x: ... the tree is rebuilt from the restored source, and the round is recorded as reverted (not applied) - the same branch a specialist takes', fs.existsSync(path.join(bad.wd, 'ninja.log')) && rows(bad.wd).length === 1 && rows(bad.wd)[0].effect === 'reverted' && rows(bad.wd)[0].fixer === 'fixer-general', JSON.stringify(rows(bad.wd)) + badOut.stdout.slice(-300))
    // The last-resort fixer exists because not every stop point has a specialist: one mechanism may span
    // several files. Two sources changed at once are KEPT in the general scope ...
    const two = setup('이 창이 읽는 값은 실제 하드웨어의 값이 아니다')
    W(path.join(two.wd, '06_machine', 'other.c'), 'int z;\n')
    const twoOut = exec(await emitted(two.wd), two)
    check('V3x: a general change that touches two sources is NOT rejected for that (one mechanism may span several files): kept, rebuilt, recorded as applied', twoOut.status === 0 && has(twoOut.stdout, '"pass":true') && has(twoOut.stdout, '"scope":"general"') && fs.existsSync(path.join(two.wd, '06_machine', 'other.c')) && rows(two.wd)[0] && rows(two.wd)[0].effect === 'applied', twoOut.stdout.slice(-400) + JSON.stringify(rows(two.wd)))
    // ... but the bypass-record checks still bind it, however many files it touched
    const twoBad = setup('(기록 없음)')
    W(path.join(twoBad.wd, '06_machine', 'other.c'), 'int z;\n')
    const twoBadOut = exec(await emitted(twoBad.wd), twoBad)
    check('V3x: a multi-file general change whose entry says "(기록 없음)" is still rejected and rolled back (widening what may be touched never widens what may go unrecorded)', has(twoBadOut.stdout, '"pass":false') && has(twoBadOut.stdout, '부작용') && !fs.existsSync(path.join(twoBad.wd, '06_machine', 'other.c')) && rd(twoBad.wd, 'machine_full.c') === 'int a;\nint b;\nint c;\n' && rows(twoBad.wd)[0] && rows(twoBad.wd)[0].effect === 'reverted', twoBadOut.stdout.slice(-400) + JSON.stringify(rows(twoBad.wd)))
    // ... and a specialist's change touching two sources is rejected as before: the REAL script, same tree, no scope
    const sp2 = setup('이 창이 읽는 값은 실제 하드웨어의 값이 아니다')
    W(path.join(sp2.wd, '06_machine', 'other.c'), 'int z;\n')
    const spGate = spawnSync('bash', [path.join(repo, 'scripts', 'check_change.sh'), sp2.wd, 'verify'], { encoding: 'utf8' })
    check('V3x: the same two-source change in the specialist scope is rejected (one change per round), so the exemption is the scope and not a loosened gate', spGate.status === 2 && has(spGate.stdout, '"pass":false') && has(spGate.stdout, '"scope":"specialist"') && has(spGate.stdout, '한 회차 한 변경'), spGate.stdout.slice(-300))
  })

  // ---------------------------------------------------------------- V4: what a fixer answers with, and the question it leaves
  await block('V4', async () => {
    const schemaOf = name => (new RegExp('const ' + name + ' = \\{([\\s\\S]*?)\\n\\}\\n').exec(fn.source) || [])[1] || ''
    const keys = text => [...text.matchAll(/^\s{4}([a-z_]+):/gm)].map(m => m[1])
    const fk = keys(schemaOf('FIXER_SCHEMA')), gk = keys(schemaOf('GENERAL_SCHEMA'))
    const never = ['escalate', 'suspect_prior_bypass', 'bypass_doc', 'category']
    check('V4: FIXER_SCHEMA holds only what the pipeline reads - none of escalate, suspect_prior_bypass, bypass_doc, category (' + fk.join(',') + ')', fk.length >= 6 && !never.some(k => fk.includes(k)) && ['fixer', 'not_mine', 'no_new_change', 'change', 'change_key', 'rationale', 'one_line_progress'].every(k => fk.includes(k)), fk.join(','))
    check('V4: GENERAL_SCHEMA drops bypass_doc and keeps what is read (' + gk.join(',') + ')', gk.length >= 8 && !never.some(k => gk.includes(k)) && ['no_new_change', 'change_key', 'build_ok', 'rationale', 'mechanism', 'changes', 'one_line_progress'].every(k => gk.includes(k)), gk.join(','))
    // and nothing in the pipeline reads those fields off a fixer's answer
    const code = fn.source.split('\n').filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n')
    check('V4: no code reads escalate / bypass_doc / category from a fixer\'s answer (attempt, fix, gen)', !/\b(attempt|fix|gen|fixAnswer)\??\.(escalate|bypass_doc|category|suspect_prior_bypass)\b/.test(code), (code.match(/\b(attempt|fix|gen)\??\.(escalate|bypass_doc|category|suspect_prior_bypass)\b/g) || []).join(','))
    // the shared answer rule: an open question goes in "rationale" with no_new_change=true, in both fixer prompts
    const cfg = { prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(),
      classify: () => ({ category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }] }),
      fixer: { fixer: 'x', not_mine: true, no_new_change: false }, general: { fixer: 'fixer-general', no_new_change: true } }
    const r1 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder(cfg))
    const sp = byLabel(r1, /^fixer-storage-1$/)[0], gn = byLabel(r1, /^general-1$/)[0]
    const RULE = 'An open question you cannot settle yourself goes in "rationale", with no_new_change=true'
    check('V4: the specialist prompt and the general prompt both say an open question goes in "rationale" with no_new_change=true, and that the next derivation gets it', sp && gn && [sp, gn].every(c => has(c.prompt, RULE) && has(c.prompt, "passes that text to the static-analyzer's next derivation")), (sp && sp.prompt.slice(-400)))
    check('V4: neither prompt offers an escalate / bypass_doc / category field', ![sp, gn].some(c => /escalate=|"escalate"|bypass_doc|suspect_prior_bypass:|"category":/.test(c.prompt)), '')
    // a declining fixer's rationale reaches the NEXT escalation as its focus, once
    const supervisor = n => ({ route: n >= 2 ? 'static-analyzer' : 'fault-classifier' })
    // the answers differ per round (the label carries the round), so what a later escalation carries can be told from an earlier one
    const ask = (specialist, general, extra = {}) => run(fn, { ...BASE_ARGS, runtime_round_cap: 3 }, responder({ ...cfg, supervisor, ...extra,
      override: async c => {
        let m
        if ((m = /^fixer-storage-(\d+)$/.exec(c.label))) return specialist(Number(m[1]))
        if ((m = /^general-(\d+)$/.exec(c.label))) return general(Number(m[1]))
        return extra.override ? extra.override(c) : undefined
      } }))
    const r2 = await ask(n => ({ fixer: 'x', no_new_change: true, rationale: `WHY-S${n} which block clears this status bit is unknown` }),
                         n => ({ fixer: 'fixer-general', no_new_change: true, rationale: `WHY-G${n} the reset line is read before it is written` }))
    const e2 = byLabel(r2, /^escalate-2$/)[0], e3 = byLabel(r2, /^escalate-3$/)[0]
    check('V4: round 1\'s two declines (the specialist and the general fixer) are the FOCUS of round 2\'s escalation, each with its fixer and round', e2 && has(e2.prompt, 'FOCUS: ') && has(e2.prompt, 'Open questions from fixers that declined') && has(e2.prompt, 'round 1, fixer-storage (no_new_change): WHY-S1 which block clears this status bit is unknown') && has(e2.prompt, 'round 1, fixer-general (no_new_change): WHY-G1 the reset line is read before it is written'), e2 && e2.prompt.slice(e2.prompt.indexOf('FOCUS') - 20, e2.prompt.indexOf('FOCUS') + 700))
    check('V4: ... and are handed over once: round 3\'s escalation carries round 2\'s questions, not round 1\'s', e3 && has(e3.prompt, 'round 2, fixer-storage (no_new_change): WHY-S2') && has(e3.prompt, 'WHY-G2') && !has(e3.prompt, 'WHY-S1') && !has(e3.prompt, 'WHY-G1'), e3 && e3.prompt.slice(e3.prompt.indexOf('FOCUS') - 20, e3.prompt.indexOf('FOCUS') + 500))
    const rq = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ ...cfg, supervisor: () => ({ route: 'static-analyzer' }) }))
    check('V4: an escalation with nothing waiting has no FOCUS and no open-question text (unchanged)', byLabel(rq, /^escalate-1$/).length === 1 && !has(byLabel(rq, /^escalate-1$/)[0].prompt, 'FOCUS:') && !has(byLabel(rq, /^escalate-1$/)[0].prompt, 'Open questions'), byLabel(rq, /^escalate-1$/)[0] && byLabel(rq, /^escalate-1$/)[0].prompt.slice(0, 200))
    const r3 = await ask(() => ({ fixer: 'x', not_mine: true }), () => ({ fixer: 'fixer-general', no_new_change: true }))
    check('V4: a decline with no rationale leaves no question behind (nothing is invented)', byLabel(r3, /^escalate-2$/).length === 1 && !has(byLabel(r3, /^escalate-2$/)[0].prompt, 'Open questions') && !has(byLabel(r3, /^escalate-2$/)[0].prompt, 'FOCUS:'), byLabel(r3, /^escalate-2$/)[0] && byLabel(r3, /^escalate-2$/)[0].prompt.slice(0, 300))
    const r4 = await ask(() => ({ fixer: 'x', not_mine: true, rationale: 'WHY-NM belongs to the kernel side maybe' }), () => ({ fixer: 'fixer-general', no_new_change: true }))
    check('V4: a not_mine decline with a rationale is carried too, marked not_mine', has((byLabel(r4, /^escalate-2$/)[0] || {}).prompt, 'round 1, fixer-storage (not_mine): WHY-NM'), '')
    // the reset-hypothesis escalation keeps its own focus and gets the waiting questions after it
    const r5 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 2 }, responder({ ...cfg, obs: () => mkObs({ guest_reset_signal: true }),
      fixer: { fixer: 'x', no_new_change: true, rationale: 'WHY-RS the watchdog block is touched by whom' },
      classify: n => (n === 1 ? { category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }] } : { category: 'guest_reset_after_jump', fixer_ranking: [] }) }))
    const er = byLabel(r5, /^escalate-2-reset$/)[0]
    check('V4: the guest_reset_after_jump escalation keeps its own focus and appends the waiting question', er && has(er.prompt, 'the classifier named guest_reset_after_jump') && has(er.prompt, 'WHY-RS the watchdog block is touched by whom'), er && er.prompt.slice(er.prompt.indexOf('FOCUS') - 20, er.prompt.indexOf('FOCUS') + 400))
    // an old question is dropped once more than five wait
    const many = await run(fn, { ...BASE_ARGS, runtime_round_cap: 4 }, responder({ ...cfg, supervisor: n => ({ route: n >= 4 ? 'static-analyzer' : 'fault-classifier' }),
      fixer: { fixer: 'x', no_new_change: true, rationale: 'WHY-MANY' }, general: { fixer: 'fixer-general', no_new_change: true, rationale: 'WHY-MANY-G' } }))
    const em = byLabel(many, /^escalate-4$/)[0]
    check('V4: at most the five most recent questions wait (three rounds of two = six, the oldest is dropped)', em && (em.prompt.match(/WHY-MANY/g) || []).length === 5 && !has(em.prompt, 'round 1, fixer-storage'), em && (em.prompt.match(/round \d, fixer-[a-z]+/g) || []).join('|'))
  })

  // ---------------------------------------------------------------- V5: one context for every fixer prompt
  await block('V5', async () => {
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ channels: { uart_bytes: 4, kernel_lines: 900, host_lines: 3 }, kernel_uniq: 800, kernel_last_time: 30, console: '/c-1', summary: '/s-1', trace: '/t-1.log', origin_block: 'ORIGIN-BLOCK-TEXT' }),
      supervisor: () => ({ route: 'fault-classifier', treatment_plan: 'a plan' }),
      classify: () => ({ category: 'mmc_partition_scan_failed', evidence: { why: 'ev' }, fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }] }),
      fixer: { fixer: 'x', not_mine: true, no_new_change: false }, general: { fixer: 'fixer-general', no_new_change: true } }))
    const sp = byLabel(r, /^fixer-storage-1$/)[0], gn = byLabel(r, /^general-1$/)[0]
    const ctx = p => { const a = p.indexOf('Classification: '), b = p.indexOf('Already attempted: '); return a < 0 || b < 0 ? null : p.slice(a, p.indexOf('\n', b) + 1) }
    const cs = sp && ctx(sp.prompt), cg = gn && ctx(gn.prompt)
    check('V5: the specialist\'s and the general fixer\'s prompts carry the very same context block (classification, fingerprint, logs, derived facts, family, channels, sources, record)', !!cs && cs === cg && cs.length > 600, cs ? cs.slice(0, 300) + ' <> ' + (cg || '').slice(0, 300) : 'no context block')
    const need = ['Classification: mmc_partition_scan_failed', '"why":"ev"', 'Fingerprint: ', 'Origin exception block: ORIGIN-BLOCK-TEXT', 'Console: /c-1', 'Summary: /s-1', 'Full trace: /t-1.log',
      'Derived facts: /wd/STATIC.md', 'Stop points derived for this firmware:', 'Family knowledge: ', 'Runbook: ', 'kernel log: /wd/07_logs/kernel_1.log',
      'Machine sources: /wd/06_machine/', 'Bypass record: /wd/06_machine/bypasses.md', 'Already attempted: /wd/rounds.jsonl - never repeat an existing change_key']
    check('V5: ... and it holds each of those pieces (fingerprint with the origin block, console / summary / trace, STATIC.md, derived table, family kit, channels, sources, ledger, rounds.jsonl)', !!cs && need.every(t => has(cs, t)), cs && need.filter(t => !has(cs, t)).join(' | '))
    check('V5: what differs stays with each caller: the specialist\'s "시도할 변경" hint and the general fixer\'s last-resort intro and build commands', has(sp.prompt, '"시도할 변경"') && !has(gn.prompt, '"시도할 변경"') && has(gn.prompt, 'You are the last resort.') && has(gn.prompt, 'sync_machine.sh') && !has(sp.prompt, 'You are the last resort.') && !has(sp.prompt, 'ninja qemu-system-aarch64'), '')
    // the stalling note is a pipeline input, so both fixers get it when the supervisor raised it
    const rs = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(),
      supervisor: () => ({ route: 'fault-classifier', suspect_prior_bypass: true }), classify: () => ({ category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }] }),
      fixer: { fixer: 'x', not_mine: true }, general: { fixer: 'fixer-general', no_new_change: true } }))
    const NOTE = 'The run is stalling. Suspect the side effects of an earlier bypass'
    check('V5: the supervisor\'s "suspect the earlier bypass" note reaches the specialist and the general fixer alike, and neither without it', [byLabel(rs, /^fixer-storage-1$/)[0], byLabel(rs, /^general-1$/)[0]].every(c => c && has(c.prompt, NOTE)) && !has(sp.prompt, NOTE) && !has(gn.prompt, NOTE), '')
    const q = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(), supervisor: () => ({ route: 'fixer-general' }) }))
    check('V5: the supervisor-direct general prompt has the same context block, with "unknown" for the classification it does not have', has(ctx((byLabel(q, /^general-1$/)[0] || {}).prompt || ''), 'Classification: unknown   Evidence: {}'), '')
  })

  // ---------------------------------------------------------------- V6: one rule text for every fixer
  await block('V6', async () => {
    const norm = t => String(t ?? '').replace(/\s+/g, ' ')
    const RULES = extractFixerRules(fn.source)
    const code = fn.source.split('\n').filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n')
    check('V6: FIXER_RULES is ONE constant that evaluates on its own to the shared rule text (a run of literals, no blank line, no other name)', typeof RULES === 'string' && RULES.length > 1500 && (code.match(/\bconst FIXER_RULES\b/g) || []).length === 1, String(RULES).slice(0, 100))
    // every wording the agent files used to pin, now pinned where the rules live
    const PINS = ['never `(기록 없음)`', 'heading `#<id>`', '- 메타: 종류=…; 표지=…; 출처=…; 도출=…', '/* bypass:<id> */', 'rejects a **new or edited** entry', '(exit 2, naming the entry)',
      'only when at least one tag exists', 'tag every row', 'as absolute paths - open them as given', '`Family knowledge:`', '`Runbook:`', '**Read them before you act**',
      'An open question you cannot settle yourself goes in "rationale", with no_new_change=true', "passes that text to the static-analyzer's next derivation",
      'no adaptive toggles', 'never speaks for the firmware', 'Never repeat a change', 'When stalling, suspect the previous bypass first', 'When you have no untried change left, say so', 'natural Korean']
    const rn = norm(RULES)
    check('V6: the rule text keeps every pinned wording (ledger rule, family kit, open question, no stubs, machine silence, no repeat, stalling, no untried change, language)', typeof RULES === 'string' && PINS.every(t => rn.includes(t)), PINS.filter(t => !rn.includes(t)).join(' | '))
    check('V6: the rules are written out, not cited: no "honesty rule", no CLAUDE.md, no section sign (a subagent cannot see the plugin CLAUDE.md)', typeof RULES === 'string' && !/honesty rule|CLAUDE\.md|§/.test(RULES), (String(RULES).match(/honesty rule|CLAUDE\.md|§/g) || []).join(','))
    check('V6: ... and carry no address and none of the fields no fixer answers with', typeof RULES === 'string' && !/0x[0-9a-fA-F]{3,}/.test(RULES) && !/escalate|bypass_doc|suspect_prior_bypass|"category"/.test(RULES), '')
    check('V6: no line of the rule text starts with "Family knowledge:" or "Runbook:" (those lines are the family kit, one per prompt)', typeof RULES === 'string' && !/^(Family knowledge|Runbook):/m.test(RULES), '')
    // the constant is used at exactly the two fixer sites, and the constant it replaced is gone
    check('V6: FIXER_RULES is appended at exactly two sites (the specialist prompt and runGeneralFixer) and OPEN_QUESTION_RULE no longer exists', (code.match(/\bFIXER_RULES\b/g) || []).length - 1 === 2 && !/OPEN_QUESTION_RULE/.test(code), String((code.match(/\bFIXER_RULES\b/g) || []).length))

    // all six specialists and the last-resort fixer, over two rounds: each round asks three specialists in turn, every one declines, and the general fixer follows
    const SIX = ['fixer-memory', 'fixer-el3', 'fixer-bootflow', 'fixer-secureboot', 'fixer-storage', 'fixer-kernel']
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 2 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(),
      supervisor: n => ({ route: 'fault-classifier', prescribed_fixer: n === 1 ? 'fixer-memory' : 'fixer-secureboot' }),
      classify: n => ({ category: 'mmc_partition_scan_failed', fixer_ranking: n === 1 ? [{ fixer: 'fixer-el3', rank: 1 }, { fixer: 'fixer-bootflow', rank: 2 }] : [{ fixer: 'fixer-storage', rank: 1 }, { fixer: 'fixer-kernel', rank: 2 }] }),
      fixer: { fixer: 'x', not_mine: true, no_new_change: false }, general: { fixer: 'fixer-general', no_new_change: true } }))
    const fx = delegated(r).filter(c => /^fixer-/.test(c.agentType || ''))
    const seen = [...new Set(fx.map(c => c.agentType))].sort()
    check('V6: the run asked all six specialists and the last-resort fixer (' + fx.length + ' fixer prompts)', fx.length >= 8 && seen.join(',') === SIX.concat('fixer-general').sort().join(','), seen.join(',') + ' / ' + r.calls.map(c => c.label).join(' '))
    const without = fx.filter(c => !has(c.prompt, RULES))
    check('V6: EVERY fixer prompt the pipeline sent - each specialist and the general fixer - contains the FIXER_RULES text whole', typeof RULES === 'string' && fx.length >= 8 && without.length === 0, without.map(c => c.label).join(' '))
    const twice = fx.filter(c => c.prompt.split(RULES).length !== 2)
    check('V6: ... exactly once (no second copy of the rules in a prompt)', typeof RULES === 'string' && fx.length >= 8 && twice.length === 0, twice.map(c => c.label).join(' '))
    check('V6: ... after the context and the caller\'s own text, so the family lines in the prompt are the only "Family knowledge:" / "Runbook:" lines', fx.every(c => (c.prompt.match(/^Family knowledge: /gm) || []).length === 1 && (c.prompt.match(/^Runbook: /gm) || []).length === 1 && c.prompt.indexOf('Family knowledge: ') < c.prompt.lastIndexOf(RULES)), '')
    // nothing else in a prompt repeats a rule the shared text holds
    const rest = fx.map(c => c.prompt.split(RULES).join(''))
    check('V6: what is left of a prompt once the rules are taken out repeats none of them (no "four-field", no "feeds the stop condition")', rest.every(p => !has(p, 'four-field') && !has(p, 'feeds the stop condition')), '')
    // what stays with each caller: the specialist declines with not_mine and names its answer fields, the general fixer has neither
    const sp = fx.find(c => c.agentType === 'fixer-memory'), gn = fx.find(c => c.agentType === 'fixer-general')
    // a dead instruction removed with the legacy verify.py flow: the verifier is not offered a --pc option (verify.py parses it and never reads it)
    check('V6: the verifier prompt does not offer explicit --pc values (the entry PCs come from stage_map.json; a missing one means the item is not measured)', !/--pc\b/.test(code) && has(fn.source, 'that item is not measured: say so in'), (code.match(/.{40}--pc\b.{20}/g) || []).join(' | '))
    check('V6: the specialist prompt says how to decline (not_mine / no_new_change) and which fields to answer with; the general prompt gives neither instruction', has(sp.prompt, 'not_mine=true when this is not your area') && has(sp.prompt, 'Answer with fixer, change (type, target, description') && !has(gn.prompt, 'not_mine=true when this is not your area') && !has(gn.prompt, 'Answer with fixer, change (type'), '')
  })
}
main().then(C.finish).catch(e => { console.log('FAIL harness crashed :: ' + (e && e.stack)); process.exit(1) })
