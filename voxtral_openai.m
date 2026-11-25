/*
 * voxtral_openai.m - OpenAI realtime transcription session
 *
 * Protocol: open a WebSocket, send session.update, wait for session.updated,
 * then append 24 kHz 16-bit PCM in 100 ms packets. Text deltas arrive while
 * audio is still being appended. On finish the buffer is committed once and
 * the final transcript completes the dictation.
 *
 * All state lives on one serial queue: feed:/finish hop onto it, and the URL
 * session delivers every delegate call and completion handler on it. Text
 * and the end status leave it only through the main queue, in order.
 *
 * Nothing the server sends is printed or stored beyond the text to type.
 */

#import "voxtral_openai.h"
#include <math.h>
#include <string.h>
#include <sys/stat.h>

#include "voxtral_dictation.h"

#define OPENAI_URL "wss://api.openai.com/v1/realtime?intent=transcription"
#define OPENAI_MODEL "gpt-live-transcribe"
#define RATE 24000
#define FRAME 240                 /* 10 ms, one silence gate decision */
#define RING (VOX_GATE_PREROLL + 1) /* dropped frames kept for re-sending, plus the current one */
#define PACKET 2400               /* 100 ms per append message */
#define MIN_COMMIT 2400           /* the server rejects a commit of less than 100 ms */
#define SLOW_LIMIT 240000         /* 10 s of audio waiting to be sent */
#define FINAL_WAIT 2.0            /* seconds from commit to the final transcript */
#define COMMIT_WAIT 5.0           /* seconds from finish to the commit being sent */

NSString *VoxOpenAILoadKey(NSString *path, NSString **reason) {
  const char *env = getenv("OPENAI_API_KEY");
  if (env && env[0])
    return @(env);

  NSString *why = @"找不到 OpenAI key";
  struct stat st;
  if (stat(path.fileSystemRepresentation, &st) == 0) {
    if (st.st_mode & 077) {
      why = @"key 文件权限必须是 600";
    } else {
      NSString *text = [NSString stringWithContentsOfFile:path
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
      NSString *key = [text stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (key.length > 0)
        return key;
    }
  }
  if (reason)
    *reason = why;
  return nil;
}

@interface VoxOpenAISession () <NSURLSessionWebSocketDelegate>
@end

@implementation VoxOpenAISession {
  dispatch_queue_t _queue;
  NSURLSession *_urlSession;
  NSURLSessionWebSocketTask *_task;
  NSString *_sessionUpdate; /* first message once the socket opens */
  void (^_onText)(NSString *);
  void (^_onDone)(VoxOpenAIStatus);

  vox_gate_t _gate;
  vox_text_t _text;
  float _ring[RING][FRAME]; /* most recent frames; frame k is _ring[k % RING] */
  long _frames;             /* complete frames seen */
  int _partial;             /* samples in _ring[_frames % RING] so far */
  NSMutableData *_pending;  /* passed the gate, not yet sent: 16-bit LE PCM */
  long _inFlight;           /* samples handed to sendMessage:, not yet completed */
  long _uploaded;           /* samples handed to sendMessage: in this session */

  BOOL _passed;     /* the gate has let at least one frame through */
  BOOL _configured; /* session.updated arrived; audio may be sent */
  BOOL _finishing;  /* finish was called */
  BOOL _committed;  /* input_audio_buffer.commit was sent */
  BOOL _ended;      /* onDone was dispatched; everything else is ignored */
}

- (instancetype)initWithKey:(NSString *)key
                  languages:(NSString *)languages
                      delay:(NSString *)delay
                   keywords:(NSString *)keywords
                   endpoint:(NSURL *)endpoint
                     onText:(void (^)(NSString *text))onText
                     onDone:(void (^)(VoxOpenAIStatus status))onDone {
  if (!(self = [super init]))
    return nil;
  _onText = onText;
  _onDone = onDone;
  _queue = dispatch_queue_create("voxtral.openai", DISPATCH_QUEUE_SERIAL);
  _pending = [NSMutableData data];
  vox_gate_init(&_gate, vox_gate_hang_frames(delay.UTF8String));
  vox_text_init(&_text);

  NSMutableDictionary *tr =
      [@{@"model" : @OPENAI_MODEL, @"delay" : delay} mutableCopy];
  if (languages.length)
    tr[@"languages"] = [languages componentsSeparatedByString:@","];
  if (keywords.length)
    tr[@"keywords"] = [keywords componentsSeparatedByString:@","];
  NSDictionary *msg = @{
    @"type" : @"session.update",
    @"session" : @{
      @"type" : @"transcription",
      @"audio" : @{
        @"input" : @{
          @"format" : @{@"type" : @"audio/pcm", @"rate" : @RATE},
          @"transcription" : tr,
          @"turn_detection" : [NSNull null]
        }
      }
    }
  };
  NSData *json = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
  _sessionUpdate = [[NSString alloc] initWithData:json
                                         encoding:NSUTF8StringEncoding];

  NSOperationQueue *delegateQueue = [NSOperationQueue new];
  delegateQueue.maxConcurrentOperationCount = 1;
  delegateQueue.underlyingQueue = _queue;
  _urlSession = [NSURLSession
      sessionWithConfiguration:[NSURLSessionConfiguration
                                   ephemeralSessionConfiguration]
                      delegate:self
                 delegateQueue:delegateQueue];
  NSMutableURLRequest *req = [NSMutableURLRequest
      requestWithURL:endpoint ?: [NSURL URLWithString:@OPENAI_URL]];
  [req setValue:[@"Bearer " stringByAppendingString:key]
      forHTTPHeaderField:@"Authorization"];
  _task = [_urlSession webSocketTaskWithRequest:req];
  [_task resume];
  return self;
}

- (void)feed:(const float *)samples count:(int)n {
  if (n <= 0)
    return;
  NSData *copy = [NSData dataWithBytes:samples length:(size_t)n * sizeof(float)];
  dispatch_async(_queue, ^{
    [self consume:copy.bytes count:n];
  });
}

- (void)finish {
  dispatch_async(_queue, ^{
    if (self->_ended || self->_finishing)
      return;
    self->_finishing = YES;
    if (!self->_passed) {
      [self endWith:VoxOpenAIStatusOK];
      return;
    }
    /* A partial last frame belongs to the upload only while the gate is open. */
    if (self->_gate.open && self->_partial > 0)
      [self queueSamples:self->_ring[self->_frames % RING] count:self->_partial];
    self->_partial = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(COMMIT_WAIT * NSEC_PER_SEC)),
                   self->_queue, ^{
                     if (!self->_committed)
                       [self endWith:VoxOpenAIStatusNetwork];
                   });
    [self pump];
  });
}

/* ---------------------------------------------------------- audio path -- */

- (void)consume:(const float *)samples count:(int)n {
  if (_ended || _finishing)
    return;
  while (n > 0) {
    float *frame = _ring[_frames % RING];
    int take = FRAME - _partial < n ? FRAME - _partial : n;
    memcpy(frame + _partial, samples, (size_t)take * sizeof(float));
    _partial += take;
    samples += take;
    n -= take;
    if (_partial < FRAME)
      break;
    _partial = 0;
    _frames++;
    int send = vox_gate_push(&_gate, vox_frame_rms(frame, FRAME));
    for (long k = _frames - send; k < _frames; k++)
      [self queueSamples:_ring[k % RING] count:FRAME];
    if (send > 0)
      _passed = YES;
  }
  [self pump];
}

- (void)queueSamples:(const float *)samples count:(int)n {
  for (int i = 0; i < n; i++) {
    float v = samples[i] < -1.0f ? -1.0f : samples[i] > 1.0f ? 1.0f : samples[i];
    uint16_t q = (uint16_t)(int16_t)lrintf(v * 32767.0f);
    uint8_t le[2] = {(uint8_t)(q & 0xff), (uint8_t)(q >> 8)};
    [_pending appendBytes:le length:2];
  }
}

/* Sends what may be sent now; on finish, the rest and the commit. */
- (void)pump {
  if (_ended)
    return;
  if ((long)_pending.length / 2 + _inFlight > SLOW_LIMIT) {
    [self endWith:VoxOpenAIStatusSlow];
    return;
  }
  if (!_configured)
    return;
  while (_pending.length >= PACKET * 2)
    [self sendPacket:PACKET];
  if (!_finishing || _committed)
    return;
  if (_pending.length > 0)
    [self sendPacket:(int)(_pending.length / 2)];
  if (_uploaded < MIN_COMMIT) {
    [self endWith:VoxOpenAIStatusOK];
    return;
  }
  _committed = YES;
  [self send:@"{\"type\":\"input_audio_buffer.commit\"}" samples:0];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(FINAL_WAIT * NSEC_PER_SEC)),
                 _queue, ^{
                   [self endWith:VoxOpenAIStatusTailUnconfirmed];
                 });
}

- (void)sendPacket:(int)n {
  NSData *pcm = [_pending subdataWithRange:NSMakeRange(0, (NSUInteger)n * 2)];
  [_pending replaceBytesInRange:NSMakeRange(0, (NSUInteger)n * 2)
                      withBytes:NULL
                         length:0];
  [self send:[NSString stringWithFormat:
                           @"{\"type\":\"input_audio_buffer.append\","
                           @"\"audio\":\"%@\"}",
                           [pcm base64EncodedStringWithOptions:0]]
      samples:n];
}

- (void)send:(NSString *)json samples:(int)n {
  _inFlight += n;
  _uploaded += n;
  NSURLSessionWebSocketMessage *m =
      [[NSURLSessionWebSocketMessage alloc] initWithString:json];
  [_task sendMessage:m
      completionHandler:^(NSError *error) {
        self->_inFlight -= n;
        if (error)
          [self endWith:VoxOpenAIStatusNetwork];
      }];
}

/* ------------------------------------------------------------- events -- */

static const char *string_field(id dict, NSString *name) {
  if (![dict isKindOfClass:[NSDictionary class]])
    return NULL;
  id v = dict[name];
  return [v isKindOfClass:[NSString class]] ? [v UTF8String] : NULL;
}

- (void)receive {
  [_task receiveMessageWithCompletionHandler:^(
             NSURLSessionWebSocketMessage *m, NSError *error) {
    if (self->_ended)
      return;
    if (error) {
      [self endWith:VoxOpenAIStatusNetwork];
      return;
    }
    if (m.type == NSURLSessionWebSocketMessageTypeString)
      [self handle:m.string];
    [self receive];
  }];
}

- (void)handle:(NSString *)message {
  id ev = [NSJSONSerialization
      JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding]
                 options:0
                   error:nil];
  const char *type = string_field(ev, @"type");
  if (!type)
    return;
  const char *item = string_field(ev, @"item_id");
  if (strcmp(type, "session.updated") == 0) {
    _configured = YES;
    [self pump];
  } else if (strcmp(type,
                    "conversation.item.input_audio_transcription.delta") == 0) {
    const char *delta = string_field(ev, @"delta");
    if (delta)
      [self type:vox_text_delta(&_text, item, delta)];
  } else if (strcmp(type,
                    "conversation.item.input_audio_transcription.completed") ==
             0) {
    const char *transcript = string_field(ev, @"transcript");
    if (transcript)
      [self type:vox_text_final(&_text, item, transcript)];
    if (_finishing)
      [self endWith:VoxOpenAIStatusOK];
  } else if (strcmp(type,
                    "conversation.item.input_audio_transcription.failed") ==
             0) {
    if (_finishing)
      [self endWith:VoxOpenAIStatusTailUnconfirmed];
  } else if (strcmp(type, "error") == 0) {
    const char *code = string_field(ev[@"error"], @"code");
    [self endWith:code && strcmp(code, "invalid_api_key") == 0
                      ? VoxOpenAIStatusKey
                      : VoxOpenAIStatusRejected];
  }
}

/* Takes ownership of `utf8` (malloc'd, may be NULL). */
- (void)type:(char *)utf8 {
  if (!utf8)
    return;
  NSString *text = @(utf8);
  free(utf8);
  void (^onText)(NSString *) = _onText;
  dispatch_async(dispatch_get_main_queue(), ^{
    onText(text);
  });
}

/* The only way out. Runs once; afterwards feed, finish and events are ignored. */
- (void)endWith:(VoxOpenAIStatus)status {
  if (_ended)
    return;
  _ended = YES;
  [_task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                      reason:nil];
  [_urlSession invalidateAndCancel];
  vox_text_free(&_text);
  _pending = nil;
  void (^onDone)(VoxOpenAIStatus) = _onDone;
  _onText = nil; /* the blocks may hold whoever holds this session */
  _onDone = nil;
  dispatch_async(dispatch_get_main_queue(), ^{
    onDone(status);
  });
}

/* --------------------------------------------------- socket lifecycle -- */

- (void)URLSession:(NSURLSession *)session
          webSocketTask:(NSURLSessionWebSocketTask *)task
    didOpenWithProtocol:(NSString *)protocol {
  (void)session;
  (void)task;
  (void)protocol;
  if (_ended)
    return;
  [self send:_sessionUpdate samples:0];
  [self receive];
}

- (void)URLSession:(NSURLSession *)session
       webSocketTask:(NSURLSessionWebSocketTask *)task
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)code
              reason:(NSData *)reason {
  (void)session;
  (void)task;
  (void)code;
  (void)reason;
  [self endWith:VoxOpenAIStatusNetwork];
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  (void)session;
  (void)error;
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)task.response;
  BOOL unauthorized = [http isKindOfClass:[NSHTTPURLResponse class]] &&
                      http.statusCode == 401;
  [self endWith:unauthorized ? VoxOpenAIStatusKey : VoxOpenAIStatusNetwork];
}

@end
