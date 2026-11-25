/*
 * voxtral_dictation.c - Pure rules for API-mode dictation
 */

#include "voxtral_dictation.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
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

/* ---- Text assembly ---- */

#define CP_OTHER 0xFFFDu /* stands for a byte that is not valid UTF-8 */

/* Decode one code point at s (n > 0 bytes left). Returns its byte length.
 * An invalid byte decodes as CP_OTHER with length 1. */
static size_t decode_cp(const unsigned char *s, size_t n, unsigned *cp) {
  size_t len = s[0] < 0x80 ? 1 : (s[0] & 0xE0) == 0xC0 ? 2 : (s[0] & 0xF0) == 0xE0 ? 3
             : (s[0] & 0xF8) == 0xF0 ? 4 : 0;
  static const unsigned min_cp[5] = {0, 0, 0x80, 0x800, 0x10000};
  if (len == 0 || len > n) goto invalid;
  unsigned c = len == 1 ? s[0] : s[0] & (0xFFu >> (len + 1));
  for (size_t i = 1; i < len; i++) {
    if ((s[i] & 0xC0) != 0x80) goto invalid;
    c = c << 6 | (s[i] & 0x3F);
  }
  if (len > 1 && (c < min_cp[len] || c > 0x10FFFF)) goto invalid;
  *cp = c;
  return len;
invalid:
  *cp = CP_OTHER;
  return 1;
}

static int is_cjk(unsigned cp) {
  return (cp >= 0x3400 && cp <= 0x4DBF) || (cp >= 0x4E00 && cp <= 0x9FFF);
}

static int is_latin(unsigned cp) {
  return (cp < 0x80 && ((cp >= '0' && cp <= '9') || ((cp | 0x20) >= 'a' && (cp | 0x20) <= 'z')))
      || (cp >= 0xC0 && cp <= 0x24F && cp != 0xD7 && cp != 0xF7);
}

static int is_blank(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

/* Copy s[0..n) with spaces added between Chinese and Latin text, continuing
 * from t->last_cp, and update t->last_cp. Blanks at the very start of a
 * dictation are dropped. Returns NULL when nothing is left to type. */
static char *spaced(vox_text_t *t, const char *s, size_t n) {
  char *out = malloc(2 * n + 1); /* at most one added space per input byte */
  if (!out) return NULL;
  size_t len = 0, i = 0;
  unsigned last = t->last_cp;
  while (i < n) {
    unsigned cp;
    size_t cl = decode_cp((const unsigned char *)s + i, n - i, &cp);
    if (last == 0 && cl == 1 && is_blank(s[i])) { i++; continue; }
    if ((is_cjk(last) && is_latin(cp)) || (is_latin(last) && is_cjk(cp))) out[len++] = ' ';
    memcpy(out + len, s + i, cl);
    len += cl;
    i += cl;
    last = cp;
  }
  if (len == 0) { free(out); return NULL; }
  out[len] = '\0';
  t->last_cp = last;
  return out;
}

void vox_text_init(vox_text_t *t) { memset(t, 0, sizeof(*t)); }

void vox_text_free(vox_text_t *t) {
  free(t->raw);
  t->raw = NULL;
  t->raw_len = 0;
}

/* Start a new item when item_id differs. last_cp is kept so spacing carries over. */
static void select_item(vox_text_t *t, const char *item_id) {
  if (strncmp(t->item, item_id, sizeof(t->item) - 1) == 0) return;
  snprintf(t->item, sizeof(t->item), "%s", item_id);
  vox_text_free(t);
}

/* Replace t->raw with s[0..n). Returns 0 on success, -1 when out of memory. */
static int set_raw(vox_text_t *t, const char *s, size_t n) {
  char *p = realloc(t->raw, n + 1);
  if (!p) return -1;
  memcpy(p, s, n);
  p[n] = '\0';
  t->raw = p;
  t->raw_len = n;
  return 0;
}

char *vox_text_delta(vox_text_t *t, const char *item_id, const char *delta) {
  if (!delta) delta = "";
  select_item(t, item_id);
  size_t n = strlen(delta);
  char *p = realloc(t->raw, t->raw_len + n + 1);
  if (!p) return NULL;
  memcpy(p + t->raw_len, delta, n + 1);
  t->raw = p;
  t->raw_len += n;
  return spaced(t, delta, n);
}

/* Drop leading and trailing ASCII whitespace from s[0..*n). */
static const char *trim(const char *s, size_t *n) {
  while (*n > 0 && is_blank(*s)) { s++; (*n)--; }
  while (*n > 0 && is_blank(s[*n - 1])) (*n)--;
  return s;
}

char *vox_text_final(vox_text_t *t, const char *item_id, const char *transcript) {
  if (!transcript) transcript = "";
  select_item(t, item_id);
  size_t raw_n = t->raw_len, full_n = strlen(transcript);
  const char *raw = trim(t->raw ? t->raw : "", &raw_n);
  const char *full = trim(transcript, &full_n);
  /* Only a longer transcript that starts with what was typed adds text. */
  if (full_n <= raw_n || memcmp(full, raw, raw_n) != 0) return NULL;
  if (set_raw(t, full, full_n) != 0) return NULL;
  return spaced(t, full + raw_n, full_n - raw_n);
}
