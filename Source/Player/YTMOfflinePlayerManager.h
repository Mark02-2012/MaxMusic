#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CoreMedia/CoreMedia.h>

@class AVPlayer;
@class AVPlayerItem;

typedef NS_ENUM(NSInteger, YTMOfflineRepeatMode) {
    YTMOfflineRepeatModeOff = 0,
    YTMOfflineRepeatModeAll,
    YTMOfflineRepeatModeOne
};

extern NSString * const YTMOfflinePlayerStateDidChangeNotification;
extern NSString * const YTMOfflinePlayerTrackDidChangeNotification;
extern NSString * const YTMOfflinePlayerTimeDidChangeNotification;
extern NSString * const YTMU_PauseOnlinePlayerNotification;
extern NSString * const YTMU_OnlinePlayerDidStartPlayingNotification;

extern BOOL gIsOfflineUpdatingNowPlayingInfo;

@interface YTMOfflinePlayerManager : NSObject

@property (nonatomic, assign, readonly) BOOL isOfflinePlayerActive;
@property (nonatomic, strong, readonly) NSArray<NSString *> *playlist;
@property (nonatomic, assign, readonly) NSInteger currentIndex;
@property (nonatomic, strong, readonly) NSString *currentFileName;
@property (nonatomic, assign, readonly) BOOL isPlaying;
@property (nonatomic, assign) BOOL isShuffleEnabled;
@property (nonatomic, assign) YTMOfflineRepeatMode repeatMode;
@property (nonatomic, assign, readonly) NSTimeInterval currentTime;
@property (nonatomic, assign, readonly) NSTimeInterval duration;

@property (nonatomic, strong, readonly) UIImage *currentArtwork;
@property (nonatomic, strong, readonly) NSString *currentTitle;
@property (nonatomic, strong, readonly) NSString *currentArtist;

+ (instancetype)sharedManager;

- (void)playPlaylist:(NSArray<NSString *> *)playlist startIndex:(NSInteger)index;
- (void)playTrackAtIndex:(NSInteger)index;
- (void)play;
- (void)pause;
- (void)togglePlayPause;
- (void)playNext;
- (void)playPrevious;
- (void)seekToTime:(NSTimeInterval)time;
- (void)toggleShuffle;
- (void)cycleRepeatMode;
- (void)updatePlaylist:(NSArray<NSString *> *)playlist;
- (void)markOnlinePlayerActive;
- (NSURL *)fileURLForAudioName:(NSString *)name;
- (UIImage *)artworkForAudioName:(NSString *)name;

@end
