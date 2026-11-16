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
check("gate off means always open", c["gate:Open Threshold"] == 0 and c["gate:Close Threshold"] == 0)
check("noise removal off takes the dry path", c["mix:Gain 1"] == 0 and c["mix:Gain 2"] == 1)
c = sc.controls(sc.normalise({"gate": {"threshold": -40}}), {})
check("gate closes 6 dB below where it opens",
      abs(20 * math.log10(c["gate:Open Threshold"] / c["gate:Close Threshold"]) - 6) < 1e-9)

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
