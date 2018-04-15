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
 * Alex Crichton for the Hermes project and Bo Anderson */

#import "AudioStreamer.h"

/* Defaults */
#define kDefaultNumAQBufs 256
#define kDefaultAQDefaultBufSize 8192

@interface AudioStreamer() <ASHTTPReadStreamHandlerDelegate, ASAudioFileStreamHandlerDelegate, ASAudioQueueHandlerDelegate>

@end

@implementation AudioStreamer

- (instancetype)initWithURL:(NSURL *)url
{
  assert(url != nil);
  if ((self = [super init]))
  {
    _url = url;
    _bufferCount  = kDefaultNumAQBufs;
    _bufferSize = kDefaultAQDefaultBufSize;
    _timeoutInterval = 10;
    _playbackRate = 1.0f;

    _readStreamHandlerClass = [ASCFReadStreamHandler class];
    _fileStreamHandlerClass = [ASAudioFileStreamHandler class];
    _audioQueueHandlerClass = [ASAudioQueueHandler class];

    _proxyInfo = [[ASProxyInformation alloc] initWithType:ASProxySystem host:nil port:0];
  }
  return self;
}

+ (instancetype)streamWithURL:(NSURL *)url
{
  return [[self alloc] initWithURL:url];
}

- (void)dealloc
{
  [self stop];
}

- (void)setHTTPProxy:(NSString *)host port:(uint16_t)port
{
  assert(_readStreamHandler == nil);
  _proxyInfo = [[ASProxyInformation alloc] initWithType:ASProxyHTTP host:host port:port];
}

- (void)setSOCKSProxy:(NSString *)host port:(uint16_t)port
{
  assert(_readStreamHandler == nil);
  _proxyInfo = [[ASProxyInformation alloc] initWithType:ASProxySOCKS host:host port:port];
}

- (ASLogLevel)logLevel
{
  return [[ASLogger sharedInstance] logLevel];
}

- (void)setLogLevel:(ASLogLevel)logLevel
{
  [[ASLogger sharedInstance] setLogLevel:logLevel];
}

- (ASLogHandler)logHandler
{
  return [[ASLogger sharedInstance] logHandler];
}

- (void)setLogHandler:(ASLogHandler)logHandler
{
  [[ASLogger sharedInstance] setLogHandler:logHandler];
}

- (BOOL)isPlaying
{
  return [_audioQueueHandler isPlaying];
}

- (BOOL)isPaused
{
  return [_audioQueueHandler isPaused];
}

- (BOOL)isWaiting
{
  return [_audioQueueHandler isWaiting] || (_audioQueueHandler == nil && _readStreamHandler != nil);
}

- (BOOL)isDone
{
  return [_audioQueueHandler isDone] || (_started && _readStreamHandler == nil);
}

- (ASDoneReason)doneReason
{
  if (_audioQueueHandler == nil)
  {
    return ([self isDone]) ? ASDoneError : ASNotDone;
  }
  return [_audioQueueHandler doneReason];
}

- (BOOL)isSeekable
{
  double tmp;
  return [_readStreamHandler isSeekable] && ![_audioQueueHandler isFinishing] && [self duration:&tmp] && [self calculatedBitRate:&tmp] && tmp != 0.0;
}

- (void)setCurrentSong:(NSString * _Nullable)currentSong
{
  _currentSong = currentSong;
  __strong id <AudioStreamerDelegate> delegate = _delegate;
  if (delegate && [delegate respondsToSelector:@selector(streamer:didUpdateCurrentSong:)]) {
    [delegate streamer:self didUpdateCurrentSong:currentSong];
  }
  ASLogInfo(@"Current song updated to \"%@\".", _currentSong);
}

- (BOOL)start
{
  if (_started) return NO;
  assert(_audioQueueHandler == nil);

  _started = YES;

  _readStreamHandler = [[_readStreamHandlerClass alloc] initWithURL:[self url]];
  [_readStreamHandler setDelegate:self];
  [_readStreamHandler setProxyInfo:_proxyInfo];
  return [_readStreamHandler openWithBufferSize:_bufferSize timeoutInterval:_timeoutInterval];
}

- (BOOL)pause
{
  assert(_audioQueueHandler != nil);

  if (![self isPlaying]) return NO;

  return [_audioQueueHandler pause];
}

- (BOOL)play
{
  assert(_audioQueueHandler != nil);

  if (![self isPaused]) return NO;

  return [_audioQueueHandler start];
}

- (void)stop
{
  if (_readStreamHandler == nil && _audioQueueHandler == nil) return;

  BOOL audioQueueInitialized = (_audioQueueHandler != nil);

  /* Clean up our streams */
  [self closeReadStream];
  _readStreamHandler = nil;

  [_fileStreamHandler close];

  [_audioQueueHandler stop];
  _audioQueueHandler = nil;

  _httpHeaders     = nil;

  if (!audioQueueInitialized)
    [self notifyStateChange];
}

- (BOOL)seekToTime:(double)newSeekTime
{
  if (![self isSeekable]) return NO;

  double bitrate;
  if (![self calculatedBitRate:&bitrate]) return NO;
  if (bitrate == 0.0) return NO;

  double duration;
  if (![self duration:&duration]) return NO;

  //
  // Store the old time from the audio queue and the time that we're seeking
  // to so that we'll know the correct time progress after seeking.
  //
  [_audioQueueHandler setProgressDelta:newSeekTime];

  //
  // Attempt to align the seek with a packet boundary
  //
  SInt64 seekPacket = 0;
  double packetDuration = _streamDescription.mFramesPerPacket / _streamDescription.mSampleRate;
  if (packetDuration > 0 && [_fileStreamHandler isVBR]) {
    seekPacket = (SInt64)floor(newSeekTime / packetDuration);
  } else if (![_fileStreamHandler isVBR]) {
    seekPacket = (SInt64)((bitrate / 8.0) * newSeekTime);
  }

  BOOL readStreamPaused = [_readStreamHandler isPaused];
  if (!readStreamPaused)
    [_readStreamHandler pause];

  ASAudioQueueSeekResult result = [_audioQueueHandler seekToPacket:&seekPacket];
  if (result == ASAudioQueueSeekFailed)
  {
    return NO;
  }
  else if (result == ASAudioQueueSeekPerformed)
  {
    if (packetDuration > 0 && [_fileStreamHandler isVBR]) {
      [_audioQueueHandler setProgressDelta:seekPacket * packetDuration];
    } else if (![_fileStreamHandler isVBR]) {
      [_audioQueueHandler setProgressDelta:seekPacket * 8.0 / bitrate];
    }
    if (!readStreamPaused)
      [_readStreamHandler resume];
    return YES;
  }

  if (packetDuration > 0 && ![_fileStreamHandler isVBR]) {
    seekPacket = (SInt64)floor(newSeekTime / packetDuration);
  }

  //
  // Calculate the byte offset for seeking
  //
  UInt64 seekByteOffset = [_fileStreamHandler dataOffset] + (UInt64)((newSeekTime / duration) * [self audioDataByteTotal]);

  UInt64 fileLength = ([_fileStreamHandler dataOffset] + [self audioDataByteTotal]);

  //
  // Attempt to leave 1 useful packet at the end of the file (although in
  // reality, this may still seek too far if the file has a long trailer).
  //
  if (seekByteOffset > fileLength - 2 * [_audioQueueHandler bufferSize]) {
    seekByteOffset = fileLength - 2 * [_audioQueueHandler bufferSize];
  }

  if (packetDuration > 0 && bitrate > 0)
  {
    SInt64 packetAlignedByteOffset = [_fileStreamHandler seekToPacket:seekPacket];
    if (packetAlignedByteOffset != -1)
    {
      if (!_bitrateEstimated) {
        [_audioQueueHandler setProgressDelta:packetAlignedByteOffset * 8.0 / bitrate];
      }
      seekByteOffset = (UInt64)packetAlignedByteOffset + [_fileStreamHandler dataOffset];
      if (seekByteOffset >= fileLength - 1) {
        // End of the file. We're done here.
        [_audioQueueHandler finalize];
        return YES;
      }
    }
  }

  [self closeReadStream];

  /* Open a new stream with a new offset */
  _readStreamHandler = [[_readStreamHandlerClass alloc] initWithURL:[self url]];
  [_readStreamHandler setDelegate:self];
  [_readStreamHandler setProxyInfo:_proxyInfo];
  return [_readStreamHandler openAtByteOffset:seekByteOffset
                                   bufferSize:_bufferSize
                              timeoutInterval:_timeoutInterval];
}

- (BOOL)seekByDelta:(double)seekTimeDelta
{
  double p = 0;
  if ([self progress:&p]) {
    return [self seekToTime:p + seekTimeDelta];
  }
  return NO;
}

- (BOOL)progress:(double *)ret
{
  return [_audioQueueHandler progress:ret];
}

- (BOOL)bufferProgress:(double *)ret
{
  if (![_audioQueueHandler isPlaying] && ![_audioQueueHandler isPaused])
    return NO;

  double duration;
  if (![self duration:&duration]) return NO;

  UInt64 byteOffset = [_readStreamHandler byteOffset];
  if (byteOffset < [_fileStreamHandler dataOffset]) byteOffset = [_fileStreamHandler dataOffset];
  *ret = (double)([_audioQueueHandler audioDataBytesReceived] + byteOffset) / (double)([_fileStreamHandler dataOffset] + [self audioDataByteTotal]) * duration;
  return YES;
}

- (BOOL)calculatedBitRate:(double *)rate
{
  if ([_readStreamHandler icyBitrate] > 0)
  {
    *rate = [_readStreamHandler icyBitrate];
    _bitrateEstimated = NO;
    return YES;
  }

  BOOL success = [_fileStreamHandler calculateBitrate:rate estimated:&_bitrateEstimated];
  if (success) return YES;

  success = [_audioQueueHandler estimateBitrate:rate];
  if (success)
  {
    _bitrateEstimated = YES;
    return YES;
  }

  return NO;
}

- (BOOL)duration:(double *)ret
{
  if (![_fileStreamHandler duration:ret])
  {
    if ([self audioDataByteTotal] == 0) return NO;

    double calcBitrate;
    if (![self calculatedBitRate:&calcBitrate]) return NO;
    if (calcBitrate == 0.0) return NO;
    *ret = [self audioDataByteTotal] / (calcBitrate * 0.125);
  }

  return YES;
}

- (BOOL)setVolume:(float)volume
{
  if (_audioQueueHandler != nil)
  {
    [_audioQueueHandler setVolume:volume];
    return YES;
  }
  return NO;
}

- (BOOL)fadeTo:(float)volume duration:(float)duration
{
  if (_audioQueueHandler != nil)
  {
    [_audioQueueHandler fadeTo:volume duration:duration];
    return YES;
  }
  return NO;
}

- (BOOL)fadeInDuration:(float)duration
{
  // Set the gain to 0.0, so we can call this method just after creating the streamer
  [self setVolume:0.0];
  return [self fadeTo:1.0 duration:duration];
}

- (BOOL)fadeOutDuration:(float)duration
{
  return [self fadeTo:0.0 duration:duration];
}

#pragma mark - Internal methods

- (void)notifyStateChange
{
  __strong id <AudioStreamerDelegate> delegate = _delegate;
  if (delegate && [delegate respondsToSelector:@selector(streamerStatusDidChange:)]) {
    [delegate streamerStatusDidChange:self];
  }
}


- (UInt64)audioDataByteTotal
{
  if ([_fileStreamHandler audioDataByteTotal] > 0)
    return [_fileStreamHandler audioDataByteTotal];
  else if ([_readStreamHandler contentLength] >= [_fileStreamHandler dataOffset])
    return [_readStreamHandler contentLength] - [_fileStreamHandler dataOffset];

  return 0;
}

/**
 * @brief Closes the read stream and frees all queued data
 */
- (void)closeReadStream
{
  [_readStreamHandler close];
  [_audioQueueHandler flushCachedData];
}

/* Delegates */

- (void)readStreamFileTypeUpdated:(AudioFileTypeID)fileType
{
  if (_fileType != fileType)
  {
    _fileType = fileType;

    if (_fileStreamHandler != nil)
    {
      [_fileStreamHandler close];
      [_audioQueueHandler stop];

      [self readStreamReadyToStartReading];
    }
  }
}

- (void)readStreamReadHTTPHeaders:(NSDictionary *)httpHeaders
{
  _httpHeaders = httpHeaders;
}

- (void)readStreamDidUpdateCurrentSong:(NSString *)currentSong shouldQueue:(BOOL)shouldQueue
{
  ASAudioQueueCallback callback = ^{
    [self setCurrentSong:currentSong];
  };

  if (_audioQueueHandler == nil || !shouldQueue)
    callback();
  else
    [_audioQueueHandler queueCallback:callback];
}

- (void)readStreamReadyToStartReading
{
  _fileStreamHandler = [[_fileStreamHandlerClass alloc] initWithFileType:_fileType];
  [_fileStreamHandler setDelegate:self];
  [_fileStreamHandler open];
}

- (void)readStreamReadBytes:(UInt8 *)bytes length:(CFIndex)length
{
  [_fileStreamHandler parseData:bytes length:(UInt32)length];
}

- (BOOL)readStreamRequestsReconnection
{
  return [self isSeekable];
}

- (void)readStreamEncounteredError:(NSError *)error
{
  _error = error;
  if ([error code] == ASReadStreamTimedOut && _audioQueueHandler != nil)
    [_audioQueueHandler finalize];
  else
    [self stop];
}

- (void)readStreamReachedEnd
{
  if (_audioQueueHandler != nil)
    [_audioQueueHandler finalize];
  else
    [self stop];
}

- (void)fileStreamBasicDescriptionUpdated:(AudioStreamBasicDescription)asbd
{
  _streamDescription = asbd;
}

- (void)fileStreamPreparedForAudioWithPacketSize:(UInt32)packetSize
                                      cookieData:(void *)cookieData
                                      cookieSize:(UInt32)cookieSize
{
  if ([_fileStreamHandler audioDataByteTotal] > 0)
    [_readStreamHandler setContentLength:[_fileStreamHandler dataOffset] + [_fileStreamHandler audioDataByteTotal]];

  if (_audioQueueHandler == nil)
  {
    _audioQueueHandler = [[_audioQueueHandlerClass alloc] initWithStreamDescription:_streamDescription
                                                                        bufferCount:_bufferCount
                                                                         packetSize:((packetSize > 0) ? packetSize : _bufferSize)];
    [_audioQueueHandler setDelegate:self];
  }

  if (_bufferFillCountToStart > 0)
    [_audioQueueHandler setBufferFillCountToStart:_bufferFillCountToStart];

  if ([self audioDataByteTotal] > 0)
    [_audioQueueHandler setPlaybackRate:_playbackRate];

  if (cookieData != NULL)
  {
    [_audioQueueHandler setMagicCookie:cookieData withSize:cookieSize];
    free(cookieData);
  }
}

- (void)fileStreamAudioPacketsReady:(const void *)inputData
                        numberBytes:(UInt32)numberBytes
                      numberPackets:(UInt32)numberPackets
                 packetDescriptions:(AudioStreamPacketDescription *)packetDescriptions
{
  [_audioQueueHandler processAudioPackets:inputData
                              numberBytes:numberBytes
                            numberPackets:numberPackets
                       packetDescriptions:packetDescriptions];
}

- (void)fileStreamFailedWithError:(NSError *)error
{
  _error = error;
  [self stop];
}

- (void)audioQueueStatusDidChange
{
  [self notifyStateChange];
}

- (void)audioQueueFailedWithError:(NSError *)error
{
  _error = error;
  [self stop];
}

- (void)audioQueueBitrateEstimationReady
{
  __strong id <AudioStreamerDelegate> delegate = _delegate;
  if (delegate && [delegate respondsToSelector:@selector(streamerBitrateIsReady:)]) {
    [delegate streamerBitrateIsReady:self];
  }
}

- (void)audioQueueBuffersFull
{
  if (!_bufferInfinite)
  {
    [_readStreamHandler pause];
  }
}

- (void)audioQueueBuffersFree
{
  if (!_bufferInfinite)
  {
    [_readStreamHandler resume];
  }
}

@end
