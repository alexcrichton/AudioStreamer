//
//  AudioStreamer.m
//  StreamingAudioPlayer
//
//  Created by Matt Gallagher on 27/09/08.
//  Copyright 2008 Matt Gallagher. All rights reserved.
//
//  This software is provided 'as-is', without any express or implied
//  warranty. In no event will the authors be held liable for any damages
//  arising from the use of this software. Permission is granted to anyone to
//  use this software for any purpose, including commercial applications, and to
//  alter it and redistribute it freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//     claim that you wrote the original software. If you use this software
//     in a product, an acknowledgment in the product documentation would be
//     appreciated but is not required.
//  2. Altered source versions must be plainly marked as such, and must not be
//     misrepresented as being the original software.
//  3. This notice may not be removed or altered from any source
//     distribution.
//

/* This file has been heavily modified since its original distribution by
 * Alex Crichton for the Hermes project */

#import "AudioStreamer.h"

#define BitRateEstimationMinPackets 50

/* Defaults */
#define kDefaultNumAQBufs 256
#define kDefaultAQDefaultBufSize 8192
#define kDefaultNumAQBufsToStart 32
#define kDefaultAudioFileType kAudioFileMP3Type

/* CHECK_ERR */
#define _CHECK_ERR_NORET(err, code, reasonStr) {                                 \
    if (err) { [self failWithErrorCode:code reason:reasonStr]; return; }        \
}
#define _CHECK_ERR_RET(err, code, reasonStr, retVal) {                           \
    if (err) { [self failWithErrorCode:code reason:reasonStr]; return retVal; } \
}
#define _CHECK_ERR_X(x, err, code, reasonStr, retVal, FUNC, ...) FUNC
#define CHECK_ERR(...) _CHECK_ERR_X(,##__VA_ARGS__, _CHECK_ERR_RET(__VA_ARGS__), _CHECK_ERR_NORET(__VA_ARGS__))

/* ASSERT_ERR */
#ifndef NDEBUG
#define ASSERT_ERR(cond, ...) \
  do {\
    if (!(cond)) {\
      NSString *reason = [NSString stringWithFormat:@"Assertion failure: %s on line %@:%d. %@",\
                                                      #cond,\
                                                      [[NSString stringWithUTF8String:__FILE__] lastPathComponent],\
                                                      __LINE__,\
                                                      [NSString stringWithFormat:@"" __VA_ARGS__]];\
      LOG_FATAL(@"%@", reason);\
      [[NSException exceptionWithName:NSInternalInconsistencyException reason:reason userInfo:nil] raise];\
    }\
  } while(0)
#else
#define ASSERT_ERR(cond, ...) \
  do {\
    if (!(cond)) {\
      NSString *reason = [NSString stringWithFormat:@"Assertion failure: %s on line %@:%d. %@",\
                                                      #cond,\
                                                      [[NSString stringWithUTF8String:__FILE__] lastPathComponent],\
                                                      __LINE__,\
                                                      [NSString stringWithFormat:@"" __VA_ARGS__]];\
      LOG_FATAL(@"%@", reason);\
    }\
  } while(0)
#endif

/* Logging */
#define LOG(lvl, fmt, args...)\
  do {\
    if (lvl <= [self logLevel]) {\
      NSString *msg = [NSString stringWithFormat:@"%s " fmt, __PRETTY_FUNCTION__, ##args];\
      if ([self logHandler])\
        [self logHandler](msg);\
      else\
        NSLog(@"%@", msg);\
    }\
  } while (0)
#define LOG_FATAL(fmt, args...) LOG(AS_LOG_LEVEL_FATAL, fmt, ##args)
#define LOG_ERROR(fmt, args...) LOG(AS_LOG_LEVEL_ERROR, fmt, ##args)
#define LOG_WARN(fmt, args...) LOG(AS_LOG_LEVEL_WARN, fmt, ##args)
#define LOG_INFO(fmt, args...) LOG(AS_LOG_LEVEL_INFO, fmt, ##args)
#define LOG_DEBUG(fmt, args...) LOG(AS_LOG_LEVEL_DEBUG, fmt, ##args)
#define LOG_VERBOSE(fmt, args...) LOG(AS_LOG_LEVEL_VERBOSE, fmt, ##args)

typedef NS_ENUM(NSUInteger, AudioStreamerProxyType) {
  AS_PROXY_SYSTEM = 0,
  AS_PROXY_SOCKS,
  AS_PROXY_HTTP,
};

typedef NS_ENUM(NSUInteger, AudioStreamerID3ParserState) {
  ID3_STATE_INITIAL = 0,
  ID3_STATE_READY_TO_PARSE,
  ID3_STATE_PARSED
};

typedef NS_OPTIONS(NSUInteger, AudioStreamerID3FlagInfo) {
  ID3_FLAG_UNSYNC = (1 << 0),
  ID3_FLAG_EXTENDED_HEADER = (1 << 1)
};

typedef struct queued_vbr_packet {
  AudioStreamPacketDescription desc;
  struct queued_vbr_packet *next;
  char data[];
} queued_vbr_packet_t;

typedef struct queued_cbr_packet {
  struct queued_cbr_packet *next;
  UInt32 byteSize;
  char data[];
} queued_cbr_packet_t;

typedef struct buffer {
  AudioStreamPacketDescription packetDescs[kAQMaxPacketDescs];
  AudioQueueBufferRef ref;
  UInt32 packetCount;
  UInt32 packetStart;
  bool inuse;
} buffer_t;

/* Errors, not an 'extern' */
NSString * const ASErrorDomain = @"com.alexcrichton.audiostreamer";

/* Woohoo, actual implementation now! */
@implementation AudioStreamer

/* Converts a given OSStatus to a friendly string.
 * The return value should be freed when done */
static char* OSStatusToStr(OSStatus status) {
  char *str = calloc(7, sizeof(char));
  *(UInt32 *)(str + 1) = CFSwapInt32HostToBig((uint32_t)status);
  if (isprint(str[1]) && isprint(str[2]) && isprint(str[3]) && isprint(str[4])) {
    str[0] = str[5] = '\'';
    str[6] = '\0';
  } else if (status > -200000 && status < 200000) {
    free(str);
    size_t needed = (size_t)snprintf(NULL, 0, "%d", (int)status);
    str = malloc(needed+1);
    sprintf(str, "%d", (int)status);
  } else {
    free(str);
    size_t needed = (size_t)snprintf(NULL, 0, "0x%x", (int)status);
    str = malloc(needed+1);
    sprintf(str, "0x%x", (int)status);
  }
  return str;
}

/* AudioFileStream callback when properties are available */
static void ASPropertyListenerProc(void *inClientData,
                            AudioFileStreamID inAudioFileStream,
                            AudioFileStreamPropertyID inPropertyID,
                            UInt32 *ioFlags) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inClientData;
  [streamer handlePropertyChangeForFileStream:inAudioFileStream
                         fileStreamPropertyID:inPropertyID
                                      ioFlags:ioFlags];
}

/* AudioFileStream callback when packets are available */
static void ASPacketsProc(void *inClientData, UInt32 inNumberBytes, UInt32
                   inNumberPackets, const void *inInputData,
                   AudioStreamPacketDescription  *inPacketDescriptions) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inClientData;
  [streamer handleAudioPackets:inInputData
                   numberBytes:inNumberBytes
                 numberPackets:inNumberPackets
            packetDescriptions:inPacketDescriptions];
}

/* AudioQueue callback notifying that a buffer is done, invoked on AudioQueue's
 * own personal threads, not the main thread */
static void ASAudioQueueOutputCallback(void *inClientData, AudioQueueRef inAQ,
                                AudioQueueBufferRef inBuffer) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inClientData;
  [streamer handleBufferCompleteForQueue:inAQ buffer:inBuffer];
}

/* AudioQueue callback that a property has changed, invoked on AudioQueue's own
 * personal threads like above */
static void ASAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ,
                                   AudioQueuePropertyID inID) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inUserData;
  [streamer handlePropertyChangeForQueue:inAQ propertyID:inID];
}

/* CFReadStream callback when an event has occurred */
static void ASReadStreamCallBack(CFReadStreamRef aStream, CFStreamEventType eventType,
                          void* inClientInfo) {
  AudioStreamer *streamer = (__bridge AudioStreamer *)inClientInfo;
  [streamer handleReadFromStream:aStream eventType:eventType];
}

/* Private method. Developers should call +[AudioStreamer streamWithURL:] */
- (instancetype)initWithURL:(NSURL*)url {
  if ((self = [super init])) {
    _url = url;
    _bufferCount  = kDefaultNumAQBufs;
    _bufferSize = kDefaultAQDefaultBufSize;
    _bufferFillCountToStart = kDefaultNumAQBufsToStart;
    _timeoutInterval = 10;
    _playbackRate = 1.0f;
#if defined(DEBUG)
    _logLevel = AS_LOG_LEVEL_INFO;
#else
    _logLevel = AS_LOG_LEVEL_ERROR;
#endif
  }
  return self;
}

+ (instancetype)streamWithURL:(NSURL*)url{
  assert(url != nil);
  return [[self alloc] initWithURL:url];
}

- (void)dealloc {
  [self stop];
  assert(queued_vbr_head == NULL);
  assert(queued_vbr_tail == NULL);
  assert(queued_cbr_head == NULL);
  assert(queued_cbr_tail == NULL);
  assert(timeout == nil);
  assert(buffers == NULL);
}

- (void)setHTTPProxy:(NSString*)host port:(int)port {
  proxyHost = host;
  proxyPort = port;
  proxyType = AS_PROXY_HTTP;
}

- (void)setSOCKSProxy:(NSString*)host port:(int)port {
  proxyHost = host;
  proxyPort = port;
  proxyType = AS_PROXY_SOCKS;
}

- (BOOL)setVolume:(float)volume {
  if (audioQueue != NULL) {
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, volume);
    return YES;
  }
  return NO;
}

- (BOOL)isPlaying {
  return state_ == AS_PLAYING;
}

- (BOOL)isPaused {
  return state_ == AS_PAUSED;
}

- (BOOL)isWaiting {
  return state_ == AS_WAITING_FOR_DATA ||
         state_ == AS_WAITING_FOR_QUEUE_TO_START;
}

- (BOOL)isDone {
  return state_ == AS_DONE || state_ == AS_STOPPED;
}

- (AudioStreamerDoneReason)doneReason {
  switch (state_) {
    case AS_STOPPED:
      return AS_DONE_STOPPED;
    case AS_DONE:
      if (_error) {
        return AS_DONE_ERROR;
      } else {
        return AS_DONE_EOF;
      }
    default:
      break;
  }
  return AS_NOT_DONE;
}

- (BOOL)isSeekable {
  double tmp;
  return seekable && [self duration:&tmp] && [self calculatedBitRate:&tmp] && tmp != 0.0;
}

- (BOOL)start {
  if (stream != NULL) return NO;
  assert(audioQueue == NULL);
  assert(state_ == AS_INITIALIZED);
  [self openReadStream];
  if (![self isDone]) {
    timeout = [NSTimer scheduledTimerWithTimeInterval:_timeoutInterval
                                               target:self
                                             selector:@selector(checkTimeout)
                                             userInfo:nil
                                              repeats:YES];
  }
  return YES;
}

- (BOOL)pause {
  if (state_ != AS_PLAYING) return NO;
  assert(audioQueue != NULL);
  OSStatus osErr = AudioQueuePause(audioQueue);
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_PAUSE_FAILED, [[self class] descriptionForAQErrorCode:osErr], NO);
  queuePaused = true;
  [self setState:AS_PAUSED];
  return YES;
}

- (BOOL)play {
  if (state_ != AS_PAUSED) return NO;
  assert(audioQueue != NULL);
  [self startAudioQueue];
  return YES;
}

- (void)stop {
  if (state_ == AS_STOPPED) return; // Already stopped.

  AudioStreamerState prevState = state_;
  if (state_ != AS_DONE) {
    // Delay notification to the end to avoid race conditions
    [self setState:AS_STOPPED shouldNotify:NO];
  }

  [timeout invalidate];
  timeout = nil;

  /* Clean up our streams */
  [self closeReadStream];
  if (audioFileStream && !isParsing) {
    [self closeFileStream];
  }
  if (audioQueue) {
    AudioQueueStop(audioQueue, true);
    OSStatus osErr = AudioQueueDispose(audioQueue, true);
    ASSERT_ERR(!osErr, @"AudioQueueDispose returned error \"%@\"", [[self class] descriptionForAQErrorCode:osErr]);
    audioQueue = nil;
  }
  if (buffers != NULL) {
    for (UInt32 i = 0; i < _bufferCount; i++) {
      free(buffers[i]);
    }
    free(buffers);
    buffers = NULL;
  }

  _httpHeaders     = nil;
  bytesFilled      = 0;
  packetsFilled    = 0;
  seekByteOffset   = 0;
  packetBufferSize = 0;

  if (prevState != state_) {
    [self notifyStateChange];
  }
}

- (BOOL)seekToTime:(double)newSeekTime {
  if (!seekable) return NO;

  double bitrate;
  double duration;
  if (![self calculatedBitRate:&bitrate]) return NO;
  if (![self duration:&duration]) return NO;
  if (bitrate == 0.0 || fileLength <= 0) {
    return NO;
  }
  assert(!seeking);
  seeking = true;

  //
  // Store the old time from the audio queue and the time that we're seeking
  // to so that we'll know the correct time progress after seeking.
  //
  seekTime = newSeekTime;

  //
  // For later
  //
  OSStatus osErr;

  //
  // Attempt to align the seek with a packet boundary
  //
  SInt64 seekPacket = 0;
  double packetDuration = _streamDescription.mFramesPerPacket / _streamDescription.mSampleRate;
  if (packetDuration > 0 && vbr) {
    seekPacket = (SInt64)floor(newSeekTime / packetDuration);
  } else if (!vbr) {
    seekPacket = (SInt64)((bitrate / 8.0) * newSeekTime);
  }

  if (totalAudioPackets != 1000000 && (UInt64)(seekPacket + 5) >= totalAudioPackets) {
    // Too little data to play anything useful
    [self setState:AS_DONE];
    return YES;
  }

  bool foundCachedPacket = false;
  bool foundQueuedPacket = false;
  if ((processedPacketsCount - 1) < (UInt64)seekPacket) {
    queued_vbr_packet_t *cur_vbr = queued_vbr_head;
    queued_cbr_packet_t *cur_cbr = queued_cbr_head;
    for (UInt32 i = 0; cur_vbr != NULL || cur_cbr != NULL; i++) {
      if ((processedPacketsCount + i) == (UInt64)seekPacket) {
        foundCachedPacket = true;
        break;
      }
      if (cur_vbr != NULL) {
        queued_vbr_packet_t *tmp_vbr = cur_vbr->next;
        cur_vbr = tmp_vbr;
      } else if (cur_cbr != NULL) {
        queued_cbr_packet_t *tmp_cbr = cur_cbr->next;
        cur_cbr = tmp_cbr;
      }
    }
  } else if ((UInt64)seekPacket < audioPacketsReceived && seekPacket != 0) {
    foundQueuedPacket = true;
  }

  if (foundCachedPacket || foundQueuedPacket) {
    CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    unscheduled = true;
    rescheduled = false;
  }

  buffer_t **oldBuffers;
  if (foundQueuedPacket) {
    oldBuffers = malloc(_bufferCount * sizeof(buffer_t*));
    CHECK_ERR(oldBuffers == NULL, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, @"", NO);
    memcpy(oldBuffers, buffers, _bufferCount * sizeof(AudioQueueBufferRef));
  }

  waitingOnBuffer = false;

  /* Stop audio for now */
  osErr = AudioQueueStop(audioQueue, true);
  if (osErr) {
    if (foundQueuedPacket) {
      free(oldBuffers);
    }
    seeking = false;
    [self failWithErrorCode:AS_AUDIO_QUEUE_STOP_FAILED reason:[[self class] descriptionForAQErrorCode:osErr]];
    return NO;
  }

  if (foundCachedPacket) {
    UInt32 packetsRemoved = 0;
    UInt32 bytesRemoved = 0;
    queued_vbr_packet_t *cur_vbr = queued_vbr_head;
    queued_cbr_packet_t *cur_cbr = queued_cbr_head;
    for (UInt32 i = 0; cur_vbr != NULL || cur_cbr != NULL; i++) {
      if ((processedPacketsCount + i) == (UInt64)seekPacket) {
        break;
      }
      if (cur_vbr != NULL) {
        queued_vbr_packet_t *tmp_vbr = cur_vbr->next;
        free(cur_vbr);
        cur_vbr = tmp_vbr;
        packetsRemoved++;
      } else if (cur_cbr != NULL) {
        queued_cbr_packet_t *tmp_cbr = cur_cbr->next;
        bytesRemoved += cur_cbr->byteSize;
        free(cur_cbr);
        cur_cbr = tmp_cbr;
      }
    }
    queued_vbr_head = cur_vbr;
    queued_cbr_head = cur_cbr;

    processedPacketsCount += (vbr ? packetsRemoved : bytesRemoved);

    //discontinuous = true;
    [self enqueueCachedData];
    waitingOnBuffer = (queued_vbr_head != NULL || queued_cbr_head != NULL);
    if (packetDuration > 0 && vbr) {
      seekTime = processedPacketsCount * packetDuration;
    } else if (!vbr) {
      seekTime = processedPacketsCount * 8.0 / bitrate;
    }
    if (![self startAudioQueue]) return NO;

    CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    rescheduled = true;

    seeking = false;
    return YES;
  } else if (foundQueuedPacket) {
    UInt32 seekPacketIdx = _bufferCount + 1;
    UInt32 endPacketIdx = _bufferCount + 1;
    SInt64 startPacket = seekPacket;
    SInt64 endPacket = seekPacket;
    UInt32 nextFillBuffer = fillBufferIndex +1;
    if (nextFillBuffer >= _bufferCount) nextFillBuffer = 0;
    UInt32 i = nextFillBuffer;
    UInt32 last = 0;
    while (i != fillBufferIndex) {
      UInt32 packetStart = oldBuffers[i]->packetStart;
      UInt32 packetCount = oldBuffers[i]->packetCount;
      if (packetCount != 0) {
        UInt32 packetEnd = packetStart + packetCount - 1;
        last = packetEnd;
        if (packetEnd >= seekPacket) {
          if (packetEnd >= endPacket) {
            endPacketIdx = i;
            endPacket = packetEnd;
          }
          if (packetStart <= startPacket) {
            seekPacketIdx = i;
            startPacket = packetStart;
          }
        }
      }
      i++;
      if (i >= _bufferCount) i = 0;
    }
    if (seekPacketIdx != (_bufferCount + 1)) {
      i = seekPacketIdx;
      UInt32 nextBuffer = endPacketIdx + 1;
      if (nextBuffer >= _bufferCount) nextBuffer = 0;
      bool start = true;
      while (i != nextBuffer || start) {
        start = false;
        UInt32 packetStart = oldBuffers[i]->packetStart;
        UInt32 packetCount = oldBuffers[i]->packetCount;
        if (packetCount > 0) {
          UInt32 packetEnd = packetStart + oldBuffers[i]->packetCount - 1;
          buffers[i]->inuse = (packetEnd >= seekPacket);
        }
        i++;
        if (i >= _bufferCount) i = 0;
      }
      i = seekPacketIdx;
      buffersUsed = 0;
      while (buffers[i]->inuse) {
        AudioQueueBufferRef fillBuf = oldBuffers[i]->ref;

        if (vbr) {
          osErr = AudioQueueEnqueueBuffer(audioQueue, fillBuf, oldBuffers[i]->packetCount,
                                          oldBuffers[i]->packetDescs);
        } else {
          osErr = AudioQueueEnqueueBuffer(audioQueue, fillBuf, 0, NULL);
        }
        if (osErr) {
          free(oldBuffers);
          [self failWithErrorCode:AS_AUDIO_QUEUE_ENQUEUE_FAILED reason:[[self class] descriptionForAQErrorCode:osErr]];
          return NO;
        }

        buffersUsed++;
        i++;
        if (i >= _bufferCount) i = 0;
        if (buffersUsed == _bufferCount) break;
      }
      fillBufferIndex = i;
      processedPacketsCount -= packetsFilled;
      packetsFilled = bytesFilled = 0;
      [self enqueueCachedData];
      waitingOnBuffer = (queued_vbr_head != NULL || queued_cbr_head != NULL);
      if (packetDuration > 0 && vbr) {
        seekTime = oldBuffers[seekPacketIdx]->packetStart * packetDuration;
      } else if (!vbr) {
        seekTime = oldBuffers[seekPacketIdx]->packetStart * 8.0 / bitrate;
      }

      free(oldBuffers);

      if (![self startAudioQueue]) return NO;

      CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
      rescheduled = true;

      seeking = false;
      return YES;
    }
    [self closeReadStream];
    [self setState:AS_WAITING_FOR_DATA];
    free(oldBuffers);
  }

  processedPacketsCount = (UInt32)seekPacket;
  audioPacketsReceived = (UInt64)seekPacket;

  if (packetDuration > 0 && !vbr) {
    seekPacket = (SInt64)floor(newSeekTime / packetDuration);
  }

  //
  // Calculate the byte offset for seeking
  //
  seekByteOffset = dataOffset + (UInt64)((newSeekTime / duration) * (fileLength - dataOffset));

  //
  // Attempt to leave 1 useful packet at the end of the file (although in
  // reality, this may still seek too far if the file has a long trailer).
  //
  if (seekByteOffset > fileLength - 2 * packetBufferSize) {
    seekByteOffset = fileLength - 2 * packetBufferSize;
  }

  if (packetDuration > 0 && bitrate > 0) {
    UInt32 ioFlags = 0;
    SInt64 packetAlignedByteOffset;
    osErr = AudioFileStreamSeek(audioFileStream, seekPacket, &packetAlignedByteOffset, &ioFlags);
    if (!osErr && !(ioFlags & kAudioFileStreamSeekFlag_OffsetIsEstimated)) {
      if (!bitrateEstimated) {
        seekTime = packetAlignedByteOffset * 8.0 / bitrate;
      }
      seekByteOffset = (UInt64)packetAlignedByteOffset + dataOffset;
      if (seekByteOffset >= fileLength - 1) {
        // End of the file. We're done here.
        [self setState:AS_DONE];
        return YES;
      }
    }
  }

  [self closeReadStream];
  [self setState:AS_WAITING_FOR_DATA];

  fillBufferIndex = 0;
  packetsFilled = 0;
  bytesFilled = 0;
  audioBytesReceived = 0;
  waitingOnBuffer = (queued_vbr_head != NULL || queued_cbr_head != NULL);

  /* Open a new stream with a new offset */
  BOOL ret = [self openReadStream];
  seeking = false;
  return ret;
}

- (BOOL)seekByDelta:(double)seekTimeDelta {
  double p = 0;
  if ([self progress:&p]) {
    return [self seekToTime:p + seekTimeDelta];
  }
  return NO;
}

- (BOOL)progress:(double*)ret {
  double sampleRate = _streamDescription.mSampleRate;
  if (state_ == AS_STOPPED) {
    *ret = lastProgress;
    return YES;
  }
  if (sampleRate <= 0 || (state_ != AS_PLAYING && state_ != AS_PAUSED))
    return NO;

  AudioTimeStamp queueTime;
  Boolean discontinuity;
  OSStatus osErr = AudioQueueGetCurrentTime(audioQueue, NULL, &queueTime, &discontinuity);
  if (osErr) {
    return NO;
  }

  double progress = seekTime + queueTime.mSampleTime / sampleRate;
  if (progress < 0.0) {
    progress = 0.0;
  }

  lastProgress = progress;
  *ret = progress;
  return YES;
}

- (BOOL)bufferProgress:(double*)ret {
  if (state_ != AS_PLAYING && state_ != AS_PAUSED)
    return NO;

  double duration;
  if (![self duration:&duration]) return NO;

  *ret = (double)(audioBytesReceived + seekByteOffset) / (double)fileLength * duration;
  return YES;
}

- (BOOL)calculatedBitRate:(double*)rate {
  if (icyBitrate > 0)
  {
    *rate = icyBitrate;
    bitrateEstimated = false;
    return YES;
  }
  else if (vbr)
  {
    double packetsPerSec = _streamDescription.mSampleRate / _streamDescription.mFramesPerPacket;
    if (packetsPerSec <= 0) return NO;

    // Method one - exact
    UInt32 bitrate;
    UInt32 bitrateSize = sizeof(bitrate);
    OSStatus status = AudioFileStreamGetProperty(audioFileStream,
                                                 kAudioFileStreamProperty_BitRate,
                                                 &bitrateSize, &bitrate);
    if (status == 0) {
      *rate = bitrate;
      bitrateEstimated = false;
      return YES;
    }

    // Method two - average
    Float64 bytesPerPacket;
    UInt32 bytesPerPacketSize = sizeof(bytesPerPacket);
    status = AudioFileStreamGetProperty(audioFileStream,
                                        kAudioFileStreamProperty_AverageBytesPerPacket,
                                        &bytesPerPacketSize, &bytesPerPacket);
    if (status == 0) {
      *rate = 8.0 * bytesPerPacket * packetsPerSec;
      bitrateEstimated = true;
      return YES;
    }

    // Method three (similar to two)
    if (processedPacketsCount > BitRateEstimationMinPackets) {
      double averagePacketByteSize = processedPacketsSizeTotal /
                                      (double)processedPacketsCount;
      /* bits/byte x bytes/packet x packets/sec = bits/sec */
      *rate = averagePacketByteSize;
      bitrateEstimated = true;
      return YES;
    }
    return NO;
  }
  else
  {
    *rate = 8.0 * _streamDescription.mSampleRate * _streamDescription.mBytesPerPacket * _streamDescription.mFramesPerPacket;
    bitrateEstimated = false;
    return YES;
  }
}

- (BOOL)duration:(double*)ret {
  if (fileLength == 0) return NO;

  double packetDuration = _streamDescription.mFramesPerPacket / _streamDescription.mSampleRate;
  if (packetDuration <= 0) return NO;

  // Method one
  UInt64 packetCount;
  UInt32 packetCountSize = sizeof(packetCount);
  OSStatus status = AudioFileStreamGetProperty(audioFileStream,
                                               kAudioFileStreamProperty_AudioDataPacketCount,
                                               &packetCountSize, &packetCount);
  if (status != 0) {
    // Method two
    packetCount = totalAudioPackets;
  }

  if (packetCount == 1000000)
  {
    // Method three
    double calcBitrate;
    if (![self calculatedBitRate:&calcBitrate]) return NO;
    if (calcBitrate == 0) return NO;
    *ret = (fileLength - dataOffset) / (calcBitrate * 0.125);
  }
  else
  {
    *ret = packetCount * packetDuration;
  }

  return YES;
}

- (BOOL)fadeTo:(float)volume duration:(float)duration {
  if (audioQueue != NULL) {
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_VolumeRampTime, duration);
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_Volume, volume);
    return YES;
  }
  return NO;
}

- (BOOL)fadeInDuration:(float)duration {
  //-- set the gain to 0.0, so we can call this method just after creating the streamer
  [self setVolume:0.0];
  return [self fadeTo:1.0 duration:duration];
}

- (BOOL)fadeOutDuration:(float)duration {
  return [self fadeTo:0.0 duration:duration];
}

#pragma mark - Internal methods

+ (NSString *)descriptionForASErrorCode:(AudioStreamerErrorCode)anErrorCode {
  switch (anErrorCode) {
    case AS_NETWORK_CONNECTION_FAILED:
      return @"Network connection failure";
    case AS_FILE_STREAM_GET_PROPERTY_FAILED:
      return @"File stream get property failed";
    case AS_FILE_STREAM_SET_PROPERTY_FAILED:
      return @"File stream set property failed";
    case AS_FILE_STREAM_PARSE_BYTES_FAILED:
      return @"Parse bytes failed";
    case AS_FILE_STREAM_OPEN_FAILED:
      return @"Failed to open file stream";
    case AS_AUDIO_DATA_NOT_FOUND:
      return @"No audio data found";
    case AS_AUDIO_QUEUE_CREATION_FAILED:
      return @"Audio queue creation failed";
    case AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED:
      return @"Audio queue buffer allocation failed";
    case AS_AUDIO_QUEUE_ENQUEUE_FAILED:
      return @"Queueing of audio buffer failed";
    case AS_AUDIO_QUEUE_ADD_LISTENER_FAILED:
      return @"Failed to add listener to audio queue";
    case AS_AUDIO_QUEUE_START_FAILED:
      return @"Failed to start the audio queue";
    case AS_AUDIO_QUEUE_PAUSE_FAILED:
      return @"Failed to pause the audio queue";
    case AS_AUDIO_QUEUE_BUFFER_MISMATCH:
      return @"Audio queue buffer mismatch";
    case AS_AUDIO_QUEUE_STOP_FAILED:
      return @"Audio queue stop failed";
    case AS_AUDIO_QUEUE_FLUSH_FAILED:
      return @"Failed to flush the audio queue";
    case AS_AUDIO_BUFFER_TOO_SMALL:
      return @"Audio buffer too small";
    case AS_TIMED_OUT:
      return @"Timed out";
  }
}

+ (NSString *)descriptionForAFSErrorCode:(OSStatus)osErr {
  switch (osErr) {
    case kAudioFileStreamError_BadPropertySize:
      return @"The size for an internal property call to the file stream was incorrect. This is a bug.";
    case kAudioFileStreamError_DataUnavailable:
      return @"The file stream could not get data for an internal property call. This is a bug.";
    case kAudioFileStreamError_DiscontinuityCantRecover:
      return @"The file stream reached a state where it could not recover.";
    case kAudioFileStreamError_IllegalOperation:
      return @"An illegal operation on the file stream was attempted. This is a bug.";
    case kAudioFileStreamError_InvalidFile:
      return @"The given HTTP stream is invalid. Perhaps an unsupported format?";
    case kAudioFileStreamError_InvalidPacketOffset:
      return @"The packet offset for the file stream is invalid. The HTTP stream could be malformed.";
    case kAudioFileStreamError_NotOptimized:
      return @"The given HTTP stream is not optimized for streaming.";
    case kAudioFileStreamError_UnspecifiedError:
      return @"An unknown error occurred in the file stream.";
    case kAudioFileStreamError_UnsupportedDataFormat:
    case kAudioFileStreamError_UnsupportedFileType:
      return @"The given HTTP stream is of an unsupported format.";
    case kAudioFileStreamError_UnsupportedProperty:
      return @"An internal property call is unsupported for this stream. This is a bug.";
    case kAudioFileStreamError_ValueUnknown:
      return @"An internal property call to the file stream could not retrieve a value. This is a bug.";
    default:
      break;
  }
  char *str = OSStatusToStr(osErr);
  NSString *ret = [NSString stringWithFormat:@"AudioFileStream error code %s", str];
  free(str);
  return ret;
}

+ (NSString *)descriptionForAQErrorCode:(OSStatus)osErr {
  switch (osErr) {
    case kAudioQueueErr_BufferEmpty:
      return @"A buffer of data was generated but no audio was found.";
    // Not documented
    /*case kAudioQueueErr_BufferEnqueuedTwice:
      return @"A buffer of data was enqueued for play twice. This is a bug.";*/
    case kAudioQueueErr_BufferInQueue:
      return @"An attempt was made to dispose a buffer of data while it was enqueued for play. This is a bug.";
    case kAudioQueueErr_CannotStart:
      return @"The audio queue (player) encountered a problem and could not start.";
    case kAudioQueueErr_CodecNotFound:
      return @"A codec could not be found for the audio.";
    case kAudioQueueErr_DisposalPending:
      return @"An interaction on the audio queue (player) was made while it was being disposed. This is a bug.";
    case kAudioQueueErr_EnqueueDuringReset:
      return @"A buffer of data was enqueued for play while the audio queue (player) was stopping. This is a bug.";
    case kAudioQueueErr_InvalidBuffer:
      return @"An invalid buffer was passed to the audio queue (player). This is a bug.";
    case kAudioQueueErr_InvalidCodecAccess:
      return @"The codec for playback could not be accessed.";
    case kAudioQueueErr_InvalidDevice:
      return @"Hardware for playback could not be found.";
    case kAudioQueueErr_InvalidOfflineMode:
      return @"The audio queue (player) was in an incorrect mode for an operation. This is a bug.";
    case kAudioQueueErr_InvalidParameter:
      return @"An internal parameter call to the audio queue (player) was invalid. This is a bug.";
    case kAudioQueueErr_InvalidProperty:
      return @"An internal property call to the audio queue (player) was invalid. This is a bug.";
    case kAudioQueueErr_InvalidPropertySize:
      return @"The size for an internal property call to the audio queue (player) was incorrect. This is a bug.";
    case kAudioQueueErr_InvalidPropertyValue:
      return @"The value given to an internal property call to the audio queue (player) was invalid. This is a bug.";
    case kAudioQueueErr_InvalidQueueType:
      return @"The audio queue (player) type is incorrect for an operation. This is a bug.";
    case kAudioQueueErr_InvalidRunState:
      return @"The audio queue (player) was in an incorrect state for an operation. This is a bug.";
    // Not documented
    /*case kAudioQueueErr_InvalidTapContext:
      return @"???";*/
    /*case kAudioQueueErr_InvalidTapType:
      return @"???";*/
    case kAudioQueueErr_Permissions:
      return @"The audio queue (player) did not have sufficient permissions for an operation. This is a bug.";
    case kAudioQueueErr_PrimeTimedOut:
      return @"The audio queue (player) timed out during a prime call. This is a bug.";
    case kAudioQueueErr_QueueInvalidated:
      return @"The audio queue (player) was invalidated as the OS audio server died.";
    // OS X 10.8. Should never happen anyway
    /*case kAudioQueueErr_RecordUnderrun:
      return @"";*/
    // Not documented
    /*case kAudioQueueErr_TooManyTaps:
      return @"???";*/
    case kAudioFormatUnsupportedDataFormatError:
      return @"The audio queue (player) got data of a format that is unsupported.";
    // Can happen for AudioQueues for some reason
    case kAudioFileStreamError_IllegalOperation:
      return @"An illegal operation was attempted on the audio queue (player). Did you seek past the file end?";
    default:
      break;
  }
  char *str = OSStatusToStr(osErr);
  NSString *ret = [NSString stringWithFormat:@"AudioQueue error code %s", str];
  free(str);
  return ret;
}

//
// failWithErrorCode:reason:
//
// Sets the playback state to failed and logs the error.
//
// Parameters:
//    errorCode - the error condition
//    reason    - the error reason
//
- (void)failWithErrorCode:(AudioStreamerErrorCode)errorCode reason:(NSString*)reason
{
  [self failWithErrorCode:errorCode reason:reason shouldStop:YES];
}

//
// failWithErrorCode:reason:shouldStop:
//
// Sets the playback state to failed and logs the error.
//
// Parameters:
//    errorCode  - the error condition
//    reason     - the error reason
//    shouldStop - whether the stream should stop immediately or not
//
- (void)failWithErrorCode:(AudioStreamerErrorCode)errorCode reason:(NSString*)reason shouldStop:(BOOL)shouldStop {
  // Only set the error once.
  if (_error) {
    return;
  }

  assert(reason != nil);

  /* Attempt to save our last point of progress */
  [self progress:&lastProgress];

  LOG_ERROR(@"got an error: %@ (%@)", [[self class] descriptionForASErrorCode:errorCode], reason);

  NSDictionary *userInfo = @{NSLocalizedDescriptionKey:
                               NSLocalizedString([[self class] descriptionForASErrorCode:errorCode], nil),
                             NSLocalizedFailureReasonErrorKey:
                               NSLocalizedString(reason, nil)};
  _error = [NSError errorWithDomain:ASErrorDomain code:errorCode userInfo:userInfo];

  if (shouldStop)
  {
    [self setState:AS_DONE shouldNotify:NO]; // Delay notification to avoid race conditions
    [self stop];
    [self notifyStateChange];
  }
}

- (void)setState:(AudioStreamerState)aStatus {
  [self setState:aStatus shouldNotify:YES];
}

- (void)setState:(AudioStreamerState)aStatus shouldNotify:(BOOL)shouldNotify {
  LOG_INFO(@"transitioning to state:%tu", aStatus);

  if (state_ == aStatus) return;
  state_ = aStatus;

  if (shouldNotify)
    [self notifyStateChange];
}

- (void)notifyStateChange {
  __strong id <AudioStreamerDelegate> delegate = _delegate;
  if (delegate && [delegate respondsToSelector:@selector(streamerStatusDidChange:)]) {
    [delegate streamerStatusDidChange:self];
  }
}

/**
 * @brief Check the stream for a timeout, and trigger one if this is a timeout
 *        situation
 */
- (void)checkTimeout {
  /* Ignore if we're in the paused state */
  if (state_ == AS_PAUSED) return;
  /* If the read stream has been unscheduled and not rescheduled, then this tick
     is irrelevant because we're not trying to read data anyway */
  if (unscheduled && !rescheduled) return;
  /* If the read stream was unscheduled and then rescheduled, then we still
     discard this sample (not enough of it was known to be in the "scheduled
     state"), but we clear flags so we might process the next sample */
  if (rescheduled && unscheduled) {
    unscheduled = false;
    rescheduled = false;
    return;
  }

  /* events happened? no timeout. */
  if (events > 0) {
    events = 0;
    return;
  }

  [self failWithErrorCode:AS_TIMED_OUT
                   reason:[NSString stringWithFormat:@"No data was received in %d seconds while expecting data.", _timeoutInterval]
               shouldStop:[self isWaiting]];
}

//
// hintForFileExtension:
//
// Generates a first guess for the file type based on the file's extension
//
// Parameters:
//    fileExtension - the file extension
//
// returns a file type hint that can be passed to the AudioFileStream
//
+ (AudioFileTypeID)hintForFileExtension:(NSString *)fileExtension {
  fileExtension = [fileExtension lowercaseString];
  if ([fileExtension isEqual:@"mp3"]) {
    return kAudioFileMP3Type;
  } else if ([fileExtension isEqual:@"wav"] ||
             [fileExtension isEqual:@"wave"]) {
    return kAudioFileWAVEType;
  } else if ([fileExtension isEqual:@"aifc"]) {
    return kAudioFileAIFCType;
  } else if ([fileExtension isEqual:@"aiff"] ||
             [fileExtension isEqual:@"aif"]) {
    return kAudioFileAIFFType;
  } else if ([fileExtension isEqual:@"m4a"]) {
    return kAudioFileM4AType;
  } else if ([fileExtension isEqual:@"mp4"]) {
    return kAudioFileMPEG4Type;
  } else if ([fileExtension isEqual:@"caf"]) {
    return kAudioFileCAFType;
  } else if ([fileExtension isEqual:@"aac"]) {
    return kAudioFileAAC_ADTSType;
  } else if ([fileExtension isEqual:@"au"] ||
             [fileExtension isEqual:@"snd"]) {
    return kAudioFileNextType;
  } else if ([fileExtension isEqual:@"3gp"]) {
    return kAudioFile3GPType;
  } else if ([fileExtension isEqual:@"3g2"]) {
    return kAudioFile3GP2Type;
  }
  return 0;
}

/**
 * @brief Guess the file type based on the listed MIME type in the http response
 *
 * Based from:
 * https://github.com/DigitalDJ/AudioStreamer/blob/master/Classes/AudioStreamer.m
 */
+ (AudioFileTypeID)hintForMIMEType:(NSString*)mimeType {
  if ([mimeType isEqual:@"audio/mpeg"]) {
    return kAudioFileMP3Type;
  } else if ([mimeType isEqual:@"audio/vnd.wave"] ||
             [mimeType isEqual:@"audio/wav"] ||
             [mimeType isEqual:@"audio/wave"] ||
             [mimeType isEqual:@"audio/x-wav"]) {
    return kAudioFileWAVEType;
  } else if ([mimeType isEqual:@"audio/x-aiff"] ||
             [mimeType isEqual:@"audio/aiff"]) {
    return kAudioFileAIFFType;
  } else if ([mimeType isEqual:@"audio/x-m4a"] ||
             [mimeType isEqual:@"audio/m4a"]) {
    return kAudioFileM4AType;
  } else if ([mimeType isEqual:@"audio/mp4"]) {
    return kAudioFileMPEG4Type;
  } else if ([mimeType isEqual:@"audio/x-caf"]) {
    return kAudioFileCAFType;
  } else if ([mimeType isEqual:@"audio/aac"] ||
             [mimeType isEqual:@"audio/aacp"]) {
    return kAudioFileAAC_ADTSType;
  } else if ([mimeType isEqual:@"audio/basic"]) {
    return kAudioFileNextType;
  } else if ([mimeType isEqual:@"audio/3gpp"]) {
    return kAudioFile3GPType;
  } else if ([mimeType isEqual:@"audio/3gpp2"]) {
    return kAudioFile3GP2Type;
  }
  return 0;
}

/**
 * @brief Creates a new stream for reading audio data
 *
 * The stream is currently only compatible with remote HTTP sources. The stream
 * opened could possibly be seeked into the middle of the file, or have other
 * things like proxies attached to it.
 *
 * @return YES if the stream was opened, or NO if it failed to open
 */
- (BOOL)openReadStream {
  NSAssert(stream == NULL, @"Download stream already initialized");

  /* Create our GET request */
  CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL,
                                                        CFSTR("GET"),
                                                        (__bridge CFURLRef) _url,
                                                        kCFHTTPVersion1_1);
  /* ID3 support */
  id3ParserState = ID3_STATE_INITIAL;

  /* ICY metadata */
  CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Icy-MetaData"), CFSTR("1"));
  icyStream = false;
  icyChecked = false;
  icyMetaBytesRemaining = 0;
  icyDataBytesRead = 0;
  icyHeadersParsed = false;
  icyMetadata = nil;
  icyMetadataPacket = 0;
  icyPendingCurrentSong = nil;
  [self setCurrentSong:nil];

  /* When seeking to a time within the stream, we both already know the file
     length and the seekByteOffset will be set to know what to send to the
     remote server */
  if (fileLength > 0 && seekByteOffset > 0) {
    NSString *str = [NSString stringWithFormat:@"bytes=%lld-%lld",
                                               seekByteOffset, fileLength - 1];
    CFHTTPMessageSetHeaderFieldValue(message,
                                     CFSTR("Range"),
                                     (__bridge CFStringRef) str);
    discontinuous = vbr;
  }

  stream = CFReadStreamCreateForHTTPRequest(NULL, message);
  CFRelease(message);

  /* Follow redirection codes by default */
  CHECK_ERR(!CFReadStreamSetProperty(stream,
                                     kCFStreamPropertyHTTPShouldAutoredirect,
                                     kCFBooleanTrue),
            AS_FILE_STREAM_SET_PROPERTY_FAILED, @"", NO);

  /* Deal with proxies */
  switch (proxyType) {
    case AS_PROXY_HTTP: {
      CFDictionaryRef proxySettings;
      if ([[[_url scheme] lowercaseString] isEqualToString:@"https"]) {
        proxySettings = (__bridge CFDictionaryRef)
          [NSMutableDictionary dictionaryWithObjectsAndKeys:
            proxyHost, kCFStreamPropertyHTTPSProxyHost,
            @(proxyPort), kCFStreamPropertyHTTPSProxyPort,
            nil];
      } else {
        proxySettings = (__bridge CFDictionaryRef)
        [NSMutableDictionary dictionaryWithObjectsAndKeys:
          proxyHost, kCFStreamPropertyHTTPProxyHost,
          @(proxyPort), kCFStreamPropertyHTTPProxyPort,
          nil];
      }
      CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy,
                              proxySettings);
      break;
    }
    case AS_PROXY_SOCKS: {
      CFDictionaryRef proxySettings = (__bridge CFDictionaryRef)
        [NSMutableDictionary dictionaryWithObjectsAndKeys:
          proxyHost, kCFStreamPropertySOCKSProxyHost,
          @(proxyPort), kCFStreamPropertySOCKSProxyPort,
          nil];
      CFReadStreamSetProperty(stream, kCFStreamPropertySOCKSProxy,
                              proxySettings);
      break;
    }
    default:
    case AS_PROXY_SYSTEM: {
      CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
      CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPProxy, proxySettings);
      CFRelease(proxySettings);
      break;
    }
  }

  /* handle SSL connections */
  if ([[[_url scheme] lowercaseString] isEqualToString:@"https"]) {
    NSDictionary *sslSettings = @{
      (id)kCFStreamSSLLevel: (NSString*)kCFStreamSocketSecurityLevelNegotiatedSSL,
      (id)kCFStreamSSLValidatesCertificateChain:  @YES,
      (id)kCFStreamSSLPeerName:                   [NSNull null]
    };

    CFReadStreamSetProperty(stream, kCFStreamPropertySSLSettings,
                            (__bridge CFDictionaryRef) sslSettings);
  }

  [self setState:AS_WAITING_FOR_DATA];

  CHECK_ERR(!CFReadStreamOpen(stream), AS_FILE_STREAM_OPEN_FAILED, @"", NO);

  /* Set the callback to receive a few events, and then we're ready to
     schedule and go */
  CFStreamClientContext context = {0, (__bridge void*) self, NULL, NULL, NULL};
  CFReadStreamSetClient(stream,
                        kCFStreamEventHasBytesAvailable |
                          kCFStreamEventErrorOccurred |
                          kCFStreamEventEndEncountered,
                        ASReadStreamCallBack,
                        &context);
  CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(),
                                  kCFRunLoopCommonModes);

  return YES;
}

//
// handleReadFromStream:eventType:
//
// Reads data from the network file stream into the AudioFileStream
//
// Parameters:
//    aStream - the network file stream
//    eventType - the event which triggered this method
//
- (void)handleReadFromStream:(CFReadStreamRef)aStream
                   eventType:(CFStreamEventType)eventType {
  assert(aStream == stream);
  assert(!waitingOnBuffer || _bufferInfinite);
  events++;

  switch (eventType) {
    case kCFStreamEventErrorOccurred: {
      LOG_INFO(@"error");
      /* Deprecated. Will eventually be a local variable. */
      NSError *networkError = (__bridge_transfer NSError*) CFReadStreamCopyError(aStream);
      if (!_error) {
        if (buffersUsed != 0) {
          /* shouldStop = NO as we will retry connecting later */
          [self failWithErrorCode:AS_NETWORK_CONNECTION_FAILED reason:[networkError localizedDescription] shouldStop:NO];
        } else {
          [self failWithErrorCode:AS_NETWORK_CONNECTION_FAILED reason:[networkError localizedDescription] shouldStop:YES];
        }
      } else {
        /* We tried reconnecting but failed. Time to stop. */
        [self setState:AS_DONE shouldNotify:NO]; // Delay notification to avoid race conditions
        [self stop];
        [self notifyStateChange];
      }
      return;
    }
    case kCFStreamEventEndEncountered:
      LOG_INFO(@"end");
      [timeout invalidate];
      timeout = nil;

      /* Flush out extra data if necessary */
      if (bytesFilled) {
        /* Disregard return value because we're at the end of the stream anyway
           so there's no bother in pausing it */
        if ([self enqueueBuffer] < 0) return;
      }

      /* If we never received any packets, then we're done now */
      if (state_ == AS_WAITING_FOR_DATA) {
        if (buffersUsed > 0) {
          /* If we got some data, the stream was either short or interrupted early.
           * We have some data so go ahead and play that. */
          [self startAudioQueue];
        } else if ((seekByteOffset - dataOffset) != 0) {
          /* If a seek was performed, and no data came back, then we probably
             seeked to the end or near the end of the stream */
          [self setState:AS_DONE];
        } else {
          /* In other cases then we just hit an error */
          [self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND reason:@""];
        }
      }
      return;

    default:
      return;

    case kCFStreamEventHasBytesAvailable:
      break;
  }
  LOG_VERBOSE(@"data");

  CFHTTPMessageRef message = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
  CFIndex statusCode = CFHTTPMessageGetResponseStatusCode(message);

  if (statusCode >= 400) {
    [self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND
                     reason:[NSString stringWithFormat:@"Server returned HTTP %ld", statusCode]];
  }

  /* Read off the HTTP headers into our own class if we haven't done so */
  if (!_httpHeaders) {
    _httpHeaders = (__bridge_transfer NSDictionary *)CFHTTPMessageCopyAllHeaderFields(message);

    //
    // Only read the content length if we seeked to time zero, otherwise
    // we may only have a subset of the total bytes.
    //
    if ((seekByteOffset - dataOffset) == 0) {
      fileLength = (UInt64)[_httpHeaders[@"Content-Length"] longLongValue];
    }

    seekable = [_httpHeaders[@"Accept-Ranges"] caseInsensitiveCompare:@"bytes"] == NSOrderedSame;
  }

  CFRelease(message);

  OSStatus osErr;

  /* If we haven't yet opened up a file stream, then do so now */
  if (!audioFileStream) {
    /* If a file type wasn't specified, we have to guess */
    if (_fileType == 0) {
      _fileType = [[self class] hintForMIMEType:_httpHeaders[@"Content-Type"]];
      if (_fileType == 0) {
        _fileType = [[self class] hintForFileExtension:[[_url path] pathExtension]];
        if (_fileType == 0) {
          _fileType = kDefaultAudioFileType;
        }
      }
    }

    // create an audio file stream parser
    osErr = AudioFileStreamOpen((__bridge void*) self, ASPropertyListenerProc,
                                ASPacketsProc, _fileType, &audioFileStream);
    CHECK_ERR(osErr, AS_FILE_STREAM_OPEN_FAILED, [[self class] descriptionForAFSErrorCode:osErr]);
  }

  UInt32 bufferSize = (_bufferSize > 0) ? _bufferSize : kDefaultAQDefaultBufSize;
  UInt8 bytes[bufferSize];
  CFIndex length;
  while (stream && CFReadStreamHasBytesAvailable(stream) && ![self isDone]) {
    length = CFReadStreamRead(stream, bytes, (CFIndex)sizeof(bytes));

    if (length < 0) {
      if (didConnect) {
        didConnect = false;
        // Ignore. A network connection error likely happened so we should wait for that to throw.
        // If this happens again, throw a audio data not found error.
        return;
      }
      [self failWithErrorCode:AS_AUDIO_DATA_NOT_FOUND reason:@""];
      return;
    } else if (length == 0) {
      return;
    }

    didConnect = true;

    // Shoutcast support.
    UInt8 bytesNoMetadata[bufferSize]; // Bytes without the ICY metadata
    UInt32 lengthNoMetadata = 0;
    NSUInteger streamStart = 0;

    if (!icyChecked && statusCode == 200) {
      NSString *icyCheck = [[NSString alloc] initWithBytes:bytes length:10 encoding:NSUTF8StringEncoding];
      if (icyCheck == nil) {
        icyCheck = [[NSString alloc] initWithBytes:bytes length:10 encoding:NSISOLatin1StringEncoding];
      }
      if (icyCheck && [icyCheck caseInsensitiveCompare:@"ICY 200 OK"] == NSOrderedSame) {
        icyStream = true;
      } else {
        if (_httpHeaders[@"icy-metaint"]) {
          icyStream = true;
          icyMetaInterval = [_httpHeaders[@"icy-metaint"] intValue];
          icyBitrate = [_httpHeaders[@"icy-br"] doubleValue] * 1000.0;
          icyHeadersParsed = true;
        }
      }
      icyChecked = true;
    }

    if (!icyStream && id3ParserState != ID3_STATE_PARSED) {
      // ID3 support
      [self parseID3TagsInBytes:bytes length:length];
    } else if (icyStream && !icyHeadersParsed) {
      NSUInteger lineStart = 0;
      while (true)
      {
        if (streamStart + 3 > (NSUInteger)length)
        {
          break;
        }

        if (bytes[streamStart] == '\r' && bytes[streamStart+1] == '\n')
        {
          NSString *fullString = [[NSString alloc] initWithBytes:bytes
                                                          length:streamStart
                                                        encoding:NSUTF8StringEncoding];
          if (fullString == nil)
          {
            fullString = [[NSString alloc] initWithBytes:bytes
                                                  length:streamStart
                                                encoding:NSISOLatin1StringEncoding];
          }

          NSArray *lineItems = [[fullString substringWithRange:NSMakeRange(lineStart,
                                                                  streamStart-lineStart)]
                                   componentsSeparatedByString:@":"];

          if ([lineItems count] >= 2)
          {
            if ([lineItems[0] caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) {
              AudioFileTypeID oldFileType = _fileType;
              _fileType = [[self class] hintForMIMEType:lineItems[1]];
              if (_fileType == 0) {
                // Okay, we can now default to this now.
                _fileType = kDefaultAudioFileType;
              }

              if (_fileType != oldFileType) {
                LOG_INFO(@"ICY stream Content-Type: %@", lineItems[1]);
                AudioFileStreamClose(audioFileStream);
                AudioQueueStop(audioQueue, true);
                if (buffers) {
                  for (UInt32 j = 0; j < _bufferCount; ++j) {
                    AudioQueueFreeBuffer(audioQueue, buffers[j]->ref);
                  }
                }

                osErr = AudioFileStreamOpen((__bridge void*) self, ASPropertyListenerProc,
                                            ASPacketsProc, _fileType, &audioFileStream);
                CHECK_ERR(osErr, AS_FILE_STREAM_OPEN_FAILED, [[self class] descriptionForAFSErrorCode:osErr]);
              }
            }
            else if ([lineItems[0] caseInsensitiveCompare:@"icy-metaint"] == NSOrderedSame) {
              icyMetaInterval = [lineItems[1] intValue];
            }
            else if ([lineItems[0] caseInsensitiveCompare:@"icy-br"] == NSOrderedSame) {
              icyBitrate = [lineItems[1] doubleValue] * 1000.0;
            }
          }

          if (bytes[streamStart+2] == '\r' && bytes[streamStart+3] == '\n') {
            icyHeadersParsed = true;
            break;
          }

          lineStart = streamStart+2;
        }

        streamStart++;
      }

      if (icyHeadersParsed) {
        streamStart = streamStart + 4;
      }
    }

    if (icyHeadersParsed) {
      for (CFIndex byte = (CFIndex)streamStart; byte < length; byte++) {
        if (icyMetaBytesRemaining > 0) {
          [icyMetadata appendFormat:@"%c", bytes[byte]];

          icyMetaBytesRemaining--;

          if (icyMetaBytesRemaining == 0) {
            // Ready for parsing
            NSArray *metadataArr = [icyMetadata componentsSeparatedByString:@";"];
            for (NSString *metadataLine in metadataArr) {
              NSString *key;
              NSScanner *scanner = [NSScanner scannerWithString:metadataLine];
              [scanner scanUpToString:@"=" intoString:&key];
              if ([scanner isAtEnd] || ![key isEqualToString:@"StreamTitle"]) continue; // Not interested in other metadata
              [scanner scanString:@"=" intoString:nil];
              [scanner scanString:@"'" intoString:nil];
              NSUInteger scanLoc = [scanner scanLocation];
              NSString *value = [metadataLine substringWithRange:NSMakeRange(scanLoc, [metadataLine length] - scanLoc - 1)];

              LOG_INFO(@"ICY stream title read: %@", value);
              icyMetadataPacket = audioPacketsReceived;
              icyPendingCurrentSong = value;
              LOG_DEBUG(@"ICY: Current song update queued for packet %llu.", icyMetadataPacket);
            }
            icyDataBytesRead = 0;
          }

          continue;
        }

        if (icyMetaInterval > 0 && icyDataBytesRead == icyMetaInterval) {
          icyMetaBytesRemaining = bytes[byte] * 16;

          icyMetadata = [NSMutableString string];

          if (icyMetaBytesRemaining == 0) {
            icyDataBytesRead = 0;
          }

          continue;
        }

        icyDataBytesRead++;
        bytesNoMetadata[lengthNoMetadata] = bytes[byte];
        lengthNoMetadata++;
      }
    }

    isParsing = true;
    UInt32 parseFlags;
    if (discontinuous) {
      parseFlags = kAudioFileStreamParseFlag_Discontinuity;
    } else {
      parseFlags = 0;
    }
    if (lengthNoMetadata > 0) {
      osErr = AudioFileStreamParseBytes(audioFileStream, lengthNoMetadata,
                                        bytesNoMetadata, parseFlags);
    } else if (icyMetaInterval == 0) {
      osErr = AudioFileStreamParseBytes(audioFileStream, (UInt32)length,
                                        bytes, parseFlags);
    } else {
      osErr = 0;
    }
    isParsing = false;

    if ([self isDone]) [self closeFileStream];
    CHECK_ERR(osErr, AS_FILE_STREAM_PARSE_BYTES_FAILED, [[self class] descriptionForAFSErrorCode:osErr]);
  }
}

- (void)parseID3TagsInBytes:(UInt8[])bytes length:(CFIndex)length
{
  UInt8 id3Version;
  int id3TagSize;
  AudioStreamerID3FlagInfo id3FlagInfo = 0;
  int id3PosStart;
  UInt8 syncedBytes[length];
  while (true) {
    if (id3ParserState == ID3_STATE_INITIAL) {
      if (length <= 10) {
        /* Not enough bytes */
        id3ParserState = ID3_STATE_PARSED;
        break;
      }

      if (bytes[0] != 'I' || bytes[1] != 'D' || bytes[2] != '3') {
        id3ParserState = ID3_STATE_PARSED; // Done here
        break;
      }

      id3Version = bytes[3];
      LOG_INFO(@"ID3 version 2.%hhu", id3Version);
      if (id3Version != 2 && id3Version != 3 && id3Version != 4) { /* Only supporting ID3v2.2, v2.3 and v2.4 */
        id3ParserState = ID3_STATE_PARSED;
        break;
      }

      if ((bytes[5] & 0x80) != 0) {
        id3FlagInfo |= ID3_FLAG_UNSYNC;
      }
      if ((bytes[5] & 0x40) != 0) {
        if (id3Version >= 3) {
          id3FlagInfo |= ID3_FLAG_EXTENDED_HEADER;
        } else {
          id3ParserState = ID3_STATE_PARSED;
          break;
        }
      }

      id3TagSize = ((bytes[6] & 0x7F) << 21) | ((bytes[7] & 0x7F) << 14) |
                    ((bytes[8] & 0x7F) << 7) | (bytes[9] & 0x7F);

      if ((length - 10) < id3TagSize) {
        LOG_WARN(@"Not enough data received to parse ID3.");
        id3ParserState = ID3_STATE_PARSED;
        break;
      } else {
        if (id3Version <= 3 && (id3FlagInfo & ID3_FLAG_UNSYNC)) {
          for (int pos = 10, last = 0, i = 0; pos < (id3TagSize + 10); pos++) {
            UInt8 byte = bytes[pos];
            if (last != 0xFF || byte != 0) {
              syncedBytes[i++] = byte;
            }
            last = byte;
          }
        } else {
          for (int pos = 10, i = 0; i < id3TagSize; pos++, i++) {
            syncedBytes[i] = bytes[pos];
          }
        }

        if (id3FlagInfo & ID3_FLAG_EXTENDED_HEADER) {
          int extendedHeaderSize = ((syncedBytes[0] << 24) | (syncedBytes[1] << 16) |
                                    (syncedBytes[2] << 8) | syncedBytes[3]);
          if (extendedHeaderSize > id3TagSize) {
            id3ParserState = ID3_STATE_PARSED;
            break;
          }
          int extendedPadding;
          if (id3Version == 3) {
            extendedPadding = ((syncedBytes[5] << 24) | (syncedBytes[6] << 16) |
                               (syncedBytes[7] << 8) | syncedBytes[8]);
          } else {
            extendedPadding = 0;
          }
          id3PosStart = ((id3Version == 3) ? 4 : 0) + extendedHeaderSize;
          if (extendedPadding < id3TagSize) {
            id3TagSize -= extendedPadding;
          } else {
            id3ParserState = ID3_STATE_PARSED;
            break;
          }
        } else {
          id3PosStart = 0;
        }

        id3ParserState = ID3_STATE_READY_TO_PARSE;
        continue;
      }
    } else if (id3ParserState == ID3_STATE_READY_TO_PARSE) {
      int pos = id3PosStart;

      NSString *id3Title;
      NSString *id3Artist;

      while (pos < id3TagSize) {
        int startPos = pos;

        int frameSize;
        if (id3Version >= 3) {
          pos += 4;
          frameSize = ((syncedBytes[pos] << 24) + (syncedBytes[pos+1] << 16) +
                       (syncedBytes[pos+2] << 8) + syncedBytes[pos+3]);
          pos += 4;
        } else {
          pos += 3;
          frameSize = (syncedBytes[pos] << 16) + (syncedBytes[pos+1] << 8) + syncedBytes[pos+2];
          pos += 3;
        }
        if ((frameSize+pos+2) > id3TagSize || frameSize == 0) {
          break;
        }

        int flags = 0;
        if (id3Version >= 3) {
          flags = (syncedBytes[pos] << 8) + syncedBytes[pos+1];

          if ((id3Version == 3 && (flags & 0x80) > 0) || (id3Version >= 4 && (flags & 0x8) > 0) || /* compressed */
              (id3Version == 3 && (flags & 0x40) > 0) || (id3Version >= 4 && (flags & 0x4) > 0) /* encrypted */) {
            // Unsupported - skip to next frame
            pos += 10 + frameSize;
            continue;
          }

          if ((id3Version == 3 && (flags & 0x20)) || (id3Version >= 4 && (flags & 0x40))) {
            pos++;
            frameSize--;
          }

          pos += 2;
        }

        CFStringEncoding encoding;

        UInt8 syncedFrameBytes[frameSize];
        if (id3Version >= 4 && (flags & 0x2)) {
          for (int pos2 = pos, last = 0, i = 0; pos2 < (frameSize+pos); pos2++) {
            UInt8 byte = syncedBytes[pos2];
            if (last != 0xFF || byte != 0) {
              if (i == 0) {
                if (byte == 3) {
                  encoding = kCFStringEncodingUTF8;
                } else if (byte == 2) {
                  encoding = kCFStringEncodingUTF16BE;
                } else if (byte == 1) {
                  encoding = kCFStringEncodingUTF16;
                } else {
                  // Default encoding
                  encoding = kCFStringEncodingISOLatin1;
                }
              }
              if ((pos+i-1) > pos) {
                // I hate UTF-16
                if ((encoding == kCFStringEncodingUTF16 || encoding == kCFStringEncodingUTF16BE) &&
                    i >= 4 && (i % 2) == 0 && syncedFrameBytes[i-3] == 0 && syncedFrameBytes[i-2] == 0 &&
                    (syncedFrameBytes[i-1] != 0 || byte != 0)) {
                  bool bigEndian = (encoding == kCFStringEncodingUTF16BE);
                  UInt8 prevByte = syncedFrameBytes[i-1];
                  syncedFrameBytes[bigEndian ? (i-2) : (i-3)] = ' ';
                  syncedFrameBytes[i-1] = bigEndian ? 0 : '&';
                  syncedFrameBytes[i] = bigEndian ? '&' : 0;
                  i++;
                  syncedFrameBytes[i] = bigEndian ? 0 : ' ';
                  i++;
                  syncedFrameBytes[i] = bigEndian ? ' ' : 0;
                  i++;
                  syncedFrameBytes[i] = prevByte;
                  i++;
                } else if ((encoding == kCFStringEncodingUTF8 || encoding == kCFStringEncodingISOLatin1) &&
                           syncedFrameBytes[i-1] == 0 && byte != 0) {
                  syncedFrameBytes[i-1] = ' ';
                  syncedFrameBytes[i] = '&';
                  i++;
                  syncedFrameBytes[i] = ' ';
                  i++;
                }
              }
              syncedFrameBytes[i++] = byte;
            }
            last = byte;
          }
        } else {
          for (int pos2 = pos, i = 0; pos2 < (frameSize+pos); pos2++, i++) {
            UInt8 byte = syncedBytes[pos2];
            if (i == 0) {
              if (byte == 3) {
                encoding = kCFStringEncodingUTF8;
              } else if (byte == 2) {
                encoding = kCFStringEncodingUTF16BE;
              } else if (byte == 1) {
                encoding = kCFStringEncodingUTF16;
              } else {
                // Default encoding
                encoding = kCFStringEncodingISOLatin1;
              }
            }
            if ((pos2-1) > pos) {
              // I hate UTF-16
              if ((encoding == kCFStringEncodingUTF16 || encoding == kCFStringEncodingUTF16BE) &&
                  i >= 4 && (i % 2) == 0 && syncedFrameBytes[i-3] == 0 && syncedFrameBytes[i-2] == 0 &&
                  (syncedFrameBytes[i-1] != 0 || byte != 0)) {
                bool bigEndian = (encoding == kCFStringEncodingUTF16BE);
                UInt8 prevByte = syncedFrameBytes[i-1];
                syncedFrameBytes[bigEndian ? (i-2) : (i-3)] = ' ';
                syncedFrameBytes[i-1] = bigEndian ? 0 : '&';
                syncedFrameBytes[i] = bigEndian ? '&' : 0;
                i++;
                syncedFrameBytes[i] = bigEndian ? 0 : ' ';
                i++;
                syncedFrameBytes[i] = bigEndian ? ' ' : 0;
                i++;
                syncedFrameBytes[i] = prevByte;
                i++;
              } else if ((encoding == kCFStringEncodingUTF8 || encoding == kCFStringEncodingISOLatin1) &&
                         syncedFrameBytes[i-1] == 0 && byte != 0) {
                syncedFrameBytes[i-1] = ' ';
                syncedFrameBytes[i] = '&';
                i++;
                syncedFrameBytes[i] = ' ';
                i++;
              }
            }
            syncedFrameBytes[i] = byte;
          }
        }

        size_t tagLen = (id3Version <= 2) ? 3 : 4;
        if (!strncmp((char*)syncedBytes+startPos, id3Version <= 2 ? "TT2" : "TIT2", tagLen)) {
          id3Title = @([(__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault,
                                                                              &syncedFrameBytes[1],
                                                                              frameSize - 1, encoding,
                                                                              encoding == kCFStringEncodingUTF16)
                        UTF8String]);
        } else if (!strncmp((char*)syncedBytes+startPos, id3Version <= 2 ? "TP1" : "TPE1", tagLen)) {
          id3Artist = @([(__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault,
                                                                               &syncedFrameBytes[1],
                                                                               frameSize - 1, encoding,
                                                                               encoding == kCFStringEncodingUTF16)
                         UTF8String]);
        }

        pos += frameSize;
      }

      if (id3Title && id3Artist) {
        [self setCurrentSong:[NSString stringWithFormat:@"%@ - %@", id3Artist, id3Title]];
      } else if (id3Title) {
        [self setCurrentSong:[NSString stringWithFormat:@"Unknown Artist - %@", id3Title]];
      } else if (id3Artist) {
        [self setCurrentSong:[NSString stringWithFormat:@"%@ - Unknown Title", id3Artist]];
      }

      LOG_INFO(@"ID3 Current Song: %@", _currentSong);

      id3ParserState = ID3_STATE_PARSED;
      break;
    } else {
      break;
    }
  }
}

- (void)setCurrentSong:(NSString *)currentSong {
  _currentSong = currentSong;
  __strong id <AudioStreamerDelegate> delegate = _delegate;
  if (delegate && [delegate respondsToSelector:@selector(streamer:didUpdateCurrentSong:)]) {
    [delegate streamer:self didUpdateCurrentSong:_currentSong];
  }
}

- (void)updateICYCurrentSong {
  if (icyPendingCurrentSong == nil) return;
  [self setCurrentSong:icyPendingCurrentSong];
  icyPendingCurrentSong = nil;
  LOG_INFO(@"ICY: Current song updated to \"%@\".", _currentSong);
}

//
// enqueueBuffer
//
// Called from ASPacketsProc and connectionDidFinishLoading to pass filled audio
// buffers (filled by ASPacketsProc) to the AudioQueue for playback. This
// function does not return until a buffer is idle for further filling or
// the AudioQueue is stopped.
//
// This function is adapted from Apple's example in AudioFileStreamExample with
// CBR functionality added.
//
- (int)enqueueBuffer {
  assert(stream != NULL);

  assert(!buffers[fillBufferIndex]->inuse);
  buffers[fillBufferIndex]->inuse = true;    // set in use flag
  buffersUsed++;

  // enqueue buffer
  AudioQueueBufferRef fillBuf = buffers[fillBufferIndex]->ref;
  fillBuf->mAudioDataByteSize = bytesFilled;

  OSStatus osErr;
  if (vbr) {
    osErr = AudioQueueEnqueueBuffer(audioQueue, fillBuf, packetsFilled,
                                    buffers[fillBufferIndex]->packetDescs);
  } else {
    osErr = AudioQueueEnqueueBuffer(audioQueue, fillBuf, 0, NULL);
  }
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_ENQUEUE_FAILED, [[self class] descriptionForAQErrorCode:osErr], -1);

  buffers[fillBufferIndex]->packetCount = packetsFilled;
  buffers[fillBufferIndex]->packetStart -= (packetsFilled - 1);
  LOG_DEBUG(@"committed buffer %d", fillBufferIndex);

  if (state_ == AS_WAITING_FOR_DATA) {
    /* Once we have a small amount of queued data, then we can go ahead and
     * start the audio queue and the file stream should remain ahead of it */
    if ((_bufferCount < _bufferFillCountToStart && buffersUsed >= _bufferCount) || buffersUsed >= _bufferFillCountToStart) {
      _error = nil; // We have successfully reconnected. Clear the error.
      if (![self startAudioQueue]) return -1;
    }
  }

  /* move on to the next buffer and wait for it to be in use */
  if (++fillBufferIndex >= _bufferCount) fillBufferIndex = 0;
  bytesFilled   = 0;    // reset bytes filled
  packetsFilled = 0;    // reset packets filled

  /* If we have no more queued data, and the stream has reached its end, then
     we're not going to be enqueueing any more buffers to the audio stream. In
     this case flush it out and asynchronously stop it */
  if (queued_vbr_head == NULL && queued_cbr_head == NULL &&
      CFReadStreamGetStatus(stream) == kCFStreamStatusAtEnd) {
    osErr = AudioQueueFlush(audioQueue);
    CHECK_ERR(osErr, AS_AUDIO_QUEUE_FLUSH_FAILED, [[self class] descriptionForAQErrorCode:osErr], -1);
  }

  if (buffers[fillBufferIndex]->inuse) {
    LOG_DEBUG(@"waiting for buffer %d", fillBufferIndex);
    if (!_bufferInfinite) {
      CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(),
                                        kCFRunLoopCommonModes);
      /* Make sure we don't have ourselves marked as rescheduled */
      unscheduled = true;
      rescheduled = false;
    }
    waitingOnBuffer = true;
    return 0;
  }
  return 1;
}

//
// createQueue
//
// Method to create the AudioQueue from the parameters gathered by the
// AudioFileStream.
//
// Creation is deferred to the handling of the first audio packet (although
// it could be handled any time after kAudioFileStreamProperty_ReadyToProducePackets
// is true).
//
- (void)createQueue {
  assert(audioQueue == NULL);

  // create the audio queue
  OSStatus osErr = AudioQueueNewOutput(&_streamDescription, ASAudioQueueOutputCallback,
                                       (__bridge void*) self, CFRunLoopGetMain(), NULL,
                                       0, &audioQueue);
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_CREATION_FAILED, [[self class] descriptionForAQErrorCode:osErr]);

  // start the queue if it has not been started already
  // listen to the "isRunning" property
  osErr = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning,
                                        ASAudioQueueIsRunningCallback,
                                        (__bridge void*) self);
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_ADD_LISTENER_FAILED, [[self class] descriptionForAQErrorCode:osErr]);

  if (vbr) {
    /* Try to determine the packet size, eventually falling back to some
       reasonable default of a size */
    UInt32 sizeOfUInt32 = sizeof(UInt32);
    osErr = AudioFileStreamGetProperty(audioFileStream,
                                       kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfUInt32,
                                       &packetBufferSize);

    if (osErr || packetBufferSize == 0) {
      osErr = AudioFileStreamGetProperty(audioFileStream,
                                         kAudioFileStreamProperty_MaximumPacketSize, &sizeOfUInt32,
                                         &packetBufferSize);
      if (osErr || packetBufferSize == 0) {
        // No packet size available, just use the default
        packetBufferSize = _bufferSize;
        defaultBufferSizeUsed = true;
      }
    }
  } else {
    packetBufferSize = _bufferSize;
    defaultBufferSizeUsed = true;
  }

  // allocate audio queue buffers
  buffers = malloc(_bufferCount * sizeof(buffer_t*));
  CHECK_ERR(buffers == NULL, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, @"");
  for (UInt32 i = 0; i < _bufferCount; ++i) {
    buffers[i] = malloc(sizeof(buffer_t));
    CHECK_ERR(buffers[i] == NULL, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, @"");
    buffers[i]->inuse = false;
    buffers[i]->packetStart = 0;
    buffers[i]->packetCount = 0;

    osErr = AudioQueueAllocateBuffer(audioQueue, packetBufferSize,
                                     &(buffers[i]->ref));
    CHECK_ERR(osErr, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, [[self class] descriptionForAQErrorCode:osErr]);
  }

  /* Playback rate */

  UInt32 propVal = 1;
  AudioQueueSetProperty(audioQueue, kAudioQueueProperty_EnableTimePitch, &propVal, sizeof(propVal));

  propVal = kAudioQueueTimePitchAlgorithm_Spectral;
  AudioQueueSetProperty(audioQueue, kAudioQueueProperty_TimePitchAlgorithm, &propVal, sizeof(propVal));

  propVal = (_playbackRate == 1.0f || fileLength == 0) ? 1 : 0;
  AudioQueueSetProperty(audioQueue, kAudioQueueProperty_TimePitchBypass, &propVal, sizeof(propVal));

  if (_playbackRate != 1.0f && fileLength > 0) {
    AudioQueueSetParameter(audioQueue, kAudioQueueParam_PlayRate, _playbackRate);
  }

  /* Some audio formats have a "magic cookie" which needs to be transferred from
     the file stream to the audio queue. If any of this fails it's "OK" because
     the stream either doesn't have a magic or error will propagate later */

  // get the cookie size
  UInt32 cookieSize;
  Boolean writable;
  OSStatus ignorableError;
  ignorableError = AudioFileStreamGetPropertyInfo(audioFileStream,
                                                  kAudioFileStreamProperty_MagicCookieData, &cookieSize,
                                                  &writable);
  if (ignorableError) {
    return;
  }

  // get the cookie data
  void *cookieData = calloc(1, cookieSize);
  if (cookieData == NULL) return;
  ignorableError = AudioFileStreamGetProperty(audioFileStream,
                                              kAudioFileStreamProperty_MagicCookieData, &cookieSize,
                                              cookieData);
  if (ignorableError) {
    free(cookieData);
    return;
  }

  // set the cookie on the queue. Don't worry if it fails, all we'd to is return
  // anyway
  AudioQueueSetProperty(audioQueue, kAudioQueueProperty_MagicCookie, cookieData,
                        cookieSize);
  free(cookieData);
}

/**
 * @brief Sets up the audio queue and starts it
 *
 * This will set all the properties before starting the stream.
 *
 * @return YES if the AudioQueue was sucessfully set to start, NO if an error occurred
 */
- (BOOL)startAudioQueue
{
  OSStatus osErr = AudioQueueStart(audioQueue, NULL);
  CHECK_ERR(osErr, AS_AUDIO_QUEUE_START_FAILED, [[self class] descriptionForAQErrorCode:osErr], NO);

  if (queuePaused) {
    queuePaused = false;
    [self setState:AS_PLAYING];
  } else {
    [self setState:AS_WAITING_FOR_QUEUE_TO_START];
  }

  return YES;
}

//
// handlePropertyChangeForFileStream:fileStreamPropertyID:ioFlags:
//
// Object method which handles implementation of ASPropertyListenerProc
//
// Parameters:
//    inAudioFileStream - should be the same as self->audioFileStream
//    inPropertyID - the property that changed
//    ioFlags - the ioFlags passed in
//
- (void)handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream
                     fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID
                                  ioFlags:(UInt32 *)ioFlags {
  assert(inAudioFileStream == audioFileStream);

  switch (inPropertyID) {
    case kAudioFileStreamProperty_ReadyToProducePackets:
      LOG_INFO(@"ready for packets");
      discontinuous = true;
      break;

    case kAudioFileStreamProperty_DataOffset: {
      SInt64 offset;
      UInt32 offsetSize = sizeof(offset);
      OSStatus osErr = AudioFileStreamGetProperty(inAudioFileStream,
                                                  kAudioFileStreamProperty_DataOffset,
                                                  &offsetSize, &offset);
      CHECK_ERR(osErr, AS_FILE_STREAM_GET_PROPERTY_FAILED, [[self class] descriptionForAFSErrorCode:osErr]);
      dataOffset = (UInt64)offset;

      if (audioDataByteCount) {
        fileLength = dataOffset + audioDataByteCount;
      }
      LOG_DEBUG(@"have data offset: %llu", dataOffset);
      break;
    }

    case kAudioFileStreamProperty_AudioDataByteCount: {
      UInt32 byteCountSize = sizeof(UInt64);
      OSStatus osErr = AudioFileStreamGetProperty(inAudioFileStream,
                                                  kAudioFileStreamProperty_AudioDataByteCount,
                                                  &byteCountSize, &audioDataByteCount);
      CHECK_ERR(osErr, AS_FILE_STREAM_GET_PROPERTY_FAILED, [[self class] descriptionForAFSErrorCode:osErr]);
      fileLength = dataOffset + audioDataByteCount;
      LOG_DEBUG(@"have byte count: %llu", audioDataByteCount);
      break;
    }

    case kAudioFileStreamProperty_DataFormat: {
      /* If we seeked, don't re-read the data */
      if (_streamDescription.mSampleRate == 0) {
        UInt32 descSize = sizeof(_streamDescription);

        OSStatus osErr = AudioFileStreamGetProperty(inAudioFileStream,
                                                    kAudioFileStreamProperty_DataFormat,
                                                    &descSize, &_streamDescription);
        CHECK_ERR(osErr, AS_FILE_STREAM_GET_PROPERTY_FAILED, [[self class] descriptionForAFSErrorCode:osErr]);
      }
      LOG_INFO(@"have data format");
      break;
    }

    case kAudioFileStreamProperty_FormatList: {
      Boolean outWriteable;
      UInt32 formatListSize;
      OSStatus osErr = AudioFileStreamGetPropertyInfo(inAudioFileStream,
                                                      kAudioFileStreamProperty_FormatList,
                                                      &formatListSize, &outWriteable);
      CHECK_ERR(osErr, AS_FILE_STREAM_GET_PROPERTY_FAILED, [[self class] descriptionForAFSErrorCode:osErr]);

      AudioFormatListItem *formatList = malloc(formatListSize);
      CHECK_ERR(formatList == NULL, AS_FILE_STREAM_GET_PROPERTY_FAILED, @"");
      osErr = AudioFileStreamGetProperty(inAudioFileStream,
                                         kAudioFileStreamProperty_FormatList,
                                         &formatListSize, formatList);
      if (osErr) {
        free(formatList);
        [self failWithErrorCode:AS_FILE_STREAM_GET_PROPERTY_FAILED reason:[[self class] descriptionForAFSErrorCode:osErr]];
        return;
      }

      for (UInt32 i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i++) {
        AudioStreamBasicDescription pasbd = formatList[i].mASBD;

        if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
        {
          _streamDescription = pasbd;
          break;
        }
      }
      free(formatList);
      break;
    }
  }
}

//
// handleAudioPackets:numberBytes:numberPackets:packetDescriptions:
//
// Object method which handles the implementation of ASPacketsProc
//
// Parameters:
//    inInputData - the packet data
//    inNumberBytes - byte size of the data
//    inNumberPackets - number of packets in the data
//    inPacketDescriptions - packet descriptions
//
- (void)handleAudioPackets:(const void*)inInputData
               numberBytes:(UInt32)inNumberBytes
             numberPackets:(UInt32)inNumberPackets
        packetDescriptions:(AudioStreamPacketDescription*)inPacketDescriptions {
  if ([self isDone]) return;
  // we have successfully read the first packets from the audio stream, so
  // clear the "discontinuous" flag
  if (discontinuous) {
    discontinuous = false;
  }

  if (!audioQueue) {
    vbr = (inPacketDescriptions != NULL);

    if (fileLength != 0) {
      OSStatus status = 0;
      UInt32 ioFlags = 0;
      SInt64 byteOffset;
      SInt64 lower = 0;
      SInt64 upper = 1000000;
      SInt64 current;
      while (upper - lower > 1 || status != 0)
      {
        current = (upper + lower) / 2;
        status = AudioFileStreamSeek(audioFileStream, current, &byteOffset, &ioFlags);
        if (status == 0)
        {
          lower = current;
        }
        else
        {
          upper = current;
        }
      }
      AudioFileStreamSeek(audioFileStream, 0, &byteOffset, &ioFlags);
      totalAudioPackets = (UInt64)current + 1;
      seekByteOffset = (UInt64)byteOffset + dataOffset;
      [self closeReadStream];
      [self openReadStream];
    }

    assert(!waitingOnBuffer);
    [self createQueue];
    if ([self isDone]) return; // Queue creation failed. Abort.
  }

  audioBytesReceived += inNumberBytes;
  audioPacketsReceived += inNumberPackets;

  if (inPacketDescriptions) {
    /* Place each packet into a buffer and then send each buffer into the audio
       queue */
    UInt32 i;
    for (i = 0; i < inNumberPackets && !waitingOnBuffer && queued_vbr_head == NULL; i++) {
      AudioStreamPacketDescription *desc = &inPacketDescriptions[i];
      int ret = [self handleVBRPacket:(inInputData + desc->mStartOffset)
                                 desc:desc];
      CHECK_ERR(ret < 0, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");
      if (!ret) break;
    }
    if (i == inNumberPackets) return;

    for (; i < inNumberPackets; i++) {
      /* Allocate the packet */
      UInt32 size = inPacketDescriptions[i].mDataByteSize;
      queued_vbr_packet_t *packet = malloc(sizeof(queued_vbr_packet_t) + size);
      CHECK_ERR(packet == NULL, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");

      /* Prepare the packet */
      packet->next = NULL;
      packet->desc = inPacketDescriptions[i];
      packet->desc.mStartOffset = 0;
      memcpy(packet->data, inInputData + inPacketDescriptions[i].mStartOffset,
             size);

      if (queued_vbr_head == NULL) {
        queued_vbr_head = queued_vbr_tail = packet;
      } else {
        queued_vbr_tail->next = packet;
        queued_vbr_tail = packet;
      }
    }
  } else {
    UInt32 packetSize = (inNumberBytes / inNumberPackets);
    UInt32 i;
    for (i = 0; i < inNumberPackets && !waitingOnBuffer && queued_cbr_head == NULL; i++) {
      int ret = [self handleCBRPacket:(inInputData + (packetSize * i))
                             byteSize:packetSize];
      CHECK_ERR(ret < 0, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");
      if (!ret) break;
    }
    if (i == inNumberPackets) return;

    for (; i < inNumberPackets; i++) {
      /* Allocate the packet */
      queued_cbr_packet_t *packet = malloc(sizeof(queued_cbr_packet_t) + packetSize);
      CHECK_ERR(packet == NULL, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");

      /* Prepare the packet */
      packet->next = NULL;
      packet->byteSize = packetSize;
      memcpy(packet->data, inInputData + (packetSize * i), packetSize);

      if (queued_cbr_head == NULL) {
        queued_cbr_head = queued_cbr_tail = packet;
      } else {
        queued_cbr_tail->next = packet;
        queued_cbr_tail = packet;
      }
    }
  }
}

- (int)handleVBRPacket:(const void*)data
                  desc:(AudioStreamPacketDescription*)desc{
  assert(audioQueue != NULL);
  UInt32 packetSize = desc->mDataByteSize;

  /* This shouldn't happen because most of the time we read the packet buffer
     size from the file stream, but if we resorted to guessing it we could
     come up too small here. Developers may have to set the bufferCount property. */
  CHECK_ERR(packetSize > packetBufferSize, AS_AUDIO_BUFFER_TOO_SMALL,
            @"The audio buffer was too small to handle the audio packets.", -1);

  // if the space remaining in the buffer is not enough for this packet, then
  // enqueue the buffer and wait for another to become available.
  if (packetBufferSize - bytesFilled < packetSize) {
    int hasFreeBuffer = [self enqueueBuffer];
    if (hasFreeBuffer <= 0) {
      return hasFreeBuffer;
    }
    assert(bytesFilled == 0);
  }

  buffers[fillBufferIndex]->packetStart = processedPacketsCount;

  /* global statistics */
  processedPacketsSizeTotal += 8.0 * packetSize / (_streamDescription.mFramesPerPacket / _streamDescription.mSampleRate);
  processedPacketsCount++;
  if (processedPacketsCount > BitRateEstimationMinPackets &&
      !bitrateNotification) {
    bitrateNotification = true;
    __strong id <AudioStreamerDelegate> delegate = _delegate;
    if (delegate && [delegate respondsToSelector:@selector(streamerBitrateIsReady:)]) {
      [delegate streamerBitrateIsReady:self];
    }
  }

  // copy data to the audio queue buffer
  AudioQueueBufferRef buf = buffers[fillBufferIndex]->ref;
  memcpy(buf->mAudioData + bytesFilled, data, (size_t)packetSize);

  // fill out packet description to pass to enqueue() later on
  buffers[fillBufferIndex]->packetDescs[packetsFilled] = *desc;
  // Make sure the offset is relative to the start of the audio buffer
  buffers[fillBufferIndex]->packetDescs[packetsFilled].mStartOffset = bytesFilled;
  // keep track of bytes filled and packets filled
  bytesFilled += packetSize;
  packetsFilled++;

  /* If filled our buffer with packets, then commit it to the system */
  if (packetsFilled >= kAQMaxPacketDescs) return [self enqueueBuffer];
  return 1;
}

- (int)handleCBRPacket:(const void*)data
              byteSize:(UInt32)byteSize {
  assert(audioQueue != NULL);

  size_t bufSpaceRemaining = packetBufferSize - bytesFilled;
  if (bufSpaceRemaining < byteSize) {
    int hasFreeBuffer = [self enqueueBuffer];
    if (hasFreeBuffer <= 0) {
      return hasFreeBuffer;
    }
    assert(bytesFilled == 0);
  }

  if ([self isDone]) return 0;

  AudioQueueBufferRef buf = buffers[fillBufferIndex]->ref;
  memcpy(buf->mAudioData + bytesFilled, data, byteSize);

  bytesFilled += byteSize;
  packetsFilled += byteSize;
  processedPacketsCount += byteSize;

  buffers[fillBufferIndex]->packetStart = processedPacketsCount;

  // Bitrate isn't estimated with these packets.
  // It's safe to calculate the bitrate as soon as we start getting audio.
  if (!bitrateNotification) {
    bitrateNotification = true;
    __strong id <AudioStreamerDelegate> delegate = _delegate;
    if (delegate && [delegate respondsToSelector:@selector(streamerBitrateIsReady:)]) {
      [delegate streamerBitrateIsReady:self];
    }
  }

  return 1;
}

/**
 * @brief Internal helper for sending cached packets to the audio queue
 *
 * This method is enqueued for delivery when an audio buffer is freed
 */
- (void)enqueueCachedData {
  if ([self isDone]) return;
  assert(!waitingOnBuffer);
  assert(!buffers[fillBufferIndex]->inuse);
  assert(stream != NULL);
  LOG_DEBUG(@"processing some cached data");

  /* Queue up as many packets as possible into the buffers */
  while (queued_vbr_head != NULL || queued_cbr_head != NULL) {
    if (queued_cbr_head != NULL) {
      int ret = [self handleCBRPacket:queued_cbr_head->data
                             byteSize:queued_cbr_head->byteSize];
      CHECK_ERR(ret < 0, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");
      if (ret == 0) break;
      queued_cbr_packet_t *next_cbr = queued_cbr_head->next;
      free(queued_cbr_head);
      queued_cbr_head = next_cbr;
    } else {
      int ret = [self handleVBRPacket:queued_vbr_head->data desc:&queued_vbr_head->desc];
      CHECK_ERR(ret < 0, AS_AUDIO_QUEUE_ENQUEUE_FAILED, @"");
      if (ret == 0) break;
      queued_vbr_packet_t *next_vbr = queued_vbr_head->next;
      free(queued_vbr_head);
      queued_vbr_head = next_vbr;
    }
  }

  /* If we finished queueing all our saved packets, we can re-schedule the
   * stream to run */
  if (queued_vbr_head == NULL && queued_cbr_head == NULL) {
    queued_vbr_tail = NULL;
    queued_cbr_tail = NULL;
    rescheduled = true;
    if (!_bufferInfinite) {
      CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    }
  }
}

//
// handleBufferCompleteForQueue:buffer:
//
// Handles the buffer completion notification from the audio queue
//
// Parameters:
//    inAQ - the queue
//    inBuffer - the buffer
//
- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ
                              buffer:(AudioQueueBufferRef)inBuffer {
  /* we're only registered for one audio queue... */
  assert(inAQ == audioQueue);
  /* Sanity check to make sure we're on the right thread */
  assert([NSThread currentThread] == [NSThread mainThread]);

  /* Figure out which buffer just became free, and it had better damn well be
     one of our own buffers */
  UInt32 idx;
  for (idx = 0; idx < _bufferCount; idx++) {
    if (buffers[idx]->ref == inBuffer) break;
  }
  CHECK_ERR(idx >= _bufferCount, AS_AUDIO_QUEUE_BUFFER_MISMATCH, @"");
  assert(buffers[idx]->inuse);

  LOG_DEBUG(@"buffer %u finished", (unsigned int)idx);

  /* Signal the buffer is no longer in use */
  buffers[idx]->inuse = false;
  buffersUsed--;

  if (icyPendingCurrentSong != nil) {
    UInt32 nextIdx = idx + 1;
    if (nextIdx == _bufferCount) nextIdx = 0;
    buffer_t *nextBuffer = buffers[nextIdx];
    if (nextBuffer->packetStart >= icyMetadataPacket) {
      [self updateICYCurrentSong];
    } else if ((nextBuffer->packetStart + nextBuffer->packetCount) >= icyMetadataPacket) {
      UInt32 packetOffset = (UInt32)(icyMetadataPacket - nextBuffer->packetStart);
      UInt64 framesToWait = _streamDescription.mFramesPerPacket * packetOffset;
      if (framesToWait == 0 && vbr) {
        for (UInt32 i = 0; i < packetOffset; i++) {
          framesToWait += nextBuffer->packetDescs[i].mVariableFramesInPacket;
        }
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(framesToWait / _streamDescription.mSampleRate * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateICYCurrentSong];
      });
    }
  }

  /* If we're done with the buffers because the stream is dying, then there's no
   * need to call more methods on it */
  if (state_ == AS_STOPPED) {
    return;

  /* If there is absolutely no more data which will ever come into the stream,
   * then we're done with the audio */
  } else if (buffersUsed == 0 && queued_vbr_head == NULL && queued_cbr_head == NULL &&
             !seeking && stream != nil && CFReadStreamGetStatus(stream) == kCFStreamStatusAtEnd) {
    assert(!waitingOnBuffer);
    seekable = false;
    AudioQueueStop(audioQueue, false);

  /* If we are out of buffers then we need to reconnect or wait */
  } else if (buffersUsed == 0 && ![self isDone] && ![self isWaiting]) {
    if (_error)
    {
      /* A previous error occurred without the need to halt,
       * so we can try reconnecting */
      if (fileLength != 0)
      {
        /* Livestream - don't bother reconnecting */
        [self setState:AS_DONE shouldNotify:NO]; // Delay notification to avoid race conditions
        [self stop];
        [self notifyStateChange];
      }
      /* Try to reconnect */
      double progress;
      [self progress:&progress];
      if (![self seekToTime:progress]) {
        [self setState:AS_DONE shouldNotify:NO]; // Delay notification to avoid race conditions
        [self stop];
        [self notifyStateChange];
      }
    }
    else
    {
      /* No previous error occurred so we simply aren't buffering fasting enough */
      OSStatus osErr = AudioQueuePause(audioQueue);
      CHECK_ERR(osErr, AS_AUDIO_QUEUE_PAUSE_FAILED, [[self class] descriptionForAQErrorCode:osErr]);
      queuePaused = true;

      /* This can either fix or delay the problem
       * If it cannot fix it, the network is simply too slow */
      if (defaultBufferSizeUsed && packetBufferSize < 65536 && !seeking) {
        packetBufferSize = packetBufferSize * 2;
        for (UInt32 j = 0; j < _bufferCount; ++j) {
          AudioQueueFreeBuffer(audioQueue, buffers[j]->ref);
        }
        for (UInt32 i = 0; i < _bufferCount; ++i) {
          osErr = AudioQueueAllocateBuffer(audioQueue, packetBufferSize,
                                           &(buffers[i]->ref));
          CHECK_ERR(osErr, AS_AUDIO_QUEUE_BUFFER_ALLOCATION_FAILED, [[self class] descriptionForAQErrorCode:osErr]);
        }
      }

      [self setState:AS_WAITING_FOR_DATA];
    }

  /* If we just opened up a buffer so try to fill it with some cached
   * data if there is any available */
  } else if (waitingOnBuffer) {
    waitingOnBuffer = false;
    [self enqueueCachedData];
  }
}

//
// handlePropertyChangeForQueue:propertyID:
//
// Implementation for ASAudioQueueIsRunningCallback
//
// Parameters:
//    inAQ - the audio queue
//    inID - the property ID
//
- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ
                          propertyID:(AudioQueuePropertyID)inID {
  /* Sanity check to make sure we're on the expected thread */
  assert([NSThread currentThread] == [NSThread mainThread]);
  /* We only asked for one property, so the audio queue had better damn well
     only tell us about this property */
  assert(inID == kAudioQueueProperty_IsRunning);

  if (state_ == AS_WAITING_FOR_QUEUE_TO_START) {
    [self setState:AS_PLAYING];
  } else if (state_ != AS_STOPPED && !seeking && !_error) {
    UInt32 running;
    UInt32 output = sizeof(running);
    OSStatus osErr = AudioQueueGetProperty(audioQueue, kAudioQueueProperty_IsRunning,
                                           &running, &output);
    if (!osErr && !running) {
      [self setState:AS_DONE shouldNotify:NO];
      // Let the method exit before notifying the world.
      dispatch_async(dispatch_get_main_queue(), ^{
        [self notifyStateChange];
      });
    }
  }
}

/**
 * @brief Closes the read stream and frees all queued data
 */
- (void)closeReadStream {
  if (waitingOnBuffer) waitingOnBuffer = false;
  queued_vbr_packet_t *cur_vbr = queued_vbr_head;
  queued_cbr_packet_t *cur_cbr = queued_cbr_head;
  while (cur_vbr != NULL || cur_cbr != NULL) {
    if (cur_vbr != NULL) {
      queued_vbr_packet_t *tmp = cur_vbr->next;
      free(cur_vbr);
      cur_vbr = tmp;
    } else {
      queued_cbr_packet_t *tmp = cur_cbr->next;
      free(cur_cbr);
      cur_cbr = tmp;
    }
  }
  queued_vbr_head = queued_vbr_tail = NULL;
  queued_cbr_head = queued_cbr_tail = NULL;

  if (stream) {
    CFReadStreamClose(stream);
    CFRelease(stream);
    stream = nil;
  }
}

/**
 * @brief Closes the file stream
 */
- (void)closeFileStream {
  OSStatus osErr = AudioFileStreamClose(audioFileStream);
  ASSERT_ERR(!osErr, @"AudioFileStreamClose returned error \"%@\"", [[self class] descriptionForAFSErrorCode:osErr]);
  audioFileStream = nil;
}

@end
