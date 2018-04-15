//
//  AudioStreamer.h
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

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import "ASLogger.h"
#import "ASCFReadStreamHandler.h"
#import "ASAudioFileStreamHandler.h"
#import "ASAudioQueueHandler.h"

@class AudioStreamer;

NS_ASSUME_NONNULL_BEGIN

/**
 * The AudioStreamerDelegate protocol provides callbacks for events that may happen
 * during the stream. This replaces the former NSNotification system used in Matt
 * Gallagher's original version.
 */
@protocol AudioStreamerDelegate <NSObject>

@optional
/**
 * @brief Called when the stream status has changed
 *
 * @param sender The streamer that called this method
 *
 * @see [AudioStreamer isPlaying]
 * @see [AudioStreamer isPaused]
 * @see [AudioStreamer isDone]
 * @see [AudioStreamer isWaiting]
 */
- (void)streamerStatusDidChange:(AudioStreamer *)sender;

/**
 * @brief Called when the stream has collected enough data to calculate the bitrate
 *
 * @details This is the earliest that seeks can be performed and, in some streams,
 * the earliest that the duration can be calculated.
 *
 * @param sender The streamer that called this method
 *
 * @see [AudioStreamer calculatedBitRate:]
 */
- (void)streamerBitrateIsReady:(AudioStreamer *)sender;

/**
 * @brief Called when the stream's current song has changed
 *
 * @param sender The streamer that called this method
 * @param currentSong The new current song. This may be nil when opening a new stream
 */
- (void)streamer:(AudioStreamer *)sender didUpdateCurrentSong:(nullable NSString *)currentSong;

@end

/**
 * This class is implemented on top of Apple's AudioQueue framework. This
 * framework is much too low-level for must use cases, so this class
 * encapsulates the functionality to provide a nicer interface. The interface
 * still requires some management, but it is far more sane than dealing with the
 * AudioQueue structures yourself.
 *
 * This class is essentially a pipeline of three components to get audio to the
 * speakers:
 *
 *              CFReadStream => AudioFileStream => AudioQueue
 *
 * ### CFReadStream
 *
 * The method of reading HTTP data is using the low-level CFReadStream class
 * because it allows configuration of proxies and scheduling/rescheduling on the
 * event loop. All data read from the HTTP stream is piped into the
 * AudioFileStream which then parses all of the data. This stage of the pipeline
 * also flags that events are happening to prevent a timeout. All network
 * activity occurs on the thread which started the audio stream.
 *
 * ### AudioFileStream
 *
 * This stage is implemented by Apple frameworks, and parses all audio data.  It
 * is composed of two callbacks which receive data. The first callback invoked
 * in series is one which is notified whenever a new property is known about the
 * audio stream being received. Once all properties have been read, the second
 * callback beings to be invoked, and this callback is responsible for dealing
 * with packets.
 *
 * The second callback is invoked whenever complete "audio packets" are
 * available to send to the audio queue. This stage is invoked on the call stack
 * of the stream which received the data (synchronously with receiving the
 * data).
 *
 * Packets received are buffered in a static set of buffers allocated by the
 * audio queue instance. When a buffer is full, it is committed to the audio
 * queue, and then the next buffer is moved on to. Multiple packets can possibly
 * fit in one buffer. When committing a buffer, if there are no more buffers
 * available, then the http read stream is unscheduled from the run loop and all
 * currently received data is stored aside for later processing.
 *
 * ### AudioQueue
 *
 * This final stage is also implemented by Apple, and receives all of the full
 * buffers of data from the AudioFileStream's parsed packets. The implementation
 * manages its own set of threads, but callbacks are invoked on the main thread.
 * The two callbacks that the audio stream is interested in are playback state
 * changing and audio buffers being freed.
 *
 * When a buffer is freed, then it is marked as so, and if the stream was
 * waiting for a buffer to be freed a message to empty the queue as much as
 * possible is sent to the main thread's run loop. Otherwise no extra action
 * need be performed.
 *
 * The main purpose of knowing when the playback state changes is to change the
 * state of the player accordingly.
 *
 * ## Errors
 *
 * There are a large number of places where error can happen, and the stream can
 * bail out at any time with an error. Each error has its own code and
 * corresponding string representation. Any error will halt the entire audio
 * stream and cease playback. Some errors might want to be handled by the
 * manager of the AudioStreamer class, but others normally indicate that the
 * remote stream just won't work.  Occasionally errors might reflect a lack of
 * local resources.
 *
 * Error information can be learned from the <error> property.
 *
 * ## Seeking
 *
 * To seek inside an audio stream, the bit rate must be known along with some
 * other metadata, but this is not known until after the stream has started.
 * For this reason the seek can fail if not enough data is known yet.
 *
 * If a seek succeeds, however, the actual method of doing so is as follows.
 * First, open a stream at position 0 and collect data about the stream, when
 * the seek is requested, cancel the stream and re-open the connection with the
 * proper byte offset. This second stream is then used to put data through the
 * pipelines.
 *
 * ## Example usage
 *
 * An audio stream is a one-shot thing. Once initialized, the source cannot be
 * changed and a single audio stream cannot be re-used. To do this, multiple
 * AudioStreamer objects need to be created/managed.
 */
@interface AudioStreamer : NSObject
{
  ASCFReadStreamHandler * _Nullable _readStreamHandler;
  ASAudioFileStreamHandler * _Nullable _fileStreamHandler;
  ASAudioQueueHandler * _Nullable _audioQueueHandler;

	ASProxyInformation *_proxyInfo;

	BOOL _started;
  BOOL _bitrateEstimated; /* Was the last bitrate calculation an estimate? */
}

/** @name Creating an audio stream */

/**
 * @brief Initialize a new audio stream with the specified url
 *
 * @details The created stream has not started playback. This gives an opportunity to
 * configure the rest of the stream as necessary. To start playback, send the
 * stream an explicit <start> message.
 *
 * @param url The remote source of audio
 * @return The stream to configure and being playback with
 */
- (instancetype)initWithURL:(NSURL *)url;

/**
 * @brief Allocate and initialize a new audio stream with the specified url
 *
 * @details The created stream has not started playback. This gives an opportunity to
 * configure the rest of the stream as necessary. To start playback, send the
 * stream an explicit <start> message.
 *
 * @param url The remote source of audio
 * @return The stream to configure and being playback with
 */
+ (instancetype)streamWithURL:(NSURL *)url;

/** @name Properties of the audio stream */

/**
 * @brief Sets the delegate for event callbacks
 *
 * @see AudioStreamerDelegate
 */
@property (nonatomic, readwrite, weak, nullable) id <AudioStreamerDelegate> delegate;

/**
 * @brief Tests whether the stream is playing
 *
 * @details Returns YES if the stream is playing, NO Otherwise
 */
@property (nonatomic, getter=isPlaying, readonly) BOOL playing;

/**
 * @brief Tests whether the stream is paused
 *
 * @details A stream is not paused if it is waiting for data. A stream is paused if and
 * only if it used to be playing, but the it was paused via the <pause> method.
 *
 * Returns YES if the stream is paused, NO Otherwise
 */
@property (nonatomic, getter=isPaused, readonly) BOOL paused;

/**
 * @brief Tests whether the stream is waiting
 *
 * @details This could either mean that we're waiting on data from the network or waiting
 * for some event with the AudioQueue instance.
 *
 * Returns YES if the stream is waiting, NO Otherwise
 */
@property (nonatomic, getter=isWaiting, readonly) BOOL waiting;

/**
 * @brief Tests whether the stream is done with all operation
 *
 * @details A stream can be 'done' if it either hits an error or consumes all audio data
 * from the remote source. This method also checks if the stream has been stopped.
 *
 * Returns YES if the stream is done, NO Otherwise
 */
@property (nonatomic, getter=isDone, readonly) BOOL done;

/**
 * @brief Returns the reason that the streamer is done
 *
 * @details When isDone returns true, this will return the reason that the stream has
 * been flagged as being done. ASNotDone will be returned otherwise.
 *
 * @see ASDoneReason
 */
@property (nonatomic, readonly) ASDoneReason doneReason;

/**
 * @brief Returns whether the stream can be seeked with the <seekToTime:> method
 *
 * @details The stream cannot be seeked if:
 *
 * - The bitrate cannot be calculated
 * - The duration cannot be calculated
 * - The Accept-Ranges HTTP header does not return "bytes"
 *
 * The <seekToTime:> method will always return this value but this property may be
 * useful for those who want to know whether they can seek beforehand. An example could
 * be if you wanted to disable user interaction if a seek bar.
 *
 * This property does not necessarily mean the current stream will never be seekable.
 * This property *could* return NO before
 * <[AudioStreamerDelegate streamerBitrateIsReady:]> is called, depending on the stream.
 *
 * Returns YES if the stream can be seeked, NO otherwise.
 */
@property (nonatomic, getter=isSeekable, readonly) BOOL seekable;

/**
 * @brief The error the streamer threw
 *
 * @details If an error occurs on the stream, then this variable is set with the
 * corresponding error information.
 *
 * By default this is nil.
 *
 * @see AudioStreamerErrorCode
 */
@property (readonly, nullable) NSError *error;

/**
 * @brief Headers received from the remote source
 *
 * @details Used to determine file size, but other information may be useful as well
 */
@property (readonly, nullable) NSDictionary<NSString *, NSString *> *httpHeaders;

/**
 * @brief The remote resource that this stream is playing
 * 
 * @details This is a read-only property and cannot be changed after creation
 */
@property (readonly) NSURL *url;

/**
 * @brief The stream's description.
 *
 * @details This property contains data like sample rate and number of audio channels.
 *
 * See Apple's AudioStreamBasicDescription documentation for more information
 */
@property (readonly) AudioStreamBasicDescription streamDescription;

/**
 * @brief The current song playing in an ICY or ID3v2 stream.
 *
 * @details This property only works for ICY streams (eg. Shoutcast) and streams with
 * ID3v2 tags (some MP3s). This will return nil if the stream is not a valid stream or
 * there is no current song metadata available.
 *
 * The format of the property in ID3v2 streams is "Artist - Title".
 *
 * The current song field is sometimes used as the stream title on some ICY streams.
 */
@property (readonly, nullable) NSString *currentSong;

/**
 * @brief The number of audio buffers to have
 *
 * @details Each audio buffer contains one or more packets of audio data. This amount is
 * only relevant if infinite buffering is turned off. This is the amount of data
 * which is stored in memory while playing. Once this memory is full, the remote
 * connection will not be read and will not receive any more data until one of
 * the buffers becomes available.
 *
 * With infinite buffering turned on, this number should be at least 3 or so to
 * make sure that there's always data to be read. With infinite buffering turned
 * off, this should be a number to not consume too much memory, but to also keep
 * up with the remote data stream. The incoming data should always be able to
 * stay ahead of these buffers being filled
 *
 * Higher values will mean more data is stored so the higher you go, the more you
 * can go without streaming more. This can help in the case of brief network
 * slowdowns. Additionally, higher bitrates demand more buffers than lower ones
 * as the data needed to store is much larger. The default value covers most
 * bitrates but further tweaking may be required in certain cases.
 *
 * Default: 256
 */
@property (readwrite) UInt32 bufferCount;

/**
 * @brief The default size for each buffer allocated
 *
 * @details Each buffer's size is attempted to be guessed from the audio stream being
 * received. This way each buffer is tuned for the audio stream itself. If this
 * inferring of the buffer size fails, however, this is used as a fallback as
 * how large each buffer should be.
 *
 * If you find that this is being used, then it should be coordinated with
 * <bufferCount> above to make sure that the audio stays responsive and slightly
 * behind the HTTP stream
 *
 * Default: 8192
 */
@property (readwrite) UInt32 bufferSize;

/**
 * @brief The number of buffers to fill before starting the stream
 *
 * @details The higher the value, the more smooth the start will be as there is more data
 * cached for playback. A higher value will however result in slower starts which
 * can also impact how "in-sync" livestreams are.
 *
 * This should always be lower than, or equal to, the <bufferCount> property but will
 * not error if not done so. AudioStreamer will simply fallback to the bufferCount
 * as the amount to fill instead.
 *
 * Default: 32
 */
@property (readwrite) UInt32 bufferFillCountToStart;

/**
 * @brief The file type of this audio stream
 *
 * @details This is an optional parameter. If not specified, then the file type will be
 * guessed. First, the MIME type of the response is used to guess the file
 * type, and if that fails the extension on the <url> is used. If that fails as
 * well, then the default is an MP3 stream.
 *
 * If this property is set, then no inferring is done and that file type is
 * always used.
 *
 * Default: (guess)
 */
@property (readwrite) AudioFileTypeID fileType;

/**
 * @brief Flag if to infinitely buffer data
 *
 * @details If this flag is set to NO, then a statically sized buffer is used as
 * determined by the <bufferCount> and <bufferSize> properties and the read stream
 * will be descheduled when those fill up. This limits the bandwidth consumed to the
 * remote source and also limits memory usage.
 *
 * If, however, you wish to hold the entire stream in memory, then you can set
 * this flag to YES. In this state, the stream will be entirely downloaded,
 * regardless if the buffers are full or not. This way if the network stream
 * cuts off halfway through a song, the rest of the song will be downloaded
 * locally to finish off. The next song might still be in trouble, however...
 * With this turned on, memory usage will be higher because the entire stream
 * will be downloaded as fast as possible, and the bandwidth to the remote will
 * also be consumed. Depending on the situation, this might not be that bad of
 * a problem.
 *
 * Default: NO
 */
@property (readwrite) BOOL bufferInfinite;

/**
 * @brief Interval to consider timeout if no network activity is seen
 *
 * @details When downloading audio data from a remote source, this is the interval in
 * which to consider it a timeout if no data is received. If the stream is
 * paused, then that time interval is not counted. This only counts if we are
 * waiting for data and an amount of time larger than this elapses.
 *
 * The units of this variable is seconds.
 *
 * Default: 10
 */
@property (readwrite) int timeoutInterval;

/**
 * @brief Rate to playback audio
 *
 * @details This property must be in the range 0.5 through 2.0.
 *
 * A value of 1.0 specifies that the audio should play back at its normal rate.
 *
 * Default: 1.0
 *
 * @available iOS 7 and later, all supported OS X versions
 */
@property (readwrite) float playbackRate;

/**
 * @brief The log level to use
 *
 * @details Default: ASLogLevelInfo on debug builds; ASLogLevelError on release
 * builds.
 *
 * @see ASLogLevel
 */
@property (readwrite) ASLogLevel logLevel;

/**
 * @brief A callback to override the logging in AudioStreamer.
 *
 * @details When set to nil, NSLog will be called for logging. Set this property
 * if you want to log using your only logging function.
 *
 * Default: nil
 */
@property (readwrite, copy, nullable) ASLogHandler logHandler;

@property (readwrite) Class readStreamHandlerClass;
@property (readwrite) Class fileStreamHandlerClass;
@property (readwrite) Class audioQueueHandlerClass;

/**
 * @brief Set an HTTP proxy for this stream
 *
 * @param host The address/hostname of the remote host
 * @param port The port of the proxy
 */
- (void)setHTTPProxy:(NSString *)host port:(uint16_t)port;

/**
 * @brief Set SOCKS proxy for this stream
 *
 * @param host The address/hostname of the remote host
 * @param port The port of the proxy
 */
- (void)setSOCKSProxy:(NSString *)host port:(uint16_t)port;

/** @name Management of the stream */

/**
 * @brief Starts playback of this audio stream.
 *
 * @details This method can only be invoked once, and other methods will not work before
 * this method has been invoked. All properties (like proxies) must be set
 * before this method is invoked.
 *
 * @return YES if the stream was started, or NO if the stream was previously
 *         started and this had no effect.
 */
- (BOOL)start;

/**
 * @brief Stop all streams, clean up resources and prevent all further events
 * from occurring.
 *
 * @details This method may be invoked at any time from any point of the audio stream as
 * a signal of error happening.
 */
- (void)stop;

/**
 * @brief Pause the audio stream if playing
 *
 * @return YES if the audio stream was paused, or NO if it was not in the
 *         playing state or an error occurred.
 */
- (BOOL)pause;

/**
 * @brief Plays the audio stream if paused
 *
 * @return YES if the audio stream entered into the playing state, or NO if
 *         any other error or bad state was encountered.
 */
- (BOOL)play;

/** @name Calculated properties and modifying the stream (all can fail) */

/**
 * @brief Seek to a specified time in the audio stream
 *
 * @details This can only happen once the bit rate of the stream is known because
 * otherwise the byte offset to the stream is not known. For this reason the
 * function can fail to actually seek.
 *
 * Additionally, seeking to a new time involves re-opening the audio stream with
 * the remote source, although this is done under the hood.
 *
 * @param newSeekTime The time in seconds to seek to
 * @return YES if the stream will be seeking, or NO if the stream did not have
 *         enough information available to it to seek to the specified time.
 */
- (BOOL)seekToTime:(double)newSeekTime;

/**
 * @brief Seek to a relative time in the audio stream
 *
 * @details This will calculate the current stream progress and seek relative to it
 * by the specified delta. Useful for seeking.
 *
 * @param seekTimeDelta The time interval from current seek time to seek to
 * @return YES if the stream will be seeking, or NO if the stream did not have
 *         enough information available to it to seek to the specified time.
 */
- (BOOL)seekByDelta:(double)seekTimeDelta;

/**
 * @brief Calculates the bit rate of the stream
 *
 * @details All packets received so far contribute to the calculation of the bit rate.
 * This is used internally to determine other factors like duration and
 * progress.
 *
 * @param ret The double to fill in with the bit rate on success
 * @return YES if the bit rate could be calculated with a high degree of
 *         certainty, or NO if it could not be.
 */
- (BOOL)calculatedBitRate:(nullable double *)ret;

/**
 * @brief Attempt to set the volume on the audio queue
 *
 * @param volume The volume to set the stream to in the range 0.0 to 1.0 where 1.0
 *        is the loudest and 0.0 is silent
 * @return YES if the volume was set, or NO if the audio queue wasn't ready to
 *         have its volume set. When the state for this audio streamer changes
 *         internally to have a stream, then setVolume: will work
 */
- (BOOL)setVolume:(float)volume;

/**
 * @brief Calculates the duration of the audio stream, in seconds
 *
 * @details Uses information about the size of the file and the calculated bit rate to
 * determine the duration of the stream.
 *
 * @param ret The variable to fill with the duration of the stream on success
 * @return YES if ret contains the duration of the stream, or NO if the duration
 *         could not be determined. In the NO case, the contents of ret are
 *         undefined
 */
- (BOOL)duration:(double *)ret;

/**
 * @brief Calculate the progress into the stream, in seconds
 *
 * @details The AudioQueue instance is polled to determine the current time into the
 * stream, and this is returned.
 *
 * @param ret A double which is filled in with the progress of the stream. The
 *        contents are undefined if NO is returned
 * @return YES if the progress of the stream was determined, or NO if the
 *         progress could not be determined at this time
 */
- (BOOL)progress:(nullable double *)ret;

/**
 * @brief Calculate the buffer progress into the stream, in seconds
 *
 * @details This calculates how far we have buffered into memory. You can stream up to
 * the point returned by this method without the streamer having to reconnect. The
 * streamer will read packets already fetched from its memory buffers.
 *
 * @param ret A double which is filled in with the buffer progress of the stream. The
 *        contents are undefined if NO is returned
 * @return YES if the buffer progress of the stream was determined, or NO if the buffer
 *         progress could not be determined at this time
 */
- (BOOL)bufferProgress:(nullable double *)ret;

/**
 * @brief Fade in playback
 *
 * @details The AudioQueue volume is progressively increased from 0 to 1
 *
 * @param duration a double which represents the fade-in time span.
 * @return YES if the fade in was set, or NO if the audio queue wasn't ready to
 *         have its volume set.
 */
- (BOOL)fadeInDuration:(float)duration;

/**
 * @brief Fade out playback
 *
 * @details The AudioQueue volume is progressively decreased from 1 to 0.
 *
 * @param duration a double which represents the fade-in time span.
 * @return YES if the fade out was set, or NO if the audio queue wasn't ready to
 *         have its volume set.
 */
- (BOOL)fadeOutDuration:(float)duration;

@end

NS_ASSUME_NONNULL_END
