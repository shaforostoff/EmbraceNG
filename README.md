# Embrace

[Embrace](https://www.ricciadams.com/projects/embrace) is a music player designed for the unique challenges of DJing social dance events. It focuses on playing back a single set list without audio glitches or accidental interruptions.

## Philosophy

Audio programming is hard. macOS audio programming is harder (usually due to sparse documentation). This repository is publicly-viewable in the hopes that its source code can help others.

Embrace is feature-complete and closed to outside contributions.

## License

Only proper attribution in source code matters. While attribution in binary form is welcomed, it is not necessary.

Hence, unless otherwise noted, all files in this project are licensed under both the [MIT License](https://github.com/shaforostoff/EmbraceNG/blob/main/LICENSE) **or** the [1-clause BSD License](https://opensource.org/license/bsd-1-clause). You may choose either license.

`SPDX-License-Identifier: MIT OR BSD-1-Clause`

# EmbraceNG (fork of Embrace)
Integrates Declick and Dehum from https://github.com/shaforostoff/shellacfilters as well as Parametric EQ.

Improved behaviour when external soundcard is suddenly disconnected during playback (I have seen this happening during a DJ set): after soundcard is replugged, the app continues playing the music from where it was interrupted. With original Embrace you'll have to start the track from beginning (and there is no way to skip to the middle of the song).

Keyboard control has been improved, automatic fade out when Stop is pressed (press the button one more time if it was accidental; set fadeout time to 0 in settings to get the old behaviour).

## Tempo and rhythm

A track with no BPM tag gets one measured from the audio. It happens during the
loudness scan the app already runs over every track when it joins the set list,
so no file is decoded twice and nothing has to be asked for: the BPM column
fills itself in.

A tag is never overwritten. The measurement is kept beside it rather than on top
of it, so a BPM added or corrected in the file later wins with no re-analysis,
and a track's state file says plainly which number came from where. The column
shows the tag where there is one and the measurement where there is not.

Nothing is measured until the tags have been read, which is the point at which
it is knowable whether measuring would add anything. Two answers come out of
the one decode, and a tag can close either: a BPM tag fills the column, and a
genre tag settles what the cortina switching below reads -- *any* genre tag,
since one naming no dance is a DJ saying this track is not part of a tanda. A
file carrying both is scanned for its waveform and not measured. The wait is a
tag parse against a decode that takes seconds, and only for the first track:
after that the metadata queue is far ahead of the scanning one.

**The BPM column is the feature's on and off.** With it off -- View > Track
Attributes > Beats Per Minute -- nothing is measured, because nothing would
read the answer. Switching it off mid-set does not throw away what has already been
measured; that is paid for, and the effects go on using it. It stops further
tracks being analysed, and switching the column back on starts them again.

The analysis is `bpmcore`, from
[foo_rubato](https://github.com/shaforostoff/foo_rubato) and vendored verbatim
under `Vendor/` -- see `Vendor/PROVENANCE.md`. It reports the tempo at the level
a dancer taps, which is the beat for a tango and the bar for a vals or a
milonga, and it settles the rhythm first because that is what decides the level.
Measured upstream against 3,692 hand-tapped tracks it lands within 2 BPM of the
tap 88.7% of the time, and classifies the rhythm correctly 93.6% of the time.
Three minutes of stereo costs about 0.2 seconds, against a decode that takes far
longer.

What it does cost is memory, because the audio has to be buffered rather than
streamed: the onset envelope is normalised by the track's overall level, which
is not known until the last frame has been seen. That is one mono float per
sample for the length of the track -- about 30MB for a three minute side -- and
the worker tells the analyzer how long the track is so the buffer is allocated
once at the right size rather than grown into. Two tracks are scanned at a time
at most.

It runs on pffft rather than the portable scalar transform foo_rubato ships --
about six times faster at these sizes, using SSE on Intel and NEON on Apple
silicon.

Measurements are **not** kept between runs, given the column is on. Every track is analysed once per
launch rather than once ever, because a measurement is a guess about the file
and the state file is not the file: keeping one keeps a bad reading too, and
there is nowhere in the interface to clear it. Re-measuring each launch means a
fix to the analysis reaches every track by being installed.

What that costs is the decode it rides on -- a set list that was already scanned
is scanned again in the background at startup, and a large one will have that
running for a while after launch. `PERSIST_DETECTED_BPM_AND_RHYTHM` at the top
of `Source/Track.m` turns it into once ever; it also works from the build
without touching the file:

    GCC_PREPROCESSOR_DEFINITIONS = $(inherited) PERSIST_DETECTED_BPM_AND_RHYTHM=1

Off, the two values are dropped on the way in as well as never written, so it
means off whatever an earlier build happened to leave on disk.

## Cortina presets

A cortina is not a tango, and the declick, dehum and EQ settings that a 1940s
shellac transfer needs are actively wrong for a modern recording played to clear
the floor.

So: **save a preset called `cortina` in an effect, and that effect switches to it
whenever the track playing is not a tango, vals, milonga or candombe.** The
moment one of those four comes round again, the effect goes back to exactly what
it was holding before.

Saving the preset under that name is the whole of the setup, and deleting it is
the whole of the undo. An effect with no such preset is never touched, so this
is opt-in per effect: the Parametric EQ can follow the cortinas while Declick
stays where it is. The name is matched against the seven recent presets in each
effect's "..." menu, without its extension and ignoring case and accents.

What the track is comes from the genre tag where the file has one. Compound and
awkward spellings are expected -- `Tango Milonga`, `Tango negro`, `Vals criollo`,
`Milonga-Candombe`, `Neotango` all read correctly, and the narrower of two words
wins, so `Tango Vals` is a vals. A tag naming none of the four is an answer
rather than a shrug: a track tagged `Rock` is a cortina.

Where there is no genre tag, the rhythm measured above is used instead. That
path has no candombe class in it and does not need one: candombes classify as
milonga, which upstream chose because the milonga prior puts their BPM on the
level they are tapped at, and which is exactly right here too.

Where there is neither -- no tag, and a track too short or too quiet to measure
-- nothing is switched. The two ways to be wrong are not equal. Leaving your own
settings on a cortina costs one track; putting a cortina preset on an
unrecognised tango takes the restoration off a track that needs it, in front of
a floor.

Two things are worth knowing:

* **It is a restore, not an undo.** Settings changed by hand while a cortina
  plays sit on top of a state that is about to be put back, and go with it. The
  effects window is for between tandas, which is exactly when a cortina is
  playing, so this is the one sharp edge.
* **What gets written to disk is your settings, not the cortina preset.** A
  quit, a crash or an edit to the chain in the middle of a cortina all leave the
  chain you built in the preferences, not the one that happened to be audible.

## Reading crash reports

EscapePod writes crash reports to `~/Library/Application Support/EmbraceNG/Crashes` as raw hex — per-thread backtraces, the crashing thread's registers and a binary image list, with no symbol names, because symbolication was meant to happen on the telemetry server. `Build/Symbolicate.py` turns one into a readable backtrace:

    Build/Symbolicate.py              # newest report
    Build/Symbolicate.py --all        # every report

Frames in EmbraceNG resolve to function and source line whenever a binary or dSYM with a matching UUID is on the machine; add `--search <dir>` to point at the build that crashed. Frames in system frameworks print as `image + offset`, since those images live in the dyld shared cache and have no file on disk to read symbols from.

## Contact

If you have questions or feature requests for EmbraceNG (Embrace fork), you can contact me via [Facebook](https://www.facebook.com/shaforostoff).
