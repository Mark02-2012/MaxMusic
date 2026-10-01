#import "YTMDownloadMetadata.h"

static NSString * const kYTMPlaylistsKey = @"__playlists__";

@implementation YTMDownloadMetadata

+ (NSURL *)metadataFileURL {
    NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
    return [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate/metadata.json"];
}

+ (NSMutableDictionary *)loadAll {
    NSURL *fileURL = [self metadataFileURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
        return [NSMutableDictionary dictionary];
    }
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (!data) return [NSMutableDictionary dictionary];
    
    NSError *error = nil;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error || ![dict isKindOfClass:[NSDictionary class]]) {
        return [NSMutableDictionary dictionary];
    }
    return [dict mutableCopy];
}

+ (void)saveAll:(NSDictionary *)metadataDict {
    NSURL *fileURL = [self metadataFileURL];
    NSURL *folderURL = [fileURL URLByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:metadataDict options:NSJSONWritingPrettyPrinted error:&error];
    if (data && !error) {
        [data writeToURL:fileURL atomically:YES];
    }
}

+ (void)saveMetadataForFileName:(NSString *)fileName videoId:(NSString *)videoId title:(NSString *)title author:(NSString *)author {
    if (!fileName || fileName.length == 0) return;
    
    NSMutableDictionary *all = [self loadAll];
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    if (videoId) item[@"videoId"] = videoId;
    if (title) item[@"title"] = title;
    if (author) item[@"author"] = author;
    
    all[fileName] = item;
    [self saveAll:all];
}

+ (NSDictionary *)metadataForFileName:(NSString *)fileName {
    if (!fileName) return nil;
    NSDictionary *all = [self loadAll];
    return all[fileName];
}

+ (NSString *)videoIdForFileName:(NSString *)fileName {
    NSDictionary *meta = [self metadataForFileName:fileName];
    return meta[@"videoId"];
}

+ (NSString *)fileNameForVideoId:(NSString *)targetVideoId {
    if (!targetVideoId) return nil;
    NSDictionary *all = [self loadAll];
    for (NSString *fileName in all) {
        if ([fileName isEqualToString:kYTMPlaylistsKey]) continue;
        NSDictionary *meta = all[fileName];
        if ([meta isKindOfClass:[NSDictionary class]] && [meta[@"videoId"] isEqualToString:targetVideoId]) {
            return fileName;
        }
    }
    return nil;
}

+ (void)removeMetadataForFileName:(NSString *)fileName {
    if (!fileName) return;
    NSMutableDictionary *all = [self loadAll];
    [all removeObjectForKey:fileName];
    
    // Also remove from any playlist containing this fileName
    NSMutableDictionary *playlists = [all[kYTMPlaylistsKey] mutableCopy];
    if (playlists) {
        for (NSString *pName in [playlists allKeys]) {
            NSMutableArray *tracks = [playlists[pName] mutableCopy];
            if ([tracks containsObject:fileName]) {
                [tracks removeObject:fileName];
                playlists[pName] = tracks;
            }
        }
        all[kYTMPlaylistsKey] = playlists;
    }
    
    [self saveAll:all];
}

+ (void)renameMetadataFrom:(NSString *)oldName to:(NSString *)newName {
    if (!oldName || !newName) return;
    NSMutableDictionary *all = [self loadAll];
    NSDictionary *oldMeta = all[oldName];
    if (oldMeta) {
        all[newName] = oldMeta;
        [all removeObjectForKey:oldName];
        
        // Update references in playlists
        NSMutableDictionary *playlists = [all[kYTMPlaylistsKey] mutableCopy];
        if (playlists) {
            for (NSString *pName in [playlists allKeys]) {
                NSMutableArray *tracks = [playlists[pName] mutableCopy];
                NSUInteger idx = [tracks indexOfObject:oldName];
                if (idx != NSNotFound) {
                    tracks[idx] = newName;
                    playlists[pName] = tracks;
                }
            }
            all[kYTMPlaylistsKey] = playlists;
        }
        
        [self saveAll:all];
    }
}

+ (NSDictionary *)allMetadata {
    return [self loadAll];
}

#pragma mark - Playlists Implementation

+ (NSMutableDictionary *)playlistsDictFromAll:(NSMutableDictionary *)all {
    NSDictionary *existing = all[kYTMPlaylistsKey];
    if ([existing isKindOfClass:[NSDictionary class]]) {
        return [existing mutableCopy];
    }
    return [NSMutableDictionary dictionary];
}

+ (NSArray<NSString *> *)allPlaylists {
    NSMutableDictionary *all = [self loadAll];
    NSDictionary *playlists = [self playlistsDictFromAll:all];
    return [[playlists allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

+ (void)createPlaylistNamed:(NSString *)name {
    if (!name || name.length == 0) return;
    NSMutableDictionary *all = [self loadAll];
    NSMutableDictionary *playlists = [self playlistsDictFromAll:all];
    if (!playlists[name]) {
        playlists[name] = @[];
        all[kYTMPlaylistsKey] = playlists;
        [self saveAll:all];
    }
}

+ (void)deletePlaylistNamed:(NSString *)name {
    if (!name) return;
    NSMutableDictionary *all = [self loadAll];
    NSMutableDictionary *playlists = [self playlistsDictFromAll:all];
    [playlists removeObjectForKey:name];
    all[kYTMPlaylistsKey] = playlists;
    [self saveAll:all];
}

+ (void)addTrack:(NSString *)fileName toPlaylist:(NSString *)playlistName {
    if (!fileName || !playlistName) return;
    NSMutableDictionary *all = [self loadAll];
    NSMutableDictionary *playlists = [self playlistsDictFromAll:all];
    NSMutableArray *tracks = [playlists[playlistName] mutableCopy] ?: [NSMutableArray array];
    if (![tracks containsObject:fileName]) {
        [tracks addObject:fileName];
        playlists[playlistName] = tracks;
        all[kYTMPlaylistsKey] = playlists;
        [self saveAll:all];
    }
}

+ (void)removeTrack:(NSString *)fileName fromPlaylist:(NSString *)playlistName {
    if (!fileName || !playlistName) return;
    NSMutableDictionary *all = [self loadAll];
    NSMutableDictionary *playlists = [self playlistsDictFromAll:all];
    NSMutableArray *tracks = [playlists[playlistName] mutableCopy];
    if (tracks && [tracks containsObject:fileName]) {
        [tracks removeObject:fileName];
        playlists[playlistName] = tracks;
        all[kYTMPlaylistsKey] = playlists;
        [self saveAll:all];
    }
}

+ (NSArray<NSString *> *)tracksForPlaylist:(NSString *)playlistName {
    if (!playlistName) return @[];
    NSMutableDictionary *all = [self loadAll];
    NSDictionary *playlists = [self playlistsDictFromAll:all];
    NSArray *tracks = playlists[playlistName];
    if ([tracks isKindOfClass:[NSArray class]]) {
        return tracks;
    }
    return @[];
}

@end
