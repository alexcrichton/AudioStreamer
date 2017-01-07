//
//  ASPlaylist.m
//  AudioStreamer
//
//  Created by Alex Crichton on 8/21/12.
//

#import "ASPlaylist.h"

NSString * const ASCreatedNewStream  = @"ASCreatedNewStream";
NSString * const ASNewSongPlaying    = @"ASNewSongPlaying";
NSString * const ASNoSongsLeft       = @"ASNoSongsLeft";
NSString * const ASRunningOutOfSongs = @"ASRunningOutOfSongs";
NSString * const ASStreamError       = @"ASStreamError";
NSString * const ASAttemptingNewSong = @"ASAttemptingNewSong";

@implementation ASPlaylist

// Backwards compatibility for subclasses.
@synthesize streamer=stream;
@synthesize playlist=urls;

- (instancetype)init {
  return [self initWithCapacity:10];
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
  if ((self = [super init])) {
    urls = [NSMutableArray arrayWithCapacity:capacity];
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (void)addSong:(NSURL*)url play:(BOOL)play {
  [urls addObject:url];

  if (play && ![stream isPlaying]) {
    [self play];
  }
}

- (void)removeSongAtIndex:(NSUInteger)idx {
  [urls removeObjectAtIndex:idx];
}

- (void)clearSongList {
  [urls removeAllObjects];
}

- (void)setAudioStream {
  if (stream != nil) {
    [stream stop];
  }
  stream = [AudioStreamer streamWithURL:_playingURL];
  [stream setDelegate:self];
  [[NSNotificationCenter defaultCenter]
        postNotificationName:ASCreatedNewStream
                      object:self
                    userInfo:@{@"stream": stream}];
  volumeSet = [stream setVolume:volume];
}

- (void)streamerBitrateIsReady:(AudioStreamer *)sender {
  NSAssert(sender == stream,
           @"Should only receive delegate calls for the current stream");

  [[NSNotificationCenter defaultCenter]
        postNotificationName:ASNewSongPlaying
                      object:self
                    userInfo:@{@"url": _playingURL}];

  if (lastKnownSeekTime == 0)
    return;
  if (![sender seekToTime:lastKnownSeekTime])
    return;
  retrying = NO;
  lastKnownSeekTime = 0;
}

- (void)streamerStatusDidChange:(AudioStreamer *)sender {
  NSAssert(sender == stream,
           @"Should only receive delegate calls for the current stream");
  if (!volumeSet) {
    volumeSet = [sender setVolume:volume];
  }

  if (stopping) {
    return;
  } else if ([self isError]) {
    /* If we've hit an error, then we want to record out current progress into
       the song. Only do this if we're not in the process of retrying to
       establish a connection, so that way we don't blow away the original
       progress from when the error first happened */
    if (!retrying) {
      if (![sender progress:&lastKnownSeekTime]) {
        lastKnownSeekTime = 0;
      }
    }

    /* If the network connection just outright failed, then we shouldn't be
       retrying with a new auth token because it will never work for that
       reason. Most likely this is some network trouble and we should have the
       opportunity to hit a button to retry this specific connection so we can
       at least hope to regain our current place in the song */
    NSInteger code = [[sender error] code];
    if (code == ASReadStreamNetworkConnectionFailed || code == ASReadStreamTimedOut) {
      [[NSNotificationCenter defaultCenter]
            postNotificationName:ASStreamError
                          object:self];

    /* Otherwise, this might be because our authentication token is invalid, but
       just in case, retry the current song automatically a few times before we
       finally give up and clear our cache of urls (see below) */
    } else {
      [self performSelector:@selector(retry) withObject:nil afterDelay:0];
    }

  /* When the stream has finished, move on to the next song */
  } else if ([sender isDone]) {
    [self performSelectorOnMainThread:@selector(next) withObject:nil waitUntilDone:NO];
  }
}

- (void)retry {
  if (tries > 2) {
    /* too many retries means just skip to the next song */
    [self clearSongList];
    [self next];
    return;
  }
  tries++;
  retrying = YES;
  [self setAudioStream];
  [stream start];
}

- (void)play {
  if (stream) {
    [stream play];
    return;
  }

  if ([urls count] == 0) {
    [[NSNotificationCenter defaultCenter]
          postNotificationName:ASNoSongsLeft
                        object:self];
    return;
  }

  _playingURL = urls[0];
  [urls removeObjectAtIndex:0];
  [self setAudioStream];
  tries = 0;

  [[NSNotificationCenter defaultCenter]
        postNotificationName:ASAttemptingNewSong
                      object:self];

  [stream start];

  if ([urls count] < 2) {
    [[NSNotificationCenter defaultCenter]
          postNotificationName:ASRunningOutOfSongs
                        object:self];
  }
}

- (void)pause {
  [stream pause];
}

- (BOOL)isPaused {
  return [stream isPaused];
}

- (BOOL)isPlaying {
  return [stream isPlaying];
}

- (BOOL)isIdle {
  return [stream isDone];
}

- (BOOL)isError {
  return [stream doneReason] == ASDoneError;
}

- (BOOL)progress:(double*)ret {
  return [stream progress:ret];
}

- (BOOL)duration:(double*)ret {
  return [stream duration:ret];
}

- (void)next {
  assert(!nexting);
  nexting = YES;
  lastKnownSeekTime = 0;
  retrying = NO;
  [self stop];
  [self play];
  nexting = NO;
}

- (void)stop {
  assert(!stopping);
  stopping = YES;
  [stream stop];
  stream = nil;
  _playingURL = nil;
  stopping = NO;
}

- (void)setVolume:(float)vol {
  volumeSet = [stream setVolume:vol];
  volume = vol;
}

@end
