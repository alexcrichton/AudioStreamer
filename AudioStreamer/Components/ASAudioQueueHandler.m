//
//  ASAudioQueueHandler.m
//  AudioStreamer
//
//  Created by Bo Anderson on 30/08/2016.
//

#import "ASAudioQueueHandler.h"
#import "ASInternal.h"


#define kDefaultNumAQBufsToStart 8

#define kBitRateEstimationMinPackets 50


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
    BOOL inuse;
} buffer_t;


NSString * const ASAudioQueueErrorDomain = @"com.alexcrichton.audiostreamer.ASAudioQueueHandler";


@implementation ASAudioQueueHandler

/* AudioQueue callback notifying that a buffer is done, invoked on AudioQueue's
 * own personal threads, not the main thread */
static void ASAudioQueueOutputCallback(void *inClientData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer)
{
    ASAudioQueueHandler *handler = (__bridge ASAudioQueueHandler *)inClientData;
    [handler handleBufferCompleteForQueue:inAQ buffer:inBuffer];
}

/* AudioQueue callback that a property has changed, invoked on AudioQueue's own
 * personal threads like above */
static void ASAudioQueueIsRunningCallback(void *inUserData, AudioQueueRef inAQ, AudioQueuePropertyID inID)
{
    ASAudioQueueHandler *handler = (__bridge ASAudioQueueHandler *)inUserData;
    [handler handlePropertyChangeForQueue:inAQ propertyID:inID];
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
- (instancetype)initWithStreamDescription:(AudioStreamBasicDescription)asbd
                              bufferCount:(UInt32)bufferCount
                               packetSize:(UInt32)packetSize
{
    if ((self = [super init]))
    {
        _streamDescription = asbd;

        // create the audio queue
        OSStatus osErr = AudioQueueNewOutput(&asbd, ASAudioQueueOutputCallback,
                                             (__bridge void *)self, CFRunLoopGetMain(), NULL,
                                             0, &_audioQueue);
        if ([self checkStatusForError:osErr errorCode:ASAudioQueueCreationFailed])
            return self;

        // start the queue if it has not been started already
        // listen to the "isRunning" property
        osErr = AudioQueueAddPropertyListener(_audioQueue, kAudioQueueProperty_IsRunning,
                                              ASAudioQueueIsRunningCallback,
                                              (__bridge void *)self);
        if ([self checkStatusForError:osErr errorCode:ASAudioQueueAddListenerFailed])
            return self;

        _bufferCount = bufferCount;
        _bufferFillCountToStart = kDefaultNumAQBufsToStart; // Default
        _bufferSize = packetSize;

        // allocate audio queue buffers
        _buffers = malloc(_bufferCount * sizeof(buffer_t *));
        if (_buffers == NULL)
        {
            [self failWithErrorCode:ASAudioQueueBufferAllocationFailed];
            return self;
        }

        for (UInt32 i = 0; i < _bufferCount; ++i)
        {
            _buffers[i] = malloc(sizeof(buffer_t));
            if (_buffers[i] == NULL)
            {
                [self failWithErrorCode:ASAudioQueueBufferAllocationFailed];
                return self;
            }

            _buffers[i]->inuse = NO;
            _buffers[i]->packetStart = 0;
            _buffers[i]->packetCount = 0;

            osErr = AudioQueueAllocateBuffer(_audioQueue, _bufferSize, &(_buffers[i]->ref));
            if ([self checkStatusForError:osErr errorCode:ASAudioQueueBufferAllocationFailed])
                return self;
        }

        _callbackQueue = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)setPlaybackRate:(AudioQueueParameterValue)playbackRate
{
    UInt32 propVal = 1;
    AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_EnableTimePitch, &propVal, sizeof(propVal));

    propVal = kAudioQueueTimePitchAlgorithm_Spectral;
    AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_TimePitchAlgorithm, &propVal, sizeof(propVal));

    propVal = (playbackRate == 1.0f) ? 1 : 0;
    AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_TimePitchBypass, &propVal, sizeof(propVal));

    if (propVal == 0)
        AudioQueueSetParameter(_audioQueue, kAudioQueueParam_PlayRate, playbackRate);
}

- (void)setMagicCookie:(void *)cookieData withSize:(UInt32)cookieSize
{
    // set the cookie on the queue. Don't worry if it fails, all we'd to is return
    // anyway
    AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_MagicCookie, cookieData, cookieSize);
}

- (void)setVolume:(float)volume
{
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_Volume, volume);
}

- (void)fadeTo:(float)volume duration:(float)duration
{
    AudioQueueSetParameter(_audioQueue, kAudioQueueParam_VolumeRampTime, duration);
    [self setVolume:volume];
}

/**
 * @brief Sets up the audio queue and starts it
 *
 * This will set all the properties before starting the stream.
 *
 * @return YES if the AudioQueue was sucessfully set to start, NO if an error occurred
 */
- (BOOL)start
{
    OSStatus osErr = AudioQueueStart(_audioQueue, NULL);
    if ([self checkStatusForError:osErr errorCode:ASAudioQueueStartFailed])
        return NO;

    if (_state == ASAudioQueuePaused)
        [self setState:ASAudioQueuePlaying];
    else
        [self setState:ASAudioQueueWaitingForQueueToStart];

    return YES;
}

- (BOOL)pause
{
    OSStatus osErr = AudioQueuePause(_audioQueue);
    if ([self checkStatusForError:osErr errorCode:ASAudioQueuePauseFailed])
        return NO;

    [self setState:ASAudioQueuePaused];
    return YES;
}

- (void)stop
{
    if (_state == ASAudioQueueStopped) return;

    /* Attempt to save our last point of progress */
    [self progress:&_lastProgress];

    if (![self isDone])
        [self setState:ASAudioQueueStopped shouldNotify:NO];

    if (_audioQueue)
    {
        AudioQueueStop(_audioQueue, true);
        OSStatus osErr = AudioQueueDispose(_audioQueue, true);
        ASAssert(osErr == noErr, @"AudioQueueDispose returned error \"%@\"", [[self class] descriptionForAQErrorCode:osErr]);
        _audioQueue = NULL;
    }
    if (_buffers != NULL)
    {
        for (UInt32 i = 0; i < _bufferCount; i++) {
            free(_buffers[i]);
        }
        free(_buffers);
        _buffers = NULL;
    }
    [self flushCachedData];

    if (_state == ASAudioQueueStopped)
        [[self delegate] audioQueueStatusDidChange];
}

- (void)flushCachedData
{
    if (_waitingOnBuffer) _waitingOnBuffer = NO;
    queued_vbr_packet_t *cur_vbr = _queued_vbr_head;
    queued_cbr_packet_t *cur_cbr = _queued_cbr_head;
    while (cur_vbr != NULL || cur_cbr != NULL)
    {
        if (cur_vbr != NULL)
        {
            queued_vbr_packet_t *tmp = cur_vbr->next;
            free(cur_vbr);
            cur_vbr = tmp;
        }
        else
        {
            queued_cbr_packet_t *tmp = cur_cbr->next;
            free(cur_cbr);
            cur_cbr = tmp;
        }
    }
    _queued_vbr_head = _queued_vbr_tail = NULL;
    _queued_cbr_head = _queued_cbr_tail = NULL;
}

- (void)dealloc
{
    [self stop];
}

- (void)finalize
{
    _noMorePackets = YES;

    /* Flush out extra data if necessary */
    if (_bytesFilled > 0)
    {
        /* Disregard return value because we're at the end of the stream anyway
         so there's no bother in pausing it */
        if ([self enqueueBuffer] < 0) return;
    }

    /* If we never received any packets, then we're done now */
    if (_state == ASAudioQueueWaitingForData)
    {
        if (_buffersUsed > 0)
        {
            /* If we got some data, the stream was either short or interrupted early.
             * We have some data so go ahead and play that. */
            [self start];
        }
        else if (_awaitingDataFromSeek)
        {
            /* If a seek was performed, and no data came back, then we probably
             seeked to the end or near the end of the stream */
            [self setState:ASAudioQueueDone];
        }
        else
        {
            /* In other cases then we just hit an error */
            [self failWithErrorCode:ASAudioQueueAudioDataNotFound];
        }
    }
}

- (void)setState:(ASAudioQueueState)state
{
    [self setState:state shouldNotify:YES];
}

- (void)setState:(ASAudioQueueState)state shouldNotify:(BOOL)shouldNotify
{
    ASLogInfo(@"transitioning to state: %tu", state);

    _state = state;
    if (shouldNotify)
        [[self delegate] audioQueueStatusDidChange];
}

- (BOOL)checkStatusForError:(OSStatus)status errorCode:(ASAudioQueueErrorCode)errorCode
{
    if (status != noErr)
    {
        [self failWithErrorCode:errorCode extraInfo:[[self class] descriptionForAQErrorCode:status]];
        return YES;
    }
    return NO;
}

- (void)failWithErrorCode:(ASAudioQueueErrorCode)errorCode
{
    [self failWithErrorCode:errorCode extraInfo:@""];
}

- (void)failWithErrorCode:(ASAudioQueueErrorCode)errorCode extraInfo:(NSString *)extraInfo
{
    if ([self isDone]) return;

    _failedWithError = YES;

    ASLogError(@"Audio queue encountered an error: %@ (%@)", [[self class] descriptionForErrorCode:errorCode], extraInfo);

    NSDictionary *userInfo = @{NSLocalizedDescriptionKey:
                                   NSLocalizedString([[self class] descriptionForErrorCode:errorCode], nil),
                               NSLocalizedFailureReasonErrorKey:
                                   NSLocalizedString(extraInfo, nil)};
    NSError *error = [NSError errorWithDomain:ASAudioQueueErrorDomain code:errorCode userInfo:userInfo];

    [self stop];
    [self setState:ASAudioQueueDone];
    [[self delegate] audioQueueFailedWithError:error];
}

+ (NSString *)descriptionForErrorCode:(ASAudioQueueErrorCode)errorCode
{
    switch (errorCode)
    {
        case ASAudioQueueAudioDataNotFound:
            return @"No audio data found";
        case ASAudioQueueCreationFailed:
            return @"Audio queue creation failed";
        case ASAudioQueueBufferAllocationFailed:
            return @"Audio queue buffer allocation failed";
        case ASAudioQueueEnqueueFailed:
            return @"Queueing of audio buffer failed";
        case ASAudioQueueAddListenerFailed:
            return @"Failed to add listener to audio queue";
        case ASAudioQueueStartFailed:
            return @"Failed to start the audio queue";
        case ASAudioQueuePauseFailed:
            return @"Failed to pause the audio queue";
        case ASAudioQueueBufferMismatch:
            return @"Audio queue buffer mismatch";
        case ASAudioQueueStopFailed:
            return @"Audio queue stop failed";
        case ASAudioQueueFlushFailed:
            return @"Failed to flush the audio queue";
        case ASAudioQueueBufferTooSmall:
            return @"The audio buffer was too small to handle the audio packets.";
    }
}

+ (NSString *)descriptionForAQErrorCode:(OSStatus)osErr
{
    switch (osErr)
    {
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

- (BOOL)isPlaying
{
    return _state == ASAudioQueuePlaying;
}

- (BOOL)isPaused
{
    return _state == ASAudioQueuePaused;
}

- (BOOL)isWaiting
{
    return _state == ASAudioQueueWaitingForData || _state == ASAudioQueueWaitingForQueueToStart;
}

- (BOOL)isFinishing
{
    return _state == ASAudioQueueFinishing;
}

- (BOOL)isDone
{
    return _state == ASAudioQueueDone || _state == ASAudioQueueStopped;
}

- (ASDoneReason)doneReason
{
    switch (_state)
    {
        case ASAudioQueueStopped:
            return ASDoneStopped;
        case ASAudioQueueDone:
            if (_failedWithError)
                return ASDoneError;
            else
                return ASDoneEOF;
        default:
            break;
    }
    return ASNotDone;
}

- (ASAudioQueueSeekResult)seekToPacket:(SInt64 *)seekPacket
{
    assert(!_seeking);
    _seeking = YES;

    BOOL foundCachedPacket = NO;
    BOOL foundQueuedPacket = NO;
    if ((_processedPacketsCount - 1) < (UInt64)*seekPacket)
    {
        queued_vbr_packet_t *cur_vbr = _queued_vbr_head;
        queued_cbr_packet_t *cur_cbr = _queued_cbr_head;
        for (UInt32 i = 0; cur_vbr != NULL || cur_cbr != NULL; i++)
        {
            if ((_processedPacketsCount + i) == (UInt64)*seekPacket)
            {
                foundCachedPacket = YES;
                break;
            }

            if (cur_vbr != NULL)
            {
                queued_vbr_packet_t *tmp_vbr = cur_vbr->next;
                cur_vbr = tmp_vbr;
            }
            else if (cur_cbr != NULL)
            {
                queued_cbr_packet_t *tmp_cbr = cur_cbr->next;
                cur_cbr = tmp_cbr;
            }
        }
    }
    else if ((UInt64)*seekPacket < _audioPacketsReceived && *seekPacket != 0)
    {
        foundQueuedPacket = YES;
    }

    buffer_t **oldBuffers;
    if (foundQueuedPacket)
    {
        oldBuffers = malloc(_bufferCount * sizeof(buffer_t *));
        if (oldBuffers == NULL)
        {
            [self failWithErrorCode:ASAudioQueueBufferAllocationFailed];
            return ASAudioQueueSeekFailed;
        }
        memcpy(oldBuffers, _buffers, _bufferCount * sizeof(AudioQueueBufferRef));
    }

    _waitingOnBuffer = NO;

    /* Stop audio for now */
    OSStatus osErr = AudioQueueStop(_audioQueue, true);
    if ([self checkStatusForError:osErr errorCode:ASAudioQueueStopFailed])
    {
        if (foundQueuedPacket)
        {
            free(oldBuffers);
        }
        _seeking = NO;
        return ASAudioQueueSeekFailed;
    }

    if (foundCachedPacket)
    {
        UInt32 packetsRemoved = 0;
        UInt32 bytesRemoved = 0;
        queued_vbr_packet_t *cur_vbr = _queued_vbr_head;
        queued_cbr_packet_t *cur_cbr = _queued_cbr_head;
        for (UInt32 i = 0; cur_vbr != NULL || cur_cbr != NULL; i++)
        {
            if ((_processedPacketsCount + i) == (UInt64)*seekPacket)
            {
                break;
            }

            if (cur_vbr != NULL)
            {
                queued_vbr_packet_t *tmp_vbr = cur_vbr->next;
                free(cur_vbr);
                cur_vbr = tmp_vbr;
                packetsRemoved++;
            }
            else if (cur_cbr != NULL)
            {
                queued_cbr_packet_t *tmp_cbr = cur_cbr->next;
                bytesRemoved += cur_cbr->byteSize;
                free(cur_cbr);
                cur_cbr = tmp_cbr;
            }
        }
        _queued_vbr_head = cur_vbr;
        _queued_cbr_head = cur_cbr;

        _processedPacketsCount += (_vbr ? packetsRemoved : bytesRemoved);

        [self enqueueCachedData];
        _waitingOnBuffer = (_queued_vbr_head != NULL || _queued_cbr_head != NULL);

        *seekPacket = _processedPacketsCount;

        if (![self start]) return ASAudioQueueSeekFailed;

        _seeking = NO;
        return ASAudioQueueSeekPerformed;
    }
    else if (foundQueuedPacket)
    {
        UInt32 seekPacketIdx = _bufferCount + 1;
        UInt32 endPacketIdx = _bufferCount + 1;
        SInt64 startPacket = *seekPacket;
        SInt64 endPacket = *seekPacket;
        UInt32 nextFillBuffer = _fillBufferIndex +1;
        if (nextFillBuffer >= _bufferCount) nextFillBuffer = 0;
        UInt32 i = nextFillBuffer;
        while (i != _fillBufferIndex)
        {
            UInt32 packetStart = oldBuffers[i]->packetStart;
            UInt32 packetCount = oldBuffers[i]->packetCount;
            if (packetCount != 0)
            {
                UInt32 packetEnd = packetStart + packetCount - 1;
                if (packetEnd >= *seekPacket)
                {
                    if (packetEnd >= endPacket)
                    {
                        endPacketIdx = i;
                        endPacket = packetEnd;
                    }
                    if (packetStart <= startPacket)
                    {
                        seekPacketIdx = i;
                        startPacket = packetStart;
                    }
                }
            }
            i++;
            if (i >= _bufferCount) i = 0;
        }
        if (seekPacketIdx != (_bufferCount + 1))
        {
            i = seekPacketIdx;
            UInt32 nextBuffer = endPacketIdx + 1;
            if (nextBuffer >= _bufferCount) nextBuffer = 0;
            BOOL start = YES;
            while (i != nextBuffer || start)
            {
                start = NO;
                UInt32 packetStart = oldBuffers[i]->packetStart;
                UInt32 packetCount = oldBuffers[i]->packetCount;
                if (packetCount > 0)
                {
                    UInt32 packetEnd = packetStart + oldBuffers[i]->packetCount - 1;
                    _buffers[i]->inuse = (packetEnd >= *seekPacket);
                }
                i++;
                if (i >= _bufferCount) i = 0;
            }
            i = seekPacketIdx;
            _buffersUsed = 0;
            while (_buffers[i]->inuse)
            {
                AudioQueueBufferRef fillBuf = oldBuffers[i]->ref;

                if (_vbr) {
                    osErr = AudioQueueEnqueueBuffer(_audioQueue, fillBuf, oldBuffers[i]->packetCount,
                                                    oldBuffers[i]->packetDescs);
                } else {
                    osErr = AudioQueueEnqueueBuffer(_audioQueue, fillBuf, 0, NULL);
                }
                if ([self checkStatusForError:osErr errorCode:ASAudioQueueEnqueueFailed])
                {
                    free(oldBuffers);
                    return ASAudioQueueSeekFailed;
                }

                _buffersUsed++;
                i++;
                if (i >= _bufferCount) i = 0;
                if (_buffersUsed == _bufferCount) break;
            }
            _fillBufferIndex = i;
            _processedPacketsCount -= _packetsFilled;
            _packetsFilled = _bytesFilled = 0;

            [self enqueueCachedData];
            _waitingOnBuffer = (_queued_vbr_head != NULL || _queued_cbr_head != NULL);

            *seekPacket = oldBuffers[seekPacketIdx]->packetStart;

            free(oldBuffers);

            if (![self start]) return ASAudioQueueSeekFailed;

            _seeking = NO;
            return ASAudioQueueSeekPerformed;
        }
        free(oldBuffers);
    }

    _processedPacketsCount = (UInt32)seekPacket;
    _audioPacketsReceived = (UInt64)seekPacket;

    [self setState:ASAudioQueueWaitingForData];
    _noMorePackets = NO;
    _awaitingDataFromSeek = YES;

    _fillBufferIndex = 0;
    _packetsFilled = 0;
    _bytesFilled = 0;
    _audioDataBytesReceived = 0;
    _waitingOnBuffer = (_queued_vbr_head != NULL || _queued_cbr_head != NULL);

    _seeking = NO;
    return ASAudioQueueSeekImpossible;
}

- (BOOL)progress:(double *)ret
{
    double sampleRate = _streamDescription.mSampleRate;
    if (_state == ASAudioQueueStopped)
    {
        *ret = _lastProgress;
        return YES;
    }
    if (sampleRate <= 0 || (![self isPlaying] && ![self isPaused] && ![self isFinishing]))
        return NO;

    AudioTimeStamp queueTime;
    Boolean discontinuity;
    OSStatus osErr = AudioQueueGetCurrentTime(_audioQueue, NULL, &queueTime, &discontinuity);
    if (osErr) {
        return NO;
    }

    double progress = _progressDelta + queueTime.mSampleTime / sampleRate;
    if (progress < 0.0) {
        progress = 0.0;
    }

    _lastProgress = progress;
    *ret = progress;
    return YES;
}

- (BOOL)estimateBitrate:(double *)rate
{
    if (_processedPacketsCount > kBitRateEstimationMinPackets)
    {
        double averagePacketByteSize = _processedPacketsSizeTotal / (double)_processedPacketsCount;
        /* bits/byte x bytes/packet x packets/sec = bits/sec */
        *rate = averagePacketByteSize;
        return YES;
    }
    return NO;
}


- (void)processAudioPackets:(const void *)inInputData
                numberBytes:(UInt32)inNumberBytes
              numberPackets:(UInt32)inNumberPackets
         packetDescriptions:(AudioStreamPacketDescription *)inPacketDescriptions
{
    assert(!_noMorePackets);

    _awaitingDataFromSeek = NO;
    _audioDataBytesReceived += inNumberBytes;
    _audioPacketsReceived += inNumberPackets;

    if (inPacketDescriptions)
    {
        _vbr = YES;

        /* Place each packet into a buffer and then send each buffer into the audio
         queue */
        UInt32 i;
        for (i = 0; i < inNumberPackets && !_waitingOnBuffer && _queued_vbr_head == NULL; i++)
        {
            AudioStreamPacketDescription *desc = &inPacketDescriptions[i];
            int ret = [self processVBRPacket:(inInputData + desc->mStartOffset) desc:desc];
            if (ret < 0)
            {
                [self failWithErrorCode:ASAudioQueueEnqueueFailed];
                return;
            }
            if (ret == 0) break;
        }
        if (i == inNumberPackets) return;

        for (; i < inNumberPackets; i++)
        {
            /* Allocate the packet */
            UInt32 size = inPacketDescriptions[i].mDataByteSize;
            queued_vbr_packet_t *packet = malloc(sizeof(queued_vbr_packet_t) + size);
            if (packet == NULL)
            {
                [self failWithErrorCode:ASAudioQueueEnqueueFailed];
                return;
            }

            /* Prepare the packet */
            packet->next = NULL;
            packet->desc = inPacketDescriptions[i];
            packet->desc.mStartOffset = 0;
            memcpy(packet->data, inInputData + inPacketDescriptions[i].mStartOffset,
                   size);

            if (_queued_vbr_head == NULL)
            {
                _queued_vbr_head = _queued_vbr_tail = packet;
            }
            else
            {
                _queued_vbr_tail->next = packet;
                _queued_vbr_tail = packet;
            }
        }
    }
    else
    {
        UInt32 packetSize = (inNumberBytes / inNumberPackets);
        UInt32 i;
        for (i = 0; i < inNumberPackets && !_waitingOnBuffer && _queued_cbr_head == NULL; i++)
        {
            int ret = [self processCBRPacket:(inInputData + (packetSize * i))
                                    byteSize:packetSize];
            if (ret < 0)
            {
                [self failWithErrorCode:ASAudioQueueEnqueueFailed];
                return;
            }
            if (ret == 0) break;
        }
        if (i == inNumberPackets) return;

        for (; i < inNumberPackets; i++)
        {
            /* Allocate the packet */
            queued_cbr_packet_t *packet = malloc(sizeof(queued_cbr_packet_t) + packetSize);
            if (packet == NULL)
            {
                [self failWithErrorCode:ASAudioQueueEnqueueFailed];
                return;
            }

            /* Prepare the packet */
            packet->next = NULL;
            packet->byteSize = packetSize;
            memcpy(packet->data, inInputData + (packetSize * i), packetSize);

            if (_queued_cbr_head == NULL)
            {
                _queued_cbr_head = _queued_cbr_tail = packet;
            }
            else
            {
                _queued_cbr_tail->next = packet;
                _queued_cbr_tail = packet;
            }
        }
    }
}

- (int)processVBRPacket:(const void *)data desc:(AudioStreamPacketDescription *)desc
{
    assert(_audioQueue != NULL);
    UInt32 packetSize = desc->mDataByteSize;

    /* This shouldn't happen because most of the time we read the packet buffer
     size from the file stream, but if we resorted to guessing it we could
     come up too small here. Developers may have to set the bufferCount property. */
    if (packetSize > _bufferSize)
    {
        [self failWithErrorCode:ASAudioQueueBufferTooSmall];
        return -1;
    }

    // if the space remaining in the buffer is not enough for this packet, then
    // enqueue the buffer and wait for another to become available.
    if (_bufferSize - _bytesFilled < packetSize)
    {
        int hasFreeBuffer = [self enqueueBuffer];
        if (hasFreeBuffer <= 0) {
            return hasFreeBuffer;
        }
        assert(_bytesFilled == 0);
    }

    _buffers[_fillBufferIndex]->packetStart = _processedPacketsCount;

    /* global statistics */
    _processedPacketsSizeTotal += 8.0 * packetSize / (_streamDescription.mFramesPerPacket / _streamDescription.mSampleRate);
    _processedPacketsCount++;
    if (_processedPacketsCount > kBitRateEstimationMinPackets && !_bitrateNotification)
    {
        _bitrateNotification = YES;
        [[self delegate] audioQueueBitrateEstimationReady];
    }

    // copy data to the audio queue buffer
    AudioQueueBufferRef buf = _buffers[_fillBufferIndex]->ref;
    memcpy(buf->mAudioData + _bytesFilled, data, (size_t)packetSize);

    // fill out packet description to pass to enqueue() later on
    _buffers[_fillBufferIndex]->packetDescs[_packetsFilled] = *desc;
    // Make sure the offset is relative to the start of the audio buffer
    _buffers[_fillBufferIndex]->packetDescs[_packetsFilled].mStartOffset = _bytesFilled;
    // keep track of bytes filled and packets filled
    _bytesFilled += packetSize;
    _packetsFilled++;

    /* If filled our buffer with packets, then commit it to the system */
    if (_packetsFilled >= kAQMaxPacketDescs) return [self enqueueBuffer];
    return 1;
}

- (int)processCBRPacket:(const void *)data byteSize:(UInt32)byteSize
{
    assert(_audioQueue != NULL);

    size_t bufSpaceRemaining = _bufferSize - _bytesFilled;
    if (bufSpaceRemaining < byteSize)
    {
        int hasFreeBuffer = [self enqueueBuffer];
        if (hasFreeBuffer <= 0) {
            return hasFreeBuffer;
        }
        assert(_bytesFilled == 0);
    }

    AudioQueueBufferRef buf = _buffers[_fillBufferIndex]->ref;
    memcpy(buf->mAudioData + _bytesFilled, data, byteSize);

    _bytesFilled += byteSize;
    _packetsFilled += byteSize;
    _processedPacketsCount += byteSize;

    _buffers[_fillBufferIndex]->packetStart = _processedPacketsCount;

    /* Bitrate isn't estimated with these packets.
     * It's safe to calculate the bitrate as soon as we start getting audio. */
    if (!_bitrateNotification)
    {
        _bitrateNotification = YES;
        [[self delegate] audioQueueBitrateEstimationReady];
    }

    return 1;
}

- (void)queueCallback:(ASAudioQueueCallback)callback
{
    _callbackQueue[@(_audioPacketsReceived)] = callback;
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
- (int)enqueueBuffer
{
    assert(!_buffers[_fillBufferIndex]->inuse);
    _buffers[_fillBufferIndex]->inuse = YES;
    _buffersUsed++;

    // enqueue buffer
    AudioQueueBufferRef fillBuf = _buffers[_fillBufferIndex]->ref;
    fillBuf->mAudioDataByteSize = _bytesFilled;

    OSStatus osErr;
    if (_vbr) {
        osErr = AudioQueueEnqueueBuffer(_audioQueue, fillBuf, _packetsFilled, _buffers[_fillBufferIndex]->packetDescs);
    } else {
        osErr = AudioQueueEnqueueBuffer(_audioQueue, fillBuf, 0, NULL);
    }
    if ([self checkStatusForError:osErr errorCode:ASAudioQueueEnqueueFailed])
        return -1;

    _buffers[_fillBufferIndex]->packetCount = _packetsFilled;
    _buffers[_fillBufferIndex]->packetStart -= (_packetsFilled - 1);
    ASLogDebug(@"committed buffer %d", _fillBufferIndex);

    if (_state == ASAudioQueueWaitingForData)
    {
        /* Once we have a small amount of queued data, then we can go ahead and
         * start the audio queue and the file stream should remain ahead of it */
        if ((_bufferCount < _bufferFillCountToStart && _buffersUsed >= _bufferCount)
            || _buffersUsed >= _bufferFillCountToStart)
        {
            if (![self start]) return -1;
        }
    }

    /* move on to the next buffer and wait for it to be in use */
    if (++_fillBufferIndex >= _bufferCount) _fillBufferIndex = 0;
    _bytesFilled   = 0;    // reset bytes filled
    _packetsFilled = 0;    // reset packets filled

    /* If we have no more queued data, and the stream has reached its end, then
     we're not going to be enqueueing any more buffers to the audio stream. In
     this case flush it out and asynchronously stop it */
    if (_queued_vbr_head == NULL && _queued_cbr_head == NULL && _noMorePackets)
    {
        osErr = AudioQueueFlush(_audioQueue);
        if ([self checkStatusForError:osErr errorCode:ASAudioQueueFlushFailed])
            return -1;
    }
    
    if (_buffers[_fillBufferIndex]->inuse)
    {
        ASLogDebug(@"waiting for buffer %d", _fillBufferIndex);
        [[self delegate] audioQueueBuffersFull];
        _waitingOnBuffer = YES;
        return 0;
    }
    return 1;
}

/**
 * @brief Internal helper for sending cached packets to the audio queue
 *
 * This method is enqueued for delivery when an audio buffer is freed
 */
- (void)enqueueCachedData
{
    assert(!_waitingOnBuffer);
    assert(!_buffers[_fillBufferIndex]->inuse);
    ASLogDebug(@"processing some cached data");
    
    /* Queue up as many packets as possible into the buffers */
    while (_queued_vbr_head != NULL || _queued_cbr_head != NULL)
    {
        if (_queued_cbr_head != NULL)
        {
            int ret = [self processCBRPacket:_queued_cbr_head->data byteSize:_queued_cbr_head->byteSize];
            if (ret < 0) {
                [self failWithErrorCode:ASAudioQueueEnqueueFailed];
                return;
            }
            if (ret == 0) break;
            
            queued_cbr_packet_t *next_cbr = _queued_cbr_head->next;
            free(_queued_cbr_head);
            _queued_cbr_head = next_cbr;
        }
        else
        {
            int ret = [self processVBRPacket:_queued_vbr_head->data desc:&_queued_vbr_head->desc];
            if (ret < 0) {
                [self failWithErrorCode:ASAudioQueueEnqueueFailed];
                return;
            }
            if (ret == 0) break;
            
            queued_vbr_packet_t *next_vbr = _queued_vbr_head->next;
            free(_queued_vbr_head);
            _queued_vbr_head = next_vbr;
        }
    }
    
    /* If we finished queueing all our saved packets, we can re-schedule the
     * stream to run */
    if (_queued_vbr_head == NULL && _queued_cbr_head == NULL)
    {
        _queued_vbr_tail = NULL;
        _queued_cbr_tail = NULL;
        
        [[self delegate] audioQueueBuffersFree];
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
- (void)handleBufferCompleteForQueue:(AudioQueueRef)inAQ buffer:(AudioQueueBufferRef)inBuffer
{
    /* we're only registered for one audio queue... */
    assert(inAQ == _audioQueue);
    /* Sanity check to make sure we're on the right thread */
    assert([NSThread currentThread] == [NSThread mainThread]);
    
    /* Figure out which buffer just became free, and it had better damn well be
     one of our own buffers */
    UInt32 idx;
    for (idx = 0; idx < _bufferCount; idx++) {
        if (_buffers[idx]->ref == inBuffer) break;
    }
    if (idx >= _bufferCount)
    {
        [self failWithErrorCode:ASAudioQueueBufferMismatch];
    }
    assert(_buffers[idx]->inuse);
    
    ASLogDebug(@"buffer %u finished", (unsigned int)idx);
    
    /* Signal the buffer is no longer in use */
    _buffers[idx]->inuse = NO;
    _buffersUsed--;

    if ([_callbackQueue count] > 0) {
        UInt32 nextIdx = idx + 1;
        if (nextIdx == _bufferCount) nextIdx = 0;
        buffer_t *nextBuffer = _buffers[nextIdx];

        NSArray<NSNumber *> *packetsToCheck = [[_callbackQueue allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *metadataPacketNum in packetsToCheck) {
            unsigned long metadataPacketIdx = [metadataPacketNum unsignedLongValue];
            ASAudioQueueCallback callback = _callbackQueue[metadataPacketNum];

            if (nextBuffer->packetStart >= metadataPacketIdx) {
                [_callbackQueue removeObjectForKey:metadataPacketNum];
                callback();
            } else if ((nextBuffer->packetStart + nextBuffer->packetCount) >= metadataPacketIdx) {
                UInt32 packetOffset = (UInt32)(metadataPacketIdx - nextBuffer->packetStart);
                UInt64 framesToWait = _streamDescription.mFramesPerPacket * packetOffset;
                if (framesToWait == 0 && _vbr) {
                    for (UInt32 i = 0; i < packetOffset; i++) {
                        framesToWait += nextBuffer->packetDescs[i].mVariableFramesInPacket;
                    }
                }
                [_callbackQueue removeObjectForKey:metadataPacketNum];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(framesToWait / _streamDescription.mSampleRate * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    callback();
                });
            } else {
                break;
            }
        }
    }
    
    /* If we're done with the buffers because the stream is dying, then there's no
     * need to call more methods on it */
    if (_state == ASAudioQueueStopped)
    {
        return;
    }
    /* If there is absolutely no more data which will ever come into the stream,
     * then we're done with the audio */
    else if (_buffersUsed == 0 && _queued_vbr_head == NULL && _queued_cbr_head == NULL && !_seeking && _noMorePackets)
    {
        assert(!_waitingOnBuffer);
        [self setState:ASAudioQueueFinishing];
        AudioQueueStop(_audioQueue, false);
    }
    /* If we are out of buffers then we aren't buffering fast enough */
    else if (_buffersUsed == 0 && ![self isDone] && ![self isWaiting])
    {
        [self pause];
        [self setState:ASAudioQueueWaitingForData];
    }
    /* If we just opened up a buffer so try to fill it with some cached
     * data if there is any available */
    else if (_waitingOnBuffer)
    {
        _waitingOnBuffer = NO;
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
- (void)handlePropertyChangeForQueue:(AudioQueueRef)inAQ propertyID:(AudioQueuePropertyID)inID
{
    /* Sanity check to make sure we're on the expected thread */
    assert([NSThread currentThread] == [NSThread mainThread]);
    /* We only asked for one property, so the audio queue had better damn well
     only tell us about this property */
    assert(inID == kAudioQueueProperty_IsRunning);
    
    if (_state == ASAudioQueueWaitingForQueueToStart)
    {
        [self setState:ASAudioQueuePlaying];
    }
    else if (![self isDone] && !_seeking)
    {
        UInt32 running;
        UInt32 output = sizeof(running);
        OSStatus osErr = AudioQueueGetProperty(_audioQueue, kAudioQueueProperty_IsRunning, &running, &output);
        if (!osErr && !running)
        {
            [self setState:ASAudioQueueDone shouldNotify:NO];
            /* Let the method exit before notifying the world. */
            dispatch_async(dispatch_get_main_queue(), ^{
                [[self delegate] audioQueueStatusDidChange];
            });
        }
    }
}

@end
