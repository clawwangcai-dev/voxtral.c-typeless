#include "voxtral_dictation.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c) \
  do { if (!(c)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

static void test_gate_noise_stays_closed(void) {
  vox_gate_t g; vox_gate_init(&g, 150);
  for (int i = 0; i < 1000; i++) CHECK(vox_gate_push(&g, 0.0078f) == 0);
}
static void test_gate_zero_frames_do_not_stick(void) { /* samples/jfk.wav starts with all-zero frames */
  vox_gate_t g; vox_gate_init(&g, 150);
  for (int i = 0; i < 4; i++) CHECK(vox_gate_push(&g, 0.0f) == 0);
  for (int i = 0; i < 300; i++) CHECK(vox_gate_push(&g, 0.008f) == 0);
  CHECK(vox_gate_push(&g, 0.0f) == 0);
  for (int i = 0; i < 300; i++) CHECK(vox_gate_push(&g, 0.008f) == 0);
  CHECK(vox_gate_push(&g, 0.05f) == 31);
}
static void test_gate_preroll_and_hang(void) {
  vox_gate_t g; vox_gate_init(&g, 150);
  for (int i = 0; i < 10; i++) CHECK(vox_gate_push(&g, 0.008f) == 0);
  CHECK(vox_gate_push(&g, 0.05f) == 11);  /* 10 dropped frames + this one */
  CHECK(vox_gate_push(&g, 0.05f) == 1);
  for (int i = 0; i < 150; i++) CHECK(vox_gate_push(&g, 0.008f) == 1); /* 1.5 s tail */
  CHECK(vox_gate_push(&g, 0.008f) == 0);  /* frame 151 closes it */
  for (int i = 0; i < 99; i++) CHECK(vox_gate_push(&g, 0.008f) == 0);
  CHECK(vox_gate_push(&g, 0.05f) == 31);  /* 100 dropped, capped at 30 */
}
static void test_gate_resume_inside_tail(void) {
  vox_gate_t g; vox_gate_init(&g, 150);
  vox_gate_push(&g, 0.008f);
  CHECK(vox_gate_push(&g, 0.05f) == 2);
  for (int i = 0; i < 100; i++) CHECK(vox_gate_push(&g, 0.008f) == 1);
  CHECK(vox_gate_push(&g, 0.05f) == 1);   /* no gap, so no pre-roll */
  for (int i = 0; i < 150; i++) CHECK(vox_gate_push(&g, 0.008f) == 1); /* tail restarts */
  CHECK(vox_gate_push(&g, 0.008f) == 0);
}
static void test_gate_long_tail_for_high_delay(void) {
  CHECK(vox_gate_hang_frames("minimal") == 150);
  CHECK(vox_gate_hang_frames("low") == 150);
  CHECK(vox_gate_hang_frames("medium") == 150);
  CHECK(vox_gate_hang_frames("high") == 250);
  CHECK(vox_gate_hang_frames("xhigh") == 250);
  vox_gate_t g; vox_gate_init(&g, 250);
  vox_gate_push(&g, 0.008f); vox_gate_push(&g, 0.05f);
  for (int i = 0; i < 250; i++) CHECK(vox_gate_push(&g, 0.008f) == 1);
  CHECK(vox_gate_push(&g, 0.008f) == 0);
}
static void test_gate_speaking_when_it_starts(void) { /* the first frames are loud, so the floor is unknown */
  vox_gate_t g; vox_gate_init(&g, 150);
  for (int i = 0; i < 20; i++) CHECK(vox_gate_push(&g, 0.05f) == 0); /* no floor yet */
  CHECK(vox_gate_push(&g, 0.008f) == 0);  /* first dip reveals the floor */
  CHECK(vox_gate_push(&g, 0.05f) == 22);  /* the 21 earlier frames are recovered */
}
static void test_gate_noise_step_recovers(void) { /* a fan turns on */
  vox_gate_t g; vox_gate_init(&g, 150);
  for (int i = 0; i < 100; i++) vox_gate_push(&g, 0.005f);
  int sent = 0;
  for (int i = 0; i < 1500; i++) sent += vox_gate_push(&g, 0.02f) > 0;
  CHECK(sent > 0 && sent < 900); /* ~6.9 s for the floor to catch up + 1.5 s tail */
  for (int i = 0; i < 500; i++) CHECK(vox_gate_push(&g, 0.02f) == 0);
}
static void test_gate_quiet_speech_is_missed(void) { /* documented trade-off */
  vox_gate_t g; vox_gate_init(&g, 150);
  for (int i = 0; i < 100; i++) vox_gate_push(&g, 0.008f);
  for (int i = 0; i < 100; i++) CHECK(vox_gate_push(&g, 0.012f) == 0);
}
static void test_frame_rms(void) {
  float s[4] = {0.5f, -0.5f, 0.5f, -0.5f};
  CHECK(fabsf(vox_frame_rms(s, 4) - 0.5f) < 1e-6f);
}

static void feed(vox_text_t *t, char *out, const char *delta) {
  char *s = vox_text_delta(t, "item_1", delta);
  if (s) { strcat(out, s); free(s); }
}
static void test_text_spacing(void) {
  struct { const char *deltas[3]; const char *typed; } cases[] = {
    {{"一个", "PR", "解决"}, "一个 PR 解决"},   /* both directions, across deltas */
    {{"一个", " PR", "解决"}, "一个 PR 解决"},  /* model already spaced one side */
    {{"新建一个PR解决"}, "新建一个 PR 解决"},    /* inside one delta */
    {{"的", "position"}, "的 position"},
    {{"Maß", "的"}, "Maß 的"},                 /* U+00C0..U+024F are Latin letters */
    {{"第", "3", "个"}, "第 3 个"},            /* digits too */
    {{"issue", "，问题"}, "issue，问题"},       /* no space next to CJK punctuation */
    {{" PR", "解决"}, "PR 解决"},              /* leading blank of a dictation is dropped */
    {{"ok ", "好"}, "ok 好"},                  /* an existing space is not doubled */
    {{"🙂", "好"}, "🙂好"},                    /* 4-byte characters pass through */
    {{"\xff\xfe", "好"}, "\xff\xfe好"},        /* malformed UTF-8 passes through */
  };
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    vox_text_t t; char out[128] = "";
    vox_text_init(&t);
    for (int j = 0; j < 3 && cases[i].deltas[j]; j++) feed(&t, out, cases[i].deltas[j]);
    CHECK(strcmp(out, cases[i].typed) == 0);
    vox_text_free(&t);
  }
}
static char *final_after(const char *delta, const char *transcript) {
  vox_text_t t; char out[128] = "";
  vox_text_init(&t);
  if (delta) feed(&t, out, delta);
  char *s = vox_text_final(&t, "item_1", transcript);
  vox_text_free(&t);
  return s;
}
static void test_text_final(void) {
  char *s;
  s = final_after("新建", "新建一个");      CHECK(s && !strcmp(s, "一个")); free(s); /* extra suffix is typed */
  s = final_after("一个", "一个PR");        CHECK(s && !strcmp(s, " PR")); free(s);  /* and gets spacing */
  s = final_after(NULL, "你好");            CHECK(s && !strcmp(s, "你好")); free(s);  /* no deltas at all */
  CHECK(final_after("新建一个 ", "新建一个") == NULL); /* only whitespace differs */
  CHECK(final_after("Marios在", "Marius在") == NULL);  /* mismatch: keep what was typed */
  CHECK(final_after("好", "") == NULL);
}
static void test_text_new_item(void) {
  vox_text_t t; char out[128] = ""; char *s;
  vox_text_init(&t);
  feed(&t, out, "你好");
  s = vox_text_delta(&t, "item_2", "Hello");        CHECK(s && !strcmp(s, " Hello")); free(s);
  s = vox_text_final(&t, "item_2", "Hello world");  CHECK(s && !strcmp(s, " world")); free(s);
  vox_text_free(&t);
}

int main(void) {
  test_gate_noise_stays_closed();
  test_gate_zero_frames_do_not_stick();
  test_gate_preroll_and_hang();
  test_gate_resume_inside_tail();
  test_gate_long_tail_for_high_delay();
  test_gate_speaking_when_it_starts();
  test_gate_noise_step_recovers();
  test_gate_quiet_speech_is_missed();
  test_frame_rms();
  test_text_spacing();
  test_text_final();
  test_text_new_item();
  if (failures) { printf("test_dictation: %d failed\n", failures); return 1; }
  printf("test_dictation: all passed\n");
  return 0;
}
