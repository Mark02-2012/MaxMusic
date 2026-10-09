#import <UIKit/UIKit.h>

@interface YTMOfflineMiniPlayerView : UIView

@property (nonatomic, copy) void (^onTapExpandBlock)(void);

- (void)updateState;

@end
