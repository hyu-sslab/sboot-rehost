// harness.js <pipeline.js> <repo> - runs workflows/pipeline.js against a scripted `agent`.
const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')

function load(pipelinePath, mutations) {
  let src = fs.readFileSync(pipelinePath, 'utf8').replace(/^export const meta/m, 'const meta')
  for (const m of mutations || []) {
    const next = typeof m === 'function' ? m(src) : (src.includes(m[0]) ? src.replace(m[0], m[1]) : src)
    if (next === src) { console.log('FAIL mutation did not apply (the code it targets has moved): ' + (typeof m === 'function' ? m.toString().slice(0, 60) : m[0].slice(0, 60))); process.exit(0) }
    src = next
  }
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
  const f = new AsyncFunction('args', 'log', 'agent', 'phase', 'budget', src)
  f.source = src                      // what was actually compiled (mutations included): static checks read this
  return f
}

/* run(pipeline, args, respond) -> { result, calls, logs } ; respond(call) returns the
 * structured answer for that call (undefined -> a generic "ok"). */
async function run(fn, args, respond) {
  const calls = [], logs = [], phases = []
  const agent = async (prompt, opts = {}) => {
    const call = { prompt, opts, label: opts.label ?? '', agentType: opts.agentType ?? null,
                   isShell: prompt.startsWith('Run the following commands exactly'), n: calls.length }
    calls.push(call)
    const r = await respond(call, calls)
    return r === undefined ? { ok: true } : r
  }
  let result, error = null
  try {
    result = await fn(args, m => logs.push(String(m)), agent, p => phases.push(p), { spent: () => 0 })
  } catch (e) { error = e }
  return { result, error, calls, logs, phases }
}

function realKit(repo, family) {
  try {
    return JSON.parse(execFileSync('python3', [path.join(repo, 'scripts', 'family_kit.py'), family],
      { encoding: 'utf8' }))
  } catch (e) { return JSON.parse(e.stdout || '{"error":"unreadable"}') }
}

module.exports = { load, run, realKit }
