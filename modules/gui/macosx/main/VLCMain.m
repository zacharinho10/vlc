/*****************************************************************************
 * VLCMain.m: MacOS X interface module
 *****************************************************************************
 * Copyright (C) 2002-2019 VLC authors and VideoLAN
 *
 * Authors: Derk-Jan Hartman <hartman at videolan.org>
 *          Felix Paul Kühne <fkuehne at videolan dot org>
 *          Pierre d'Herbemont <pdherbemont # videolan org>
 *          David Fuhrmann <david dot fuhrmann at googlemail dot com>
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

/*****************************************************************************
 * Preamble
 *****************************************************************************/
#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#import "main/VLCMain.h"

#include <stdlib.h>                                      /* malloc(), free() */
#include <string.h>
#include <stdatomic.h>

#include <vlc_common.h>
#include <vlc_actions.h>
#include <vlc_dialog.h>
#include <vlc_url.h>
#include <vlc_variables.h>

#import "library/VLCLibraryWindow.h"

#import "main/CompatibilityFixes.h"
#import "main/VLCMain+OldPrefs.h"
#import "main/VLCApplication.h"

#import "extensions/NSString+Helpers.h"

#import "menus/VLCMainMenu.h"
#import "menus/VLCStatusBarIcon.h"

#import "os-integration/VLCClickerManager.h"

#import "panels/dialogs/VLCResumeDialogController.h"
#import "panels/dialogs/VLCCoreDialogProvider.h"
#import "panels/VLCAudioEffectsWindowController.h"
#import "panels/VLCBookmarksWindowController.h"
#import "panels/VLCInformationWindowController.h"
#import "panels/VLCVideoEffectsWindowController.h"
#import "panels/VLCTrackSynchronizationWindowController.h"

#import "library/VLCLibraryController.h"
#import "playlist/VLCPlaylistController.h"
#import "playlist/VLCPlayerController.h"
#import "playlist/VLCPlaylistModel.h"
#import "playlist/VLCPlaybackContinuityController.h"

#import "preferences/prefs.h"
#import "preferences/VLCSimplePrefsController.h"

#import "windows/extensions/VLCExtensionsManager.h"
#import "windows/logging/VLCLogWindowController.h"
#import "windows/convertandsave/VLCConvertAndSaveWindowController.h"
#import "windows/VLCOpenWindowController.h"
#import "windows/VLCOpenInputMetadata.h"
#import "windows/video/VLCVoutView.h"
#import "windows/video/VLCVideoOutputProvider.h"

#ifdef HAVE_SPARKLE
#import <Sparkle/Sparkle.h>                 /* we're the update delegate */
#endif

NSString *VLCConfigurationChangedNotification = @"VLCConfigurationChangedNotification";

#pragma mark -
#pragma mark Private extension

@interface VLCMain ()
#ifdef HAVE_SPARKLE
<SUUpdaterDelegate, NSApplicationDelegate>
#else
<NSApplicationDelegate>
#endif
{
    intf_thread_t *p_intf;
    BOOL launched;

    BOOL b_active_videoplayback;

    VLCMainMenu *_mainmenu;
    VLCPrefs *_prefs;
    VLCSimplePrefsController *_sprefs;
    VLCOpenWindowController *_open;
    VLCCoreDialogProvider *_coredialogs;
    VLCBookmarksWindowController *_bookmarks;
    VLCResumeDialogController *_resume_dialog;
    VLCPlaybackContinuityController *_continuityController;
    VLCLogWindowController *_messagePanelController;
    VLCStatusBarIcon *_statusBarIcon;
    VLCTrackSynchronizationWindowController *_trackSyncPanel;
    VLCAudioEffectsWindowController *_audioEffectsPanel;
    VLCVideoEffectsWindowController *_videoEffectsPanel;
    VLCConvertAndSaveWindowController *_convertAndSaveWindow;
    VLCInformationWindowController *_currentMediaInfoPanel;
    VLCLibraryWindowController *_libraryWindowController;
    VLCClickerManager *_clickerManager;

    bool b_intf_terminating; /* Makes sure applicationWillTerminate will be called only once */
}
+ (void)killInstance;
- (void)applicationWillTerminate:(NSNotification *)notification;

@end

#pragma mark -
#pragma mark VLC Interface Object Callbacks

/*****************************************************************************
 * OpenIntf: initialize interface
 *****************************************************************************/

static intf_thread_t *p_interface_thread;

intf_thread_t *getIntf()
{
    return p_interface_thread;
}

int OpenIntf (vlc_object_t *p_this)
{
    @autoreleasepool {
        intf_thread_t *p_intf = (intf_thread_t*) p_this;
        p_interface_thread = p_intf;
        msg_Dbg(p_intf, "Starting macosx interface");

        @try {
            [VLCApplication sharedApplication];
            [VLCMain sharedInstance];

            [[NSBundle mainBundle] loadNibNamed:@"MainMenu" owner:[[VLCMain sharedInstance] mainMenu] topLevelObjects:nil];
            [[[VLCMain sharedInstance] libraryWindow] makeKeyAndOrderFront:nil];

            msg_Dbg(p_intf, "Finished loading macosx interface");
            return VLC_SUCCESS;
        } @catch (NSException *exception) {
            msg_Err(p_intf, "Loading the macosx interface failed. Do you have a valid window server?");
            return VLC_EGENERIC;
        }
    }
}

void CloseIntf (vlc_object_t *p_this)
{
    @autoreleasepool {
        msg_Dbg(p_this, "Closing macosx interface");
        [[VLCMain sharedInstance] applicationWillTerminate:nil];
        [VLCMain killInstance];

        p_interface_thread = nil;
    }
}

#pragma mark -
#pragma mark Variables Callback

/*****************************************************************************
 * ShowController: Callback triggered by the show-intf playlist variable
 * through the ShowIntf-control-intf, to let us show the controller-win;
 * usually when in fullscreen-mode
 *****************************************************************************/
static int ShowController(vlc_object_t *p_this, const char *psz_variable,
                     vlc_value_t old_val, vlc_value_t new_val, void *param)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{

            intf_thread_t *p_intf = getIntf();
            if (p_intf) {
                VLCMain *mainInstance = [VLCMain sharedInstance];
                if ([[[mainInstance playlistController] playerController] fullscreen]) {
                    [[NSNotificationCenter defaultCenter] postNotificationName:VLCVideoWindowShouldShowFullscreenController
                                                                        object:mainInstance];
                } else if (!strcmp(psz_variable, "intf-show")) {
                    [[mainInstance libraryWindow] makeKeyAndOrderFront:nil];
                }
            }

        });

        return VLC_SUCCESS;
    }
}

static int BossCallback(vlc_object_t *p_this, const char *psz_var,
                        vlc_value_t oldval, vlc_value_t new_val, void *param)
{
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[[VLCMain sharedInstance] playlistController] pausePlayback];
            [[NSApplication sharedApplication] hide:nil];
        });

        return VLC_SUCCESS;
    }
}

/*****************************************************************************
 * VLCMain implementation
 *****************************************************************************/
@implementation VLCMain

#pragma mark -
#pragma mark Initialization

static VLCMain *sharedInstance = nil;

+ (VLCMain *)sharedInstance;
{
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        sharedInstance = [[VLCMain alloc] init];
    });

    return sharedInstance;
}

+ (void)killInstance
{
    sharedInstance = nil;
}

- (id)init
{
    self = [super init];
    if (self) {
        p_intf = getIntf();

        [VLCApplication sharedApplication].delegate = self;

        _playlistController = [[VLCPlaylistController alloc] initWithPlaylist:vlc_intf_GetMainPlaylist(p_intf)];
        _libraryController = [[VLCLibraryController alloc] init];
        _continuityController = [[VLCPlaybackContinuityController alloc] init];

        // first initalize extensions dialog provider, then core dialog
        // provider which will register both at the core
        _extensionsManager = [[VLCExtensionsManager alloc] init];
        _coredialogs = [[VLCCoreDialogProvider alloc] init];

        _mainmenu = [[VLCMainMenu alloc] init];
        _statusBarIcon = [[VLCStatusBarIcon  alloc] init];

        _voutProvider = [[VLCVideoOutputProvider alloc] init];

        _libraryWindowController = [[VLCLibraryWindowController alloc] initWithLibraryWindow];

        libvlc_int_t *libvlc = vlc_object_instance(p_intf);
        var_AddCallback(libvlc, "intf-toggle-fscontrol", ShowController, (__bridge void *)self);
        var_AddCallback(libvlc, "intf-show", ShowController, (__bridge void *)self);
        var_AddCallback(libvlc, "intf-boss", BossCallback, (__bridge void *)self);

        // Load them here already to apply stored profiles
        _videoEffectsPanel = [[VLCVideoEffectsWindowController alloc] init];
        _audioEffectsPanel = [[VLCAudioEffectsWindowController alloc] init];

        if ([NSApp currentSystemPresentationOptions] & NSApplicationPresentationFullScreen)
            [_playlistController.playerController setFullscreen:YES];

        if (var_InheritInteger(p_intf, "macosx-icon-change")) {
            /* After day 354 of the year, the usual VLC cone is replaced by another cone
             * wearing a Father Xmas hat.
             * Note: this icon doesn't represent an endorsement of The Coca-Cola Company.
             */
            NSCalendar *gregorian =
            [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSUInteger dayOfYear = [gregorian ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitYear forDate:[NSDate date]];

            if (dayOfYear >= 354)
                [[VLCApplication sharedApplication] setApplicationIconImage: [NSImage imageNamed:@"VLC-Xmas"]];
            else
                [[VLCApplication sharedApplication] setApplicationIconImage: [NSImage imageNamed:@"VLC"]];
        }
    }

    return self;
}

- (void)applicationWillFinishLaunching:(NSNotification *)aNotification
{
    _clickerManager = [[VLCClickerManager alloc] init];

#ifdef HAVE_SPARKLE
    [[SUUpdater sharedUpdater] setDelegate:self];
#endif
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    launched = YES;

    if (!p_intf)
        return;

    [self migrateOldPreferences];

    /* Handle sleep notification */
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(computerWillSleep:)
           name:NSWorkspaceWillSleepNotification object:nil];

    // respect playlist-autostart
    if (var_GetBool(p_intf, "playlist-autostart")) {
        if ([_playlistController.playlistModel numberOfPlaylistItems] > 0) {
            [_playlistController startPlaylist];
        }
    }
}

#pragma mark -
#pragma mark Termination

- (BOOL)isTerminating
{
    return b_intf_terminating;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    msg_Dbg(getIntf(), "applicationWillTerminate called");
    if (b_intf_terminating)
        return;
    b_intf_terminating = true;

    _continuityController = nil;

    if (notification == nil)
        [[NSNotificationCenter defaultCenter] postNotificationName: NSApplicationWillTerminateNotification object: nil];

    /* save current video and audio profiles */
    [[self videoEffectsPanel] saveCurrentProfileAtTerminate];
    [[self audioEffectsPanel] saveCurrentProfileAtTerminate];

    libvlc_int_t *libvlc = vlc_object_instance(p_intf);
    var_DelCallback(libvlc, "intf-toggle-fscontrol", ShowController, (__bridge void *)self);
    var_DelCallback(libvlc, "intf-show", ShowController, (__bridge void *)self);
    var_DelCallback(libvlc, "intf-boss", BossCallback, (__bridge void *)self);

    [[NSNotificationCenter defaultCenter] removeObserver: self];

    // closes all open vouts
    _voutProvider = nil;

    /* write cached user defaults to disk */
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark -
#pragma mark Sparkle delegate

#ifdef HAVE_SPARKLE
/* received directly before the update gets installed, so let's shut down a bit */
- (void)updater:(SUUpdater *)updater willInstallUpdate:(SUAppcastItem *)update
{
    [NSApp activateIgnoringOtherApps:YES];
    [_playlistController stopPlayback];
}

/* don't be enthusiastic about an update if we currently play a video */
- (BOOL)updaterMayCheckForUpdates:(SUUpdater *)bundle
{
    if ([self activeVideoPlayback])
        return NO;

    return YES;
}
#endif

#pragma mark -
#pragma mark Other notification

/* Triggered when the computer goes to sleep */
- (void)computerWillSleep: (NSNotification *)notification
{
    [_playlistController pausePlayback];
}

#pragma mark -
#pragma mark File opening over dock icon

- (void)application:(NSApplication *)o_app openFiles:(NSArray *)o_names
{
    // Only add items here which are getting dropped to to the application icon
    // or are given at startup. If a file is passed via command line, libvlccore
    // will add the item, but cocoa also calls this function. In this case, the
    // invocation is ignored here.
    NSArray *resultItems = o_names;
    if (launched == NO) {
        NSArray *launchArgs = [[NSProcessInfo processInfo] arguments];

        if (launchArgs) {
            NSSet *launchArgsSet = [NSSet setWithArray:launchArgs];
            NSMutableSet *itemSet = [NSMutableSet setWithArray:o_names];
            [itemSet minusSet:launchArgsSet];
            resultItems = [itemSet allObjects];
        }
    }

    NSArray *o_sorted_names = [resultItems sortedArrayUsingSelector: @selector(caseInsensitiveCompare:)];
    NSMutableArray *o_result = [NSMutableArray arrayWithCapacity: [o_sorted_names count]];
    for (NSUInteger i = 0; i < [o_sorted_names count]; i++) {
        char *psz_uri = vlc_path2uri([[o_sorted_names objectAtIndex:i] UTF8String], "file");
        if (!psz_uri)
            continue;

        VLCOpenInputMetadata *o_inputMetadata = [[VLCOpenInputMetadata alloc] init];
        o_inputMetadata.MRLString = toNSStr(psz_uri);
        [o_result addObject: o_inputMetadata];
        free(psz_uri);
    }

    [_playlistController addPlaylistItems:o_result];
}

/* When user click in the Dock icon our double click in the finder */
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)hasVisibleWindows
{
    if (!hasVisibleWindows)
        [[self libraryWindow] makeKeyAndOrderFront:self];

    return YES;
}

- (void)setActiveVideoPlayback:(BOOL)b_value
{
    assert([NSThread isMainThread]);

    b_active_videoplayback = b_value;
    if ([self libraryWindow]) {
//        [[self libraryWindow] toggleVideoPlaybackAppearance];
    }
}

#pragma mark -
#pragma mark Other objects getters

- (VLCMainMenu *)mainMenu
{
    return _mainmenu;
}

- (VLCLibraryWindowController *)libraryWindowController
{
    return _libraryWindowController;
}

- (VLCLibraryWindow *)libraryWindow
{
    return (VLCLibraryWindow *)_libraryWindowController.window;
}

- (VLCLogWindowController *)debugMsgPanel
{
    if (!_messagePanelController)
        _messagePanelController = [[VLCLogWindowController alloc] init];

    return _messagePanelController;
}

- (VLCTrackSynchronizationWindowController *)trackSyncPanel
{
    if (!_trackSyncPanel)
        _trackSyncPanel = [[VLCTrackSynchronizationWindowController alloc] init];

    return _trackSyncPanel;
}

- (VLCAudioEffectsWindowController *)audioEffectsPanel
{
    return _audioEffectsPanel;
}

- (VLCVideoEffectsWindowController *)videoEffectsPanel
{
    return _videoEffectsPanel;
}

- (VLCInformationWindowController *)currentMediaInfoPanel;
{
    if (!_currentMediaInfoPanel)
        _currentMediaInfoPanel = [[VLCInformationWindowController alloc] init];

    return _currentMediaInfoPanel;
}

- (VLCBookmarksWindowController *)bookmarks
{
    if (!_bookmarks)
        _bookmarks = [[VLCBookmarksWindowController alloc] init];

    return _bookmarks;
}

- (VLCOpenWindowController *)open
{
    if (!_open)
        _open = [[VLCOpenWindowController alloc] init];

    return _open;
}

- (VLCConvertAndSaveWindowController *)convertAndSaveWindow
{
    if (_convertAndSaveWindow == nil)
        _convertAndSaveWindow = [[VLCConvertAndSaveWindowController alloc] init];

    return _convertAndSaveWindow;
}

- (VLCSimplePrefsController *)simplePreferences
{
    if (!_sprefs)
        _sprefs = [[VLCSimplePrefsController alloc] init];

    return _sprefs;
}

- (VLCPrefs *)preferences
{
    if (!_prefs)
        _prefs = [[VLCPrefs alloc] init];

    return _prefs;
}

- (VLCCoreDialogProvider *)coreDialogProvider
{
    return _coredialogs;
}

- (VLCResumeDialogController *)resumeDialog
{
    if (!_resume_dialog)
        _resume_dialog = [[VLCResumeDialogController alloc] init];

    return _resume_dialog;
}

- (BOOL)activeVideoPlayback
{
    return b_active_videoplayback;
}

@end
