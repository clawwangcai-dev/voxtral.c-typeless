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
  if (!item_id) item_id = "";
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
  const char *suffix = full + raw_n;
  size_t suffix_n = full_n - raw_n;
  /* A blank already typed at the end must not be doubled by the suffix. */
  if (t->last_cp < 0x80 && is_blank((char)t->last_cp))
    while (suffix_n > 0 && is_blank(*suffix)) { suffix++; suffix_n--; }
  return spaced(t, suffix, suffix_n);
}

/* ---- Config file parsing ---- */

static int is_space(char c) { return c == ' ' || c == '\t' || c == '\r'; }

/* Same as trim() but also drops '\r', so CRLF files parse like LF files. */
static const char *trim_line(const char *s, size_t *n) {
  while (*n > 0 && is_space(*s)) { s++; (*n)--; }
  while (*n > 0 && is_space(s[*n - 1])) (*n)--;
  return s;
}

/* Cut s before a UTF-8 character that its end leaves incomplete. */
static void cut_partial_char(char *s) {
  size_t n = strlen(s), lead = n;
  while (lead > 0 && ((unsigned char)s[lead - 1] & 0xC0) == 0x80) lead--;
  if (lead == 0) return;
  lead--; /* the byte that starts the last character */
  unsigned char c = (unsigned char)s[lead];
  size_t want = (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 ? 4 : 1;
  if (n - lead < want) s[lead] = '\0';
}

/* A long name is cut to fit err, on a character boundary. */
static int config_fail(char *err, size_t err_len, const char *head, const char *name, size_t name_n,
                       const char *tail) {
  if (err_len == 0) return -1;
  int len = snprintf(err, err_len, "%s%.*s%s", head, (int)name_n, name, tail);
  if (len >= 0 && (size_t)len >= err_len) cut_partial_char(err);
  return -1;
}

/* Comma separated language codes of ASCII letters, digits and '-' only (e.g. "zh-CN,en"). */
static int is_language_list(const char *s) {
  for (; *s; s++)
    if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') || (*s >= '0' && *s <= '9') ||
          *s == '-' || *s == ','))
      return 0;
  return 1;
}

/*
 * Copy a comma separated list into dst (size cap) with each item trimmed and
 * empty items dropped. Returns 0, or -1 when the result does not fit.
 * An empty result leaves dst "".
 */
static int copy_list(char *dst, size_t cap, const char *s, size_t n) {
  size_t out = 0;
  const char *end = s + n;
  while (s <= end) {
    const char *comma = memchr(s, ',', (size_t)(end - s));
    size_t item_n = (size_t)((comma ? comma : end) - s);
    const char *item = trim_line(s, &item_n);
    if (item_n > 0) {
      size_t need = item_n + (out > 0 ? 1 : 0);
      if (out + need >= cap) return -1;
      if (out > 0) dst[out++] = ',';
      memcpy(dst + out, item, item_n);
      out += item_n;
    }
    if (!comma) break;
    s = comma + 1;
  }
  dst[out] = '\0';
  return 0;
}

/* Set dst (size cap) to one of the `allowed` words (NULL-terminated), or fail. */
static int copy_word(char *dst, size_t cap, const char *s, size_t n, const char *const *allowed,
                     const char **why) {
  if (n >= cap) { *why = " 的值太长"; return -1; }
  for (; *allowed; allowed++)
    if (strlen(*allowed) == n && memcmp(*allowed, s, n) == 0) {
      memcpy(dst, s, n);
      dst[n] = '\0';
      return 0;
    }
  *why = " 的值无效";
  return -1;
}

/* Apply one `name = value` pair (value non-empty). Returns 0, or -1 with *why set. */
static int config_apply(vox_config_t *cfg, const char *name, size_t name_n, const char *v, size_t n,
                        const char **why) {
  static const char *const backends[] = {"local", "openai", NULL};
  static const char *const delays[] = {"minimal", "low", "medium", "high", "xhigh", NULL};
#define IS(key) (name_n == strlen(key) && memcmp(name, key, name_n) == 0)
  if (!IS("backend") && !IS("delay") && !IS("max_minutes") && !IS("languages") && !IS("keywords")) {
    *why = NULL; /* unknown name */
    return -1;
  }
  if (n == 0) return 0; /* an empty value means "not written" */
  *why = " 的值无效";
  if (IS("backend")) return copy_word(cfg->backend, sizeof cfg->backend, v, n, backends, why);
  if (IS("delay")) return copy_word(cfg->delay, sizeof cfg->delay, v, n, delays, why);
  if (IS("max_minutes")) {
    int minutes = 0;
    for (size_t i = 0; i < n; i++) {
      if (v[i] < '0' || v[i] > '9') return -1;
      minutes = minutes * 10 + (v[i] - '0');
      if (minutes > 55) return -1;
    }
    if (minutes < 1) return -1;
    cfg->max_minutes = minutes;
    return 0;
  }
  { /* languages or keywords */
    int is_keywords = IS("keywords");
    char tmp[sizeof cfg->keywords];
    char *dst = is_keywords ? cfg->keywords : cfg->languages;
    size_t cap = is_keywords ? sizeof cfg->keywords : sizeof cfg->languages;
    if (copy_list(tmp, cap, v, n) != 0) { *why = " 的值太长"; return -1; }
    if (is_keywords && (strchr(tmp, '<') || strchr(tmp, '>'))) return -1;
    if (!is_keywords && !is_language_list(tmp)) return -1; /* a typo, or a fullwidth comma */
    if (tmp[0]) memcpy(dst, tmp, strlen(tmp) + 1); /* a list of only commas is also "not written" */
    return 0;
  }
}

int vox_config_parse(const char *text, vox_config_t *cfg, char *err, size_t err_len) {
  if (err_len > 0) err[0] = '\0';
  memset(cfg, 0, sizeof(*cfg));
  snprintf(cfg->backend, sizeof cfg->backend, "local");
  snprintf(cfg->delay, sizeof cfg->delay, "low");
  cfg->max_minutes = 10;
  if (!text) return 0;
  if (strncmp(text, "\xef\xbb\xbf", 3) == 0) text += 3;

  for (int line_no = 1; *text; line_no++) {
    const char *eol = strchr(text, '\n');
    size_t n = eol ? (size_t)(eol - text) : strlen(text);
    const char *line = text;
    text += n + (eol ? 1 : 0);

    const char *hash = memchr(line, '#', n);
    if (hash) n = (size_t)(hash - line);
    line = trim_line(line, &n);
    if (n == 0) continue;

    const char *eq = memchr(line, '=', n);
    if (!eq) {
      if (err_len > 0) snprintf(err, err_len, "第 %d 行缺少 =", line_no);
      return -1;
    }
    size_t name_n = (size_t)(eq - line), value_n = n - name_n - 1;
    const char *name = trim_line(line, &name_n);
    const char *value = trim_line(eq + 1, &value_n);

    const char *why;
    if (config_apply(cfg, name, name_n, value, value_n, &why) == 0) continue;
    if (!why) return config_fail(err, err_len, "不认识的配置项 ", name, name_n, "");
    return config_fail(err, err_len, "", name, name_n, why);
  }
  return 0;
}
