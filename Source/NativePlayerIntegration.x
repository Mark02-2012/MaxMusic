#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "Headers/YTICommand.h"
#import "Headers/YTPlayerResponse.h"
#import "Headers/YTPlayerViewController.h"
#import "Utils/YTMDownloadMetadata.h"
#import "Player/YTMOfflinePlayerManager.h"

@interface YTPlayerViewController (YTMU)
- (void)ytmu_pauseOnlinePlayer;
@end

@interface YTIVideoDetails (YTM)
@property (nonatomic, copy, readwrite) NSString *videoId;
@end

@interface YTPlayerResponse (YTM)
- (NSString *)contentVideoID;
@end

@interface YTIWatchEndpoint : NSObject
@property (nonatomic, copy, readwrite) NSString *videoId;
@property (nonatomic, copy, readwrite) NSString *playlistId;
@property (nonatomic, assign, readwrite) unsigned int index;
@end

@interface YTICommand (Watch)
@property (nonatomic, readwrite, strong) YTIWatchEndpoint *watchEndpoint;
@end

@interface UIViewController (YTCommand)
- (void)handleCommand:(YTICommand *)command sender:(id)sender;
- (void)handleCommand:(YTICommand *)command;
@end

@interface YTIMusicAppViewController : UIViewController
- (void)handleCommand:(YTICommand *)command sender:(id)sender;
@end


#pragma mark - Native player integration

@implementation UIViewController (YTMNativePlayer)

+ (void)ytm_playVideoWithID:(NSString *)videoId fromSender:(id)sender {
    if (!videoId || videoId.length == 0) {
        return;
    }

    // We are explicitly starting an online video.
    [[%c(YTMOfflinePlayerManager) sharedManager] markOnlinePlayerActive];

    YTIWatchEndpoint *watchEndpoint = [%c(YTIWatchEndpoint) new];
    watchEndpoint.videoId = videoId;

    YTICommand *command = [%c(YTICommand) new];
    command.watchEndpoint = watchEndpoint;

    UIViewController *topVC =
        [UIApplication sharedApplication].keyWindow.rootViewController;

    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    if ([topVC respondsToSelector:@selector(handleCommand:sender:)]) {
        [topVC handleCommand:command sender:sender];
    } else if ([topVC respondsToSelector:@selector(handleCommand:)]) {
        [topVC handleCommand:command];
    } else {
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        UIViewController *rootVC = window.rootViewController;

        if ([rootVC respondsToSelector:@selector(handleCommand:sender:)]) {
            [(id)rootVC handleCommand:command sender:sender];
        } else if ([rootVC respondsToSelector:@selector(handleCommand:)]) {
            [rootVC handleCommand:command];
        }
    }
}

@end


#pragma mark - Online command detection

%hook UIViewController

- (void)handleCommand:(id)command sender:(id)sender {
    if (command &&
        [command respondsToSelector:@selector(watchEndpoint)] &&
        [command performSelector:@selector(watchEndpoint)] != nil) {

        [[%c(YTMOfflinePlayerManager) sharedManager] markOnlinePlayerActive];
    }

    %orig;
}

- (void)handleCommand:(id)command {
    if (command &&
        [command respondsToSelector:@selector(watchEndpoint)] &&
        [command performSelector:@selector(watchEndpoint)] != nil) {

        [[%c(YTMOfflinePlayerManager) sharedManager] markOnlinePlayerActive];
    }

    %orig;
}

%end


#pragma mark - Local downloaded audio integration

%hook YTPlayerResponse

- (YTIStreamingData *)streamingData {
    YTIStreamingData *sd = %orig;

    NSString *vId = nil;

    if ([self respondsToSelector:@selector(videoDetails)]) {
        vId = self.playerData.videoDetails.videoId;
    }

    if (!vId && [self respondsToSelector:@selector(contentVideoID)]) {
        vId = [(id)self contentVideoID];
    }

    if (vId) {
        NSString *localFileName =
            [YTMDownloadMetadata fileNameForVideoId:vId];

        if (!localFileName) {
            NSURL *documentsURL =
                [[[NSFileManager defaultManager]
                    URLsForDirectory:NSDocumentDirectory
                           inDomains:NSUserDomainMask] lastObject];

            NSURL *directURL =
                [documentsURL
                    URLByAppendingPathComponent:
                        [NSString stringWithFormat:@"YTMusicUltimate/%@", vId]];

            if ([[NSFileManager defaultManager]
                    fileExistsAtPath:directURL.path]) {

                localFileName = vId;
            }
        }

        if (localFileName) {
            NSURL *documentsURL =
                [[[NSFileManager defaultManager]
                    URLsForDirectory:NSDocumentDirectory
                           inDomains:NSUserDomainMask] lastObject];

            NSURL *localAudioURL =
                [documentsURL
                    URLByAppendingPathComponent:
                        [NSString stringWithFormat:
                            @"YTMusicUltimate/%@",
                            localFileName]];

            if ([[NSFileManager defaultManager]
                    fileExistsAtPath:localAudioURL.path]) {

                sd.hlsManifestURL = localAudioURL.absoluteString;
            }
        }
    }

    return sd;
}

%end


#pragma mark - Player activation

%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(ytmu_pauseOnlinePlayer)
               name:YTMU_PauseOnlinePlayerNotification
             object:nil];
}

- (void)playbackController:(id)arg1
       didActivateVideo:(id)arg2
       withPlaybackData:(id)arg3 {

    YTMOfflinePlayerManager *manager =
        [%c(YTMOfflinePlayerManager) sharedManager];

    /*
     * An online video has now been activated.
     *
     * The offline player may still have its active flag set because
     * closing the offline player UI does not necessarily clear it.
     *
     * Clear it BEFORE %orig so the normal YouTube player is allowed
     * to continue.
     */
    if (manager.isOfflinePlayerActive) {
        [manager markOnlinePlayerActive];
    }

    %orig;
}

%new

- (void)ytmu_pauseOnlinePlayer {
    dispatch_async(dispatch_get_main_queue(), ^{
        id playerObj = (id)self;

        if ([playerObj respondsToSelector:@selector(pause)]) {
            [playerObj performSelector:@selector(pause)];
        } else if ([playerObj respondsToSelector:@selector(pauseVideo)]) {
            [playerObj performSelector:@selector(pauseVideo)];
        }
    });
}

%end


#pragma mark - Now Playing information

%hook MPNowPlayingInfoCenter

- (void)setNowPlayingInfo:(NSDictionary *)info {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {

        if (!gIsOfflineUpdatingNowPlayingInfo) {
            return;
        }
    }

    %orig;
}

%end


#pragma mark - Queue controller

%hook YTQueueController

- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)playVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)nextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)previousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)skipToNextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)skipToPreviousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

%end


#pragma mark - Local playback controller

%hook YTLocalPlaybackController

- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)playVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)nextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)previousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

%end


#pragma mark - Single video controller

%hook YTSingleVideoController

- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)playVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)nextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)previousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

%end


#pragma mark - Main player controls

%hook YTPlayerViewController

/*
 * IMPORTANT:
 *
 * These methods used to simply return while the offline player was
 * active. That could prevent YouTube from ever reaching
 * playbackController:didActivateVideo:...
 *
 * We therefore clear the offline state FIRST, then let YouTube
 * continue normally.
 */

- (void)play {
    [[%c(YTMOfflinePlayerManager) sharedManager]
        markOnlinePlayerActive];

    %orig;
}

- (void)playVideo {
    [[%c(YTMOfflinePlayerManager) sharedManager]
        markOnlinePlayerActive];

    %orig;
}

- (void)nextVideo {
    [[%c(YTMOfflinePlayerManager) sharedManager]
        markOnlinePlayerActive];

    %orig;
}

- (void)previousVideo {
    [[%c(YTMOfflinePlayerManager) sharedManager]
        markOnlinePlayerActive];

    %orig;
}

%end


#pragma mark - Remote control center

%hook YTRemoteControlCenter

- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)pause {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)next {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)previous {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

%end


#pragma mark - System media controls

%hook YTSystemMediaControlHandler

- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)pause {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)next {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

- (void)previous {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {
        return;
    }

    %orig;
}

%end


#pragma mark - UIResponder remote controls

%hook UIResponder

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager]
            isOfflinePlayerActive]) {

        if (![self isKindOfClass:[%c(YTMOfflinePlayerManager) class]]) {
            return;
        }
    }

    %orig;
}

%end
