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

@implementation UIViewController (YTMNativePlayer)

+ (void)ytm_playVideoWithID:(NSString *)videoId fromSender:(id)sender {
    if (!videoId || videoId.length == 0) return;
    
    [[%c(YTMOfflinePlayerManager) sharedManager] markOnlinePlayerActive];
    
    YTIWatchEndpoint *watchEndpoint = [%c(YTIWatchEndpoint) new];
    watchEndpoint.videoId = videoId;
    
    YTICommand *command = [%c(YTICommand) new];
    command.watchEndpoint = watchEndpoint;
    
    UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
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
            [(id)rootVC handleCommand:command];
        }
    }
}

@end

%hook UIViewController
- (void)handleCommand:(id)command sender:(id)sender {
    if (command && [command respondsToSelector:@selector(watchEndpoint)] && [command performSelector:@selector(watchEndpoint)] != nil) {
        [[%c(YTMOfflinePlayerManager) sharedManager] markOnlinePlayerActive];
    }
    %orig;
}
- (void)handleCommand:(id)command {
    if (command && [command respondsToSelector:@selector(watchEndpoint)] && [command performSelector:@selector(watchEndpoint)] != nil) {
        [[%c(YTMOfflinePlayerManager) sharedManager] markOnlinePlayerActive];
    }
    %orig;
}
%end

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
        NSString *localFileName = [YTMDownloadMetadata fileNameForVideoId:vId];
        if (!localFileName) {
            NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *directURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", vId]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:directURL.path]) {
                localFileName = vId;
            }
        }
        
        if (localFileName) {
            NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *localAudioURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@", localFileName]];
            if ([[NSFileManager defaultManager] fileExistsAtPath:localAudioURL.path]) {
                sd.hlsManifestURL = localAudioURL.absoluteString;
            }
        }
    }
    
    return sd;
}
%end

%hook YTPlayerViewController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(ytmu_pauseOnlinePlayer) name:YTMU_PauseOnlinePlayerNotification object:nil];
}

- (void)playbackController:(id)arg1 didActivateVideo:(id)arg2 withPlaybackData:(id)arg3 {
    %orig;
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) {
        [(id)self ytmu_pauseOnlinePlayer];
    } else {
        [[%c(YTMOfflinePlayerManager) sharedManager] markOnlinePlayerActive];
    }
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

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) {
        if (!gIsOfflineUpdatingNowPlayingInfo) {
            return;
        }
    }
    %orig;
}
%end

%hook YTQueueController
- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)playVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)nextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)previousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)skipToNext {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)skipToPrevious {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)playNextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)playPreviousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
%end

%hook YTLocalPlaybackController
- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)playVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)nextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)previousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)playNextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)playPreviousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
%end

%hook YTSingleVideoController
- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)playVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)nextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)previousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
%end

%hook YTPlayerViewController
- (void)play {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)playVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)nextVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
- (void)previousVideo {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return;
    %orig;
}
%end

%hook YTRemoteControlCenter
- (id)handleNextCommand:(id)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return nil;
    return %orig;
}
- (id)handlePreviousCommand:(id)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return nil;
    return %orig;
}
- (id)handlePlayCommand:(id)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return nil;
    return %orig;
}
- (id)handlePauseCommand:(id)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return nil;
    return %orig;
}
%end

%hook YTSystemMediaControlHandler
- (id)handleNextTrackCommand:(id)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return nil;
    return %orig;
}
- (id)handlePreviousTrackCommand:(id)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return nil;
    return %orig;
}
- (id)handlePlayCommand:(id)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return nil;
    return %orig;
}
- (id)handlePauseCommand:(id)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) return nil;
    return %orig;
}
%end

%hook UIResponder
- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if ([[%c(YTMOfflinePlayerManager) sharedManager] isOfflinePlayerActive]) {
        if (![self isKindOfClass:[%c(YTMOfflinePlayerManager) class]]) {
            return;
        }
    }
    %orig;
}
%end
