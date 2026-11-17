"""Tests for bin/soundcheck that need no PipeWire: settings, the rendered
config, and the file handling. Run through test/run-tests.sh."""

import importlib.machinery
import importlib.util
import json
import math
import os
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

loader = importlib.machinery.SourceFileLoader("soundcheck", os.path.join(ROOT, "bin", "soundcheck"))
spec = importlib.util.spec_from_loader("soundcheck", loader)
sc = importlib.util.module_from_spec(spec)
loader.exec_module(sc)

failures = 0


def check(name, ok, detail=""):
    global failures
    print(f"{'ok  ' if ok else 'FAIL'} {name}{'  (' + detail + ')' if detail else ''}")
    if not ok:
        failures += 1


# ---- settings come out clamped and typed, whatever goes in
hostile = {
    "mic": "x; rm -rf ~", "monitorSink": "-oProxyCommand=evil",
    "curve": [float("nan")] * sc.GRID, "gains": [1e9] * sc.BANDS,
    "highpass": {"on": "yes", "freq": -5}, "gate": {"threshold": "loud"},
    "compressor": {"ratio": 1e6}, "gain": float("inf"), "extra": {"a": 1},
}
s = sc.normalise(hostile)
check("bad microphone name is dropped", s["mic"] == "")
check("option-shaped sink name is dropped", s["monitorSink"] == "")
check("NaN curve becomes flat", all(v == 0 for v in s["curve"]))
check("huge gains are clamped", all(v == 18 for v in s["gains"]))
check("a non-boolean switch keeps its default", s["highpass"]["on"] is True)
check("ranges are clamped", s["highpass"]["freq"] == 20 and s["compressor"]["ratio"] == 10 and s["gain"] == 0)
check("unknown keys are not carried", "extra" not in s)
check("a short curve is replaced", len(sc.normalise({"curve": [1, 2]})["curve"]) == sc.GRID)

# ---- the rendered config
mic = "alsa_input.usb-Example_Mic-00.mono-fallback"
plain = sc.render(sc.default_settings(), {"lsp": False, "rnnoise": False}, mic)
full = sc.render(sc.default_settings(), {"lsp": True, "rnnoise": True}, mic)
check("thirty bands", plain.count("label = bq_peaking") == sc.BANDS)
check("captures the chosen microphone", f'target.object      = "{mic}"' in plain)
check("never falls back to the default source", "node.dont-fallback = true" in plain)
check("no package steps without packages", "lv2" not in plain and "ladspa" not in plain)
check("package steps when installed", "compressor_mono" in full and "limiter_mono" in full and "librnnoise_ladspa" in full)
check("no exponents reach SPA-JSON", "e-0" not in full and "e+0" not in full)
try:
    sc.render(sc.default_settings(), {}, 'mic" } evil = { "')
    check("a quote in a microphone name is refused", False)
except ValueError:
    check("a quote in a microphone name is refused", True)

c = sc.controls(sc.normalise({"gate": {"on": False}, "denoise": {"on": False}}), {"lsp": True, "rnnoise": True})
check("gate off means always open", c["g_knee:Min"] == 1.0)
check("noise removal off takes the dry path", c["mix:Gain 1"] == 0 and c["mix:Gain 2"] == 1)


def gate_gain(controls, level_db):
    # What the gate's parts compute for a steady level: g_pre, g_log, g_lin, g_knee.
    x = max(1e-5, 10 * 10 ** (level_db / 20))
    out = sc.GATE_LOG_M2 * math.log(10.0 * x) + controls["g_lin:Add"]
    return min(1.0, max(controls["g_knee:Min"], out))


c = sc.controls(sc.normalise({"gate": {"threshold": -40}}), {})
check("the gate is shut 3 dB under its threshold", gate_gain(c, -43) < 1e-6 and gate_gain(c, -60) == 0)
check("half open at the threshold", abs(gate_gain(c, -40) - 0.5) < 1e-6)
check("and fully open 3 dB over it", gate_gain(c, -37) > 1 - 1e-6 and gate_gain(c, -10) == 1)
check("every gate control stays inside PipeWire's ranges",
      all(-10 <= sc.controls(sc.normalise({"gate": {"threshold": th}}), {})["g_lin:Add"] <= 10 for th in range(-90, -9))
      and -10 <= sc.GATE_LOG_M2 <= 10)
check("PipeWire's own noisegate is not used", "noisegate" not in full)
check("the gate multiplies the voice by its gain",
      'input = "gate:In 1"' in plain and 'input = "gate:In 2"' in plain and 'input = "gin:In"' in plain)

try:
    sc.unit_text("/home/a b/x.conf")
    check("a path with a space never reaches the unit file", False)
except ValueError:
    check("a path with a space never reaches the unit file", True)

# ---- the panel draws with the same band widths PipeWire is given
js = subprocess.run(
    ["node", "-e", f"""
const fs=require('fs'),vm=require('vm'),E={{}};vm.createContext(E);
vm.runInContext(fs.readFileSync({json.dumps(os.path.join(ROOT, 'Eq.js'))},'utf8').replace(/^\\.pragma library\\s*$/m,''),E);
console.log(JSON.stringify([...Array(E.BANDS).keys()].map(i=>[E.bandFreq(i),E.bandQ(i)])))"""],
    capture_output=True, text=True, timeout=20)
pairs = json.loads(js.stdout)
worst = max(max(abs(f - sc.band_freq(i)), abs(q - sc.band_q(i))) for i, (f, q) in enumerate(pairs))
check("Eq.js and the config agree on every band", worst < 1e-6, f"worst difference {worst:.2e}")

# ---- distortion and reverb
fx = sc.render(sc.normalise({"distortion": {"on": True}, "reverb": {"on": True}}), {"reverb": True}, mic)
check("distortion is a soft clipper made of PipeWire's parts",
      "label = recip" in fx and 'input = "d_clip:In 2"' in fx and 'input = "d_mix:In 2"' in fx)
check("the reverb plays the room written next to the config",
      "label = convolver" in fx and sc.REVERB_FILE in fx)
c = sc.controls(sc.normalise({"distortion": {"on": False}, "reverb": {"on": False}}), {"reverb": True})
check("distortion off passes the dry voice only", c["d_mix:Gain 1"] == 0 and c["d_mix:Gain 2"] == 1)
check("reverb off adds nothing", c["rv_mix:Gain 1"] == 0 and c["rv_mix:Gain 2"] == 1)
check("no reverb controls without a reverb in the graph", "rv_mix:Gain 1" not in sc.controls(sc.default_settings(), {}))
check("the drive stays inside PipeWire's ranges at full",
      all(abs(sc.controls(sc.normalise({"distortion": {"drive": d}}), {})[k]) <= 10
          for d in (0, 50, 100) for k in ("d_pre:Mult", "d_pre2:Mult", "d_post:Mult")))
d_off = sc.controls(sc.normalise({"distortion": {"drive": 0}}), {})
check("no drive is no gain", abs(d_off["d_pre:Mult"] * d_off["d_pre2:Mult"] * d_off["d_post:Mult"] - 1) < 1e-9)
ir, ir_gain = sc.reverb_ir()
check("the room is the same every time", sc.reverb_ir()[0] is ir and len(ir) > 44 + sc.RATE)
import array as _array
_pcm = _array.array("h"); _pcm.frombytes(ir[44:])
_energy = sum((v / 32768.0) ** 2 for v in _pcm)
check("and its gain makes it unity", abs(ir_gain * ir_gain * _energy - 1) < 1e-6)
check("settings without the new steps get them, switched off",
      sc.normalise({})["distortion"]["on"] is False and sc.normalise({})["reverb"]["on"] is False)

# ---- the preview: the test recording through a chain of its own
pv = sc.render(sc.default_settings(), {"lsp": False, "rnnoise": False}, "", preview_sink="alsa_output.example")
check("the preview is fed by hand, never by the session manager", 'node.name        = "soundcheck_preview_in"' in pv
      and "node.autoconnect = false" in pv)
check("the preview plays on the output it was given, and only there",
      'target.object      = "alsa_output.example"' in pv and "node.dont-fallback = true" in pv)
check("the preview is no microphone", "Audio/Source" not in pv and sc.NODE_SOURCE not in pv)
try:
    sc.render(sc.default_settings(), {}, "", preview_sink='out" } evil = { "')
    check("a quote in an output name is refused", False)
except ValueError:
    check("a quote in an output name is refused", True)
argv = sc.record_argv(None, "f32", "soundcheck_meter_in")
check("a recorder without a target waits to be linked", "--target" not in argv and "node.autoconnect = false" in argv[-2])

# ---- the analyzer behind the curve
an = sc.Analyzer(("in", "out"))
loud = [-90.0] * sc.GRID
loud[20] = -30.0
an.update({"in": loud, "out": loud}, 0.0, 0.05)
check("a band rises at once", an.shown["in"][20] == -30.0)
quiet = [-90.0] * sc.GRID
an.update({"in": quiet, "out": quiet}, 0.1, 0.1)
check("and falls back gradually", abs(an.shown["in"][20] - (-30.0 - sc.RELEASE_DB_S * 0.1)) < 1e-6)
check("the peak stays where it was", an.peaks[20] == -30.0)
for i in range(2, 80):
    an.update({"in": quiet, "out": quiet}, i * 0.05 + 0.1, 0.05)
check("and sinks after the hold", an.peaks[20] < -60.0)
check("the top of the scale stays within its limits", sc.TOP_MIN <= an.top <= sc.TOP_MAX)
msg = an.message()
check("the message carries bands, peaks, top and the output",
      msg["type"] == "spectrum" and len(msg["bands"]) == sc.GRID and len(msg["peaks"]) == sc.GRID
      and len(msg["out"]) == sc.GRID and isinstance(msg["top"], float))
check("no output without a chain", "out" not in sc.Analyzer(("in",)).message())

# ---- files: a planted symlink is replaced, never written through
with tempfile.TemporaryDirectory() as home:
    sc.HOME = home
    victim = os.path.join(home, "victim")
    with open(victim, "w") as f:
        f.write("must survive")
    os.makedirs(os.path.join(home, ".config", "omarchy-soundcheck"), mode=0o755)
    cfg = os.path.join(home, ".config", "omarchy-soundcheck")
    os.symlink(victim, os.path.join(cfg, "settings.json"))
    with open(os.path.join(cfg, "old.json"), "w") as f:
        f.write("{}")
    os.chmod(os.path.join(cfg, "old.json"), 0o644)
    sc.store_json("settings.json", sc.default_settings())
    with open(victim) as f:
        check("a symlinked settings file does not redirect the write", f.read() == "must survive")
    check("the directory is made private", os.stat(cfg).st_mode & 0o777 == 0o700)
    check("files already in it are made private", os.stat(os.path.join(cfg, "old.json")).st_mode & 0o777 == 0o600)
    check("the settings are written as a regular file", os.path.isfile(os.path.join(cfg, "settings.json"))
          and not os.path.islink(os.path.join(cfg, "settings.json")))
    check("and read back", sc.load_settings()["gate"]["threshold"] == -55)
    with open(os.path.join(cfg, "settings.json"), "w") as f:
        f.write("{broken")
    check("a damaged settings file falls back to defaults", sc.load_settings() == sc.default_settings())

sys.exit(1 if failures else 0)
