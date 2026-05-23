#import "../headers/Scrobbler.h"
#import <MediaPlayer/MediaPlayer.h>

static NSString *currentSongLocalID = @"";
static NSString *currentTrack = @"";
static NSString *currentArtist = @"";
static double currentTotalMediaTime = 0;
static double trackedElapsed = 0;        // our own elapsed counter
static NSTimer *timer = nil;
static BOOL scrobbled = NO;
static BOOL isPlaying = NO;

@implementation LFMScrobbler

+ (void) scrobbleCurrentIfEligible {
    if (!scrobbled && currentTotalMediaTime > 0 && trackedElapsed >= (currentTotalMediaTime / 2)) {
        NSLog(@"[LFM] Scrobbling: %@ - %@ (elapsed: %.0fs / %.0fs)", currentArtist, currentTrack, trackedElapsed, currentTotalMediaTime);
        [LFMClient scrobble:currentTrack artist:currentArtist duration:currentTotalMediaTime elapsed:trackedElapsed];
        scrobbled = YES;
    }
}

+ (void) poll {
    dispatch_async(dispatch_get_main_queue(), ^{
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        NSDictionary *info = [center nowPlayingInfo];

        NSString *artist   = info[MPMediaItemPropertyArtist];
        NSString *track    = info[MPMediaItemPropertyTitle];
        double duration    = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
        double rate        = [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue];

        if (!artist || !track || duration <= 0) {
            NSLog(@"[LFM] Metadata not available yet (artist=%@, track=%@, duration=%.0f)", artist, track, duration);
            return;
        }

        // Use localID for song-change detection, fall back to track name
        YTQueueController *controller = [LFMYouTubeInstances queueController];
        YTQueueItem *item             = [controller nowPlayingMusicQueueItem];
        NSString *localID             = [item localID] ?: track;

        BOOL songChanged = ![localID isEqualToString:currentSongLocalID];

        if (songChanged) {
            // Attempt to scrobble the previous song before switching
            [LFMScrobbler scrobbleCurrentIfEligible];

            NSLog(@"[LFM] Now Playing: %@ - %@ (duration: %.0fs)", artist, track, duration);

            // Reset state for new song
            currentSongLocalID    = localID;
            currentTrack          = track;
            currentArtist         = artist;
            currentTotalMediaTime = duration;
            trackedElapsed        = 0;
            scrobbled             = NO;

            [LFMClient setNowPlaying:track artist:artist duration:duration];
        } else {
            // Tick elapsed forward only while actually playing
            if (isPlaying && rate > 0) {
                trackedElapsed += 1.0;
            }

            // Check scrobble threshold
            [LFMScrobbler scrobbleCurrentIfEligible];
        }
    });
}

@end

%hook MLHAMPlayerItem

- (void) playerStateDidChangeFrom:(NSInteger*)from to:(NSInteger*)to {
    %orig;

    if ((int)(size_t)to == 3) {
        isPlaying = TRUE;

        dispatch_async(dispatch_get_main_queue(), ^{
            timer = [NSTimer
                scheduledTimerWithTimeInterval:1.0f
                target:[NSBlockOperation blockOperationWithBlock:^{ [LFMScrobbler poll]; }]
                selector:@selector(main)
                userInfo:nil
                repeats:YES
            ];
        });
    } else {
        if (timer) {
            [timer invalidate];
            timer = nil;
        }
        isPlaying = FALSE;
    }

    currentTotalMediaTime = [self totalMediaTime];
}

%end