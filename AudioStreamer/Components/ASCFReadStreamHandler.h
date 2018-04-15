//
//  ASHTTPHandler.h
//  AudioStreamer
//
//  Created by Bo Anderson on 29/08/2016.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "ASProxyInformation.h"

/**
 * Error codes that the read stream could throw.
 *
 * These are mainly used internally but can be used for comparison with
 * the <[AudioStreamer error]> property.
 *
 * ```
 * if ([[streamer error] code] == ASReadStreamNetworkConnectionFailed)
 * {
 *     // Retry
 * }
 * ```
 *
 * You can also check the domain of the error to see if it came from the
 * read stream:
 *
 * ```
 * if ([[streamer error] domain] == ASReadStreamErrorDomain)
 * {
 *     // It's a read stream error
 * }
 * ```
 */
typedef NS_ENUM(NSInteger, ASReadStreamErrorCode)
{
    /**
     * The network connection to the stream has failed
     */
    ASReadStreamNetworkConnectionFailed = 100,
    /**
     * The read stream threw an error when attempting to set a property
     */
    ASReadStreamSetPropertyFailed = 101,
    /**
     * The file stream threw an error when opening
     */
    ASReadStreamOpenFailed = 102,
    /**
     * No audio could be found in stream
     */
    ASReadStreamAudioDataNotFound = 103,
    /**
     * The connection to the stream timed out
     */
    ASReadStreamTimedOut = 104
};

typedef NS_ENUM(NSUInteger, ASID3ParserState)
{
    ASID3StateInitial = 0,
    ASID3StateReadyToParse,
    ASID3StateParsed
};


extern NSString * const ASReadStreamErrorDomain;


@protocol ASHTTPReadStreamHandlerDelegate <NSObject>

- (void)readStreamFileTypeUpdated:(AudioFileTypeID)fileType;
- (void)readStreamReadHTTPHeaders:(NSDictionary *)httpHeaders;
- (void)readStreamDidUpdateCurrentSong:(NSString *)currentSong;

- (void)readStreamReadyToStartReading;
- (void)readStreamReadBytes:(UInt8 *)bytes length:(CFIndex)length;

- (void)readStreamEncounteredError:(NSError *)error;
- (void)readStreamReachedEnd;

- (BOOL)readStreamRequestsReconnection;

@end


@interface ASCFReadStreamHandler : NSObject
{
    CFReadStreamRef _stream;

    NSURL *_url;

    NSDictionary *_httpHeaders;

    AudioFileTypeID _fileType;

    UInt32 _bufferSize;

    /* Timeout management */
    NSTimer *_timeout; /* timer managing the timeout event */
    BOOL _unscheduled; /* flag if the http stream is unscheduled */
    BOOL _rescheduled; /* flag if the http stream was rescheduled */
    int _events;       /* events which have happened since the last tick */

    BOOL _didConnect;

    BOOL _readStreamReady;
    BOOL _errorThrown;

    NSError *_networkError;
    BOOL _timedOut;

    UInt64 _bytesReceived;

    /* ICY stream metadata */
    BOOL _icyStream;               /* Is this an ICY stream? */
    BOOL _icyChecked;              /* Have we already checked if this is an ICY stream? */
    BOOL _icyHeadersParsed;        /* Are all the ICY headers parsed? */
    int _icyMetaInterval;          /* The interval between ICY metadata bytes */
    UInt16 _icyMetaBytesRemaining; /* How many bytes of ICY metadata are left? */
    int _icyDataBytesRead;         /* How many data bytes have been read in an ICY stream since metadata? */
    NSMutableString *_icyMetadata; /* The string of metadata itself, as it is being read */
    
    ASID3ParserState _id3ParserState;
}

@property (nonatomic, weak) id <ASHTTPReadStreamHandlerDelegate> delegate;

@property (nonatomic, strong) ASProxyInformation *proxyInfo;

@property (nonatomic, assign, readonly) UInt64 byteOffset;

@property (nonatomic, assign) UInt64 contentLength;

@property (nonatomic, copy, readonly) NSString *currentSong;

/* The bitrate of the ICY stream (Icecast & Shoutcast) */
@property (nonatomic, assign, readonly) double icyBitrate;

@property (nonatomic, assign, readonly, getter=isSeekable) BOOL seekable;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithURL:(NSURL *)url NS_DESIGNATED_INITIALIZER;

- (BOOL)openWithBufferSize:(UInt32)bufferSize timeoutInterval:(NSTimeInterval)timeoutInterval;
- (BOOL)openAtByteOffset:(UInt64)byteOffset bufferSize:(UInt32)bufferSize timeoutInterval:(NSTimeInterval)timeoutInterval;
- (void)close;

- (void)pause;
- (void)resume;

- (BOOL)isPaused;

@end
