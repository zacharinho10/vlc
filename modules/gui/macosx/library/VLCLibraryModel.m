/*****************************************************************************
 * VLCLibraryModel.m: MacOS X interface module
 *****************************************************************************
 * Copyright (C) 2019 VLC authors and VideoLAN
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan -dot- org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "VLCLibraryModel.h"

#import "main/VLCMain.h"
#import "library/VLCLibraryDataTypes.h"

NSString *VLCLibraryModelAudioMediaListUpdated = @"VLCLibraryModelAudioMediaListUpdated";
NSString *VLCLibraryModelVideoMediaListUpdated = @"VLCLibraryModelVideoMediaListUpdated";
NSString *VLCLibraryModelRecentMediaListUpdated = @"VLCLibraryModelRecentMediaListUpdated";
NSString *VLCLibraryModelMediaItemUpdated = @"VLCLibraryModelMediaItemUpdated";

@interface VLCLibraryModel ()
{
    vlc_medialibrary_t *_p_mediaLibrary;
    vlc_ml_event_callback_t *_p_eventCallback;

    NSArray *_cachedAudioMedia;
    NSArray *_cachedVideoMedia;
    NSArray *_cachedRecentMedia;
    NSNotificationCenter *_defaultNotificationCenter;
}

- (void)updateCachedListOfAudioMedia;
- (void)updateCachedListOfVideoMedia;
- (void)updateCachedListOfRecentMedia;
- (void)mediaItemWasUpdated:(VLCMediaLibraryMediaItem *)mediaItem;

@end

static void libraryCallback(void *p_data, const vlc_ml_event_t *p_event)
{
    switch(p_event->i_type)
    {
        case VLC_ML_EVENT_MEDIA_ADDED:
        case VLC_ML_EVENT_MEDIA_UPDATED:
        case VLC_ML_EVENT_MEDIA_DELETED:
            dispatch_async(dispatch_get_main_queue(), ^{
                VLCLibraryModel *libraryModel = (__bridge VLCLibraryModel *)p_data;
                switch (libraryModel.libraryMode) {
                    case VLCLibraryModeAudio:
                        [libraryModel updateCachedListOfRecentMedia];
                        [libraryModel updateCachedListOfAudioMedia];
                        break;

                    case VLCLibraryModeVideo:
                        [libraryModel updateCachedListOfRecentMedia];
                        [libraryModel updateCachedListOfVideoMedia];
                        break;

                    default:
                        [libraryModel updateCachedListOfRecentMedia];
                        break;
                }

            });
            break;
        case VLC_ML_EVENT_MEDIA_THUMBNAIL_GENERATED:
            if (p_event->media_thumbnail_generated.b_success) {
                VLCMediaLibraryMediaItem *mediaItem = [[VLCMediaLibraryMediaItem alloc] initWithMediaItem:(struct vlc_ml_media_t *)p_event->media_thumbnail_generated.p_media];
                dispatch_async(dispatch_get_main_queue(), ^{
                    VLCLibraryModel *libraryModel = (__bridge VLCLibraryModel *)p_data;
                    [libraryModel mediaItemWasUpdated:mediaItem];
                });
            }
            break;
        default:
            break;
    }
}

@implementation VLCLibraryModel

- (instancetype)initWithLibrary:(vlc_medialibrary_t *)library
{
    self = [super init];
    if (self) {
        _p_mediaLibrary = library;
        _p_eventCallback = vlc_ml_event_register_callback(_p_mediaLibrary, libraryCallback, (__bridge void *)self);
        _defaultNotificationCenter = [NSNotificationCenter defaultCenter];
        [_defaultNotificationCenter addObserver:self
                                       selector:@selector(applicationWillTerminate:)
                                           name:NSApplicationWillTerminateNotification
                                         object:nil];
    }
    return self;
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    if (_p_eventCallback) {
        vlc_ml_event_unregister_callback(_p_mediaLibrary, _p_eventCallback);
    }
}

- (void)dealloc
{
    [_defaultNotificationCenter removeObserver:self];
}

- (void)mediaItemWasUpdated:(VLCMediaLibraryMediaItem *)mediaItem
{
    [_defaultNotificationCenter postNotificationName:VLCLibraryModelMediaItemUpdated object:mediaItem];
}

- (size_t)numberOfAudioMedia
{
    if (!_cachedAudioMedia) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCachedListOfAudioMedia];
        });
    }

    return _cachedAudioMedia.count;
}

- (void)updateCachedListOfAudioMedia
{
    vlc_ml_media_list_t *p_media_list = vlc_ml_list_audio_media(_p_mediaLibrary, NULL);
    NSMutableArray *mutableArray = [[NSMutableArray alloc] initWithCapacity:p_media_list->i_nb_items];
    for (size_t x = 0; x < p_media_list->i_nb_items; x++) {
        VLCMediaLibraryMediaItem *mediaItem = [[VLCMediaLibraryMediaItem alloc] initWithMediaItem:&p_media_list->p_items[x]];
        [mutableArray addObject:mediaItem];
    }
    _cachedAudioMedia = [mutableArray copy];
    vlc_ml_media_list_release(p_media_list);
    [_defaultNotificationCenter postNotificationName:VLCLibraryModelAudioMediaListUpdated object:self];
}

- (NSArray<VLCMediaLibraryMediaItem *> *)listOfAudioMedia
{
    if (!_cachedAudioMedia) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCachedListOfAudioMedia];
        });
    }

    return _cachedAudioMedia;
}

- (size_t)numberOfVideoMedia
{
    if (!_cachedVideoMedia) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCachedListOfVideoMedia];
        });
    }

    return _cachedVideoMedia.count;
}

- (void)updateCachedListOfVideoMedia
{
    vlc_ml_media_list_t *p_media_list = vlc_ml_list_video_media(_p_mediaLibrary, NULL);
    if (p_media_list == NULL) {
        return;
    }
    NSMutableArray *mutableArray = [[NSMutableArray alloc] initWithCapacity:p_media_list->i_nb_items];
    for (size_t x = 0; x < p_media_list->i_nb_items; x++) {
        VLCMediaLibraryMediaItem *mediaItem = [[VLCMediaLibraryMediaItem alloc] initWithMediaItem:&p_media_list->p_items[x]];
        [mutableArray addObject:mediaItem];
    }
    _cachedVideoMedia = [mutableArray copy];
    vlc_ml_media_list_release(p_media_list);
    [_defaultNotificationCenter postNotificationName:VLCLibraryModelVideoMediaListUpdated object:self];
}

- (NSArray<VLCMediaLibraryMediaItem *> *)listOfVideoMedia
{
    if (!_cachedVideoMedia) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCachedListOfVideoMedia];
        });
    }

    return _cachedVideoMedia;
}

- (void)updateCachedListOfRecentMedia
{
    vlc_ml_query_params_t queryParameters;
    memset(&queryParameters, 0, sizeof(vlc_ml_query_params_t));
    queryParameters.i_nbResults = 20;
    vlc_ml_media_list_t *p_media_list = vlc_ml_list_history(_p_mediaLibrary, &queryParameters);
    if (p_media_list == NULL) {
        return;
    }
    NSMutableArray *mutableArray = [[NSMutableArray alloc] initWithCapacity:p_media_list->i_nb_items];
    for (size_t x = 0; x < p_media_list->i_nb_items; x++) {
        VLCMediaLibraryMediaItem *mediaItem = [[VLCMediaLibraryMediaItem alloc] initWithMediaItem:&p_media_list->p_items[x]];
        [mutableArray addObject:mediaItem];
    }
    _cachedRecentMedia = [mutableArray copy];
    vlc_ml_media_list_release(p_media_list);
    [_defaultNotificationCenter postNotificationName:VLCLibraryModelRecentMediaListUpdated object:self];
}

- (size_t)numberOfRecentMedia
{
    if (!_cachedRecentMedia) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCachedListOfRecentMedia];
        });
    }

    return _cachedRecentMedia.count;
}

- (NSArray<VLCMediaLibraryMediaItem *> *)listOfRecentMedia
{
    if (!_cachedRecentMedia) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCachedListOfRecentMedia];
        });
    }

    return _cachedRecentMedia;
}

- (NSArray<VLCMediaLibraryEntryPoint *> *)listOfMonitoredFolders
{
    vlc_ml_entry_point_list_t *pp_entrypoints;
    int ret = vlc_ml_list_folder(_p_mediaLibrary, &pp_entrypoints);
    if (ret != VLC_SUCCESS) {
        msg_Err(getIntf(), "failed to retrieve list of monitored library folders (%i)", ret);
        return @[];
    }

    NSMutableArray *mutableArray = [[NSMutableArray alloc] initWithCapacity:pp_entrypoints->i_nb_items];
    for (size_t x = 0; x < pp_entrypoints->i_nb_items; x++) {
        VLCMediaLibraryEntryPoint *entryPoint = [[VLCMediaLibraryEntryPoint alloc] initWithEntryPoint:&pp_entrypoints->p_items[x]];
        if (entryPoint) {
            [mutableArray addObject:entryPoint];
        }
    }

    vlc_ml_entry_point_list_release(pp_entrypoints);
    return [mutableArray copy];
}

@end
