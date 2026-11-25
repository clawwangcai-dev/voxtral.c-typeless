/*
 * test_openai.m - Tests for the OpenAI realtime transcription session
 *
 * A and B run offline. C, D and E talk to the real OpenAI endpoint and need
 * a key in $HOME/.config/voxtral/openai_key (or OPENAI_API_KEY); without one
 * they are skipped. D uploads about 11 s of audio (roughly 0.003 USD).
 * Text from the server is checked but never printed.
 */

#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "voxtral_audio.h"
#include "voxtral_openai.h"

static int failures;
#define CHECK(c)                                                               \
  do {                                                                         \
    if (!(c)) {                                                                \
      printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                      \
      failures++;                                                              \
    }                                                                          \
  } while (0)

/* Spins the main run loop (where onText and onDone run) until cond() holds or
 * `seconds` pass. Returns whether cond() held. */
static BOOL wait_until(BOOL (^cond)(void), double seconds) {
  NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!cond()) {
    if ([limit timeIntervalSinceNow] <= 0)
      return NO;
    [[NSRunLoop mainRunLoop]
           runMode:NSDefaultRunLoopMode
        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  }
  return YES;
}

/* A 16 kHz WAV, linearly interpolated to 24 kHz. */
static float *load_24k(const char *path, int *n_out) {
  int n16 = 0;
  float *s16 = vox_load_wav(path, &n16);
  if (!s16 || n16 < 2) {
    free(s16);
    return NULL;
  }
  int n = (int)((long)(n16 - 1) * 3 / 2) + 1;
  float *s = malloc((size_t)n * sizeof(float));
  for (int i = 0; i < n; i++) {
    double pos = i * 2.0 / 3.0;
    int j = (int)pos;
    double f = pos - j;
    s[i] = j + 1 < n16 ? (float)(s16[j] * (1 - f) + s16[j + 1] * f) : s16[j];
  }
  free(s16);
  *n_out = n;
  return s;
}

/* Lowercase, letters and spaces only, runs of spaces collapsed. */
static NSString *normalize(NSString *text) {
  NSMutableString *out = [NSMutableString string];
  NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
  BOOL space = YES;
  NSString *lower = text.lowercaseString;
  for (NSUInteger i = 0; i < lower.length; i++) {
    unichar c = [lower characterAtIndex:i];
    if ([letters characterIsMember:c]) {
      [out appendFormat:@"%C", c];
      space = NO;
    } else if (!space) {
      [out appendString:@" "];
      space = YES;
    }
  }
  return out;
}

static void write_file(NSString *path, const char *text, mode_t mode) {
  [[NSData dataWithBytes:text length:strlen(text)] writeToFile:path
                                                    atomically:NO];
  chmod(path.fileSystemRepresentation, mode);
}

/* Callback results of one session. */
@interface Recorder : NSObject
@property int textCount;
@property int doneCount;
@property VoxOpenAIStatus status;
@property double startedAt;
@property double firstTextAt;
@property double finishAt; /* 0 = finish not called */
@property double doneAt;
@property(strong) NSMutableString *allText;
@end
@implementation Recorder
- (instancetype)init {
  if ((self = [super init]))
    _allText = [NSMutableString string];
  return self;
}
@end

static const char *status_name(VoxOpenAIStatus status) {
  switch (status) {
  case VoxOpenAIStatusOK: return "OK";
  case VoxOpenAIStatusTailUnconfirmed: return "TailUnconfirmed";
  case VoxOpenAIStatusNetwork: return "Network";
  case VoxOpenAIStatusKey: return "Key";
  case VoxOpenAIStatusRejected: return "Rejected";
  case VoxOpenAIStatusSlow: return "Slow";
  }
  return "?";
}

/* Printed only when a scenario failed. The text is the transcript of our own
 * sample audio; server error text never reaches the test. */
static void explain(const char *name, Recorder *r, VoxOpenAISession *s) {
  double from = r.finishAt > 0 ? r.finishAt : r.startedAt;
  const char *since = r.finishAt > 0 ? "finish" : "start";
  if (r.doneCount > 0)
    printf("  %s: status %s, doneCount %d, ended %.2f s after %s\n", name,
           status_name(r.status), r.doneCount, r.doneAt - from, since);
  else
    printf("  %s: never ended (%.2f s after %s), doneCount 0\n", name,
           CFAbsoluteTimeGetCurrent() - from, since);
  if (r.textCount > 0)
    printf("  %s: first text %.2f s after start\n", name,
           r.firstTextAt - r.startedAt);
  printf("  %s: %d text callbacks: \"%s\"\n", name, r.textCount,
         normalize(r.allText).UTF8String);
  printf("  %s: uploaded %.2f s of %.2f s captured\n", name, s.uploadedSeconds,
         s.capturedSeconds);
}

static VoxOpenAISession *start(Recorder *r, NSString *key,
                               NSString *languages, NSString *keywords,
                               NSURL *endpoint) {
  r.startedAt = CFAbsoluteTimeGetCurrent();
  return [[VoxOpenAISession alloc] initWithKey:key
      languages:languages
      delay:@"low"
      keywords:keywords
      endpoint:endpoint
      onText:^(NSString *text) {
        if (r.textCount == 0)
          r.firstTextAt = CFAbsoluteTimeGetCurrent();
        r.textCount++;
        [r.allText appendString:text];
      }
      onDone:^(VoxOpenAIStatus status) {
        if (r.doneCount == 0)
          r.doneAt = CFAbsoluteTimeGetCurrent();
        r.doneCount++;
        r.status = status;
      }];
}

/* The key comes from OPENAI_API_KEY, else from a file that only its owner
 * can read. */
static void test_key(NSString *dir) {
  int before = failures;
  const char *saved = getenv("OPENAI_API_KEY");
  char *saved_copy = saved ? strdup(saved) : NULL;
  unsetenv("OPENAI_API_KEY");

  NSString *why = nil;
  NSString *k600 = [dir stringByAppendingPathComponent:@"k600"];
  NSString *k644 = [dir stringByAppendingPathComponent:@"k644"];
  NSString *empty = [dir stringByAppendingPathComponent:@"empty"];
  NSString *missing = [dir stringByAppendingPathComponent:@"missing"];
  write_file(k600, "sk-test\n", 0600);
  write_file(k644, "sk-test\n", 0644);
  write_file(empty, "", 0600);

  CHECK([VoxOpenAILoadKey(k600, &why) isEqualToString:@"sk-test"]);
  why = nil;
  CHECK(VoxOpenAILoadKey(k644, &why) == nil && [why containsString:@"600"]);
  why = nil;
  CHECK(VoxOpenAILoadKey(empty, &why) == nil && why.length > 0);
  why = nil;
  CHECK(VoxOpenAILoadKey(missing, &why) == nil && why.length > 0);
  setenv("OPENAI_API_KEY", "sk-env", 1);
  CHECK([VoxOpenAILoadKey(k644, &why) isEqualToString:@"sk-env"]);

  if (saved_copy)
    setenv("OPENAI_API_KEY", saved_copy, 1);
  else
    unsetenv("OPENAI_API_KEY");
  free(saved_copy);
  if (failures == before)
    printf("ok A\n");
}

/* Nothing listens on the endpoint: exactly one onDone with Network. */
static void test_dead_endpoint(void) {
  int before = failures;
  Recorder *r = [Recorder new];
  VoxOpenAISession *s =
      start(r, @"sk-x", @"", @"", [NSURL URLWithString:@"wss://127.0.0.1:9/"]);
  CHECK(wait_until(^{ return (BOOL)(r.doneCount == 1); }, 10));
  CHECK(r.status == VoxOpenAIStatusNetwork && r.textCount == 0);
  [s finish];
  wait_until(^{ return NO; }, 0.5);
  CHECK(r.doneCount == 1);
  if (failures == before)
    printf("ok B\n");
  else
    explain("B", r, s);
}

/* The real endpoint refuses a made-up key; no audio is sent. */
static void test_invalid_key(void) {
  int before = failures;
  Recorder *r = [Recorder new];
  VoxOpenAISession *s = start(r, @"sk-invalid", @"", @"", nil);
  CHECK(wait_until(^{ return (BOOL)(r.doneCount == 1); }, 10) &&
        r.status == VoxOpenAIStatusKey && r.textCount == 0);
  (void)s;
  if (failures == before)
    printf("ok C\n");
  else
    explain("C", r, s);
}

/* Occurrences of `phrase` in `text`, not overlapping. */
static int count_of(NSString *text, NSString *phrase) {
  int count = 0;
  NSRange from = NSMakeRange(0, text.length);
  for (;;) {
    NSRange r = [text rangeOfString:phrase options:0 range:from];
    if (r.location == NSNotFound)
      return count;
    count++;
    from.location = NSMaxRange(r);
    from.length = text.length - from.location;
  }
}

/* A real speech in real time: text arrives while audio is still being
 * uploaded, and the final transcript arrives after finish. Two languages and
 * a keyword make the server check every field of session.update; a phrase
 * typed twice would show up as a second occurrence. */
static void test_speech(NSString *key) {
  int before = failures;
  int n = 0;
  float *audio = load_24k("samples/jfk.wav", &n);
  CHECK(audio != NULL);
  if (!audio)
    return;
  Recorder *r = [Recorder new];
  VoxOpenAISession *s = start(r, key, @"en,de", @"country", nil);
  for (int i = 0; i < n; i += 2400) {
    [s feed:audio + i count:(n - i < 2400 ? n - i : 2400)];
    wait_until(^{ return NO; }, 0.1);
  }
  r.finishAt = CFAbsoluteTimeGetCurrent();
  [s finish];
  free(audio);
  CHECK(r.firstTextAt > 0 && r.firstTextAt < r.finishAt);
  CHECK(wait_until(^{ return (BOOL)(r.doneCount == 1); }, 10) &&
        r.status == VoxOpenAIStatusOK);
  CHECK(count_of(normalize(r.allText),
                 @"ask not what your country can do for you") == 1);
  /* Everything fed was accepted; the speech is never silent long enough to
   * pause the upload. */
  CHECK(fabs(s.capturedSeconds - n / 24000.0) < 0.001);
  CHECK(s.uploadedSeconds > 5 && s.uploadedSeconds <= s.capturedSeconds);
  if (failures == before)
    printf("ok D\n");
  else
    explain("D", r, s);
}

/* One second of digital silence, then finish: nothing was said. */
static void test_silence(NSString *key) {
  int before = failures;
  float *zeros = calloc(24000, sizeof(float));
  Recorder *r = [Recorder new];
  VoxOpenAISession *s = start(r, key, @"", @"", nil);
  [s feed:zeros count:24000];
  r.finishAt = CFAbsoluteTimeGetCurrent();
  [s finish];
  free(zeros);
  CHECK(wait_until(^{ return (BOOL)(r.doneCount == 1); }, 2) &&
        r.status == VoxOpenAIStatusOK && r.textCount == 0);
  CHECK(s.capturedSeconds == 1.0 && s.uploadedSeconds == 0);
  if (failures == before)
    printf("ok E\n");
  else
    explain("E", r, s);
}

int main(void) {
  @autoreleasepool {
    NSString *dir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    test_key(dir);
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    test_dead_endpoint();

    NSString *path = [NSHomeDirectory()
        stringByAppendingPathComponent:@".config/voxtral/openai_key"];
    NSString *key = VoxOpenAILoadKey(path, NULL);
    if (key) {
      test_invalid_key();
      test_speech(key);
      test_silence(key);
    } else {
      printf("SKIP C D E: no API key\n");
    }

    if (failures) {
      printf("test_openai: %d failed\n", failures);
      return 1;
    }
    printf("test_openai: all passed\n");
  }
  return 0;
}
