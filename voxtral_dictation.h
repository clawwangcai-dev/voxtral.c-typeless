/*
 * voxtral_dictation.h - Pure rules for API-mode dictation
 *
 * No I/O and no platform code, so these rules can be unit tested anywhere.
 */

#ifndef VOXTRAL_DICTATION_H
#define VOXTRAL_DICTATION_H

/* One call per 10 ms frame. */
#define VOX_GATE_PREROLL 30 /* frames re-sent when speech resumes (300 ms) */

typedef struct {
  float floor; /* noise floor estimate; 0 = no estimate yet */
  int hang;    /* frames still uploaded after speech ends */
  int silence; /* consecutive non-speech frames while open */
  int open;    /* 1 while uploading */
  int skipped; /* frames dropped since the gate closed, capped at VOX_GATE_PREROLL */
} vox_gate_t;

/* Hang time in frames for a delay setting: 250 for "high"/"xhigh", else 150. */
int vox_gate_hang_frames(const char *delay);
void vox_gate_init(vox_gate_t *g, int hang_frames);
/* 0 = drop this frame. n >= 1 = upload the n most recent frames, this one last. */
int vox_gate_push(vox_gate_t *g, float rms);
/* Root mean square of n samples in [-1, 1]. */
float vox_frame_rms(const float *samples, int n);

#endif /* VOXTRAL_DICTATION_H */
