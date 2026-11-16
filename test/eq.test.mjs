// Checks the curve solver: what the 30 filters do together has to match what
// was painted, within a dB, across the whole range people actually draw in.
//
//   node test/eq.test.mjs

import fs from "node:fs"
import vm from "node:vm"
import path from "node:path"
import { fileURLToPath } from "node:url"

const here = path.dirname(fileURLToPath(import.meta.url))
const source = fs.readFileSync(path.join(here, "..", "Eq.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const Eq = {}
vm.createContext(Eq)
vm.runInContext(source, Eq)

let failures = 0
function check(name, ok, detail) {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? "  (" + detail + ")" : ""}`)
  if (!ok) failures++
}

// Compare on a dense grid, between the grid points as well as on them.
function worstError(target, gains) {
  let worst = 0
  for (let n = 0; n <= 400; n++) {
    const pos = (Eq.GRID - 1) * n / 400
    const freq = 1000 * Math.pow(2, (pos - 32) / 6)
    if (freq < 30 || freq > 16000) continue
    const k = Math.floor(pos), f = pos - k
    const want = k >= Eq.GRID - 1 ? target[Eq.GRID - 1] : target[k] * (1 - f) + target[k + 1] * f
    worst = Math.max(worst, Math.abs(Eq.bandsDb(gains, freq) - want))
  }
  return worst
}

const flatGains = Eq.solve(Eq.flat())
check("flat target gives flat bands", flatGains.every(g => g === 0))

for (const p of Eq.PRESETS) {
  const t = Eq.preset(p.id)
  const g = Eq.solve(t)
  const err = worstError(t, g)
  check(`preset ${p.id} within 1 dB`, err < 1.0, `worst ${err.toFixed(2)} dB`)
}

let bump = Eq.flat()
for (let i = 0; i < 4; i++) bump = Eq.dab(bump, Eq.gridPos(1000), 9, 0.85)
const bumpErr = worstError(bump, Eq.solve(bump))
check("a brushed +9 dB bump within 1 dB", bumpErr < 1.0, `worst ${bumpErr.toFixed(2)} dB, peak ${Math.max(...bump).toFixed(1)}`)

let notch = Eq.flat()
notch = Eq.stroke(notch, Eq.gridPos(150), -12, Eq.gridPos(400), -12)
const notchErr = worstError(notch, Eq.solve(notch))
check("a broad -12 dB scoop within 1 dB", notchErr < 1.0, `worst ${notchErr.toFixed(2)} dB`)

const zigzag = []
for (let k = 0; k < Eq.GRID; k++) zigzag.push(k % 2 ? 12 : -12)
const zg = Eq.solve(zigzag)
check("an impossible zigzag stays bounded", zg.every(g => isFinite(g) && Math.abs(g) <= Eq.MAX_GAIN), `max ${Math.max(...zg.map(Math.abs)).toFixed(1)}`)

const junk = Eq.solve([NaN, Infinity, "x", null, 1e9])
check("junk input is clamped, never NaN", junk.length === Eq.BANDS && junk.every(g => isFinite(g)))

const t0 = performance.now()
for (let i = 0; i < 50; i++) Eq.solve(Eq.preset("clearer"))
const ms = (performance.now() - t0) / 50
check("solve is quick enough to run while dragging", ms < 8, `${ms.toFixed(2)} ms`)

const hp = Eq.responseDb(flatGains, true, 80, 40)
check("high-pass is about -12 dB an octave below its corner", hp < -10 && hp > -14, `${hp.toFixed(1)} dB at 40 Hz`)

process.exit(failures ? 1 : 0)
