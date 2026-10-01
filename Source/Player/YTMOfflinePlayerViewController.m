#import "YTMOfflinePlayerViewController.h"
#import "YTMOfflinePlayerManager.h"
#import "../Headers/Localization.h"

@interface YTMOfflinePlayerViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIButton *dismissButton;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UIImageView *artworkImageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;

@property (nonatomic, strong) UISlider *timeSlider;
@property (nonatomic, strong) UILabel *elapsedTimeLabel;
@property (nonatomic, strong) UILabel *remainingTimeLabel;

@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *prevButton;
@property (nonatomic, strong) UIButton *playPauseButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *repeatButton;

@property (nonatomic, strong) UILabel *queueHeaderLabel;
@property (nonatomic, strong) UITableView *queueTableView;

@property (nonatomic, assign) BOOL isScrubbing;
@end

@implementation YTMOfflinePlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor colorWithRed:12/255.0 green:12/255.0 blue:14/255.0 alpha:1.0];
    
    [self setupUI];
    [self setupNotifications];
    [self updateUI];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    // Header dismiss button
    self.dismissButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.dismissButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dismissButton setImage:[UIImage systemImageNamed:@"chevron.down"] forState:UIControlStateNormal];
    self.dismissButton.tintColor = [UIColor whiteColor];
    [self.dismissButton addTarget:self action:@selector(didTapDismiss) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.dismissButton];
    
    // Header title
    self.headerTitleLabel = [[UILabel alloc] init];
    self.headerTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.headerTitleLabel.text = LOC(@"NOW_PLAYING") ?: @"NOW PLAYING";
    self.headerTitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    self.headerTitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    self.headerTitleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.headerTitleLabel];
    
    // Artwork Image View
    self.artworkImageView = [[UIImageView alloc] init];
    self.artworkImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.artworkImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkImageView.layer.cornerRadius = 14;
    self.artworkImageView.clipsToBounds = YES;
    self.artworkImageView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    
    // Artwork container for shadow
    UIView *artworkContainer = [[UIView alloc] init];
    artworkContainer.translatesAutoresizingMaskIntoConstraints = NO;
    artworkContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    artworkContainer.layer.shadowOffset = CGSizeMake(0, 8);
    artworkContainer.layer.shadowRadius = 14;
    artworkContainer.layer.shadowOpacity = 0.5;
    [artworkContainer addSubview:self.artworkImageView];
    [self.view addSubview:artworkContainer];
    
    // Track Title
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.numberOfLines = 1;
    self.titleLabel.textAlignment = NSTextAlignmentLeft;
    [self.view addSubview:self.titleLabel];
    
    // Track Artist
    self.artistLabel = [[UILabel alloc] init];
    self.artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.artistLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.artistLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.7];
    self.artistLabel.textAlignment = NSTextAlignmentLeft;
    [self.view addSubview:self.artistLabel];
    
    // Scrubber Slider
    self.timeSlider = [[UISlider alloc] init];
    self.timeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.timeSlider.minimumTrackTintColor = [UIColor redColor];
    self.timeSlider.maximumTrackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
    self.timeSlider.thumbTintColor = [UIColor whiteColor];
    [self.timeSlider addTarget:self action:@selector(sliderTouchDown) forControlEvents:UIControlEventTouchDown];
    [self.timeSlider addTarget:self action:@selector(sliderTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.timeSlider addTarget:self action:@selector(sliderValueChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.timeSlider];
    
    // Time Labels
    self.elapsedTimeLabel = [[UILabel alloc] init];
    self.elapsedTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.elapsedTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.elapsedTimeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    self.elapsedTimeLabel.text = @"0:00";
    [self.view addSubview:self.elapsedTimeLabel];
    
    self.remainingTimeLabel = [[UILabel alloc] init];
    self.remainingTimeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.remainingTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.remainingTimeLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
    self.remainingTimeLabel.textAlignment = NSTextAlignmentRight;
    self.remainingTimeLabel.text = @"-0:00";
    [self.view addSubview:self.remainingTimeLabel];
    
    // Control Buttons
    self.shuffleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.shuffleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.shuffleButton setImage:[UIImage systemImageNamed:@"shuffle"] forState:UIControlStateNormal];
    [self.shuffleButton addTarget:self action:@selector(didTapShuffle) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.shuffleButton];
    
    self.prevButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.prevButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.prevButton setImage:[UIImage systemImageNamed:@"backward.fill"] forState:UIControlStateNormal];
    self.prevButton.tintColor = [UIColor whiteColor];
    [self.prevButton addTarget:self action:@selector(didTapPrev) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.prevButton];
    
    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.playPauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.playPauseButton.backgroundColor = [UIColor whiteColor];
    self.playPauseButton.tintColor = [UIColor blackColor];
    self.playPauseButton.layer.cornerRadius = 28;
    self.playPauseButton.clipsToBounds = YES;
    [self.playPauseButton addTarget:self action:@selector(didTapPlayPause) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.playPauseButton];
    
    self.nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.nextButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.nextButton setImage:[UIImage systemImageNamed:@"forward.fill"] forState:UIControlStateNormal];
    self.nextButton.tintColor = [UIColor whiteColor];
    [self.nextButton addTarget:self action:@selector(didTapNext) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.nextButton];
    
    self.repeatButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.repeatButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.repeatButton setImage:[UIImage systemImageNamed:@"repeat"] forState:UIControlStateNormal];
    [self.repeatButton addTarget:self action:@selector(didTapRepeat) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.repeatButton];
    
    // Queue Section Header
    self.queueHeaderLabel = [[UILabel alloc] init];
    self.queueHeaderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.queueHeaderLabel.text = @"UP NEXT";
    self.queueHeaderLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    self.queueHeaderLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5];
    [self.view addSubview:self.queueHeaderLabel];
    
    // Queue Table View
    self.queueTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.queueTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.queueTableView.backgroundColor = [UIColor clearColor];
    self.queueTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.queueTableView.dataSource = self;
    self.queueTableView.delegate = self;
    [self.view addSubview:self.queueTableView];
    
    // Constraints
    [NSLayoutConstraint activateConstraints:@[
        // Artwork Image inner constraints
        [self.artworkImageView.topAnchor constraintEqualToAnchor:artworkContainer.topAnchor],
        [self.artworkImageView.leadingAnchor constraintEqualToAnchor:artworkContainer.leadingAnchor],
        [self.artworkImageView.trailingAnchor constraintEqualToAnchor:artworkContainer.trailingAnchor],
        [self.artworkImageView.bottomAnchor constraintEqualToAnchor:artworkContainer.bottomAnchor],
        
        // Header
        [self.dismissButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.dismissButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.dismissButton.widthAnchor constraintEqualToConstant:32],
        [self.dismissButton.heightAnchor constraintEqualToConstant:32],
        
        [self.headerTitleLabel.centerYAnchor constraintEqualToAnchor:self.dismissButton.centerYAnchor],
        [self.headerTitleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        
        // Artwork Container
        [artworkContainer.topAnchor constraintEqualToAnchor:self.dismissButton.bottomAnchor constant:16],
        [artworkContainer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [artworkContainer.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.55],
        [artworkContainer.heightAnchor constraintEqualToAnchor:artworkContainer.widthAnchor],
        
        // Title & Artist
        [self.titleLabel.topAnchor constraintEqualToAnchor:artworkContainer.bottomAnchor constant:16],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        
        [self.artistLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.artistLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.artistLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        
        // Time Slider
        [self.timeSlider.topAnchor constraintEqualToAnchor:self.artistLabel.bottomAnchor constant:16],
        [self.timeSlider.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.timeSlider.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        
        // Time Labels
        [self.elapsedTimeLabel.topAnchor constraintEqualToAnchor:self.timeSlider.bottomAnchor constant:4],
        [self.elapsedTimeLabel.leadingAnchor constraintEqualToAnchor:self.timeSlider.leadingAnchor constant:4],
        
        [self.remainingTimeLabel.topAnchor constraintEqualToAnchor:self.timeSlider.bottomAnchor constant:4],
        [self.remainingTimeLabel.trailingAnchor constraintEqualToAnchor:self.timeSlider.trailingAnchor constant:-4],
        
        // Play/Pause Center
        [self.playPauseButton.topAnchor constraintEqualToAnchor:self.timeSlider.bottomAnchor constant:28],
        [self.playPauseButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.playPauseButton.widthAnchor constraintEqualToConstant:56],
        [self.playPauseButton.heightAnchor constraintEqualToConstant:56],
        
        // Prev & Next
        [self.prevButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.prevButton.trailingAnchor constraintEqualToAnchor:self.playPauseButton.leadingAnchor constant:-28],
        [self.prevButton.widthAnchor constraintEqualToConstant:36],
        [self.prevButton.heightAnchor constraintEqualToConstant:36],
        
        [self.nextButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.nextButton.leadingAnchor constraintEqualToAnchor:self.playPauseButton.trailingAnchor constant:28],
        [self.nextButton.widthAnchor constraintEqualToConstant:36],
        [self.nextButton.heightAnchor constraintEqualToConstant:36],
        
        // Shuffle & Repeat
        [self.shuffleButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.shuffleButton.trailingAnchor constraintEqualToAnchor:self.prevButton.leadingAnchor constant:-20],
        [self.shuffleButton.widthAnchor constraintEqualToConstant:28],
        [self.shuffleButton.heightAnchor constraintEqualToConstant:28],
        
        [self.repeatButton.centerYAnchor constraintEqualToAnchor:self.playPauseButton.centerYAnchor],
        [self.repeatButton.leadingAnchor constraintEqualToAnchor:self.nextButton.trailingAnchor constant:20],
        [self.repeatButton.widthAnchor constraintEqualToConstant:28],
        [self.repeatButton.heightAnchor constraintEqualToConstant:28],
        
        // Queue Section Header
        [self.queueHeaderLabel.topAnchor constraintEqualToAnchor:self.playPauseButton.bottomAnchor constant:20],
        [self.queueHeaderLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        
        // Queue Table View
        [self.queueTableView.topAnchor constraintEqualToAnchor:self.queueHeaderLabel.bottomAnchor constant:8],
        [self.queueTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.queueTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.queueTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8]
    ]];
}

- (void)setupNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateUI) name:YTMOfflinePlayerStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateUI) name:YTMOfflinePlayerTrackDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateTime) name:YTMOfflinePlayerTimeDidChangeNotification object:nil];
}

- (void)updateUI {
    YTMOfflinePlayerManager *manager = [YTMOfflinePlayerManager sharedManager];
    
    self.titleLabel.text = manager.currentTitle ?: @"";
    self.artistLabel.text = manager.currentArtist ?: @"";
    self.artworkImageView.image = manager.currentArtwork;
    
    NSString *playIconName = manager.isPlaying ? @"pause.fill" : @"play.fill";
    [self.playPauseButton setImage:[UIImage systemImageNamed:playIconName] forState:UIControlStateNormal];
    
    // Shuffle style
    self.shuffleButton.tintColor = manager.isShuffleEnabled ? [UIColor redColor] : [[UIColor whiteColor] colorWithAlphaComponent:0.5];
    
    // Repeat style
    switch (manager.repeatMode) {
        case YTMOfflineRepeatModeOff:
            [self.repeatButton setImage:[UIImage systemImageNamed:@"repeat"] forState:UIControlStateNormal];
            self.repeatButton.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.5];
            break;
        case YTMOfflineRepeatModeAll:
            [self.repeatButton setImage:[UIImage systemImageNamed:@"repeat"] forState:UIControlStateNormal];
            self.repeatButton.tintColor = [UIColor redColor];
            break;
        case YTMOfflineRepeatModeOne:
            [self.repeatButton setImage:[UIImage systemImageNamed:@"repeat.1"] forState:UIControlStateNormal];
            self.repeatButton.tintColor = [UIColor redColor];
            break;
    }
    
    [self updateTime];
    [self.queueTableView reloadData];
}

- (void)updateTime {
    if (self.isScrubbing) return;
    
    YTMOfflinePlayerManager *manager = [YTMOfflinePlayerManager sharedManager];
    if (manager.duration > 0) {
        self.timeSlider.maximumValue = manager.duration;
        self.timeSlider.value = manager.currentTime;
        
        self.elapsedTimeLabel.text = [self formatTime:manager.currentTime];
        NSTimeInterval remaining = manager.duration - manager.currentTime;
        self.remainingTimeLabel.text = [NSString stringWithFormat:@"-%@", [self formatTime:remaining]];
    } else {
        self.timeSlider.value = 0;
        self.elapsedTimeLabel.text = @"0:00";
        self.remainingTimeLabel.text = @"-0:00";
    }
}

- (NSString *)formatTime:(NSTimeInterval)time {
    if (isnan(time) || time < 0) return @"0:00";
    NSInteger minutes = (NSInteger)time / 60;
    NSInteger seconds = (NSInteger)time % 60;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
}

#pragma mark - Queue TableView DataSource & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [YTMOfflinePlayerManager sharedManager].playlist.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 48;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellIdentifier = @"YTMQueueCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        cell.detailTextLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.6];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 4;
    }
    
    YTMOfflinePlayerManager *manager = [YTMOfflinePlayerManager sharedManager];
    NSString *fileName = manager.playlist[indexPath.row];
    
    NSString *cleanName = [fileName stringByDeletingPathExtension];
    NSArray *components = [cleanName componentsSeparatedByString:@" - "];
    NSString *title = (components.count >= 2) ? [[components subarrayWithRange:NSMakeRange(1, components.count - 1)] componentsJoinedByString:@" - "] : cleanName;
    NSString *artist = (components.count >= 2) ? components[0] : @"Offline Track";
    
    cell.textLabel.text = title;
    cell.detailTextLabel.text = artist;
    cell.imageView.image = [manager artworkForAudioName:fileName];
    
    if (indexPath.row == manager.currentIndex) {
        cell.textLabel.textColor = [UIColor redColor];
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
        cell.tintColor = [UIColor redColor];
    } else {
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [[YTMOfflinePlayerManager sharedManager] playTrackAtIndex:indexPath.row];
}

#pragma mark - Actions

- (void)didTapDismiss {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)didTapPlayPause {
    [[YTMOfflinePlayerManager sharedManager] togglePlayPause];
}

- (void)didTapPrev {
    [[YTMOfflinePlayerManager sharedManager] playPrevious];
}

- (void)didTapNext {
    [[YTMOfflinePlayerManager sharedManager] playNext];
}

- (void)didTapShuffle {
    [[YTMOfflinePlayerManager sharedManager] toggleShuffle];
}

- (void)didTapRepeat {
    [[YTMOfflinePlayerManager sharedManager] cycleRepeatMode];
}

- (void)sliderTouchDown {
    self.isScrubbing = YES;
}

- (void)sliderTouchUp {
    self.isScrubbing = NO;
    [[YTMOfflinePlayerManager sharedManager] seekToTime:self.timeSlider.value];
}

- (void)sliderValueChanged {
    self.elapsedTimeLabel.text = [self formatTime:self.timeSlider.value];
    YTMOfflinePlayerManager *manager = [YTMOfflinePlayerManager sharedManager];
    if (manager.duration > 0) {
        NSTimeInterval remaining = manager.duration - self.timeSlider.value;
        self.remainingTimeLabel.text = [NSString stringWithFormat:@"-%@", [self formatTime:remaining]];
    }
}

@end
