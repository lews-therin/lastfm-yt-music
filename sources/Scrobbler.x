#import "../headers/Scrobbler.h"
#import <MediaPlayer/MediaPlayer.h>

static NSString *currentSongLocalID = @"";
static double currentTotalMediaTime = 0;
static BOOL currentSongReplayed = NO;
static NSTimer *timer = nil;
static BOOL scrobbled = NO;
static BOOL isPlaying = NO;

@implementation LFMScrobbler

+ (void) poll {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Use MPNowPlayingInfoCenter — stable across YT Music updates
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        NSDictionary *info = [center nowPlayingInfo];

        NSString *artist = info[MPMediaItemPropertyArtist];
        NSString *track  = info[MPMediaItemPropertyTitle];
        NSNumber *durationNum = info[MPMediaItemPropertyPlaybackDuration];

        // Guard against nil metadata (e.g. during buffering)
        if (!artist || !track) {
            NSLog(@"[LFM] Metadata not available yet (artist=%@, track=%@)", artist, track);
            return;
        }

        // Still use the internal controller for localID + mediaTime
        YTQueueController *controller = [LFMYouTubeInstances queueController];
        YTQueueItem *item             = [controller nowPlayingMusicQueueItem];
        NSString *localID             = [item localID] ?: track; // fall back to track name if localID is nil
        double mediaTime              = [controller nowPlayingVideoMediaTime];

        // Use duration from MPNowPlayingInfo if internal API gives 0
        if (durationNum && currentTotalMediaTime <= 0) {
            currentTotalMediaTime = [durationNum doubleValue];
        }

        // ✅ Fixed: use isEqualToString: instead of ==
        if ((!currentSongReplayed && [currentSongLocalID isEqualToString:localID] && mediaTime < 1) && isPlaying) {
            currentSongReplayed = YES;
        }

        if ((![localID isEqualToString:currentSongLocalID] || mediaTime > 1) && isPlaying) {
            currentSongReplayed = NO;
        }

        if ((![localID isEqualToString:currentSongLocalID] || currentSongReplayed) && isPlaying) {
            NSLog(@"[LFM] Now Playing: %@ - %@", artist, track);

            scrobbled = NO;
            currentSongLocalID = localID;
            [LFMClient setNowPlaying:track artist:artist duration:currentTotalMediaTime];
        }

        if (!scrobbled && isPlaying && currentTotalMediaTime > 0 && mediaTime >= (currentTotalMediaTime / 2)) {
            NSLog(@"[LFM] Scrobbling: %@ - %@", artist, track);

            [LFMClient scrobble:track artist:artist duration:currentTotalMediaTime elapsed:mediaTime];
            scrobbled = YES;
        }
    });
}

@end

%hook MLHAMPlayerItem

- (void) playerStateDidChangeFrom:(NSInteger*)from to:(NSInteger*)to {
    %orig;

    // 3 = Playing
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