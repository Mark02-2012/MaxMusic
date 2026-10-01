#import "YTMOfflinePlayerManager.h"
#import <AVFoundation/AVFoundation.h>

NSString * const YTMOfflinePlayerStateDidChangeNotification = @"YTMOfflinePlayerStateDidChangeNotification";
NSString * const YTMOfflinePlayerTrackDidChangeNotification = @"YTMOfflinePlayerTrackDidChangeNotification";
NSString * const YTMOfflinePlayerTimeDidChangeNotification = @"YTMOfflinePlayerTimeDidChangeNotification";
NSString * const YTMU_PauseOnlinePlayerNotification = @"YTMU_PauseOnlinePlayerNotification";
NSString * const YTMU_OnlinePlayerDidStartPlayingNotification = @"YTMU_OnlinePlayerDidStartPlayingNotification";

BOOL gIsOfflineUpdatingNowPlayingInfo = NO;

@interface YTMOfflinePlayerManager ()
@property (nonatomic, assign, readwrite) BOOL isOfflinePlayerActive;
@property (nonatomic, strong, readwrite) NSArray<NSString *> *playlist;
@property (nonatomic, assign, readwrite) NSInteger currentIndex;
@property (nonatomic, strong, readwrite) NSString *currentFileName;
@property (nonatomic, assign, readwrite) BOOL isPlaying;
@property (nonatomic, assign, readwrite) NSTimeInterval currentTime;
@property (nonatomic, assign, readwrite) NSTimeInterval duration;

@property (nonatomic, strong, readwrite) UIImage *currentArtwork;
@property (nonatomic, strong, readwrite) NSString *currentTitle;
@property (nonatomic, strong, readwrite) NSString *currentArtist;

@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) id timeObserverToken;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *shuffledIndices;
@property (nonatomic, assign) NSInteger currentShufflePosition;

- (void)setupAudioSession;
- (void)setupRemoteCommandCenter;
- (void)removeTimeObserver;
- (void)addTimeObserver;
- (void)updateNowPlayingInfo;
- (void)rebuildShuffleIndices;
- (void)parseTrackMetadataForFile:(NSString *)fileName;
- (void)handleItemDidPlayToEnd:(NSNotification *)notification;
@end

@implementation YTMOfflinePlayerManager

+ (instancetype)sharedManager {
    static YTMOfflinePlayerManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[YTMOfflinePlayerManager alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _playlist = @[];
        _currentIndex = NSNotFound;
        _repeatMode = YTMOfflineRepeatModeAll;
        _isShuffleEnabled = NO;
        _shuffledIndices = [NSMutableArray array];
        _currentShufflePosition = 0;
        _isOfflinePlayerActive = NO;
        
        [self setupRemoteCommandCenter];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleItemDidPlayToEnd:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:nil];
                                                   
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(markOnlinePlayerActive)
                                                     name:YTMU_OnlinePlayerDidStartPlayingNotification
                                                   object:nil];
    }
    return self;
}

- (void)markOnlinePlayerActive {
    self.isOfflinePlayerActive = NO;
    if (self.isPlaying) {
        [self pause];
    }
}

- (void)dealloc {
    [self removeTimeObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupAudioSession {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [audioSession setCategory:AVAudioSessionCategoryPlayback error:&error];
    [audioSession setActive:YES error:&error];
}

#pragma mark - Playback Controls

- (void)playPlaylist:(NSArray<NSString *> *)playlist startIndex:(NSInteger)index {
    if (!playlist || playlist.count == 0) return;
    
    self.isOfflinePlayerActive = YES;
    self.playlist = [playlist copy];
    [self rebuildShuffleIndices];
    
    if (index < 0 || index >= self.playlist.count) {
        index = 0;
    }
    
    [self playTrackAtIndex:index];
}

- (void)updatePlaylist:(NSArray<NSString *> *)playlist {
    if (!playlist) return;
    NSString *currentName = self.currentFileName;
    self.playlist = [playlist copy];
    [self rebuildShuffleIndices];
    
    if (currentName) {
        NSUInteger newIndex = [self.playlist indexOfObject:currentName];
        if (newIndex != NSNotFound) {
            self.currentIndex = newIndex;
        } else if (self.playlist.count > 0) {
            self.currentIndex = 0;
        } else {
            [self pause];
            self.currentIndex = NSNotFound;
            self.currentFileName = nil;
        }
    }
}

- (void)playTrackAtIndex:(NSInteger)index {
    if (index < 0 || index >= self.playlist.count) return;
    
    self.isOfflinePlayerActive = YES;
    [self setupAudioSession];
    
    self.currentIndex = index;
    self.currentFileName = self.playlist[index];
    
    [self parseTrackMetadataForFile:self.currentFileName];
    
    NSURL *fileURL = [self fileURLForAudioName:self.currentFileName];
    if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
        return;
    }
    
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:fileURL];
    if (!playerItem) return;
    
    if (self.player) {
        [self removeTimeObserver];
        [self.player replaceCurrentItemWithPlayerItem:playerItem];
    } else {
        self.player = [AVPlayer playerWithPlayerItem:playerItem];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMU_PauseOnlinePlayerNotification object:nil];
    
    [self addTimeObserver];
    [self.player play];
    self.isPlaying = YES;
    
    [self updateNowPlayingInfo];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMOfflinePlayerTrackDidChangeNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMOfflinePlayerStateDidChangeNotification object:self];
}

- (void)play {
    self.isOfflinePlayerActive = YES;
    if (self.player) {
        [self setupAudioSession];
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMU_PauseOnlinePlayerNotification object:nil];
        [self.player play];
        self.isPlaying = YES;
        [self updateNowPlayingInfo];
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMOfflinePlayerStateDidChangeNotification object:self];
    } else if (self.playlist.count > 0) {
        NSInteger targetIndex = (self.currentIndex != NSNotFound && self.currentIndex < self.playlist.count) ? self.currentIndex : 0;
        [self playTrackAtIndex:targetIndex];
    }
}

- (void)pause {
    if (self.player) {
        [self.player pause];
        self.isPlaying = NO;
        [self updateNowPlayingInfo];
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMOfflinePlayerStateDidChangeNotification object:self];
    }
}

- (void)togglePlayPause {
    if (self.isPlaying) {
        [self pause];
    } else {
        [self play];
    }
}

- (void)playNext {
    if (self.playlist.count == 0) return;
    
    if (self.repeatMode == YTMOfflineRepeatModeOne) {
        [self seekToTime:0];
        [self play];
        return;
    }
    
    NSInteger nextIndex = NSNotFound;
    if (self.isShuffleEnabled) {
        if (self.shuffledIndices.count > 0) {
            self.currentShufflePosition = (self.currentShufflePosition + 1) % self.shuffledIndices.count;
            nextIndex = [self.shuffledIndices[self.currentShufflePosition] integerValue];
        } else {
            nextIndex = (self.currentIndex + 1) % self.playlist.count;
        }
    } else {
        if (self.currentIndex + 1 < self.playlist.count) {
            nextIndex = self.currentIndex + 1;
        } else if (self.repeatMode == YTMOfflineRepeatModeAll) {
            nextIndex = 0;
        }
    }
    
    if (nextIndex != NSNotFound) {
        [self playTrackAtIndex:nextIndex];
    } else {
        [self pause];
        [self seekToTime:0];
    }
}

- (void)playPrevious {
    if (self.playlist.count == 0) return;
    
    if (self.currentTime > 3.0) {
        [self seekToTime:0];
        return;
    }
    
    NSInteger prevIndex = NSNotFound;
    if (self.isShuffleEnabled) {
        if (self.shuffledIndices.count > 0) {
            if (self.currentShufflePosition > 0) {
                self.currentShufflePosition--;
            } else {
                self.currentShufflePosition = self.shuffledIndices.count - 1;
            }
            prevIndex = [self.shuffledIndices[self.currentShufflePosition] integerValue];
        } else {
            prevIndex = (self.currentIndex > 0) ? self.currentIndex - 1 : self.playlist.count - 1;
        }
    } else {
        if (self.currentIndex > 0) {
            prevIndex = self.currentIndex - 1;
        } else if (self.repeatMode == YTMOfflineRepeatModeAll) {
            prevIndex = self.playlist.count - 1;
        } else {
            prevIndex = 0;
        }
    }
    
    if (prevIndex != NSNotFound) {
        [self playTrackAtIndex:prevIndex];
    }
}

- (void)seekToTime:(NSTimeInterval)time {
    if (self.player) {
        CMTime targetTime = CMTimeMakeWithSeconds(time, NSEC_PER_SEC);
        [self.player seekToTime:targetTime completionHandler:^(BOOL finished) {
            if (finished) {
                [self updateNowPlayingInfo];
            }
        }];
    }
}

- (void)toggleShuffle {
    self.isShuffleEnabled = !self.isShuffleEnabled;
    [self rebuildShuffleIndices];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMOfflinePlayerStateDidChangeNotification object:self];
}

- (void)cycleRepeatMode {
    switch (self.repeatMode) {
        case YTMOfflineRepeatModeOff:
            self.repeatMode = YTMOfflineRepeatModeAll;
            break;
        case YTMOfflineRepeatModeAll:
            self.repeatMode = YTMOfflineRepeatModeOne;
            break;
        case YTMOfflineRepeatModeOne:
            self.repeatMode = YTMOfflineRepeatModeOff;
            break;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMOfflinePlayerStateDidChangeNotification object:self];
}

#pragma mark - Auto Play Next Handler

- (void)handleItemDidPlayToEnd:(NSNotification *)notification {
    AVPlayerItem *item = notification.object;
    if (item == self.player.currentItem) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.repeatMode == YTMOfflineRepeatModeOne) {
                [self seekToTime:0];
                [self play];
            } else {
                [self playNext];
            }
        });
    }
}

#pragma mark - Helper Methods & Metadata

- (void)rebuildShuffleIndices {
    [self.shuffledIndices removeAllObjects];
    for (NSInteger i = 0; i < self.playlist.count; i++) {
        [self.shuffledIndices addObject:@(i)];
    }
    
    for (NSUInteger i = 0; i < self.shuffledIndices.count; i++) {
        NSUInteger remainingCount = self.shuffledIndices.count - i;
        NSUInteger exchangeIndex = i + arc4random_uniform((uint32_t)remainingCount);
        [self.shuffledIndices exchangeObjectAtIndex:i withObjectAtIndex:exchangeIndex];
    }
    
    if (self.currentIndex != NSNotFound && self.playlist.count > 0) {
        NSUInteger pos = [self.shuffledIndices indexOfObject:@(self.currentIndex)];
        if (pos != NSNotFound) {
            self.currentShufflePosition = pos;
        }
    }
}

- (NSURL *)downloadsDirectoryURL {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
}

- (NSURL *)fileURLForAudioName:(NSString *)name {
    return [[self downloadsDirectoryURL] URLByAppendingPathComponent:name];
}

- (UIImage *)artworkForAudioName:(NSString *)name {
    NSString *baseName = [name stringByDeletingPathExtension];
    NSString *imageName = [NSString stringWithFormat:@"%@.png", baseName];
    NSURL *imageURL = [[self downloadsDirectoryURL] URLByAppendingPathComponent:imageName];
    
    UIImage *image = [UIImage imageWithContentsOfFile:imageURL.path];
    if (!image) {
        image = [UIImage systemImageNamed:@"music.note"];
    }
    return image;
}

- (void)parseTrackMetadataForFile:(NSString *)fileName {
    NSString *cleanName = [fileName stringByDeletingPathExtension];
    NSArray *components = [cleanName componentsSeparatedByString:@" - "];
    
    if (components.count >= 2) {
        self.currentArtist = components[0];
        self.currentTitle = [[components subarrayWithRange:NSMakeRange(1, components.count - 1)] componentsJoinedByString:@" - "];
    } else {
        self.currentTitle = cleanName;
        self.currentArtist = @"Offline Track";
    }
    
    self.currentArtwork = [self artworkForAudioName:fileName];
}

#pragma mark - Time Observer & Remote Controls

- (void)addTimeObserver {
    [self removeTimeObserver];
    
    __weak typeof(self) weakSelf = self;
    self.timeObserverToken = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, NSEC_PER_SEC)
                                                                        queue:dispatch_get_main_queue()
                                                                   usingBlock:^(CMTime time) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        strongSelf.currentTime = CMTimeGetSeconds(time);
        CMTime durationTime = strongSelf.player.currentItem.duration;
        if (CMTIME_IS_VALID(durationTime) && !CMTIME_IS_INDEFINITE(durationTime)) {
            strongSelf.duration = CMTimeGetSeconds(durationTime);
        } else {
            strongSelf.duration = 0;
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:YTMOfflinePlayerTimeDidChangeNotification object:strongSelf];
    }];
}

- (void)removeTimeObserver {
    if (self.timeObserverToken && self.player) {
        [self.player removeTimeObserver:self.timeObserverToken];
        self.timeObserverToken = nil;
    }
}

- (void)setupRemoteCommandCenter {
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    
    [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!self.isOfflinePlayerActive) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        [self play];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!self.isOfflinePlayerActive) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        [self pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!self.isOfflinePlayerActive) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        [self togglePlayPause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!self.isOfflinePlayerActive) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        [self playNext];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!self.isOfflinePlayerActive) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        [self playPrevious];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!self.isOfflinePlayerActive) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        MPChangePlaybackPositionCommandEvent *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
        [self seekToTime:positionEvent.positionTime];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!self.isOfflinePlayerActive) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        MPSkipIntervalCommandEvent *skipEvent = (MPSkipIntervalCommandEvent *)event;
        NSTimeInterval interval = (skipEvent && skipEvent.interval > 0) ? skipEvent.interval : 15.0;
        [self seekToTime:self.currentTime + interval];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    
    [commandCenter.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        if (!self.isOfflinePlayerActive) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        MPSkipIntervalCommandEvent *skipEvent = (MPSkipIntervalCommandEvent *)event;
        NSTimeInterval interval = (skipEvent && skipEvent.interval > 0) ? skipEvent.interval : 15.0;
        [self seekToTime:MAX(0, self.currentTime - interval)];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)updateNowPlayingInfo {
    if (!self.isOfflinePlayerActive) return;
    
    gIsOfflineUpdatingNowPlayingInfo = YES;
    NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];
    
    if (self.currentTitle) {
        nowPlayingInfo[MPMediaItemPropertyTitle] = self.currentTitle;
    }
    if (self.currentArtist) {
        nowPlayingInfo[MPMediaItemPropertyArtist] = self.currentArtist;
    }
    if (self.currentArtwork) {
        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:self.currentArtwork.size requestHandler:^UIImage * _Nonnull(CGSize size) {
            return self.currentArtwork;
        }];
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork;
    }
    
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = @(self.duration);
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = @(self.isPlaying ? 1.0 : 0.0);
    
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nowPlayingInfo;
    gIsOfflineUpdatingNowPlayingInfo = NO;
}

@end
