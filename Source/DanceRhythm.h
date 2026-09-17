// (c) 2026 Nick Shaforostov
// MIT License (or) 1-clause BSD License

// What the floor is dancing to, and how the two places that can answer it are
// read: a genre tag written by a person, and a rhythm measured from the audio.
//
// Only one distinction is actually acted on -- danced, or a cortina -- but the
// specific rhythm is carried through anyway, because it is what the logs need
// to be readable when a track is switched the wrong way round.
//
// The last function here is the other half of the same subject: whether the
// audio is worth asking at all, given what the tags have already said.

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, DanceRhythm) {
    DanceRhythmUnknown = 0,   // no tag, and nothing measured

    DanceRhythmTango,
    DanceRhythmVals,
    DanceRhythmMilonga,
    DanceRhythmCandombe,

    DanceRhythmReggae,        // measured only; bpmcore has a class for it
    DanceRhythmOther          // measured, and none of the above
};


#ifdef __cplusplus
extern "C" {
#endif

// Reads a genre tag however it is spelled: case, accents and punctuation are
// folded away, and the four names are looked for inside the string rather than
// against the whole of it, so "Tango Milonga", "Tango negro", "Vals criollo",
// "Milonga-Candombe" and "Neotango" all land where they should.
//
// Unknown for a tag that names none of the four, and not Other, because this
// function is only shown the string and cannot tell a cortina from a tag that
// was never filled in -- both arrive here as "no match".  Only the caller knows
// whether there was a tag at all, and -[Track danceRhythm] is where that is
// turned into an answer.
extern DanceRhythm GetDanceRhythmForGenreString(NSString *genre);

// Reads what BPMAnalyzerGetRhythm reported, which is one of bpmcore's own
// class names.  Exact, not fuzzy: these strings are ours on both ends.
//
// There is no candombe here and there does not need to be.  bpmcore has four
// classes and a catch-all, and candombes land in Milonga -- deliberately, since
// the milonga prior is what puts their BPM on the level they are tapped at.
// A candombe therefore reads as danced by this path as surely as by the tag.
extern DanceRhythm GetDanceRhythmForDetectedName(NSString *name);

// The rule, and the only one of these three a caller normally wants: the genre
// tag where the file has one, and the measurement where it does not.
//
// A tag naming none of the four reads as Other rather than Unknown, because a
// tag that says "Rock" is a DJ saying this is a cortina.  It is the absence of
// a tag, not its contents, that hands the question to the measurement -- so a
// tag nobody filled in is answered from the audio, and a tag somebody did fill
// in is never second-guessed by it.
//
// Unknown only when there was neither.
extern DanceRhythm GetDanceRhythm(NSString *genre, NSString *detectedName);

// Tango, vals, milonga and candombe.  This is the question the effects switch
// on: everything else played at a milonga is a cortina.
extern BOOL GetDanceRhythmIsDanced(DanceRhythm rhythm);

// For logs.  Never nil.
extern NSString *GetNameForDanceRhythm(DanceRhythm rhythm);

// Whether measuring this track would tell the app anything it would then read.
//
// The measurement is not free -- it rides a decode, and the decode is the cost
// -- so it is worth doing only while one of the two answers it produces is
// still open.  They are open separately, and they are read by different parts
// of the app, so they are asked separately:
//
//   The BPM half is open when the column is showing and no tag has filled it.
//   `displaysBPM` is the preference behind that column, and it governs this
//   half and only this half: with the column hidden there is nowhere for a
//   measured tempo to appear, so measuring for it is work nothing reads.
//
//   The rhythm half is open when there is no genre tag, and *any* non-empty
//   genre closes it, because one naming no dance is a DJ saying this is a
//   cortina -- GetDanceRhythm's rule above, read from the other end.  This
//   half does not consult `displaysBPM`, because what reads it is the effects
//   switching, which goes on working whatever the track list is showing.  An
//   untagged track is measured with the column hidden for that reason alone.
//
// So a hidden column stops a genre-tagged track being measured and does not
// stop an untagged one.  Both halves come out of the one decode, so whichever
// opened it, both answers are kept -- showing the column again then costs
// nothing for a track already measured for its rhythm.
//
// `detectedRhythm` is what a previous scan reported, and any non-nil value
// closes both halves.  The worker reports a rhythm whatever it found -- the
// string "Unknown" where it found nothing -- so this is "has been measured",
// not "was measured successfully", and a track that cannot be measured is not
// decoded again on every launch.
extern BOOL GetWantsTempoMeasurement(
    BOOL       displaysBPM,
    NSString  *detectedRhythm,
    NSInteger  taggedBPM,
    NSString  *taggedGenre
);

#ifdef __cplusplus
}
#endif
