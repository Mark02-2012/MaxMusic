#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import "FFMpegDownloader.h"
#import "Utils/YTMDownloadMetadata.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

@interface UIView (YTMAncestor)
- (UIViewController *)_viewControllerForAncestor;
@end

static __weak id gActivePlayerResponse = nil;
static __weak id gActivePlayerVC = nil;

%hook YTPlayerViewController
- (void)setPlayerResponse:(id)response {
    gActivePlayerResponse = response;
    gActivePlayerVC = self;
    %orig;
}
%end

%hook YTMWatchViewController
- (void)setPlayerResponse:(id)response {
    gActivePlayerResponse = response;
    %orig;
}
- (void)setPlayerViewController:(id)playerVC {
    gActivePlayerVC = playerVC;
    %orig;
}
%end

static id callObjectSelector(id target, SEL sel) {
    if (!target || !sel || ![target respondsToSelector:sel]) return nil;
    IMP imp = [target methodForSelector:sel];
    id (*func)(id, SEL) = (id (*)(id, SEL))imp;
    return func(target, sel);
}

static id findPlayerResponseInObject(id obj, NSMutableSet *visited) {
    if (!obj || [visited containsObject:obj]) return nil;
    [visited addObject:obj];
    
    for (NSString *selName in @[@"playerResponse", @"activePlayerResponse", @"playerData"]) {
        SEL sel = NSSelectorFromString(selName);
        if ([obj respondsToSelector:sel]) {
            id res = callObjectSelector(obj, sel);
            if (res) return res;
        }
    }
    
    for (NSString *ivarName in @[@"_playerResponse", @"_playerData", @"_activePlayerResponse", @"_playerViewController"]) {
        if (class_getInstanceVariable([obj class], [ivarName UTF8String]) != NULL) {
            id res = [obj valueForKey:ivarName];
            if (res) {
                id found = findPlayerResponseInObject(res, visited);
                if (found) return found;
            }
        }
    }
    
    if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)obj;
        if (vc.parentViewController) {
            id found = findPlayerResponseInObject(vc.parentViewController, visited);
            if (found) return found;
        }
        if (vc.presentedViewController) {
            id found = findPlayerResponseInObject(vc.presentedViewController, visited);
            if (found) return found;
        }
        for (UIViewController *child in vc.childViewControllers) {
            id found = findPlayerResponseInObject(child, visited);
            if (found) return found;
        }
    }
    
    if ([obj isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)obj;
        if ([v respondsToSelector:@selector(_viewControllerForAncestor)]) {
            id ancestor = [v _viewControllerForAncestor];
            if (ancestor) {
                id found = findPlayerResponseInObject(ancestor, visited);
                if (found) return found;
            }
        }
        if (v.nextResponder) {
            id found = findPlayerResponseInObject(v.nextResponder, visited);
            if (found) return found;
        }
        for (UIView *sub in v.subviews) {
            id found = findPlayerResponseInObject(sub, visited);
            if (found) return found;
        }
    }
    
    return nil;
}

static YTPlayerResponse *findActivePlayerResponse(UIView *sourceView) {
    if (gActivePlayerResponse) {
        return (YTPlayerResponse *)gActivePlayerResponse;
    }
    
    NSMutableSet *visited = [NSMutableSet set];
    if (sourceView) {
        id resp = findPlayerResponseInObject(sourceView, visited);
        if (resp) return (YTPlayerResponse *)resp;
    }
    
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (window && window.rootViewController) {
        id resp = findPlayerResponseInObject(window.rootViewController, visited);
        if (resp) return (YTPlayerResponse *)resp;
    }
    
    return nil;
}

static NSString *getContentVideoIDFromHierarchy(UIView *sourceView) {
    if (gActivePlayerVC) {
        for (NSString *selName in @[@"contentVideoID", @"currentVideoID", @"videoId"]) {
            SEL sel = NSSelectorFromString(selName);
            id res = callObjectSelector(gActivePlayerVC, sel);
            if ([res isKindOfClass:[NSString class]] && [(NSString *)res length] > 0) {
                return (NSString *)res;
            }
        }
    }
    
    id playerResp = findActivePlayerResponse(sourceView);
    if (playerResp) {
        id playerData = [playerResp respondsToSelector:@selector(playerData)] ? callObjectSelector(playerResp, @selector(playerData)) : playerResp;
        id videoDetails = callObjectSelector(playerData, NSSelectorFromString(@"videoDetails"));
        if (videoDetails && [videoDetails respondsToSelector:NSSelectorFromString(@"videoId")]) {
            NSString *vId = callObjectSelector(videoDetails, NSSelectorFromString(@"videoId"));
            if ([vId isKindOfClass:[NSString class]] && vId.length > 0) return vId;
        }
    }
    
    return nil;
}

static CGFloat getTotalMediaTimeFromHierarchy(UIView *sourceView) {
    if (gActivePlayerVC && [gActivePlayerVC respondsToSelector:NSSelectorFromString(@"currentVideoTotalMediaTime")]) {
        SEL sel = NSSelectorFromString(@"currentVideoTotalMediaTime");
        IMP imp = [gActivePlayerVC methodForSelector:sel];
        CGFloat (*func)(id, SEL) = (CGFloat (*)(id, SEL))imp;
        return func(gActivePlayerVC, sel);
    }
    return 0;
}

static NSString *sanitizeFileNameString(NSString *input) {
    if (!input) return @"";
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|"];
    NSString *clean = [[input componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@""];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return clean.length > 0 ? clean : @"Track";
}

static NSString *generateSAPISIDHASH(NSString *sapisid, NSString *origin) {
    if (!sapisid || sapisid.length == 0) return nil;
    
    NSTimeInterval timeStamp = [[NSDate date] timeIntervalSince1970];
    NSString *timestampStr = [NSString stringWithFormat:@"%lld", (long long)timeStamp];
    
    NSString *inputStr = [NSString stringWithFormat:@"%@ %@ %@", timestampStr, sapisid, origin];
    
    const char *cstr = [inputStr UTF8String];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(cstr, (CC_LONG)strlen(cstr), digest);
    
    NSMutableString *sha1Str = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [sha1Str appendFormat:@"%02x", digest[i]];
    }
    
    return [NSString stringWithFormat:@"SAPISIDHASH %@_%@", timestampStr, sha1Str];
}

static NSDictionary *fetchPlayerResponseForVideoId(NSString *videoId) {
    if (!videoId || videoId.length == 0) return nil;
    
    NSArray *clients = @[
        @{@"clientName": @"ANDROID", @"clientVersion": @"19.05.36", @"androidSdkVersion": @30},
        @{@"clientName": @"IOS", @"clientVersion": @"19.05.36", @"osVersion": @"16.5"},
        @{@"clientName": @"WEB_REMIX", @"clientVersion": @"1.20231214.00.00"}
    ];
    
    NSString *sapisid = nil;
    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        if ([cookie.name isEqualToString:@"SAPISID"]) {
            sapisid = cookie.value;
            break;
        }
    }
    
    NSString *origin = @"https://music.youtube.com";
    NSString *authHeader = generateSAPISIDHASH(sapisid, origin);
    
    for (NSDictionary *clientInfo in clients) {
        NSURL *url = [NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player"];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:origin forHTTPHeaderField:@"Origin"];
        [request setValue:origin forHTTPHeaderField:@"X-Origin"];
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
        
        if (authHeader) {
            [request setValue:authHeader forHTTPHeaderField:@"Authorization"];
        }
        
        NSDictionary *bodyDict = @{
            @"context": @{
                @"client": clientInfo
            },
            @"videoId": videoId
        };
        
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
        request.HTTPBody = bodyData;
        
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSDictionary *resultDict = nil;
        
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]] && json[@"streamingData"]) {
                    resultDict = json;
                }
            }
            dispatch_semaphore_signal(sema);
        }];
        [task resume];
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)));
        
        if (resultDict) return resultDict;
    }
    
    return nil;
}

static NSString *extractURLFromFormatDict(NSDictionary *fmt) {
    if (![fmt isKindOfClass:[NSDictionary class]]) return nil;
    
    NSString *url = fmt[@"url"];
    if ([url isKindOfClass:[NSString class]] && url.length > 0) return url;
    
    NSString *cipher = fmt[@"signatureCipher"] ?: fmt[@"cipher"];
    if ([cipher isKindOfClass:[NSString class]] && cipher.length > 0) {
        NSArray *components = [cipher componentsSeparatedByString:@"&"];
        for (NSString *comp in components) {
            if ([comp hasPrefix:@"url="]) {
                NSString *encodedURL = [comp substringFromIndex:4];
                NSString *decodedURL = [encodedURL stringByRemovingPercentEncoding];
                if (decodedURL.length > 0) return decodedURL;
            }
        }
    }
    
    return nil;
}

static NSString *extractAudioURLFromPlayerResponse(NSDictionary *json) {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    
    NSDictionary *streamingData = json[@"streamingData"];
    if (![streamingData isKindOfClass:[NSDictionary class]]) return nil;
    
    NSString *hls = streamingData[@"hlsManifestURL"];
    if ([hls isKindOfClass:[NSString class]] && hls.length > 0) {
        return hls;
    }
    
    NSArray *adaptiveFormats = streamingData[@"adaptiveFormats"];
    if ([adaptiveFormats isKindOfClass:[NSArray class]]) {
        NSString *bestAACURL = nil;
        NSInteger highestAACBitrate = 0;
        
        NSString *bestAnyAudioURL = nil;
        NSInteger highestAnyBitrate = 0;
        
        for (NSDictionary *fmt in adaptiveFormats) {
            if (![fmt isKindOfClass:[NSDictionary class]]) continue;
            NSString *mime = fmt[@"mimeType"];
            NSString *urlStr = extractURLFromFormatDict(fmt);
            
            if ([mime isKindOfClass:[NSString class]] && [mime containsString:@"audio/"] && [urlStr isKindOfClass:[NSString class]] && urlStr.length > 0) {
                NSInteger bitrate = [fmt[@"bitrate"] integerValue];
                
                if (bitrate > highestAnyBitrate || !bestAnyAudioURL) {
                    highestAnyBitrate = bitrate;
                    bestAnyAudioURL = urlStr;
                }
                
                if ([mime containsString:@"mp4"] || [mime containsString:@"m4a"] || [mime containsString:@"aac"]) {
                    if (bitrate > highestAACBitrate || !bestAACURL) {
                        highestAACBitrate = bitrate;
                        bestAACURL = urlStr;
                    }
                }
            }
        }
        
        if (bestAACURL) return bestAACURL;
        if (bestAnyAudioURL) return bestAnyAudioURL;
    }
    
    NSArray *formats = streamingData[@"formats"];
    if ([formats isKindOfClass:[NSArray class]]) {
        for (NSDictionary *fmt in formats) {
            if (![fmt isKindOfClass:[NSDictionary class]]) continue;
            NSString *urlStr = extractURLFromFormatDict(fmt);
            if ([urlStr isKindOfClass:[NSString class]] && urlStr.length > 0) {
                return urlStr;
            }
        }
    }
    
    return nil;
}

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(id)sourceView;
- (void)downloadAudioInternal:(id)sourceView completion:(void (^)(void))completion;
- (void)downloadTrackWithVideoId:(NSString *)videoId title:(NSString *)suggestedTitle playlistName:(NSString *)playlistName completion:(void (^)(BOOL, NSString *))completion;
- (void)downloadCoverImage:(id)sourceView;
- (void)downloadPlaylistTracks:(id)sourceView;
- (NSString *)getURLFromManifest:(NSURL *)manifest;
@end

static NSString *getPlaylistTitleFromHierarchy(UIView *sourceView) {
    UIViewController *topVC = [sourceView respondsToSelector:@selector(_viewControllerForAncestor)] ? [sourceView _viewControllerForAncestor] : nil;
    if (!topVC) {
        topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
    }
    
    if ([topVC respondsToSelector:@selector(title)] && topVC.title.length > 0) {
        return topVC.title;
    }
    
    NSMutableArray *queue = [NSMutableArray arrayWithObject:topVC.view ?: sourceView];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)v;
            if (lbl.text.length > 0 && lbl.font.pointSize >= 18) {
                return lbl.text;
            }
        }
        for (UIView *sub in v.subviews) {
            [queue addObject:sub];
        }
    }
    return @"Downloaded Playlist";
}

static void extractVideoIdAndTitleFromObject(id obj, NSString **outVideoId, NSString **outTitle) {
    if (!obj) return;
    
    NSString *vId = nil;
    NSString *tTitle = nil;
    
    if ([obj respondsToSelector:NSSelectorFromString(@"playlistItemData")]) {
        id itemData = callObjectSelector(obj, NSSelectorFromString(@"playlistItemData"));
        if (itemData && [itemData respondsToSelector:NSSelectorFromString(@"videoId")]) {
            id v = callObjectSelector(itemData, NSSelectorFromString(@"videoId"));
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) vId = v;
        }
    }
    
    if (!vId && [obj respondsToSelector:NSSelectorFromString(@"videoId")]) {
        id v = callObjectSelector(obj, NSSelectorFromString(@"videoId"));
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) vId = v;
    }
    
    for (NSString *epKey in @[@"watchEndpoint", @"navigationEndpoint", @"endpoint", @"command", @"serviceEndpoint", @"playNavigationEndpoint"]) {
        if (!vId && [obj respondsToSelector:NSSelectorFromString(epKey)]) {
            id ep = callObjectSelector(obj, NSSelectorFromString(epKey));
            if (ep) {
                if ([ep respondsToSelector:NSSelectorFromString(@"videoId")]) {
                    id v = callObjectSelector(ep, NSSelectorFromString(@"videoId"));
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) vId = v;
                }
                if (!vId && [ep respondsToSelector:NSSelectorFromString(@"watchEndpoint")]) {
                    id wep = callObjectSelector(ep, NSSelectorFromString(@"watchEndpoint"));
                    if (wep && [wep respondsToSelector:NSSelectorFromString(@"videoId")]) {
                        id v = callObjectSelector(wep, NSSelectorFromString(@"videoId"));
                        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) vId = v;
                    }
                }
            }
        }
    }
    
    if (!vId && [obj respondsToSelector:NSSelectorFromString(@"flexColumns")]) {
        id cols = callObjectSelector(obj, NSSelectorFromString(@"flexColumns"));
        if ([cols isKindOfClass:[NSArray class]]) {
            for (id col in cols) {
                extractVideoIdAndTitleFromObject(col, &vId, &tTitle);
                if (vId) break;
            }
        }
    }
    
    for (NSString *renKey in @[@"playlistPanelVideoRenderer", @"musicResponsiveListItemRenderer", @"musicTwoRowItemRenderer", @"compactVideoRenderer", @"musicResponsiveListItemFlexColumnRenderer"]) {
        if (!vId && [obj respondsToSelector:NSSelectorFromString(renKey)]) {
            id ren = callObjectSelector(obj, NSSelectorFromString(renKey));
            if (ren) {
                extractVideoIdAndTitleFromObject(ren, &vId, &tTitle);
            }
        }
    }
    
    if (vId) {
        if ([obj respondsToSelector:NSSelectorFromString(@"title")]) {
            id tObj = callObjectSelector(obj, NSSelectorFromString(@"title"));
            if ([tObj isKindOfClass:[NSString class]]) {
                tTitle = tObj;
            } else if (tObj) {
                if ([tObj respondsToSelector:NSSelectorFromString(@"runs")]) {
                    NSArray *runs = callObjectSelector(tObj, NSSelectorFromString(@"runs"));
                    if ([runs isKindOfClass:[NSArray class]] && runs.count > 0) {
                        id firstRun = runs.firstObject;
                        if ([firstRun respondsToSelector:NSSelectorFromString(@"text")]) {
                            id txt = callObjectSelector(firstRun, NSSelectorFromString(@"text"));
                            if ([txt isKindOfClass:[NSString class]]) tTitle = txt;
                        }
                    }
                } else if ([tObj respondsToSelector:NSSelectorFromString(@"simpleText")]) {
                    id txt = callObjectSelector(tObj, NSSelectorFromString(@"simpleText"));
                    if ([txt isKindOfClass:[NSString class]]) tTitle = txt;
                }
            }
        }
        
        *outVideoId = vId;
        if (tTitle && !*outTitle) *outTitle = tTitle;
    }
}

static void scanObjectForTracks(id obj, NSMutableArray *tracks, NSMutableSet *visited) {
    if (!obj) return;
    NSValue *ptrVal = [NSValue valueWithNonretainedObject:obj];
    if ([visited containsObject:ptrVal]) return;
    [visited addObject:ptrVal];
    
    if (visited.count > 3000) return;
    
    if (gActivePlayerVC && (obj == gActivePlayerVC || ([obj isKindOfClass:[UIView class]] && [(UIView *)obj isDescendantOfView:((UIViewController *)gActivePlayerVC).view]))) {
        return;
    }
    
    NSString *clsName = NSStringFromClass([obj class]);
    if ([clsName containsString:@"Carousel"] || [clsName containsString:@"Recom"] || [clsName containsString:@"WatchNext"] || [clsName containsString:@"WatchPanel"]) return;
    
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            scanObjectForTracks(item, tracks, visited);
        }
        return;
    }
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        for (id val in [(NSDictionary *)obj allValues]) {
            scanObjectForTracks(val, tracks, visited);
        }
        return;
    }
    
    NSString *vId = nil;
    NSString *tTitle = nil;
    extractVideoIdAndTitleFromObject(obj, &vId, &tTitle);
    if (vId && vId.length > 0) {
        BOOL exists = NO;
        for (NSDictionary *d in tracks) {
            if ([d[@"videoId"] isEqualToString:vId]) {
                exists = YES;
                break;
            }
        }
        if (!exists) {
            [tracks addObject:@{
                @"videoId": vId,
                @"title": tTitle ?: @"Track"
            }];
        }
        return;
    }
    
    if ([obj isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)obj;
        id ds = cv.dataSource;
        if (ds && ds != cv) scanObjectForTracks(ds, tracks, visited);
    } else if ([obj isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)obj;
        id ds = tv.dataSource;
        if (ds && ds != tv) scanObjectForTracks(ds, tracks, visited);
    }
    
    NSArray *selNames = @[
        @"contents", @"items", @"sections", @"renderers", @"model", @"entry",
        @"renderer", @"playlistPanel", @"watchNextResponse", @"sectionListRenderer",
        @"playlistPanelRenderer", @"singleColumnWatchNextResults", @"results",
        @"playlist", @"playlistVideoListRenderer", @"playlistPanelVideoRenderer",
        @"musicResponsiveListItemRenderer", @"content", @"response", @"browseResponse",
        @"singleColumnBrowseResultsRenderer", @"tabs", @"tabRenderer", @"playlistItemData",
        @"navigationEndpoint", @"watchEndpoint", @"menu", @"menuRenderer", @"flexColumns",
        @"musicResponsiveListItemFlexColumnRenderer", @"text", @"runs", @"overlay",
        @"musicItemThumbnailOverlayRenderer", @"playNavigationEndpoint", @"compactVideoRenderer"
    ];
    for (NSString *selName in selNames) {
        SEL sel = NSSelectorFromString(selName);
        if ([obj respondsToSelector:sel]) {
            id child = callObjectSelector(obj, sel);
            if (child) scanObjectForTracks(child, tracks, visited);
        }
    }
    
    if ([obj isKindOfClass:[UIView class]]) {
        UIView *v = (UIView *)obj;
        if (class_getInstanceVariable([v class], "_controller") != NULL) {
            id controller = [v valueForKey:@"_controller"];
            if (controller) scanObjectForTracks(controller, tracks, visited);
        }
        for (UIView *sub in v.subviews) {
            scanObjectForTracks(sub, tracks, visited);
        }
    } else if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)obj;
        if (gActivePlayerVC && vc == gActivePlayerVC) return;
        
        if (vc.view) scanObjectForTracks(vc.view, tracks, visited);
        for (UIViewController *child in vc.childViewControllers) {
            if (gActivePlayerVC && child == gActivePlayerVC) continue;
            scanObjectForTracks(child, tracks, visited);
        }
        if (vc.presentedViewController) scanObjectForTracks(vc.presentedViewController, tracks, visited);
    }
}

static NSString *extractPlaylistIdFromHierarchy(UIView *sourceView) {
    UIViewController *vc = nil;
    if (sourceView && [sourceView respondsToSelector:@selector(_viewControllerForAncestor)]) {
        vc = [sourceView _viewControllerForAncestor];
    }
    
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableArray *queue = [NSMutableArray array];
    
    if (vc) [queue addObject:vc];
    
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    UIViewController *root = window.rootViewController;
    if (root) {
        UIViewController *top = root;
        while (top.presentedViewController) {
            top = top.presentedViewController;
        }
        if (top && ![queue containsObject:top]) [queue addObject:top];
        if (root && ![queue containsObject:root]) [queue addObject:root];
    }
    
    while (queue.count > 0) {
        id obj = queue.firstObject;
        [queue removeObjectAtIndex:0];
        
        if (!obj || [visited containsObject:[NSValue valueWithNonretainedObject:obj]]) continue;
        [visited addObject:[NSValue valueWithNonretainedObject:obj]];
        if (visited.count > 200) break;
        
        for (NSString *selName in @[@"playlistId", @"browseId"]) {
            if ([obj respondsToSelector:NSSelectorFromString(selName)]) {
                NSString *pid = callObjectSelector(obj, NSSelectorFromString(selName));
                if ([pid isKindOfClass:[NSString class]] && pid.length > 0) {
                    if ([pid hasPrefix:@"VL"] || [pid hasPrefix:@"PL"] || [pid hasPrefix:@"OL"] || [pid hasPrefix:@"RD"] || [pid hasPrefix:@"UU"]) {
                        return pid;
                    }
                }
            }
        }
        
        for (NSString *selName in @[@"browseEndpoint", @"endpoint", @"navigationEndpoint", @"command"]) {
            if ([obj respondsToSelector:NSSelectorFromString(selName)]) {
                id ep = callObjectSelector(obj, NSSelectorFromString(selName));
                if (ep) [queue addObject:ep];
            }
        }
        
        if ([obj isKindOfClass:[UIViewController class]]) {
            UIViewController *vcObj = (UIViewController *)obj;
            if (gActivePlayerVC && vcObj == gActivePlayerVC) continue;
            for (UIViewController *child in vcObj.childViewControllers) {
                if (gActivePlayerVC && child == gActivePlayerVC) continue;
                [queue addObject:child];
            }
            if (vcObj.parentViewController) [queue addObject:vcObj.parentViewController];
            if (vcObj.presentingViewController) [queue addObject:vcObj.presentingViewController];
        }
    }
    
    return nil;
}

static void extractTracksFromJSONObject(id obj, NSMutableArray *tracks);

static void extractTracksFromJSONObject(id obj, NSMutableArray *tracks) {
    if (!obj) return;
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        
        // Check for musicResponsiveListItemRenderer which contains playlist tracks
        NSDictionary *renderer = dict[@"musicResponsiveListItemRenderer"];
        if ([renderer isKindOfClass:[NSDictionary class]]) {
            NSString *videoId = nil;
            NSString *title = nil;
            
            // Extract videoId from playlistItemData
            NSDictionary *playlistItemData = renderer[@"playlistItemData"];
            if ([playlistItemData isKindOfClass:[NSDictionary class]]) {
                NSString *vid = playlistItemData[@"videoId"];
                if ([vid isKindOfClass:[NSString class]] && vid.length > 0) {
                    videoId = vid;
                }
            }
            
            // Extract videoId from overlay -> musicItemThumbnailOverlayRenderer -> content -> musicPlayButtonRenderer -> playNavigationEndpoint -> watchEndpoint
            if (!videoId) {
                NSDictionary *overlay = renderer[@"overlay"];
                if ([overlay isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *thumbOverlay = overlay[@"musicItemThumbnailOverlayRenderer"];
                    if ([thumbOverlay isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *content = thumbOverlay[@"content"];
                        if ([content isKindOfClass:[NSDictionary class]]) {
                            NSDictionary *playBtn = content[@"musicPlayButtonRenderer"];
                            if ([playBtn isKindOfClass:[NSDictionary class]]) {
                                NSDictionary *playNav = playBtn[@"playNavigationEndpoint"];
                                if ([playNav isKindOfClass:[NSDictionary class]]) {
                                    NSDictionary *watchEp = playNav[@"watchEndpoint"];
                                    if ([watchEp isKindOfClass:[NSDictionary class]]) {
                                        NSString *vid = watchEp[@"videoId"];
                                        if ([vid isKindOfClass:[NSString class]] && vid.length > 0) {
                                            videoId = vid;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Extract title from flexColumns[0]
            NSArray *flexColumns = renderer[@"flexColumns"];
            if ([flexColumns isKindOfClass:[NSArray class]] && flexColumns.count > 0) {
                NSDictionary *firstCol = flexColumns[0];
                if ([firstCol isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *flexColRenderer = firstCol[@"musicResponsiveListItemFlexColumnRenderer"];
                    if ([flexColRenderer isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *text = flexColRenderer[@"text"];
                        if ([text isKindOfClass:[NSDictionary class]]) {
                            NSArray *runs = text[@"runs"];
                            if ([runs isKindOfClass:[NSArray class]] && runs.count > 0) {
                                NSDictionary *firstRun = runs[0];
                                if ([firstRun isKindOfClass:[NSDictionary class]]) {
                                    NSString *txt = firstRun[@"text"];
                                    if ([txt isKindOfClass:[NSString class]] && txt.length > 0) {
                                        title = txt;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            if (videoId) {
                BOOL exists = NO;
                for (NSDictionary *d in tracks) {
                    if ([d[@"videoId"] isEqualToString:videoId]) {
                        exists = YES;
                        break;
                    }
                }
                if (!exists) {
                    [tracks addObject:@{
                        @"videoId": videoId,
                        @"title": title ?: @"Track"
                    }];
                }
            }
            return;
        }
        
        // Check for playlistPanelVideoRenderer (another format)
        NSDictionary *panelRenderer = dict[@"playlistPanelVideoRenderer"];
        if ([panelRenderer isKindOfClass:[NSDictionary class]]) {
            NSString *videoId = panelRenderer[@"videoId"];
            NSString *title = nil;
            NSDictionary *titleObj = panelRenderer[@"title"];
            if ([titleObj isKindOfClass:[NSDictionary class]]) {
                NSArray *runs = titleObj[@"runs"];
                if ([runs isKindOfClass:[NSArray class]] && runs.count > 0) {
                    title = runs[0][@"text"];
                }
                if (!title) {
                    title = titleObj[@"simpleText"];
                }
            }
            if ([videoId isKindOfClass:[NSString class]] && videoId.length > 0) {
                BOOL exists = NO;
                for (NSDictionary *d in tracks) {
                    if ([d[@"videoId"] isEqualToString:videoId]) {
                        exists = YES;
                        break;
                    }
                }
                if (!exists) {
                    [tracks addObject:@{
                        @"videoId": videoId,
                        @"title": title ?: @"Track"
                    }];
                }
            }
            return;
        }
        
        // Recurse into all values
        for (id val in dict.allValues) {
            extractTracksFromJSONObject(val, tracks);
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            extractTracksFromJSONObject(item, tracks);
        }
    }
}

static NSArray<NSDictionary *> *extractPlaylistTracks(UIView *sourceView) {
    NSString *playlistId = extractPlaylistIdFromHierarchy(sourceView);
    
    if (playlistId && playlistId.length > 0) {
        NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
        
        // Call InnerTube browse API
        NSString *browseId = playlistId;
        if ([browseId hasPrefix:@"PL"] && ![browseId hasPrefix:@"VL"]) {
            browseId = [NSString stringWithFormat:@"VL%@", browseId];
        }
        
        NSURL *url = [NSURL URLWithString:@"https://music.youtube.com/youtubei/v1/browse"];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"https://music.youtube.com" forHTTPHeaderField:@"Origin"];
        [request setValue:@"https://music.youtube.com" forHTTPHeaderField:@"Referer"];
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
        
        NSDictionary *bodyDict = @{
            @"context": @{
                @"client": @{
                    @"clientName": @"WEB_REMIX",
                    @"clientVersion": @"1.20231214.00.00",
                    @"hl": @"en",
                    @"gl": @"US"
                }
            },
            @"browseId": browseId
        };
        
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
        request.HTTPBody = bodyData;
        
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSData *responseData = nil;
        
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data) {
                responseData = data;
            }
            dispatch_semaphore_signal(sema);
        }];
        [task resume];
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)));
        
        if (responseData) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                extractTracksFromJSONObject(json, tracks);
            }
        }
        
        if (tracks.count > 0) return tracks;
    }
    
    // Fallback to UI scanning if API fails
    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    if (sourceView) {
        scanObjectForTracks(sourceView, tracks, visited);
    }
    return tracks;
}

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {

    if (class_getInstanceVariable([self class], "_controller") == NULL) {
        return %orig;
    }

    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) {
        return %orig;
    }

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    BOOL isDownloadNode = NO;
    if (node && node.key) {
        NSString *k = [node.key lowercaseString];
        if ([k containsString:@"download"] || [k containsString:@"offline"] || [k containsString:@"save"]) {
            isDownloadNode = YES;
        }
    }
    if (!isDownloadNode) {
        for (NSString *selName in @[@"offlinePlaylistEndpoint", @"offlineEndpoint", @"downloadCommand"]) {
            if ([self respondsToSelector:NSSelectorFromString(selName)] || (node && [node respondsToSelector:NSSelectorFromString(selName)])) {
                isDownloadNode = YES;
                break;
            }
        }
    }
    
    if (!isDownloadNode) {
        return %orig;
    }

    UIView *tapView = tapRecognizer.view;
    UIViewController *presentingVC = [tapView respondsToSelector:@selector(_viewControllerForAncestor)] ? [tapView _viewControllerForAncestor] : nil;
    if (!presentingVC) {
        presentingVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    }

    BOOL isPlaylistDownload = NO;
    if (node && node.key) {
        NSString *k = [node.key lowercaseString];
        if ([k containsString:@"playlist"] || [k containsString:@"header"] || [k containsString:@"browse"] || [k containsString:@"shelf"]) {
            isPlaylistDownload = YES;
        }
    }
    if (!isPlaylistDownload && presentingVC) {
        NSString *vcCls = NSStringFromClass([presentingVC class]);
        if ([vcCls containsString:@"Browse"] || [vcCls containsString:@"Playlist"] || [vcCls containsString:@"Section"]) {
            isPlaylistDownload = YES;
        }
    }
    
    if (isPlaylistDownload) {
        [self downloadPlaylistTracks:(id)tapView];
        return;
    }

    YTPlayerResponse *playerResponse = findActivePlayerResponse(tapView);

    if (playerResponse) {
        YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
        sheetController.sourceView = tapView;
        [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:@"Download All Playlist Tracks" iconImage:[%c(YTUIResources) downloadOutline] style:0 handler:^ {
            [self downloadPlaylistTracks:(id)tapView];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
            [self downloadAudio:(id)tapView];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
            [self downloadCoverImage:(id)tapView];
        }]];

        [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
            return %orig;
        }]];

        if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
            [sheetController presentFromViewController:presentingVC animated:YES completion:nil];
        } else if (YTMU(@"downloadAudio")) {
            [self downloadAudio:(id)tapView];
        } else if (YTMU(@"downloadCoverImage")) {
            [self downloadCoverImage:(id)tapView];
        }
    } else {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = LOC(@"DONT_RUSH");
        alertView.subtitle = LOC(@"DONT_RUSH_DESC");
        [alertView show];
    }
}

%new
- (void)downloadPlaylistTracks:(UIView *)sourceView {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self downloadPlaylistTracks:sourceView];
        });
        return;
    }
    
    NSString *playlistName = getPlaylistTitleFromHierarchy(sourceView);
    
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.mode = MBProgressHUDModeIndeterminate;
    hud.label.text = @"Fetching playlist tracks...";
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSDictionary *> *tracks = extractPlaylistTracks(sourceView);
        
        if (tracks.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [hud hideAnimated:YES];
                hud.label.text = @"Downloading Track...";
                [self downloadAudio:sourceView];
            });
            return;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [YTMDownloadMetadata createPlaylistNamed:playlistName];
            hud.label.text = [NSString stringWithFormat:@"Downloading Playlist (%lu tracks)...", (unsigned long)tracks.count];
        });
        
        NSUInteger count = 0;
        __block NSUInteger successCount = 0;
        __block NSUInteger failCount = 0;
        __block NSString *lastError = nil;
        
        for (NSDictionary *dict in tracks) {
            count++;
            NSString *vId = dict[@"videoId"];
            NSString *tTitle = dict[@"title"];
            
            NSUInteger currentCount = count;
            dispatch_async(dispatch_get_main_queue(), ^{
                hud.label.text = [NSString stringWithFormat:@"Downloading (%lu/%lu): %@", (unsigned long)currentCount, (unsigned long)tracks.count, tTitle ?: @"Track"];
            });
            
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            [self downloadTrackWithVideoId:vId title:tTitle playlistName:playlistName completion:^(BOOL success, NSString *errorReason) {
                if (success) {
                    successCount++;
                } else {
                    failCount++;
                    lastError = errorReason;
                }
                dispatch_semaphore_signal(sema);
            }];
            dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [hud hideAnimated:YES];
            
            YTAlertView *alertView = [%c(YTAlertView) infoDialog];
            alertView.title = @"Playlist Download Complete";
            if (failCount == 0) {
                alertView.subtitle = [NSString stringWithFormat:@"Successfully downloaded %lu tracks to '%@'", (unsigned long)successCount, playlistName];
            } else {
                alertView.subtitle = [NSString stringWithFormat:@"Downloaded %lu tracks. %lu failed. Last error: %@", (unsigned long)successCount, (unsigned long)failCount, lastError ?: @"Unknown"];
            }
            [alertView show];
            
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadDataNotification" object:nil];
        });
    });
}

%new
- (void)downloadTrackWithVideoId:(NSString *)videoId title:(NSString *)suggestedTitle playlistName:(NSString *)playlistName completion:(void (^)(BOOL, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *json = fetchPlayerResponseForVideoId(videoId);
        
        NSString *audioURL = extractAudioURLFromPlayerResponse(json);
        
        NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
        NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
        [[NSFileManager defaultManager] createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
        
        if (!audioURL || audioURL.length == 0) {
            NSString *logMsg = [NSString stringWithFormat:@"Failed for video %@: audioURL is nil. JSON: %@\n", videoId, json];
            NSURL *logURL = [folderURL URLByAppendingPathComponent:@"error_log.txt"];
            [logMsg writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
            
            if (completion) completion(NO, @"Audio URL not found (possibly region blocked or requires signature)");
            return;
        }
        
        NSDictionary *videoDetails = json[@"videoDetails"];
        NSString *rawTitle = videoDetails[@"title"] ?: suggestedTitle ?: @"Downloaded Track";
        NSString *rawAuthor = videoDetails[@"author"] ?: @"YouTube Music";
        
        NSString *title = sanitizeFileNameString(rawTitle);
        NSString *author = sanitizeFileNameString(rawAuthor);
        
        NSString *thumbnailURLStr = nil;
        NSArray *thumbnails = videoDetails[@"thumbnail"][@"thumbnails"];
        if ([thumbnails isKindOfClass:[NSArray class]] && thumbnails.count > 0) {
            thumbnailURLStr = [thumbnails lastObject][@"url"];
        }
        
        NSString *mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
        NSString *fileName = [NSString stringWithFormat:@"%@.m4a", mediaName];
        
        NSURL *tempURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", videoId]];
        NSURL *outputURL = [folderURL URLByAppendingPathComponent:fileName];
        
        // Clean up any existing temp file
        [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
        
        // Handle HLS manifest URL
        NSString *downloadURL = audioURL;
        if ([audioURL containsString:@"m3u8"] || [audioURL containsString:@"manifest"]) {
            downloadURL = [self getURLFromManifest:[NSURL URLWithString:audioURL]];
        }
        
        if (!downloadURL || downloadURL.length == 0) {
            NSString *logMsg = [NSString stringWithFormat:@"Failed for video %@: Manifest returned nil URL.\n", videoId];
            NSURL *logURL = [folderURL URLByAppendingPathComponent:@"error_log.txt"];
            [logMsg writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
            if (completion) completion(NO, @"Invalid manifest URL");
            return;
        }
        
        // Run FFMpeg: try copy first, then re-encode
        NSArray *args1 = @[@"-i", downloadURL, @"-y", @"-c", @"copy", tempURL.path];
        int returnCode = [MobileFFmpeg executeWithArguments:args1];
        if (returnCode != RETURN_CODE_SUCCESS) {
            NSArray *args2 = @[@"-i", downloadURL, @"-y", @"-c:a", @"aac", @"-b:a", @"192k", tempURL.path];
            returnCode = [MobileFFmpeg executeWithArguments:args2];
        }
        
        BOOL success = NO;
        if (returnCode == RETURN_CODE_SUCCESS) {
            // Move temp to final destination
            [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
            NSError *moveError = nil;
            success = [[NSFileManager defaultManager] moveItemAtURL:tempURL toURL:outputURL error:&moveError];
            if (!success) {
                // Try copy as fallback
                NSError *copyError = nil;
                success = [[NSFileManager defaultManager] copyItemAtURL:tempURL toURL:outputURL error:&copyError];
                [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
            }
        } else {
            NSString *logMsg = [NSString stringWithFormat:@"Failed FFMpeg for video %@: rc=%d output=%@\n", videoId, returnCode, [MobileFFmpegConfig getLastCommandOutput]];
            NSURL *logURL = [folderURL URLByAppendingPathComponent:@"error_log.txt"];
            [logMsg writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
            
            [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
        }
        
        if (success) {
            // Save metadata
            [YTMDownloadMetadata saveMetadataForFileName:fileName videoId:videoId title:title author:author];
            
            // Add to playlist
            if (playlistName.length > 0) {
                [YTMDownloadMetadata addTrack:fileName toPlaylist:playlistName];
            }
            
            // Download cover image
            if (thumbnailURLStr.length > 0) {
                NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnailURLStr]];
                if (imageData) {
                    NSURL *coverURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", mediaName]];
                    [imageData writeToURL:coverURL atomically:YES];
                }
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadDataNotification" object:nil];
            });
            if (completion) completion(YES, nil);
        } else {
            if (completion) completion(NO, @"FFMpeg failed or file could not be saved");
        }
    });
}

%new
- (void)downloadAudio:(UIView *)sourceView {
    [self downloadAudioInternal:sourceView completion:nil];
}

%new
- (void)downloadAudioInternal:(UIView *)sourceView completion:(void (^)(void))completion {
    __block YTPlayerResponse *playerResponse = nil;
    __block NSString *title = @"Downloaded Track";
    __block NSString *author = @"YouTube Music";
    __block NSString *urlStr = nil;
    __block NSString *videoID = nil;
    __block CGFloat duration = 0;
    __block NSString *thumbnailURLStr = nil;

    void (^extractMetadataBlock)(void) = ^{
        playerResponse = findActivePlayerResponse(sourceView);
        if (!playerResponse) return;

        YTIPlayerResponse *playerData = nil;
        if ([playerResponse respondsToSelector:@selector(playerData)]) {
            playerData = callObjectSelector(playerResponse, @selector(playerData));
        } else {
            playerData = (id)playerResponse;
        }
        
        YTIVideoDetails *videoDetails = callObjectSelector(playerData, NSSelectorFromString(@"videoDetails"));
        YTIStreamingData *streamingData = callObjectSelector(playerData, NSSelectorFromString(@"streamingData"));
        
        NSString *rawTitle = [videoDetails respondsToSelector:@selector(title)] ? videoDetails.title : @"Downloaded Track";
        NSString *rawAuthor = [videoDetails respondsToSelector:@selector(author)] ? videoDetails.author : @"YouTube Music";
        
        title = [rawTitle stringByReplacingOccurrencesOfString:@"/" withString:@""];
        author = [rawAuthor stringByReplacingOccurrencesOfString:@"/" withString:@""];
        urlStr = [streamingData respondsToSelector:@selector(hlsManifestURL)] ? streamingData.hlsManifestURL : nil;
        videoID = getContentVideoIDFromHierarchy(sourceView);
        duration = getTotalMediaTimeFromHierarchy(sourceView);

        if ([videoDetails respondsToSelector:@selector(thumbnail)]) {
            YTIThumbnailDetails *thumbnailDetails = videoDetails.thumbnail;
            if ([thumbnailDetails respondsToSelector:@selector(thumbnailsArray)]) {
                NSMutableArray *thumbnailsArray = [thumbnailDetails performSelector:@selector(thumbnailsArray)];
                YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
                if (thumbnail && thumbnail.URL) {
                    thumbnailURLStr = thumbnail.URL;
                }
            }
        }
    };

    if ([NSThread isMainThread]) {
        extractMetadataBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), extractMetadataBlock);
    }

    if (!playerResponse) {
        if (completion) completion();
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
        ffmpeg.tempName = videoID;
        ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author, title];
        ffmpeg.videoId = videoID;
        ffmpeg.trackTitle = title;
        ffmpeg.trackAuthor = author;
        ffmpeg.duration = round(duration);

        NSString *extractedURL = [self getURLFromManifest:[NSURL URLWithString:urlStr]];
        
        if (extractedURL.length > 0) {
            [ffmpeg downloadAudio:extractedURL];

            if (thumbnailURLStr.length > 0) {
                NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnailURLStr]];
                if (imageData) {
                    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
                    NSURL *coverURL = [documentsURL URLByAppendingPathComponent:[NSString stringWithFormat:@"YTMusicUltimate/%@ - %@.png", author, title]];
                    [imageData writeToURL:coverURL atomically:YES];
                }
            }
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                YTAlertView *alertView = [%c(YTAlertView) infoDialog];
                alertView.title = LOC(@"OOPS");
                alertView.subtitle = LOC(@"LINK_NOT_FOUND");
                [alertView show];
            });
        }
        
        if (completion) {
            completion();
        }
    });
}

%new
- (NSString *)getURLFromManifest:(NSURL *)manifest {
    NSData *manifestData = [NSData dataWithContentsOfURL:manifest];
    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];

    NSArray *groupIDS = @[@"234", @"233"]; // Our priority to find group id 234
    for (NSString *groupID in groupIDS) {
        for (NSString *line in manifestLines) {
            NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
            if ([line containsString:searchString]) {
                NSRange startRange = [line rangeOfString:@"https://"];
                NSRange endRange = [line rangeOfString:@"index.m3u8"];

                if (startRange.location != NSNotFound && endRange.location != NSNotFound) {
                    NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                    return [line substringWithRange:targetRange];
                }
            }
        }
    }

    return nil;
}

%new
- (void)downloadCoverImage:(UIView *)sourceView {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self downloadCoverImage:sourceView];
        });
        return;
    }
    
    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.mode = MBProgressHUDModeIndeterminate;

    YTPlayerResponse *playerResponse = findActivePlayerResponse(sourceView);
    if (!playerResponse) {
        [hud hideAnimated:YES];
        return;
    }

    YTIPlayerResponse *playerData = nil;
    if ([playerResponse respondsToSelector:@selector(playerData)]) {
        playerData = callObjectSelector(playerResponse, @selector(playerData));
    } else {
        playerData = (id)playerResponse;
    }
    
    YTIVideoDetails *videoDetails = callObjectSelector(playerData, NSSelectorFromString(@"videoDetails"));

    NSString *thumbnailURL = nil;
    if ([videoDetails respondsToSelector:@selector(thumbnail)]) {
        YTIThumbnailDetails *thumbnailDetails = videoDetails.thumbnail;
        if ([thumbnailDetails respondsToSelector:@selector(thumbnailsArray)]) {
            NSMutableArray *thumbnailsArray = [thumbnailDetails performSelector:@selector(thumbnailsArray)];
            YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
            if (thumbnail && thumbnail.URL) {
                thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];
            }
        }
    }

    if (thumbnailURL.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
            [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];
            dispatch_async(dispatch_get_main_queue(), ^{
                [hud hideAnimated:YES];
            });
        });
    } else {
        [hud hideAnimated:YES];
    }
}
%end
