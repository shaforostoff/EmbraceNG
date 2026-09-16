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

The analysis is `bpmcore`, from
[foo_rubato](https://github.com/shaforostoff/foo_rubato) and vendored verbatim
under `Vendor/` -- see `Vendor/PROVENANCE.md`. It reports the tempo at the level
a dancer taps, which is the beat for a tango and the bar for a vals or a
milonga, and it settles the rhythm first because that is what decides the level.
Measured upstream against 3,692 hand-tapped tracks it lands within 2 BPM of the
tap 88.7% of the time, and classifies the rhythm correctly 93.6% of the time.
Three minutes of stereo costs about 0.2 seconds, against a decode that takes far
longer.

It runs on pffft rather than the portable scalar transform foo_rubato ships --
about six times faster at these sizes, using SSE on Intel and NEON on Apple
silicon.

## Reading crash reports

EscapePod writes crash reports to `~/Library/Application Support/EmbraceNG/Crashes` as raw hex — per-thread backtraces, the crashing thread's registers and a binary image list, with no symbol names, because symbolication was meant to happen on the telemetry server. `Build/Symbolicate.py` turns one into a readable backtrace:

    Build/Symbolicate.py              # newest report
    Build/Symbolicate.py --all        # every report

Frames in EmbraceNG resolve to function and source line whenever a binary or dSYM with a matching UUID is on the machine; add `--search <dir>` to point at the build that crashed. Frames in system frameworks print as `image + offset`, since those images live in the dyld shared cache and have no file on disk to read symbols from.

## Contact

If you have questions or feature requests for EmbraceNG (Embrace fork), you can contact me via [Facebook](https://www.facebook.com/shaforostoff).
