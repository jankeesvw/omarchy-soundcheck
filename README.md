# Soundcheck

Draw the sound of your microphone.

Soundcheck puts a chain in front of your microphone: a curve you paint with the mouse, a noise gate, and when you want them, noise removal, a compressor and a limiter. Every app gets the result, because Soundcheck becomes your default input. Meet, Zoom, Slack, OBS, a browser tab, anything that records.

<p align="center"><img src="screenshots/panel.png" alt="The Soundcheck panel on a dark theme: a painted curve over the live spectrum of the microphone, the chain with high-pass, noise removal, noise gate, compressor, limiter and volume, and the test and listen-in controls" width="49%">&nbsp;<img src="screenshots/light.png" alt="The same panel on Catppuccin Latte" width="49%"></p>

And it lets you hear what you did. Record ten seconds and they play back round and round the way the others will hear them, while you keep changing things, with Before and After one click apart. Or listen in: your own voice in your headphones while you paint the curve, through every step.

The bar shows a pair of headphones. Dimmed while Soundcheck is off, in your accent colour while it is on, with a dot beside them while you are listening in (the one state you do not want to forget about), and crossed out in red when the chain should be running and is not.

## Install

Everything in one go, the plugin together with the two packages it can use:

```bash
omarchy pkg add noise-suppression-for-voice lsp-plugins-lv2 && omarchy plugin add https://github.com/jankeesvw/omarchy-soundcheck --enable
```

It asks for your password for the packages, whether you trust the plugin, and where in the bar it goes (on the right unless you pick another place). Then click the headphones and switch it on.

The packages are for three steps only: `noise-suppression-for-voice` for noise removal (RNNoise), `lsp-plugins-lv2` for the compressor and the limiter. The curve, the high-pass, the noise gate, distortion, reverb, the volume, the test and listening in are built into PipeWire itself. So the plugin alone works too:

```bash
omarchy plugin add https://github.com/jankeesvw/omarchy-soundcheck --enable
```

The steps that need a package then say which one, and copy the command when you click it. Once a package is there, its step offers to restart the chain. That is a second of silence on the microphone, so do it before a call rather than in one.

## Switching it on

The switch at the top of the panel. It does three things:

1. It starts the chain as a small PipeWire client of its own, under a systemd user service, so it is there again after a reboot.
2. It makes **Soundcheck Microphone** your default input.
3. It moves anything that is already recording over to it. Without this, a call that was running when you switched would keep the bare microphone until you rejoined.

Switching it off does the same in reverse: the microphone you had becomes the default again, recording apps move back to it, and the service is removed.

PipeWire and WirePlumber are never restarted, not when you switch, not when you change something. A restart drops every app's audio connection, and some hardware does not take it well; a webcam that hangs every time you touch your microphone settings is not a trade anyone wants. The way Omarchy runs its own speaker tuning is the way this runs too.

Pick the microphone in the panel. The chain listens to that one microphone and never to "the default", because the default is now the chain itself. Switching microphones moves the chain over without a restart.

## Drawing the curve

Drag across the graph and the curve follows the pointer: wherever you go, the curve goes to your height. The brush is soft, about a third of an octave wide, so a quick stroke comes out smooth rather than jagged. Drag with the right button to paint back towards 0 dB, double-click to start over flat.

Behind the curve runs a live spectrum of your microphone while the panel is open: where your voice sits and how loud, twenty times a second. A dotted line over it holds the loudest each frequency has been for the last second or two, and the one that sticks out most gets its frequency written next to it. With Soundcheck on, a line shows what it sends on, so you see a peak go down as you paint over it. The scale follows your microphone, so a quiet one fills the graph as well as a loud one.

That is the point of drawing here rather than turning knobs: the hum is a bump at 50 Hz, the boxiness is a hump around 300, the hiss is a shelf above 8 kHz, a whistle is a spike that keeps its label, and you can paint them out where you see them.

There are two lines on top. The filled one is what you painted. The thin one is what the filters actually do, worked out with the same formulas PipeWire runs, so it is what you will hear. They match within a dB; where they part is the high-pass at the bottom end.

Under the graph sit 30 filters, one every third of an octave from 25 Hz to 20 kHz. Neighbouring filters overlap, so their boosts add up: setting each one to the height you painted would overshoot by several dB. Soundcheck solves all thirty together instead, so the sum lands on your curve.

Every change is heard straight away, while you drag. Nothing restarts and nothing clicks, so you can do this during a call.

Four starting points sit above the graph: **Flat**, **Clearer** (less boxiness around 280 Hz, more presence around 4 kHz), **Warmer** and **Less hiss**. **Bypass** switches everything to neutral for as long as you hold it on, so you can hear the difference live. It never touches what you saved.

## The chain

In the order your voice goes through it:

| Step | What it is for | Starts at |
|---|---|---|
| **High-pass** | Rumble, pops, the desk being bumped. Everything below the frequency is cut. | 80 Hz |
| **Noise removal** | RNNoise, a small neural network that keeps voices and drops fans, keyboards and traffic. The slider is how sure it must be that you are talking. Needs `noise-suppression-for-voice`. | 50% |
| **Noise gate** | Silence between your sentences: shut 3 dB under the threshold, fully open 3 dB over it, opening at once and letting go gently. Under the slider runs a strip of the last six seconds: how loud your microphone was, with the threshold drawn across it. What got through is in your accent colour, what the gate held back is grey, so you can put the threshold between the room and your voice and watch it work. | -55 dB |
| **Curve** | What you painted. | flat |
| **Distortion** | Grit, from a little warmth to a broken radio. The slider is the drive; the loudness stays about where it was. | off, 40% |
| **Compressor** | Evens out loud and quiet. The slider is the threshold, the ratio is 3:1, and half of what it takes away at full level is given back, so switching it on makes you more even rather than quieter. Needs `lsp-plugins-lv2`. | -24 dB |
| **Reverb** | A room around your voice: made up, about a second long, and the same room every time. The slider is how much of it you hear. | off, 30% |
| **Limiter** | A ceiling nothing goes past, for the laugh that would otherwise clip. Needs `lsp-plugins-lv2`. | -1 dB |
| **Volume** | The level of the whole thing, for when the curve took a lot away or added a lot. | 0 dB |

## Testing it

**Record** takes up to ten seconds; press it again to stop sooner. It records your bare microphone and plays it straight back through the chain, round and round until you press Stop.

While it plays, change anything: paint the curve, move the gate, switch a step on or off. You hear it on the next word, because After is not a recording of how it sounded then but your recording going through a preview of the chain right now. The graph and the gate's strip follow the recording while it plays, so you see what you hear. The preview is a chain of its own that plays on the output you listen in on and never reaches an app, so this works with Soundcheck switched off as well.

**Before** plays the recording as it is. Switching while it plays starts the other one from the top, so you compare the same sentence.

While a test plays, listening in pauses, or you would hear yourself twice.

The recording lives in `$XDG_RUNTIME_DIR/omarchy-soundcheck/`, which is memory, not disk. The next test replaces it and logging out removes it.

## Listening in

Switch on **Listen in** and you hear yourself in your headphones, through every step: what the others get. Handy while you paint the curve, and for some people during calls as well.

It picks the first output that is a pair of headphones. Pick a speaker instead and the panel warns you, because the speakers will feed back into the microphone.

Listening in stays on when you close the panel; the dot beside the headphones in the bar reminds you. It never switches itself on, also not after a restart of the shell, so you will not suddenly hear yourself out of nowhere.

## Keys

Everything works without a mouse. Tab walks the controls. On the graph, Left and Right pick a frequency, Up and Down raise or lower it by half a dB (Shift for 3 dB), 0 sets it back to zero and F makes the curve flat. On a step, Space switches it and Left and Right move its slider.

Anywhere in the panel: **R** records, **P** plays, **L** listens in, **B** bypasses and **Esc** closes.

## Command line

The panel runs a small helper that lives inside the plugin:

```bash
~/.config/omarchy/plugins/jankeesvw.soundcheck/bin/soundcheck status
```

```bash
soundcheck status                      # everything the panel shows, as JSON
soundcheck on | off                    # what the switch does
soundcheck reload                      # rebuild the chain after installing a package
soundcheck mic <node name>             # listen to another microphone
soundcheck save '<settings json>'      # store settings and apply them
soundcheck render                      # the PipeWire config "on" would write
soundcheck demo on | off               # invented devices and curve, for screenshots
```

## What it writes

- `~/.config/omarchy-soundcheck/settings.json`: your curve and the settings of every step.
- `~/.config/omarchy-soundcheck/state.json`: the microphone to give back when you switch off, and which packages the running chain was built with.
- `~/.config/omarchy-soundcheck/pipewire.conf`: the chain, only while Soundcheck is on.
- `~/.config/omarchy-soundcheck/reverb.wav`: the room the reverb plays, written the first time it is needed.
- `~/.config/systemd/user/omarchy-soundcheck.service`: the service that runs it, only while Soundcheck is on.
- `$XDG_RUNTIME_DIR/omarchy-soundcheck/`: the last test recording, and the preview's config while one plays, in memory.

The directory is private to you (0700, files 0600) and every file is written to a temporary name first and then moved into place, so a half-written settings file cannot happen.

Nothing goes over the network. The microphone is opened by the chain only while something records from Soundcheck Microphone, and by the panel only while the panel is open, for the meter.

## If something is not working

**The bar shows a crossed-out red microphone.** The service should be running and the microphone it provides is gone. `systemctl --user status omarchy-soundcheck` says why. Switching off and on again in the panel rebuilds it.

**The panel says apps use another input.** Something set the default input back to your bare microphone, often the input list in Omarchy's own audio panel. Switch Soundcheck off and on to take over again, or pick Soundcheck Microphone in that list.

**A step says it needs a package that is installed.** Click **Restart chain** under it. A chain is built with what was installed when it started.

**The meter under the gate does not move.** It shows the microphone picked in the panel. Check that it is the one you are talking into.

**You hear an echo of yourself.** Listening in is on. The dot beside the headphones in the bar says so.

## Removing it

Switch Soundcheck off first, in the panel or with `soundcheck off`. That gives your microphone back and removes the service. Then:

```bash
omarchy plugin remove jankeesvw.soundcheck
rm -r ~/.config/omarchy-soundcheck
```

The second line takes your curve and settings with it.

Removed the plugin while Soundcheck was still on? The service keeps running without it, so take it out by hand and pick your microphone again in Omarchy's audio panel:

```bash
systemctl --user disable --now omarchy-soundcheck.service
rm ~/.config/systemd/user/omarchy-soundcheck.service
systemctl --user daemon-reload
```

The packages for noise removal and the compressor stay installed: other things may use them. `omarchy pkg drop noise-suppression-for-voice lsp-plugins-lv2` removes them.

## Credit

The filters are the ones from Robert Bristow-Johnson's [Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/), which PipeWire's built-in filters implement too. Noise removal is [RNNoise](https://github.com/xiph/rnnoise) by Jean-Marc Valin, as packaged by [werman/noise-suppression-for-voice](https://github.com/werman/noise-suppression-for-voice). The compressor and limiter are from [LSP Plugins](https://lsp-plug.in).

None of them has anything to do with this one.

## Licence

MIT.

The devices and the curve in the screenshots come from the plugin's demo mode (`soundcheck demo on`), shot in a clean Omarchy VM on its stock wallpapers.
