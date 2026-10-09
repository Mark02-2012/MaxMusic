#import "YTMOfflineMiniPlayerView.h"
#import "YTMOfflinePlayerManager.h"

@interface YTMOfflineMiniPlayerView ()
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIProgressView *progressView;
@end

@implementation YTMOfflineMiniPlayerView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupUI];
        [self setupNotifications];
        [self updateState];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    self.backgroundColor = [UIColor colorWithRed:20/255.0 green:20/255.0 blue:20/255.0 alpha:0.95];
    self.layer.cornerRadius = 12;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.clipsToBounds = YES;
    
    // Top progress line
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.progressTintColor = [UIColor redColor];
    self.progressView.trackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    [self addSubview:self.progressView];
    
    // Artwork
    self.artworkImageView = [[UIImageView alloc] init];
    self.artworkImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkImageView.layer.cornerRadius = 6;
    self.artworkImageView.clipsToBounds = YES;
    self.artworkImageView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    [self addSubview:self.artworkImageView];
    
    // Labels stack / layout
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor whiteColor];
    [self addSubview:self.titleLabel];
    
    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.artistLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.artistLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    [self addSubview:self.artistLabel];
    
    // Play/Pause button
    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playPauseButton.tintColor = [UIColor whiteColor];
    [self.playPauseButton addTarget:self action:@selector(didTapPlayPause) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.playPauseButton];
    
    // Next button
    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.nextButton.tintColor = [UIColor whiteColor];
    [self.nextButton setImage:[UIImage systemImageNamed:@"forward.fill"] forState:UIControlStateNormal];
    [self.nextButton addTarget:self action:@selector(didTapNext) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.nextButton];
    
    // Tap gesture on self to expand
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didTapSelf:)];
    [self addGestureRecognizer:tap];
    
    [NSLayoutConstraint activateConstraints:@[
        // Progress view
        [self.progressView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.progressView.heightAnchor constraintEqualToConstant:2],
        
        // Artwork
        [self.artworkImageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [self.artworkImageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:1],
        [self.artworkImageView.widthAnchor constraintEqualToConstant:44],
        [self.artworkImageView.heightAnchor constraintEqualToConstant:44],
        
        // Next button (right)
        [self.nextButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [self.nextButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.nextButton.widthAnchor constraintEqualToConstant:32],
        [self.nextButton.heightAnchor constraintEqualToConstant:32],
        
        // Play/Pause button
        [self.playPauseButton.trailingAnchor constraintEqualToAnchor:self.nextButton.leadingAnchor constant:-8],
        [self.playPauseButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.playPauseButton.widthAnchor constraintEqualToConstant:32],
        [self.playPauseButton.heightAnchor constraintEqualToConstant:32],
        
        // Title
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.artworkImageView.trailingAnchor constant:12],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.playPauseButton.leadingAnchor constant:-8],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.artworkImageView.topAnchor constant:4],
        
        // Artist
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.artworkImageView.trailingAnchor constant:12],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:self.playPauseButton.leadingAnchor constant:-8],
        [self.artistLabel.bottomAnchor constraintEqualToAnchor:self.artworkImageView.bottomAnchor constant:-4]
    ]];
}

- (void)setupNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateState) name:YTMOfflinePlayerStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateState) name:YTMOfflinePlayerTrackDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateTime) name:YTMOfflinePlayerTimeDidChangeNotification object:nil];
}

- (void)updateState {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTMOfflinePlayerManager *manager = [YTMOfflinePlayerManager sharedManager];
        
        if (manager.currentFileName.length > 0 || manager.currentTitle.length > 0) {
            self.hidden = NO;
            self.titleLabel.text = manager.currentTitle ?: @"Offline Track";
            self.artistLabel.text = manager.currentArtist ?: @"Artist";
            self.artworkImageView.image = manager.currentArtwork ?: [UIImage systemImageNamed:@"music.note"];
            
            NSString *iconName = manager.isPlaying ? @"pause.fill" : @"play.fill";
            [self.playPauseButton setImage:[UIImage systemImageNamed:iconName] forState:UIControlStateNormal];
            
            [self updateTime];
        } else {
            self.hidden = YES;
        }
    });
}

- (void)updateTime {
    YTMOfflinePlayerManager *manager = [YTMOfflinePlayerManager sharedManager];
    if (manager.duration > 0) {
        float progress = manager.currentTime / manager.duration;
        [self.progressView setProgress:progress animated:YES];
    } else {
        [self.progressView setProgress:0 animated:NO];
    }
}

- (void)didTapPlayPause {
    [[YTMOfflinePlayerManager sharedManager] togglePlayPause];
}

- (void)didTapNext {
    [[YTMOfflinePlayerManager sharedManager] playNext];
}

- (void)didTapSelf:(UITapGestureRecognizer *)gesture {
    CGPoint point = [gesture locationInView:self];
    // Check if tap was on action buttons
    if (CGRectContainsPoint(self.playPauseButton.frame, point) || CGRectContainsPoint(self.nextButton.frame, point)) {
        return;
    }
    
    if (self.onTapExpandBlock) {
        self.onTapExpandBlock();
    } else {
        UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
        if (![topVC isKindOfClass:NSClassFromString(@"YTMOfflinePlayerViewController")]) {
            Class playerClass = NSClassFromString(@"YTMOfflinePlayerViewController");
            if (playerClass) {
                UIViewController *playerVC = [[playerClass alloc] init];
                playerVC.modalPresentationStyle = UIModalPresentationFullScreen;
                [topVC presentViewController:playerVC animated:YES completion:nil];
            }
        }
    }
}

@end
