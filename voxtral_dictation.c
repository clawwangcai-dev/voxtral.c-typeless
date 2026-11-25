/*
 * voxtral_dictation.c - Pure rules for API-mode dictation
 */

#include "voxtral_dictation.h"

#include <math.h>
#include <string.h>

#define FLOOR_MIN 0.001f  /* frames below this are digital silence */
#define FLOOR_RISE 1.001f /* per frame, about 0.9 dB per second */
#define SPEECH_RATIO 2.0f

int vox_gate_hang_frames(const char *delay) {
  if (strcmp(delay, "high") == 0 || strcmp(delay, "xhigh") == 0) return 250;
  return 150;
}

void vox_gate_init(vox_gate_t *g, int hang_frames) {
  memset(g, 0, sizeof(*g));
  g->hang = hang_frames;
}

int vox_gate_push(vox_gate_t *g, float rms) {
  if (rms >= FLOOR_MIN)
    g->floor = (g->floor == 0 || rms < g->floor) ? rms : g->floor * FLOOR_RISE;
  float floor = g->floor > 0 ? g->floor : FLOOR_MIN;
  if (rms > floor * SPEECH_RATIO) {
    int n = 1;
    if (!g->open) { n += g->skipped; g->open = 1; g->skipped = 0; }
    g->silence = 0;
    return n;
  }
  if (g->open && ++g->silence <= g->hang) return 1;
  g->open = 0;
  if (g->skipped < VOX_GATE_PREROLL) g->skipped++;
  return 0;
}

float vox_frame_rms(const float *samples, int n) {
  double sum = 0;
  for (int i = 0; i < n; i++) sum += (double)samples[i] * samples[i];
  return (float)sqrt(sum / n);
}
