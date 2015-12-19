XCB           = xcodebuild
CONFIGURATION = Release
XCBFLAGS      = -configuration $(CONFIGURATION)

.PHONY: dochtml docset

all: framework mac iphonelib iphone

framework:
	$(XCB) $(XCBFLAGS) -target AudioStreamer

mac:
	$(XCB) $(XCBFLAGS) -target 'Mac Streaming Player'

iphonelib: XCBFLAGS += -sdk iphoneos
iphonelib:
	$(XCB) $(XCBFLAGS) -target 'libAudioStreamer'

iphone: XCBFLAGS += -sdk iphoneos
iphone:
	$(XCB) $(XCBFLAGS) -target 'iPhone Streaming Player'

dochtml:
	appledoc --project-name AudioStreamer --project-company ' ' \
		--company-id ' ' --no-repeat-first-par -o dochtml \
		--no-create-docset --explicit-crossref --ignore AudioStreamer.m \
		--ignore ASPlaylist.m --ignore iOSStreamer.m AudioStreamer

docset:
	appledoc --project-name AudioStreamer --project-company ' ' \
		--company-id ' ' --no-repeat-first-par -o docset \
		--docset-install-path docset --explicit-crossref \
		--ignore AudioStreamer.m --ignore ASPlaylist.m \
		--ignore iOSStreamer.m AudioStreamer

clean:
	$(XCB) clean
	rm -rf build
