//
//  iOSStreamer.h
//  AudioStreamer
//
//  Created by Bo Anderson on 07/09/2012.
//

#import "AudioStreamer.h"
#import <AVFoundation/AVFAudio.h>

@class iOSStreamer;

/**
 * The iOSStreamerDelegate protocol extends the <AudioStreamerDelegate> and provides
 * callbacks for the interruption events that the <iOSStreamer> class deals with.
 * You can use these callbacks to override the default behaviour on interruption.
 */
@protocol iOSStreamerDelegate <AudioStreamerDelegate>

@optional
/**
 * @brief Called when the stream is interrupted
 *
 * @param sender The streamer that called this method
 *
 * @return YES to override the default behaviour of pausing the stream
 */
- (BOOL)streamerInterruptionDidBegin:(iOSStreamer *)sender;
/**
 * @brief Called when the stream interruption has ended
 *
 * @param sender The streamer that called this method
 * @param flags The flags received indicating whether the stream should resume.
 * This will be AVAudioSessionInterruptionOptionShouldResume if it should resume or 0
 * if it should not.
 *
 * @return YES to override the default behaviour of playing the stream if the flag
 * allows and stopping if it does not
 */
- (BOOL)streamer:(iOSStreamer *)sender interruptionDidEndWithFlags:(AVAudioSessionInterruptionOptions)flags;

@end

/**
 * The iOSStreamer subclass is for those using <AudioStreamer> on iOS.
 * This class adds extra iOS features that are unavailable or not required
 * on OS X.
 *
 * This class adds:
 *
 * - Ability to play audio while your app is in the background
 * - Interruption handling (eg. phone calls)
 * - Ability to play concurrent streams
 *
 * You only need to replace "AudioStreamer" with "iOSStreamer" in your
 * code. Everything else is handled for you which is why there is little
 * additional properties and methods.
 */
@interface iOSStreamer : AudioStreamer

/** @name Properties */

/**
 * @brief Sets the delegate for event callbacks
 *
 * @see iOSStreamerDelegate
 * @see AudioStreamerDelegate
 */
@property (nonatomic, readwrite, weak) id <iOSStreamerDelegate> delegate;

/**
 * @brief Whether the stream is currently interrupted
 *
 * @details The stream may be interrupted for various reasons such as
 * a phone call. This property will be set to YES if the stream is currently
 * interrupted and will be set back to NO when the interruption is over
 */
@property (readonly, getter=isInterrupted) BOOL interrupted;

@end
