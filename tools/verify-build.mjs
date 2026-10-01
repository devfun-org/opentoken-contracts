import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import solc from 'solc'
import { keccak256 } from 'viem'

const root = fileURLToPath(new URL('../', import.meta.url))
const read = file => fs.readFileSync(path.join(root, file), 'utf8')
const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const proof = JSON.parse(read('verification/production-bytecode.json'))
assert.equal(solc.version().split('.Emscripten')[0], proof.compilerVersion)

const productionFiles = fs.readdirSync(path.join(root, 'src'), { recursive: true })
  .filter(file => file.endsWith('.sol')).map(file => `src/${file}`).sort()
assert.deepEqual(productionFiles, Object.keys(proof.sourceFiles).sort())
for (const [file, hash] of Object.entries(proof.sourceFiles)) {
  assert.equal(digest(read(file)), hash, `Deployed source changed: ${file}`)
}

const outputs = new Map()
for (const deployment of proof.deployments) {
  for (const contract of deployment.contracts) {
    let output = outputs.get(contract.compilerInput)
    if (!output) {
      const text = read(contract.compilerInput)
      assert.equal(digest(text), proof.compilerInputs[contract.compilerInput])
      const input = JSON.parse(text)
      for (const [file, source] of Object.entries(input.sources)) {
        assert.equal(read(file), source.content, `Compiler input source mismatch: ${file}`)
      }
      output = JSON.parse(solc.compile(text))
      const errors = (output.errors ?? []).filter(error => error.severity === 'error')
      assert.equal(errors.length, 0, errors.map(error => error.formattedMessage).join('\n'))
      outputs.set(contract.compilerInput, output)
    }
    const [source, name] = contract.contractIdentifier.split(':')
    const artifact = output.contracts[source][name]
    const creation = `0x${artifact.evm.bytecode.object}`
    const runtime = `0x${artifact.evm.deployedBytecode.object}`
    assert.equal(keccak256(creation), contract.creationTemplateHash, `${name}: creation template`)
    assert.equal(keccak256(runtime), contract.runtimeTemplateHash, `${name}: runtime template`)
    assert.equal(creation + contract.constructorArguments.slice(2), contract.creationBytecode,
      `${deployment.chainId}/${name}: full creation bytecode, including constructor arguments`)

    const forge = JSON.parse(read(`out/${path.basename(source)}/${name}.json`))
    assert.equal(forge.bytecode.object, creation, `${name}: Forge and archived input differ`)
    assert.equal(forge.deployedBytecode.object, runtime, `${name}: Forge runtime differs`)

    const references = Object.values(artifact.evm.deployedBytecode.immutableReferences).flat()
    const allowed = new Map(references.map(ref => [ref.start, ref.length]))
    assert.equal(allowed.size, references.length, `${name}: duplicate compiler immutable offset`)
    assert.equal(contract.immutableValues.length, allowed.size, `${name}: incomplete immutable values`)
    const patched = Buffer.from(runtime.slice(2), 'hex')
    for (const { offset, value } of contract.immutableValues) {
      const length = allowed.get(offset)
      assert.ok(length, `${name}: value is outside a compiler-declared immutable`)
      const bytes = Buffer.from(value.slice(2), 'hex')
      assert.equal(bytes.length, length)
      assert.equal(patched.subarray(offset, offset + length).toString('hex'), '00'.repeat(length))
      bytes.copy(patched, offset)
      allowed.delete(offset)
    }
    assert.equal(allowed.size, 0)
    assert.equal(`0x${patched.toString('hex')}`, contract.runtimeBytecode,
      `${deployment.chainId}/${name}: full runtime including metadata differs`)
    assert.equal(keccak256(contract.runtimeBytecode), contract.runtimeHash)
    assert.equal(deployment.observation.runtimes[name].keccak256, contract.runtimeHash)
    assert.equal(deployment.observation.runtimes[name].address.toLowerCase(), contract.address.toLowerCase())
    assert.equal(contract.verification.creationMatch, 'exact_match')
    assert.equal(contract.verification.runtimeMatch, 'exact_match')
    console.log(`${deployment.chainId} ${name}: exact creation and runtime reproduction`)
  }
}
console.log('All 18 production addresses reproduce exactly. No network, signing or transaction calls.')
