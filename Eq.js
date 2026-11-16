.pragma library

// The arithmetic behind the curve you draw.
//
// You paint a target on a grid of 59 points, one every sixth of an octave from
// 25 Hz to 20 kHz. Underneath sit 30 fixed peaking filters, one every third of
// an octave, and their gains are solved so that the sum of all 30 lands on what
// you painted. Taking the painted value per band instead does not work:
// neighbouring bands overlap, so their boosts add up and the result overshoots
// by several dB wherever the curve is broad.
//
// The filter formulas are the RBJ cookbook ones, which is what PipeWire's
// builtin bq_peaking and bq_highpass implement, so the response drawn in the
// panel is the response you hear.
//
// No QML in here, so test/run-tests.sh can load this file in node.

var RATE = 48000
var BANDS = 30
var GRID = 59
var BAND_Q = 2.5
var MAX_TARGET = 12
var MAX_GAIN = 18
var HIGHPASS_Q = 0.707

function bandFreq(i) { return 1000 * Math.pow(2, (i - 16) / 3) }

// The bands are a fixed width in octaves. Near the top of the range the
// bilinear transform squeezes a filter of constant Q, which left ripples of
// several dB between 12 and 20 kHz; widening the Q there by the cookbook's
// bandwidth formula keeps the bands overlapping evenly all the way up.
var _bandQ = null
function bandQ(i) {
  if (!_bandQ) {
    _bandQ = []
    var bw = 2 / Math.LN2 * Math.asinh(1 / (2 * BAND_Q))
    for (var b = 0; b < BANDS; b++) {
      var w0 = 2 * Math.PI * bandFreq(b) / RATE
      _bandQ.push(1 / (2 * Math.sinh(Math.LN2 / 2 * bw * w0 / Math.sin(w0))))
    }
  }
  return _bandQ[i]
}
function gridFreq(k) { return 1000 * Math.pow(2, (k - 32) / 6) }

// Grid position (fractional) of a frequency, and back again.
function gridPos(freq) { return 32 + 6 * Math.log(freq / 1000) / Math.LN2 }

function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

function finite(v, fallback) {
  var n = Number(v)
  return isFinite(n) ? n : fallback
}

// b0 b1 b2 a1 a2, normalised by a0.
function peaking(freq, q, gainDb) {
  var A = Math.pow(10, gainDb / 40)
  var w0 = 2 * Math.PI * freq / RATE
  var cw = Math.cos(w0)
  var alpha = Math.sin(w0) / (2 * q)
  var a0 = 1 + alpha / A
  return [(1 + alpha * A) / a0, (-2 * cw) / a0, (1 - alpha * A) / a0,
          (-2 * cw) / a0, (1 - alpha / A) / a0]
}

function highpass(freq, q) {
  var w0 = 2 * Math.PI * freq / RATE
  var cw = Math.cos(w0)
  var alpha = Math.sin(w0) / (2 * q)
  var a0 = 1 + alpha
  return [(1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0,
          (-2 * cw) / a0, (1 - alpha) / a0]
}

function magDb(c, freq) {
  var w = 2 * Math.PI * freq / RATE
  var cw = Math.cos(w), sw = Math.sin(w), c2 = Math.cos(2 * w), s2 = Math.sin(2 * w)
  var nr = c[0] + c[1] * cw + c[2] * c2, ni = -(c[1] * sw + c[2] * s2)
  var dr = 1 + c[3] * cw + c[4] * c2, di = -(c[3] * sw + c[4] * s2)
  var num = nr * nr + ni * ni, den = dr * dr + di * di
  if (!(num > 0) || !(den > 0)) return -120
  return 10 * Math.log10(num / den)
}

// The sum of all bands at one frequency, in dB.
function bandsDb(gains, freq) {
  var total = 0
  for (var i = 0; i < BANDS; i++) {
    var g = gains[i]
    if (g > 0.001 || g < -0.001) total += magDb(peaking(bandFreq(i), bandQ(i), g), freq)
  }
  return total
}

// The same sum on the whole target grid at once, for the solver: the trig per
// grid point and the coefficients per band are computed once instead of once
// per pair.
var _gridTrig = null
function _trig() {
  if (_gridTrig) return _gridTrig
  _gridTrig = []
  for (var k = 0; k < GRID; k++) {
    var w = 2 * Math.PI * gridFreq(k) / RATE
    _gridTrig.push([Math.cos(w), Math.sin(w), Math.cos(2 * w), Math.sin(2 * w)])
  }
  return _gridTrig
}

function gridDb(gains) {
  var trig = _trig(), out = new Array(GRID), k
  for (k = 0; k < GRID; k++) out[k] = 0
  for (var i = 0; i < BANDS; i++) {
    var g = gains[i]
    if (!(g > 0.001 || g < -0.001)) continue
    var c = peaking(bandFreq(i), bandQ(i), g)
    for (k = 0; k < GRID; k++) {
      var t = trig[k]
      var nr = c[0] + c[1] * t[0] + c[2] * t[2], ni = -(c[1] * t[1] + c[2] * t[3])
      var dr = 1 + c[3] * t[0] + c[4] * t[2], di = -(c[3] * t[1] + c[4] * t[3])
      out[k] += 10 * Math.log10((nr * nr + ni * ni) / (dr * dr + di * di))
    }
  }
  return out
}

// Least-squares fit, precomputed once: M = (B'B + lambda I)^-1 B', where
// B[k][i] is band i's response at grid point k per dB of gain. The ridge term
// keeps neighbouring bands from fighting each other with huge opposite gains.
var _fit = null

function _solveLinear(A, b) {
  var n = b.length, i, j, k
  var M = []
  for (i = 0; i < n; i++) M.push(A[i].slice().concat([b[i]]))
  for (i = 0; i < n; i++) {
    var p = i
    for (j = i + 1; j < n; j++) if (Math.abs(M[j][i]) > Math.abs(M[p][i])) p = j
    var t = M[i]; M[i] = M[p]; M[p] = t
    for (j = i + 1; j < n; j++) {
      var f = M[j][i] / M[i][i]
      for (k = i; k <= n; k++) M[j][k] -= f * M[i][k]
    }
  }
  var x = new Array(n)
  for (i = n - 1; i >= 0; i--) {
    var s = M[i][n]
    for (j = i + 1; j < n; j++) s -= M[i][j] * x[j]
    x[i] = s / M[i][i]
  }
  return x
}

function _fitMatrix() {
  if (_fit) return _fit
  var proto = 6, lambda = 0.02, i, j, k
  var B = []
  for (k = 0; k < GRID; k++) {
    var row = []
    for (i = 0; i < BANDS; i++) row.push(magDb(peaking(bandFreq(i), bandQ(i), proto), gridFreq(k)) / proto)
    B.push(row)
  }
  // Columns of M: solve (B'B + lambda I) m = e_k-weighted B' column by column.
  var BtB = []
  for (i = 0; i < BANDS; i++) {
    BtB.push(new Array(BANDS))
    for (j = 0; j < BANDS; j++) {
      var s = 0
      for (k = 0; k < GRID; k++) s += B[k][i] * B[k][j]
      BtB[i][j] = s + (i === j ? lambda : 0)
    }
  }
  var M = []
  for (i = 0; i < BANDS; i++) M.push(new Array(GRID))
  for (k = 0; k < GRID; k++) {
    var col = []
    for (i = 0; i < BANDS; i++) col.push(B[k][i])
    var x = _solveLinear(BtB, col)
    for (i = 0; i < BANDS; i++) M[i][k] = x[i]
  }
  _fit = M
  return M
}

function _apply(M, vec) {
  var out = new Array(BANDS)
  for (var i = 0; i < BANDS; i++) {
    var s = 0
    for (var k = 0; k < GRID; k++) s += M[i][k] * vec[k]
    out[i] = s
  }
  return out
}

// Painted target (GRID values in dB) to band gains (BANDS values in dB).
function solve(target) {
  var M = _fitMatrix(), i, k
  var t = new Array(GRID)
  for (k = 0; k < GRID; k++) t[k] = clamp(finite(target[k], 0), -MAX_TARGET, MAX_TARGET)
  var g = _apply(M, t)
  for (i = 0; i < BANDS; i++) g[i] = clamp(g[i], -MAX_GAIN, MAX_GAIN)
  // The dB shape of a peaking filter widens a little with its gain, so the
  // linear fit is refined against the real response a few times.
  for (var pass = 0; pass < 4; pass++) {
    var now = gridDb(g)
    var e = new Array(GRID)
    for (k = 0; k < GRID; k++) e[k] = t[k] - now[k]
    var d = _apply(M, e)
    for (i = 0; i < BANDS; i++) g[i] = clamp(g[i] + d[i], -MAX_GAIN, MAX_GAIN)
  }
  for (i = 0; i < BANDS; i++) g[i] = Math.round(g[i] * 100) / 100
  return g
}

function flat() {
  var t = new Array(GRID)
  for (var k = 0; k < GRID; k++) t[k] = 0
  return t
}

// One dab of the brush at a fractional grid position: pull the target towards
// `level` with a Gaussian falloff, a third of an octave wide on each side.
function dab(target, pos, level, strength) {
  var out = target.slice()
  var sigma = 1.6
  var from = Math.max(0, Math.floor(pos - 4 * sigma)), to = Math.min(GRID - 1, Math.ceil(pos + 4 * sigma))
  for (var k = from; k <= to; k++) {
    var w = strength * Math.exp(-0.5 * Math.pow((k - pos) / sigma, 2))
    out[k] = clamp(out[k] + w * (level - out[k]), -MAX_TARGET, MAX_TARGET)
  }
  return out
}

// A stroke from one pointer position to the next, dabbed every half grid step
// so a fast flick across the graph leaves no gaps.
function stroke(target, pos0, level0, pos1, level1) {
  var steps = Math.max(1, Math.ceil(Math.abs(pos1 - pos0) * 2))
  var out = target
  for (var s = 0; s <= steps; s++) {
    var f = s / steps
    out = dab(out, pos0 + (pos1 - pos0) * f, level0 + (level1 - level0) * f, 0.85)
  }
  return out
}

// Keyboard nudge: add `delta` dB around one band, with the same falloff.
function nudge(target, pos, delta) {
  var out = target.slice()
  var sigma = 1.6
  for (var k = 0; k < GRID; k++) {
    var w = Math.exp(-0.5 * Math.pow((k - pos) / sigma, 2))
    if (w > 0.01) out[k] = clamp(out[k] + w * delta, -MAX_TARGET, MAX_TARGET)
  }
  return out
}

// What you actually hear at one frequency: the bands plus the high-pass.
function responseDb(gains, highpassOn, highpassFreq, freq) {
  var total = bandsDb(gains, freq)
  if (highpassOn) total += magDb(highpass(highpassFreq, HIGHPASS_Q), freq)
  return total
}

// A target from a few anchor points ([freq, dB] pairs), smoothly joined in
// log frequency. Presets are written this way.
function fromAnchors(anchors) {
  var t = new Array(GRID)
  for (var k = 0; k < GRID; k++) {
    var x = Math.log(gridFreq(k))
    if (x <= Math.log(anchors[0][0])) { t[k] = anchors[0][1]; continue }
    var last = anchors[anchors.length - 1]
    if (x >= Math.log(last[0])) { t[k] = last[1]; continue }
    for (var a = 0; a < anchors.length - 1; a++) {
      var x0 = Math.log(anchors[a][0]), x1 = Math.log(anchors[a + 1][0])
      if (x >= x0 && x <= x1) {
        var f = (x - x0) / (x1 - x0)
        var smooth = f * f * (3 - 2 * f)
        t[k] = anchors[a][1] + (anchors[a + 1][1] - anchors[a][1]) * smooth
        break
      }
    }
  }
  return t
}

var PRESETS = [
  { id: "flat", label: "Flat", anchors: [[25, 0], [20000, 0]] },
  // Takes the boxiness out of a dynamic broadcast mic and adds a little air.
  { id: "clearer", label: "Clearer", anchors: [[25, 0], [120, 0], [280, -3.5], [700, -0.5], [2000, 0], [4200, 3], [8000, 1.5], [14000, 2], [20000, 1]] },
  { id: "warmer", label: "Warmer", anchors: [[25, 0], [90, 1], [180, 3], [400, 1], [1000, 0], [5000, -1], [10000, -2.5], [20000, -3]] },
  { id: "less-hiss", label: "Less hiss", anchors: [[25, 0], [3000, 0], [6000, -2], [9000, -6], [14000, -9], [20000, -10]] }
]

function preset(id) {
  for (var i = 0; i < PRESETS.length; i++)
    if (PRESETS[i].id === id) return fromAnchors(PRESETS[i].anchors)
  return flat()
}
