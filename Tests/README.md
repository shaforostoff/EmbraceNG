# AUNBandEQ tests

`NBandEQTests.m` exercises Apple's parametric EQ (`kAudioUnitSubType_NBandEQ`),
which `Source/EffectAdditions.m` registers as `EmbraceParametricEQ`.

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
