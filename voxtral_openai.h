/*
 * voxtral_openai.h - OpenAI realtime transcription session
 *
 * One session is one dictation: it streams microphone audio that passes the
 * silence gate to OpenAI and hands back text to type as it arrives.
 */

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
