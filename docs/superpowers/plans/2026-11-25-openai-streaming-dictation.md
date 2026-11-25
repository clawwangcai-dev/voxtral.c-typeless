# OpenAI 流式听写（API 模式）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 macOS 听写程序加一个 API 模式：把麦克风音频流式发给 OpenAI `gpt-live-transcribe`，边说边把文字打进当前窗口。

**Architecture:** 纯规则（静音闸门、文字拼接、配置解析）放在标准 C 的 `voxtral_dictation.c`，离线单测。网络传输放在 `voxtral_openai.m`（`NSURLSessionWebSocketTask`），会话的全部状态只在一个串行队列上读写。`voxtral_daemon.m` 启动时按配置选后端；API 模式的听写状态只在主队列上改，结束流程不阻塞主线程。

**Tech Stack:** C99、Objective-C（ARC）、Foundation、AppKit、AudioToolbox、make。

**Spec:** `docs/superpowers/specs/2026-11-25-openai-streaming-dictation-design.md`（先读它；本计划只写它没定的东西）

## Global Constraints

- 分支：从 `main` 建 `feat/openai-dictation`，所有提交都在这个分支上，不 push。第一个提交加入 `docs/superpowers/` 下的设计稿和本计划。
- 提交信息沿用仓库的 `feat:` / `fix:` / `docs:` / `chore:` 前缀，结尾加一行 `Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>`。
- 不引入新依赖：只用 C 标准库、Foundation、AppKit、AudioToolbox。
- `voxtral_dictation.c` 只用标准 C，不包含任何平台头文件。
- 不留没人调用的代码。构建无警告（`-Wall -Wextra`）。
- 本地模式行为不变：`main.c`、`start_listening`、`stop_listening`、`audio_thread_func`、`drain_and_inject` 不动。
- 端点 `wss://api.openai.com/v1/realtime?intent=transcription`，模型 `gpt-live-transcribe`，音频 24000 Hz、16 位小端、单声道。
- 已打出的字绝不退格。
- key 和服务端返回的任何原文都不写日志、不进菜单、不进进程参数。
- 配置目录是 `$HOME/.config/voxtral`（读环境变量 `HOME`，没有时用 `NSHomeDirectory()`）。

## Review Focus

设计稿没有逐条写、但使用者最可能碰到的五种情况。每条都已在对应任务里加了测试。

1. 按下热键时已经在说话：第一帧就是大声，底噪还没有估计。期望不丢开头。→ Task 1 `test_gate_speaking_when_it_starts`
2. 听写中断网或根本连不上。期望只收到一次 `onDone(Network)`，之后再调用不会有第二次。→ Task 4 场景 B
3. key 文件不规整：结尾有换行、空文件、权限 644。期望能用，或给出明确原因。→ Task 4 场景 A
4. 配置文件带 BOM、CRLF、超长值、非 ASCII 词条。期望正常解析，或报错，但不截断。→ Task 3
5. 增量里有 4 字节字符或非法 UTF-8。期望原样打出，不崩溃。→ Task 2

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `voxtral_dictation.h` / `.c` | 新建 | 静音闸门、文字拼接、配置解析。纯函数，不碰网络和平台 |
| `test_dictation.c` | 新建 | 上面三块的离线单测 |
| `voxtral_openai.h` / `.m` | 新建 | 一次听写对应一个 WebSocket 会话；读 key |
| `test_openai.m` | 新建 | 会话的测试：key 读取、连不上、无效 key、真实转写 |
| `test_daemon_startup.sh` | 新建 | 听写程序启动检查的脚本测试 |
| `voxtral_mic.h` / `voxtral_mic_macos.c` | 修改 | 增加 `vox_mic_start_rate` |
| `voxtral_daemon.m` | 修改 | 选后端、`--check`、菜单、API 模式的听写流程、热键监听修复 |
| `Makefile`、`.gitignore` | 修改 | 新目标和产物 |
| `README.md`、`CLAUDE.md` | 修改 | API 模式的说明 |

---

### Task 1: 静音闸门

**Files:**
- Create: `voxtral_dictation.h`, `voxtral_dictation.c`, `test_dictation.c`
- Modify: `Makefile`（`test-dictation`、`test`、`clean`、`.PHONY`、`help`）、`.gitignore`

**Interfaces:**
- Produces（`voxtral_dictation.h`，后面的任务都靠它）:

```c
/* One call per 10 ms frame. */
#define VOX_GATE_PREROLL 30 /* frames re-sent when speech resumes (300 ms) */

typedef struct {
  float floor; /* noise floor estimate; 0 = no estimate yet */
  int hang;    /* frames still uploaded after speech ends */
  int silence; /* consecutive non-speech frames while open */
  int open;    /* 1 while uploading */
  int skipped; /* frames dropped since the gate closed, capped at VOX_GATE_PREROLL */
} vox_gate_t;

int vox_gate_hang_frames(const char *delay); /* 250 for "high"/"xhigh", else 150 */
void vox_gate_init(vox_gate_t *g, int hang_frames);
/* 0 = drop this frame. n >= 1 = upload the n most recent frames, this one last. */
int vox_gate_push(vox_gate_t *g, float rms);
float vox_frame_rms(const float *samples, int n);
```

- [ ] **Step 1: 建分支并提交文档**

```bash
git checkout -b feat/openai-dictation
git add docs/superpowers
git commit -m "docs: add OpenAI streaming dictation design and plan"
```

- [ ] **Step 2: 写失败的测试** `test_dictation.c`

```c
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
```

- [ ] **Step 3: 加 Makefile 目标**（放在平台条件块之外，Linux 上也能跑）

```make
test-dictation: test_dictation.c voxtral_dictation.c voxtral_dictation.h
	$(CC) -Wall -Wextra -O2 -o test_dictation test_dictation.c voxtral_dictation.c -lm
	./test_dictation

test: test-dictation
	@./runtest.sh
```

`clean` 里删除 `test_dictation test_openai`；`.PHONY` 加 `test-dictation test-api test-daemon`；`help` 的 "Other targets" 加三行说明；`.gitignore` 加 `test_dictation` 和 `test_openai`。

- [ ] **Step 4: 运行，确认失败**

Run: `make test-dictation`　Expected: 编译失败，`voxtral_dictation.h` 不存在。

- [ ] **Step 5: 实现** `voxtral_dictation.h`（上面的接口）和 `voxtral_dictation.c`

规则来自设计稿"进行中的静音闸门"。闸门的判定顺序测试定不死，按这个写：

```c
#define FLOOR_MIN 0.001f    /* frames below this are digital silence */
#define FLOOR_RISE 1.001f   /* per frame, about 0.9 dB per second */
#define SPEECH_RATIO 2.0f

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
```

底噪下限 0.001 乘以 2 就是设计稿里的 0.002 绝对阈值，不用另写一个常量。

- [ ] **Step 6: 运行，确认通过**

Run: `make test-dictation`　Expected: `test_dictation: all passed`

- [ ] **Step 7: 提交**

```bash
git add voxtral_dictation.h voxtral_dictation.c test_dictation.c Makefile .gitignore
git commit -m "feat: add adaptive silence gate for API dictation"
```

---

### Task 2: 文字拼接

**Files:**
- Modify: `voxtral_dictation.h`, `voxtral_dictation.c`, `test_dictation.c`

**Interfaces:**
- Produces:

```c
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
```

- [ ] **Step 1: 写失败的测试**（加到 `test_dictation.c`，并在 `main` 里调用）

```c
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
    {{"🙂", "好"}, "🙂好"},                    /* Review Focus 5: 4-byte characters */
    {{"\xff\xfe", "好"}, "\xff\xfe好"},        /* Review Focus 5: malformed UTF-8 passes through */
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
```

- [ ] **Step 2: 运行，确认失败**

Run: `make test-dictation`　Expected: 编译失败，`vox_text_t` 未定义。

- [ ] **Step 3: 实现**

- 逐个码点处理，输出时原样复制该码点的字节；解不出来的字节当作"其他"类，原样复制一个字节。
- 汉字：U+3400–U+4DBF、U+4E00–U+9FFF。拉丁：ASCII 字母和数字、U+00C0–U+024F（去掉 U+00D7 和 U+00F7）。
- 要打的码点和 `last_cp` 一个是汉字、一个是拉丁时，先输出一个空格。`last_cp == 0` 时遇到空白（空格、制表、换行）直接跳过。
- `vox_text_delta`：`item_id` 和 `t->item` 不同时换成新的并清空 `raw`（`last_cp` 保留）；把增量追加到 `raw`。
- `vox_text_final`：两边都去掉首尾 ASCII 空白后比较；最终稿以 `raw` 开头且更长时，返回多出来的那段（同样过补空格规则），并把 `raw` 换成最终稿；其余情况返回 `NULL`。

- [ ] **Step 4: 运行，确认通过**

Run: `make test-dictation`　Expected: `test_dictation: all passed`

- [ ] **Step 5: 提交**

```bash
git add voxtral_dictation.h voxtral_dictation.c test_dictation.c
git commit -m "feat: add append-only text assembly with CJK/Latin spacing"
```

---

### Task 3: 配置解析

**Files:**
- Modify: `voxtral_dictation.h`, `voxtral_dictation.c`, `test_dictation.c`

**Interfaces:**
- Produces:

```c
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
```

- [ ] **Step 1: 写失败的测试**（加到 `test_dictation.c`，并在 `main` 里调用）

```c
static void test_config(void) {
  vox_config_t c; char err[128];

  CHECK(vox_config_parse(NULL, &c, err, sizeof err) == 0);
  CHECK(!strcmp(c.backend, "local") && !strcmp(c.delay, "low") && c.max_minutes == 10);
  CHECK(!c.languages[0] && !c.keywords[0]);

  const char *spec_example =
      "backend = openai\nlanguages = zh,en,de\ndelay = low\n"
      "keywords = Leistungsverzeichnis, Einzelpreis, Gesamtpreis\nmax_minutes = 10\n";
  CHECK(vox_config_parse(spec_example, &c, err, sizeof err) == 0);
  CHECK(!strcmp(c.backend, "openai") && !strcmp(c.languages, "zh,en,de"));
  CHECK(!strcmp(c.keywords, "Leistungsverzeichnis,Einzelpreis,Gesamtpreis"));

  /* Review Focus 4: BOM, CRLF, comments, blank lines, empty items, empty value */
  CHECK(vox_config_parse("\xef\xbb\xbf# mine\r\n\r\n  languages = zh, en ,, de   # mixed\r\ndelay =\r\n",
                         &c, err, sizeof err) == 0);
  CHECK(!strcmp(c.languages, "zh,en,de") && !strcmp(c.delay, "low"));
  CHECK(vox_config_parse("keywords = 报价单, Größe", &c, err, sizeof err) == 0);
  CHECK(!strcmp(c.keywords, "报价单,Größe"));
  CHECK(vox_config_parse("max_minutes = 55", &c, err, sizeof err) == 0 && c.max_minutes == 55);

  const char *bad[] = {"delay = fast", "backend = cloud", "keywords = a<b", "keywords = a>b",
                       "max_minutes = 0", "max_minutes = 56", "max_minutes = ten",
                       "langauges = zh", "delay low"};
  for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
    err[0] = 0;
    CHECK(vox_config_parse(bad[i], &c, err, sizeof err) == -1 && err[0]);
  }
  CHECK(vox_config_parse("delay = fast", &c, err, sizeof err) == -1 && strstr(err, "delay"));

  char big[2100] = "keywords = "; /* Review Focus 4: too long is an error, never a truncation */
  memset(big + 11, 'a', 2000); big[2011] = 0;
  CHECK(vox_config_parse(big, &c, err, sizeof err) == -1);
}
```

- [ ] **Step 2: 运行，确认失败**

Run: `make test-dictation`　Expected: 编译失败，`vox_config_t` 未定义。

- [ ] **Step 3: 实现** `vox_config_parse`

格式规则见设计稿第 3 节。出错文案固定为这四种：`第 N 行缺少 =`、`不认识的配置项 <名称>`、`<名称> 的值无效`、`<名称> 的值太长`。`languages` 和 `keywords` 存成各项去空白后用逗号连接的形式。

- [ ] **Step 4: 运行，确认通过**

Run: `make test-dictation`　Expected: `test_dictation: all passed`

- [ ] **Step 5: 提交**

```bash
git add voxtral_dictation.h voxtral_dictation.c test_dictation.c
git commit -m "feat: add dictation config parser"
```

---

### Task 4: OpenAI 会话

**Files:**
- Create: `voxtral_openai.h`, `voxtral_openai.m`, `test_openai.m`
- Modify: `Makefile`（`test-api`）

**Interfaces:**
- Consumes: Task 1 的 `vox_gate_*`、`vox_frame_rms`；Task 2 的 `vox_text_*`。
- Produces（`voxtral_openai.h`）:

```objc
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, VoxOpenAIStatus) {
  VoxOpenAIStatusOK = 0,
  VoxOpenAIStatusTailUnconfirmed, /* final transcript failed or did not arrive within 2 s */
  VoxOpenAIStatusNetwork,         /* cannot connect, connection lost, or commit not sent within 5 s of finish */
  VoxOpenAIStatusKey,             /* server rejected the API key */
  VoxOpenAIStatusRejected,        /* server refused the session or reported an error */
  VoxOpenAIStatusSlow             /* more than 10 s of audio waiting to be sent */
};

/* Environment variable OPENAI_API_KEY, else the file at `path`.
 * Returns nil and sets *reason when there is no usable key. */
NSString *VoxOpenAILoadKey(NSString *path, NSString **reason);

@interface VoxOpenAISession : NSObject
/* Starts connecting at once. onText and onDone run on the main queue;
 * onDone runs exactly once, after every onText. */
- (instancetype)initWithKey:(NSString *)key
                  languages:(NSString *)languages /* "zh,en,de" or "" */
                      delay:(NSString *)delay
                   keywords:(NSString *)keywords  /* "a,b" or "" */
                   endpoint:(NSURL *)endpoint     /* nil = the OpenAI endpoint */
                     onText:(void (^)(NSString *text))onText
                     onDone:(void (^)(VoxOpenAIStatus status))onDone;
- (void)feed:(const float *)samples count:(int)n; /* 24 kHz mono; never blocks */
- (void)finish;                                   /* never blocks; onDone follows */
@end
```

- [ ] **Step 1: 写失败的测试** `test_openai.m`

辅助函数：`wait_until(BOOL (^cond)(void), double seconds)` 用 `[[NSRunLoop mainRunLoop] runMode:beforeDate:]` 转主循环直到条件成立或超时；`load_24k(path, &n)` 用 `vox_load_wav` 读 16 kHz 样本后线性插值到 24 kHz。每个场景通过打印 `ok <名称>`，任一断言失败计数并最终返回 1，全部通过打印 `test_openai: all passed`。

场景和断言（`dir` 是 `NSTemporaryDirectory()` 下新建的目录）：

```objc
/* A. key file — offline. Review Focus 3. Runs with OPENAI_API_KEY unset, then set. */
write(dir/"k600", "sk-test\n", 0600);  CHECK([VoxOpenAILoadKey(k600, &why) isEqualToString:@"sk-test"]);
write(dir/"k644", "sk-test\n", 0644);  CHECK(VoxOpenAILoadKey(k644, &why) == nil && [why containsString:@"600"]);
write(dir/"empty", "", 0600);          CHECK(VoxOpenAILoadKey(empty, &why) == nil && why.length > 0);
                                       CHECK(VoxOpenAILoadKey(dir/"missing", &why) == nil && why.length > 0);
setenv("OPENAI_API_KEY", "sk-env", 1); CHECK([VoxOpenAILoadKey(k644, &why) isEqualToString:@"sk-env"]);

/* B. dead endpoint — no key needed. Review Focus 2. */
session = [[VoxOpenAISession alloc] initWithKey:@"sk-x" ... endpoint:[NSURL URLWithString:@"wss://127.0.0.1:9/"] ...];
CHECK(wait_until(^{ return doneCount == 1; }, 10));
CHECK(status == VoxOpenAIStatusNetwork && textCount == 0);
[session finish]; wait_until(^{ return NO; }, 0.5);
CHECK(doneCount == 1);                 /* never a second onDone */

/* C, D, E need a real key from VoxOpenAILoadKey($HOME/.config/voxtral/openai_key).
 * Without one, print "SKIP C D E: no API key" and continue. */

/* C. invalid key against the real endpoint — sends no audio */
... initWithKey:@"sk-invalid" ... endpoint:nil ...
CHECK(wait_until(^{ return doneCount == 1; }, 10) && status == VoxOpenAIStatusKey && textCount == 0);

/* D. samples/jfk.wav in real time: 2400-sample chunks, wait_until(NO, 0.1) between chunks */
... languages:@"en" delay:@"low" keywords:@"" ...
CHECK(firstTextAt > 0 && firstTextAt < finishCalledAt);   /* text arrives before commit */
CHECK(wait_until(^{ return doneCount == 1; }, 10) && status == VoxOpenAIStatusOK);
CHECK([normalize(allText) containsString:@"ask not what your country can do for you"]);
/* normalize = lowercase, keep letters and spaces only, collapse runs of spaces */

/* E. one second of zeros, then finish: nothing was said */
CHECK(wait_until(^{ return doneCount == 1; }, 2) && status == VoxOpenAIStatusOK && textCount == 0);
```

- [ ] **Step 2: 加 Makefile 目标**（放在 `ifeq ($(UNAME_S),Darwin)` 块里，不要求 arm64）

```make
test-api: test_openai.m voxtral_openai.m voxtral_openai.h voxtral_dictation.c voxtral_audio.c
	$(CC) -Wall -Wextra -O2 -fobjc-arc -o test_openai test_openai.m voxtral_openai.m \
		voxtral_dictation.c voxtral_audio.c -framework Foundation -lm
	./test_openai
```

- [ ] **Step 3: 运行，确认失败**

Run: `make test-api`　Expected: 编译失败，`voxtral_openai.h` 不存在。

- [ ] **Step 4: 实现** `voxtral_openai.h`（上面的接口）和 `voxtral_openai.m`

`VoxOpenAILoadKey`：环境变量非空就用它；否则文件不存在或去空白后为空，原因是 `找不到 OpenAI key`；文件权限 `st_mode & 077` 不为 0，原因是 `key 文件权限必须是 600`。

会话的规则（数值都来自设计稿第 4、5 节）：

- 一个串行队列持有全部状态。`feed:count:` 复制样本后异步进这个队列。回调一律在这个队列之外派发到主队列。
- `NSURLSession` 用 `ephemeralSessionConfiguration`，回调队列的 `underlyingQueue` 就是上面的串行队列。请求头 `Authorization: Bearer <key>`。
- 连接打开后发的第一条消息（`languages`、`keywords` 为空时省略该字段）：

```json
{"type":"session.update","session":{"type":"transcription","audio":{"input":{
  "format":{"type":"audio/pcm","rate":24000},
  "transcription":{"model":"gpt-live-transcribe","languages":["zh","en","de"],"delay":"low","keywords":["a","b"]},
  "turn_detection":null}}}}
```

- 收到 `session.updated` 之前不发任何音频。
- 音频按 240 个样本一帧：`vox_frame_rms` 算音量，`vox_gate_push` 决定上传几帧（闸门的尾随帧数取 `vox_gate_hang_frames(delay)`）；保留最近 30 个被丢弃的帧供补发。
- 上传：每 2400 个样本一包，`{"type":"input_audio_buffer.append","audio":"<base64>"}`。
- 等待发送和已发送但未确认的样本合计超过 240000（10 秒）：`Slow`。
- 事件：
  - `conversation.item.input_audio_transcription.delta`（`item_id`、`delta`）→ `vox_text_delta` → `onText`
  - `conversation.item.input_audio_transcription.completed`（`item_id`、`transcript`）→ `vox_text_final` → `onText`；已在收尾则 `OK`
  - `conversation.item.input_audio_transcription.failed` → 已在收尾则 `TailUnconfirmed`
  - `error`：`error.code` 是 `invalid_api_key` 则 `Key`，否则 `Rejected`
- `finish`：
  - 闸门从没放行过任何帧：立刻 `OK`。
  - 否则把不满一帧、不满一包的音频也发出去；本段上传满 2400 个样本才发 `{"type":"input_audio_buffer.commit"}`，不满就直接 `OK`。
  - 提交发出后等最终稿 2 秒，超时 `TailUnconfirmed`。
  - `finish` 之后 5 秒内提交还没发出去（还没连上）：`Network`。
- 握手失败、连接断开、收发出错：`Network`（握手的 HTTP 状态是 401 时 `Key`）。
- 结束时（任何状态）：只进一次；`cancelWithCloseCode:` 加 `invalidateAndCancel`；之后的 `feed`、`finish` 和事件全部忽略。
- 不打印、不保存服务端发来的任何字符串。

- [ ] **Step 5: 运行，确认通过**

Run: `make test-api`
Expected（有 key 时）: `ok A` 到 `ok E` 五行，然后 `test_openai: all passed`。场景 D 约 12 秒，费用约 0.003 美元。

- [ ] **Step 6: 提交**

```bash
git add voxtral_openai.h voxtral_openai.m test_openai.m Makefile
git commit -m "feat: add OpenAI realtime transcription session"
```

---

### Task 5: 听写程序选后端

**Files:**
- Create: `test_daemon_startup.sh`
- Modify: `voxtral_daemon.m`（`main`、`usage`、`DaemonDelegate`、`hotkey_callback`、`setup_hotkey_tap`）、`Makefile`（`DAEMON_SRC`、`test-daemon`）

**Interfaces:**
- Consumes: `vox_config_parse`（Task 3）、`VoxOpenAILoadKey`（Task 4）。
- Produces（都在 `voxtral_daemon.m` 里，Task 6 要用）:
  - `static BOOL g_backend_openai;`　`static NSString *g_api_key;`
  - `static NSString *config_dir(void);` 返回 `$HOME/.config/voxtral`
  - `static int load_config(vox_config_t *cfg, char *err, size_t err_len);` 读 `<config_dir>/config`（不存在等于空）后调用 `vox_config_parse`；文件存在却读不出来时返回 -1，原因 `无法读取配置文件`
  - `- (void)showNotice:(NSString *)text;` 加在 `DaemonDelegate` 上；`nil` 表示隐藏

- [ ] **Step 1: 写失败的测试** `test_daemon_startup.sh`

每个用例新建临时目录 `$T`，把 `./voxtral-daemon` 复制进去（否则它会在仓库根目录找到 `voxtral-model`），在 `$T` 里用 `HOME=$T` 运行 `./voxtral-daemon --check`，比较退出码和输出。全部通过打印 `test_daemon_startup: all passed`，否则打印失败的用例并返回 1。

| # | `$T/.config/voxtral/` 里的文件 | 环境变量 | 参数 | 期望退出码 | 输出必须包含 | 输出不得包含 |
|---|---|---|---|---|---|---|
| 1 | `config`: `delay = fast` | 无 key | | 1 | `配置无效`、`delay` | |
| 2 | `config`: `backend = openai` | 无 key | | 1 | `找不到 OpenAI key` | |
| 3 | 同 2，加 `openai_key`（权限 644） | 无 key | | 1 | `600` | |
| 4 | 无 | 无 key | | 1 | `voxtral-model` | |
| 5 | 同 2，加 `openai_key`（权限 600） | 无 key | | 0 | `backend: openai` | `sk-` |
| 6 | `config`: `backend = openai` | `OPENAI_API_KEY=sk-test` | | 0 | `backend: openai` | `sk-test` |
| 7 | 无 | `OPENAI_API_KEY=sk-test` | `-d $T` | 0 | `backend: local` | |

"无 key"用 `env -u OPENAI_API_KEY`。用例 7 对应反目标"没有主动开启，音频却被上传"。

- [ ] **Step 2: 改 Makefile**（daemon 所在的条件块里）

```make
DAEMON_SRC = voxtral_daemon.m voxtral_openai.m voxtral_dictation.c

test-daemon: daemon
	./test_daemon_startup.sh
```

- [ ] **Step 3: 运行，确认失败**

Run: `make test-daemon`　Expected: 用例 1、2、3、5、6、7 失败（现在的程序不认识 `--check`）。

- [ ] **Step 4: 实现**

`main` 的顺序改为：解析参数 → 读配置 → 按后端校验 → 无障碍权限 → 本地模式才初始化 Metal 并加载模型 → 热键 → 运行。

- 新参数 `--check`：做完"读配置"和"按后端校验"后，标准输出打印 `backend: openai` 或 `backend: local (model: <目录>)` 并返回 0；校验失败则把原因打到标准错误并返回 1。`--check` 从不弹窗。`usage` 里加上它和配置文件的位置。
- `static void fatal_startup(NSString *message)`：把原因打到标准错误；标准错误不是终端（`isatty` 为假，即从 Finder 启动）时再用 `NSAlert` 弹窗；然后 `exit(1)`。
- 校验失败的原因文案：`配置无效：<err>`；`VoxOpenAILoadKey` 给的原因原样使用；找不到模型用 `找不到 voxtral-model：请放在 Voxtral.app 旁边、放进它的 Resources，或用 -d 指定`。
- `backend = openai` 时不找模型目录，不调用 `vox_metal_init` 和 `vox_load`，key 存进 `g_api_key`。命令行给了 `-d` 就打一行 `API 模式，忽略 -d`。
- 菜单顺序：模式（不可点，`模式：OpenAI 流式` 或 `模式：本地模型`）、提示（默认隐藏，`showNotice:` 控制）、开始/停止、分隔线、退出。
- 热键监听修复：`setup_hotkey_tap` 把 `CGEventTapCreate` 的结果存进 `static CFMachPortRef g_tap`，`hotkey_callback` 里被禁用时调用 `CGEventTapEnable(g_tap, true)`。

- [ ] **Step 5: 运行，确认通过**

Run: `make test-daemon`　Expected: `test_daemon_startup: all passed`
Run: `make test-dictation`　Expected: `test_dictation: all passed`

- [ ] **Step 6: 提交**

```bash
git add voxtral_daemon.m test_daemon_startup.sh Makefile
git commit -m "feat: select dictation backend from config and add --check"
```

---

### Task 6: API 模式的听写流程

**Files:**
- Modify: `voxtral_mic.h`, `voxtral_mic_macos.c`, `voxtral_daemon.m`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: `VoxOpenAISession`、`VoxOpenAIStatus`（Task 4）；`g_backend_openai`、`g_api_key`、`load_config`、`showNotice:`（Task 5）；`vox_config_t`（Task 3）。
- Produces: `int vox_mic_start_rate(int sample_rate);`（`voxtral_mic.h`）。`vox_mic_start()` 保留，等于 `vox_mic_start_rate(16000)`。

这个任务的验证是构建加真机清单：热键、麦克风和往窗口打字没法自动化。清单要由使用者本人执行，执行者把清单交给使用者并等结果。

- [ ] **Step 1: 麦克风采样率**

`vox_mic_start_rate(int sample_rate)` 用传入的采样率填 `AudioStreamBasicDescription`，每个 AudioQueue 缓冲区取 `sample_rate / 10` 个样本；`vox_mic_start()` 调用它传 16000。非 macOS 的桩函数同样加上。环形缓冲大小不变（24 kHz 下约 6.6 秒），更新那行注释。

- [ ] **Step 2: 听写流程**（`voxtral_daemon.m`）

新增状态：`static uint64_t g_dictation_id; static VoxOpenAISession *g_session; static dispatch_queue_t g_teardown_q;`（串行）`static int g_max_minutes; static BOOL g_cap_hit;`

热键回调和菜单项都改成调用同一个 `toggle_dictation()`：本地模式走原来的 `start_listening` / `stop_listening`；API 模式空闲时调 `api_start()`，否则调 `api_stop()`。

`api_start()`（主队列，状态不是空闲就返回）：
1. `load_config`。失败：`showNotice:@"配置无效：<err>"`，图标 ⚠️，响 `Basso`，返回。
2. `vox_mic_start_rate(24000)`。失败：`showNotice:@"出错：麦克风"`，图标 ⚠️，响 `Basso`，返回。
3. `id = ++g_dictation_id`；`g_cap_hit = NO`；隐藏提示。
4. 建会话。`onText`：`id` 不等于 `g_dictation_id` 就丢弃，否则 `inject_text`。`onDone`：调 `api_done(id, status)`。
5. 状态改为听写中，起音频线程，响 `Tink`，图标 🔴。
6. `dispatch_after` `max_minutes * 60` 秒：`id` 仍是当前且状态是听写中时，置 `g_cap_hit = YES` 并调 `api_stop()`。

音频线程：循环 `vox_mic_read`（每次最多 2400 个样本）交给 `[g_session feed:count:]`，没有数据时睡 10 毫秒；循环体包在 `@autoreleasepool` 里。不做积压丢弃，不做旧的静音判断。

`api_stop()`（主队列，状态不是听写中就返回，所以收尾中再按热键没有效果）：状态改为收尾中，然后在 `g_teardown_q` 上：停音频线程并 `pthread_join`，`vox_mic_stop()`，把环形缓冲里剩下的样本读完交给会话，`[session finish]`。主线程不等待。

`api_done(id, status)`（主队列）：`id` 过期就返回。状态是听写中（会话自己出错结束）时先改为收尾中，在 `g_teardown_q` 上停音频线程和麦克风。无论哪种情况，都经过 `g_teardown_q` 再回到主队列调 `api_idle(status)`，保证拆除动作已经做完。

`api_idle(status)`（主队列）：状态改为空闲，`g_session = nil`，然后：

| 情况 | 声音 | 图标 | 提示 |
|---|---|---|---|
| `OK` | `Pop` | 🎤 | 隐藏 |
| `OK` 且 `g_cap_hit` | `Glass` | 🎤 | `已到 N 分钟上限，自动结束` |
| `TailUnconfirmed` | `Pop` | 🎤 | `结尾可能不完整` |
| `TailUnconfirmed` 且 `g_cap_hit` | `Glass` | 🎤 | `已到 N 分钟上限，自动结束；结尾可能不完整` |
| `Network` | `Basso` | ⚠️ | `出错：网络` |
| `Key` | `Basso` | ⚠️ | `出错：key 无效` |
| `Rejected` | `Basso` | ⚠️ | `出错：服务端拒绝` |
| `Slow` | `Basso` | ⚠️ | `出错：网络太慢` |

`quitApp:` 在 API 模式下不走 `stop_listening`：停麦克风后直接退出。

- [ ] **Step 3: 构建并跑全部自动测试**

Run: `make clean && make mps && make daemon`　Expected: 无警告，生成 `voxtral` 和 `voxtral-daemon`
Run: `make test-dictation && make test-api && make test-daemon`　Expected: 三个都是 `all passed`

- [ ] **Step 4: 文档**

`README.md` 在 "macOS Standalone Application (Daemon)" 一节后面加 "OpenAI streaming mode" 小节，`CLAUDE.md` 的 Quick Reference 和 Key Files 相应更新。必须写到：
- 开启方法：`~/.config/voxtral/config` 写 `backend = openai`，key 放 `~/.config/voxtral/openai_key`（权限 600）或环境变量 `OPENAI_API_KEY`；从 Finder 启动的 `.app` 读不到 shell 的环境变量。
- 五个配置项、默认值、合法取值；`backend` 改了要重启，其余下次按 ⌥Space 生效。
- 混说多种语言或专业术语要配 `languages` 和 `keywords`。
- 这个模式下音频会上传到 OpenAI：有声时上传，停顿 1.5 秒（`high`/`xhigh` 为 2.5 秒）后暂停；按上传时长计费，公布价 0.017 美元/分钟。
- 单次听写上限 `max_minutes`。
- `voxtral-daemon --check`、`make test-dictation`、`make test-api`、`make test-daemon`。

- [ ] **Step 5: 提交**

```bash
git add voxtral_mic.h voxtral_mic_macos.c voxtral_daemon.m README.md CLAUDE.md
git commit -m "feat: add OpenAI streaming mode to the dictation daemon"
```

- [ ] **Step 6: 真机清单**（交给使用者执行；配置为 `backend = openai`、`languages = zh,en,de`、`delay = low`，带词表）

| # | 操作 | 期望 |
|---|---|---|
| 1 | 对着文本编辑器混说中英德；中文输入法开着时再试一次 | 字边说边出，三种语言都是原文；响结束音之后不再有字冒出来 |
| 2 | 快速连按 ⌥Space 三次 | 不崩溃，键盘不卡，最后回到 🎤 |
| 3 | 不戴耳机（外放），按下后不说话，马上再按 | 没有错误音，没有字；终端里 `uploaded` 的秒数接近 0 |
| 4 | 说完最后一个字立刻按停；`delay = high` 再试一次 | 尾字完整，并且在结束音之前打完 |
| 5 | 说一句，停 5 秒，再说一句；再试一次停 2–3 分钟 | 停顿前的字都已出完，第二句的开头没有被吃掉；终端里 `uploaded` 明显小于 `captured` |
| 6 | 一边按热键一边开始说话 | 开头的字没有丢 |
| 7 | 听写中关掉 Wi-Fi | 错误音，⚠️，菜单显示 `出错：网络`，已打的字保留；恢复网络后再按能正常开始，⚠️ 消失 |
| 8 | 配置改成 `max_minutes = 1`，开始后等 1 分钟 | 自动结束，`Glass` 音，菜单显示上限提示 |
| 9 | 配置改成 `delay = fast`，按 ⌥Space | 不开始，菜单显示完整的 `配置无效：delay 的值无效`；改回后不用重启就能用 |
| 10 | 删掉配置文件后重启 | 回到本地模式，行为和改动前一样 |
| 11 | 双击 `Voxtral.app`，配置是 `backend = openai` 但没有 key 文件 | 弹窗说明找不到 key |
| 12 | `max_minutes = 10`，放一段播客连续听写满 10 分钟 | 到上限正常结束，没有报错（确认单段 10 分钟可行；不行就把默认值调低并更新设计稿） |
| 13 | 分别用 `low` 和 `high` 说同一句话 | 记下"说完到屏幕出字"的大致时间，写进 README |

从终端启动 `./voxtral-daemon` 才能看到每次听写结束时打印的 `uploaded X.X s of Y.Y s captured`。

清单里任何一项不符合期望，都回到 Step 2 修，修完重跑 Step 3 和出问题的那几项。
