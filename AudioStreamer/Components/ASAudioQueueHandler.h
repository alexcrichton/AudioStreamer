//
//  ASAudioQueueHandler.h
//  AudioStreamer
//
//  Created by Bo Anderson on 30/08/2016.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

/* Maximum number of packets which can be contained in one buffer */
#define kAQMaxPacketDescs 512


typedef NS_ENUM(NSUInteger, ASAudioQueueState)
{
    ASAudioQueueWaitingForData = 0,
    ASAudioQueueWaitingForQueueToStart,
    ASAudioQueuePlaying,
    ASAudioQueuePaused,
    ASAudioQueueStopped,
    ASAudioQueueFinishing,
    ASAudioQueueDone
};

/**
 * Error codes that the audio queue could throw.
 *
 * These are mainly used internally but can be used for comparison with
 * the <[AudioStreamer error]> property.
 *
 * ```
 * if ([[streamer error] code] == ASAudioQueueAudioDataNotFound)
 * {
 *     // Bad stream?
 * }
 * ```
 *
 * You can also check the domain of the error to see if it came from the
 * read stream:
 *
 * ```
 * if ([[streamer error] domain] == ASAudioQueueErrorDomain)
 * {
 *     // It's an audio queue error
 * }
 * ```
 */
typedef NS_ENUM(NSInteger, ASAudioQueueErrorCode)
{
    /**
     * No audio could be found in stream
     */
    ASAudioQueueAudioDataNotFound = 301,
    /**
     * The audio queue (player) threw an error on creation
     */
    ASAudioQueueCreationFailed = 302,
    /**
     * The audio queue (player) threw an error when allocating buffers
     */
    ASAudioQueueBufferAllocationFailed = 303,
    /**
     * The audio queue (player) threw an error when enqueuing buffers
     */
    ASAudioQueueEnqueueFailed = 304,
    /**
     * The audio queue (player) threw an error when adding a property listener
     */
    ASAudioQueueAddListenerFailed = 305,
    /**
     * The audio queue (player) threw an error on start
     */
    ASAudioQueueStartFailed = 306,
    /**
     * The audio queue (player) threw an error on pause
     */
    ASAudioQueuePauseFailed = 307,
    /**
     * There was a mismatch in the audio queue's (player's) buffers.
     * Perhaps you set <[AudioStreamer bufferCount]> while the stream was running?
     */
    ASAudioQueueBufferMismatch = 308,
    /**
     * The audio queue (player) threw an error on stop
     */
    ASAudioQueueStopFailed = 309,
    /**
     * The audio queue (player) threw an error while flushing
     */
    ASAudioQueueFlushFailed = 310,
    /**
     * The buffer size is too small. Try increasing <[AudioStreamer bufferSize]>
     */
    ASAudioQueueBufferTooSmall = 311
};

/**
 * Possible reasons of why the streamer is now done.
 */
typedef NS_ENUM(NSInteger, ASDoneReason)
{
    /**
     * The streamer has ended with an error. Check <[AudioStreamer error]> for information
     */
    ASDoneError = -1,
    /**
     * The streamer is not done
     */
    ASNotDone = 0,
    /**
     * The streamer was stopped through the <[AudioStreamer stop]> method
     */
    ASDoneStopped = 1,
    /**
     * The streamer has reached the end of the file
     */
    ASDoneEOF = 2
};

typedef NS_ENUM(NSInteger, ASAudioQueueSeekResult)
{
    ASAudioQueueSeekFailed = -1,
    ASAudioQueueSeekImpossible = 0,
    ASAudioQueueSeekPerformed = 1
};


typedef void (^ASAudioQueueCallback)(void);


extern NSString * const ASAudioQueueErrorDomain;


@protocol ASAudioQueueHandlerDelegate <NSObject>

- (void)audioQueueStatusDidChange;
- (void)audioQueueFailedWithError:(NSError *)error;

- (void)audioQueueBitrateEstimationReady;

- (void)audioQueueBuffersFull;
- (void)audioQueueBuffersFree;

@end


@interface ASAudioQueueHandler : NSObject
{
    AudioQueueRef _audioQueue;

    ASAudioQueueState _state;

    AudioStreamBasicDescription _streamDescription;

    double _lastProgress; /* last calculated progress point */

    /* Once properties have been read, packets arrive, and the audio queue is
     created once the first packet arrives */

    /* When receiving audio data, raw data is placed into these buffers. The
     * buffers are essentially a "ring buffer of buffers" as each buffer is cycled
     * through and then freed when not in use. Each buffer can contain one or many
     * packets, so the packetDescs array is a list of packets which describes the
     * data in the next pending buffer (used to enqueue data into the AudioQueue
     * structure) */
    struct buffer **_buffers;      /* Information for each buffer */
    UInt32 _bufferCount;
    UInt32 _bufferFillCountToStart;
    AudioStreamPacketDescription _packetDescs[kAQMaxPacketDescs];
    UInt32 _packetsFilled;         /* number of valid entries in packetDescs */
    UInt32 _bytesFilled;           /* bytes in use in the pending buffer */
    unsigned int _fillBufferIndex; /* index of the pending buffer */
    UInt32 _buffersUsed;           /* Number of buffers in use */

    UInt64 _audioPacketsReceived;      /* The total number of audio packets we have received so far */
    UInt64 _processedPacketsSizeTotal; /* helps calculate the bit rate */

    /* cache state (see above description) */
    BOOL _waitingOnBuffer;
    struct queued_vbr_packet *_queued_vbr_head;
    struct queued_vbr_packet *_queued_vbr_tail;
    struct queued_cbr_packet *_queued_cbr_head;
    struct queued_cbr_packet *_queued_cbr_tail;

    BOOL _noMorePackets;
    BOOL _failedWithError;
    BOOL _seeking;
    BOOL _awaitingDataFromSeek;
    BOOL _vbr; /* Are we playing a VBR stream? */
    BOOL _bitrateNotification; /* notified that the bitrate is ready */

    NSMutableDictionary<NSNumber *, ASAudioQueueCallback> *_callbackQueue;
}

@property (nonatomic, weak) id <ASAudioQueueHandlerDelegate> delegate;

@property (nonatomic, assign) UInt32 bufferFillCountToStart;

@property (nonatomic, assign, readonly) UInt32 bufferSize;
@property (nonatomic, assign, readonly) UInt32 processedPacketsCount;
@property (nonatomic, assign, readonly) UInt64 audioDataBytesReceived;

@property (nonatomic, assign) double progressDelta; /* If the queue gets interrupted, e.g. seeks */

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithStreamDescription:(AudioStreamBasicDescription)asbd
                              bufferCount:(UInt32)bufferCount
                               packetSize:(UInt32)packetSize NS_DESIGNATED_INITIALIZER;

- (void)setPlaybackRate:(AudioQueueParameterValue)playbackRate;
- (void)setMagicCookie:(void *)cookieData withSize:(UInt32)cookieSize;
- (void)setVolume:(float)volume;
- (void)fadeTo:(float)volume duration:(float)duration;

- (BOOL)start;
- (BOOL)pause;
- (void)stop;

- (void)flushCachedData;

- (void)finalize;

- (BOOL)isPlaying;
- (BOOL)isPaused;
- (BOOL)isWaiting;
- (BOOL)isFinishing;
- (BOOL)isDone;

- (ASDoneReason)doneReason;

- (ASAudioQueueSeekResult)seekToPacket:(SInt64 *)seekPacket;

- (BOOL)progress:(double *)ret;
- (BOOL)estimateBitrate:(double *)rate;

- (void)processAudioPackets:(const void *)inputData
                numberBytes:(UInt32)numberBytes
              numberPackets:(UInt32)numberPackets
         packetDescriptions:(AudioStreamPacketDescription *)packetDescriptions;

- (void)queueCallback:(ASAudioQueueCallback)callback;

@end
