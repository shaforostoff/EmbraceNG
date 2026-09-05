# Embrace

[Embrace](https://www.ricciadams.com/projects/embrace) is a music player designed for the unique challenges of DJing social dance events. It focuses on playing back a single set list without audio glitches or accidental interruptions.

## Philosophy

Audio programming is hard. macOS audio programming is harder (usually due to sparse documentation). This repository is publicly-viewable in the hopes that its source code can help others.

Embrace is feature-complete and closed to outside contributions.

If you are struggling with an audio or DSP concept, you can contact me via my [contact form](https://www.ricciadams.com) and I can try to point you in the right direction.

## License

I only care about proper attribution in source code. While attribution in binary form is welcomed, it is not necessary.

Hence, unless otherwise noted, all files in this project are licensed under both the [MIT License](https://github.com/iccir/Embrace/blob/main/LICENSE) **or** the [1-clause BSD License](https://opensource.org/license/bsd-1-clause). You may choose either license.

`SPDX-License-Identifier: MIT OR BSD-1-Clause`

# EmbraceNG
Integrates Declick and Dehum from https://github.com/shaforostoff/shellacfilters as well as Parametric EQ.

Improved behaviour when external soundcard is suddenly disconnected during playback (I have seen this happening during a DJ set): after soundcard is replugged, the app continues playing the music from where it was. With original Embrace you'll have to start the track from beginning (and there is no way to skip to the middle of the song).

Keyboard control has been improved, automatic fade out when Stop is pressed (press the button one more time if it was accidental; set fadeout time to 0 in settings to get the old behaviour).
