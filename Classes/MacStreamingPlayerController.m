//
//  MacStreamingPlayerController.m
//  MacStreamingPlayer
//
//  Created by Matt Gallagher on 28/10/08.
//  Copyright Matt Gallagher 2008. All rights reserved.
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

#import "MacStreamingPlayerController.h"

@implementation MacStreamingPlayerController

- (void)awakeFromNib
{
	[NSApp activateIgnoringOtherApps:YES];
	NSRect frame = [window frame];
	frame.size.height = 159;
	[window setMinSize:frame.size];
	[window setMaxSize:frame.size];
	[window setFrame:frame display:YES];
}

//
// setButtonImage:
//
// Used to change the image on the playbutton. This method exists for
// the purpose of inter-thread invocation because
// the observeValueForKeyPath:ofObject:change:context: method is invoked
// from secondary threads and UI updates are only permitted on the main thread.
//
// Parameters:
//    image - the image to set on the play button.
//
- (void)setButtonImage:(NSImage *)image
{
	[button.layer removeAllAnimations];
	if (!image)
	{
		[button setImage:[NSImage imageNamed:@"playbutton"]];
	}
	else
	{
		[button setImage:image];

		if ([button.image isEqual:[NSImage imageNamed:@"loadingbutton"]])
		{
			[self spinButton];
		}
	}
}

//
// destroyStreamer
//
// Removes the streamer and the UI update timer
//
- (void)destroyStreamer
{
	if (streamer)
	{
		[progressSlider setEnabled:NO];

		[progressUpdateTimer invalidate];
		progressUpdateTimer = nil;

		[streamer stop];
		streamer = nil;
	}
}

//
// createStreamer
//
// Creates or recreates the AudioStreamer object.
//
- (void)createStreamer
{
	[self destroyStreamer];

	NSString *escapedValue =
		(__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(
			nil,
			(__bridge CFStringRef)[downloadSourceField stringValue],
			NULL,
			NULL,
            kCFStringEncodingUTF8);

	NSURL *url = [NSURL URLWithString:escapedValue];
	streamer = [AudioStreamer streamWithURL:url];
	[streamer setDelegate:self];

	[self setButtonImage:[NSImage imageNamed:@"loadingbutton"]];

	progressUpdateTimer =
		[NSTimer
			scheduledTimerWithTimeInterval:0.1
			target:self
			selector:@selector(updateProgress:)
			userInfo:nil
			repeats:YES];
}

//
// spinButton
//
// Shows the spin button when the audio is loading. This is largely irrelevant
// now that the audio is loaded from a local file.
//
- (void)spinButton
{
	[CATransaction begin];
	[CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
	CGRect frame = NSRectToCGRect([button frame]);
	button.layer.anchorPoint = CGPointMake(0.5, 0.5);
	button.layer.position = CGPointMake(frame.origin.x + 0.5 * frame.size.width, frame.origin.y + 0.5 * frame.size.height);
	[CATransaction commit];

	[CATransaction begin];
	[CATransaction setValue:(id)kCFBooleanFalse forKey:kCATransactionDisableActions];
	[CATransaction setValue:@2.0f forKey:kCATransactionAnimationDuration];

	CABasicAnimation *animation;
	animation = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
	animation.fromValue = @0.0f;
	animation.toValue = @(-2.0 * M_PI);
	animation.timingFunction = [CAMediaTimingFunction functionWithName: kCAMediaTimingFunctionLinear];
	animation.delegate = self;
	[button.layer addAnimation:animation forKey:@"rotationAnimation"];

	[CATransaction commit];
}

//
// restartButtonAnimation
//
// If the button is spinning, this will restart the animation
//
- (void)restartButtonAnimation
{
	if ([streamer isWaiting])
	{
		[button.layer removeAllAnimations];
		[self spinButton];
	}
}

//
// animationDidStop:finished:
//
// Restarts the spin animation on the button when it ends. Again, this is
// largely irrelevant now that the audio is loaded from a local file.
//
// Parameters:
//    theAnimation - the animation that rotated the button.
//    finished - is the animation finised?
//
- (void)animationDidStop:(CAAnimation *)theAnimation finished:(BOOL)finished
{
	if (finished)
	{
		[self spinButton];
	}
}

//
// buttonPressed:
//
// Handles the play/stop button. Creates, observes and starts the
// audio streamer when it is a play button. Stops the audio streamer when
// it isn't.
//
// Parameters:
//    sender - normally, the play/stop button.
//
- (IBAction)buttonPressed:(id)sender
{
	if ([button.image isEqual:[NSImage imageNamed:@"playbutton"]])
	{
		[window makeFirstResponder:nil];

		[self createStreamer];
		[streamer start];
	}
	else
	{
		[streamer stop];
	}
}

//
// streamerStatusDidChange:
//
// Invoked when the AudioStreamer
// reports that its playback status has changed.
//
- (void)streamerStatusDidChange:(AudioStreamer *)sender
{
	if ([sender isWaiting])
	{
		[self setButtonImage:[NSImage imageNamed:@"loadingbutton"]];
	}
	else if ([sender isPlaying])
	{
		[self setButtonImage:[NSImage imageNamed:@"stopbutton"]];
	}
	else if ([sender isDone])
	{
		[self destroyStreamer];
		[self setButtonImage:[NSImage imageNamed:@"playbutton"]];
	}
}

//
// sliderMoved:
//
// Invoked when the user moves the slider
//
// Parameters:
//    aSlider - the slider (assumed to be the progress slider)
//
- (IBAction)sliderMoved:(NSSlider *)aSlider
{
	double duration;
	if ([streamer duration:&duration])
	{
		double newSeekTime = ([aSlider doubleValue] / 100.0) * duration;
		[streamer seekToTime:newSeekTime];
	}
}

//
// updateProgress:
//
// Invoked when the AudioStreamer
// reports that its playback progress has changed.
//
- (void)updateProgress:(NSTimer *)updatedTimer
{
	[progressSlider setEnabled:[streamer isSeekable]];

	double bitrate;
	if ([streamer calculatedBitRate:&bitrate])
	{
		double progress;
		double bufferProgress;
		double duration;

		if ([streamer progress:&progress] && [streamer bufferProgress:&bufferProgress] && [streamer duration:&duration])
		{
			[positionLabel setStringValue:
				[NSString stringWithFormat:@"Time Played: %@/%@",
					[self stringFromSeconds:progress],
					[self stringFromSeconds:duration]]];
			[progressSlider setDoubleValue:100 * progress / duration];
			[progressSlider setBufferValue:100 * bufferProgress / duration];
		}
		else
		{
			if ([streamer isPlaying]) {
				[positionLabel setStringValue:@"Time Played:"];
			}
			if (![streamer isWaiting]) {
				[progressSlider setDoubleValue:0.0];
				[progressSlider setBufferValue:0.0];
			}
		}
	}
	else
	{
		[positionLabel setStringValue:@"Time Played:"];
	}

	NSString *currentSong = [streamer currentSong];
	if (currentSong && [streamInfoLabel stringValue] != currentSong)
	{
		[streamInfoLabel setStringValue:currentSong];
		NSRect frame = [window frame];
		frame.size.height = 184;
		[window setMinSize:frame.size];
		[window setMaxSize:frame.size];
		[window setFrame:frame display:YES];
		[self adjustStreamInfoFontSize];
		[self restartButtonAnimation];
	}
	else if (!currentSong && ![[streamInfoLabel stringValue] isEqualToString:@""])
	{
		[streamInfoLabel setStringValue:@""];
		NSRect frame = [window frame];
		frame.size.height = 159;
		[window setMinSize:frame.size];
		[window setMaxSize:frame.size];
		[window setFrame:frame display:YES];
		[self restartButtonAnimation];
	}
}

//
// adjustStreamInfoFontSize
//
// Adjusts the font size of the streamInfoLabel to fit the width.
//
- (void)adjustStreamInfoFontSize
{
	NSString *fontName = [[streamInfoLabel font] fontName];
	NSSize targetSize = [streamInfoLabel frame].size;
	int i;
	for (i = 9; i <= 14; i++)
	{
		NSDictionary *attrs = @{NSFontAttributeName : [NSFont fontWithName:fontName size:i]};
		NSSize strSize = [[streamInfoLabel stringValue] sizeWithAttributes:attrs];
		if (strSize.width > targetSize.width) break;
	}
	[streamInfoLabel setFont:[NSFont fontWithName:fontName size:i-1]];
}

//
// stringFromSeconds:
//
// Converts a CGFloat time, in seconds, into NSString in HH:MM:SS.ss format
//
// Parameters:
//    interval - the time, in seconds, to convert
//
// returns the NSString of the converted time
//
- (NSString *)stringFromSeconds:(double)totalSconds
{
	double seconds = fmod(totalSconds, 60);
	int minutes = (int)floor(fmod(totalSconds / 60, 60));
	int hours = (int)floor(fmod(totalSconds / 3600, 60));
	return [NSString stringWithFormat:@"%02d:%02d:%04.1f", hours, minutes, seconds];
}
//
// control:textView:doCommandBySelector:
//
// Start the streamer when return is pressed in the text field
//
// Parameters:
//    control - the control that called this method
//    textView - the field editor of the control
//    commandSelector - the command that the control is about to call
//
// returns YES to override the command, NO otherwise
//
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
	if ([NSStringFromSelector(commandSelector) isEqualToString:@"insertNewline:"])
	{
		[window makeFirstResponder:nil];
		[self createStreamer];
		[streamer start];
		return YES;
	}
	return NO;
}

//
// dealloc
//
// Releases instance memory.
//
- (void)dealloc
{
	[self destroyStreamer];
	if (progressUpdateTimer)
	{
		[progressUpdateTimer invalidate];
		progressUpdateTimer = nil;
	}
}

@end
