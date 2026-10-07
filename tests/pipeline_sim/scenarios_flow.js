// scenarios_flow.js <repo> - end-to-end scripted runs of workflows/pipeline.js: flows, stop reasons, the commands it emits, and the earlier fix-stage promises.
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
  // ---------------------------------------------------------------- A: MediaTek F2, autoboot
  await block('A', async () => {
    const rounds = {
      1: mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'], kernel_uniq: null }),
      2: mkObs({ milestone: 'lk_entry', milestones_reached: ['preloader_entry', 'lk_entry'], kernel_uniq: null }),
      3: mkObs({ milestone: 'kernel_entry',
        milestones_reached: ['preloader_entry', 'lk_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry'],
        rx_reported: true, rx_served: 3, rx_polls: 5 }),
      4: mkObs({ milestone: 'kernel_alive',
        milestones_reached: ['preloader_entry', 'lk_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive'],
        channels: { uart_bytes: 10, kernel_lines: 400, host_lines: 4 }, kernel_uniq: 380, kernel_last_time: 12.5,
        kernel_alive_evidence: { channel: 'memdump', token: 'Freeing unused kernel memory', kernel_time: 12.5, task: 'swapper', via: 'alternate', note: '배너 미관측' } }),
    }
    const stage1 = { verdict: 'VERIFIED', verdict_label: 'x', gates_passed: 3, gates_total: 3, verify_bypass: { count: 2, status: 'present', unproven: true } }
    const stage1final = { verdict: 'VERIFIED', verdict_label: 'VERIFIED (출처 검증 통과) · 검증 우회 3건 · verify_ok: reached_bypassed', gates_passed: 3, gates_total: 3, verify_bypass: { count: 3, status: 'present', unproven: false } }
    const planOn = { present: true, derived: true, plan: { region_base: '0x1', region_size: 4096, console_size: 1024, source: 'lk_log', evidence: 'e' } }
    const plan = n => n >= 3 ? planOn : { present: false, derived: false, plan: null, reason: 'no ring named yet' }
    const r = await run(fn, BASE_ARGS, responder({ obs: n => rounds[n], stage1, stage1final, plan,
      medium0: { hci_kind: 'emmc', basis: 'dtb', confidence: 'medium', reason: 'r', evidence: ['e1'], notes: [] },
      mediumLog: () => ({ hci_kind: 'emmc', basis: 'bootloader_log', confidence: 'high', evidence: ['l1'] }) }))
    check('A: pipeline ran without throwing', !r.error, r.error && r.error.stack)
    const res = r.result || {}
    check('A: ladder has no surface rung (none dropped)', JSON.stringify(res.goals) === JSON.stringify(
      ['preloader_entry', 'bl31_entry', 'lk_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive']), JSON.stringify(res.goals))
    check('A: bl_surface none is not BLOCKED_NO_INPUT_PATH', res.stop_reason !== 'BLOCKED_NO_INPUT_PATH', res.stop_reason)
    check('A: bl31_entry (never observed) is not in reached_goals', Array.isArray(res.reached_goals) && !res.reached_goals.includes('bl31_entry'), JSON.stringify(res.reached_goals))
    check('A: bl31_entry is listed as passed over', (res.passed_over || []).includes('bl31_entry'), JSON.stringify(res.passed_over))
    check('A: reached_goals = the observed rungs only', JSON.stringify(res.reached_goals) === JSON.stringify(
      ['preloader_entry', 'lk_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive']), JSON.stringify(res.reached_goals))
    check('A: rung_states.bl31_entry not_reached', res.rung_states?.bl31_entry === 'not_reached', JSON.stringify(res.rung_states))
    check('A: rung_states.verify_ok reached_bypassed (count 3)', res.rung_states?.verify_ok === 'reached_bypassed', JSON.stringify(res.rung_states))
    check('A: rung_states.kernel_alive reached', res.rung_states?.kernel_alive === 'reached', JSON.stringify(res.rung_states))
    check('A: grade text says verify_ok bypass count', res.grade === 'F2 (verify_ok 우회 3건)', res.grade)
    check('A: verify_bypass count + unproven in result', res.verify_bypass?.count === 3 && res.verify_bypass?.unproven === false, JSON.stringify(res.verify_bypass))
    check('A: autoboot observed after kernel_entry', res.autoboot === 'observed', res.autoboot)
    check('A: negative test performed and reported', res.negative_test?.performed === true, JSON.stringify(res.negative_test))
    check('A: success true (VERIFIED)', res.success === true, JSON.stringify(res.verdict))
    // family kit injection: every delegated prompt a family agent reads
    const famTypes = ['static-analyzer', 'supervisor', 'fault-classifier']
    const sites = delegated(r).filter(c => famTypes.includes(c.agentType) || /^fixer-/.test(c.agentType || '') || c.label === 'build' || /^rebuild-/.test(c.label) || /^general-/.test(c.label))
    const missing = sites.filter(c => !(has(c.prompt, FAM_LINE + '\n') && has(c.prompt, RB_LINE + '\n')))
    check('A: every family-agent prompt carries both family lines (' + sites.length + ' prompts)', sites.length >= 5 && missing.length === 0, missing.map(c => c.label).join(','))
    // ordering of the build preparation
    const order = r.calls.map(c => c.label)
    const iTree = order.indexOf('qemu-tree-reset'), iCore = order.indexOf('core-patch'), iMed = order.indexOf('detect-medium'), iBuild = order.indexOf('build')
    check('A: qemu_tree reset -> core patch -> detect_medium -> build', iTree >= 0 && iTree < iCore && iCore < iMed && iMed < iBuild, order.slice(0, 30).join(' '))
    check('A: reset command is qemu_tree.sh reset', has(r.calls[iTree].prompt, 'scripts/qemu_tree.sh" reset'), r.calls[iTree].prompt)
    check('A: core patch passes --family mediatek', has(r.calls[iCore].prompt, 'patch_qemu_core.py --family mediatek'), r.calls[iCore].prompt)
    const build = r.calls[iBuild]
    check('A: build prompt points at the mixed-arch template + example + runbook', has(build.prompt, 'templates/machine_mixed_arch.c.tmpl') && has(build.prompt, 'examples/a136u-mt6833') && has(build.prompt, RB_LINE), '')
    check('A: build prompt has no "no AArch32 template" instruction', !has(build.prompt, 'no AArch32 template yet') && !has(build.prompt, 'machine template is missing'), '')
    check('A: build prompt says derive only, never borrow', has(build.prompt, 'ONLY from those') && has(build.prompt, 'not borrowable'), '')
    check('A: build prompt: medium follows kind (emmc, no storage_hci)', has(build.prompt, 'build_lu.py "/wd" --out /wd/fw/lu0.img --medium emmc') && has(build.prompt, 'do NOT use storage_hci.c.tmpl'), build.prompt.slice(build.prompt.indexOf('3. Synthesise'), build.prompt.indexOf('3. Synthesise') + 300))
    check('A: build prompt records touched tree files', has(build.prompt, 'qemu_tree.sh" record hw/arm/meson.build'), '')
    check('A: build prompt origin-aware placement', has(build.prompt, 'origin "medium": the machine does NOT place it') && has(build.prompt, 'origin "handoff"'), '')
    check('A: patch_kernel call has 3 args incl. sites file', has(build.prompt, 'patch_kernel.py /wd/fw/Image /wd/fw/Image.patched /wd/kernel_patch_sites.json'), '')
    check('A: patch_qemu_core no longer in the build agent step list', !has(build.prompt, 'patch_qemu_core.py  (idempotent'), '')
    // memdump derive happened and was recorded
    const planCall = byLabel(r, /^memdump-plan-/)
    check('A: memdump derive attempted with host-line filter', planCall.length >= 1 && has(planCall[0].prompt, 'memdump_observe.py derive') && has(planCall[0].prompt, 'qemu-system-'), planCall[0] && planCall[0].prompt)
    check('A: memdump evidence handed to static-analyzer to record in STATIC.md', byLabel(r, /^memdump-evidence-/).length === 1, '')
    // kernel metrics recorded only when the channel exists
    const goal4 = byLabel(r, /^goal-4$/)[0], goal1 = byLabel(r, /^goal-1$/)[0]
    check('A: round with kernel channel records fp_klast/fp_kuniq', goal4 && has(goal4.prompt, 'fp_klast=12.5') && has(goal4.prompt, 'fp_kuniq=380'), goal4 && goal4.prompt)
    check('A: round without kernel channel keeps its old identity (no fp_k*)', goal1 && !has(goal1.prompt, 'fp_klast') && !has(goal1.prompt, 'fp_kuniq'), goal1 && goal1.prompt)
    check('A: kernel_alive banner-not-observed is recorded', has(goal4.prompt, '배너 미관측'), goal4 && goal4.prompt)
    // medium decision recorded in STATIC.md
    check('A: medium detection recorded in STATIC.md (printf >> STATIC.md)', byLabel(r, /^record-medium/).every(c => has(c.prompt, '>> "/wd/STATIC.md"')) && byLabel(r, /^record-medium/).length >= 1, '')
    // verify wiring
    const v1 = byLabel(r, /^verify-stage1$/)[0], vneg = byLabel(r, /^verify-negative-round$/)[0], v2 = byLabel(r, /^verify-stage1-final$/)[0], vr = byLabel(r, /^verify$/)[0]
    check('A: verify.py gets --round --trace --stage-map --bypass-ledger --memdump-log', v1 && ['--round 4', '--trace "$TRACE"', '--stage-map "$WD/stage_map.json"', '--bypass-ledger "$WD/06_machine/bypasses.md"', '--memdump-log', '--negative-console', '--verify-ok-token', '--shape-budget 120'].every(t => has(v1.prompt, t)), v1 && v1.prompt)
    check('A: verify trace comes from the observation of the last round', v1 && has(v1.prompt, "TRACE='/trace/run.log'"), v1 && v1.prompt)
    check('A: surface none -> no --surface / --input-token passed', v1 && !has(v1.prompt, '--surface') && !has(v1.prompt, '--input-token'), v1 && v1.prompt)
    check('A: no ~/rehost/_traces lookup in the verify command', v1 && !has(v1.prompt, '_traces'), '')
    check('A: negative round after stage 1, before the final stage 1 and the verifier', v1 && vneg && v2 && vr && v1.n < vneg.n && vneg.n < v2.n && v2.n < vr.n, [v1 && v1.n, vneg && vneg.n, v2 && v2.n, vr && vr.n].join(','))
    check('A: negative round makes the image, saves avb_negative.txt (not console_N)', vneg && has(vneg.prompt, 'make_negative_image.py') && has(vneg.prompt, 'avb_negative.txt') && has(vneg.prompt, 'fw/lu0_negative.img') && has(vneg.prompt, 'MEDIUM='), vneg && vneg.prompt)
    check('A: negative round never overwrites fw/lu0.img', vneg && !has(vneg.prompt, '--out "$WD/fw/lu0.img"') && !/>\s*"?\$WD\/fw\/lu0\.img/.test(vneg.prompt), '')
    check('A: negative round number cannot collide with a real round', vneg && has(vneg.prompt, 'N=9004'), vneg && vneg.prompt.slice(0, 200))
    check('A: stale avb_negative.txt cleared before measuring', byLabel(r, /^verify-clear-negative$/).length === 1 && byLabel(r, /^verify-clear-negative$/)[0].n < v1.n, '')
    check('A: verifier is told the count goes in the first lines of VERIFICATION.md', vr && has(vr.prompt, 'FIRST lines') && has(vr.prompt, 'verify_bypass'), '')
    const pk = byLabel(r, /^package$/)[0]
    check('A: package prompt carries the grade text and the negative-test cost', pk && has(pk.prompt, 'F2 (verify_ok 우회 3건)') && has(pk.prompt, 'negative test ran one extra round'), pk && pk.prompt.slice(0, 600))
    check('A: package excludes the negative medium copy', pk && has(pk.prompt, 'NOT fw/lu0_negative.img'), '')
    check('A: grade text logged', r.logs.some(l => has(l, 'F2 (verify_ok 우회 3건)')), r.logs.join('\n'))
    check('A: .sboot_version marker command is the first call', r.calls[0].label === 'workspace-marker' && has(r.calls[0].prompt, '.sboot_version') && has(r.calls[0].prompt, '.claude-plugin/plugin.json'), r.calls[0].prompt)
    check('A: marker never overwrites and skips a resumed workspace', has(r.calls[0].prompt, 'if [ -e "$WS/.sboot_version" ]') && has(r.calls[0].prompt, 'rounds.jsonl'), '')
    check('A: carve/stage_map get --arch in the prior prompt', (() => { const p = byLabel(r, /^analyze$/)[0]; return has(p.prompt, 'pass --arch arm32 --family mediatek to EVERY carve_disasm.py call') && has(p.prompt, '--arch arm32 --profile mediatek --origin container'); })(), '')
    check('A: prior prompt has the channel column + banner-first kernel_alive + hardware-SHA branch', (() => { const p = byLabel(r, /^analyze$/)[0].prompt; return has(p, '<milestone>\\t<token>[\\t<channel>]') && has(p, 'banner\n') !== undefined && has(p, 'HARDWARE') && has(p, 'reached_bypassed') && has(p, 'MEMORY-DUMP CHANNEL'); })(), '')
    check('A: prior prompt no longer calls a surface of none a hard blocker', !has(byLabel(r, /^analyze$/)[0].prompt, '"none" is a hard\n'), '')
    check('A: prior prompt no longer says the images verify unpatched unconditionally', !has(byLabel(r, /^analyze$/)[0].prompt, 'The images are genuinely signed, so verification is expected to\n   PASS unpatched'), '')
    const sup1 = byLabel(r, /^supervisor-1$/)[0], sup4 = byLabel(r, /^supervisor-4$/)[0]
    check('A: before the memory-dump plan the supervisor is told the run sees the UART only', sup1 && has(sup1.prompt, 'Observation channels: UART only') && has(sup1.prompt, 'not evidence about it'), sup1 && sup1.prompt.slice(0, 80))
    check('A: after the plan was derived the channel is reported on', sup4 && has(sup4.prompt, 'Observation channels: UART + memory dump'), sup4 && sup4.prompt.slice(0, 80))
    check('A: the rung -> stage mapping is written for the run script (stage-rungs step)', byLabel(r, /^stage-rungs$/).length === 1 && has(byLabel(r, /^stage-rungs$/)[0].prompt, 'stage_rungs.json'), '')
    check('A: record-blocker not called for none', byLabel(r, /^record-blocker$/).length === 0, '')
  })

  // ---------------------------------------------------------------- B: BLOCKED_ARCH semantics
  await block('B', async () => {
    const r1 = await run(fn, BASE_ARGS, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, arch_supported: false, stages: [] } }))
    check('B: arch_supported=false -> BLOCKED_ARCH', r1.result?.stop_reason === 'BLOCKED_ARCH', JSON.stringify(r1.result))
    check('B: BLOCKED_ARCH names the missing entry signature and keeps "tool gap" wording', has(r1.result?.detail, '진입 시그니처') && has(r1.result?.detail, '펌웨어의 한계가 아니라 도구의 결손'), r1.result?.detail)
    check('B: BLOCKED_ARCH does not claim the signature is "not defined yet"', !has(r1.result?.detail, '아직 정의되지 않았습니다'), r1.result?.detail)
    check('B: BLOCKED_ARCH stops before any build', !r1.calls.some(c => c.label === 'build' || c.label === 'qemu-tree-reset'), '')
    // arm32 alone is not a stop
    const r2 = await run(fn, BASE_ARGS, responder({ obs: () => mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] }), prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [MT_STAGES[0]] }, supervisor: () => ({ route: 'fault-classifier' }) }))
    check('B: arch=arm32 with a derived map is not a stop at analysis', r2.calls.some(c => c.label === 'build'), r2.calls.map(c => c.label).slice(0, 15).join(' '))
    // unconfirmed-only map -> one re-derivation, then proceeds with the confirmed result
    const calls = []
    const r3 = await run(fn, BASE_ARGS, responder({ obs: () => mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] }),
      prior: { ...MT_PRIOR, stages: [{ name: 'preloader', arch: 'aarch32', origin: 'container', state: 'unconfirmed' }] },
      override: async c => { if (c.label === 'analyze-rederive') return { arch_supported: true, new_facts_count: 1, stages: [MT_STAGES[0]] } } }))
    const redo = byLabel(r3, /^analyze-rederive$/)
    check('B: unconfirmed-only map triggers one re-derivation with the candidates', redo.length === 1 && has(redo[0].prompt, 'base.rejected_anchors') && has(redo[0].prompt, 'Family knowledge:'), redo[0] && redo[0].prompt)
    check('B: after re-derivation the exec stage builds the ladder', JSON.stringify(r3.result?.goals?.slice(0, 1)) === JSON.stringify(['preloader_entry']), JSON.stringify(r3.result?.goals))
    check('B: an unconfirmed stage is not documented as a bypass', !r3.logs.some(l => has(l, '각각 우회로 문서화')), r3.logs.join('\n'))
    // a stage that is still unconfirmed after the re-derivation: honest, no BLOCKED_ARCH
    const r4 = await run(fn, BASE_ARGS, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [{ name: 'preloader', state: 'unconfirmed' }] },
      build: { build_ok: false, build_error: 'entry undetermined' },
      override: async c => { if (c.label === 'analyze-rederive') return { arch_supported: true, new_facts_count: 0, stages: [{ name: 'preloader', state: 'unconfirmed' }] } } }))
    check('B: still unconfirmed -> no BLOCKED_ARCH, Build reports (BLOCKED_BUILD)', r4.result?.stop_reason === 'BLOCKED_BUILD', JSON.stringify(r4.result))
    // a stage named kernel gets no rung of its own
    const r5 = await run(fn, BASE_ARGS, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0], { name: 'kernel', arch: 'aarch64', origin: 'handoff', state: 'exec' }] } }))
    check('B: a "kernel" stage does not duplicate kernel_entry', (r5.result?.goals || r5.calls.map(c => c.prompt).join('')).length > 0 && r5.logs.some(l => has(l, '칸을 만들지 않은 스테이지')), r5.logs.join('\n'))
  })

  // ---------------------------------------------------------------- C: exynos path unchanged in kind
  await block('C', async () => {
    const r = await run(fn, { ...BASE_ARGS, soc_family: 'exynos', arch: 'arm64', bl_surface: 'shell', target: 'F1' },
      responder({ family: 'exynos', obs: n => mkObs({ milestone: n === 1 ? 'preloader_entry' : 'shell', milestones_reached: n === 1 ? ['preloader_entry'] : ['preloader_entry', 'shell'] }), prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [A64_STAGE] } }))
    check('C: exynos F1 ladder keeps its surface rung', JSON.stringify(r.result?.goals) === JSON.stringify(['preloader_entry', 'shell']), JSON.stringify(r.result?.goals))
    const core = byLabel(r, /^core-patch$/)[0]
    check('C: exynos gets the SMC-hook patch set', core && has(core.prompt, 'patch_qemu_core.py --family exynos'), core && core.prompt)
    const cls = r.calls.filter(c => c.agentType === 'static-analyzer')[0]
    check('C: family with no profile lists reads (none)', has(cls.prompt, 'Family knowledge: (none)') && has(cls.prompt, 'Runbook: (none)'), cls.prompt.slice(0, 500))
    const build = byLabel(r, /^build$/)[0]
    check('C: aarch64 chain builds from machine_full + storage_hci (medium unknown)', has(build.prompt, '/plug/templates/machine_full.c.tmpl plus /plug/templates/storage_hci.c.tmpl') && !has(build.prompt, 'machine_mixed_arch.c.tmpl" ') , '')
    check('C: F1 build does not call patch_kernel', !has(build.prompt, 'patch_kernel.py'), '')
    check('C: F1 never runs a negative test or a memdump derive', !r.calls.some(c => /^verify-negative-round|^memdump-plan-/.test(c.label)), '')
    check('C: F1 result carries no verify_ok state', r.result && r.result.grade === 'F1', r.result && r.result.grade)
  })

  await block('C2', async () => {
    const r = await run(fn, { ...BASE_ARGS, soc_family: 'generic', target: 'F1' }, responder({ family: 'generic', obs: () => mkObs({ milestones_reached: ['preloader_entry'] }), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    const core = byLabel(r, /^core-patch$/)[0]
    check('C: another family with an AArch32 stage gets the SMC-hook set AND the AArch32 patch (--family all)', core && has(core.prompt, 'patch_qemu_core.py --family all'), core && core.prompt)
    const rm = await run(fn, { ...BASE_ARGS, target: 'F1' }, responder({ obs: () => mkObs({ milestones_reached: ['preloader_entry'] }), prior: { ...MT_PRIOR, stages: [A64_STAGE] }, family: 'mediatek' }))
    check('C: the MediaTek family keeps its own set', has(byLabel(rm, /^core-patch$/)[0].prompt, 'patch_qemu_core.py --family mediatek'), '')
  })

  // ---------------------------------------------------------------- D: family kit failures never stop the run
  await block('D', async () => {
    const r = await run(fn, BASE_ARGS, responder({ kit: { family: 'mediatek', knowledge: [], runbook: '', error: 'unreadable', profile: '' },
      obs: n => mkObs({ milestone: 'x' }), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    check('D: unreadable profile is warned, not fatal', r.logs.some(l => has(l, '프로필을 읽지 못했습니다')) && r.calls.some(c => c.label === 'build'), r.logs.slice(0, 8).join('\n'))
    const p = byLabel(r, /^analyze$/)[0]
    check('D: prompts say (none) when the kit could not be read', has(p.prompt, 'Family knowledge: (none)'), '')
    const r2 = await run(fn, BASE_ARGS, responder({ kit: null, obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    check('D: no kit answer at all is warned, not fatal', r2.logs.some(l => has(l, 'family_kit.py 의 결과를 얻지 못했습니다')) && r2.calls.some(c => c.label === 'build'), '')
    const r3 = await run(fn, BASE_ARGS, responder({ kit: { family: 'mediatek', knowledge: ['knowledge/family_a.md', 'knowledge/nope.md'], runbook: 'knowledge/gone.md', missing: ['knowledge/nope.md', 'knowledge/gone.md'], note: 'n' },
      obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    const p3 = byLabel(r3, /^analyze$/)[0]
    check('D: files the plugin does not have are dropped from the lists', has(p3.prompt, 'Family knowledge: /plug/knowledge/family_a.md\n') && has(p3.prompt, 'Runbook: (none)'), p3.prompt.slice(p3.prompt.indexOf('Family knowledge'), p3.prompt.indexOf('Family knowledge') + 200))
    check('D: a decision is journaled for the family kit', byLabel(r3, /^family-decision$/).length === 1 && has(byLabel(r3, /^family-decision$/)[0].prompt, 'decision'), '')
  })

  // ---------------------------------------------------------------- E: qemu tree cannot be proven clean
  await block('E', async () => {
    const r = await run(fn, BASE_ARGS, responder({ obs: () => mkObs(), tree: { exit_code: 2, error: 'pristine tarball 이 없어 복원할 수 없습니다' } }))
    check('E: tree reset exit 2 -> BLOCKED_ENV', r.result?.stop_reason === 'BLOCKED_ENV', JSON.stringify(r.result))
    check('E: the stderr sentence and /sboot-rehost:init are reported', r.logs.some(l => has(l, 'pristine tarball')) && r.logs.some(l => has(l, '/sboot-rehost:init')), r.logs.join('\n'))
    check('E: nothing is patched or built on an unproven tree', !r.calls.some(c => c.label === 'core-patch' || c.label === 'build'), r.calls.map(c => c.label).join(' '))
    const r2 = await run(fn, BASE_ARGS, responder({ obs: () => mkObs(), core: { exit_code: 1, output: '[FAIL] anchor count 0' } }))
    check('E: core patch failure -> BLOCKED_BUILD, no machine build', r2.result?.stop_reason === 'BLOCKED_BUILD' && !r2.calls.some(c => c.label === 'build'), JSON.stringify(r2.result))
  })

  // ---------------------------------------------------------------- F: round numbering after qemu_abort
  await block('F', async () => {
    const seq = []
    const r = await run(fn, { ...BASE_ARGS, target: 'F1', prior: undefined, bl_surface: 'shell' }, responder({
      prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [MT_STAGES[0]] },
      obs: n => { seq.push(n); return n === 1 ? mkObs({ run_fault: true, run_fault_line: 'assert x' }) : mkObs({ milestone: 'shell', milestones_reached: ['preloader_entry', 'shell'] }) } }))
    const runs = r.calls.filter(c => /^run-\d+$/.test(c.label)).map(c => c.label)
    check('F: round after a qemu_abort is run-2, not run-3', JSON.stringify(runs) === JSON.stringify(['run-1', 'run-2']), runs.join(','))
    check('F: the abort round is still answered by the general fixer', r.calls.some(c => c.label === 'general-1'), '')
  })

  // ---------------------------------------------------------------- G: observed waiting for input
  await block('G', async () => {
    const wait = n => mkObs({ rx_reported: true, rx_polls: 50000, rx_served: 3, exceptions: 0, stall_count: n })
    const r = await run(fn, BASE_ARGS, responder({ obs: wait, prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    check('G: surface none + parked on the console for 2 rounds -> BLOCKED_NO_INPUT_PATH', r.result?.stop_reason === 'BLOCKED_NO_INPUT_PATH', JSON.stringify(r.result && { s: r.result.stop_reason, d: r.result.detail }))
    check('G: it takes the observation, not the derivation (needs INPUT_WAIT_ROUNDS rounds)', r.calls.filter(c => /^run-\d+$/.test(c.label)).length === 2, r.calls.filter(c => /^run-/.test(c.label)).length)
    check('G: the stop is recorded as a blocker', r.calls.some(c => /^record-input-blocker/.test(c.label) && has(c.prompt, 'BLOCKED_NO_INPUT_PATH')), '')
    // a handful of polls is a key check, not a wait
    let n3 = 0
    const r2 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 4 }, responder({ obs: () => mkObs({ rx_reported: true, rx_polls: 7, exceptions: 0 }), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    check('G: a few polls never stop the run', r2.result?.stop_reason !== 'BLOCKED_NO_INPUT_PATH', JSON.stringify(r2.result && r2.result.stop_reason))
    // exceptions mean some other stop point
    const r3 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 4 }, responder({ obs: () => mkObs({ rx_reported: true, rx_polls: 90000, exceptions: 40, origin_type: 'data_abort' }), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    check('G: a stall with exceptions is not "waiting for input"', r3.result?.stop_reason !== 'BLOCKED_NO_INPUT_PATH', JSON.stringify(r3.result && r3.result.stop_reason))
    // a surface that exists is never this stop
    const r4 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 3 }, responder({ obs: wait, prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [MT_STAGES[0]] } }))
    check('G: with a shell surface the wait rule does not apply', r4.result?.stop_reason !== 'BLOCKED_NO_INPUT_PATH', JSON.stringify(r4.result && r4.result.stop_reason))
    // the measured field wins when run_round reports one
    const r5 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 3 }, responder({ obs: () => mkObs({ waiting_for_input: false, rx_reported: true, rx_polls: 99999 }), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    check('G: waiting_for_input=false from run_round overrides the poll heuristic', r5.result?.stop_reason !== 'BLOCKED_NO_INPUT_PATH', JSON.stringify(r5.result && r5.result.stop_reason))
  })

  // ---------------------------------------------------------------- H: boot medium decided by the log
  await block('H', async () => {
    const rr = n => n === 1 ? mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] })
      : mkObs({ milestone: 'lk_entry', milestones_reached: ['preloader_entry', 'lk_entry'] })
    const r = await run(fn, { ...BASE_ARGS, target: 'F1' }, responder({ obs: rr, prior: { ...MT_PRIOR, stages: [MT_STAGES[0], MT_STAGES[2]] },
      medium0: { hci_kind: 'unknown', basis: 'none', confidence: 'none', evidence: [], notes: ['no dtb'] },
      mediumLog: n => ({ hci_kind: 'emmc', basis: 'bootloader_log', confidence: 'high', evidence: ['[SD0] x'] }) }))
    const det = byLabel(r, /^detect-medium-1$/)[0]
    check('H: round 1 asks detect_medium with that round\'s console, host lines removed', det && has(det.prompt, '/wd/07_logs/console_1.txt') && has(det.prompt, 'grep -a -v -E') && has(det.prompt, '--bootloader-log'), det && det.prompt)
    const rb = byLabel(r, /^rebuild-1$/)[0]
    check('H: unknown -> emmc from the log is a build-layer change: machine and medium rebuilt', rb && has(rb.prompt, 'REBUILD') && has(rb.prompt, '--medium emmc') && has(rb.prompt, 'not the UFS host controller'), rb && rb.prompt.slice(0, 500))
    check('H: the rebuild is recorded as build_layer with change_key medium:unknown->emmc', r.calls.some(c => /^medium-rebuild-record-1$/.test(c.label) && has(c.prompt, 'medium:unknown->emmc') && has(c.prompt, 'build_layer')), '')
    check('H: no second detection once the log decided', byLabel(r, /^detect-medium-/).filter(c => c.label !== 'detect-medium').length === 1, byLabel(r, /^detect-medium-/).map(c => c.label).join(','))
    const rbCount = byLabel(r, /^rebuild-/).length
    check('H: rebuilt exactly once', rbCount === 1, rbCount)
    // same answer as the DTB: no rebuild
    const r2 = await run(fn, { ...BASE_ARGS, target: 'F1' }, responder({ obs: rr, prior: { ...MT_PRIOR, stages: [MT_STAGES[0], MT_STAGES[2]] },
      medium0: { hci_kind: 'emmc', basis: 'dtb', confidence: 'medium', evidence: [], notes: [] },
      mediumLog: () => ({ hci_kind: 'emmc', basis: 'bootloader_log', confidence: 'high', evidence: ['l'] }) }))
    check('H: dtb and log agree -> no rebuild', byLabel(r2, /^rebuild-/).length === 0, '')
    // dtb said ufs, the log says emmc
    const r3 = await run(fn, { ...BASE_ARGS, target: 'F1' }, responder({ obs: rr, prior: { ...MT_PRIOR, stages: [MT_STAGES[0], MT_STAGES[2]] },
      medium0: { hci_kind: 'ufs', basis: 'dtb', confidence: 'low', evidence: [], notes: [] },
      mediumLog: () => ({ hci_kind: 'emmc', basis: 'bootloader_log', confidence: 'high', evidence: ['l'] }) }))
    check('H: dtb ufs vs log emmc -> rebuild for emmc', byLabel(r3, /^rebuild-/).length === 1 && has(byLabel(r3, /^rebuild-/)[0].prompt, 'ufs → emmc') === false || byLabel(r3, /^rebuild-/).length === 1, '')
    // an answer that is only "unknown" never overwrites a DTB answer
    const r4 = await run(fn, { ...BASE_ARGS, target: 'F1' }, responder({ obs: rr, prior: { ...MT_PRIOR, stages: [MT_STAGES[0], MT_STAGES[2]] },
      medium0: { hci_kind: 'emmc', basis: 'dtb', confidence: 'medium', evidence: [], notes: [] },
      mediumLog: () => ({ hci_kind: 'unknown', basis: 'none', confidence: 'none', evidence: [] }) }))
    check('H: a log that decides nothing leaves the DTB answer and rebuilds nothing', byLabel(r4, /^rebuild-/).length === 0, '')
    const b0 = byLabel(r4, /^build$/)[0]
    check('H: build with a DTB-decided medium passes --medium', has(b0.prompt, '--medium emmc'), '')
    const rU = await run(fn, { ...BASE_ARGS, target: 'F1' }, responder({ obs: () => mkObs(), prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] } }))
    check('H: an undecided medium passes no --medium and says so', !has(byLabel(rU, /^build$/)[0].prompt, '--medium ') && has(byLabel(rU, /^build$/)[0].prompt, '미확정'), '')
  })

  // ---------------------------------------------------------------- I: guest reset hypothesis
  await block('I', async () => {
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ milestone: 'none', guest_reset_signal: true, guest_reset: { host_line: 'x', after_s: 0.38 } }),
      supervisor: () => ({ route: 'fault-classifier' }),
      classify: () => ({ category: 'guest_reset_after_jump', fixer_ranking: [] }) }))
    const cls = byLabel(r, /^classify-1$/)[0]
    check('I: guest_reset_signal reaches the classifier as a candidate', cls && has(cls.prompt, 'guest_reset_after_jump') && has(cls.prompt, 'HYPOTHESIS'), cls && cls.prompt)
    const esc = byLabel(r, /^escalate-1-reset$/)[0]
    check('I: the named hypothesis is DERIVED (escalation with a focus), not fixed', esc && has(esc.prompt, 'FOCUS:') && has(esc.prompt, 'Do NOT fix it'), esc && esc.prompt)
    check('I: no fixer was asked for a no-owner hypothesis', !r.calls.some(c => /^fixer-/.test(c.label)), r.calls.map(c => c.label).join(' '))
    // supervisor sends it straight to the general fixer: it is re-routed to the classifier
    const r2 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ guest_reset_signal: true }), supervisor: () => ({ route: 'fixer-general' }), classify: () => ({ category: 'guest_reset_after_jump', fixer_ranking: [] }) }))
    check('I: supervisor -> fixer-general with a reset signal is rerouted to the classifier', byLabel(r2, /^classify-1$/).length === 1 && !r2.calls.some(c => c.label === 'general-1' && true && c.n < byLabel(r2, /^classify-1$/)[0].n), r2.calls.map(c => c.label).join(' '))
    // kernel reached: the signal is no longer a stop-point signal
    const r3 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ milestones_reached: ['kernel_alive'], guest_reset_signal: true }) }))
    check('I: with kernel_alive reached the classifier is not pushed towards guest_reset', !r3.calls.some(c => /^classify-/.test(c.label) && has(c.prompt, 'guest_reset_signal is true and kernel_alive was NOT reached')), '')
  })

  // ---------------------------------------------------------------- J: negative test off / unproven
  await block('J', async () => {
    const rounds = { 1: mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] }) }
    const r = await run(fn, { ...BASE_ARGS, target: 'F2', negative_test: false }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: n => mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive'] }) }))
    check('J: negative_test=false runs no negative round', !r.calls.some(c => c.label === 'verify-negative-round'), '')
    check('J: unproven verification is reported, never "passed"', r.result?.verify_bypass?.unproven === true && r.result?.negative_test?.performed === false, JSON.stringify(r.result && [r.result.verify_bypass, r.result.negative_test]))
    check('J: no bypass -> plain grade', r.result?.grade === 'F2' && r.result?.rung_states?.verify_ok === 'reached', JSON.stringify(r.result && [r.result.grade, r.result.rung_states]))
    // UNVERIFIED -> no negative round
    const r2 = await run(fn, { ...BASE_ARGS, target: 'F2' }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, stage1: { verdict: 'UNVERIFIED', gates_passed: 2, gates_total: 3, verify_bypass: { count: 0, unproven: true } },
      verifier: { script_passes: 2, final_passes: 2, final_verdict: 'UNVERIFIED' },
      obs: n => mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive'] }) }))
    check('J: UNVERIFIED stage 1 -> no negative round', !r2.calls.some(c => c.label === 'verify-negative-round') && r2.result?.success === false, '')
    // the verifier may find a bypass the script did not
    const r3 = await run(fn, { ...BASE_ARGS, target: 'F2' }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, neg: { performed: false, skipped_reason: 'no vbmeta' },
      verifier: { script_passes: 3, final_passes: 3, final_verdict: 'VERIFIED', verify_bypass: { count: 1, unproven: true } },
      obs: n => mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive'] }) }))
    check('J: a bypass only the verifier found still counts (max of the two)', r3.result?.verify_bypass?.count === 1 && r3.result?.grade === 'F2 (verify_ok 우회 1건)', JSON.stringify(r3.result && [r3.result.verify_bypass, r3.result.grade]))
    check('J: make_negative_image failure is reported as not performed with its reason', has(r3.result?.negative_test?.reason, 'no vbmeta'), JSON.stringify(r3.result && r3.result.negative_test))
    check('J: only one verify.py run when the negative round did not happen', !r3.calls.some(c => c.label === 'verify-stage1-final'), '')
  })

  // ---------------------------------------------------------------- K: surfaces that exist keep their flags
  await block('K', async () => {
    const r = await run(fn, { ...BASE_ARGS, target: 'F2', soc_family: 'exynos', arch: 'arm64' }, responder({ family: 'exynos', prior: { ...MT_PRIOR, bl_surface: 'fastboot', stages: [MT_STAGES[0]] },
      obs: n => mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'fastboot', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive'] }) }))
    const v1 = byLabel(r, /^verify-stage1$/)[0]
    check('K: fastboot surface passes --surface fastboot --input-token getvar:', v1 && has(v1.prompt, '--surface fastboot') && has(v1.prompt, "--input-token 'getvar:'"), v1 && v1.prompt)
    check('K: surface derivation corrected the hint to fastboot', JSON.stringify(r.result?.goals?.slice(0, 2)) === JSON.stringify(['preloader_entry', 'fastboot']), JSON.stringify(r.result?.goals))
  })

  // ---------------------------------------------------------------- L: hints and routing text
  await block('L', async () => {
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ milestone: 'none', channels: { uart_bytes: 4, kernel_lines: 900, host_lines: 3 }, kernel_uniq: 800, kernel_last_time: 30, kernel_moving: true,
        kernel_alive_evidence: { channel: 'memdump', via: 'alternate', note: '배너 미관측' }, kernel: { gaps: { count: 2, total_s: 3.5, span_s: 60 } }, early_exit: { reason: 'exceptions' } }) }))
    const sup = byLabel(r, /^supervisor-1$/)[0]
    check('L: supervisor sees the kernel channel, the gaps and "banner not observed"', sup && has(sup.prompt, 'kernel_lines=900') && has(sup.prompt, 'kernel log gaps: 2') && has(sup.prompt, 'banner itself was NOT observed') && has(sup.prompt, 'kernel log is moving'), sup && sup.prompt)
    check('L: kernel log gaps are logged as suspected loss', r.logs.some(l => has(l, '커널 로그 유실 의심 2 구간')), r.logs.join('\n'))
    check('L: fingerprint text carries kernel depth', has(sup.prompt, '"kernel_uniq":800'), '')
    check('L: supervisor knows the surface is none and autoboot pending', has(sup.prompt, 'Surface: none') && has(sup.prompt, 'autoboot is pending'), '')
    const r2 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1, max_exceptions: 1000000 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs() }))
    check('L: max_exceptions is passed to the run only when set', has(byLabel(r2, /^run-1$/)[0].prompt, 'MAX_EXCEPTIONS=1000000 TIMEOUT=200 ') && !has(byLabel(r, /^run-1$/)[0].prompt, 'MAX_EXCEPTIONS'), '')
  })

  // ---------------------------------------------------------------- M: every delegation site
  await block('M', async () => {
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 2 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ milestone: 'none', escalate_to_analyst: true }),
      supervisor: n => ({ route: n === 1 ? 'static-analyzer' : 'fault-classifier', prescribed_fixer: 'fixer-memory' }),
      classify: () => ({ category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }, { fixer: 'fixer-kernel', rank: 2 }] }),
      fixer: { fixer: 'x', not_mine: true, no_new_change: false },
      plan: { present: true, derived: true, plan: { region_base: '0x2', region_size: 8192, console_size: 2048 } } }))
    const need = c => has(c.prompt, FAM_LINE + '\n') && has(c.prompt, RB_LINE + '\n')
    const kinds = {
      'static-analyzer prior': byLabel(r, /^analyze$/)[0],
      'escalation': byLabel(r, /^escalate-1$/)[0],
      'memdump evidence': byLabel(r, /^memdump-evidence-/)[0],
      'supervisor': byLabel(r, /^supervisor-1$/)[0],
      'fault-classifier': byLabel(r, /^classify-1$/)[0],
      'specialist fixer': byLabel(r, /^fixer-storage-1$/)[0],
      'general fixer': byLabel(r, /^general-1$/)[0],
      'build': byLabel(r, /^build$/)[0],
    }
    for (const [k, c] of Object.entries(kinds)) check('M: ' + k + ' prompt exists and carries the family kit', !!c && need(c), c ? c.prompt.slice(0, 200) : 'no such call')
    const cls = kinds['fault-classifier']
    check('M: classifier Knowledge tables = common three + the family table', cls && has(cls.prompt, 'Knowledge tables: ' + COMMON.concat(KIT.knowledge).map(plugAbs).join(', ') + '.'), cls && cls.prompt.slice(cls.prompt.indexOf('Knowledge tables'), cls.prompt.indexOf('Knowledge tables') + 220))
    check('M: classifier prompt is no longer the broken "Do not match against the a class" sentence', cls && !has(cls.prompt, 'against the\na class') && !has(cls.prompt, 'against the a class'), '')
    const allDelegated = delegated(r).filter(c => c.agentType !== 'verifier' && c.label !== 'package')
    const lacking = allDelegated.filter(c => !need(c))
    check('M: no delegated prompt (except verifier/package) lacks the family kit (' + allDelegated.length + ' checked)', allDelegated.length >= 8 && lacking.length === 0, lacking.map(c => c.label).join(','))
    check('M: the supervisor prescription and ranking were all asked before the general fixer', ['fixer-memory-1', 'fixer-storage-1', 'fixer-kernel-1'].every(l => r.calls.some(c => c.label === l)) && r.calls.findIndex(c => c.label === 'general-1') > r.calls.findIndex(c => c.label === 'fixer-kernel-1'), r.calls.map(c => c.label).join(' '))
    // the exact set of delegation sites is a closed list
    const labelsOf = new Set(delegated(r).map(c => c.label.replace(/-\d+(-reset)?$/, '')))
    const known = ['analyze', 'build', 'escalate', 'supervisor', 'classify', 'fixer-memory', 'fixer-storage', 'fixer-kernel', 'general', 'memdump-evidence', 'verify', 'package', 'analyze-rederive', 'analyze-tokens', 'rebuild']
    check('M: no delegation site this list does not know about', [...labelsOf].every(l => known.includes(l)), [...labelsOf].join(','))
  })

  // ---------------------------------------------------------------- X: the emitted commands, executed
  await block('X', async () => {
    // every shell command the pipeline emitted in the big MediaTek run parses as bash
    const wd = mktmp('ws'), plug = fakePlugin({})
    const rounds = {
      1: mkObs({ milestone: 'kernel_entry', milestones_reached: ['preloader_entry', 'lk_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry'], trace: '/tr ace/run 4.log' }),
      2: mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'lk_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive'], trace: "/tr ace/it's run.log" }),
    }
    const A = { ...BASE_ARGS, workdir: wd, plugin_dir: plug, bootloader_path: path.join(wd, 'fw dir', 'pre loader.img') }
    const r = await run(fn, A, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0], MT_STAGES[2]] }, obs: n => rounds[n],
      plan: { present: true, derived: true, plan: { region_base: '0x2' } } }))
    const shells = r.calls.filter(c => c.isShell)
    const bad = shells.map(c => [c.label, bashSyntax(c)]).filter(x => x[1])
    check('X: every shell command (' + shells.length + ') and heredoc script parses as bash', bad.length === 0, bad.map(x => x[0] + ': ' + x[1]).join(' | '))

    const sr = r.calls.find(c => c.label === 'stage-rungs')
    const rsr = sh(cmdOf(sr), wd)
    let rungsFile = null; try { rungsFile = JSON.parse(fs.readFileSync(path.join(wd, 'stage_rungs.json'), 'utf8')) } catch (e) {}
    check('X: stage_rungs.json maps each rung to its stage and entry PC', rsr.status === 0 && rungsFile && rungsFile.rungs.length === 2 && rungsFile.rungs[0].rung === 'preloader_entry' && rungsFile.rungs[0].stage === 'preloader' && rungsFile.rungs[0].entry_pc === '0x201004' && rungsFile.rungs[1].rung === 'lk_entry' && rungsFile.rungs[1].index === 1, rsr.stderr + JSON.stringify(rungsFile))
    // --- the verify command, run against a stand-in verify.py that prints its argv
    W(path.join(plug, 'scripts', 'verify.py'), 'import json,sys\nprint(json.dumps(sys.argv[1:]))\n')
    W(path.join(wd, 'milestone_tokens.txt'), 'preloader_entry\tfoo\nverify_ok\tSECURE : Signature verification succeed (boot)\tuart\nkernel_alive\tLinux version\tmemdump\n')
    W(path.join(wd, '07_logs', 'kernel_2.log'), '0.000000 Linux version x\n')
    W(path.join(wd, 'verify_ref', 'kernel_Image.img'), 'k')
    const v = r.calls.find(c => c.label === 'verify-stage1')
    const rv = sh(cmdOf(v), wd)
    let argv = []; try { argv = JSON.parse(rv.stdout) } catch (e) {}
    const arg = f => argv[argv.indexOf(f) + 1]
    check('X: verify command runs and passes the round', rv.status === 0 && arg('--round') === '2', rv.stdout + rv.stderr)
    check('X: verify gets the trace path from the observation, with spaces and a quote intact', arg('--trace') === "/tr ace/it's run.log", JSON.stringify(argv))
    check('X: verify gets the memdump log, the kernel image and the stage map', arg('--memdump-log') === path.join(wd, '07_logs', 'kernel_2.log') && arg('--kernel') === path.join(wd, 'verify_ref', 'kernel_Image.img') && arg('--stage-map') === path.join(wd, 'stage_map.json'), JSON.stringify(argv))
    check('X: the verify_ok token (with spaces) arrives as ONE argument', arg('--verify-ok-token') === 'SECURE : Signature verification succeed (boot)', JSON.stringify(argv))
    check('X: container path with a space stays one argument', arg('--container') === path.join(wd, 'fw dir', 'pre loader.img'), JSON.stringify(argv))
    check('X: --bypass-ledger and --negative-console and --shape-budget are passed', arg('--bypass-ledger') === path.join(wd, '06_machine', 'bypasses.md') && arg('--negative-console') === path.join(wd, '07_logs', 'avb_negative.txt') && arg('--shape-budget') === '120', JSON.stringify(argv))
    fs.rmSync(path.join(wd, '07_logs', 'kernel_2.log')); fs.rmSync(path.join(wd, 'verify_ref'), { recursive: true }); fs.rmSync(path.join(wd, 'milestone_tokens.txt'))
    const rv2 = sh(cmdOf(v), wd); let argv2 = []; try { argv2 = JSON.parse(rv2.stdout) } catch (e) {}
    check('X: flags with nothing behind them are left out (no kernel log, no kernel image, no token)', !argv2.includes('--memdump-log') && !argv2.includes('--kernel') && !argv2.includes('--verify-ok-token'), JSON.stringify(argv2))
  })
  await block('X1', async () => {
    // --- the negative round, executed against stand-in scripts
    const wd = mktmp('ws'), plug = fakePlugin({
      'make_negative_image.py': 'import os,sys,json,shutil\nwd=sys.argv[1]\nif os.path.exists(os.path.join(wd,"FAIL_MAKE")):\n    print(json.dumps({"ok":False,"reason":"no vbmeta"})); sys.exit(1)\nshutil.copyfile(os.path.join(wd,"fw","lu0.img"), os.path.join(wd,"fw","lu0_negative.img"))\nprint(json.dumps({"ok":True}))\n',
      'run_full.sh': '#!/usr/bin/env bash\nWD="$1"; N="$5"\necho "$MEDIUM" > "$WD/medium_used.txt"; echo "T=$TIMEOUT P=$TIMEOUT_PROBE args=$*" > "$WD/run_args.txt"\nmkdir -p "$WD/07_logs"\nprintf "guest line one\\nHash does not match\\n" > "$WD/07_logs/console_$N.txt"\nprintf "0.1 kern line\\n" > "$WD/07_logs/kernel_$N.log"\necho "run $N" > "$WD/07_logs/run_$N.summary.txt"\necho OVERWRITTEN > "$WD/fingerprint.json"; echo OVERWRITTEN > "$WD/fingerprint.prev.json"; echo OVERWRITTEN > "$WD/input_summary.json"\n',
    })
    W(path.join(wd, 'fw', 'lu0.img'), 'ORIGINAL-MEDIUM-BYTES')
    W(path.join(wd, 'fingerprint.json'), 'REAL-FP'); W(path.join(wd, 'fingerprint.prev.json'), 'REAL-PREV'); W(path.join(wd, 'input_summary.json'), 'REAL-IN')
    W(path.join(wd, '07_logs', 'console_4.txt'), 'real round 4 console')
    const rounds = { 1: mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive'] }) }
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: plug, bootloader_path: '/fw/pre.img' }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: n => rounds[n] }))
    const neg = r.calls.find(c => c.label === 'verify-negative-round')
    const rn = sh(cmdOf(neg), wd)
    check('X: negative round command runs', rn.status === 0 && has(rn.stdout, 'negative_round=done'), rn.stdout + rn.stderr)
    check('X: it ran on the negative copy, never on lu0.img', fs.readFileSync(path.join(wd, 'medium_used.txt'), 'utf8').trim() === path.join(wd, 'fw', 'lu0_negative.img'), '')
    check('X: the original medium is untouched', fs.readFileSync(path.join(wd, 'fw', 'lu0.img'), 'utf8') === 'ORIGINAL-MEDIUM-BYTES', '')
    check('X: avb_negative.txt = guest UART console + kernel log text of that round (the "<seconds> " prefix taken off)', fs.readFileSync(path.join(wd, '07_logs', 'avb_negative.txt'), 'utf8') === 'guest line one\nHash does not match\nkern line\n', fs.readFileSync(path.join(wd, '07_logs', 'avb_negative.txt'), 'utf8'))
    check('X: fingerprint.json, fingerprint.prev.json, input_summary.json are put back', ['fingerprint.json:REAL-FP', 'fingerprint.prev.json:REAL-PREV', 'input_summary.json:REAL-IN'].every(x => { const [f, v] = x.split(':'); return fs.readFileSync(path.join(wd, f), 'utf8') === v }), '')
    check('X: no file of the negative round number is left behind (no console_9001)', !fs.existsSync(path.join(wd, '07_logs', 'console_9001.txt')) && !fs.existsSync(path.join(wd, '07_logs', 'kernel_9001.log')) && !fs.existsSync(path.join(wd, '07_logs', 'run_9001.summary.txt')), fs.readdirSync(path.join(wd, '07_logs')).join(','))
    check('X: a real round\'s own files are not touched', fs.readFileSync(path.join(wd, '07_logs', 'console_4.txt'), 'utf8') === 'real round 4 console', '')
    check('X: the probe is off and the timeout is the run timeout', has(fs.readFileSync(path.join(wd, 'run_args.txt'), 'utf8'), 'T=200 P=0') && has(fs.readFileSync(path.join(wd, 'run_args.txt'), 'utf8'), ' 9001 '), fs.readFileSync(path.join(wd, 'run_args.txt'), 'utf8'))
    check('X: the reported console size is the real one', has(rn.stdout, 'console_bytes=' + fs.statSync(path.join(wd, '07_logs', 'avb_negative.txt')).size), rn.stdout)
    // the image cannot be made
    fs.rmSync(path.join(wd, 'medium_used.txt')); W(path.join(wd, 'FAIL_MAKE'), '')
    const rn2 = sh(cmdOf(neg), wd)
    check('X: when the damaged image cannot be made no round is run', has(rn2.stdout, 'negative_round=skipped') && !fs.existsSync(path.join(wd, 'medium_used.txt')), rn2.stdout + rn2.stderr)
  })
  await block('X2', async () => {
    // --- workspace marker, executed
    const plug = fakePlugin({})
    const mk = async wd => { const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: plug }, async c => c.label === 'check-version' ? { ok: false, state: 'stale', problems: ['x'] } : undefined); return r.calls[0] }
    const ws1 = mktmp('ws'); const c1 = await mk(ws1)
    sh(cmdOf(c1), ws1)
    check('X: a new workspace gets .sboot_version = the plugin version', fs.existsSync(path.join(ws1, '.sboot_version')) && fs.readFileSync(path.join(ws1, '.sboot_version'), 'utf8') === '9.9.9\n', fs.existsSync(path.join(ws1, '.sboot_version')) && fs.readFileSync(path.join(ws1, '.sboot_version'), 'utf8'))
    W(path.join(plug, '.claude-plugin', 'plugin.json'), '{"version": "1.2.3"}')
    sh(cmdOf(c1), ws1)
    check('X: it is never overwritten (a later release does not claim the workspace)', fs.readFileSync(path.join(ws1, '.sboot_version'), 'utf8') === '9.9.9\n', '')
    const ws2 = mktmp('ws'); W(path.join(ws2, 'rounds.jsonl'), '{}\n')
    sh(cmdOf(c1).replace(ws1, ws2), ws2)
    check('X: a resumed workspace that already holds a run is left unmarked on purpose', !fs.existsSync(path.join(ws2, '.sboot_version')), '')
    const ws3 = mktmp('ws'); fs.rmSync(path.join(plug, '.claude-plugin'), { recursive: true })
    const o3 = sh(cmdOf(c1).replace(ws1, ws3), ws3)
    check('X: no readable plugin version -> no marker, and no failure', !fs.existsSync(path.join(ws3, '.sboot_version')) && o3.status === 0, o3.stdout + o3.stderr)
  })
  await block('X3', async () => {
    // --- detect_medium command, executed against a stand-in that prints its argv and the log it was given
    const wd = mktmp('ws'), plug = fakePlugin({ 'detect_medium.py': 'import sys,json\nlog=""\nargs=sys.argv[1:]\nif "--bootloader-log" in args: log=open(args[args.index("--bootloader-log")+1]).read()\nprint(json.dumps({"argv":args,"log":log}))\n' })
    W(path.join(wd, 'fw', 'a.dtb'), 'd'); W(path.join(wd, '02_unpacked', 'b.dtb'), 'd')
    W(path.join(wd, '07_logs', 'console_1.txt'), 'old console\n')
    const consoleNow = path.join(wd, '07_logs', 'console_2.txt')
    W(consoleNow, 'guest: [SD0] Initialized, eMMC45\nqemu-system-aarch64: info: rehost: UFS thing\n1791000000.5 qemu-system-aarch64: info: x\n')
    const rounds = { 1: mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] }) }
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: plug, target: 'F1', bootloader_path: path.join(wd, 'pre.img') }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: n => rounds[n],
      medium0: { hci_kind: 'unknown', basis: 'none' } }))
    const d0 = r.calls.find(c => c.label === 'detect-medium'), d1 = r.calls.find(c => c.label === 'detect-medium-1')
    const o0 = JSON.parse(sh(cmdOf(d0), wd).stdout)
    check('X: Build-time detection passes the container and every staged *.dtb', o0.argv.filter((a, i) => o0.argv[i - 1] === '--dtb').sort().join('|') === [path.join(wd, 'pre.img'), path.join(wd, 'fw', 'a.dtb'), path.join(wd, '02_unpacked', 'b.dtb')].sort().join('|'), JSON.stringify(o0.argv))
    check('X: Build-time detection takes the newest console an earlier run left, when there is one', o0.argv.includes('--bootloader-log'), JSON.stringify(o0.argv))
    W(path.join(wd, '07_logs', 'console_1.txt'), 'round one console\nguest: eMMC init ok\n')
    const o1 = JSON.parse(sh(cmdOf(d1), wd).stdout)
    check('X: per-round detection reads that round\'s console, QEMU host lines removed (with or without a timestamp)', o1.argv.includes('--bootloader-log') && !has(o1.log, 'qemu-system') && has(o1.log, 'eMMC init ok'), JSON.stringify(o1))
    check('X: the temporary filtered copy does not survive', !fs.existsSync(path.join(wd, '07_logs', '.guest_for_detect.txt')), '')
  })
  await block('X4', async () => {
    // --- memdump derive command, executed against the REAL memdump_observe.py
    const wd = mktmp('ws')
    const rounds = { 1: mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] }) }
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: repo, target: 'F2' }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: n => rounds[n] }))
    const pc = r.calls.find(c => /^memdump-plan-1$/.test(c.label))
    const lines = ['bootloader banner', '[0200] reserve-R[3].start: 0x50100000, size: 0x40000 map:0 name:pstore',
      'RAM_CONSOLE pstore_addr:0x50100000, pstore_size:0x40000, pstore_console_size:0x20000, pstore_pmsg_size:0x8000',
      'qemu-system-aarch64: info: rehost: reserve-R[9].start: 0x70000000, size: 0x1000 map:0 name:pstore',
      '1791000000.5 qemu-system-aarch64: info: rehost: pstore_addr:0x71000000, pstore_size:0x2000']
    W(path.join(wd, '07_logs', 'console_1.txt'), lines.join('\n') + '\n')
    const rd = sh(cmdOf(pc), wd)
    check('X: derive command writes memdump_plan.json from the bootloader\'s own lines', rd.status === 0 && has(rd.stdout, 'plan_status=derived') && fs.existsSync(path.join(wd, 'memdump_plan.json')), rd.stdout + rd.stderr)
    const plan = fs.existsSync(path.join(wd, 'memdump_plan.json')) ? JSON.parse(fs.readFileSync(path.join(wd, 'memdump_plan.json'), 'utf8')) : {}
    check('X: our own host lines (a conflicting region) were not read as the bootloader\'s', plan.region_base === '0x50100000' && plan.region_size === 262144 && plan.console_size === 131072, JSON.stringify(plan))
    check('X: no temporary file is left in the workspace', fs.readdirSync(wd).filter(f => f.startsWith('.memdump')).length === 0, fs.readdirSync(wd).join(','))
    const rd2 = sh(cmdOf(pc), wd)
    check('X: a plan that exists is reported present and not re-derived', has(rd2.stdout, 'plan_status=present'), rd2.stdout)
    // a ring with no capacity is not written
    fs.rmSync(path.join(wd, 'memdump_plan.json'))
    W(path.join(wd, '07_logs', 'console_1.txt'), '[0200] reserve-R[3].start: 0x50100000, size: 0x40000 map:0 name:pstore\n')
    const rd3 = sh(cmdOf(pc), wd)
    check('X: a region without a derived ring capacity writes no plan', has(rd3.stdout, 'plan_status=none') && !fs.existsSync(path.join(wd, 'memdump_plan.json')), rd3.stdout + rd3.stderr)
    // nothing about a ring
    W(path.join(wd, '07_logs', 'console_1.txt'), 'just boot noise\n')
    const rd4 = sh(cmdOf(pc), wd)
    check('X: a console that names no ring writes no plan and is not an error', has(rd4.stdout, 'plan_status=none') && !fs.existsSync(path.join(wd, 'memdump_plan.json')), rd4.stdout + rd4.stderr)
    // conflicting regions from the bootloader's own lines are refused
    W(path.join(wd, '07_logs', 'console_1.txt'), 'RAM_CONSOLE pstore_addr:0x1000, pstore_size:0x2000, pstore_console_size:0x100\nRAM_CONSOLE pstore_addr:0x9000, pstore_size:0x2000, pstore_console_size:0x100\n')
    const rd5 = sh(cmdOf(pc), wd)
    check('X: conflicting sources are refused, not guessed', has(rd5.stdout, 'plan_status=none') && !fs.existsSync(path.join(wd, 'memdump_plan.json')), rd5.stdout + rd5.stderr)
  })
  await block('X5', async () => {
    // --- qemu_tree reset / core patch commands report their exit codes
    const wd = mktmp('ws'), plug = fakePlugin({ 'qemu_tree.sh': '#!/usr/bin/env bash\necho \'{"action":"reset","restored":[],"removed":[],"absent":[],"noop":true}\'\nexit ${FAKE_TREE_EXIT:-0}\n', 'patch_qemu_core.py': 'import sys\nprint("ARGS", sys.argv[1:])\nsys.exit(0)\n' })
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: plug, target: 'F1' }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs({ milestones_reached: ['preloader_entry'] }) }))
    const t = r.calls.find(c => c.label === 'qemu-tree-reset'), c2 = r.calls.find(c => c.label === 'core-patch')
    const o = sh(cmdOf(t), wd, { FAKE_TREE_EXIT: '2' })
    check('X: the reset command reports qemu_tree.sh\'s own exit code', has(o.stdout, 'qemu_tree_exit=2'), o.stdout)
    const o2 = sh(cmdOf(c2), wd)
    check('X: the core patch command passes the family set and reports its exit code', has(o2.stdout, "'--family', 'mediatek'") && has(o2.stdout, 'patch_exit=0'), o2.stdout)
  })

  // ---------------------------------------------------------------- R: the emitted commands against the REAL scripts
  await block('R1', async () => {
    const wd = mktmp('ws')
    W(path.join(wd, 'bl.bin'), 'x'.repeat(4096))
    W(path.join(wd, '07_logs', 'console_1.txt'), 'preloader banner\n[SD0] Initialized, eMMC45\nqemu-system-aarch64: info: rehost: ufshcd init\n')
    W(path.join(wd, '06_machine', 'machine_full.c'), 'int x;\n')
    W(path.join(wd, '06_machine', 'bypasses.md'), '### #1 x\n- 대상: a\n- 이유: b\n- 방법: c\n- 부작용: d\n')
    W(path.join(wd, 'stage_map.json'), '{}')
    const obs = mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'kernel_entry', 'kernel_alive'], trace: path.join(wd, 'trace.log') })
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: repo, bootloader_path: path.join(wd, 'bl.bin'), runtime_round_cap: 3, negative_test: false },
      responder({ prior: { ...MT_PRIOR, stages: [A64_STAGE] }, obs: () => obs }))
    const parse = out => { try { return JSON.parse(out) } catch (e) { return null } }
    const v1 = r.calls.find(c => c.label === 'verify-stage1')
    const rv = sh(cmdOf(v1), wd)
    const jv = parse(rv.stdout)
    check('R: the real verify.py accepts every flag of the emitted verify command and measures', rv.status === 0 && jv && jv.verdict && jv.verify_bypass && jv.flow === 'unified', rv.stdout.slice(0, 200) + rv.stderr.slice(0, 300))
    const pp = r.calls.find(c => c.label === 'verify-prep')
    const rp = sh(cmdOf(pp), wd)
    check('R: the real verify_prep.py accepts the emitted prep command and reports ok', rp.status === 0 && /"ok": true/.test(rp.stdout), rp.stdout.slice(0, 200) + rp.stderr.slice(0, 300))
    const d1 = r.calls.find(c => c.label === 'detect-medium-1')
    const rd = sh(cmdOf(d1), wd)
    const jd = parse(rd.stdout)
    check('R: the real detect_medium.py reads the bootloader\'s eMMC line and ignores our own host line naming UFS', rd.status === 0 && jd && jd.hci_kind === 'emmc' && jd.basis === 'bootloader_log', rd.stdout.slice(0, 300) + rd.stderr.slice(0, 200))
    const sf = await run(fn, { ...BASE_ARGS, soc_family: 'exynos', arch: 'arm64', workdir: wd, plugin_dir: repo, bootloader_path: path.join(wd, 'bl.bin'), runtime_round_cap: 3, negative_test: false },
      responder({ family: 'exynos', prior: { ...MT_PRIOR, bl_surface: 'shell', stages: [A64_STAGE] }, obs: () => mkObs({ milestone: 'kernel_alive', milestones_reached: ['preloader_entry', 'shell', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive'], trace: path.join(wd, 'trace.log') }) }))
    const rs = sh(cmdOf(sf.calls.find(c => c.label === 'verify-stage1')), wd)
    check('R: the real verify.py accepts --surface shell --input-token help as well', rs.status === 0 && parse(rs.stdout) && parse(rs.stdout).verdict, rs.stdout.slice(0, 200) + rs.stderr.slice(0, 300))
  })

  await block('R2', async () => {
    // The prompts name flags of scripts the PIPELINE does not run (an agent does). They must exist.
    const help = (script, ...a) => { const r = spawnSync('python3', [path.join(repo, 'scripts', script), ...a], { encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } }); return r.stdout + r.stderr }
    const src = fs.readFileSync(PJ, 'utf8')
    const pairs = [
      ['build_lu.py', ['--help'], ['--medium', '--family'], 'build_lu.py --medium/--family'],
      ['carve_disasm.py', ['--help'], ['--arch', '--family', 'carve_check'], 'carve_disasm.py --arch/--family'],
      ['stage_map.py', ['--help'], ['--origin', '--partition', '--arch', '--profile', '--out'], 'stage_map.py --origin/--partition/--arch/--profile/--out'],
      ['patch_qemu_core.py', ['--help'], ['--family'], 'patch_qemu_core.py --family'],
      ['memdump_observe.py', ['derive', '--help'], ['--bootloader-log', '--cmdline-file', '--out'], 'memdump_observe.py derive'],
      ['verify_prep.py', ['--help'], ['--round', '--flatten', '--label'], 'verify_prep.py'],
      ['detect_medium.py', ['--help'], ['--dtb', '--bootloader-log'], 'detect_medium.py'],
      ['patch_kernel.py', [], ['<Image>', '<Image.patched>', '<sites.json>'], 'patch_kernel.py (three arguments)'],
    ]
    for (const [script, args_, flags, what] of pairs) {
      const out_ = help(script, ...args_)
      check('R: ' + what + ' takes what the pipeline asks for', flags.every(f => out_.includes(f)), flags.filter(f => !out_.includes(f)).join(',') + ' missing from ' + script)
    }
    const tree = spawnSync('bash', [path.join(repo, 'scripts', 'qemu_tree.sh')], { encoding: 'utf8' })
    check('R: qemu_tree.sh knows reset and record', /reset\|status\|record/.test(tree.stderr + tree.stdout), tree.stderr + tree.stdout)
  })

  // ---------------------------------------------------------------- N: rungs and rebuild details
  await block('N1', async () => {
    const stages = [
      { name: 'lk', arch: 'aarch32', origin: 'medium', state: 'exec' },
      { name: 'lk', arch: 'aarch32', origin: 'medium', state: 'exec' },
      { name: 'BL 2/x', arch: 'aarch64', origin: 'handoff', state: 'exec' },
      { name: 'enc', arch: 'aarch64', origin: 'container', state: 'encrypted' },
    ]
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1, bl_surface: 'shell' }, responder({ prior: { ...MT_PRIOR, bl_surface: 'shell', stages }, obs: () => mkObs() }))
    const g = (r.calls.find(c => c.label === 'run-1') || {}).prompt || ''
    check('N: duplicate stage names get distinct rungs, odd characters are replaced, an ordinary name is untouched',
      has(g, "'lk_entry,lk1_entry,BL_2_x_entry,shell,medium_up") || has(g, 'lk_entry,lk1_entry,BL_2_x_entry,shell,medium_up'), g.slice(g.indexOf('run_round.sh'), g.indexOf('run_round.sh') + 300))
    check('N: an encrypted stage gets no rung and is logged as a skip to be documented', r.logs.some(l => has(l, '건너뛰는 스테이지 1개') && has(l, 'enc(encrypted)')), r.logs.join('\n'))
  })
  await block('N2', async () => {
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs(),
      supervisor: () => ({ route: 'rebuild', layer: 'build', build_change: { change_key: 'entry-pc', change: 'enter at the derived entry', reason: 'wrong premise' } }) }))
    const rb = byLabel(r, /^rebuild-1$/)[0]
    check('N: a supervisor rebuild goes through the same build agent, with the family kit and the exact change', rb && has(rb.prompt, 'REBUILD') && has(rb.prompt, 'enter at the derived entry') && has(rb.prompt, FAM_LINE + '\n'), rb && rb.prompt.slice(0, 300))
    check('N: the rebuild does not reset the QEMU tree or re-apply the core patch', byLabel(r, /^qemu-tree-reset$/).length === 1 && byLabel(r, /^core-patch$/).length === 1, r.calls.map(c => c.label).join(' '))
  })

  // ---------------------------------------------------------------- U: what kernel_alive says about the banner
  // A UART match is a plain string match: its record carries no `via`, so nothing measured whether
  // the banner was seen. The pipeline must not write "banner observed" for it.
  await block('U', async () => {
    const ALL = ['preloader_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive']
    const UART_EV = { channel: 'uart', note: 'UART 콘솔 토큰 일치 — 커널 시각·태스크 접두는 검증하지 않음' }
    const MEM_BANNER = { channel: 'memdump', token: 'Linux version', kernel_time: 0, task: 'swapper', banner: true, via: 'banner', note: '' }
    const MEM_ALT = { channel: 'memdump', token: 'Freeing unused kernel memory', kernel_time: 12.5, task: 'swapper', banner: false, via: 'alternate', note: '배너(Linux version) 미관측 — 대체 토큰으로 판정' }
    const go = ev => run(fn, { ...BASE_ARGS, runtime_round_cap: 3, negative_test: false },
      responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs({ milestone: 'kernel_alive', milestones_reached: ALL, kernel_alive_evidence: ev }) }))
    const goal1 = r => (byLabel(r, /^goal-1$/)[0] || {}).prompt || ''
    const rU = await go(UART_EV), rB = await go(MEM_BANNER), rA = await go(MEM_ALT), rN = await go(null)
    check('U: UART kernel_alive is journaled as "banner not verified"', has(goal1(rU), '배너 관측 여부 미검증'), goal1(rU))
    check('U: ... and never as "banner observed"', !/배너 관측(?! 여부)/.test(goal1(rU)) && !has(goal1(rU), '배너 미관측'), goal1(rU))
    check('U: a memdump hit that says via=banner is journaled as observed', /— 배너 관측(?! 여부)/.test(goal1(rB)) && !has(goal1(rB), '미검증'), goal1(rB))
    check('U: an alternate token is journaled as banner NOT observed', has(goal1(rA), '배너 미관측 (대체 토큰으로 판정)'), goal1(rA))
    check('U: no evidence record at all is said, not defaulted', has(goal1(rN), 'kernel_alive 근거 기록 없음'), goal1(rN))
    check('U: the result carries what kernel_alive rests on',
      rU.result?.kernel_alive_basis?.banner === 'unverified' && rU.result?.kernel_alive_basis?.channel === 'uart' &&
      rB.result?.kernel_alive_basis?.banner === 'observed' && rA.result?.kernel_alive_basis?.banner === 'not_observed' &&
      rN.result?.kernel_alive_basis?.banner === 'unknown', JSON.stringify([rU, rB, rA, rN].map(x => x.result?.kernel_alive_basis)))
    const supU = byLabel(rU, /^supervisor-1$/)[0]
    check('U: the supervisor is told the UART banner is not verified (not "observed", not "missing")', supU && has(supU.prompt, 'is NOT verified') && !has(supU.prompt, 'banner itself was NOT observed'), supU && supU.prompt.slice(0, 200))
    check('U: the kit README is told to say "NOT VERIFIED" for a UART match', has((byLabel(rU, /^package$/)[0] || {}).prompt, 'kernel banner is NOT VERIFIED') && has((byLabel(rB, /^package$/)[0] || {}).prompt, 'kernel banner is OBSERVED'), '')
    const an = byLabel(rU, /^analyze$/)[0].prompt
    check('U: the analyst is told the timestamp-and-task bar is the memdump channel\'s', has(an, '- memdump: an alternate counts only when its line carries a kernel timestamp') && has(an, '- uart: a plain string match') && has(an, 'NOT VERIFIED on this channel'), an.slice(an.indexOf('kernel_entry'), an.indexOf('kernel_entry') + 900))
    check('U: the old sentence that gave BOTH channels the timestamp bar is gone', !has(an, 'An alternate counts only when its line carries a kernel\n   timestamp and the task'), '')
  })

  // ---------------------------------------------------------------- Q: a stop knows what the ledger holds
  await block('Q', async () => {
    const SKIP = ['preloader_entry', 'verify_ok']        // medium_up, partitions never seen
    const stopRun = (extra, cfg) => run(fn, { ...BASE_ARGS, ...extra }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: n => mkObs({ milestone: 'verify_ok', milestones_reached: SKIP, stop: n === 2, stop_reason: n === 2 ? 'EXHAUSTED' : null }),
      supervisor: n => ({ route: n === 2 ? 'stop' : 'fault-classifier' }), ...cfg }))
    const r = await stopRun({}, { stopBypass: { f_rows: 2, ledger: 'present' } })
    const res = r.result || {}
    check('Q: the run stopped on the measured stop', res.stopped === true && res.stop_reason === 'EXHAUSTED', JSON.stringify([res.stopped, res.stop_reason]))
    check('Q: verify_ok observed behind 2 ledger bypass rows is reached_bypassed in the stop result', res.rung_states?.verify_ok === 'reached_bypassed', JSON.stringify(res.rung_states))
    check('Q: a rung stepped over (never seen) is still not_reached', res.rung_states?.medium_up === 'not_reached' && res.rung_states?.preloader_entry === 'reached', JSON.stringify(res.rung_states))
    check('Q: the stop result says how many and on what basis', res.verify_bypass?.count === 2 && res.verify_bypass?.assessed === true && has(res.verify_bypass?.basis, '표지 F'), JSON.stringify(res.verify_bypass))
    check('Q: the stop is logged with the count', r.logs.some(l => has(l, 'reached_bypassed') && has(l, '2건')), r.logs.join('\n'))
    const sc = byLabel(r, /^session-close-stop$/)[0]
    check('Q: the session-end line counts OBSERVED rungs (2/6), not the index the loop advanced to (4/6)', sc && has(sc.prompt, '도달 2/6') && !has(sc.prompt, '도달 4/6'), sc && sc.prompt)
    check('Q: the journal also carries the bypass state at the stop', sc && has(sc.prompt, 'journal.sh') && has(sc.prompt, '검증 우회(표지 F) 2건'), sc && sc.prompt)
    check('Q: the ledger is asked after the stop was decided, before the hand-over is closed', (() => { const o = r.calls.map(c => c.label); return o.indexOf('stop-report') < o.indexOf('stop-bypass-count') && o.indexOf('stop-bypass-count') < o.indexOf('session-close-stop') })(), r.calls.map(c => c.label).join(' '))
    // no ledger rows: plain reached
    const r0 = await stopRun({}, { stopBypass: { f_rows: 0, ledger: 'present' } })
    check('Q: no flagged row -> verify_ok stays plain reached', r0.result?.rung_states?.verify_ok === 'reached' && r0.result?.verify_bypass?.count === 0, JSON.stringify(r0.result && [r0.result.rung_states, r0.result.verify_bypass]))
    // the ledger could not be read: not zero, and said
    const rn = await stopRun({}, { override: async c => c.label === 'stop-bypass-count' ? null : undefined })
    check('Q: an unreadable ledger is "not assessed", never silently zero', rn.result?.verify_bypass?.assessed === false && rn.result?.verify_bypass?.count === null && rn.logs.some(l => has(l, '판정하지 못했습니다')), JSON.stringify(rn.result?.verify_bypass))
    // verify_ok never observed: nothing to qualify, nothing asked
    const rv = await run(fn, { ...BASE_ARGS }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: n => mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'], stop: n === 1, stop_reason: n === 1 ? 'EXHAUSTED' : null }), supervisor: () => ({ route: 'stop' }) }))
    check('Q: verify_ok not observed -> the ledger is not read for it', !rv.calls.some(c => c.label === 'stop-bypass-count') && rv.result?.rung_states?.verify_ok === 'not_reached', JSON.stringify(rv.result?.rung_states))
    // the runtime round cap is a stop too
    const rc = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ milestone: 'verify_ok', milestones_reached: SKIP }), stopBypass: { f_rows: 1, ledger: 'present' } }))
    check('Q: RUNTIME_ROUND_CAP reports verify_ok reached_bypassed too', rc.result?.stop_reason === 'RUNTIME_ROUND_CAP' && rc.result?.rung_states?.verify_ok === 'reached_bypassed' && rc.result?.verify_bypass?.count === 1, JSON.stringify(rc.result && [rc.result.stop_reason, rc.result.rung_states, rc.result.verify_bypass]))
    const cap = byLabel(rc, /^resume-round-cap$/)[0]
    check('Q: the round-cap hand-over counts observed rungs (2/6), not the advanced index', cap && has(cap.prompt, '도달 2/6') && has(cap.prompt, '검증 우회(표지 F) 1건'), cap && cap.prompt)
  })
  await block('Q2', async () => {
    // --- the emitted ledger command, executed, against the REAL ledger parser (verify_gates.parse_ledger).
    // The two must agree on what an F-marked entry is; a ledger shape one of them reads differently is drift.
    const wd = mktmp('ws')
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] },
      obs: () => mkObs({ milestone: 'verify_ok', milestones_reached: ['preloader_entry', 'verify_ok'] }) }))
    const call = r.calls.find(c => c.label === 'stop-bypass-count')
    check('Q: the ledger command was emitted and parses as bash', !!call && bashSyntax(call) === '', call && bashSyntax(call))
    const meta = (kinds, marks) => `- 메타: 종류=${kinds}; 표지=${marks}; 출처=A; 도출=semi\n`
    const entry = (id, m) => `### #${id} 우회 ${id}\n- 대상: t${id}\n- 이유: r\n- 방법: m\n- 부작용: s\n${m}\n`
    const FX = {
      'two flagged of three entries': [entry(1, meta('P', 'F,L')) + entry(2, meta('S', 'K')) + entry(3, '') + entry(4, meta('P', 'L, F')), 2],
      'bold meta label': ['### #1 x\n- 대상: a\n- **메타**: 종류=P; 표지=L,F; 출처=A\n- 이유: r\n', 1],
      'full-width colon and semicolon': ['### #1 x\n- 대상: a\n- 메타：종류=P； 표지=F\n', 1],
      'a fenced block holds a fake heading and a fake flag': ['### #1 x\n- 대상: a\n- 메타: 표지=L\n```\n### #9 fake\n- 메타: 표지=F\n```\n', 0],
      'two meta lines in one entry count once': ['### #1 x\n- 대상: a\n- 메타: 표지=F\n- 메타: 표지=F,L\n### #2 y\n- 대상: b\n', 1],
      'no flag, dash and an invalid word': ['### #1 x\n- 대상: a\n- 메타: 표지=-\n### #2 y\n- 대상: b\n- 메타: 표지=FK\n', 0],
      'an F in another key is not a flag': ['### #1 x\n- 대상: a\n- 메타: 종류=P; 근거=표지 F 아님\n', 0],
      'no meta lines at all': ['### #1 x\n- 대상: a\n- 이유: r\n- 방법: m\n- 부작용: s\n', 0],
    }
    const py = text => {
      W(path.join(wd, 'ledger_fx.md'), text)
      const o = spawnSync('python3', ['-c', 'import sys,json; sys.path.insert(0, sys.argv[1]); import verify_gates as v; es = v.parse_ledger(open(sys.argv[2], encoding="utf-8").read()); print(sum(1 for e in es if "F" in ((e.get("meta") or {}).get("표지") or [])))', path.join(repo, 'scripts'), path.join(wd, 'ledger_fx.md')], { encoding: 'utf8', env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } })
      return Number(o.stdout.trim())
    }
    for (const [name, [text, want]] of Object.entries(FX)) {
      W(path.join(wd, '06_machine', 'bypasses.md'), text)
      const o = sh(cmdOf(call), wd)
      const got = Number((/f_rows=(\d+)/.exec(o.stdout) || [])[1])
      check('Q: ledger count — ' + name + ' (' + want + ', the real parser agrees)', got === want && py(text) === want && has(o.stdout, 'ledger=present'), o.stdout + o.stderr + ' parser=' + py(text))
    }
    fs.rmSync(path.join(wd, '06_machine', 'bypasses.md'))
    const oa = sh(cmdOf(call), wd)
    check('Q: no ledger file -> ledger=absent, f_rows=0 (nothing recorded, and said so)', has(oa.stdout, 'ledger=absent') && has(oa.stdout, 'f_rows=0'), oa.stdout + oa.stderr)
  })

  // ---------------------------------------------------------------- K2: every delegated prompt names the kernel log
  await block('K2', async () => {
    const planOn = { present: true, derived: true, plan: { region_base: '0x1', region_size: 4096, console_size: 1024, source: 'lk_log', evidence: 'e' } }
    const base = { prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, plan: planOn,
      supervisor: () => ({ route: 'fault-classifier' }),
      classify: () => ({ category: 'mmc_partition_scan_failed', fixer_ranking: [{ fixer: 'fixer-storage', rank: 1 }] }),
      fixer: { fixer: 'x', not_mine: true, no_new_change: false } }
    const obsK = o => () => mkObs({ milestone: 'none', escalate_to_analyst: true, ...o })
    const r = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ ...base,
      obs: obsK({ channels: { uart_bytes: 4, kernel_lines: 900, host_lines: 3 }, kernel_uniq: 800, kernel_last_time: 30 }) }))
    const KL = '/wd/07_logs/kernel_1.log', HL = '/wd/07_logs/host_1.txt'
    const sites = { supervisor: byLabel(r, /^supervisor-1$/)[0], classifier: byLabel(r, /^classify-1$/)[0], escalation: byLabel(r, /^escalate-1$/)[0],
      'specialist fixer': byLabel(r, /^fixer-storage-1$/)[0], 'general fixer': byLabel(r, /^general-1$/)[0] }
    for (const [k, c] of Object.entries(sites)) check('K: the ' + k + ' prompt names the kernel log of the round and says it is guest evidence', !!c && has(c.prompt, 'kernel log: ' + KL) && has(c.prompt, 'GUEST evidence'), c ? c.prompt.slice(0, 120) : 'no such call')
    check('K: the host log is named as the machine speaking, not as guest evidence', Object.values(sites).every(c => c && has(c.prompt, 'host log: ' + HL) && has(c.prompt, 'never evidence about the guest')), '')
    // memory-dump channel on, kernel silent this round: the path is still named, with its line count
    const r2 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ ...base, obs: obsK({}) }))
    const s2 = byLabel(r2, /^supervisor-1$/)[0], c2 = byLabel(r2, /^classify-1$/)[0]
    check('K: with the channel on and an empty kernel log this round the path is named with "0 lines" (a silent kernel log is an observation)', s2 && c2 && has(s2.prompt, 'kernel log: ' + KL) && has(s2.prompt, '(0 lines this round)') && has(c2.prompt, 'kernel log: ' + KL), s2 && s2.prompt.slice(0, 200))
    check('K: no host log is named when the round had no host lines', s2 && !has(s2.prompt, 'host log:'), '')
    // UART only, no plan: nothing is invented
    const r3 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ ...base, plan: undefined, obs: obsK({}) }))
    const s3 = byLabel(r3, /^supervisor-1$/)[0]
    check('K: with no memory-dump channel and no kernel lines no kernel log is named', s3 && !has(s3.prompt, 'kernel log:') && !has(s3.prompt, 'kernel_1.log'), s3 && s3.prompt.slice(0, 200))
    // the observation may name its own paths (run_round.sh); they win over the default
    const r4 = await run(fn, { ...BASE_ARGS, runtime_round_cap: 1 }, responder({ ...base,
      obs: obsK({ channels: { uart_bytes: 4, kernel_lines: 5, host_lines: 0 }, kernel_log: '/elsewhere/k.log' }) }))
    const s4 = byLabel(r4, /^supervisor-1$/)[0]
    check('K: a kernel_log path carried by the observation is the one named', s4 && has(s4.prompt, 'kernel log: /elsewhere/k.log') && !has(s4.prompt, KL), s4 && s4.prompt.slice(0, 200))
  })

  // ---------------------------------------------------------------- X6: a console is not text
  await block('X6', async () => {
    // the emitted commands, executed on a console that holds a NUL and bytes that are not UTF-8
    const bin = (...parts) => Buffer.concat(parts.map(x => typeof x === 'string' ? Buffer.from(x, 'latin1') : Buffer.from(x)))
    const wd = mktmp('ws'), plug = fakePlugin({ 'detect_medium.py': 'import sys,json\nargs=sys.argv[1:]\nlog=open(args[args.index("--bootloader-log")+1],"rb").read().decode("latin-1") if "--bootloader-log" in args else None\nprint(json.dumps({"argv":args,"log":log}))\n' })
    const con = bin('guest: [SD0] Initialized, eMMC45\n', [0x00, 0xff, 0xfe], ' junk\nqemu-system-aarch64: info: rehost: UFS thing\n1791000000.5 qemu-system-aarch64: info: x\nlater guest line\n')
    W(path.join(wd, '07_logs', 'console_2.txt'), '')
    fs.writeFileSync(path.join(wd, '07_logs', 'console_2.txt'), con)
    const rounds = { 1: mkObs({ milestone: 'preloader_entry', milestones_reached: ['preloader_entry'] }) }
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: plug, target: 'F1', bootloader_path: path.join(wd, 'pre.img') }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: n => rounds[n], medium0: { hci_kind: 'unknown', basis: 'none' } }))
    const d1 = r.calls.find(c => c.label === 'detect-medium-1')
    const o1 = sh(cmdOf(d1).replace('console_1.txt', 'console_2.txt'), wd)
    let j1 = null; try { j1 = JSON.parse(o1.stdout) } catch (e) {}
    check('X: a console with a NUL and non-UTF-8 bytes still reaches detect_medium (the guest lines, host lines out)', j1 && has(j1.log, 'eMMC45') && has(j1.log, 'later guest line') && !has(j1.log, 'qemu-system') && j1.log.includes('\u0000') && j1.log.includes('ÿ'), o1.stdout + o1.stderr)
    check('X: nothing is said on stderr when the filter worked', !has(o1.stderr, 'guest_filter'), o1.stderr)
    // every line a host line: the medium is decided from the device tree, and that is said
    fs.writeFileSync(path.join(wd, '07_logs', 'console_2.txt'), 'qemu-system-aarch64: info: a\n1791000000.5 qemu-system-aarch64: info: b\n')
    const o2 = sh(cmdOf(d1).replace('console_1.txt', 'console_2.txt'), wd)
    check('X: a console of only host lines is reported (guest_filter=empty), not read as "the bootloader said nothing"', has(o2.stderr, 'guest_filter=empty') && o2.status === 0, o2.stdout + o2.stderr)
    // the memory-dump derive, against the REAL memdump_observe.py
    const wd2 = mktmp('ws')
    const r2 = await run(fn, { ...BASE_ARGS, workdir: wd2, plugin_dir: repo, target: 'F2' }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: n => rounds[n] }))
    const pc = r2.calls.find(c => /^memdump-plan-1$/.test(c.label))
    fs.mkdirSync(path.join(wd2, '07_logs'), { recursive: true })
    fs.writeFileSync(path.join(wd2, '07_logs', 'console_1.txt'), bin('bootloader banner\n', [0x00, 0xff, 0xfe], ' junk\n[0200] reserve-R[3].start: 0x50100000, size: 0x40000 map:0 name:pstore\n',
      'RAM_CONSOLE pstore_addr:0x50100000, pstore_size:0x40000, pstore_console_size:0x20000, pstore_pmsg_size:0x8000\n', 'qemu-system-aarch64: info: rehost: reserve-R[9].start: 0x70000000, size: 0x1000 map:0 name:pstore\n'))
    const rd = sh(cmdOf(pc), wd2)
    let plan = {}; try { plan = JSON.parse(fs.readFileSync(path.join(wd2, 'memdump_plan.json'), 'utf8')) } catch (e) {}
    check('X: the ring is derived from a console that holds a NUL and non-UTF-8 bytes (the memory-dump channel is not lost to the filter)', has(rd.stdout, 'plan_status=derived') && plan.region_base === '0x50100000' && plan.console_size === 131072, rd.stdout + rd.stderr + JSON.stringify(plan))
    // all host lines: the reason says so
    fs.rmSync(path.join(wd2, 'memdump_plan.json'))
    fs.writeFileSync(path.join(wd2, '07_logs', 'console_1.txt'), 'qemu-system-aarch64: info: a\n')
    const rh = sh(cmdOf(pc), wd2)
    check('X: a console of only host lines writes no plan and says why', has(rh.stdout, 'plan_status=none') && has(rh.stdout, '게스트 줄이 없습니다') && !fs.existsSync(path.join(wd2, 'memdump_plan.json')), rh.stdout + rh.stderr)
    // the filter itself failing (grep exits 2) is reported, never swallowed
    const stub = mktmp('stub'); W(path.join(stub, 'grep'), '#!/bin/sh\nexit 2\n'); fs.chmodSync(path.join(stub, 'grep'), 0o755)
    const envNoFn = { PATH: stub + path.delimiter + process.env.PATH }
    for (const k of Object.keys(process.env)) if (k.startsWith('BASH_FUNC_grep')) envNoFn[k] = undefined
    fs.writeFileSync(path.join(wd2, '07_logs', 'console_1.txt'), 'something\n')
    const rf = sh(cmdOf(pc), wd2, envNoFn)
    check('X: a failing filter is reported with its exit code and no plan is written', has(rf.stdout, 'plan_status=none') && has(rf.stdout, 'grep 종료코드 2') && !fs.existsSync(path.join(wd2, 'memdump_plan.json')), rf.stdout + rf.stderr)
    const rf2 = sh(cmdOf(d1).split(wd).join(wd2), wd2, envNoFn)
    check('X: detect_medium is told when the filter failed', has(rf2.stderr, 'guest_filter=failed grep_exit=2'), rf2.stdout + rf2.stderr)
  })

  // ---------------------------------------------------------------- X7: the negative console meets the real verifier
  await block('X7', async () => {
    // The seam: avb_negative.txt is written by the pipeline and judged by the real verify.py against the
    // intact round's console. kernel_N.log lines carry "<seconds> "; the intact side has it taken off.
    const wd = mktmp('ws')
    const stand = {
      'make_negative_image.py': 'import os,sys,json,shutil\nwd=sys.argv[1]\nshutil.copyfile(os.path.join(wd,"fw","lu0.img"), os.path.join(wd,"fw","lu0_negative.img"))\nprint(json.dumps({"ok":True}))\n',
      'run_full.sh': '#!/usr/bin/env bash\nWD="$1"; N="$5"\nmkdir -p "$WD/07_logs"\nprintf "%b" "$FAKE_CON" > "$WD/07_logs/console_$N.txt"\nprintf "%b" "$FAKE_KLOG" > "$WD/07_logs/kernel_$N.log"\n',
    }
    const plug = fakePlugin(stand)
    W(path.join(wd, 'bl.bin'), 'x'.repeat(4096))
    W(path.join(wd, 'fw', 'lu0.img'), 'MEDIUM')
    W(path.join(wd, '06_machine', 'machine_full.c'), 'int x;\n')
    W(path.join(wd, '06_machine', 'bypasses.md'), '### #1 x\n- 대상: a\n- 이유: b\n- 방법: c\n- 부작용: d\n')
    W(path.join(wd, 'stage_map.json'), '{}')
    const INTACT_K = '1.234 avb: verification failed for vbmeta\n2.000 init: started\n'
    W(path.join(wd, '07_logs', 'console_1.txt'), 'boot line\n')
    W(path.join(wd, '07_logs', 'kernel_1.log'), INTACT_K)
    const ALL = ['preloader_entry', 'medium_up', 'partitions', 'verify_ok', 'kernel_entry', 'kernel_alive']
    const cfg = { prior: { ...MT_PRIOR, stages: [MT_STAGES[0]] }, obs: () => mkObs({ milestone: 'kernel_alive', milestones_reached: ALL, trace: path.join(wd, 'trace.log') }) }
    const rPlug = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: plug, bootloader_path: path.join(wd, 'bl.bin') }, responder(cfg))
    const rRepo = await run(fn, { ...BASE_ARGS, workdir: wd, plugin_dir: repo, bootloader_path: path.join(wd, 'bl.bin') }, responder(cfg))
    const negCmd = cmdOf(rPlug.calls.find(c => c.label === 'verify-negative-round'))
    const verCmd = cmdOf(rRepo.calls.find(c => c.label === 'verify-stage1-final'))
    const measure = env => {
      const n = sh(negCmd, wd, env)
      const v = sh(verCmd, wd)
      let j = null; try { j = JSON.parse(v.stdout) } catch (e) {}
      return { n, v, neg: j && j.verify_bypass && j.verify_bypass.negative_test, j }
    }
    // (1) the corrupted run printed exactly what the intact run printed: a stubbed verifier. NOT rejected.
    const same = measure({ FAKE_CON: 'boot line\\n', FAKE_KLOG: INTACT_K.replace(/\n/g, '\\n') })
    check('X: the negative console = the guest lines, kernel log timestamps off', has(fs.readFileSync(path.join(wd, '07_logs', 'avb_negative.txt'), 'utf8'), 'avb: verification failed for vbmeta') && !/^\d/m.test(fs.readFileSync(path.join(wd, '07_logs', 'avb_negative.txt'), 'utf8').replace(/^boot line\n/, '')), fs.readFileSync(path.join(wd, '07_logs', 'avb_negative.txt'), 'utf8'))
    check('X: seam — identical intact and corrupted runs are NOT reported as a rejected image (a stubbed verifier)', same.neg && same.neg.rejected === false && same.neg.new_failure_lines.length === 0, same.v.stdout.slice(0, 300) + same.v.stderr.slice(0, 300) + same.n.stderr)
    check('X: ... and the verification-bypass report counts the unrejected corruption', same.j && same.j.verify_bypass.signals.some(x => x.id === 'negative_test' && x.count === 1), '')
    // (2) the corrupted run printed a failure the intact one did not: rejected, timestamp not part of the line
    const diff = measure({ FAKE_CON: 'boot line\\n', FAKE_KLOG: (INTACT_K + '3.500 avb: vbmeta digest mismatch\n').replace(/\n/g, '\\n') })
    check('X: seam — a failure line only the corrupted run printed IS a rejection, and is quoted without the kernel time', diff.neg && diff.neg.rejected === true && diff.neg.new_failure_lines.length === 1 && diff.neg.new_failure_lines[0] === 'avb: vbmeta digest mismatch', JSON.stringify(diff.neg))
    // (3) a UART console with no final newline must not swallow the first kernel line
    const nonl = measure({ FAKE_CON: 'boot line', FAKE_KLOG: '5.000 avb: vbmeta digest mismatch\\n' })
    const txt = fs.readFileSync(path.join(wd, '07_logs', 'avb_negative.txt'), 'utf8')
    check('X: a console with no final newline keeps its last line and the first kernel line apart', txt === 'boot line\navb: vbmeta digest mismatch\n', JSON.stringify(txt))
  })

  // ---------------------------------------------------------------- T: the token file meets the ladder
  await block('T', async () => {
    const TWO = [MT_STAGES[0], MT_STAGES[2]]                 // preloader, lk -> preloader_entry, lk_entry
    const A = { ...BASE_ARGS, runtime_round_cap: 1 }
    const goodCfg = { prior: { ...MT_PRIOR, stages: TWO }, obs: () => mkObs() }
    const r = await run(fn, A, responder(goodCfg))
    const an = byLabel(r, /^analyze$/)[0].prompt
    check('T: the analyst is given the stage-rung rule and the tail of the ladder, not a placeholder ladder', has(an, '`<stage name>_entry`') && has(an, 'medium_up, partitions, verify_ok, kernel_entry, kernel_alive') && !has(an, 'stage_entry'), an.slice(an.indexOf('8. MILESTONE'), an.indexOf('8. MILESTONE') + 700))
    check('T: a token file that matches the ladder is not corrected', byLabel(r, /^analyze-tokens$/).length === 0 && byLabel(r, /^milestone-token-check$/).length === 1 && byLabel(r, /^milestone-token-recheck$/).length === 0, r.calls.map(c => c.label).slice(0, 14).join(' '))
    check('T: nothing is flagged in the result when the file matches', Array.isArray(r.result?.milestone_token_problems) && r.result.milestone_token_problems.length === 0, JSON.stringify(r.result?.milestone_token_problems))
    check('T: the check runs after the stage map is final and before Build', (() => { const o = r.calls.map(c => c.label); return o.indexOf('stage-rungs') < o.indexOf('milestone-token-check') && o.indexOf('milestone-token-check') < o.indexOf('qemu-tree-reset') })(), r.calls.map(c => c.label).slice(0, 14).join(' '))
    // the analyst named its rungs after the stages, not after the ladder
    const rBad = await run(fn, A, responder({ ...goodCfg, tokens: L => L === 'milestone-token-check'
      ? { tokens_file: 'present', unknown_rungs: ['preloader', 'lk'], first_rung_token: false }
      : { tokens_file: 'present', unknown_rungs: [], first_rung_token: true } }))
    const fix = byLabel(rBad, /^analyze-tokens$/)
    check('T: names that are no rung of the ladder cost exactly one correction, then a re-check', fix.length === 1 && byLabel(rBad, /^milestone-token-recheck$/).length === 1, rBad.calls.map(c => c.label).slice(0, 16).join(' '))
    const fp = fix[0] ? fix[0].prompt : ''
    check('T: the correction carries the exact ladder and each rung with the stage it stands for', has(fp, 'preloader_entry, lk_entry, medium_up') && has(fp, 'preloader_entry  <- stage "preloader" (index 0') && has(fp, 'lk_entry  <- stage "lk" (index 1'), fp.slice(0, 700))
    check('T: the correction names what was wrong, forbids moving a token between stages and inventing a first-stage token', has(fp, '사다리에 없는 칸 이름: preloader, lk') && has(fp, '첫 스테이지 칸 preloader_entry') && has(fp, 'Never move a token to a different stage') && has(fp, 'never invent one'), fp)
    check('T: the correction goes to the static-analyzer with the family kit', byLabel(rBad, /^analyze-tokens$/)[0].agentType === 'static-analyzer' && has(fp, FAM_LINE + '\n') && has(fp, RB_LINE + '\n'), '')
    check('T: a correction that worked leaves no problem and no decision about a mismatch', (rBad.result?.milestone_token_problems ?? []).length === 0 && byLabel(rBad, /^token-mismatch-decision$/).length === 0, JSON.stringify(rBad.result?.milestone_token_problems))
    // still wrong after the correction: said loudly, recorded, the run goes on (no firmware fact was established)
    const rStill = await run(fn, A, responder({ ...goodCfg, tokens: () => ({ tokens_file: 'present', unknown_rungs: [], first_rung_token: false }) }))
    check('T: a first-stage rung still without a token after the correction is reported loudly and recorded in the result', (rStill.result?.milestone_token_problems ?? []).some(x => has(x, 'preloader_entry')) && rStill.logs.some(l => has(l, '★ 경고') && has(l, 'preloader_entry')) && byLabel(rStill, /^token-mismatch-decision$/).length === 1, JSON.stringify(rStill.result?.milestone_token_problems) + rStill.logs.join('\n'))
    check('T: ... and it is not a stop (the run goes on to Build)', rStill.calls.some(c => c.label === 'build') && byLabel(rStill, /^analyze-tokens$/).length === 1, '')
    // no token file at all
    const rNone = await run(fn, A, responder({ ...goodCfg, tokens: () => ({ tokens_file: 'missing' }) }))
    check('T: a missing token file is a problem too', byLabel(rNone, /^analyze-tokens$/).length === 1 && has(byLabel(rNone, /^analyze-tokens$/)[0].prompt, 'milestone_tokens.txt 가 없거나 비어 있습니다'), '')
    // a check that could not be made is said, not read as "fine" or as "wrong"
    const rUn = await run(fn, A, responder({ ...goodCfg, tokens: () => null, override: async c => /^milestone-token-/.test(c.label) ? null : undefined }))
    check('T: a check that could not be made is logged and asks nothing of the analyst', rUn.logs.some(l => has(l, '대조하지 못했습니다')) && byLabel(rUn, /^analyze-tokens$/).length === 0, '')
    // nothing derived -> the placeholder ladder has no real rungs to compare with
    const rPh = await run(fn, A, responder({ prior: { ...MT_PRIOR, stages: [] }, obs: () => mkObs() }))
    check('T: with no executable stage there is nothing to check', byLabel(rPh, /^milestone-token-check$/).length === 0, '')
  })
  await block('T2', async () => {
    // --- the emitted check command, executed. Stages: preloader, lk -> rungs preloader_entry, lk_entry.
    const wd = mktmp('ws')
    const r = await run(fn, { ...BASE_ARGS, workdir: wd, runtime_round_cap: 1 }, responder({ prior: { ...MT_PRIOR, stages: [MT_STAGES[0], MT_STAGES[2]] }, obs: () => mkObs() }))
    const call = r.calls.find(c => c.label === 'milestone-token-check')
    check('T: the check command parses as bash and names the first stage rung', !!call && bashSyntax(call) === '' && has(call.prompt, "-v first='preloader_entry'"), call && (bashSyntax(call) || call.prompt.slice(0, 300)))
    const lines = o => o.stdout.split('\n').filter(Boolean)
    const o0 = sh(cmdOf(call), wd)
    check('T: no token file -> tokens_file=missing', lines(o0).join('|') === 'tokens_file=missing', o0.stdout + o0.stderr)
    W(path.join(wd, 'milestone_tokens.txt'), 'preloader\tfoo\nlk_entry\tbar\r\nshell\tS-BOOT #\nkernel_alive\tLinux version\tmemdump\nbare line for the surface\nmedium_up\t\n')
    const o1 = sh(cmdOf(call), wd)
    check('T: a stage named instead of its rung is "unknown"; the first rung has no token; a tab-less line is not a name; names past the target are fine',
      lines(o1).join('|') === 'tokens_file=present|unknown_rung=preloader|first_rung_token=no', o1.stdout + o1.stderr)
    W(path.join(wd, 'milestone_tokens.txt'), 'preloader_entry\tfoo\r\nlk_entry\tbar\nmedium_up\tx\nkernel_alive\tLinux version\tmemdump\nbare line\n')
    const o2 = sh(cmdOf(call), wd)
    check('T: a file that matches the ladder reports nothing unknown and the first rung has its token (CRLF tolerated)', lines(o2).join('|') === 'tokens_file=present|first_rung_token=yes', o2.stdout + o2.stderr)
    W(path.join(wd, 'milestone_tokens.txt'), 'preloader_entry\t\nlk_entry\tbar\nlk_entry\tbar2\n')
    const o3 = sh(cmdOf(call), wd)
    check('T: an empty token does not count for the first rung', lines(o3).join('|') === 'tokens_file=present|first_rung_token=no', o3.stdout + o3.stderr)
    W(path.join(wd, 'milestone_tokens.txt'), 'lk\ta\nlk\tb\nBL_2\tc\n')
    const o4 = sh(cmdOf(call), wd)
    check('T: an unknown name is reported once however often it appears', lines(o4).filter(x => x === 'unknown_rung=lk').length === 1 && has(o4.stdout, 'unknown_rung=BL_2'), o4.stdout)
  })

}
main().then(C.finish).catch(e => { console.log('FAIL harness crashed :: ' + (e && e.stack)); process.exit(1) })
