//
//  ASiOSAudioQueueHandler.m
//  AudioStreamer
//
//  Created by Bo Anderson on 06/01/2017.
//

#import "ASiOSAudioQueueHandler.h"

@implementation ASiOSAudioQueueHandler

- (instancetype)initWithStreamDescription:(AudioStreamBasicDescription)asbd
                              bufferCount:(UInt32)bufferCount
                               packetSize:(UInt32)packetSize
{
    if ((self = [super initWithStreamDescription:asbd
                                     bufferCount:bufferCount
                                      packetSize:packetSize]))
    {
        if (![self isDone])
        {
            /* "Prefer" hardware playback but not "require" it.
             * This means that streams can use software playback if hardware is unavailable.
             * This allows for concurrent streams */
            UInt32 propVal = kAudioQueueHardwareCodecPolicy_PreferHardware;
            AudioQueueSetProperty(_audioQueue, kAudioQueueProperty_HardwareCodecPolicy, &propVal, sizeof(propVal));
        }
    }
    return self;
}

@end
