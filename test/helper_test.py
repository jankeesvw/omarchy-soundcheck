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
n_kinds = len(sc.DIST_KINDS)
check("every kind of distortion is made of PipeWire's parts",
      "label = recip" in fx and "label = ladspa" not in fx
      and all(f'input = "d_mix:In {i}"' in fx for i in range(1, n_kinds + 2)))
check("the reverb plays the room written next to the config",
      "label = convolver" in fx and sc.REVERB_FILE in fx)
c = sc.controls(sc.normalise({"distortion": {"on": False}, "reverb": {"on": False}}), {"reverb": True})
check("distortion off passes the dry voice only",
      all(c[f"d_mix:Gain {i + 1}"] == 0 for i in range(n_kinds)) and c[f"d_mix:Gain {n_kinds + 1}"] == 1)
check("reverb off adds nothing", c["rv_mix:Gain 1"] == 0 and c["rv_mix:Gain 2"] == 1)
check("no reverb controls without a reverb in the graph", "rv_mix:Gain 1" not in sc.controls(sc.default_settings(), {}))
for kind in sc.DIST_KINDS:
    ck = sc.controls(sc.normalise({"distortion": {"on": True, "kind": kind}}), {})
    gains = [ck[f"d_mix:Gain {i + 1}"] for i in range(n_kinds + 1)]
    check(f"{kind} distortion passes that kind and nothing else",
          sum(1 for g in gains if g > 0) == 1 and gains[sc.DIST_KINDS.index(kind)] > 0)
check("an unknown kind of distortion is the warm one",
      sc.normalise({"distortion": {"kind": "../x"}})["distortion"]["kind"] == "warm")
check("the drive and the levels stay inside PipeWire's ranges",
      all(0 <= v <= 10 for d in (0, 50, 100) for kind in sc.DIST_KINDS
          for k, v in sc.controls(sc.normalise({"distortion": {"on": True, "kind": kind, "drive": d}}), {}).items()
          if k.startswith("d_")))
d_off = sc.controls(sc.normalise({"distortion": {"drive": 0}}), {})
check("no drive is no gain", abs(d_off["d_pre:Mult"] * d_off["d_pre2:Mult"] - 1) < 1e-9)
check("the level follows its table between the points",
      abs(sc.dist_level("hard", 10) - (-3.6)) < 1e-9 and sc.dist_level("warm", 100) == -23.2
      and sc.dist_level("fuzz", 150) == -27.9)
legacy = sc.controls(sc.normalise({"distortion": {"on": False}}), {"v": 3})
check("a chain from version 3 keeps its dry voice",
      legacy["d_mix:Gain 1"] == 0 and legacy["d_mix:Gain 2"] == 1 and f"d_mix:Gain {n_kinds + 1}" not in legacy)

# ---- pitch
pt = sc.render(sc.normalise({"pitch": {"on": True, "semitones": 7}}), {"pitch": True}, mic)
check("the pitch shifter is Rubber Band's live one",
      "label = rubberband-live-pitchshifter-mono" in pt and '"Semitones" = 7.000000' in pt)
check("off, the voice goes around the shifter",
      'input = "p_mix:In 2"' in pt and 'output = "pin:Out" input = "p_mix:In 2"' in pt)
check("no pitch shifter without the package", "rubberband" not in sc.render(sc.default_settings(), {}, mic))
cp = sc.controls(sc.normalise({"pitch": {"on": False}}), {"pitch": True})
check("pitch off passes the voice as it is", cp["p_mix:Gain 1"] == 0 and cp["p_mix:Gain 2"] == 1)
check("pitch stays within an octave, in whole semitones",
      sc.normalise({"pitch": {"semitones": 40}})["pitch"]["semitones"] == 12
      and sc.normalise({"pitch": {"semitones": 2.6}})["pitch"]["semitones"] == 3
      and sc.normalise({"pitch": {"semitones": "x"}})["pitch"]["semitones"] == -5)
check("the meter sees a peak over full scale", sc.level_db([2.0, -2.0])[1] > 5.9)
ir, ir_gain = sc.reverb_ir()
check("the room is the same every time", sc.reverb_ir()[0] is ir and len(ir) > 44 + sc.RATE)
import array as _array
_pcm = _array.array("h"); _pcm.frombytes(ir[44:])
_energy = sum((v / 32768.0) ** 2 for v in _pcm)
check("and its gain makes it unity", abs(ir_gain * ir_gain * _energy - 1) < 1e-6)
check("settings without the new steps get them, switched off",
      sc.normalise({})["distortion"]["on"] is False and sc.normalise({})["reverb"]["on"] is False
      and sc.normalise({})["pitch"]["on"] is False)

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


# ---- the analysis: a made-up voice, so the answers are known
import array as _arr
import random as _random


def voice(seconds=8.0, f0=120.0, noise_db=-65.0, level=0.25, rumble=0.0, clip=False, pause=0.5):
    """Phrases of a buzzy voice at f0, syllables four times a second, pauses
    between the phrases, and white noise under all of it."""
    rate = sc.RATE
    rng = _random.Random(7)
    period = int(round(rate / f0))
    harm = int((rate / 2) / f0 * 0.4)
    table = [sum(math.sin(2 * math.pi * h * i / period) / h for h in range(1, harm)) for i in range(period)]
    peak = max(abs(v) for v in table)
    table = [v / peak for v in table]
    sigma = 10 ** (noise_db / 20)
    out = _arr.array("h")
    phrase = 1.5
    for i in range(int(seconds * rate)):
        t = i / rate
        in_phrase = (t % (phrase + pause)) < phrase
        env = (0.55 - 0.45 * math.cos(2 * math.pi * 4 * t)) if in_phrase else 0.0
        v = level * env * table[i % period] + rng.gauss(0, sigma)
        if rumble:
            v += rumble * math.sin(2 * math.pi * 40 * t)
        if clip:
            v *= 6
        out.append(int(max(-32768, min(32767, round(v * 32768)))))
    return out


an = sc.analyse(voice(), "alsa_input.example")
check("the analysis finds the voice and the room", "error" not in an and an["noiseSure"], str(an.get("error", "")))
check("the room is measured in the pauses", abs(an["noise"] - (-65.0)) < 3, str(an["noise"]))
check("the voice well above it", an["speech"] - an["noise"] > 25, f'{an["speech"]} over {an["noise"]}')
check("the pitch is found", abs(an["f0"] - 120) <= 5, str(an["f0"]))
check("nothing clipped", an["clips"] == 0)
check("no rumble in a clean voice", an["rumble"] < -20, str(an["rumble"]))
check("both spectra on the grid", len(an["spectrum"]) == sc.GRID and len(an["noiseSpectrum"]) == sc.GRID)
check("a deep voice is heard as one", abs(sc.analyse(voice(f0=85.0))["f0"] - 85) <= 4)
check("a high voice too", abs(sc.analyse(voice(f0=210.0))["f0"] - 210) <= 8)

clipped = sc.analyse(voice(clip=True))
check("clipping is counted", clipped["clips"] > 0, str(clipped.get("clips")))
check("and it is the first thing said, in red", sc.findings(clipped)[0]["urgent"] and "clipped" in sc.findings(clipped)[0]["text"])
check("too short to measure", "error" in sc.analyse(voice(seconds=2.0)))
check("silence is not a voice", "error" in sc.analyse(_arr.array("h", [0] * sc.RATE * 6)))
check("noise is not a voice", "error" in sc.analyse(voice(level=0.0, noise_db=-40.0)))
check("talking without a pause leaves the room unmeasured",
      not sc.analyse(voice(pause=0.0))["noiseSure"])
rumbly = sc.analyse(voice(rumble=0.2))
check("rumble is heard", rumbly["rumble"] > -20, str(rumbly["rumble"]))

graph = {"lsp": True}
fits = {pid: sc.fit_preset(pid, an, graph) for pid in sc.FITTED_IDS}
check("four presets to fit", list(fits) == ["natural", "call", "podcast", "stream"])
for pid, fit in fits.items():
    merged = sc.normalise(dict(sc.default_settings(), **fit))
    check(f"{pid}: within every range", all(merged[k] == fit[k] for k in fit))
    check(f"{pid}: the gate sits between the room and your softest words",
          an["noiseEnv"] < fit["gate"]["threshold"] < an["lowEnv"], f'{an["noiseEnv"]} < {fit["gate"]["threshold"]} < {an["lowEnv"]}')
    check(f"{pid}: the compressor starts under your voice", fit["compressor"]["threshold"] < an["speech"])
check("the presets go from gentle to firm",
      fits["natural"]["compressor"]["ratio"] < fits["call"]["compressor"]["ratio"]
      < fits["podcast"]["compressor"]["ratio"] < fits["stream"]["compressor"]["ratio"])
check("and from quiet to loud", fits["stream"]["gain"] > fits["natural"]["gain"])
check("a call cuts more low end", fits["call"]["highpass"]["freq"] >= 100)
check("the high-pass stays under the voice", all(f["highpass"]["freq"] <= 0.6 * 120 + 30 for f in fits.values()))
deep = dict(an, f0=85)
check("a deep voice keeps its low end", sc.fit_preset("podcast", deep, graph)["highpass"]["freq"] == 65)
check("rumble sends the high-pass up", sc.fit_preset("podcast", dict(an, rumble=-10.0), graph)["highpass"]["freq"] == 100)
noisy = dict(an, noise=an["speech"] - 22, noiseEnv=an["speech"] - 24)
check("a noisy room gets more noise removal",
      sc.fit_preset("call", noisy, graph)["denoise"]["amount"] > fits["call"]["denoise"]["amount"])
check("natural in a quiet room leaves the gate and the noise removal off",
      not sc.fit_preset("natural", dict(an, noise=an["speech"] - 50), graph)["gate"]["on"]
      and not sc.fit_preset("natural", dict(an, noise=an["speech"] - 50), graph)["denoise"]["on"])
quiet_mic = dict(an, speech=an["speech"] - 20, spread=[d - 20 for d in an["spread"]])
check("a quieter microphone gets more volume", sc.fit_preset("call", quiet_mic, graph)["gain"] > fits["call"]["gain"])
check("and is told to turn up", any("quiet" in f["text"] and f["urgent"] for f in sc.findings(quiet_mic)))
check("without a compressor the volume makes up the difference",
      sc.fit_preset("podcast", an, {})["gain"] != fits["podcast"]["gain"])
typical = {pid: sc.fit_preset(pid, None, graph) for pid in sc.FITTED_IDS}
check("without a test the presets are set for a voice like most",
      all(sc.normalise(dict(sc.default_settings(), **f))["gate"]["threshold"] == f["gate"]["threshold"] for f in typical.values()))
check("the curve leaves your pitch alone",
      all(abs(v) < 1e-9 for k, v in enumerate(sc.matching_curve(deep, 0.5)) if sc.grid_freq(k) < 1.5 * 85))
loud_room = dict(an, noiseSpectrum=[d - 3 for d in an["spectrum"]])
check("and lifts nothing where the room is as loud as the voice",
      max(sc.preset_curve(dict(sc.PRESETS)["stream"], loud_room)) <= 0.0 + 1e-9
      and max(sc.matching_curve(loud_room, 0.6)) <= 1e-9)
check("the curve stays within reach", all(-12 <= v <= 12 for f in fits.values() for v in f["curve"]))
view = sc.analysis_view(dict(an, at=1, mic="alsa_input.example"), "alsa_input.example")
check("the panel is told what was measured", view["sameMic"] and view["speech"] == round(an["speech"]))
check("a test on another microphone is not used for this one",
      sc.preset_fits(dict(an, mic="alsa_input.other"), "alsa_input.example", graph)[3]["settings"] == typical["podcast"])
listed = sc.preset_fits(an, "alsa_input.example", graph)
clean = listed[0]
check("clean comes first, with nothing to fit", clean["id"] == "clean" and clean["fitted"] is False
      and all(p["fitted"] for p in listed[1:]))
check("clean switches every step and every effect off",
      all(clean["settings"][k] == {"on": False} for k in ("highpass", "denoise", "gate", "compressor", "limiter",
                                                          "distortion", "pitch", "reverb")))
check("with the curve flat and the volume at 0",
      clean["settings"]["curve"] == [0.0] * sc.GRID and clean["settings"]["gain"] == 0.0)
mine = sc.default_settings()
mine["gate"]["threshold"] = -47.0
mine["distortion"].update(on=True, kind="fuzz", drive=80.0)
for k, v in clean["settings"].items():
    if isinstance(v, dict):
        mine[k].update(v)
    else:
        mine[k] = v
merged = sc.normalise(mine)
check("and leaves the sliders where they were", merged["gate"] == {"on": False, "threshold": -47.0}
      and merged["distortion"] == {"on": False, "kind": "fuzz", "drive": 80.0})
check("clean is kept as the preset chosen", sc.normalise({"preset": "clean"})["preset"] == "clean")
check("the preset chosen is kept, an unknown one is not",
      sc.normalise({"preset": "podcast"})["preset"] == "podcast" and sc.normalise({"preset": "evil"})["preset"] == "")

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
    sc.write_conf(sc.default_settings(), {"v": 3}, "alsa_input.example")
    check("a chain from an older version keeps its config", not os.path.exists(os.path.join(cfg, "pipewire.conf")))
    sc.write_conf(sc.default_settings(), {"v": sc.GRAPH_VERSION}, "alsa_input.example")
    check("a current one gets it rewritten", os.path.isfile(os.path.join(cfg, "pipewire.conf")))
    sc.store_json(sc.ANALYSIS_FILE, dict(an, mic="alsa_input.example"))
    back = sc.load_analysis()
    check("an analysis is kept and read back", back is not None and back["speech"] == an["speech"]
          and back["spectrum"] == an["spectrum"])
    for name, bad in (("a short spectrum", dict(an, spectrum=[0.0] * 3)), ("a level that is text", dict(an, speech="loud")),
                      ("an infinite level", dict(an, noise=float("inf"))), ("an old version", dict(an, v=0))):
        sc.store_json(sc.ANALYSIS_FILE, bad)
        check(f"an analysis with {name} is not used", sc.load_analysis() is None)
    sc.store_json(sc.ANALYSIS_FILE, dict(an, speech=40.0, mic="x; rm"))
    odd = sc.load_analysis()
    check("numbers out of range are brought back, and a bad name dropped", odd["speech"] == 0 and odd["mic"] == "")

sys.exit(1 if failures else 0)
