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
// Playlist ID from the most recent YTICommand watchEndpoint.
static NSString *gActivePlaylistId = nil;

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
- (void)downloadPlaylistTracks:(id)sourceView saveAsCustomOfflinePlaylist:(BOOL)saveAsCustomOfflinePlaylist;
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
    
    UIView *startingView = topVC.view ?: sourceView;
    NSMutableArray *queue = [NSMutableArray array];
    if (startingView) [queue addObject:startingView];
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

static BOOL isValidPlaylistBrowseID(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NO;
    NSString *upper = [value uppercaseString];
    return [upper hasPrefix:@"VL"] || [upper hasPrefix:@"VM"] ||
           [upper hasPrefix:@"PL"] || [upper hasPrefix:@"OL"] ||
           [upper hasPrefix:@"RD"] || [upper hasPrefix:@"UU"] ||
           [upper hasPrefix:@"FL"] || [upper hasPrefix:@"LL"];
}

static NSString *normalizePlaylistBrowseID(NSString *playlistId) {
    if (![playlistId isKindOfClass:[NSString class]]) return nil;
    NSString *clean = [playlistId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length == 0) return nil;

    NSString *upper = clean.uppercaseString;
    if ([upper hasPrefix:@"VL"] || [upper hasPrefix:@"VM"]) return clean;

    for (NSString *prefix in @[@"PL", @"OL", @"RD", @"UU", @"FL", @"LL"]) {
        if ([upper hasPrefix:prefix]) return [@"VL" stringByAppendingString:clean];
    }
    return clean;
}

static NSString *extractPlaylistIdFromObject(id obj, NSMutableSet *visited, NSUInteger depth) {
    if (!obj || depth > 12) return nil;

    if ([obj isKindOfClass:[NSString class]]) {
        NSString *candidate = [(NSString *)obj stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (isValidPlaylistBrowseID(candidate)) return candidate;
        NSURLComponents *components = [NSURLComponents componentsWithString:candidate];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"list"] && isValidPlaylistBrowseID(item.value)) return item.value;
        }
        return nil;
    }

    NSValue *ptrVal = [NSValue valueWithNonretainedObject:obj];
    if ([visited containsObject:ptrVal]) return nil;
    [visited addObject:ptrVal];
    if (visited.count > 4000) return nil;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;

        for (NSString *key in @[@"playlistId", @"playlistID", @"listId", @"browseId", @"browseID"]) {
            id value = dict[key];
            if ([value isKindOfClass:[NSString class]] && isValidPlaylistBrowseID(value)) {
                return value;
            }
        }

        for (NSString *key in @[@"browseEndpoint", @"navigationEndpoint", @"endpoint", @"command", @"serviceEndpoint", @"watchEndpoint"]) {
            NSString *found = extractPlaylistIdFromObject(dict[key], visited, depth + 1);
            if (found) return found;
        }

        for (id value in dict.allValues) {
            NSString *found = extractPlaylistIdFromObject(value, visited, depth + 1);
            if (found) return found;
        }
        return nil;
    }

    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            NSString *found = extractPlaylistIdFromObject(item, visited, depth + 1);
            if (found) return found;
        }
        return nil;
    }

    // Newer YouTube Music builds often keep the browse/playlist model in
    // private object ivars instead of exposing it through selectors. Inspect
    // object-valued ivars as a fallback so ELMNodeController can still lead
    // us to playlistId/browseId.
    Class cls = [obj class];
    NSUInteger ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    for (NSUInteger i = 0; i < ivarCount; i++) {
        Ivar ivar = ivars[i];
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') continue;

        id child = object_getIvar(obj, ivar);
        if (!child || child == obj) continue;

        NSString *found = extractPlaylistIdFromObject(child, visited, depth + 1);
        if (found) {
            free(ivars);
            return found;
        }
    }
    if (ivars) free(ivars);

    // Repeat for superclasses; ELM objects frequently inherit their payload
    // storage from a base controller/model class.
    Class superCls = class_getSuperclass(cls);
    while (superCls && superCls != [NSObject class]) {
        NSUInteger superCount = 0;
        Ivar *superIvars = class_copyIvarList(superCls, &superCount);
        for (NSUInteger i = 0; i < superCount; i++) {
            Ivar ivar = superIvars[i];
            const char *type = ivar_getTypeEncoding(ivar);
            if (!type || type[0] != '@') continue;

            id child = object_getIvar(obj, ivar);
            if (!child || child == obj) continue;

            NSString *found = extractPlaylistIdFromObject(child, visited, depth + 1);
            if (found) {
                if (superIvars) free(superIvars);
                return found;
            }
        }
        if (superIvars) free(superIvars);
        superCls = class_getSuperclass(superCls);
    }

    for (NSString *selName in @[
        @"playlistId", @"playlistID", @"listId", @"browseId", @"browseID", @"browseEndpoint", @"navigationEndpoint",
        @"endpoint", @"command", @"serviceEndpoint", @"watchEndpoint",
        @"node", @"data", @"model", @"content", @"renderer", @"playlist",
        @"response", @"browseResponse", @"sectionListRenderer", @"tabs", @"tabRenderer"
    ]) {
        SEL sel = NSSelectorFromString(selName);
        if (![obj respondsToSelector:sel]) continue;
        id child = callObjectSelector(obj, sel);
        NSString *found = extractPlaylistIdFromObject(child, visited, depth + 1);
        if (found) return found;
    }

    if ([obj isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)obj;
        // The active player can own the watch/playlist endpoint. Do not skip it.
        NSString *found = extractPlaylistIdFromObject(vc.view, visited, depth + 1);
        if (found) return found;

        for (UIViewController *child in vc.childViewControllers) {
            found = extractPlaylistIdFromObject(child, visited, depth + 1);
            if (found) return found;
        }

        if (vc.presentedViewController) {
            found = extractPlaylistIdFromObject(vc.presentedViewController, visited, depth + 1);
            if (found) return found;
        }

        if (vc.parentViewController) {
            found = extractPlaylistIdFromObject(vc.parentViewController, visited, depth + 1);
            if (found) return found;
        }
    } else if ([obj isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)obj;

        if (class_getInstanceVariable([view class], @"_controller") != NULL) {
            id controller = [view valueForKey:@"_controller"];
            NSString *found = extractPlaylistIdFromObject(controller, visited, depth + 1);
            if (found) return found;
        }

        if ([view respondsToSelector:@selector(_viewControllerForAncestor)]) {
            UIViewController *ancestorVC = [view _viewControllerForAncestor];
            NSString *found = extractPlaylistIdFromObject(ancestorVC, visited, depth + 1);
            if (found) return found;
        }

        if (view.superview) {
            NSString *found = extractPlaylistIdFromObject(view.superview, visited, depth + 1);
            if (found) return found;
        }
    }

    return nil;
}

// YTICommand carries the original YTIWatchEndpoint used to start a track.
// Its playlistId is the authoritative playlist context; PlayerResponse alone
// generally only contains video metadata and cannot identify the playlist.
%hook YTICommand
- (void)setWatchEndpoint:(id)watchEndpoint {
    %orig;

    NSString *playlistId = nil;
    if (watchEndpoint) {
        if ([watchEndpoint respondsToSelector:NSSelectorFromString(@"playlistId")]) {
            id value = callObjectSelector(watchEndpoint, NSSelectorFromString(@"playlistId"));
            if ([value isKindOfClass:[NSString class]]) playlistId = value;
        }

        if (!isValidPlaylistBrowseID(playlistId)) {
            NSMutableSet *commandVisited = [NSMutableSet set];
            playlistId = extractPlaylistIdFromObject(watchEndpoint, commandVisited, 0);
        }
    }

    gActivePlaylistId = isValidPlaylistBrowseID(playlistId) ? [playlistId copy] : nil;
    NSLog(@"[MaxMusic Playlist] WatchEndpoint updated; playlistID=%@",
          gActivePlaylistId ?: @"(none)");
}
%end

static NSString *findContinuationToken(id obj, NSMutableSet *visited, NSUInteger depth) {
    if (!obj || depth > 16) return nil;

    NSValue *ptrVal = [NSValue valueWithNonretainedObject:obj];
    if ([visited containsObject:ptrVal]) return nil;
    [visited addObject:ptrVal];
    if (visited.count > 5000) return nil;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;

        NSDictionary *continuationCommand = dict[@"continuationCommand"];
        if ([continuationCommand isKindOfClass:[NSDictionary class]]) {
            NSString *token = continuationCommand[@"token"];
            if ([token isKindOfClass:[NSString class]] && token.length > 0) return token;
        }

        id continuationEndpoint = dict[@"continuationEndpoint"];
        if (continuationEndpoint) {
            NSString *token = findContinuationToken(continuationEndpoint, visited, depth + 1);
            if (token) return token;
        }

        NSDictionary *nextContinuationData = dict[@"nextContinuationData"];
        if ([nextContinuationData isKindOfClass:[NSDictionary class]]) {
            NSString *token = nextContinuationData[@"continuation"];
            if ([token isKindOfClass:[NSString class]] && token.length > 0) return token;
        }

        for (id value in dict.allValues) {
            NSString *token = findContinuationToken(value, visited, depth + 1);
            if (token) return token;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            NSString *token = findContinuationToken(item, visited, depth + 1);
            if (token) return token;
        }
    }

    return nil;
}

static NSString *extractPlaylistIdFromHierarchy(UIView *sourceView) {
    // First inspect the tapped control and its actual controller hierarchy.
    NSMutableSet *viewVisited = [NSMutableSet set];
    NSString *playlistId = extractPlaylistIdFromObject(sourceView, viewVisited, 0);
    if (playlistId) return playlistId;

    UIViewController *vc = nil;
    if (sourceView && [sourceView respondsToSelector:@selector(_viewControllerForAncestor)]) {
        vc = [sourceView _viewControllerForAncestor];
    }

    if (vc) {
        NSMutableSet *controllerVisited = [NSMutableSet set];
        playlistId = extractPlaylistIdFromObject(vc, controllerVisited, 0);
        if (playlistId) return playlistId;
    }

    // The watch command is the reliable link between a track and the playlist
    // it was launched from. This also survives opening a download action sheet.
    if (isValidPlaylistBrowseID(gActivePlaylistId)) {
        return gActivePlaylistId;
    }

    // When the action originates from Now Playing, the playlist endpoint can
    // be retained by the active player controller rather than by the button.
    if (gActivePlayerVC) {
        NSMutableSet *playerVisited = [NSMutableSet set];
        playlistId = extractPlaylistIdFromObject(gActivePlayerVC, playerVisited, 0);
        if (playlistId) return playlistId;
    }

    // Some app versions keep the watch/playlist context on the response model.
    if (gActivePlayerResponse) {
        NSMutableSet *responseVisited = [NSMutableSet set];
        playlistId = extractPlaylistIdFromObject(gActivePlayerResponse, responseVisited, 0);
        if (playlistId) return playlistId;
    }

    // Deliberately do not scan the entire app window: that can select an
    // unrelated playlist from a recommendation shelf.
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
            
            // A playlist renderer may expose its track through navigationEndpoint.
            if (!videoId) {
                NSDictionary *navigationEndpoint = renderer[@"navigationEndpoint"];
                NSDictionary *watchEndpoint = navigationEndpoint[@"watchEndpoint"];
                NSString *endpointVideoId = watchEndpoint[@"videoId"];
                if ([endpointVideoId isKindOfClass:[NSString class]] && endpointVideoId.length > 0) {
                    videoId = endpointVideoId;
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
            } else {
                // Newer renderer variants can place the watch endpoint deeper
                // than playlistItemData/overlay. Search only this row's subtree.
                for (id nestedValue in renderer.allValues) {
                    extractTracksFromJSONObject(nestedValue, tracks);
                }
            }
            return;
        }

        // Classic YouTube playlist renderer (also returned by some mixed pages).
        NSDictionary *playlistVideoRenderer = dict[@"playlistVideoRenderer"];
        if ([playlistVideoRenderer isKindOfClass:[NSDictionary class]]) {
            NSString *videoId = playlistVideoRenderer[@"videoId"];
            NSDictionary *titleObject = playlistVideoRenderer[@"title"];
            NSString *title = titleObject[@"simpleText"];
            if (![title isKindOfClass:[NSString class]]) {
                NSArray *runs = titleObject[@"runs"];
                if ([runs isKindOfClass:[NSArray class]] && runs.count > 0) title = runs.firstObject[@"text"];
            }
            if ([videoId isKindOfClass:[NSString class]] && videoId.length > 0) {
                BOOL exists = NO;
                for (NSDictionary *d in tracks) {
                    if ([d[@"videoId"] isEqualToString:videoId]) { exists = YES; break; }
                }
                if (!exists) [tracks addObject:@{@"videoId": videoId, @"title": title ?: @"Track"}];
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

static void YTMUWritePlaylistDebugLog(NSString *message) {
    if (message.length == 0) return;
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
    [[NSFileManager defaultManager] createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *logURL = [folderURL URLByAppendingPathComponent:@"playlist_debug.log"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
    if (!handle) {
        [message writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static NSArray<NSDictionary *> *extractPlaylistTracks(NSString *playlistId) {
    NSMutableArray<NSDictionary *> *tracks = [NSMutableArray array];
    YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"--- Playlist fetch %@ ---", [NSDate date]]);
    YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Resolved playlist ID: %@", playlistId ?: @"(nil)"]);

    if (!isValidPlaylistBrowseID(playlistId)) {
        YTMUWritePlaylistDebugLog(@"Playlist fetch aborted: no valid playlist ID was resolved.");
        return tracks;
    }

    NSString *browseId = normalizePlaylistBrowseID(playlistId);
    if (browseId.length == 0) {
        YTMUWritePlaylistDebugLog(@"Playlist fetch aborted: browseId normalization returned an empty value.");
        return tracks;
    }
    YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Normalized browseId: %@", browseId]);

    NSURL *url = [NSURL URLWithString:@"https://music.youtube.com/youtubei/v1/browse?prettyPrint=false"];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 20.0;
    configuration.timeoutIntervalForResource = 30.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

    NSDictionary *context = @{@"client": @{
        @"clientName": @"WEB_REMIX",
        @"clientVersion": @"1.20260327.10.00",
        @"hl": @"en",
        @"gl": @"US"
    }};

    // Reuse the app's existing YouTube Music cookies. No API key is added.
    NSArray<NSHTTPCookie *> *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url];
    NSMutableArray<NSString *> *cookieParts = [NSMutableArray array];
    NSString *sapisid = nil;
    for (NSHTTPCookie *cookie in cookies) {
        if (cookie.name.length > 0 && cookie.value.length > 0) {
            [cookieParts addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
        }
        if (!sapisid && ([cookie.name isEqualToString:@"SAPISID"] ||
                         [cookie.name isEqualToString:@"__Secure-3PAPISID"] ||
                         [cookie.name isEqualToString:@"__Secure-1PAPISID"])) {
            sapisid = cookie.value;
        }
    }

    NSString *origin = @"https://music.youtube.com";
    NSString *authHeader = generateSAPISIDHASH(sapisid, origin);
    YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"YouTube cookies available: %@; SAPISID auth available: %@",
                              cookieParts.count ? @"yes" : @"no", authHeader.length ? @"yes" : @"no"]);

    NSString *continuation = nil;
    NSMutableSet *seenContinuations = [NSMutableSet set];
    NSUInteger page = 0;

    while (page < 100) {
        NSMutableDictionary *bodyDict = [@{@"context": context} mutableCopy];
        if (continuation.length > 0) bodyDict[@"continuation"] = continuation;
        else bodyDict[@"browseId"] = browseId;

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 20.0;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [request setValue:@"67" forHTTPHeaderField:@"X-Youtube-Client-Name"];
        [request setValue:@"1.20260327.10.00" forHTTPHeaderField:@"X-Youtube-Client-Version"];
        [request setValue:origin forHTTPHeaderField:@"Origin"];
        [request setValue:origin forHTTPHeaderField:@"X-Origin"];
        [request setValue:[origin stringByAppendingString:@"/"] forHTTPHeaderField:@"Referer"];
        [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
        if (cookieParts.count > 0) [request setValue:[cookieParts componentsJoinedByString:@"; "] forHTTPHeaderField:@"Cookie"];
        if (authHeader.length > 0) {
            [request setValue:authHeader forHTTPHeaderField:@"Authorization"];
            [request setValue:@"0" forHTTPHeaderField:@"X-Goog-AuthUser"];
        }
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];

        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSData *responseData = nil;
        __block NSError *requestError = nil;
        __block NSHTTPURLResponse *httpResponse = nil;
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            responseData = data;
            requestError = error;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) httpResponse = (NSHTTPURLResponse *)response;
            dispatch_semaphore_signal(sema);
        }];
        [task resume];

        if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC))) != 0) {
            [task cancel];
            YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Page %lu timed out", (unsigned long)(page + 1)]);
            break;
        }

        NSInteger statusCode = httpResponse.statusCode;
        if (requestError || responseData.length == 0 || (statusCode != 0 && (statusCode < 200 || statusCode >= 300))) {
            NSString *bodyPreview = responseData.length ? [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding] : @"(empty body)";
            if (bodyPreview.length > 1800) bodyPreview = [[bodyPreview substringToIndex:1800] stringByAppendingString:@"…"];
            YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Page %lu failed: HTTP %ld, error=%@, body=%@",
                                      (unsigned long)(page + 1), (long)statusCode,
                                      requestError.localizedDescription ?: @"none", bodyPreview ?: @"(non-UTF8 body)"]);
            break;
        }

        NSError *jsonError = nil;
        id jsonObject = [NSJSONSerialization JSONObjectWithData:responseData options:NSJSONReadingMutableContainers error:&jsonError];
        if (![jsonObject isKindOfClass:[NSDictionary class]]) {
            YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Page %lu invalid JSON: %@",
                                      (unsigned long)(page + 1), jsonError.localizedDescription ?: @"unknown"]);
            break;
        }

        NSDictionary *json = (NSDictionary *)jsonObject;
        NSUInteger before = tracks.count;
        extractTracksFromJSONObject(json, tracks);
        page++;
        YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Page %lu: HTTP %ld, added %lu, total %lu",
                                  (unsigned long)page, (long)statusCode,
                                  (unsigned long)(tracks.count - before), (unsigned long)tracks.count]);
        if (tracks.count == before) {
            NSArray *rootKeys = [[json allKeys] sortedArrayUsingSelector:@selector(compare:)];
            NSString *bodyPreview = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
            if (bodyPreview.length > 2600) bodyPreview = [[bodyPreview substringToIndex:2600] stringByAppendingString:@"…"];
            YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"No tracks parsed on page %lu. Root keys=%@. JSON preview=%@",
                                      (unsigned long)page, rootKeys ?: @[], bodyPreview ?: @"(non-UTF8 body)"]);
        }

        NSMutableSet *tokenVisited = [NSMutableSet set];
        NSString *nextToken = findContinuationToken(json, tokenVisited, 0);
        if (nextToken.length == 0) {
            YTMUWritePlaylistDebugLog(@"Pagination finished: no continuation token.");
            break;
        }
        if ([seenContinuations containsObject:nextToken]) {
            YTMUWritePlaylistDebugLog(@"Pagination stopped: repeated continuation token.");
            break;
        }
        [seenContinuations addObject:nextToken];
        continuation = nextToken;
    }

    [session invalidateAndCancel];
    YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Playlist fetch completed: %lu tracks.", (unsigned long)tracks.count]);
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

    NSString *nodePlaylistId = nil;
    if (node) {
        NSMutableSet *nodeVisited = [NSMutableSet set];
        nodePlaylistId = extractPlaylistIdFromObject(node, nodeVisited, 0);
        if (isValidPlaylistBrowseID(nodePlaylistId)) {
            gActivePlaylistId = [nodePlaylistId copy];
        }
    }

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

    BOOL isPlaylistDownload = isValidPlaylistBrowseID(nodePlaylistId);
    if (!isPlaylistDownload && node && node.key) {
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
        NSLog(@"[MaxMusic Playlist] Direct playlist download tap: node=%@ key=%@ playlistID=%@",
              NSStringFromClass([node class]), node.key ?: @"(nil)", nodePlaylistId ?: @"(nil)");
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

    UIViewController *presentingVC = nil;
    if (sourceView && [sourceView respondsToSelector:@selector(_viewControllerForAncestor)]) {
        presentingVC = [sourceView _viewControllerForAncestor];
    }
    if (!presentingVC) {
        presentingVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    }
    while (presentingVC.presentedViewController && !presentingVC.presentedViewController.isBeingDismissed) {
        presentingVC = presentingVC.presentedViewController;
    }

    if (!presentingVC) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = @"Unable to Start Download";
        alertView.subtitle = @"Could not find a view controller to show the download options.";
        [alertView show];
        return;
    }

    UIAlertController *choiceController = [UIAlertController alertControllerWithTitle:@"Download All Playlist Tracks"
                                                                               message:@"How would you like to save this playlist?"
                                                                        preferredStyle:UIAlertControllerStyleActionSheet];

    [choiceController addAction:[UIAlertAction actionWithTitle:@"Separate Songs"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
        [self downloadPlaylistTracks:sourceView saveAsCustomOfflinePlaylist:NO];
    }]];

    [choiceController addAction:[UIAlertAction actionWithTitle:@"Custom Offline Playlist"
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *action) {
        [self downloadPlaylistTracks:sourceView saveAsCustomOfflinePlaylist:YES];
    }]];

    [choiceController addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil]];

    // Required on iPad when presenting an action sheet.
    UIPopoverPresentationController *popover = choiceController.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: presentingVC.view;
        popover.sourceRect = sourceView ? sourceView.bounds : presentingVC.view.bounds;
    }

    [presentingVC presentViewController:choiceController animated:YES completion:nil];
}

%new
- (void)downloadPlaylistTracks:(UIView *)sourceView saveAsCustomOfflinePlaylist:(BOOL)saveAsCustomOfflinePlaylist {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self downloadPlaylistTracks:sourceView saveAsCustomOfflinePlaylist:saveAsCustomOfflinePlaylist];
        });
        return;
    }

    // Read UIKit/player state on the main thread before starting network work.
    NSString *playlistId = extractPlaylistIdFromHierarchy(sourceView);
    if (!isValidPlaylistBrowseID(playlistId) && isValidPlaylistBrowseID(gActivePlaylistId)) {
        playlistId = gActivePlaylistId;
    }
    NSString *playlistName = saveAsCustomOfflinePlaylist ? getPlaylistTitleFromHierarchy(sourceView) : nil;
    if (saveAsCustomOfflinePlaylist && playlistName.length == 0) {
        playlistName = @"Downloaded Playlist";
    }

    YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Download mode: %@", saveAsCustomOfflinePlaylist ? @"custom offline playlist" : @"separate songs"]);
    YTMUWritePlaylistDebugLog([NSString stringWithFormat:@"Playlist ID resolved on main thread: %@", playlistId ?: @"(nil)"]);

    if (!isValidPlaylistBrowseID(playlistId)) {
        YTAlertView *alertView = [%c(YTAlertView) infoDialog];
        alertView.title = @"Playlist Not Found";
        alertView.subtitle = @"Could not find this playlist's ID. No tracks were downloaded.";
        [alertView show];
        return;
    }

    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.mode = MBProgressHUDModeIndeterminate;
    hud.label.text = @"Fetching playlist tracks...";

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSDictionary *> *tracks = extractPlaylistTracks(playlistId);

        if (tracks.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [hud hideAnimated:YES];

                YTAlertView *alertView = [%c(YTAlertView) infoDialog];
                alertView.title = @"Playlist Not Found";
                alertView.subtitle = @"YouTube Music returned no tracks for this playlist. No current or suggested track was downloaded.";
                [alertView show];
            });
            return;
        }

        dispatch_sync(dispatch_get_main_queue(), ^{
            if (saveAsCustomOfflinePlaylist) {
                [YTMDownloadMetadata createPlaylistNamed:playlistName];
                hud.label.text = [NSString stringWithFormat:@"Saving Custom Offline Playlist (%lu tracks)...", (unsigned long)tracks.count];
            } else {
                hud.label.text = [NSString stringWithFormat:@"Downloading Separate Songs (%lu tracks)...", (unsigned long)tracks.count];
            }
        });

        NSUInteger count = 0;
        __block NSUInteger successCount = 0;
        __block NSUInteger failCount = 0;
        __block NSString *lastError = nil;

        for (NSDictionary *dict in tracks) {
            count++;
            NSString *vId = dict[@"videoId"];
            NSString *tTitle = dict[@"title"];
            if (![vId isKindOfClass:[NSString class]] || vId.length == 0) {
                failCount++;
                lastError = @"Playlist item did not contain a video ID";
                continue;
            }

            NSUInteger currentCount = count;
            dispatch_async(dispatch_get_main_queue(), ^{
                hud.label.text = [NSString stringWithFormat:@"Downloading (%lu/%lu): %@",
                                 (unsigned long)currentCount, (unsigned long)tracks.count,
                                 tTitle ?: @"Track"];
            });

            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            NSString *targetPlaylistName = saveAsCustomOfflinePlaylist ? playlistName : nil;
            [self downloadTrackWithVideoId:vId title:tTitle playlistName:targetPlaylistName completion:^(BOOL success, NSString *errorReason) {
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
                if (saveAsCustomOfflinePlaylist) {
                    alertView.subtitle = [NSString stringWithFormat:@"Successfully saved %lu tracks to the custom offline playlist '%@'.",
                                          (unsigned long)successCount, playlistName];
                } else {
                    alertView.subtitle = [NSString stringWithFormat:@"Successfully downloaded %lu songs separately.", (unsigned long)successCount];
                }
            } else if (saveAsCustomOfflinePlaylist) {
                alertView.subtitle = [NSString stringWithFormat:@"Saved %lu tracks to '%@'. %lu failed. Last error: %@",
                                      (unsigned long)successCount, playlistName,
                                      (unsigned long)failCount, lastError ?: @"Unknown"];
            } else {
                alertView.subtitle = [NSString stringWithFormat:@"Downloaded %lu songs separately. %lu failed. Last error: %@",
                                      (unsigned long)successCount, (unsigned long)failCount,
                                      lastError ?: @"Unknown"];
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
