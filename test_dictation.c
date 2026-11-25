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
static void test_gate_speaking_when_it_starts(void) { /* Review Focus 1 */
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
  if (failures) { printf("test_dictation: %d failed\n", failures); return 1; }
  printf("test_dictation: all passed\n");
  return 0;
}
