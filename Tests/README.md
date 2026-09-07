# Tests

## AUNBandEQ tests

`NBandEQTests.m` exercises Apple's parametric EQ (`kAudioUnitSubType_NBandEQ`),
which `Source/EffectAdditions.m` registers as `AppleParametricEQ`.

```bash
Tests/run-nbandeq-tests.sh          # full suite, three allocator configurations
Tests/run-nbandeq-tests.sh --quick  # skips the soak, format matrix and churn
```

The runner builds with `clang` directly -- there is no Xcode target -- and runs
the suite three times: plain, under libmalloc's scribble/guard-edge
diagnostics, and under Guard Malloc, which puts every allocation on its own
page so an out-of-bounds access inside AudioToolbox faults immediately instead
of quietly touching neighbouring heap.

## Results on macOS 14.8.8 (AUNBandEQ 1.6.0)

The render and parameter surfaces are clean. 232 assertions pass in every
configuration, including:

- a 46-second render soak with ~1.7M parameter writes racing the render thread
- ~3.4M band-count resizes performed *during* an active render
- all 16 bands active across 4 sample rates x 4 channel counts x 4 slice sizes
- 300 instantiate / configure / render / uninitialize / dispose cycles
- gain accuracy within 0.5 dB of the requested value

No heap canary was ever disturbed, no render call returned an error, and no
allocation overrun was detected under Guard Malloc.

Two behaviours worth recording, neither of them a defect:

- **`kAUNBandEQProperty_NumberOfBands` is settable while initialized**, though
  `AudioUnitProperties.h` says it "can only be set if the unit is
  uninitialized". The unit resizes correctly and survives being resized under a
  live render, but the header and the implementation disagree.
- **Gain parameters are not clamped.** `AudioUnitSetParameter` stores any finite
  value verbatim, so a gain past roughly ±20000 dB overflows `10^(dB/20)` and
  puts infinity in the stream. NaN and infinity are refused outright
  (`kAudioUnitErr_InvalidParameterValue`), and frequency, bandwidth, filter type
  and bypass never destabilise the filter at any value. This is arithmetic, not
  corruption. It is unreachable from the app's own UI, which clamps to the
  parameter's declared range.

## The one real finding: preset deserialization

`testFullStateRecordCountIsValidated` fails, and it should. The opaque `data`
blob inside an audio unit's `fullState` is laid out as:

```
[8-byte header][big-endian uint32 record count][count x 8-byte records]
```

Each record is a big-endian `float` value followed by a big-endian parameter ID.
For a default eight-band unit the count is 81 and the blob is 12 + 81*8 = 660
bytes.

**Nothing cross-checks that count against the blob's actual length.** A blob
declaring more records than it holds walks the parser off the end of the
allocation:

```
CoreAudio  movl 0x4(%rbx), %eax     <-- faults here
           bswapl %esi
           bswapl %eax
AudioToolboxCore  AudioUnitSetProperty          (kAudioUnitProperty_ClassInfo)
AudioToolboxCore  setStateAndNotify(CFDictionary, AUAudioUnitV2Bridge*, uint)
```

It is an out-of-bounds **read**, not a write, so it is a crash rather than an
exploitable corruption primitive. With the normal allocator it only faults once
the walk reaches an unmapped page -- a count of 65536 is silently tolerated
while 1048576 crashes. Under Guard Malloc even a blob truncated to 12 bytes
faults, which is what proves the read is genuinely out of bounds rather than
merely unlucky.

The format is CoreAudio's shared `ClassInfo` representation, not something
AUNBandEQ defines, so `testOtherAppleEffectsShareTheFormat` confirms the same
layout in AUGraphicEQ, AUParametricEQ, AUDynamicsProcessor, AUMultibandCompressor,
AUPeakLimiter, AULowpass, AUHighShelfFilter, AUDelay and AUMatrixReverb.
Feeding `count = 0xFFFFFFFF` crashes AUGraphicEQ, AUDynamicsProcessor,
AUMultibandCompressor and AUPeakLimiter as well.

### Why this matters here

`Source/Effect.m:106` deserializes a property list straight out of a saved set
list and hands it to `-setFullState:` without validation:

```objc
NSDictionary *fullState = [NSPropertyListSerialization propertyListWithData:info ...];
if (fullState) [_audioUnit setFullState:fullState];
```

A truncated or corrupted set list file therefore crashes the app on load, for
any Apple effect, with no way for the user to recover the rest of the file.
These cases are reported as `XFAIL`, not `FAIL`: they document Apple's defect
and will start passing the day it is fixed, but they do not fail the suite,
because the app now screens the blob itself.

## The workaround

`Source/AudioUnitStateValidation.m` validates the blob before it reaches the
audio unit: `data`, if present, must be `NSData`, at least 12 bytes long, and
`12 + count * 8` must equal its length exactly. Non-Apple units are passed
through untouched, since their state is opaque and guessing at the format would
throw away valid presets.

`Source/Effect.m` routes all four of its `-setFullState:` call sites through
`-_applyFullState:toAudioUnit:`, which applies the check and, on rejection, logs
and leaves the unit at its current values:

- the bundled `.aupreset` loaded at construction
- the state stored in a saved set list (`-initWithStateDictionary:`)
- `-loadAudioPresetAtFileURL:`, which takes any file the user picks
- the temporary unit inside `-_setFullState:`

A set list with a malformed effect state now keeps the effect in the chain at
its defaults rather than dropping it, so the signal path does not change shape
underneath the user mid-set.

`testStateValidatorHoldsUnderFuzzing` pins the guarantee that matters, and it is
deliberately one-directional: **anything the validator accepts must not crash.**
Across 250 fuzzed presets it accepts ~181 and none of them crash, in all three
allocator configurations. Of the ~69 it rejects, roughly a third would in fact
have been harmless -- an acceptable trade, since those blobs are corrupt either
way and the cost of being wrong in the other direction is a crash on stage.

---

# AUNBandEQ editor tests

`NBandEQViewTests.m` covers what the headless suite cannot: Apple's *editor*,
`AUNBandEQView`, which `EditSystemEffectController` embeds whenever the user
opens the Parametric EQ window.

```bash
Tests/run-nbandeq-view-tests.sh
```

These need a window server session -- they load the view, host it in an
offscreen window and really draw it -- so they will not run over a plain SSH
login. Each case runs in its own exec'd child, because two of them are known
Apple crashes and would otherwise take the whole run down. `fork` without
`exec` is not usable here: AppKit cannot be used in a forked child, and a bare
fork produces convincing-looking crashes that have nothing to do with the EQ.

## Results on macOS 14.8.8

Fine: parameter edits under a live editor, out-of-range and non-finite values,
200 preset loads with the window open, and audio rendering (4M+ slices) while
the editor is driven. Two crashes, both reachable from the app's UI, both now
mitigated:

### 1. Band count changing under a live editor

Three or four changes are enough. AppKit traps on a rect computed by
`-[CAAppleEQGraphView updateGraphFrame]` via `-[CAFilterControl update]`, from
controls the band-count change has already invalidated. A single change is
always safe; only repetition crashes. Ordinary parameter editing never does.

The obvious repair -- rebuild the editor after the change -- does not work: an
audio unit hands out its view controller once, and a second
`-requestViewControllerWithCompletionHandler:` never completes.

**Mitigation:** `EmbraceAudioUnitFullStateByPreservingBandCount()` holds the
band count at whatever the unit already has, so a preset cannot move it.
`Effect.m` applies this to every state it installs. This costs nothing in
practice: the app never varies the count, and AUNBandEQ exposes all its bands
regardless, leaving unused ones bypassed. Verified at 200 preset loads.

Reachable from **Load Preset…** and **Restore Default Values**
([EditEffectController.m:133](../Source/EditEffectController.m:133) and
[:161](../Source/EditEffectController.m:161)) with the EQ window open.

### 2. Closing the editor window while releasing the audio unit

Closing the window tears down the backing layer that CoreAudioKit still has a
deferred update queued against; releasing the unit removes what would otherwise
keep it alive. **Either alone is survivable -- together they crash.** That
combination is exactly what `-closeEditControllerForEffect:` did: `[controller
close]`, followed immediately by the caller releasing the effect.

**Mitigation:** order the window out instead of closing it, which leaves the
layer intact for the pending update to land on. Verified over 12 cycles.

Reachable by selecting the Parametric EQ in the Effects window and deleting it
while its editor is open ([EffectsController.m:324](../Source/EffectsController.m:324)).

## What these tests do not cover

No synthesized mouse input. Dragging band handles on the curve runs AppKit
tracking loops, which are difficult to drive deterministically from a test and
easy to hang. If a corruption bug lives in the drag handling specifically,
nothing here would find it.

---

# Synthesized mouse tests

`NBandEQMouseTests.m` posts real `NSEvent`s and dispatches them, so the code
under test is the editor's own mouse handling rather than the audio unit's API.

```bash
Tests/run-nbandeq-mouse-tests.sh
```

The obvious failure mode for a suite like this is passing by doing nothing, so
every interaction is measured against the parameter tree and the band count: an
interaction that changes neither is not counted as exercised, and
`testControlsRespond` fails outright if nothing in the editor reacts.

Mechanically: drag and mouse-up events are posted *before* the mouse-down that
starts a control's tracking loop, because the loop pulls from the same queue,
and the queue is drained between interactions so one cannot poison the next.
Each group runs in an exec'd child under `alarm(90)`, so a wedged tracking loop
is reported as a watchdog kill instead of hanging the run.

`NSPopUpButton` is excluded everywhere. It is an `NSButton` subclass, so a naive
button sweep picks up the per-band filter-type popups, and clicking one opens a
modal menu loop that a synthetic event stream has no way out of -- it wedges
until the watchdog fires.

## What is covered

Slider drags, 391 random drags across and beyond the editor's bounds, and 60
clicks against ~32k rendered audio slices. Parameters stay finite throughout,
the unit stays coherent, and audio never goes non-finite.

## What is not covered, and why

**Dragging band handles on the response curve.** `AUAdvancedEQGraphView`
declines `mouseDown:` -- it returns in 0.0000s, and a 4px-resolution sweep of
the whole curve finds no grabbable point -- unless its window is key. A session
that will not grant key status makes this untestable: `makeKeyWindow`,
`activateIgnoringOtherApps:`, a `canBecomeKeyWindow` override and wrapping the
binary in a `.app` bundle all leave `isKeyWindow` false.

The test detects this and **skips loudly rather than passing**. A plain
`NSSlider` in the same view moves under the identical technique, which is what
establishes that the harness works and the graph view is genuinely gating on
key status. Re-run from a normal GUI login to cover it.

**The editor's own band-count controls.** The ten plain buttons are the add and
remove-band controls: a `+`/`-` pair in the header and a `-` per visible band
row. Neither a synthetic click nor `-performClick:` moves a parameter or the
band count, so their actions are not reachable from this harness and the suite
reports `0 of 10`.

This matters for how the band-count crash is scoped. If those buttons did change
the count, a user could reach that crash by clicking `+`/`-` a few times, and
`EmbraceAudioUnitFullStateByPreservingBandCount()` would not help -- it only
guards state the app installs. **That was not demonstrated**, so the crash
remains scoped to the preset path. It is worth re-checking on a machine where
the editor's controls do respond.

## An unguarded accessor, noted but not filed

Clicking a control inside one of the eight hidden band rows reaches
`-[CAAppleEQGraphView controlAtIndex:]` with an index past the end of its
control array and throws `NSRangeException: index 8 beyond bounds [0 .. 7]`.

A real mouse cannot click a hidden row, so this is not a user-reachable crash
and the app needs no mitigation for it. It is recorded because the accessor is
unguarded: anything else that reaches it with a stale index -- a band count that
moved, say -- throws the same way. `IsReachableByMouse()` keeps the suite to
controls a mouse could actually hit.


## Parametric EQ core

`ParaEQCoreTests.cpp` checks `Source/paraeq_core.{h,cpp}`, the portable core
behind the app's own Parametric Equalizer. Framework-free and headless, because
the core is: it is meant to go upstream beside declick and dehum, so anything it
needed from AudioToolbox would belong in the wrapper instead.

```bash
Tests/run-paraeq-core-tests.sh   # -O2 as shipped, then -O0 with asan + ubsan
```

43 checks, all passing on macOS 14.8.8. The interesting ones:

- **measured vs predicted.** Sines are run through a real `Channel` and the gain
  it actually applies is compared against `magnitudeDb()`, within 0.06 dB at
  nine frequencies. This is what keeps the curve a host draws honest: without
  it, both sides could agree on the same wrong formula.
- **cookbook sections land where the formulas say.** Peaking gain at its centre,
  shelf gain at DC and Nyquist, half gain at the shelf corner, -3.01 dB at the
  high-pass corner at both 12 and 24 dB/oct, and -12.30 / -24.10 dB an octave
  below it, which is what makes the two-stage version Butterworth rather than
  merely fourth order.
- **interpolated coefficients stay inside the stability triangle.** 49 pairs of
  the most distant settings the controls allow, 1001 interpolants each. The
  glide's safety is an argument rather than a measurement -- the stable region
  is convex, so a straight line between two stable settings cannot leave it --
  and this pins the argument to the code.

One finding came out of writing them. The glide originally stepped the
coefficients once per 32-sample sub-block, and *that is audible*: a jump in `b0`
puts `b0*x` straight into the output, so each boundary left a step about 35 dB
below the signal, which the second difference of the output shows as 2.2e-2
against the 4.1e-4 the tone itself carries. Stepping every sample instead brings
it to 4.6e-4 -- the tone's own curvature -- and costs nothing in the state a
settled equaliser is in for all but 300 ms after a knob stops moving.
