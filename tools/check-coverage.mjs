import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, URL } from 'node:url'

export const coverageThresholds = { lines: 100, functions: 100, branches: 90 }
const root = fileURLToPath(new URL('../', import.meta.url))

export function checkCoverage(lcov, files) {
  const records = new Map()
  for (const section of lcov.split('end_of_record')) {
    const fields = Object.fromEntries(section.trim().split(/\r?\n/).map(line => {
      const separator = line.indexOf(':')
      return [line.slice(0, separator), line.slice(separator + 1)]
    }))
    if (!fields.SF) continue
    const file = path.relative(root, path.resolve(root, fields.SF)).split(path.sep).join('/')
    assert.ok(!records.has(file), `Duplicate coverage record: ${file}`)
    records.set(file, fields)
  }
  assert.ok(files.length > 0, 'No production Solidity files found')
  const summary = []
  for (const file of files) {
    const fields = records.get(file)
    assert.ok(fields, `Missing coverage record: ${file}`)
    const result = { file }
    for (const [metric, foundKey, hitKey] of [
      ['lines', 'LF', 'LH'], ['functions', 'FNF', 'FNH'], ['branches', 'BRF', 'BRH'],
    ]) {
      assert.match(fields[foundKey] ?? '', /^\d+$/, `Missing/invalid ${foundKey}: ${file}`)
      assert.match(fields[hitKey] ?? '', /^\d+$/, `Missing/invalid ${hitKey}: ${file}`)
      const found = Number(fields[foundKey])
      const hit = Number(fields[hitKey])
      assert.ok(Number.isSafeInteger(found) && Number.isSafeInteger(hit) && hit <= found, `Invalid ${metric} counts: ${file}`)
      if (metric !== 'branches') assert.ok(found > 0, `No measurable ${metric}: ${file}`)
      const percent = found === 0 ? 100 : hit / found * 100
      assert.ok(percent >= coverageThresholds[metric], `${file}: ${metric} ${percent.toFixed(2)}% is below ${coverageThresholds[metric]}%`)
      result[metric] = `${hit}/${found}`
    }
    summary.push(result)
  }
  return summary
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const files = ['src'].flatMap(directory =>
    fs.readdirSync(path.join(root, directory), { recursive: true })
      .filter(file => file.endsWith('.sol'))
      .map(file => `${directory}/${file.split(path.sep).join('/')}`)).sort()
  const summary = checkCoverage(fs.readFileSync(path.join(root, 'lcov.info'), 'utf8'), files)
  console.table(summary)
  console.log(`Coverage gate passed for ${summary.length} production Solidity files.`)
}
