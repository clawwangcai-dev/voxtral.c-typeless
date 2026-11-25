/*
 * voxtral_dictation.h - Pure rules for API-mode dictation
 *
 * No I/O and no platform code, so these rules can be unit tested anywhere.
 */

#ifndef VOXTRAL_DICTATION_H
#define VOXTRAL_DICTATION_H

#include <stddef.h>

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

/*
 * Text assembly. Typed text is never taken back, so these functions only
 * return text to append. A space is added between Chinese and Latin text
 * (letters and digits) when the model did not write one.
 */
typedef struct {
  char item[64];    /* item_id the raw text belongs to */
  char *raw;        /* deltas received for `item`, concatenated */
  size_t raw_len;
  unsigned last_cp; /* last code point typed in this dictation; 0 = nothing yet */
} vox_text_t;

void vox_text_init(vox_text_t *t);
void vox_text_free(vox_text_t *t);
/* Both return malloc'd UTF-8 to type (caller frees), or NULL when there is nothing to type. */
char *vox_text_delta(vox_text_t *t, const char *item_id, const char *delta);
char *vox_text_final(vox_text_t *t, const char *item_id, const char *transcript);

/* Settings from ~/.config/voxtral/config. */
typedef struct {
  char backend[8];     /* "local" | "openai" */
  char languages[128]; /* "zh,en,de"; "" = unset */
  char delay[8];       /* minimal | low | medium | high | xhigh */
  char keywords[1024]; /* "a,b,c"; "" = none */
  int max_minutes;     /* 1..55 */
} vox_config_t;

/* Fills the defaults, then applies `text` (the file's contents; NULL = no file).
 * Returns 0, or -1 with a short reason in `err`. */
int vox_config_parse(const char *text, vox_config_t *cfg, char *err, size_t err_len);

#endif /* VOXTRAL_DICTATION_H */
