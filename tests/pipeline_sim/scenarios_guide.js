// scenarios_guide.js <repo> - the guide pass (P1-P9), the handoffs from the other owners (H1-H8) and static facts about the source (S).
// Prints "PASS|FAIL <what>" lines. The shared setup is in common.js; tests/parts/pipeline_family.sh runs this file
// once as it is and once per mutation (SBOOT_MUTATE), and counts what it prints.
const C = require('./common.js')
const {
  path, load, run, realKit, repo, PJ, MUT, MUTATIONS,
  fn, out, check, has, fs, os, spawnSync, TMPROOT,
  tmpdirs, mktmp, W, cmdOf, sh, bashSyntax, fakePlugin, KIT,
  plugAbs, FAM_LINE, RB_LINE, COMMON, OK, mkObs, MT_STAGES, A64_STAGE,
  MT_PRIOR, responder, BASE_ARGS, prompts, delegated, byLabel, block,
} = C

async function main() {
  // ---------------------------------------------------------------- P1: family files are handed over as absolute paths that open
  await block('P1', async () => {
    const cfg = { prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ milestone: 'none', escalate_to_analyst: true }),
      supervisor: n => ({ route: n === 1 ? 'static-analyzer' : 'fault-classifier', prescribed_fixer: 'fixer-memory' }),
      classify: () => ({ category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }, { fixer: 'fixer-kernel', rank: 2 }] }),
      fixer: { fixer: 'x', not_mine: true, no_new_change: false },
      plan: { present: true, derived: true, plan: { region_base: '0x2', region_size: 8192, console_size: 2048 } } }
    const r = await run(fn, { ...BASE_ARGS, plugin_dir: repo, runtime_round_cap: 2 }, responder(cfg))
    const pathsOf = (prompt, key) => { const m = new RegExp('^' + key + ': (.*)$', 'm').exec(prompt); return m ? m[1].split(', ') : [] }
    const sites = delegated(r).filter(c => c.agentType !== 'verifier' && c.label !== 'package')
    const bad = []
    for (const c of sites) for (const p of pathsOf(c.prompt, 'Family knowledge').concat(pathsOf(c.prompt, 'Runbook'))) {
      if (p !== '(none)' && !(path.isAbsolute(p) && fs.existsSync(p))) bad.push(c.label + ' -> ' + p)
    }
    check('P1: every path on the Family knowledge / Runbook lines of every delegated prompt (' + sites.length + ') is absolute and opens', sites.length >= 8 && bad.length === 0, bad.join(' | '))
    check('P1: the lines are not vacuous (the real mediatek profile names a table and a runbook)', pathsOf(sites[0].prompt, 'Family knowledge').some(p => p.startsWith(repo + '/knowledge/')) && pathsOf(sites[0].prompt, 'Runbook')[0].startsWith(repo + '/knowledge/'), sites[0].prompt.slice(0, 200))
    check('P1: family_kit.py itself still answers plugin-relative paths (the join is the pipeline\'s)', (KIT.knowledge || []).concat([KIT.runbook]).every(p => !path.isAbsolute(p)), JSON.stringify(KIT))
    const cls = byLabel(r, /^classify-1$/)[0], sup = byLabel(r, /^supervisor-1$/)[0], an = byLabel(r, /^analyze$/)[0], bd = byLabel(r, /^build$/)[0]
    const tables = ((/Knowledge tables: (.*?)\. Do not match/.exec(cls.prompt) || [])[1] || '').split(', ').filter(Boolean)
    check('P1: the classifier\'s knowledge tables are absolute and open (' + tables.length + ')', tables.length >= 4 && tables.every(p => path.isAbsolute(p) && fs.existsSync(p)), tables.join(' | '))
    const reg = (/Registry: (\S+) - only these/.exec(cls.prompt) || [])[1], reg2 = (/domains in (\S+) - read it/.exec(sup.prompt) || [])[1], prof = (/Profile hints: (\S+) /.exec(an.prompt) || [])[1]
    check('P1: the registry (classifier, supervisor) and the profile hints (analyst) are absolute and open', [reg, reg2, prof].every(p => p && path.isAbsolute(p) && fs.existsSync(p)), JSON.stringify([reg, reg2, prof]))
    const tpl = bd.prompt.match(/\/[^\s:]*\/(?:templates|examples)\/[A-Za-z0-9_.-]+\/?/g) || []
    check('P1: the machine-build prompt names its templates and the example as absolute, existing paths (' + tpl.length + ')', tpl.length >= 3 && tpl.every(p => p.startsWith(repo + '/') && fs.existsSync(p)), tpl.join(' | '))
    const rs = await run(fn, { ...BASE_ARGS, plugin_dir: repo + '/', runtime_round_cap: 1 }, responder({ ...cfg, obs: () => mkObs() }))
    check('P1: a plugin root given with a trailing slash does not double it', !/\/\//.test(pathsOf(byLabel(rs, /^analyze$/)[0].prompt, 'Runbook')[0]), pathsOf(byLabel(rs, /^analyze$/)[0].prompt, 'Runbook')[0])
  })

  // ---------------------------------------------------------------- P2: the architecture is derived, never defaulted
  await block('P2', async () => {
    const NOARCH = { ...BASE_ARGS, runtime_round_cap: 1 }; delete NOARCH.arch
    const DET = (arch, o = {}) => ({ arch, entry_signature: arch === 'arm32' ? 'gfh' : 'vector_table', basis: ['synthetic: header declares the entry', 'synthetic: second basis line'], confidence: 'cross_checked', exit_code: 0, ...o })
    const UNK = { arch: 'unknown', entry_signature: 'none', basis: ['synthetic: no header and no vector table'], confidence: 'unconfirmed', exit_code: 0 }
    const go = (args, cfg) => run(fn, args, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, ...cfg }))
    const labels = r => r.calls.map(c => c.label)
    const detCalls = r => byLabel(r, /^detect-arch$/)
    // (1) derived arm32: used (the stage looks AArch64, so only the derived arch can pick the mixed template), journaled with its basis
    const r1 = await go(NOARCH, { detect: DET('arm32'), prior: { ...MT_PRIOR, stages: [A64_STAGE] } })
    const an1 = byLabel(r1, /^analyze$/)[0], bd1 = byLabel(r1, /^build$/)[0], dec1 = byLabel(r1, /^arch-decision$/)[0]
    check('P2: an absent arch runs stage_map.py --detect-arch on the container, once, with the path as ONE argument', detCalls(r1).length === 1 && has(detCalls(r1)[0].prompt, "stage_map.py --detect-arch '/fw/pre.img'") && has(detCalls(r1)[0].prompt, 'detect_arch_exit='), detCalls(r1)[0] && detCalls(r1)[0].prompt)
    check('P2: ... before the analyst, and the analyst is handed the derived arch with its basis', labels(r1).indexOf('detect-arch') >= 0 && labels(r1).indexOf('detect-arch') < labels(r1).indexOf('analyze') && has(an1.prompt, 'arch=arm32') && has(an1.prompt, '--arch arm32 --profile mediatek') && has(an1.prompt, 'derived by stage_map.py --detect-arch') && has(an1.prompt, 'synthetic: header declares the entry'), an1.prompt.slice(0, 400))
    check('P2: the derived arm32 builds the mixed-arch machine (not the AArch64 template) and no BLOCKED_ARCH', has(bd1.prompt, 'STRUCTURE ONLY') && r1.result?.stop_reason !== 'BLOCKED_ARCH', bd1.prompt.slice(0, 300))
    check('P2: the decision is journaled with the signature and the basis lines', dec1 && has(dec1.prompt, 'journal.sh') && has(dec1.prompt, 'decision') && has(dec1.prompt, 'gfh') && has(dec1.prompt, 'synthetic: header declares the entry'), dec1 && dec1.prompt)
    // (2) derived arm64
    const r2 = await go(NOARCH, { detect: DET('arm64'), prior: { ...MT_PRIOR, stages: [A64_STAGE] } })
    check('P2: a derived arm64 passes --arch arm64 and builds the single-architecture machine', has(byLabel(r2, /^analyze$/)[0].prompt, '--arch arm64 --profile mediatek') && !has(byLabel(r2, /^build$/)[0].prompt, 'STRUCTURE ONLY'), '')
    // (3) unknown, and the stage map then succeeds: arm64 is kept, said to be provisional, never silent
    const r3 = await go(NOARCH, { detect: UNK, prior: { ...MT_PRIOR, stages: [A64_STAGE] } })
    const an3 = byLabel(r3, /^analyze$/)[0], dec3 = byLabel(r3, /^arch-decision$/)[0]
    check('P2: unknown + a successful stage map continues with arm64 - as PROVISIONAL, with the basis and the instruction not to switch', r3.result?.stop_reason !== 'BLOCKED_ARCH' && r3.calls.some(c => c.label === 'build') && has(an3.prompt, 'arm64 is PROVISIONAL') && has(an3.prompt, 'synthetic: no header and no vector table') && has(an3.prompt, 'do not switch to another'), an3.prompt.slice(an3.prompt.indexOf('Architecture:'), an3.prompt.indexOf('Architecture:') + 700))
    check('P2: ... and the journal says unknown, not "arm64"', dec3 && has(dec3.prompt, 'unknown') && has(dec3.prompt, 'synthetic: no header and no vector table') && !has(dec3.prompt, "'arm64 (도출"), dec3 && dec3.prompt)
    const kept3 = byLabel(r3, /^arch-provisional-kept$/)[0]
    check('P2: ... and once the stage map succeeded the journal says arm64 stayed provisional (a working guess is not read as a derivation)', kept3 && has(kept3.prompt, 'decision') && has(kept3.prompt, 'arm64 임시 유지') && byLabel(r1, /^arch-provisional-kept$/).length === 0, kept3 && kept3.prompt)
    check('P2: ... and the log says out loud that the architecture was not derived', r3.logs.some(l => has(l, '아키텍처를 도출하지 못했습니다') && has(l, 'synthetic: no header and no vector table')), r3.logs.join('\n'))
    // (4)(5)(6) unknown, and the guess did not carry the derivation: BLOCKED_ARCH naming the basis, before any build
    const checkStop = (name, r, wantWhy) => {
      const d = r.result?.detail
      check('P2: unknown + ' + name + ' -> BLOCKED_ARCH that names the detect-arch basis (never BLOCKED_CARVE), nothing is built', r.result?.stop_reason === 'BLOCKED_ARCH' && has(d, 'synthetic: no header and no vector table') && has(d, 'arm64 로 임시') && has(d, wantWhy) && !r.calls.some(c => c.label === 'build' || c.label === 'qemu-tree-reset'), JSON.stringify(r.result))
      check('P2: ... recorded as a blocker row, and the note says an explicit arch resumes it', r.calls.some(c => c.label === 'record-blocker' && has(c.prompt, 'code=BLOCKED_ARCH') && has(c.prompt, 'synthetic: no header')) && has(d, 'arch 입력으로'), '')
    }
    checkStop('no entry signature (arch_supported=false)', await go(NOARCH, { detect: UNK, prior: { ...MT_PRIOR, arch_supported: false, stages: [] } }), '진입 시그니처')
    checkStop('a carve verdict', await go(NOARCH, { detect: UNK, prior: { ...MT_PRIOR, carve_is_full: false, stages: [A64_STAGE] } }), 'carve 판정')
    checkStop('an empty stage map', await go(NOARCH, { detect: UNK, prior: { ...MT_PRIOR, stages: [] } }), '스테이지 지도가 비어')
    checkStop('no analyst answer at all (nothing shows the stage map succeeded)', await go(NOARCH, { detect: UNK, override: async c => (c.label === 'analyze' ? null : undefined) }), '확인할 수 없습니다')
    // (3b) unknown, and the stage-map TOOL finds an entry signature under exactly one reading: that reading is used - here arm32, so the
    //      machine is the mixed-arch one although the old default was arm64 - PROVISIONALLY, and the journal says what each reading found
    const PROBE32 = { arm32_exit: 0, arm32_entry_stubs: 1, arm64_exit: 0, arm64_entry_stubs: 0 }
    const r3b = await go(NOARCH, { detect: UNK, probe: PROBE32, prior: { ...MT_PRIOR, stages: [A64_STAGE] } })
    const an3b = byLabel(r3b, /^analyze$/)[0], pd3b = byLabel(r3b, /^arch-probe-decision$/)[0], kept3b = byLabel(r3b, /^arch-provisional-kept$/)[0], pr3b = byLabel(r3b, /^arch-probe$/)
    check('P2: unknown + an entry signature under arm32 ONLY -> arm32 (not the arm64 default): the analyst gets --arch arm32, PROVISIONAL, and what each reading found', r3b.result?.stop_reason !== 'BLOCKED_ARCH' && has(an3b.prompt, 'arch=arm32') && has(an3b.prompt, '--arch arm32 --profile mediatek') && has(an3b.prompt, 'arm32 is PROVISIONAL') && has(an3b.prompt, 'arm32 해석: 종료코드 0 — 진입 시그니처 있음') && has(an3b.prompt, 'arm64 해석: 종료코드 0, 진입 스텁 0개 — 진입 시그니처 없음') && has(an3b.prompt, 'a reading the tool supports, not a default'), an3b.prompt.slice(an3b.prompt.indexOf('Architecture:'), an3b.prompt.indexOf('Architecture:') + 900))
    check('P2: ... so the machine is the mixed-arch one', has(byLabel(r3b, /^build$/)[0].prompt, 'STRUCTURE ONLY'), '')
    check('P2: ... the probe is ONE step before the analyst, runs BOTH readings and writes its maps beside (never over) stage_map.json', pr3b.length === 1 && labels(r3b).indexOf('arch-probe') < labels(r3b).indexOf('analyze') && labels(r3b).indexOf('arch-probe') < labels(r3b).indexOf('stage-assets') && has(cmdOf(pr3b[0]), 'for A in arm32 arm64; do') && has(cmdOf(pr3b[0]), 'stage_map.py "$IMG" --arch "$A" --quiet --out "$F"') && has(cmdOf(pr3b[0]), "OUT='/wd/08_docs'") && has(cmdOf(pr3b[0]), 'arch_probe_$A.json') && !has(cmdOf(pr3b[0]), '/wd/stage_map.json') && has(cmdOf(pr3b[0]), "IMG='/fw/pre.img'"), pr3b[0] && pr3b[0].prompt)
    check('P2: ... and the journal says the tool\'s exit codes and stub count decided it, and that detect-arch did not confirm it', pd3b && has(pd3b.prompt, 'arm32 임시') && has(pd3b.prompt, '두 해석 중 arm32 에서만 진입 시그니처가 나옴') && has(pd3b.prompt, '분석가의 응답이 아닙니다') && has(pd3b.prompt, 'detect-arch 가 확인한 값이 아니므로 임시') && has(pd3b.prompt, 'synthetic: no header and no vector table'), pd3b && pd3b.prompt)
    check('P2: ... and the final journal line states what was actually checked (the probe lines and the analyst\'s non-refuting map), not "the stage map found a signature"', kept3b && has(kept3b.prompt, 'arm32 임시 유지') && has(kept3b.prompt, 'arm32 해석: 종료코드 0 — 진입 시그니처 있음') && has(kept3b.prompt, '진입 스텁 0개') && has(kept3b.prompt, 'arch_supported 가 false 가 아니고') && !has(kept3b.prompt, 'stage_map.py 가 진입 시그니처를 찾았습니다'), kept3b && kept3b.prompt)
    // (3c) unknown, and the tool's two readings tell nothing: BLOCKED_ARCH BEFORE the analyst, before staging and before any build - whatever an arm64 map would have shown
    const A64_EXEC_NOENTRY = { name: 'stage0', arch: 'aarch64', origin: 'container', state: 'exec', entry_pc: null, confidence: 'unconfirmed' }   // what stage_map.py --arch arm64 reports for an AArch32 image
    const stopPre = async (name, probe, wants, noteWants) => {
      const r = await go(NOARCH, { detect: UNK, probe, prior: { ...MT_PRIOR, arch_supported: true, carve_is_full: true, stages: [A64_EXEC_NOENTRY] } })
      const d = r.result?.detail || ''
      check('P2: unknown + ' + name + ' -> BLOCKED_ARCH naming the detect-arch basis and what each reading found, before the analyst, the asset staging and any build (an arm64 map that "succeeded" does not change it)', r.result?.stop_reason === 'BLOCKED_ARCH' && has(d, 'synthetic: no header and no vector table') && wants.every(w => has(d, w)) && !r.calls.some(c => c.label === 'analyze' || c.label === 'stage-assets' || c.label === 'build' || c.label === 'qemu-tree-reset'), JSON.stringify(r.result))
      check('P2: ... (' + name + ') recorded as a blocker row and the note says an explicit arch resumes it', r.calls.some(c => c.label === 'record-blocker' && has(c.prompt, 'code=BLOCKED_ARCH')) && has(d, 'arch 입력으로 arm32 또는 arm64 를 명시하면') && noteWants.every(w => has(r.result?.note, w)), r.result?.note)
      check('P2: ... (' + name + ') never the arm64 provisional text of the old path', !has(d, '로 임시 진행했으나') && !r.logs.some(l => has(l, '진입 시그니처를 찾았습니다')), d)
      return r
    }
    const rNone = await stopPre('no entry signature under either reading', { arm32_exit: 3, arm32_entry_stubs: 0, arm64_exit: 0, arm64_entry_stubs: 0 }, ['어느 쪽에서도 진입 시그니처', 'arm32 해석: 종료코드 3 — 진입 시그니처 없음', 'arm64 해석: 종료코드 0, 진입 스텁 0개 — 진입 시그니처 없음', '기본값으로 삼지 않으므로', '도구의 결손'], ['도구의 결손'])
    await stopPre('an entry signature under BOTH readings', { arm32_exit: 0, arm32_entry_stubs: 1, arm64_exit: 0, arm64_entry_stubs: 2 }, ['양쪽 모두에서 진입 시그니처가 나와 어느 쪽인지 정하지 못했습니다', '기본값을 고르지 않고 정지합니다'], ['도출기가 어느 쪽인지 정하지 못했습니다', '펌웨어가 실행 불가하다는 판정이 아닙니다'])
    for (const [name, probe] of [['no probe answer at all', null], ['a failed run (exit 1, no map written)', { arm32_exit: 1, arm32_entry_stubs: null, arm64_exit: 1, arm64_entry_stubs: null }], ['an arm64 map the stub count could not be read from', { arm32_exit: 3, arm32_entry_stubs: 0, arm64_exit: 0, arm64_entry_stubs: null }], ['one reading that failed while the other found a signature', { arm32_exit: 0, arm32_entry_stubs: 1, arm64_exit: 2, arm64_entry_stubs: null }]]) {
      await stopPre(name, probe, ['그 결과를 확인하지 못했습니다', '시그니처가 없다고 판단할 수 없어 정지합니다', 'arch_probe_<arch>.err'], ['도구의 결손'])
    }
    // the stop text is recorded WHOLE: the detect-arch basis and the way to resume are exactly what a 400-character cut drops
    const UNK_LONG = { ...UNK, basis: Array.from({ length: 6 }, (_, i) => 'synthetic basis line ' + (i + 1) + ': ' + 'x'.repeat(70)) }
    const rLong = await go(NOARCH, { detect: UNK_LONG, probe: { arm32_exit: 3, arm32_entry_stubs: 0, arm64_exit: 0, arm64_entry_stubs: 0 } })
    const dLong = rLong.result?.detail || '', recLong = byLabel(rLong, /^record-blocker$/)[0], decLong = byLabel(rLong, /^arch-decision$/)[0], pdLong = byLabel(rLong, /^arch-probe-decision$/)[0]
    check('P2: the BLOCKED_ARCH detail is longer than the 400 characters shq() keeps (' + dLong.length + ')', dLong.length > 400 && has(dLong, 'synthetic basis line 6') && has(dLong, '이어서 진행합니다'), String(dLong.length))
    check('P2: ... and the blocker row and the journal note carry it WHOLE (the last basis line and the resume sentence are in the emitted command)', recLong && has(recLong.prompt, 'detail=' + "'" + dLong + "'") && has(recLong.prompt, "note '하드 블로커 BLOCKED_ARCH: " + dLong + "'"), recLong && recLong.prompt.slice(-300))
    check('P2: ... and so do the arch decisions (all six basis lines, none cut)', decLong && pdLong && [1, 2, 3, 4, 5, 6].every(i => has(decLong.prompt, 'synthetic basis line ' + i + ': ') && has(pdLong.prompt, 'synthetic basis line ' + i + ': ')) && has(decLong.prompt, 'x'.repeat(70) + "'"), decLong && decLong.prompt.slice(-200))
    // (7) a resolved arch keeps the old verdicts: a carve is a carve
    const r7 = await go(NOARCH, { detect: DET('arm64'), prior: { ...MT_PRIOR, carve_is_full: false, stages: [A64_STAGE] } })
    check('P2: with a derived arch a carve verdict stays BLOCKED_CARVE', r7.result?.stop_reason === 'BLOCKED_CARVE', JSON.stringify(r7.result))
    // (8) an explicit arch wins, is journaled as given, and nothing is derived
    const r8 = await go({ ...BASE_ARGS, runtime_round_cap: 1 }, { detect: DET('arm64') })
    check('P2: an explicit arch is used as given: no detect-arch call, journaled as an input', detCalls(r8).length === 0 && has(byLabel(r8, /^analyze$/)[0].prompt, '--arch arm32') && has(byLabel(r8, /^analyze$/)[0].prompt, 'was given as an input') && has((byLabel(r8, /^arch-decision$/)[0] || {}).prompt, '입력으로 지정') && byLabel(r8, /^arch-provisional-kept$/).length === 0, labels(r8).slice(0, 12).join(' '))
    check('P2: a derived or given arch needs no second reading: the two-reading probe runs only when detect-arch could not decide', byLabel(r1, /^arch-probe$/).length === 0 && byLabel(r2, /^arch-probe$/).length === 0 && byLabel(r8, /^arch-probe$/).length === 0 && byLabel(r3, /^arch-probe$/).length === 1, '')
    // (9) auto / unknown / an unrecognised value all mean "derive"
    for (const v of ['auto', 'unknown', 'AUTO', 'x86']) {
      const r = await go({ ...NOARCH, arch: v }, { detect: DET('arm32') })
      check('P2: arch input "' + v + '" is derived, not taken', detCalls(r).length === 1 && has(byLabel(r, /^analyze$/)[0].prompt, '--arch arm32') && (v !== 'x86' || r.logs.some(l => has(l, '"x86"') && has(l, '쓰지 않고 도출'))), labels(r).slice(0, 10).join(' '))
    }
    // (10) a failed or senseless detection is "unknown", with its own reason in the basis
    const rx = await go(NOARCH, { detect: { exit_code: 2 } })
    check('P2: detect-arch exit 2 (unreadable image) is unknown with that reason, never a default', has(byLabel(rx, /^analyze$/)[0].prompt, 'arm64 is PROVISIONAL') && has(byLabel(rx, /^analyze$/)[0].prompt, '종료코드 2'), byLabel(rx, /^analyze$/)[0].prompt.slice(0, 300))
    const rn = await go(NOARCH, { detect: null })
    check('P2: no detect-arch answer at all is unknown with that reason', has(byLabel(rn, /^analyze$/)[0].prompt, 'arm64 is PROVISIONAL') && has(byLabel(rn, /^analyze$/)[0].prompt, '결과를 얻지 못했습니다'), '')
    const rw = await go(NOARCH, { detect: DET('riscv') })
    check('P2: an answer that is not arm32 / arm64 / unknown is unknown', has(byLabel(rw, /^analyze$/)[0].prompt, 'arm64 is PROVISIONAL') && has(byLabel(rw, /^analyze$/)[0].prompt, 'riscv'), '')
    check('P2: session-open does not claim an architecture it has not derived', has(byLabel(r1, /^session-open$/)[0].prompt, 'arch=auto') && !has(byLabel(r1, /^session-open$/)[0].prompt, 'arch=arm64'), byLabel(r1, /^session-open$/)[0].prompt.slice(0, 200))
  })

  // ---------------------------------------------------------------- P3: the kernel assets are staged by the pipeline, before the analyst
  await block('P3', async () => {
    const go = (args, cfg) => run(fn, args, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, ...cfg }))
    const labels = r => r.calls.map(c => c.label)
    const A2 = { ...BASE_ARGS, runtime_round_cap: 1 }
    const r1 = await go(A2, {})
    const st = byLabel(r1, /^stage-assets$/), an = byLabel(r1, /^analyze$/)[0]
    check('P3: a default (F2) run stages the kernel assets with extract_boot_assets.sh, once, before the analyst', st.length === 1 && labels(r1).indexOf('stage-assets') < labels(r1).indexOf('analyze') && has(st[0].prompt, 'scripts/extract_boot_assets.sh') && has(st[0].prompt, '02_unpacked'), st[0] && st[0].prompt.slice(0, 300))
    check('P3: the analyst is told what was staged and that nobody has to extract anything', has(an.prompt, 'staged from 02_unpacked/boot.img by scripts/extract_boot_assets.sh (Image yes, dtb yes, initrd yes, super no)') && has(an.prompt, 'The PIPELINE staged them') && has(an.prompt, 'never tell the user to run that script') && !has(an.prompt, 'if already staged'), an.prompt.slice(an.prompt.indexOf('Boot assets'), an.prompt.indexOf('Boot assets') + 500))
    const dec = byLabel(r1, /^assets-decision$/)[0]
    check('P3: the staging result is journaled', dec && has(dec.prompt, 'journal.sh') && has(dec.prompt, '커널 자산 적재') && has(dec.prompt, 'staged from 02_unpacked/boot.img'), dec && dec.prompt)
    check('P3: staged assets are not a blocker (assets_ok true / null)', r1.result?.stop_reason !== 'BLOCKED_ASSET', JSON.stringify(r1.result?.stop_reason))
    // F1: nothing to stage
    const rf = await go({ ...A2, target: 'F1' }, {})
    check('P3: F1 stages nothing and says why', byLabel(rf, /^stage-assets$/).length === 0 && has(byLabel(rf, /^analyze$/)[0].prompt, 'not staged: the target is F1'), '')
    // the package truly lacks them after staging -> BLOCKED_ASSET, with what staging did
    const rb = await go(A2, { assets: { staging: 'no_boot_img', exit_code: null, image: false, dtb: false, initrd: false, super: false }, prior: { ...MT_PRIOR, assets_ok: false, stages: [MT_STAGES[0]] } })
    check('P3: assets absent AFTER staging -> BLOCKED_ASSET that reports the staging result, before any build', rb.result?.stop_reason === 'BLOCKED_ASSET' && has(rb.result?.detail, '적재한 뒤에도') && has(rb.result?.detail, 'NOT staged: the package has no 02_unpacked/boot.img') && !rb.calls.some(c => c.label === 'build'), JSON.stringify(rb.result))
    check('P3: ... and its note no longer asks a person to extract anything', has(rb.result?.note, '파이프라인이 02_unpacked 에서 적재') && !has(rb.result?.note, '자산을 확보한 뒤'), rb.result?.note)
    const rfail = await go(A2, { assets: { staging: 'failed', exit_code: 7, image: false, dtb: false, initrd: false, super: false, log: '/wd/08_docs/assets_staging.txt' }, prior: { ...MT_PRIOR, assets_ok: false, stages: [MT_STAGES[0]] } })
    check('P3: a failed staging is reported with its exit code and log', rfail.result?.stop_reason === 'BLOCKED_ASSET' && has(rfail.result?.detail, 'staging FAILED (exit 7; log /wd/08_docs/assets_staging.txt)'), JSON.stringify(rfail.result))
    const rnone = await go(A2, { assets: null })
    check('P3: no staging answer is warned about and the analyst still judges the assets itself', rnone.logs.some(l => has(l, '적재 결과를 얻지 못했습니다')) && has(byLabel(rnone, /^analyze$/)[0].prompt, 'could not report the staging result'), '')
    const rpar = await go(A2, { assets: { staging: 'partial', exit_code: 4, image: true, dtb: true, initrd: true, super: false, log: '/wd/08_docs/assets_staging.txt' } })
    check('P3: a super that could not be unpacked is a PARTIAL staging (the kernel side is there) - told to the analyst, not a blocker by itself', has(byLabel(rpar, /^analyze$/)[0].prompt, 'staged PARTIALLY') && has(byLabel(rpar, /^analyze$/)[0].prompt, 'Image yes') && rpar.result?.stop_reason !== 'BLOCKED_ASSET', byLabel(rpar, /^analyze$/)[0].prompt.slice(byLabel(rpar, /^analyze$/)[0].prompt.indexOf('Boot assets'), byLabel(rpar, /^analyze$/)[0].prompt.indexOf('Boot assets') + 300))
    const rsum = await go(A2, { assets: { staging: 'staged', exit_code: 0, image: true, dtb: false, initrd: true, super: true, summary: 'assets: image=1 dtb=0 initrd=1 super=sparse' } })
    check('P3: the script\'s own summary line reaches the analyst (a sparse super that was not converted is visible)', has(byLabel(rsum, /^analyze$/)[0].prompt, 'script: assets: image=1 dtb=0 initrd=1 super=sparse'), '')
  })

  // ---------------------------------------------------------------- X8: the staging command, executed (stand-in script, then the real one)
  await block('X8', async () => {
    const STAND = '#!/usr/bin/env bash\necho "$# $1|$2|$3|$4" >> "$1/calls.txt"\nif [ -n "$FAKE_FAIL" ]; then echo boom; exit 7; fi\nmkdir -p "$1/fw"; printf K > "$1/fw/Image"; printf D > "$1/fw/board.dtb"\nif [ -n "$3" ]; then printf S > "$1/fw/super.img"; fi\necho "assets: image=1 dtb=1 initrd=0 super=raw"\nexit ${FAKE_EXIT:-0}\n'
    const plug = fakePlugin({ 'extract_boot_assets.sh': STAND })
    const wd = mktmp('ws')
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: plug, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }))
    const call = r.calls.find(c => c.label === 'stage-assets')
    check('P3: the staging command parses as bash', !!call && bashSyntax(call) === '', call && bashSyntax(call))
    const kv = o => Object.fromEntries(o.stdout.split('\n').filter(l => l.includes('=')).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
    const calls = () => (fs.existsSync(path.join(wd, 'calls.txt')) ? fs.readFileSync(path.join(wd, 'calls.txt'), 'utf8').split('\n').filter(Boolean) : [])
    const boot = path.join(wd, '02_unpacked', 'boot.img')
    const o0 = sh(cmdOf(call), wd)
    check('P3: no boot.img in 02_unpacked -> assets_staging=no_boot_img and the script is not called', kv(o0).assets_staging === 'no_boot_img' && calls().length === 0 && kv(o0).staged_image === 'no', o0.stdout + o0.stderr)
    W(boot, 'BOOT'); W(path.join(wd, '02_unpacked', 'super.img'), 'SUPER'); W(path.join(wd, '02_unpacked', 'x.dtb'), 'DTB')
    const o1 = sh(cmdOf(call), wd), k1 = kv(o1)
    check('P3: boot.img + super + dtb -> the script gets <workdir> <boot.img> <super> <dtb>, and the result is reported', k1.assets_staging === 'staged' && k1.assets_exit === '0' && calls().length === 1 && calls()[0] === ['4 ' + wd, boot, path.join(wd, '02_unpacked', 'super.img'), path.join(wd, '02_unpacked', 'x.dtb')].join('|') && k1.staged_image === 'yes' && k1.staged_dtb === 'yes' && k1.staged_super === 'yes' && k1.staged_initrd === 'no', o1.stdout + o1.stderr + JSON.stringify(calls()))
    check('P3: the unpack output is kept in 08_docs/assets_staging.txt, and the script\'s own last line is relayed', fs.existsSync(path.join(wd, '08_docs', 'assets_staging.txt')) && k1.staging_log === path.join(wd, '08_docs', 'assets_staging.txt') && k1.script_summary === 'assets: image=1 dtb=1 initrd=0 super=raw', JSON.stringify(k1))
    const o2 = sh(cmdOf(call), wd)
    check('P3: it is run every time (the script is the idempotent one): a second run stages again and still reports', kv(o2).assets_staging === 'staged' && calls().length === 2 && kv(o2).staged_image === 'yes', o2.stdout + o2.stderr)
    fs.rmSync(path.join(wd, '02_unpacked', 'super.img')); fs.rmSync(path.join(wd, '02_unpacked', 'x.dtb'))
    W(path.join(wd, '02_unpacked', 'super.img.lz4'), 'LZ4')
    const o4 = sh(cmdOf(call), wd)
    check('P3: a super.img.lz4 is handed over as the super; a missing dtb is an empty argument', calls().length === 3 && calls()[2].endsWith('|' + path.join(wd, '02_unpacked', 'super.img.lz4') + '|') && kv(o4).super_source === path.join(wd, '02_unpacked', 'super.img.lz4'), JSON.stringify(calls()))
    fs.rmSync(path.join(wd, '02_unpacked', 'super.img.lz4'))
    const o6 = sh(cmdOf(call), wd)
    check('P3: neither super nor dtb -> two empty arguments, and super_source says none', calls().length === 4 && calls()[3].endsWith('||') && kv(o6).super_source === 'none', JSON.stringify(calls()))
    const o5 = sh(cmdOf(call), wd, { FAKE_FAIL: '1' }), k5 = kv(o5)
    check('P3: a failing script -> assets_staging=failed with its exit code and the log tail on stderr', k5.assets_staging === 'failed' && k5.assets_exit === '7' && has(o5.stderr, 'boom'), o5.stdout + o5.stderr)
    const o7 = sh(cmdOf(call), wd, { FAKE_EXIT: '4' }), k7 = kv(o7)
    check('P3: exit 4 (the super could not be unpacked, the boot side is staged) -> partial, not failed', k7.assets_staging === 'partial' && k7.assets_exit === '4' && k7.staged_image === 'yes', o7.stdout + o7.stderr)
  })
  await block('R3', async () => {
    // the emitted staging command against the REAL extract_boot_assets.sh, on a synthetic Android boot image (header v0, python fallback)
    const wd = mktmp('ws')
    const ps = 4096, kernel = Buffer.from('synthetic-kernel-bytes-'.padEnd(64, 'x'))
    const hdr = Buffer.alloc(ps); hdr.write('ANDROID!', 0, 'latin1'); hdr.writeUInt32LE(kernel.length, 0x08); hdr.writeUInt32LE(0, 0x10); hdr.writeUInt32LE(ps, 0x24); hdr.writeUInt32LE(0, 0x28)
    fs.mkdirSync(path.join(wd, '02_unpacked'), { recursive: true })
    fs.writeFileSync(path.join(wd, '02_unpacked', 'boot.img'), Buffer.concat([hdr, kernel, Buffer.alloc(ps - kernel.length)]))
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: repo, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }))
    const call = r.calls.find(c => c.label === 'stage-assets')
    const o = sh(cmdOf(call), wd, { UNPACK_BOOTIMG: '/nonexistent/unpack_bootimg', PYTHONDONTWRITEBYTECODE: '1' })
    check('R: the emitted staging command, run against the real extract_boot_assets.sh, stages the kernel from a boot image', has(o.stdout, 'assets_staging=staged') && has(o.stdout, 'staged_image=yes') && fs.existsSync(path.join(wd, 'fw', 'Image')) && fs.readFileSync(path.join(wd, 'fw', 'Image')).equals(kernel), o.stdout + o.stderr)
    check('R: the real script\'s own last line is relayed', has(o.stdout, 'script_summary=assets: image=1'), o.stdout)
    const o2 = sh(cmdOf(call), wd, { UNPACK_BOOTIMG: '/nonexistent/unpack_bootimg' })
    check('R: a second run over the same workspace stages again without harm (the script is idempotent)', has(o2.stdout, 'assets_staging=staged') && fs.readFileSync(path.join(wd, 'fw', 'Image')).equals(kernel), o2.stdout + o2.stderr)
    // a file that is not an Android boot image: the script says so (exit 3), the pipeline reports failed and keeps fw/ as it was
    W(path.join(wd, '02_unpacked', 'boot.img'), 'this is not a boot image'.padEnd(8192, 'x'))
    const o3 = sh(cmdOf(call), wd, { UNPACK_BOOTIMG: '/nonexistent/unpack_bootimg' })
    check('R: a boot.img that is not one -> failed with the script\'s exit 3, and the earlier fw/Image is kept', has(o3.stdout, 'assets_staging=failed') && has(o3.stdout, 'assets_exit=3') && fs.readFileSync(path.join(wd, 'fw', 'Image')).equals(kernel), o3.stdout + o3.stderr)
  })

  await block('R4', async () => {
    // the emitted detect-arch command against the REAL stage_map.py, on synthetic images (no firmware bytes), and
    // what the pipeline then does with the real answers
    const wd = mktmp('ws')
    if (!fs.readFileSync(path.join(repo, 'scripts', 'stage_map.py'), 'utf8').includes('--detect-arch')) {
      out.push('NOTE R4: scripts/stage_map.py has no --detect-arch - the seam with the real script was not checked')
      return
    }
    const w32 = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n >>> 0); return b }
    const stub = Buffer.concat([0x14000001, 0x10000000, 0xD5384241, 0xD51EC000].map(w32))
    const plain = n => Buffer.concat(Array.from({ length: n / 4 }, () => w32(0xA9BF7BFD)))
    const a64 = path.join(wd, "pre loader's a64.bin"), noise = path.join(wd, 'noise.bin'), nothing = path.join(wd, "no such 'file'.bin")
    fs.writeFileSync(a64, Buffer.concat([stub, plain(0x8000 - 16), stub, plain(0x8000 - 16)]))
    fs.writeFileSync(noise, Buffer.alloc(4096, 0x78))
    const mkArgs = file => { const a = { ...BASE_ARGS, workdir: wd, plugin_dir: repo, bootloader_path: file, runtime_round_cap: 1 }; delete a.arch; return a }
    const cfgOf = det => ({ detect: det, prior: { ...MT_PRIOR, stages: [A64_STAGE] }, obs: () => mkObs() })
    const emitted = async file => cmdOf((await run(fn, mkArgs(file), responder(cfgOf(undefined)))).calls.find(c => c.label === 'detect-arch'))
    const exec = async file => { const o = sh(await emitted(file), wd, { PYTHONDONTWRITEBYTECODE: '1' }); const j = o.stdout.split('\n').find(l => l.startsWith('{')); return { o, json: j ? JSON.parse(j) : null } }
    const A = await exec(a64), N = await exec(noise), X = await exec(nothing)
    check('R: the real --detect-arch answers the contract through the emitted command (a path with a space and a quote is ONE argument)', A.json && ['arm32', 'arm64', 'unknown'].includes(A.json.arch) && typeof A.json.entry_signature === 'string' && Array.isArray(A.json.basis) && A.json.basis.length > 0 && ['derived', 'cross_checked', 'unconfirmed'].includes(A.json.confidence) && has(A.o.stdout, 'detect_arch_exit=0'), A.o.stdout + A.o.stderr)
    check('R: a synthetic AArch64 start-up stub reads as arm64; noise reads as unknown with exit 0 (unknown is an answer, not a failure)', A.json && A.json.arch === 'arm64' && N.json && N.json.arch === 'unknown' && has(N.o.stdout, 'detect_arch_exit=0'), JSON.stringify([A.json && A.json.arch, N.json && N.json.arch]))
    check('R: an unreadable file prints no JSON and the command reports exit 2', X.json === null && has(X.o.stdout, 'detect_arch_exit=2'), X.o.stdout + X.o.stderr)
    // the real answers, relayed the way the agent would relay them, drive the pipeline
    const rA = await run(fn, mkArgs(a64), responder(cfgOf({ ...A.json, exit_code: 0 })))
    check('R: the real arm64 answer is used (--arch arm64, no provisional note)', has(byLabel(rA, /^analyze$/)[0].prompt, '--arch arm64 --profile mediatek') && !has(byLabel(rA, /^analyze$/)[0].prompt, 'PROVISIONAL'), '')
    // ---- an "unknown" container and the two readings, against the REAL stage_map.py. The old rule was "draw an arm64 map and keep arm64 if
    //      it succeeds" - and the arm64 map ALWAYS succeeds (exit 0, an exec stage), for an AArch32 image and for random bytes alike.
    const A32 = n => Array.from({ length: n / 8 }, () => Buffer.concat([w32(0xE92D4010), w32(0xE8BD8010)]))   // push {r4,lr} / pop {r4,pc}
    const vt = Buffer.concat(Array.from({ length: 8 }, () => w32(0xEAFFFFFE)))                                  // eight `b .` slots: an ARM vector table
    const a32plain = path.join(wd, "a32 plain's.bin"), a32vt = path.join(wd, 'a32vt.bin'), both = path.join(wd, 'both.bin')
    fs.writeFileSync(a32plain, Buffer.concat(A32(0x4000)))
    fs.writeFileSync(a32vt, Buffer.concat([vt, ...A32(0x4000)]))
    fs.writeFileSync(both, Buffer.concat([vt, ...A32(0x4000), stub, ...A32(0x4000)]))
    const UNK_REAL = j => ({ ...j, exit_code: 0 })
    const probeOf = async (file, detectJson) => {          // the command the pipeline emitted for the probe, run for real, and what it printed
      const r = await run(fn, mkArgs(file), responder(cfgOf(UNK_REAL(detectJson))))
      const call = r.calls.find(c => c.label === 'arch-probe')
      const o = call ? sh(cmdOf(call), wd, { PYTHONDONTWRITEBYTECODE: '1' }) : { status: -1, stdout: '', stderr: 'no arch-probe call' }
      const g = k => { const m = new RegExp('probe_' + k + ' exit=(\\d+) entry_stubs=(\\S+)').exec(o.stdout); return m ? [Number(m[1]), m[2] === '-' ? null : Number(m[2])] : [null, null] }
      const [e32, c32] = g('arm32'), [e64, c64] = g('arm64')
      return { r, call, o, probe: { arm32_exit: e32, arm32_entry_stubs: c32, arm64_exit: e64, arm64_entry_stubs: c64 } }
    }
    const readMap = n => { try { return JSON.parse(fs.readFileSync(path.join(wd, '08_docs', 'arch_probe_' + n + '.json'), 'utf8')) } catch (e) { return null } }
    const DET_UNK = { arch: 'unknown', entry_signature: 'none', basis: ['real detect-arch said unknown'], confidence: 'unconfirmed' }
    const detOf = async file => (await exec(file)).json
    // (a) AArch32 code with no entry signature (the finding's case): detect-arch unknown, arm32 exit 3, and the arm64 map "succeeds"
    const dPlain = await detOf(a32plain)
    const P1 = await probeOf(a32plain, dPlain)
    const m64 = readMap('arm64'), m32 = readMap('arm32')
    check('R: the real detect-arch calls an AArch32 image with no entry signature "unknown"', dPlain && dPlain.arch === 'unknown', JSON.stringify(dPlain))
    check('R: ... and under --arch arm64 the REAL tool exits 0 with arch_supported true, an exec stage and NO entry point - the "map succeeded" signal the old path trusted', m64 && m64.arch_supported === true && m64.entry_stubs.length === 0 && m64.stages.length === 1 && m64.stages[0].state === 'exec' && m64.stages[0].arch === 'aarch64' && m64.stages[0].entry_pc === null && m64.stages[0].confidence === 'unconfirmed', JSON.stringify(m64 && { s: m64.arch_supported, st: m64.entry_stubs.length, stages: m64.stages.map(x => [x.state, x.entry_pc, x.confidence]) }))
    check('R: ... while arm32 exits 3 (arch_supported false, no stage): the emitted probe command reports both, with the stub count read out of the real JSON', m32 && m32.arch_supported === false && JSON.stringify(P1.probe) === JSON.stringify({ arm32_exit: 3, arm32_entry_stubs: 0, arm64_exit: 0, arm64_entry_stubs: 0 }), P1.o.stdout + P1.o.stderr)
    const prior64 = { ...MT_PRIOR, arch_supported: true, stages: m64 ? m64.stages.map(x => ({ name: x.name, arch: x.arch, origin: x.origin, state: x.state, entry_pc: x.entry_pc, confidence: x.confidence })) : [] }
    const rPlain = await run(fn, mkArgs(a32plain), responder({ ...cfgOf(UNK_REAL(dPlain)), probe: P1.probe, prior: prior64 }))
    check('R: fed that real output (and an analyst reporting the real arm64 stage list as a SUCCESS), the pipeline stops with BLOCKED_ARCH before the analyst - it does not keep arm64 and build', rPlain.result?.stop_reason === 'BLOCKED_ARCH' && has(rPlain.result?.detail, 'arm32 해석: 종료코드 3 — 진입 시그니처 없음') && has(rPlain.result?.detail, 'arm64 해석: 종료코드 0, 진입 스텁 0개 — 진입 시그니처 없음') && has(rPlain.result?.detail, dPlain.basis[dPlain.basis.length - 1].slice(0, 20)) && !rPlain.calls.some(c => c.label === 'analyze' || c.label === 'build') && !rPlain.logs.some(l => has(l, '진입 시그니처를 찾았습니다')), JSON.stringify(rPlain.result && rPlain.result.detail))
    // (b) random bytes and (c) a real vector table, a real AArch64 stub, (d) both, (e) an unreadable file
    const dNoise = await detOf(noise)
    const P2n = await probeOf(noise, dNoise)
    const wd2 = mktmp('wsrec')                              // the run whose recorded commands are executed for real below
    const rNoise = await run(fn, { ...mkArgs(noise), workdir: wd2 }, responder({ ...cfgOf(UNK_REAL(dNoise)), probe: P2n.probe }))
    check('R: random bytes: the probe reads exit 3 / 0 stubs and 0 / 0 stubs, and the run stops with BLOCKED_ARCH carrying the real detect-arch basis', JSON.stringify(P2n.probe) === JSON.stringify({ arm32_exit: 3, arm32_entry_stubs: 0, arm64_exit: 0, arm64_entry_stubs: 0 }) && rNoise.result?.stop_reason === 'BLOCKED_ARCH' && has(rNoise.result?.detail, dNoise.basis[dNoise.basis.length - 1].slice(0, 20)) && !rNoise.calls.some(c => c.label === 'build'), JSON.stringify(P2n.probe) + JSON.stringify(rNoise.result))
    const P3 = await probeOf(a32vt, DET_UNK)
    check('R: an image with a real ARM vector table at its start: arm32 exits 0 with one stub, arm64 has none -> exactly ONE reading has a signature', P3.probe.arm32_exit === 0 && P3.probe.arm32_entry_stubs >= 1 && P3.probe.arm64_exit === 0 && P3.probe.arm64_entry_stubs === 0, JSON.stringify(P3.probe))
    const r3 = await run(fn, mkArgs(a32vt), responder({ ...cfgOf(UNK_REAL(DET_UNK)), probe: P3.probe }))
    check('R: ... and the pipeline (detect-arch unknown) uses arm32 PROVISIONALLY and builds the mixed-arch machine - where the old default built the AArch64 one', has(byLabel(r3, /^analyze$/)[0].prompt, '--arch arm32 --profile mediatek') && has(byLabel(r3, /^analyze$/)[0].prompt, 'arm32 is PROVISIONAL') && has(byLabel(r3, /^build$/)[0].prompt, 'STRUCTURE ONLY'), byLabel(r3, /^analyze$/)[0].prompt.slice(0, 300))
    const P4 = await probeOf(a64, DET_UNK)
    check('R: a real AArch64 start-up stub: arm32 exits 3, arm64 lists stubs (an exit code of 0 under arm64 means nothing; the stub count does)', P4.probe.arm32_exit === 3 && P4.probe.arm64_exit === 0 && P4.probe.arm64_entry_stubs >= 1, JSON.stringify(P4.probe))
    const r4 = await run(fn, mkArgs(a64), responder({ ...cfgOf(UNK_REAL(DET_UNK)), probe: P4.probe }))
    check('R: ... and the pipeline uses arm64, provisionally, with the single-architecture machine', has(byLabel(r4, /^analyze$/)[0].prompt, '--arch arm64 --profile mediatek') && has(byLabel(r4, /^analyze$/)[0].prompt, 'arm64 is PROVISIONAL') && !has(byLabel(r4, /^build$/)[0].prompt, 'STRUCTURE ONLY'), '')
    const P5 = await probeOf(both, DET_UNK)
    const r5 = await run(fn, mkArgs(both), responder({ ...cfgOf(UNK_REAL(DET_UNK)), probe: P5.probe }))
    check('R: a vector table AND an AArch64 stub: both readings have a signature -> BLOCKED_ARCH (not decided), no default picked', P5.probe.arm32_exit === 0 && P5.probe.arm64_entry_stubs >= 1 && r5.result?.stop_reason === 'BLOCKED_ARCH' && has(r5.result?.detail, '양쪽 모두에서 진입 시그니처가 나와') && !r5.calls.some(c => c.label === 'analyze' || c.label === 'build'), JSON.stringify(P5.probe) + JSON.stringify(r5.result))
    const P6 = await probeOf(nothing, { exit_code: 2 })
    const rX = await run(fn, mkArgs(nothing), responder({ ...cfgOf({ exit_code: 2 }), probe: P6.probe }))
    check('R: an unreadable container: the real tool fails (no map written, stub count "-" read as null), and the run stops with BLOCKED_ARCH that names detect-arch\'s exit 2 and says it cannot conclude "no signature"', P6.probe.arm32_exit !== 0 && P6.probe.arm32_exit !== 3 && P6.probe.arm32_entry_stubs === null && rX.result?.stop_reason === 'BLOCKED_ARCH' && has(rX.result?.detail, '종료코드 2') && has(rX.result?.detail, '시그니처가 없다고 판단할 수 없어 정지합니다') && !rX.calls.some(c => c.label === 'analyze'), JSON.stringify(P6.probe) + JSON.stringify(rX.result))
    // (f) what the pipeline recorded, run for real through the repo's own record.py and journal.sh: the stop text is whole
    const recCall = byLabel(rNoise, /^record-blocker$/)[0], dNoiseText = rNoise.result?.detail || ''
    const orec = sh(cmdOf(recCall), wd2, { PYTHONDONTWRITEBYTECODE: '1' })
    const blockerRows = fs.existsSync(path.join(wd2, 'blockers.jsonl')) ? fs.readFileSync(path.join(wd2, 'blockers.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l)) : []
    const jtext = fs.existsSync(path.join(wd2, 'JOURNAL.md')) ? fs.readFileSync(path.join(wd2, 'JOURNAL.md'), 'utf8') : ''
    check('R: the BLOCKED_ARCH detail (' + dNoiseText.length + ' characters, past the 400 shq() keeps) lands WHOLE in blockers.jsonl and JOURNAL.md through the real record.py and journal.sh', orec.status === 0 && dNoiseText.length > 400 && blockerRows.length === 1 && blockerRows[0].detail === dNoiseText && has(jtext, dNoiseText) && has(blockerRows[0].detail, '이어서 진행합니다'), orec.stdout.slice(0, 200) + orec.stderr.slice(0, 300) + ' len=' + (blockerRows[0] && blockerRows[0].detail.length))
    const decCall = byLabel(rNoise, /^arch-probe-decision$/)[0]
    const odec = sh(cmdOf(decCall), wd2, { PYTHONDONTWRITEBYTECODE: '1' })
    const jtext3 = fs.existsSync(path.join(wd2, 'JOURNAL.md')) ? fs.readFileSync(path.join(wd2, 'JOURNAL.md'), 'utf8') : ''
    check('R: ... and the arch decision journals the same whole text (real journal.sh): the text now appears in a decision line too', odec.status === 0 && (jtext3.split(dNoiseText).length - 1) >= 2 && has(jtext3, '이어서 진행합니다'), odec.stdout.slice(0, 200) + odec.stderr.slice(0, 300) + ' occurrences=' + (jtext3.split(dNoiseText).length - 1))
  })

  // ---------------------------------------------------------------- P4: a resumed workspace numbers its rounds on
  await block('P4', async () => {
    const seen = []
    const mk = (base, cap, extra) => run(fn, { ...BASE_ARGS, runtime_round_cap: cap }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      roundBase: base, obs: n => { seen.push(n); return mkObs({ milestone: 'none' }) }, ...extra }))
    const runs = r => r.calls.filter(c => /^run-\d+$/.test(c.label)).map(c => c.label)
    const r1 = await mk({ last_round: 5, rounds_jsonl: 5, logs: 4 }, 2)
    check('P4: a workspace that holds rounds up to 5 continues at run-6 (nothing earlier is overwritten)', JSON.stringify(runs(r1)) === JSON.stringify(['run-6', 'run-7']), runs(r1).join(','))
    check('P4: the runtime cap counts THIS invocation\'s rounds (2), not the absolute number', r1.result?.stop_reason === 'RUNTIME_ROUND_CAP' && r1.result?.rounds_this_invocation === 2 && r1.result?.rounds_run === 7 && r1.result?.round_start === 6, JSON.stringify(r1.result && [r1.result.stop_reason, r1.result.rounds_this_invocation, r1.result.rounds_run, r1.result.round_start]))
    const rb = byLabel(r1, /^round-base-decision$/)[0]
    check('P4: the resume is logged and journaled with the reason', r1.logs.some(l => has(l, '재개') && has(l, '회차 6 부터')) && rb && has(rb.prompt, 'journal.sh') && has(rb.prompt, '6 부터 이어서') && has(rb.prompt, '덮고'), rb && rb.prompt)
    check('P4: the number is read once per invocation, before the first round', byLabel(r1, /^round-base$/).length === 1 && r1.calls.findIndex(c => c.label === 'round-base') < r1.calls.findIndex(c => c.label === 'run-6'), r1.calls.map(c => c.label).join(' '))
    const r0 = await mk({ last_round: 0, rounds_jsonl: 0, logs: 0 }, 2)
    check('P4: a fresh workspace starts at run-1 and journals no resume', JSON.stringify(runs(r0)) === JSON.stringify(['run-1', 'run-2']) && byLabel(r0, /^round-base-decision$/).length === 0 && r0.result?.round_start === 1, runs(r0).join(','))
    const rn = await mk(null, 1)
    check('P4: an unreadable round number is warned about (earlier logs may be overwritten) and starts at 1', JSON.stringify(runs(rn)) === JSON.stringify(['run-1']) && rn.logs.some(l => has(l, '마지막 회차 번호를 읽지 못했습니다')), rn.logs.join('\n'))
    const rnl = await mk({ last_round: null }, 1)
    check('P4: a null last_round is "could not read it", not round 0', JSON.stringify(runs(rnl)) === JSON.stringify(['run-1']) && rnl.logs.some(l => has(l, '마지막 회차 번호를 읽지 못했습니다')), rnl.logs.join('\n'))
    const rz = await mk({ last_round: 9004 }, 1)
    check('P4: a number in the negative-test range is not a round number', JSON.stringify(runs(rz)) === JSON.stringify(['run-1']), runs(rz).join(','))
    // an input-starved round is re-run under the same number and does not eat the cap
    let calls = 0
    const rs = await run(fn, { ...BASE_ARGS, runtime_round_cap: 2 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, roundBase: { last_round: 3 },
      obs: n => { calls++; return mkObs({ milestone: 'none', input_starved: calls === 1, rx_polls: 10 }) } }))
    check('P4: a starved round is repeated under its own number and the cap still counts two real rounds', JSON.stringify(runs(rs)) === JSON.stringify(['run-4', 'run-4', 'run-5']) && rs.result?.rounds_this_invocation === 2, runs(rs).join(',') + ' ' + JSON.stringify(rs.result && rs.result.rounds_this_invocation))
  })
  await block('X9', async () => {
    // the emitted round-base command, executed against a workspace made by the REAL record.py and real log names
    const wd = mktmp('ws')
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }))
    const call = r.calls.find(c => c.label === 'round-base')
    check('P4: the round-base command parses as bash', !!call && bashSyntax(call) === '', call && bashSyntax(call))
    const kv = o => Object.fromEntries(o.stdout.split('\n').filter(l => l.includes('=')).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
    const o0 = sh(cmdOf(call), wd)
    check('P4: an empty workspace is round 0', kv(o0).last_round === '0' && kv(o0).rounds_jsonl === '0' && kv(o0).logs === '0', o0.stdout + o0.stderr)
    const rec = n => spawnSync('python3', [path.join(repo, 'scripts', 'record.py'), wd, 'round', 'round=' + n, 'goal=x', 'category=c'], { encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } })
    ;[1, 2, 4, 9001].forEach(rec)
    const o1 = sh(cmdOf(call), wd)
    check('P4: rows written by the real record.py: the highest below 9000 (the negative round 9001 is not a round)', kv(o1).rounds_jsonl === '4' && kv(o1).last_round === '4', o1.stdout + o1.stderr)
    for (const f of ['console_5.txt', 'kernel_5.log', 'host_5.txt', 'run_5.summary.txt', 'origin_5.txt', 'console_9001.txt', 'avb_negative.txt', 'qemu_negative.stderr.txt', 'memdump_scan_3.json']) W(path.join(wd, '07_logs', f), 'x')
    const o2 = sh(cmdOf(call), wd)
    check('P4: a round that left logs but no row (it died before it was recorded) still counts: logs 5 beats rows 4', kv(o2).logs === '5' && kv(o2).rounds_jsonl === '4' && kv(o2).last_round === '5', o2.stdout + o2.stderr)
    W(path.join(wd, '07_logs', 'console_8999.txt'), 'x'); W(path.join(wd, '07_logs', 'console_9000.txt'), 'x')
    const o3 = sh(cmdOf(call), wd)
    check('P4: 8999 is a round, 9000 and above are the negative range', kv(o3).logs === '8999' && kv(o3).last_round === '8999', o3.stdout + o3.stderr)
    fs.rmSync(path.join(wd, '07_logs'), { recursive: true })
    const o4 = sh(cmdOf(call), wd)
    check('P4: rounds.jsonl alone is enough', kv(o4).last_round === '4' && kv(o4).logs === '0', o4.stdout + o4.stderr)
    const ws2 = mktmp('ws'); W(path.join(ws2, '07_logs', 'console_7.txt'), 'x')
    const o5 = sh(cmdOf(call).split(wd).join(ws2), ws2)
    check('P4: logs alone are enough', kv(o5).last_round === '7' && kv(o5).rounds_jsonl === '0', o5.stdout + o5.stderr)
  })

  // ---------------------------------------------------------------- P5: the observation names its own log files
  await block('P5', async () => {
    const planOn = { present: true, derived: true, plan: { region_base: '0x1', region_size: 4096, console_size: 1024, source: 'lk_log', evidence: 'e' } }
    const base = { prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, plan: planOn, supervisor: () => ({ route: 'fault-classifier' }),
      classify: () => ({ category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }] }), fixer: { fixer: 'x', not_mine: true, no_new_change: false } }
    const obsP = o => () => mkObs({ milestone: 'none', escalate_to_analyst: true, ...o })
    const sitesOf = r => ({ supervisor: byLabel(r, /^supervisor-1$/)[0], classifier: byLabel(r, /^classify-1$/)[0], analyst: byLabel(r, /^escalate-1$/)[0] })
    // a null in the observation is an answer: this round wrote no kernel log, and no path is invented for it
    const rNull = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ ...base, obs: obsP({ kernel_log: null, host_log: null }) }))
    const sn = sitesOf(rNull)
    check('P5: observation kernel_log=null with the channel on -> "none", no kernel_1.log path is invented (supervisor, classifier, analyst)', Object.values(sn).every(c => c && has(c.prompt, 'kernel log: none') && has(c.prompt, 'kernel_log is null') && !has(c.prompt, 'kernel_1.log')), JSON.stringify(Object.entries(sn).map(([k, c]) => [k, c && has(c.prompt, 'kernel log: none')])))
    check('P5: host_log=null names no host log either', Object.values(sn).every(c => c && !has(c.prompt, 'host log:') && !has(c.prompt, 'host_1.txt')), '')
    // paths in the observation win - also for a host log the channel counters do not count
    const rP = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ ...base, obs: obsP({ channels: { uart_bytes: 4, kernel_lines: 5, host_lines: 0 }, kernel_log: '/elsewhere/k.log', host_log: '/elsewhere/h.txt' }) }))
    const sp = sitesOf(rP)
    check('P5: kernel_log / host_log paths carried by the observation are the ones named, in all three prompts, with the field named', Object.values(sp).every(c => c && has(c.prompt, 'kernel log: /elsewhere/k.log') && has(c.prompt, 'host log: /elsewhere/h.txt') && has(c.prompt, 'observation.json field kernel_log') && has(c.prompt, 'observation.json field host_log') && !has(c.prompt, 'kernel_1.log')), JSON.stringify(Object.entries(sp).map(([k, c]) => [k, c && c.prompt.slice(c.prompt.indexOf('kernel log'), c.prompt.indexOf('kernel log') + 120)])))
    // an observation without the keys (an older run_round.sh) keeps the per-round default
    const rOld = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ ...base, obs: obsP({ channels: { uart_bytes: 4, kernel_lines: 9, host_lines: 2 } }) }))
    check('P5: no kernel_log / host_log key in the observation -> the per-round default paths (fallback kept)', Object.values(sitesOf(rOld)).every(c => c && has(c.prompt, 'kernel log: /wd/07_logs/kernel_1.log') && has(c.prompt, 'host log: /wd/07_logs/host_1.txt')), '')
    const sv = sn.supervisor, cl = sn.classifier
    check('P5: supervisor and classifier are told where the files are listed (observation.json: kernel_log, host_log)', has(sv.prompt, 'named in observation.json as kernel_log and host_log') && has(cl.prompt, 'named in observation.json as kernel_log and host_log'), '')
    check('P5: the run relay is told to relay a null as null', has(byLabel(rNull, /^run-1$/)[0].prompt, 'relay a null as null'), '')
    const schema = /const RUN_SCHEMA = \{([\s\S]*?)\n\}\n/.exec(fn.source)[1]
    check('P5: RUN_SCHEMA carries kernel_log and host_log as path-or-null', /^\s{4}kernel_log: \{ type: \['string', 'null'\] \}/m.test(schema) && /^\s{4}host_log: \{ type: \['string', 'null'\] \}/m.test(schema), '')
  })

  // ---------------------------------------------------------------- P6 / P7 / P9: analyst and build prompt rules
  await block('P6', async () => {
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }))
    const an = byLabel(r, /^analyze$/)[0].prompt
    check('P6: the analyst is told to write <workdir>/kernel_task_regex.txt (first non-empty line, first capture group = the task)', has(an, '/wd/kernel_task_regex.txt') && has(an, 'first\n   non-empty line is ONE regular expression') && has(an, 'first\n   capture group is the task name'), an.slice(an.indexOf('The scan accepts'), an.indexOf('The scan accepts') + 700))
    check('P6: it is told NOT to set an environment variable (and the identifier is not offered as a knob)', has(an, 'Do NOT set an\n   environment variable') && !has(an, 'KERNEL_TASK_REGEX'), '')
    check('P6: no delegated prompt tells anyone to set KERNEL_TASK_REGEX', !delegated(r).some(c => has(c.prompt, 'KERNEL_TASK_REGEX')), '')
  })
  await block('P7', async () => {
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs({ escalate_to_analyst: true }) }))
    const esc = byLabel(r, /^escalate-1$/)[0].prompt
    check('P7: the owning-fixer column allows the six fixers or the literal word build (K6)', has(esc, 'one of the six fixer names (fixer-memory, fixer-el3, fixer-bootflow, fixer-secureboot, fixer-storage, fixer-kernel) or the literal word build'), esc.slice(esc.indexOf('The owning-fixer'), esc.indexOf('The owning-fixer') + 400))
    check('P7: build is explained as a build-layer row that no fixer can reach', has(esc, 'build-layer row') && has(esc, 'no fixer can reach'), '')
    check('P7: the old "must be one of <fixers>" rule that excluded build is gone', !has(esc, 'Owning fixer must be one of'), '')
  })
  await block('P9', async () => {
    const mixed = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }))
    const single = await run(fn, { ...BASE_ARGS, soc_family: 'exynos', arch: 'arm64', target: 'F1', runtime_round_cap: 1 }, responder({ family: 'exynos', prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [A64_STAGE] }, obs: () => mkObs() }))
    const reb = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(),
      supervisor: () => ({ route: 'rebuild', layer: 'build', build_change: { change_key: 'entry-pc', change: 'enter at the derived entry', reason: 'wrong premise' } }) }))
    const READ = 'READ FIRST. Before you write or change anything, open every file named on the "Family knowledge:"'
    for (const [name, r, label] of [['mixed-arch', mixed, /^build$/], ['single-arch', single, /^build$/], ['rebuild', reb, /^rebuild-1$/]]) {
      const b = byLabel(r, label)[0]
      check('P9: the ' + name + ' machine-build prompt tells the agent to read the Family knowledge files and the Runbook before it acts', b && has(b.prompt, READ) && has(b.prompt, 'and "Runbook:" lines above') && b.prompt.indexOf('READ FIRST') < b.prompt.indexOf('1. Record the phase') && b.prompt.indexOf('Family knowledge:') < b.prompt.indexOf('READ FIRST'), b && b.prompt.slice(0, 500))
    }
    check('P9: ... saying they hold shapes and order, never values', has(byLabel(mixed, /^build$/)[0].prompt, 'never values') && has(byLabel(mixed, /^build$/)[0].prompt, "come only from STATIC.md and /wd/stage_map.json"), '')
  })

  // ---------------------------------------------------------------- P8: BLOCKED_KO has an emitter
  await block('P8', async () => {
    const go = (args, sd) => run(fn, args, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]], storage_driver: sd } }))
    const absent = { form: 'absent', evidence: 'synthetic: find modules -name "*mmc*.ko" -> 0 hits; strings Image | grep -ciE "mmc_block|sdhci" -> 0 hits (no vendor module, no driver strings in the kernel image)' }
    const r = await go({ ...BASE_ARGS, runtime_round_cap: 1 }, absent)
    check('P8: storage_driver.form=absent -> BLOCKED_KO with the analyst\'s evidence, before any build', r.result?.stop_reason === 'BLOCKED_KO' && has(r.result?.detail, 'storage_driver.form=absent') && has(r.result?.detail, 'no vendor module, no driver strings in the kernel image') && has(r.result?.detail, '-> 0 hits') && !r.calls.some(c => c.label === 'build' || c.label === 'qemu-tree-reset'), JSON.stringify(r.result))
    const rec = byLabel(r, /^record-blocker$/)[0]
    check('P8: ... recorded as a blockers.jsonl row the way BLOCKED_CARVE is (record.py blocker code= detail=, plus a journal note)', rec && has(rec.prompt, 'record.py "/wd" blocker code=BLOCKED_KO') && has(rec.prompt, 'detail=') && has(rec.prompt, 'journal.sh'), rec && rec.prompt)
    check('P8: ... and the note says what to do', has(r.result?.note, '드라이버가 모듈로도 빌트인으로도 없어'), r.result?.note)
    // an "absent" with nothing behind it is a claim, not a finding: the K4 recipe can miss a driver (it once grepped one medium kind's names only)
    const koSkips = async (name, sd) => {
      const rr = await go({ ...BASE_ARGS, runtime_round_cap: 1 }, sd)
      const j = byLabel(rr, /^ko-unconfirmed$/)[0]
      check('P8: absent ' + name + ' is UNCONFIRMED: no BLOCKED_KO, the run goes on to a build, and it is said in the log and journaled', rr.result?.stop_reason !== 'BLOCKED_KO' && rr.calls.some(c => c.label === 'build') && rr.logs.some(l => has(l, 'BLOCKED_KO 로 정지하지 않습니다')) && j && has(j.prompt, 'journal.sh') && has(j.prompt, 'decision') && has(j.prompt, '미확정') && !byLabel(rr, /^record-blocker$/).length, JSON.stringify(rr.result?.stop_reason) + ' ' + (j && j.prompt))
      return rr
    }
    const rk1 = await koSkips('with no evidence key', { form: 'absent' })
    check('P8: ... the log says the evidence is missing', rk1.logs.some(l => has(l, 'storage_driver.form=absent 로 보고됐으나 근거가 없습니다')), rk1.logs.join('\n'))
    for (const [name, ev] of [['with an empty evidence string', '   '], ['with an empty evidence object', {}], ['with null evidence', null], ['with an empty evidence list', []]]) await koSkips(name, { form: 'absent', evidence: ev })
    const rk2 = await koSkips('with evidence that has no hit count', { form: 'absent', evidence: 'synthetic: I looked and found no driver anywhere' })
    check('P8: ... and the log quotes the evidence it found too thin', rk2.logs.some(l => has(l, '근거에 적중 수가 없습니다') && has(l, 'I looked and found no driver anywhere')), rk2.logs.join('\n'))
    const rk3 = await go({ ...BASE_ARGS, runtime_round_cap: 1 }, { form: 'absent', evidence: { commands: ['find modules -name "*mmc*.ko"', 'strings Image | grep -c sdhci'], hits: { ko: 0, builtin: 0 }, medium: 'emmc' } })
    check('P8: an object evidence with commands and hit counts stops the run, and the stop quotes it (the evidence is serialised, not dropped)', rk3.result?.stop_reason === 'BLOCKED_KO' && has(rk3.result?.detail, 'sdhci') && has(rk3.result?.detail, '"hits"'), JSON.stringify(rk3.result))
    check('P8: ... a run that stopped does not also journal an "unconfirmed" decision', byLabel(r, /^ko-unconfirmed$/).length === 0 && byLabel(rk3, /^ko-unconfirmed$/).length === 0, '')
    for (const form of ['builtin', 'module']) {
      const rr = await go({ ...BASE_ARGS, runtime_round_cap: 1 }, { form, evidence: 'synthetic' })
      check('P8: form=' + form + ' is not a blocker (a missing .ko with a built-in driver is a reachable run)', rr.result?.stop_reason !== 'BLOCKED_KO' && rr.calls.some(c => c.label === 'build'), JSON.stringify(rr.result?.stop_reason))
    }
    const rn = await go({ ...BASE_ARGS, runtime_round_cap: 1 }, null)
    check('P8: no storage_driver report is not a blocker', rn.result?.stop_reason !== 'BLOCKED_KO', '')
    const r1 = await go({ ...BASE_ARGS, target: 'F1', runtime_round_cap: 1 }, absent)
    check('P8: F1 does not need the kernel side, so absent does not stop it', r1.result?.stop_reason !== 'BLOCKED_KO' && r1.calls.some(c => c.label === 'build'), JSON.stringify(r1.result?.stop_reason))
    const rc = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, carve_is_full: false, stages: [MT_STAGES[0]], storage_driver: absent } }))
    check('P8: the existing blockers keep their precedence (a carve is reported before BLOCKED_KO)', rc.result?.stop_reason === 'BLOCKED_CARVE', JSON.stringify(rc.result?.stop_reason))
  })

  // ---------------------------------------------------------------- H: handoffs from the other owners, each with its seam to the real script
  const pyRun = (code, ...a) => spawnSync('python3', ['-c', code, ...a], { encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1', PYTHONPATH: path.join(repo, 'scripts') } })
  // the JSON object a script printed: from its first line that opens one to the last closing brace
  const jsonOf = out => { const s = String(out), l = s.split('\n').find(x => x.trim().startsWith('{')); if (!l) return null; const a = s.indexOf(l), b = s.lastIndexOf('}'); try { return JSON.parse(s.slice(a, b + 1)) } catch (e) { return null } }
  const hashEngineOf = j => (j && j.verify_bypass ? j.verify_bypass.hash_engine : null)
  const analystPrompt = async (extra = {}, cfg = {}) => {
    const wd = mktmp('ws')
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: repo, runtime_round_cap: 1, ...extra }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(), ...cfg }))
    return { r, wd, an: byLabel(r, /^analyze$/)[0].prompt }
  }

  // stagemap handoff: the architecture of each LATER image is asked of the tool, not copied from the container
  await block('H1', async () => {
    const { wd, an } = await analystPrompt()
    const sect = an.slice(an.indexOf('1. STAGE MAP'), an.indexOf('2. SKIP PLAN'))
    check('H1: the stage-map step says the architecture belongs to the IMAGE, and the Architecture line is the container\'s', has(sect, 'The architecture belongs to the IMAGE, not to the run') && has(sect, "is the CONTAINER's"), sect.slice(0, 400))
    check('H1: ... and for each LATER image the analyst asks stage_map.py --detect-arch and passes the answer to that image\'s --arch', has(sect, 'For each LATER image ask') && has(sect, 'stage_map.py --detect-arch <that image>') && has(sect, "pass the answer to that image's stage_map.py --arch"), sect.slice(0, 900))
    check('H1: ... reading exit 2 (unreadable) and exit 64 (a caller mistake) as the script defines them', has(sect, 'Exit 2 = the file cannot be read') && has(sect, 'exit 64 = you combined the flag with an image or'), '')
    check('H1: ... "unknown" is not defaulted: both readings are tried, neither has a signature = arch_supported=false, both have one = recorded and left unconfirmed', has(sect, '"unknown" is an answer, not a') && has(sect, '--arch arm32 and with --arch arm64') && has(sect, 'If neither has one, report arch_supported=false') && has(sect, 'record both in STATIC.md and leave that image\'s stages unconfirmed'), sect.slice(0, 1500))
    check('H1: ... and the two readings do not say "none" the same way: arm32 exit 3, but arm64 NEVER exits 3 (a signature there is a non-empty entry_stubs list), so exit 0 alone is no evidence', has(sect, 'Under arm32 exit 3 = no entry signature') && has(sect, 'Under arm64 the tool NEVER') && has(sect, 'exits 3') && has(sect, 'a non-empty "entry_stubs" list') && has(sect, 'an empty list is none') && has(sect, '--arch arm64 never exits 3, so its exit'), sect.slice(0, 2400))
    check('H1: ... and the basis goes into STATIC.md', has(sect, 'Write the basis lines into STATIC.md'), '')
    // the container's own answer: its basis is to be written into STATIC.md too (not only journaled by the pipeline)
    const d1 = await analystPrompt({ arch: undefined }, { detect: { arch: 'arm32', entry_signature: 'gfh', basis: ['synthetic: the header declares the entry'], confidence: 'cross_checked', exit_code: 0 } })
    check('H1: a derived container arch hands the analyst its basis and asks for it in STATIC.md', has(d1.an, 'synthetic: the header declares the entry') && has(d1.an, 'Write those basis lines into STATIC.md'), d1.an.slice(d1.an.indexOf('Architecture:'), d1.an.indexOf('Architecture:') + 700))
    // the command it names, run against the real script on synthetic images
    const cmd = (/^\s*(bash "[^"]+\/py\.sh" stage_map\.py --detect-arch) <that image>\s*$/m.exec(sect) || [])[1]
    const w32 = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n >>> 0); return b }
    const stub = Buffer.concat([0x14000001, 0x10000000, 0xD5384241, 0xD51EC000].map(w32))
    const plain = n => Buffer.concat(Array.from({ length: n / 4 }, () => w32(0xA9BF7BFD)))
    const img = path.join(wd, "later image's.bin"), none = path.join(wd, 'no such.bin')
    fs.writeFileSync(img, Buffer.concat([stub, plain(0x8000 - 16), stub, plain(0x8000 - 16)]))
    const q = f => "'" + f.replace(/'/g, "'\\''") + "'"
    const o1 = cmd ? sh(`${cmd} ${q(img)}`, wd, { PYTHONDONTWRITEBYTECODE: '1' }) : { status: -1, stdout: '', stderr: 'no command found in the prompt' }
    const j1 = jsonOf(o1.stdout)
    check('H1: the command the prompt names is the real one: ONE JSON object {arch, entry_signature, basis, confidence}, exit 0', !!cmd && o1.status === 0 && j1 && ['arm32', 'arm64', 'unknown'].includes(j1.arch) && Array.isArray(j1.basis) && 'entry_signature' in j1 && 'confidence' in j1, o1.stdout + o1.stderr)
    const o2 = sh(`${cmd} ${q(none)}`, wd, { PYTHONDONTWRITEBYTECODE: '1' })
    check('H1: ... an unreadable image exits 2 (what the prompt says exit 2 means)', !!cmd && o2.status === 2, o2.status + ' ' + o2.stderr)
    const o3 = sh(`${cmd} ${q(img)} ${q(img)}`, wd, { PYTHONDONTWRITEBYTECODE: '1' })
    check('H1: ... the flag combined with an image exits 64 (what the prompt says exit 64 means)', !!cmd && o3.status === 64, o3.status + ' ' + o3.stderr)
  })

  // stagemap handoff: extract_boot_assets.sh's exit codes are told to the analyst, not collapsed into "failed"
  await block('H2', async () => {
    const go = (assets, prior) => run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]], ...(prior || {}) }, assets }))
    const F = (code, extra) => ({ staging: 'failed', exit_code: code, image: false, dtb: false, initrd: false, super: false, log: '/wd/08_docs/assets_staging.txt', ...extra })
    const r3 = await go(F(3), { assets_ok: false })
    check('H2: exit 3 reads "boot.img could not be parsed" (and that fw/ keeps what it held), not just FAILED', r3.result?.stop_reason === 'BLOCKED_ASSET' && has(r3.result?.detail, 'staging FAILED (exit 3: boot.img could not be parsed') && has(r3.result?.detail, 'fw/ keeps what it held before'), JSON.stringify(r3.result))
    const r2 = await go(F(2), { assets_ok: false })
    check('H2: exit 2 reads "an input file is missing or unreadable"', has(r2.result?.detail, 'staging FAILED (exit 2: an input file is missing or unreadable'), JSON.stringify(r2.result?.detail))
    const r1 = await go(F(1), { assets_ok: false })
    check('H2: exit 1 reads as a pipeline fault, not as a statement about the package', has(r1.result?.detail, '(exit 1: the script was called with too few arguments (a pipeline fault, not the package)'), JSON.stringify(r1.result?.detail))
    const r7 = await go(F(7), { assets_ok: false })
    check('H2: an exit the script does not document is reported by its number and log, with no invented meaning', has(r7.result?.detail, 'staging FAILED (exit 7; log /wd/08_docs/assets_staging.txt)'), JSON.stringify(r7.result?.detail))
    const r4 = await go({ staging: 'partial', exit_code: 4, image: true, dtb: true, initrd: true, super: false, log: '/wd/08_docs/assets_staging.txt' })
    const a4 = byLabel(r4, /^analyze$/)[0].prompt
    check('H2: exit 4 is PARTIAL and says why (the super could not be unpacked: lz4 missing or failed) while the kernel side is in fw/', has(a4, 'staged PARTIALLY') && has(a4, '(exit 4: the super image could not be unpacked (lz4 missing, or the unpack failed)') && has(a4, 'Image yes') && r4.result?.stop_reason !== 'BLOCKED_ASSET', a4.slice(a4.indexOf('Boot assets'), a4.indexOf('Boot assets') + 400))
    const rs = await go({ staging: 'staged', exit_code: 0, image: true, dtb: true, initrd: true, super: true, summary: 'assets: image=1 dtb=1 initrd=1 super=sparse' })
    const rr = await go({ staging: 'staged', exit_code: 0, image: true, dtb: true, initrd: true, super: true, summary: 'assets: image=1 dtb=1 initrd=1 super=raw' })
    check('H2: a super left SPARSE (summary super=sparse) is said so - "super yes" is not read as a usable rootfs source; a raw one is not flagged', has(byLabel(rs, /^analyze$/)[0].prompt, 'the super image is still SPARSE, not converted to raw') && !has(byLabel(rr, /^analyze$/)[0].prompt, 'still SPARSE'), '')
    // the real script: not a boot image -> exit 3, relayed by the emitted command as failed/3, then told to the analyst in words
    const wd = mktmp('ws')
    fs.mkdirSync(path.join(wd, '02_unpacked'), { recursive: true })
    fs.writeFileSync(path.join(wd, '02_unpacked', 'boot.img'), 'this is not a boot image'.padEnd(8192, 'x'))
    const rd = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: repo, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }))
    const o = sh(cmdOf(rd.calls.find(c => c.label === 'stage-assets')), wd, { UNPACK_BOOTIMG: '/nonexistent/unpack_bootimg', PYTHONDONTWRITEBYTECODE: '1' })
    const kv = Object.fromEntries(o.stdout.split('\n').filter(l => l.includes('=')).map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]))
    const real = await go({ staging: kv.assets_staging, exit_code: Number(kv.assets_exit), image: kv.staged_image === 'yes', dtb: kv.staged_dtb === 'yes', initrd: kv.staged_initrd === 'yes', super: kv.staged_super === 'yes', log: kv.staging_log }, { assets_ok: false })
    check('H2: the real script\'s exit 3, relayed by the emitted command, reaches the stop as "boot.img could not be parsed"', kv.assets_staging === 'failed' && kv.assets_exit === '3' && has(real.result?.detail, 'staging FAILED (exit 3: boot.img could not be parsed'), o.stdout + o.stderr + JSON.stringify(real.result?.detail))
  })

  // guide / observe handoffs: the analyst's items 7 (hash_engine row), 9 (cmdline partition), 11 (memdump plan)
  await block('H3', async () => {
    const { wd, an } = await analystPrompt()
    // item 7: the row, and the shape agrees with the reader (verify_gates)
    check('H3: item 7 asks for the hash_engine row in STATIC.md, names its shape (step 14d, absolute path) and says no row while undecided', has(an, 'RECORD WHICH CASE THIS IS as the `hash_engine` row in STATIC.md') && has(an, 'step 14d of ' + repo + '/agents/static-analyzer.md') && has(an, 'write NO row') && has(an, 'a row without a hex\n   address does not count'), an.slice(an.indexOf('RECORD WHICH'), an.indexOf('RECORD WHICH') + 500))
    check('H3: ... evidence = a 0x function address or SMC id; append-only so a LATER row wins; never in a code fence; only the analyst writes it', has(an, 'whose evidence cell holds a 0x function address or SMC id') && has(an, 'a corrected answer is a LATER row and the last\n   one wins') && has(an, 'never put the row inside a code fence') && has(an, 'Only you write this row - a fixer must not'), '')
    check('H3: ... and why it matters (fixer-secureboot and verify.py read it; check_change.sh rejects a labelled hash bypass without it)', has(an, "Without it fixer-secureboot and verify.py's hash_engine state never see an answer") && has(an, 'check_change.sh rejects a labelled (F) hash, digest or signature bypass that has no hardware row'), '')
    const shape = /`(\| hash_engine \| hardware or\s+software \| <evidence> \|)`/.exec(an)
    const state = text => { W(path.join(wd, 'STATIC.md'), text); const o = pyRun('import json,sys,verify_gates as vg; print(json.dumps(vg.hash_engine_state(sys.argv[1])))', wd); return jsonOf(o.stdout) || { status: 'unreadable:' + o.stderr.slice(0, 120) } }
    const rowOf = (value, evidence) => shape ? shape[1].replace(/hardware or\s+software/, value).replace('<evidence>', evidence) : '(shape not found in the prompt)'
    check('H3: the table row exactly as the prompt shapes it (hardware + a 0x function address and SMC id) is read by verify_gates as a usable hardware row', !!shape && state('| 항목 | 값 | 근거 |\n|---|---|---|\n' + rowOf('hardware', 'digest function 0x1f40; SMC id 0x82000001') + '\n').status === 'hardware', JSON.stringify(state('| 항목 | 값 | 근거 |\n|---|---|---|\n' + rowOf('hardware', 'x'))))
    check('H3: ... the same row with no hex address does NOT count (the prompt says so), and a software row is read as software', state(rowOf('hardware', 'looks like an engine') + '\n').status === 'unevidenced' && state(rowOf('software', 'compression rounds at 0x2a00') + '\n').status === 'software', '')
    check('H3: ... the one-line form the prompt also names is read, a LATER row wins (append-only), no row at all is "absent"', state('hash_engine: hardware (evidence: function 0x1f40)\n').status === 'hardware' && state(rowOf('hardware', 'function 0x1f40') + '\n\nlater:\n' + rowOf('software', 'rounds 0x2a00') + '\n').status === 'software' && state('nothing here\n').status === 'absent', '')
    check('H3: ... and a row inside a code fence is not read (the prompt says never to put it there)', state('```\n' + rowOf('hardware', 'function 0x1f40') + '\n```\n').status !== 'hardware', '')
    // item 9: the cmdline plan names its partition, and build_lu.py really reads these keys the way the prompt says
    const c9 = an.slice(an.indexOf('9. KERNEL COMMAND LINE'), an.indexOf('10. KERNEL SIDE'))
    check('H3: item 9 puts "partition" (and an optional "offset") in the cmdline_plan.json shape', has(c9, '"partition": "<the partition the bootloader reads the command line') && has(c9, 'optional "offset": <bytes from the start of that partition, default 0>'), c9.slice(0, 700))
    check('H3: ... says a source that is not a partition writes nothing (warning_cmdline); for this (MediaTek) family a plan naming nothing writes nothing either - the param fallback is not offered - and the Build step reports the warning', has(c9, 'prints warning_cmdline.') && has(c9, 'writes nothing for this family either') && !has(c9, 'warning_cmdline_target') && has(c9, 'the Build step reports it to the supervisor'), c9.slice(300))
    // the same item for an Exynos run keeps the param fallback it always described, and says the name is a guess
    const ex9 = (await analystPrompt({ soc_family: 'exynos', arch: 'arm64', target: 'F1' }, { family: 'exynos', prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [A64_STAGE] } })).an
    const e9 = ex9.slice(ex9.indexOf('9. KERNEL COMMAND LINE'), ex9.indexOf('10. KERNEL SIDE'))
    check('H3: ... and for an Exynos run a plan naming nothing still falls back to param with warning_cmdline_target (a guess), the Build step reporting both', has(e9, 'falls back to a partition literally') && has(e9, 'warning_cmdline_target - that name is a guess') && has(e9, 'Both are warning_* keys: the Build step reports them to the supervisor'), e9.slice(300))
    const lu = (plan, extraParts) => {
      const w = mktmp('lu')
      W(path.join(w, 'fw', 'a.bin'), 'A'.repeat(2048)); W(path.join(w, 'fw', 'b.bin'), 'B'.repeat(2048)); W(path.join(w, 'fw', 'p.bin'), 'P'.repeat(2048))
      W(path.join(w, 'lu_manifest.json'), JSON.stringify({ medium: 'emmc', partitions: [{ name: 'boot', source: 'fw/a.bin' }, { name: 'bootargs_a', source: 'fw/b.bin' }].concat(extraParts || []) }))
      W(path.join(w, 'cmdline_plan.json'), JSON.stringify(plan))
      const o = spawnSync('python3', [path.join(repo, 'scripts', 'build_lu.py'), w, '--out', path.join(w, 'fw', 'lu0.img')], { encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } })
      return jsonOf(o.stdout) || { error: o.stderr.slice(0, 200) }
    }
    const base = { default: 'console=ram', uart: 'console=ttyS0,115200n8', source: 'free text evidence', evidence: 'e' }
    const j1 = lu({ ...base, partition: 'bootargs_a', offset: 16 })
    check('H3: build_lu.py writes the uart line into the partition the plan names, at the plan\'s offset (the keys the prompt shows)', j1.cmdline_written === true && j1.cmdline_target && j1.cmdline_target.partition === 'bootargs_a' && j1.cmdline_target.offset === 16 && !('warning_cmdline' in j1), JSON.stringify(j1).slice(0, 300))
    const j2 = lu({ ...base, source: 'built into the bootloader' })
    check('H3: ... a source that is not a partition name writes nothing and prints warning_cmdline', j2.cmdline_written === false && typeof j2.warning_cmdline === 'string' && !('warning_cmdline_target' in j2), JSON.stringify(j2).slice(0, 300))
    const j3 = lu({ default: 'console=ram', uart: 'console=ttyS0,115200n8' }, [{ name: 'param', source: 'fw/p.bin' }])
    check('H3: ... a plan that names no partition at all falls back to the one called param and prints warning_cmdline_target', j3.cmdline_written === true && j3.cmdline_target && j3.cmdline_target.partition === 'param' && typeof j3.warning_cmdline_target === 'string', JSON.stringify(j3).slice(0, 300))
    // item 6/11: how the task regex is applied - the prompt's claims against the real scan
    const tr = (rx, line) => pyRun('import sys,os; os.environ["KERNEL_TASK_REGEX"]=sys.argv[1]; import memdump_observe as m; print(m.task_of(sys.argv[2]))', rx, line).stdout.trim()
    check('H3: the prompt says the task regex is SEARCHED (unanchored) in the first 64 characters of the line text, a group names the task and without one the whole match does', has(an, 'It is SEARCHED,\n   not anchored, in the first 64 characters of each kernel line') && has(an, 'without a group the whole match is the name') && has(an, 'a regex that does not compile is reported on the round\'s stderr and the default'), '')
    check('H3: ... and the real scan does exactly that (mid-line match found, whole match without a group, nothing beyond 64 characters, a broken regex falls back to the default shape)', tr('<tsk:([a-z]+)>', 'xx <tsk:init> y') === 'init' && tr('<tsk:[a-z]+>', 'xx <tsk:init> y') === '<tsk:init>' && tr('<tsk:([a-z]+)>', 'x'.repeat(70) + ' <tsk:init>') === 'None' && tr('([', '[  1:swapper/0] hello') === 'swapper/0', [tr('<tsk:([a-z]+)>', 'xx <tsk:init> y'), tr('<tsk:[a-z]+>', 'xx <tsk:init> y'), tr('<tsk:([a-z]+)>', 'x'.repeat(70) + ' <tsk:init>'), tr('([', '[  1:swapper/0] hello')].join('|'))
    // item 11: the plan needs base and size; console_size is 0 when no source gives it (what derive writes)
    const c11 = an.slice(an.indexOf('11. MEMORY-DUMP CHANNEL'), an.indexOf('First record the phase'))
    check('H3: item 11 asks for the plan only when region_base AND region_size are derived, console_size being 0 when no source gives it', has(c11, '"console_size": <N or 0>') && has(c11, 'ONLY when region_base AND region_size are derived') && !has(c11, 'AND console_size are all derived') && has(c11, 'and 0 when none does'), c11.slice(0, 900))
    check('H3: ... console_size is then 미확정 in STATIC.md and never invented; a DTB reserved-memory region is hand-written with the node path and flagged hand-read', has(c11, 'say console_size is 미확정 in STATIC.md, never invent one') && has(c11, 'DTB reserved-memory node') && has(c11, 'flagged in STATIC.md as hand-read'), '')
    const dcmd = (/^\s*(bash "[^"]+\/py\.sh" memdump_observe\.py derive --bootloader-log) <console>/m.exec(c11) || [])[1]
    W(path.join(wd, 'bl.log'), 'RAM_CONSOLE pstore_addr:0x50100000, pstore_size:0x40000\n')
    const od = dcmd ? sh(`${dcmd} bl.log --out plan.json`, wd, { PYTHONDONTWRITEBYTECODE: '1' }) : { status: -1, stderr: 'no derive command in the prompt' }
    const plan = (() => { try { return JSON.parse(fs.readFileSync(path.join(wd, 'plan.json'), 'utf8')) } catch (e) { return null } })()
    check('H3: the derive command the prompt names is real, and without a ring size in the log it writes console_size 0 (exit 0) - the plan the prompt allows', !!dcmd && od.status === 0 && plan && plan.region_base === '0x50100000' && plan.region_size === 262144 && plan.console_size === 0, (od.stdout || '') + (od.stderr || ''))
    const rp = pyRun('import sys,memdump_observe as m; p,why=m.read_plan(sys.argv[1]); print(p and (p["capacity_assumed"], p["capacity"]))', path.join(wd, 'plan.json'))
    check('H3: ... and the scan accepts that plan, assuming the whole region is the ring (capacity_assumed)', rp.stdout.trim() === '(True, 262144)', rp.stdout + rp.stderr)
  })

  // P8 needs an emitter AND a source: the analyst is asked to report storage_driver, or BLOCKED_KO could never be raised
  await block('H9', async () => {
    const f2 = (await analystPrompt()).an
    const f1 = (await analystPrompt({ target: 'F1' })).an
    check('H9: an F2 analyst is asked to report storage_driver {form: module|builtin|absent, evidence} and told only "absent" stops the run (BLOCKED_KO)', has(f2, 'Report storage_driver {form: "module" | "builtin" | "absent", evidence}') && has(f2, 'only "absent" - no vendor .ko AND no driver in the kernel image - stops the run') && has(f2, 'records BLOCKED_KO from your answer'), f2.slice(f2.indexOf('10. KERNEL SIDE'), f2.indexOf('10. KERNEL SIDE') + 900))
    check('H9: an F1 run does not ask (it needs no kernel side)', !has(f1, 'Report storage_driver'), '')
    const k = f2.slice(f2.indexOf('Report storage_driver'), f2.indexOf('Kernel patch sites'))
    check('H9: the K4 search is MEDIUM-AWARE: decide the kind first (item 6, detect_medium.py), then grep that kind\'s drivers (eMMC: mmc / sdhci / dw_mmc; UFS: ufshcd), because one kind\'s names find nothing on the other', has(k, 'THE MEDIUM THIS BOARD BOOTS FROM') && has(k, 'decide the kind first') && has(k, 'detect_medium.py') && has(k, 'eMMC: the mmc block and sdhci / dw_mmc') && has(k, 'UFS: ufshcd') && has(k, 'finds nothing and would read as "absent"'), k)
    check('H9: ... and "absent" needs the commands run and their hit counts, otherwise it is unconfirmed and does not stop (leave storage_driver out)', has(k, 'names each command you ran') && has(k, 'its hit count') && has(k, 'treats it as\n   unconfirmed and does NOT stop') && has(k, 'leave\n   storage_driver out'), k)
    check('H9: ... with no vendor driver name in the pipeline (the host driver is the one the DTB node names)', !/msdc|ufs-exynos|ufs_qcom|exynos-ufs/.test(k), k)
    check('H9: the key the prompt names is the one the pipeline reads (storage_driver.form) and the agent doc defines the same three values', /storage_driver: \{ type: \['object', 'null'\] \}/.test(fn.source) && fs.readFileSync(path.join(repo, 'agents', 'static-analyzer.md'), 'utf8').includes('storage_driver: { form: "module" | "builtin" | "absent", evidence: … }'), '')
  })

  // guide handoff: the machine-build prompt asks for the STATIC.md address-windows table by pointing at the template, for a mixed-arch machine only
  await block('H5', async () => {
    const mixed = await run(fn, { ...BASE_ARGS, plugin_dir: repo, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }))
    const single = await run(fn, { ...BASE_ARGS, soc_family: 'exynos', arch: 'arm64', target: 'F1', runtime_round_cap: 1, plugin_dir: repo }, responder({ family: 'exynos', prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [A64_STAGE] }, obs: () => mkObs() }))
    const reb = await run(fn, { ...BASE_ARGS, plugin_dir: repo, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(),
      supervisor: () => ({ route: 'rebuild', layer: 'build', build_change: { change_key: 'entry-pc', change: 'enter at the derived entry', reason: 'wrong premise' } }) }))
    const tmpl = path.join(repo, 'templates', 'machine_mixed_arch.c.tmpl')
    for (const [name, r, label] of [['build', mixed, /^build$/], ['rebuild', reb, /^rebuild-1$/]]) {
      const b = byLabel(r, label)[0].prompt
      check('H5: the mixed-arch ' + name + ' prompt asks for the "address windows" table in STATIC.md and points at the Conventions block of the template', has(b, 'ADDRESS WINDOWS TABLE') && has(b, 'headed "address windows" in\n   /wd/STATIC.md') && has(b, 'Conventions\n   block at the top of ' + tmpl), b.slice(b.indexOf('ADDRESS WINDOWS'), b.indexOf('ADDRESS WINDOWS') + 600))
      check('H5: ... without copying the columns (the definition lives in one place)', !has(b, 'security_effect') && !has(b, 'catchall') && !has(b, 'pre_handoff'), '')
    }
    check('H5: a single-architecture build asks for no such table (the template is the mixed-arch one)', !has(byLabel(single, /^build$/)[0].prompt, 'ADDRESS WINDOWS TABLE'), '')
    const t = fs.readFileSync(tmpl, 'utf8')
    check('H5: the pointer is valid: the template exists, and its Conventions block defines the address windows table', /Conventions:/.test(t) && /address windows/.test(t) && /security_effect/.test(t), '')
  })

  // verify handoff: verify_bypass.hash_engine and address_windows, as the REAL verify.py measures them, reach the log, the verifier and the result
  await block('H7', async () => {
    const HE = (o = {}) => ({ row: false, status: 'absent', value: null, evidence: null, line: null, conflict: false, static: '/wd/STATIC.md', needed_by: [{ id: '7', heading: 'digest compare forced', word: 'digest' }], unbacked: ['7'], ...o })
    const stage = (he, aw) => ({ verdict: 'VERIFIED', verdict_label: 'VERIFIED (출처 검증 통과) · 검증 우회 1건 · verify_ok: reached_bypassed', gates_passed: 3, gates_total: 3, verify_bypass: { count: 1, status: 'present', unproven: false, ...(he === undefined ? {} : { hash_engine: he }) }, ...(aw === undefined ? {} : { address_windows: aw }) })
    const go = (stage1, extra = {}, cfg = {}) => run(fn, { ...BASE_ARGS, runtime_round_cap: 3, negative_test: false, ...extra }, responder({ prior: { ...MT_PRIOR, stages: [A64_STAGE] }, obs: () => mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'kernel_entry', 'kernel_alive'] }), stage1, ...cfg }))
    const logsOf = r => r.logs.filter(l => l.startsWith('[검증]'))
    // (1) a labelled hash bypass with no hardware row
    const r1 = await go(stage(HE()))
    check('H7: a labelled hash bypass with NO hash_engine row is said out loud, with the ids that have no backing', logsOf(r1).some(l => has(l, 'hash_engine 행: 없음 (상태 absent)') && has(l, '이 행에 기대는 기록: 7') && has(l, '근거 없는 기록: 7') && has(l, '전제 없이 쓰인 해시 우회')), logsOf(r1).join('\n'))
    const vr1 = byLabel(r1, /^verify$/)[0].prompt
    check('H7: the verifier is told what the script measured, and to report verify_bypass.hash_engine {row, unbacked} (rule 5 of verifier.md)', has(vr1, 'When a ledger entry changes a hash, digest or signature comparison, say whether STATIC.md carries') && has(vr1, 'The script measured: hash_engine 행: 없음') && has(vr1, 'verify_bypass.hash_engine {row,\n   unbacked}') && has(vr1, 'The row is a necessary condition, not a proof'), vr1.slice(vr1.indexOf('When a ledger entry'), vr1.indexOf('When a ledger entry') + 600))
    check('H7: the result carries hash_engine {row, unbacked ids} next to the count', r1.result?.verify_bypass?.hash_engine && r1.result.verify_bypass.hash_engine.row === false && JSON.stringify(r1.result.verify_bypass.hash_engine.unbacked) === '["7"]' && r1.result.verify_bypass.count === 1, JSON.stringify(r1.result?.verify_bypass))
    // (2) the row exists: "있음", nothing unbacked
    const r2 = await go(stage(HE({ row: true, status: 'hardware', value: 'hardware', line: 41, unbacked: [] })))
    check('H7: with a hardware row the line says so (value and STATIC.md line) and lists no unbacked entry', logsOf(r2).some(l => has(l, 'hash_engine 행: 있음 (hardware, STATIC.md 41줄)') && has(l, '근거 없는 기록: 없음') && !has(l, '전제 없이')) && JSON.stringify(r2.result?.verify_bypass?.hash_engine?.unbacked) === '[]', logsOf(r2).join('\n'))
    // (3) nothing leans on the row: no line, no clutter, null in the result
    const r3 = await go(stage(HE({ needed_by: [], unbacked: [] })))
    check('H7: when no ledger entry leans on the row nothing is printed and the result says null', !logsOf(r3).some(l => has(l, 'hash_engine')) && r3.result?.verify_bypass?.hash_engine === null, logsOf(r3).join('\n'))
    const r4 = await go(stage(undefined))
    check('H7: a measurement with no hash_engine object at all (an older verify.py) is not an error and prints nothing', !r4.error && !logsOf(r4).some(l => has(l, 'hash_engine')) && r4.result?.verify_bypass?.hash_engine === null, r4.error && r4.error.stack)
    // (4) address windows: a reference line for a mixed-arch machine, nothing otherwise
    const AW = (o = {}) => ({ applicable: true, status: 'columns_incomplete', windows: 4, tables: 1, missing_columns: ['security_effect'], security_effect_empty: 4, security_effect_true: 0, note: 'x', ...o })
    const r5 = await go(stage(HE({ needed_by: [], unbacked: [] }), AW()))
    check('H7: the address-windows table is reported for the mixed-arch machine: status, rows, empty security_effect cells, missing columns', logsOf(r5).some(l => has(l, '주소 창 표 (혼합 아키텍처 머신, 참고): columns_incomplete · 창 4행 · 보안 영향 칸이 빈 행 4 · 빠진 열 security_effect')), logsOf(r5).join('\n'))
    const vr5 = byLabel(r5, /^verify$/)[0].prompt
    check('H7: ... the verifier (mixed-arch) is asked for the same one line, as a reference item', has(vr5, 'This machine is mixed-architecture: also give the address-window table in one line') && has(vr5, 'the script measured: 주소 창 표'), '')
    const r6 = await go(stage(HE({ needed_by: [], unbacked: [] }), AW({ applicable: false, status: 'not_applicable' })))
    check('H7: ... and an inapplicable table (not a mixed-arch machine) prints nothing', !logsOf(r6).some(l => has(l, '주소 창 표')), logsOf(r6).join('\n'))
    const rs = await go(stage(HE(), AW()), { soc_family: 'exynos', arch: 'arm64', target: 'F1' }, { family: 'exynos', prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [A64_STAGE] }, obs: () => mkObs({ milestone: 'shell', milestones_reached: ['preloader_entry', 'shell'] }) })
    check('H7: a single-architecture verifier prompt does not ask for the address-window line', !has(byLabel(rs, /^verify$/)[0].prompt, 'also give the address-window table'), '')
    const sch = /const VERIFY_SCHEMA = \{([\s\S]*?)\n\}\n/.exec(fn.source)[1]
    check('H7: VERIFY_SCHEMA carries address_windows (the relay is asked for it)', /^\s{4}address_windows: \{ type: \['object', 'null'\] \}/m.test(sch) && has(byLabel(r1, /^verify-stage1$/)[0].prompt, 'verify_bypass and address_windows from the JSON'), '')
    // (5) the seam: the real verify.py's own JSON, through the emitted verify command, on a synthetic workspace
    const wd = mktmp('ws')
    W(path.join(wd, 'bl.bin'), 'x'.repeat(4096))
    W(path.join(wd, '07_logs', 'console_1.txt'), 'preloader banner\n')
    W(path.join(wd, '06_machine', 'machine_full.c'), 'int handoff_tick;\n')
    W(path.join(wd, '06_machine', 'bypasses.md'), '### #7 digest compare forced\n- 대상: the digest comparison of the verified boot path\n- 이유: the digest engine is not modelled\n- 방법: the compare result is forced equal\n- 부작용: the firmware\'s own digest check is not exercised\n- 메타: 종류=P; 표지=F; 출처=C; 도출=semi\n')
    W(path.join(wd, 'stage_map.json'), '{}')
    const obsK = mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'kernel_entry', 'kernel_alive'], trace: path.join(wd, 'trace.log') })
    const measure = async () => {
      const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: repo, bootloader_path: path.join(wd, 'bl.bin'), runtime_round_cap: 3, negative_test: false }, responder({ prior: { ...MT_PRIOR, stages: [A64_STAGE] }, obs: () => obsK }))
      const o = sh(cmdOf(r.calls.find(c => c.label === 'verify-stage1')), wd, { PYTHONDONTWRITEBYTECODE: '1' })
      return { o, j: jsonOf(o.stdout) }
    }
    const m1 = await measure()
    const he1 = hashEngineOf(m1.j)
    check('H7: the real verify.py (no STATIC.md row) reports hash_engine.row=false with entry 7 as needed and unbacked, and an address_windows object', m1.o.status === 0 && he1 && he1.row === false && JSON.stringify(he1.unbacked) === '["7"]' && he1.needed_by.length === 1 && m1.j.address_windows && m1.j.address_windows.applicable === true, m1.o.stdout.slice(0, 200) + m1.o.stderr.slice(0, 300))
    const p1 = await go(m1.j)
    check('H7: ... and the pipeline, fed that real JSON, says "없음" and names entry 7 as unbacked, and reports the missing address-windows table', logsOf(p1).some(l => has(l, 'hash_engine 행: 없음') && has(l, '근거 없는 기록: 7')) && logsOf(p1).some(l => has(l, '주소 창 표 (혼합 아키텍처 머신, 참고): missing')), logsOf(p1).join('\n'))
    W(path.join(wd, 'STATIC.md'), '## 해시 계산 위치\n\n| 항목 | 값 | 근거 |\n|---|---|---|\n| hash_engine | hardware | digest function 0x1f40, SMC id 0x82000001 |\n')
    const m2 = await measure()
    const he2 = hashEngineOf(m2.j)
    check('H7: the real verify.py with the row written reports row=true, value hardware, nothing unbacked', he2 && he2.row === true && he2.value === 'hardware' && JSON.stringify(he2.unbacked) === '[]', JSON.stringify(he2))
    const p2 = await go(m2.j)
    check('H7: ... and the pipeline says "있음" with the STATIC.md line and no unbacked entry', logsOf(p2).some(l => has(l, 'hash_engine 행: 있음 (hardware, STATIC.md ') && has(l, '근거 없는 기록: 없음')), logsOf(p2).join('\n'))
  })

  // verify handoff: the escalation asks the analyst for the hash_engine row when the question is where the digest is computed
  await block('H8', async () => {
    const r = await run(fn, { ...BASE_ARGS, plugin_dir: repo, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs({ escalate_to_analyst: true }) }))
    const esc = byLabel(r, /^escalate-1$/)[0].prompt
    check('H8: the escalation prompt says that "where the digest is computed" is answered by the hash_engine row of STATIC.md (step 14d, absolute path), not a stop-point row', has(esc, 'WHERE THE DIGEST IS COMPUTED') && has(esc, 'the `hash_engine` row of STATIC.md') && has(esc, 'step 14d of ' + repo + '/agents/static-analyzer.md') && has(esc, 'not a stop-point row'), esc.slice(esc.indexOf('If the question is'), esc.indexOf('If the question is') + 500))
    check('H8: ... only when decided (undecided = no row), only the analyst writes it, and check_change.sh rejects a labelled hash bypass without a hardware row', has(esc, 'undecided means NO row') && has(esc, 'Only you write it - a fixer must not') && has(esc, 'without a hardware row check_change.sh rejects a labelled hash bypass'), '')
  })

  // ---------------------------------------------------------------- S: static facts about the source
  await block('S', async () => {
    const src = fs.readFileSync(PJ, 'utf8')
    const code = src.split('\n').filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l)).join('\n')
    const agentCalls = (code.match(/\bagent\(/g) || []).length
    const kitCalls = (code.match(/\bfamilyContext\(\)/g) || []).length - 1       // minus the definition
    // delegation sites: shell() relays commands (no family), the verifier and the package
    // agent do not read family material; every other agent() call does.
    const DELEGATION_SITES = ['fixer-general', 'static-analyzer prior', 'static-analyzer re-derivation', 'static-analyzer token correction', 'machine build',
      'static-analyzer escalation', 'static-analyzer memdump evidence', 'supervisor', 'fault-classifier', 'specialist fixer']
    const NO_FAMILY = ['shell relay', 'verifier', 'package']
    check('S: ' + agentCalls + ' agent() call sites = ' + DELEGATION_SITES.length + ' delegation sites + ' + NO_FAMILY.length + ' that read no family material', agentCalls === DELEGATION_SITES.length + NO_FAMILY.length, 'agent( count ' + agentCalls)
    // the two fixer prompts (the specialists' and the last-resort fixer's) share ONE context text, fixerContext(), which holds the one
    // familyContext() call for both: so the sites are counted by calls, and the shared helper is checked to serve exactly the two of them
    const fixerCtxCalls = (code.match(/\bfixerContext\(/g) || []).length - 1                  // minus the definition
    const directKit = kitCalls - 1                                                              // minus the call inside fixerContext() itself
    check('S: every delegation site puts familyContext() in its prompt (' + directKit + ' direct calls + the shared fixerContext() for ' + fixerCtxCalls + ' fixer prompts = ' + DELEGATION_SITES.length + ' sites)', directKit + fixerCtxCalls === DELEGATION_SITES.length && fixerCtxCalls === 2 && /function fixerContext\([^)]*\) \{[\s\S]*?familyContext\(\)[\s\S]*?\n\}/.test(code), 'familyContext() calls ' + kitCalls + ', fixerContext() calls ' + fixerCtxCalls)
    check('S: the real MediaTek profile names at least one table and a runbook (the checks above would be vacuous otherwise)', (KIT.knowledge || []).length >= 1 && !!KIT.runbook, JSON.stringify(KIT))
    check('S: no device value (an address) lives in pipeline.js', !/0x[0-9a-fA-F]{3,}/.test(code), (code.match(/0x[0-9a-fA-F]{3,}/g) || []).join(','))
    check('S: KNOWLEDGE is no longer a constant', !/\bconst KNOWLEDGE\b/.test(code) && /\blet KNOWLEDGE\b/.test(code), '')
    check('S: the three phase-1 smoke strings are still there', ['route === GENERAL_FIXER', 'KNOWN_FIXERS.includes(sup?.prescribed_fixer)', "route === 'revert'", 'candidates.slice(0, 3)', 'sync_machine.sh', 'BLOCKED_ENV'].every(t => src.includes(t)), '')
    const known = /KNOWN_FIXERS = \[([^\]]*)\]/.exec(src)
    check('S: KNOWN_FIXERS is the list smoke.sh pins', known && [...known[1].matchAll(/'([^']+)'/g)].map(m => m[1]).join(',') === 'fixer-memory,fixer-el3,fixer-bootflow,fixer-secureboot,fixer-storage,fixer-kernel', known && known[1])
    check('S: the five phases are unchanged', ['Analyze', 'Build', 'Loop', 'Verify', 'Package'].every(t => src.includes("phase('" + t + "')")), '')
  })

}
main().then(C.finish).catch(e => { console.log('FAIL harness crashed :: ' + (e && e.stack)); process.exit(1) })
