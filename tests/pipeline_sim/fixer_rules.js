// fixer_rules.js [repo] - the text of FIXER_RULES in workflows/pipeline.js, evaluated on its own.
//
// FIXER_RULES is the one constant that holds the rules every fixer shares (agents/fixer-*.md keep only what is specific
// to one fixer). The definition is a run of single-quoted literals with no blank line and no reference to another name,
// so it can be cut out of the source and evaluated alone. Two users:
//   * scenarios_neutral.js (V6) calls extractFixerRules(fn.source): the SAME text, mutations included, that the
//     pipeline appends to each fixer prompt.
//   * tests/parts/family_kit.sh and canon.sh run this file (`node fixer_rules.js <repo>`) and pin the wording of the
//     rules in what it prints. A pipeline.js without the constant prints nothing and exits 1.
const fs = require('fs')
const path = require('path')

function extractFixerRules(src) {
  const start = src.indexOf('const FIXER_RULES =')
  if (start < 0) return null
  const end = src.indexOf('\n\n', start)          // the definition ends at the first blank line
  const block = src.slice(start, end < 0 ? undefined : end)
  try { return new Function(block + '\nreturn FIXER_RULES')() } catch (e) { return null }
}

module.exports = { extractFixerRules }

if (require.main === module) {
  const repo = process.argv[2] || path.resolve(__dirname, '..', '..')
  const text = extractFixerRules(fs.readFileSync(path.join(repo, 'workflows', 'pipeline.js'), 'utf8'))
  if (typeof text !== 'string' || !text) process.exit(1)
  process.stdout.write(text)
}
