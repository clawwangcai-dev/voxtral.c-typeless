/*
 * voxtral_daemon.m - macOS voice dictation daemon
 *
 * Background daemon that uses voxtral.c C API for real-time speech-to-text
 * and injects transcribed text into the current active window via CGEvent.
 *
 * Usage: ./voxtral-daemon [-d <model_dir>] [-I <seconds>] [--check]
 *
 * Settings come from ~/.config/voxtral/config; "backend = openai" sends audio
 * to OpenAI instead of loading the local model.
 *
 * Controls:
 *   Option+Space  - Toggle dictation on/off
 *   Menu bar icon  - Shows status (🎤 idle, 🔴 listening)
 */

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <pthread.h>

#include "voxtral.h"
#include "voxtral_dictation.h"
#include "voxtral_mic.h"
#import "voxtral_openai.h"
#ifdef USE_METAL
#include "voxtral_metal.h"
#endif

/* ========================================================================
 * Configuration
 * ======================================================================== */

#define DAEMON_DEFAULT_INTERVAL 1.0f /* -I default for daemon (lower latency)  \
                                      */
#define MIC_WINDOW 160               /* 10ms at 16kHz */
#define SILENCE_THRESH 0.002f        /* RMS threshold (~-54 dBFS) */
#define SILENCE_PASS 60              /* pass-through windows (600ms) */
#define MIC_BUF_SIZE 4800            /* 300ms max read */
#define HOTKEY_KEYCODE 49            /* Space bar */
#define HOTKEY_MODIFIERS kCGEventFlagMaskAlternate /* Option key */

/* ========================================================================
 * Daemon State
 * ======================================================================== */

typedef enum { STATE_IDLE, STATE_LISTENING, STATE_FLUSHING } daemon_state_t;

static daemon_state_t g_state = STATE_IDLE;
static vox_ctx_t *g_ctx = NULL;
static vox_stream_t *g_stream = NULL;
static pthread_t g_audio_thread;
static volatile int g_audio_running = 0;
static float g_interval = DAEMON_DEFAULT_INTERVAL;
static BOOL g_backend_openai = NO;
static NSString *g_api_key = nil; /* set only when g_backend_openai */
static BOOL g_check_only = NO;    /* --check: report problems, never show alerts */
static CFMachPortRef g_tap = NULL;

/* Forward declarations */
static void toggle_dictation(void);
static void start_listening(void);
static void stop_listening(void);
static void inject_text(const char *text);

/* ========================================================================
 * Menu Bar UI (NSStatusItem)
 * ======================================================================== */

@interface DaemonDelegate : NSObject <NSApplicationDelegate>
@property(strong) NSStatusItem *statusItem;
@property(strong) NSMenuItem *toggleItem;
@property(strong) NSMenuItem *noticeItem;
@end

@implementation DaemonDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;

  /* Create status bar item */
  self.statusItem = [[NSStatusBar systemStatusBar]
      statusItemWithLength:NSVariableStatusItemLength];
  self.statusItem.button.title = @"🎤";
  self.statusItem.button.toolTip = @"Voxtral Dictation";

  /* Build menu */
  NSMenu *menu = [[NSMenu alloc] init];

  /* Items without an action are shown greyed out */
  NSMenuItem *modeItem = [[NSMenuItem alloc]
      initWithTitle:g_backend_openai ? @"模式：OpenAI 流式" : @"模式：本地模型"
             action:nil
      keyEquivalent:@""];
  [menu addItem:modeItem];

  self.noticeItem = [[NSMenuItem alloc] initWithTitle:@""
                                               action:nil
                                        keyEquivalent:@""];
  self.noticeItem.hidden = YES;
  [menu addItem:self.noticeItem];

  self.toggleItem =
      [[NSMenuItem alloc] initWithTitle:@"⌥Space 开始听写"
                                 action:@selector(toggleDictation:)
                          keyEquivalent:@""];
  self.toggleItem.target = self;
  [menu addItem:self.toggleItem];

  [menu addItem:[NSMenuItem separatorItem]];

  NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出 Voxtral"
                                                    action:@selector(quitApp:)
                                             keyEquivalent:@"q"];
  quitItem.target = self;
  [menu addItem:quitItem];

  self.statusItem.menu = menu;

  fprintf(stderr, "voxtral-daemon: ready (⌥Space to start dictation)\n");
}

- (void)toggleDictation:(id)sender {
  (void)sender;
  toggle_dictation();
}

- (void)quitApp:(id)sender {
  (void)sender;
  if (g_state != STATE_IDLE) {
    stop_listening();
  }
  [NSApp terminate:nil];
}

- (void)updateIcon:(NSString *)icon menuTitle:(NSString *)title {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.statusItem.button.title = icon;
    self.toggleItem.title = title;
  });
}

/* Shows a one-line notice in the menu; nil hides it. Any thread. */
- (void)showNotice:(NSString *)text {
  dispatch_async(dispatch_get_main_queue(), ^{
    self.noticeItem.hidden = (text == nil);
    if (text)
      self.noticeItem.title = text;
  });
}

@end

static DaemonDelegate *g_delegate = nil;

/* ========================================================================
 * Text Injection via CGEvent
 * ======================================================================== */

static void inject_text(const char *text) {
  if (!text || !text[0])
    return;

  CFStringRef str =
      CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
  if (!str)
    return;

  CFIndex len = CFStringGetLength(str);
  if (len == 0) {
    CFRelease(str);
    return;
  }

  UniChar *chars = (UniChar *)malloc((size_t)len * sizeof(UniChar));
  CFStringGetCharacters(str, CFRangeMake(0, len), chars);

  for (CFIndex i = 0; i < len; i++) {
    CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, 0, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, 0, false);
    CGEventKeyboardSetUnicodeString(keyDown, 1, &chars[i]);
    CGEventKeyboardSetUnicodeString(keyUp, 1, &chars[i]);
    /* Clear modifier flags so injected chars aren't affected by
     * physical modifier keys the user might be holding */
    CGEventSetFlags(keyDown, (CGEventFlags)0);
    CGEventSetFlags(keyUp, (CGEventFlags)0);
    CGEventPost(kCGHIDEventTap, keyDown);
    CGEventPost(kCGHIDEventTap, keyUp);
    CFRelease(keyDown);
    CFRelease(keyUp);
  }

  free(chars);
  CFRelease(str);
}

/* ========================================================================
 * Audio Capture Thread
 * ======================================================================== */

static void drain_and_inject(vox_stream_t *s) {
  const char *tokens[64];
  int n;
  while ((n = vox_stream_get(s, tokens, 64)) > 0) {
    for (int i = 0; i < n; i++) {
      const char *t = tokens[i];
      if (t && t[0]) {
        /* Dispatch text injection to main thread so CGEvent
         * is posted from the main run loop context */
        char *copy = strdup(t);
        dispatch_async(dispatch_get_main_queue(), ^{
          inject_text(copy);
          free(copy);
        });
      }
    }
  }
}

static void *audio_thread_func(void *arg) {
  (void)arg;
  float buf[MIC_BUF_SIZE];
  int silence_count = 0;
  int was_skipping = 0;
  int overbuf_warned = 0;

  while (g_audio_running) {
    /* Over-buffer detection (same logic as main.c) */
    int avail = vox_mic_read_available();
    if (avail > 80000) { /* > 5 seconds buffered */
      if (!overbuf_warned) {
        fprintf(stderr,
                "voxtral-daemon: warning: can't keep up, skipping audio\n");
        overbuf_warned = 1;
      }
      float discard[MIC_BUF_SIZE];
      while (vox_mic_read_available() > 16000)
        vox_mic_read(discard, MIC_BUF_SIZE);
      silence_count = 0;
      was_skipping = 0;
    } else if (avail < 32000) {
      overbuf_warned = 0;
    }

    int n = vox_mic_read(buf, MIC_BUF_SIZE);
    if (n == 0) {
      usleep(10000); /* 10ms idle */
      continue;
    }

    /* Process in 10ms windows for silence cancellation */
    int off = 0;
    while (off + MIC_WINDOW <= n) {
      float energy = 0;
      for (int i = 0; i < MIC_WINDOW; i++) {
        float v = buf[off + i];
        energy += v * v;
      }
      float rms = sqrtf(energy / MIC_WINDOW);

      if (rms > SILENCE_THRESH) {
        if (was_skipping)
          was_skipping = 0;
        vox_stream_feed(g_stream, buf + off, MIC_WINDOW);
        silence_count = 0;
      } else {
        silence_count++;
        if (silence_count <= SILENCE_PASS) {
          vox_stream_feed(g_stream, buf + off, MIC_WINDOW);
        } else if (!was_skipping) {
          was_skipping = 1;
          vox_stream_flush(g_stream);
        }
      }
      off += MIC_WINDOW;
    }

    /* Feed remaining samples (< 1 window) */
    if (off < n)
      vox_stream_feed(g_stream, buf + off, n - off);

    /* Drain tokens and inject */
    drain_and_inject(g_stream);
  }

  return NULL;
}

/* ========================================================================
 * Dictation Start / Stop
 * ======================================================================== */

static void start_listening(void) {
  if (g_state != STATE_IDLE)
    return;

  /* Create a fresh stream */
  g_stream = vox_stream_init(g_ctx);
  if (!g_stream) {
    fprintf(stderr, "voxtral-daemon: failed to init stream\n");
    return;
  }
  vox_set_processing_interval(g_stream, g_interval);
  vox_stream_set_continuous(g_stream, 1);

  /* Start microphone */
  if (vox_mic_start() != 0) {
    fprintf(stderr, "voxtral-daemon: failed to start microphone\n");
    vox_stream_free(g_stream);
    g_stream = NULL;
    return;
  }

  g_state = STATE_LISTENING;
  g_audio_running = 1;
  pthread_create(&g_audio_thread, NULL, audio_thread_func, NULL);

  /* Play start sound */
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSSound soundNamed:@"Tink"] play];
  });

  [g_delegate updateIcon:@"🔴" menuTitle:@"⌥Space 停止听写"];
  fprintf(stderr, "voxtral-daemon: listening...\n");
}

static void stop_listening(void) {
  if (g_state == STATE_IDLE)
    return;

  g_state = STATE_FLUSHING;

  /* Stop audio thread */
  g_audio_running = 0;
  pthread_join(g_audio_thread, NULL);

  /* Stop microphone */
  vox_mic_stop();

  /* Flush remaining tokens */
  if (g_stream) {
    vox_stream_finish(g_stream);
    drain_and_inject(g_stream);
    vox_stream_free(g_stream);
    g_stream = NULL;
  }

  g_state = STATE_IDLE;

  /* Play stop sound */
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSSound soundNamed:@"Pop"] play];
  });

  [g_delegate updateIcon:@"🎤" menuTitle:@"⌥Space 开始听写"];
  fprintf(stderr, "voxtral-daemon: stopped\n");
}

/* Shared by the hotkey and the menu item. Main thread. */
static void toggle_dictation(void) {
  if (g_backend_openai) {
    /* Dictation through OpenAI is added by the following change; until then
     * the hotkey is swallowed and nothing starts, so the local functions
     * below are never called without a loaded model. */
    return;
  }
  if (g_state == STATE_IDLE) {
    start_listening();
  } else {
    stop_listening();
  }
}

/* ========================================================================
 * Global Hotkey via CGEvent Tap
 * ======================================================================== */

static CGEventRef hotkey_callback(CGEventTapProxy proxy, CGEventType type,
                                  CGEventRef event, void *refcon) {
  (void)proxy;
  (void)refcon;

  /* Re-enable tap if it gets disabled by the system */
  if (type == kCGEventTapDisabledByTimeout ||
      type == kCGEventTapDisabledByUserInput) {
    CGEventTapEnable(g_tap, true);
    return event;
  }

  if (type != kCGEventKeyDown)
    return event;

  CGKeyCode keycode =
      (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
  CGEventFlags flags = CGEventGetFlags(event);

  /* Check for Option+Space */
  if (keycode == HOTKEY_KEYCODE && (flags & HOTKEY_MODIFIERS) &&
      !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                 kCGEventFlagMaskShift))) {
    /* Toggle dictation on main thread */
    dispatch_async(dispatch_get_main_queue(), ^{
      toggle_dictation();
    });
    return NULL; /* Swallow the event */
  }

  return event;
}

static int setup_hotkey_tap(void) {
  CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
  g_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                           kCGEventTapOptionDefault, mask, hotkey_callback,
                           NULL);

  if (!g_tap) {
    fprintf(stderr, "voxtral-daemon: cannot create event tap.\n"
                    "Please grant Accessibility permission:\n"
                    "  System Settings → Privacy & Security → Accessibility\n");
    return -1;
  }

  CGEventTapEnable(g_tap, true);

  CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, g_tap, 0);
  CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
  CFRelease(source);
  /* Don't release g_tap — must stay alive */

  return 0;
}

/* ========================================================================
 * Startup: configuration, validation, usage
 * ======================================================================== */

/* Reports why the daemon cannot start and exits. Started from Finder there is
 * no terminal to read stderr, so a dialog is shown as well. */
static void fatal_startup(NSString *message) {
  fprintf(stderr, "voxtral-daemon: %s\n", [message UTF8String]);
  if (!g_check_only && !isatty(STDERR_FILENO)) {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [app activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Voxtral 无法启动";
    alert.informativeText = message;
    [alert runModal];
  }
  exit(1);
}

static NSString *config_dir(void) {
  const char *home = getenv("HOME");
  NSString *base = (home && home[0]) ? [NSString stringWithUTF8String:home]
                                     : NSHomeDirectory();
  return [base stringByAppendingPathComponent:@".config/voxtral"];
}

/* Reads <config_dir>/config (a missing file is an empty one) and parses it.
 * Returns 0, or -1 with a short reason in err. */
static int load_config(vox_config_t *cfg, char *err, size_t err_len) {
  NSString *path = [config_dir() stringByAppendingPathComponent:@"config"];
  NSString *text = nil;
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    text = [NSString stringWithContentsOfFile:path
                                     encoding:NSUTF8StringEncoding
                                        error:nil];
    if (!text) {
      snprintf(err, err_len, "无法读取配置文件");
      return -1;
    }
  }
  return vox_config_parse(text ? [text UTF8String] : NULL, cfg, err, err_len);
}

static void usage(const char *prog) {
  fprintf(stderr, "voxtral-daemon — macOS voice dictation with Voxtral\n\n");
  fprintf(stderr, "Usage: %s [options]\n\n", prog);
  fprintf(stderr, "Options:\n");
  fprintf(stderr, "  -d <dir>      Model directory (default: auto-detect)\n");
  fprintf(stderr, "  -I <secs>     Processing interval (default: %.1f)\n",
          DAEMON_DEFAULT_INTERVAL);
  fprintf(stderr, "  --check       Validate settings, print the backend, exit\n");
  fprintf(stderr, "  -h            Show this help\n");
  fprintf(stderr, "\nSettings: ~/.config/voxtral/config\n");
  fprintf(stderr, "  backend = openai   send audio to OpenAI (default: local)\n");
  fprintf(stderr, "\nControls:\n");
  fprintf(stderr, "  ⌥Space        Toggle dictation on/off\n");
  fprintf(stderr, "  Menu bar 🎤   Click for options\n");
}

int main(int argc, char **argv) {
  const char *model_dir = NULL;

  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-d") == 0 && i + 1 < argc) {
      model_dir = argv[++i];
    } else if (strcmp(argv[i], "-I") == 0 && i + 1 < argc) {
      g_interval = (float)atof(argv[++i]);
      if (g_interval <= 0) {
        fprintf(stderr, "Error: -I requires a positive number\n");
        return 1;
      }
    } else if (strcmp(argv[i], "--check") == 0) {
      g_check_only = YES;
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      usage(argv[0]);
      return 0;
    } else {
      fprintf(stderr, "Unknown option: %s\n", argv[i]);
      usage(argv[0]);
      return 1;
    }
  }

  vox_config_t cfg;
  char err[160];
  if (load_config(&cfg, err, sizeof err) != 0)
    fatal_startup([NSString stringWithFormat:@"配置无效：%s", err]);

  if (strcmp(cfg.backend, "openai") == 0) {
    NSString *reason = nil;
    g_api_key = VoxOpenAILoadKey(
        [config_dir() stringByAppendingPathComponent:@"openai_key"], &reason);
    if (!g_api_key)
      fatal_startup(reason);
    g_backend_openai = YES;
    if (model_dir)
      fprintf(stderr, "voxtral-daemon: API 模式，忽略 -d\n");
  } else {
    if (!model_dir) {
      /* Auto-detect model directory if not provided */
      NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
      NSString *alongsideApp = [[bundlePath stringByDeletingLastPathComponent]
          stringByAppendingPathComponent:@"voxtral-model"];
      NSString *inResources = [[[NSBundle mainBundle] resourcePath]
          stringByAppendingPathComponent:@"voxtral-model"];
      NSString *inCwd = @"./voxtral-model";

      NSArray *paths = @[ alongsideApp, inResources, inCwd ];
      for (NSString *p in paths) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p
                                                 isDirectory:&isDir] &&
            isDir) {
          model_dir = strdup([p UTF8String]);
          break;
        }
      }
    }

    BOOL isDir = NO;
    if (!model_dir ||
        ![[NSFileManager defaultManager]
            fileExistsAtPath:[NSString stringWithUTF8String:model_dir]
                 isDirectory:&isDir] ||
        !isDir)
      fatal_startup(@"找不到 voxtral-model：请放在 Voxtral.app 旁边、放进它的 "
                    @"Resources，或用 -d 指定");
  }

  if (g_check_only) {
    if (g_backend_openai)
      printf("backend: openai\n");
    else
      printf("backend: local (model: %s)\n", model_dir);
    return 0;
  }

  /* Check accessibility permission */
  NSDictionary *opts =
      @{(__bridge NSString *)kAXTrustedCheckOptionPrompt : @YES};
  if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts)) {
    fprintf(stderr,
            "voxtral-daemon: accessibility permission required.\n"
            "A system dialog should have appeared. Please grant permission,\n"
            "then restart voxtral-daemon.\n");
    return 1;
  }

  if (!g_backend_openai) {
    /* Silence voxtral status output (we do our own feedback) */
    extern int vox_verbose;
    vox_verbose = 0;

#ifdef USE_METAL
    vox_metal_init();
#endif

    /* Load model */
    fprintf(stderr, "voxtral-daemon: loading model from %s...\n", model_dir);
    g_ctx = vox_load(model_dir);
    if (!g_ctx) {
      fprintf(stderr, "voxtral-daemon: failed to load model\n");
      return 1;
    }
    fprintf(stderr, "voxtral-daemon: model loaded\n");
  }

  /* Setup global hotkey */
  if (setup_hotkey_tap() != 0) {
    if (g_ctx)
      vox_free(g_ctx);
    return 1;
  }

  /* Create NSApplication and run */
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    g_delegate = [[DaemonDelegate alloc] init];
    app.delegate = g_delegate;

    [app run]; /* Blocks — runs the event loop */
  }

  /* Cleanup (reached on quit) */
  if (!g_backend_openai) {
    if (g_state != STATE_IDLE)
      stop_listening();
    vox_free(g_ctx);
#ifdef USE_METAL
    vox_metal_shutdown();
#endif
  }

  return 0;
}
