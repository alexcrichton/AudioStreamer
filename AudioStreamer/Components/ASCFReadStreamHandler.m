//
//  ASHTTPHandler.m
//  AudioStreamer
//
//  Created by Bo Anderson on 29/08/2016.
//

#import "ASCFReadStreamHandler.h"
#import "ASInternal.h"


#define kDefaultAudioFileType kAudioFileMP3Type


typedef NS_OPTIONS(NSUInteger, ASID3FlagInfo)
{
    ASID3FlagUnsync = (1 << 0),
    ASID3FlagExtendedHeader = (1 << 1)
};


NSString * const ASReadStreamErrorDomain = @"com.alexcrichton.audiostreamer.ASHTTPReadStreamHandler";


@interface ASCFReadStreamHandler()

@end

@implementation ASCFReadStreamHandler

/* CFReadStream callback when an event has occurred */
static void ASReadStreamCallback(CFReadStreamRef aStream, CFStreamEventType eventType, void *inClientInfo)
{
    ASCFReadStreamHandler *handler = (__bridge ASCFReadStreamHandler *)inClientInfo;
    [handler handleReadFromStream:aStream eventType:eventType];
}


- (instancetype)initWithURL:(NSURL *)url
{
    if ((self = [super init]))
    {
        _url = url;
    }
    return self;
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
- (BOOL)openWithBufferSize:(UInt32)bufferSize timeoutInterval:(NSTimeInterval)timeoutInterval
{
    return [self openAtByteOffset:0 bufferSize:bufferSize timeoutInterval:timeoutInterval];
}

- (BOOL)openAtByteOffset:(UInt64)byteOffset bufferSize:(UInt32)bufferSize timeoutInterval:(NSTimeInterval)timeoutInterval
{
    NSAssert(_stream == NULL, @"Download stream already initialized");

    /* Create our GET request */
    CFHTTPMessageRef message = CFHTTPMessageCreateRequest(NULL, CFSTR("GET"), (__bridge CFURLRef)_url, kCFHTTPVersion1_1);

    /* ID3 support */
    _id3ParserState = ASID3StateInitial;

    /* ICY metadata */
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Icy-MetaData"), CFSTR("1"));
    _icyStream = NO;
    _icyChecked = NO;
    _icyMetaBytesRemaining = 0;
    _icyDataBytesRead = 0;
    _icyHeadersParsed = NO;
    _icyMetadata = nil;
    [self setCurrentSong:nil];

    _byteOffset = byteOffset;
    if (_byteOffset > 0)
    {
        NSString *str = [NSString stringWithFormat:@"bytes=%lld-%lld", _byteOffset, _contentLength - 1];
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Range"), (__bridge CFStringRef)str);
    }

    _bufferSize = bufferSize;
    _bytesReceived = 0;

    _stream = CFReadStreamCreateForHTTPRequest(NULL, message);
    CFRelease(message);

    /* Follow redirection codes by default */
    Boolean success = CFReadStreamSetProperty(_stream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue);
    if (!success)
    {
        [self failWithErrorCode:ASReadStreamSetPropertyFailed];
        return NO;
    }

    /* Deal with proxies */
    switch ([_proxyInfo type])
    {
        case ASProxyHTTP: {
            CFDictionaryRef proxySettings;
            if ([[[_url scheme] lowercaseString] isEqualToString:@"https"]) {
                proxySettings = (__bridge CFDictionaryRef)
                [NSMutableDictionary dictionaryWithObjectsAndKeys:
                        [_proxyInfo host], kCFStreamPropertyHTTPSProxyHost,
                        @([_proxyInfo port]), kCFStreamPropertyHTTPSProxyPort,
                        nil];
            } else {
                proxySettings = (__bridge CFDictionaryRef)
                    [NSMutableDictionary dictionaryWithObjectsAndKeys:
                        [_proxyInfo host], kCFStreamPropertyHTTPProxyHost,
                        @([_proxyInfo port]), kCFStreamPropertyHTTPProxyPort,
                        nil];
            }
            CFReadStreamSetProperty(_stream, kCFStreamPropertyHTTPProxy, proxySettings);
            break;
        }
        case ASProxySOCKS: {
            CFDictionaryRef proxySettings = (__bridge CFDictionaryRef)
                [NSMutableDictionary dictionaryWithObjectsAndKeys:
                    [_proxyInfo host], kCFStreamPropertySOCKSProxyHost,
                    @([_proxyInfo port]), kCFStreamPropertySOCKSProxyPort,
                    nil];
            CFReadStreamSetProperty(_stream, kCFStreamPropertySOCKSProxy, proxySettings);
            break;
        }
        case ASProxySystem: {
            CFDictionaryRef proxySettings = CFNetworkCopySystemProxySettings();
            CFReadStreamSetProperty(_stream, kCFStreamPropertyHTTPProxy, proxySettings);
            CFRelease(proxySettings);
            break;
        }
    }

    /* handle SSL connections */
    if ([[[_url scheme] lowercaseString] isEqualToString:@"https"]) {
        NSDictionary *sslSettings = @{
                                      (id)kCFStreamSSLLevel: (NSString *)kCFStreamSocketSecurityLevelNegotiatedSSL,
                                      (id)kCFStreamSSLValidatesCertificateChain: @YES,
                                      (id)kCFStreamSSLPeerName:                  [NSNull null]
                                      };
        
        CFReadStreamSetProperty(_stream, kCFStreamPropertySSLSettings, (__bridge CFDictionaryRef)sslSettings);
    }
    
    /* Set the callback to receive a few events, and then we're ready to
     schedule and go */
    CFStreamClientContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    CFReadStreamSetClient(_stream,
                          kCFStreamEventHasBytesAvailable | kCFStreamEventErrorOccurred | kCFStreamEventEndEncountered,
                          ASReadStreamCallback, &context);
    CFReadStreamScheduleWithRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);

    success = CFReadStreamOpen(_stream);
    if (!success)
    {
        [self failWithErrorCode:ASReadStreamOpenFailed];
        return NO;
    }

    _timeout = [NSTimer scheduledTimerWithTimeInterval:timeoutInterval
                                                target:self
                                              selector:@selector(checkTimeout)
                                              userInfo:nil
                                               repeats:YES];
    
    return YES;
}

- (void)close
{
    if (_stream)
    {
        CFReadStreamClose(_stream);
        CFRelease(_stream);
        _stream = NULL;
    }
    [_timeout invalidate];
    _timeout = nil;
}

- (void)dealloc
{
    [self close];
}

- (void)pause
{
    if (_unscheduled && !_rescheduled) return;

    CFReadStreamUnscheduleFromRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    /* Make sure we don't have ourselves marked as rescheduled */
    _unscheduled = YES;
    _rescheduled = NO;
}

- (void)resume
{
    if (!_unscheduled || _rescheduled) return;

    _rescheduled = YES;
    CFReadStreamScheduleWithRunLoop(_stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
}

- (BOOL)isPaused
{
    return _unscheduled;
}

- (void)failWithErrorCode:(ASReadStreamErrorCode)errorCode
{
    [self failWithErrorCode:errorCode extraInfo:@""];
}

- (void)failWithErrorCode:(ASReadStreamErrorCode)errorCode extraInfo:(NSString *)extraInfo
{
    if (_errorThrown) return;
    _errorThrown = YES;

    ASLogError(@"Read stream encountered an error: %@ (%@)", [[self class] descriptionForErrorCode:errorCode], extraInfo);

    NSDictionary *userInfo = @{NSLocalizedDescriptionKey:
                                   NSLocalizedString([[self class] descriptionForErrorCode:errorCode], nil),
                               NSLocalizedFailureReasonErrorKey:
                                   NSLocalizedString(extraInfo, nil)};
    NSError *error = [NSError errorWithDomain:ASReadStreamErrorDomain code:errorCode userInfo:userInfo];

    [[self delegate] readStreamEncounteredError:error];
}

+ (NSString *)descriptionForErrorCode:(ASReadStreamErrorCode)errorCode
{
    switch (errorCode)
    {
        case ASReadStreamNetworkConnectionFailed:
            return @"Network connection failure";
        case ASReadStreamSetPropertyFailed:
            return @"Read stream set property failed";
        case ASReadStreamOpenFailed:
            return @"Failed to open read stream";
        case ASReadStreamAudioDataNotFound:
            return @"No audio data found";
        case ASReadStreamTimedOut:
            return @"Timed out";
    }
}

- (void)setCurrentSong:(NSString *)currentSong
{
    _currentSong = currentSong;
    [[self delegate] readStreamDidUpdateCurrentSong:currentSong shouldQueue:(_icyDataBytesRead > 0)];
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
- (void)handleReadFromStream:(CFReadStreamRef)aStream eventType:(CFStreamEventType)eventType
{
    assert(aStream == _stream);
    _events++;

    switch (eventType) {
        case kCFStreamEventErrorOccurred: {
            ASLogInfo(@"error");

            NSError *networkError = (__bridge_transfer NSError *)CFReadStreamCopyError(aStream);
            if (_networkError != nil || !_seekable || ![[self delegate] readStreamRequestsReconnection])
            {
                [self failWithErrorCode:ASReadStreamNetworkConnectionFailed extraInfo:[_networkError localizedDescription]];
            }
            else
            {
                _networkError = networkError;

                NSTimeInterval timeoutInterval = [_timeout timeInterval];
                [self close];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    ASLogInfo(@"Attempting reconnection...");
                    [self openAtByteOffset:_byteOffset + _bytesReceived
                                bufferSize:_bufferSize
                           timeoutInterval:timeoutInterval];
                });
            }

            return;
        }
        case kCFStreamEventEndEncountered:
            ASLogInfo(@"end");
            [_timeout invalidate];
            _timeout = nil;

            [[self delegate] readStreamReachedEnd];
            return;

        default:
            return;

        case kCFStreamEventHasBytesAvailable:
            break;
    }
    ASLogVerbose(@"data");

    CFHTTPMessageRef message = (CFHTTPMessageRef)CFReadStreamCopyProperty(_stream, kCFStreamPropertyHTTPResponseHeader);
    CFIndex statusCode = CFHTTPMessageGetResponseStatusCode(message);

    if (statusCode >= 400) {
        [self failWithErrorCode:ASReadStreamAudioDataNotFound
                      extraInfo:[NSString stringWithFormat:@"Server returned HTTP %ld", statusCode]];
    }

    /* Read off the HTTP headers into our own class if we haven't done so */
    if (!_httpHeaders)
    {
        _httpHeaders = (__bridge_transfer NSDictionary *)CFHTTPMessageCopyAllHeaderFields(message);

        //
        // Only read the content length if we seeked to time zero, otherwise
        // we may only have a subset of the total bytes.
        //
        if (_byteOffset == 0) {
            _contentLength = (UInt64)[_httpHeaders[@"Content-Length"] longLongValue];
        }

        _seekable = [@"bytes" caseInsensitiveCompare:_httpHeaders[@"Accept-Ranges"]] == NSOrderedSame;

        [[self delegate] readStreamReadHTTPHeaders:_httpHeaders];
    }

    CFRelease(message);

    /* If we haven't yet opened up a file stream, then do so now */
    if (!_readStreamReady) {
        _readStreamReady = YES;

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

        [[self delegate] readStreamFileTypeUpdated:_fileType];
        [[self delegate] readStreamReadyToStartReading];
    }

    UInt8 bytes[_bufferSize];
    CFIndex length;
    while (_stream && CFReadStreamHasBytesAvailable(_stream)) {
        length = CFReadStreamRead(_stream, bytes, (CFIndex)sizeof(bytes));

        if (length < 0) {
            if (_didConnect) {
                _didConnect = NO;
                // Ignore. A network connection error likely happened so we should wait for that to throw.
                // If this happens again, throw a audio data not found error.
                return;
            }
            [self failWithErrorCode:ASReadStreamAudioDataNotFound];
            return;
        } else if (length == 0) {
            return;
        }

        _didConnect = YES;
        _networkError = nil;
        _timedOut = NO;

        _bytesReceived += (UInt64)length;

        // Shoutcast support.
        UInt8 bytesNoMetadata[_bufferSize]; // Bytes without the ICY metadata
        CFIndex lengthNoMetadata = 0;
        NSUInteger streamStart = 0;

        if (!_icyChecked && statusCode == 200) {
            NSString *icyCheck = [[NSString alloc] initWithBytes:bytes length:10 encoding:NSUTF8StringEncoding];
            if (icyCheck == nil) {
                icyCheck = [[NSString alloc] initWithBytes:bytes length:10 encoding:NSISOLatin1StringEncoding];
            }
            if (icyCheck && [icyCheck caseInsensitiveCompare:@"ICY 200 OK"] == NSOrderedSame) {
                _icyStream = YES;
            } else {
                if (_httpHeaders[@"icy-metaint"]) {
                    _icyStream = YES;
                    _icyMetaInterval = [_httpHeaders[@"icy-metaint"] intValue];
                    _icyBitrate = [_httpHeaders[@"icy-br"] doubleValue] * 1000.0;
                    _icyHeadersParsed = YES;
                }
            }
            _icyChecked = YES;
        }

        if (!_icyStream && _id3ParserState != ASID3StateParsed) {
            // ID3 support
            [self parseID3TagsInBytes:bytes length:length];
        } else if (_icyStream && !_icyHeadersParsed) {
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
                                ASLogInfo(@"ICY stream Content-Type: %@", lineItems[1]);
                                [[self delegate] readStreamFileTypeUpdated:_fileType];
                            }
                        }
                        else if ([lineItems[0] caseInsensitiveCompare:@"icy-metaint"] == NSOrderedSame) {
                            _icyMetaInterval = [lineItems[1] intValue];
                        }
                        else if ([lineItems[0] caseInsensitiveCompare:@"icy-br"] == NSOrderedSame) {
                            _icyBitrate = [lineItems[1] doubleValue] * 1000.0;
                        }
                    }

                    if (bytes[streamStart + 2] == '\r' && bytes[streamStart + 3] == '\n') {
                        _icyHeadersParsed = YES;
                        break;
                    }

                    lineStart = streamStart + 2;
                }

                streamStart++;
            }

            if (_icyHeadersParsed) {
                streamStart = streamStart + 4;
            }
        }

        if (_icyHeadersParsed) {
            for (CFIndex byte = (CFIndex)streamStart; byte < length; byte++) {
                if (_icyMetaBytesRemaining > 0) {
                    [_icyMetadata appendFormat:@"%c", bytes[byte]];

                    _icyMetaBytesRemaining--;

                    if (_icyMetaBytesRemaining == 0) {
                        // Ready for parsing
                        NSArray *metadataArr = [_icyMetadata componentsSeparatedByString:@";"];
                        for (NSString *metadataLine in metadataArr) {
                            NSString *key;
                            NSScanner *scanner = [NSScanner scannerWithString:metadataLine];
                            [scanner scanUpToString:@"=" intoString:&key];
                            if ([scanner isAtEnd] || ![key isEqualToString:@"StreamTitle"]) continue; // Not interested in other metadata
                            [scanner scanString:@"=" intoString:nil];
                            [scanner scanString:@"'" intoString:nil];
                            NSUInteger scanLoc = [scanner scanLocation];
                            NSString *value = [metadataLine substringWithRange:NSMakeRange(scanLoc, [metadataLine length] - scanLoc - 1)];

                            ASLogInfo(@"ICY stream title read: %@", value);
                            [self setCurrentSong:value];
                        }
                        _icyDataBytesRead = 0;
                    }

                    continue;
                }

                if (_icyMetaInterval > 0 && _icyDataBytesRead == _icyMetaInterval) {
                    _icyMetaBytesRemaining = bytes[byte] * 16;

                    _icyMetadata = [NSMutableString string];

                    if (_icyMetaBytesRemaining == 0) {
                        _icyDataBytesRead = 0;
                    }

                    continue;
                }

                _icyDataBytesRead++;
                bytesNoMetadata[lengthNoMetadata] = bytes[byte];
                lengthNoMetadata++;
            }
        }

        if (lengthNoMetadata > 0)
            [[self delegate] readStreamReadBytes:bytesNoMetadata length:lengthNoMetadata];
        else if (_icyMetaInterval == 0)
            [[self delegate] readStreamReadBytes:bytes length:length];
    }
}

- (void)parseID3TagsInBytes:(UInt8[])bytes length:(CFIndex)length
{
    UInt8 id3Version;
    int id3TagSize;
    ASID3FlagInfo id3FlagInfo = 0;
    int id3PosStart;
    UInt8 syncedBytes[length];
    while (true)
    {
        if (_id3ParserState == ASID3StateInitial) {
            if (length <= 10) {
                /* Not enough bytes */
                _id3ParserState = ASID3StateParsed;
                break;
            }

            if (bytes[0] != 'I' || bytes[1] != 'D' || bytes[2] != '3') {
                _id3ParserState = ASID3StateParsed; // Done here
                break;
            }

            id3Version = bytes[3];
            ASLogInfo(@"ID3 version 2.%hhu", id3Version);
            if (id3Version != 2 && id3Version != 3 && id3Version != 4) { /* Only supporting ID3v2.2, v2.3 and v2.4 */
                _id3ParserState = ASID3StateParsed;
                break;
            }

            if ((bytes[5] & 0x80) != 0) {
                id3FlagInfo |= ASID3FlagUnsync;
            }
            if ((bytes[5] & 0x40) != 0) {
                if (id3Version >= 3) {
                    id3FlagInfo |= ASID3FlagExtendedHeader;
                } else {
                    _id3ParserState = ASID3StateParsed;
                    break;
                }
            }

            id3TagSize = ((bytes[6] & 0x7F) << 21) | ((bytes[7] & 0x7F) << 14) |
                            ((bytes[8] & 0x7F) << 7) | (bytes[9] & 0x7F);

            if ((length - 10) < id3TagSize)
            {
                ASLogWarn(@"Not enough data received to parse ID3.");
                _id3ParserState = ASID3StateParsed;
                break;
            }
            else
            {
                if (id3Version <= 3 && (id3FlagInfo & ASID3FlagUnsync)) {
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

                if (id3FlagInfo & ASID3FlagExtendedHeader) {
                    int extendedHeaderSize = ((syncedBytes[0] << 24) | (syncedBytes[1] << 16) |
                                              (syncedBytes[2] << 8) | syncedBytes[3]);
                    if (extendedHeaderSize > id3TagSize) {
                        _id3ParserState = ASID3StateParsed;
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
                        _id3ParserState = ASID3StateParsed;
                        break;
                    }
                } else {
                    id3PosStart = 0;
                }

                _id3ParserState = ASID3StateReadyToParse;
                continue;
            }
        } else if (_id3ParserState == ASID3StateReadyToParse) {
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
                                    BOOL bigEndian = (encoding == kCFStringEncodingUTF16BE);
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
                                BOOL bigEndian = (encoding == kCFStringEncodingUTF16BE);
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
                if (!strncmp((char *)syncedBytes+startPos, id3Version <= 2 ? "TT2" : "TIT2", tagLen)) {
                    id3Title = @([(__bridge_transfer NSString *)CFStringCreateWithBytes(kCFAllocatorDefault,
                                                                                        &syncedFrameBytes[1],
                                                                                        frameSize - 1, encoding,
                                                                                        encoding == kCFStringEncodingUTF16)
                                  UTF8String]);
                } else if (!strncmp((char *)syncedBytes+startPos, id3Version <= 2 ? "TP1" : "TPE1", tagLen)) {
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

            if (_currentSong != nil)
                ASLogInfo(@"ID3 Current Song: %@", _currentSong);
            
            _id3ParserState = ASID3StateParsed;
            break;
        } else {
            break;
        }
    }
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
+ (AudioFileTypeID)hintForFileExtension:(NSString *)fileExtension
{
    fileExtension = [fileExtension lowercaseString];

    if ([fileExtension isEqual:@"mp3"])
        return kAudioFileMP3Type;
    else if ([fileExtension isEqual:@"wav"] || [fileExtension isEqual:@"wave"])
        return kAudioFileWAVEType;
    else if ([fileExtension isEqual:@"aifc"])
        return kAudioFileAIFCType;
    else if ([fileExtension isEqual:@"aiff"] || [fileExtension isEqual:@"aif"])
        return kAudioFileAIFFType;
    else if ([fileExtension isEqual:@"m4a"])
        return kAudioFileM4AType;
    else if ([fileExtension isEqual:@"mp4"])
        return kAudioFileMPEG4Type;
    else if ([fileExtension isEqual:@"caf"])
        return kAudioFileCAFType;
    else if ([fileExtension isEqual:@"aac"])
        return kAudioFileAAC_ADTSType;
    else if ([fileExtension isEqual:@"au"] || [fileExtension isEqual:@"snd"])
        return kAudioFileNextType;
    else if ([fileExtension isEqual:@"3gp"])
        return kAudioFile3GPType;
    else if ([fileExtension isEqual:@"3g2"])
        return kAudioFile3GP2Type;

    return 0;
}

/**
 * @brief Guess the file type based on the listed MIME type in the http response
 *
 * Based from:
 * https://github.com/DigitalDJ/AudioStreamer/blob/master/Classes/AudioStreamer.m
 */
+ (AudioFileTypeID)hintForMIMEType:(NSString*)mimeType
{
    if ([mimeType isEqual:@"audio/mpeg"])
        return kAudioFileMP3Type;
    else if ([mimeType isEqual:@"audio/vnd.wave"] || [mimeType isEqual:@"audio/wav"] ||
               [mimeType isEqual:@"audio/wave"] || [mimeType isEqual:@"audio/x-wav"])
        return kAudioFileWAVEType;
    else if ([mimeType isEqual:@"audio/x-aiff"] || [mimeType isEqual:@"audio/aiff"])
        return kAudioFileAIFFType;
    else if ([mimeType isEqual:@"audio/x-m4a"] || [mimeType isEqual:@"audio/m4a"])
        return kAudioFileM4AType;
    else if ([mimeType isEqual:@"audio/mp4"])
        return kAudioFileMPEG4Type;
    else if ([mimeType isEqual:@"audio/x-caf"])
        return kAudioFileCAFType;
    else if ([mimeType isEqual:@"audio/aac"] || [mimeType isEqual:@"audio/aacp"])
        return kAudioFileAAC_ADTSType;
    else if ([mimeType isEqual:@"audio/basic"])
        return kAudioFileNextType;
    else if ([mimeType isEqual:@"audio/3gpp"])
        return kAudioFile3GPType;
    else if ([mimeType isEqual:@"audio/3gpp2"])
        return kAudioFile3GP2Type;

    return 0;
}

/**
 * @brief Check the stream for a timeout, and trigger one if this is a timeout
 *        situation
 */
- (void)checkTimeout
{
    /* If the read stream has been unscheduled and not rescheduled, then this tick
     is irrelevant because we're not trying to read data anyway */
    if (_unscheduled && !_rescheduled) return;
    /* If the read stream was unscheduled and then rescheduled, then we still
     discard this sample (not enough of it was known to be in the "scheduled
     state"), but we clear flags so we might process the next sample */
    if (_rescheduled && _unscheduled)
    {
        _unscheduled = NO;
        _rescheduled = NO;
        return;
    }

    /* events happened? no timeout. */
    if (_events > 0)
    {
        _events = 0;
        return;
    }

    if (_timedOut || !_seekable || ![[self delegate] readStreamRequestsReconnection])
    {
        /* We tried reconnecting but failed. */
        [self failWithErrorCode:ASReadStreamTimedOut
                      extraInfo:[NSString stringWithFormat:@"No data was received in %f seconds while expecting data.", [_timeout timeInterval]]];
    }
    else
    {
        ASLogInfo(@"Timed out. Attempting reconnection...");
        _timedOut = YES;
        NSTimeInterval timeoutInterval = [_timeout timeInterval];
        [self close];
        [self openAtByteOffset:_byteOffset + _bytesReceived bufferSize:_bufferSize timeoutInterval:timeoutInterval];
    }
}

@end
