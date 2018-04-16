# AudioStreamer

This project is a method of streaming audio from a remote HTTP source. Multiple audio formats are supported.  The goal of this project is to provide a robust and much easier-to-use API than using AudioQueue services directly.

This project is a fork of @mattgallagher's [AudioStreamer](https://github.com/mattgallagher/AudioStreamer) and most of the credit goes to him for all the awesome work that he put into it. His version is no longer maintained, however, and I've decided to actively maintain it for a project that I'm using this library for, [Hermes](https://github.com/HermesApp/Hermes).

## Documentation

Documentation can either be found [here](http://alexcrichton.com/AudioStreamer/index.html) in an Apple-like format or in this README.

## The `AudioStreamer` class

The AudioStreamer class is a wrapper around the AudioQueue, AudioFileStream, and CFReadStream classes. It aims to provide a solid API to manage an audio stream. When dealing with remote audio, however, there are a large number of errors which can happen, and it can get very confusing very quickly. To simplify things, the core principals of the AudioStreamer class are:

* An AudioStreamer instance can only be used once for one song
* Once an error has been encountered, it is impossible for any more playback to occur using this instance of an AudioStreamer
* All notifications of state and error are sent through `AudioStreamerDelegate`, and this is how the stream should be managed/watched. See the [AudioStreamerDelegate documentation page](http://alexcrichton.com/AudioStreamer/Protocols/AudioStreamerDelegate.html)

It is NOT the job of the AudioStreamer to:

* Resolve errors on the audio or network streams
* Display errors in any form or fashion
* Play multiple songs (see the `ASPlaylist` class)
* Automatically perform actions in response to playback events

## The `iOSStreamer` class

The iOSStreamer class is a subclass of AudioStreamer which handles possible interruptions to the stream. These include, but are not limited to:

* Phone calls (including FaceTime)
* Siri
* Playing audio in another app (eg. Music) after the stream has started.

iOSStreamer introduces `iOSStreamerDelegate` which extends `AudioStreamerDelegate`. This delegate may be used to handle interruptions yourself. For example, you may want to stop the stream instead of pausing it when playing a livestream.

## Sample Usage (`AudioStreamer`)

```objc
- (void) play {
  NSURL *url = ...;
  AudioStreamer *stream = [AudioStreamer streamWithUrl:url];
  [stream setDelegate:self];

  /* Optional: Set some properties like proxies, buffer sizes, formats, etc. on stream */

  [stream start];
}

- (void)streamerStatusDidChange:(AudioStreamer *)sender {
  if ([sender error] != nil) {
    // handle the error via a UI, retrying the stream, etc.
  } else if ([sender isPlaying]) {
    [self setIcon:pause];
  } else if ([sender isPaused]) {
    [self setIcon:play];
  } else if ([sender isDone]) {
    [self playNextSong];
  } else {
    // stream is waiting for data, probably nothing to do
  }
}
```

## Changes

The AudioStreamer class has heavily changed from the original version, and all of the methods and whatnot can be found in the source files. The source also contains a large amount of documentation for usage.

* [Header](https://github.com/alexcrichton/AudioStreamer/blob/master/AudioStreamer/AudioStreamer.h)
* [Implementation](https://github.com/alexcrichton/AudioStreamer/blob/master/AudioStreamer/AudioStreamer.m)

## Using AudioStreamer as a Framework (OS X)

```bash
git clone git://github.com/alexcrichton/AudioStreamer
cd AudioStreamer
make framework
```

The built framework will be available in `build/Release/AudioStreamer.framework`. To use this with an application, you need to configure Xcode to link against this framework and also copy it into the `Frameworks` folder of your project after it is built.

## Including AudioStreamer source directly

All files related to the AudioStreamer library are located in the [AudioStreamer](https://github.com/alexcrichton/AudioStreamer/tree/master/AudioStreamer) directory. These just need to be copied into your project and added to the compiled sources list.

You must also link against some frameworks to build:

* OS X - AudioToolbox, CoreServices, and Foundation (last 2 can be replaced with Cocoa)
* iOS - AudioToolbox, AVFoundation (if using the iOSStreamer class), CFNetwork and Foundation

The sample apps use some additional frameworks but these are specific to the sample apps.

## Supported OS versions

AudioStreamer currently targets a minimum of iOS 8.0 and OS X 10.7. All later versions are supported too.

## Problems/Question?

Open [an issue](https://github.com/alexcrichton/AudioStreamer/issues)! I'd love to fix any problems and find bugs because I use the library as well!
