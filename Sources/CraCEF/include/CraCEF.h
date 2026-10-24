// CraCEF: the Objective-C surface Swift uses to drive Chromium (CEF).
// Everything here runs on the main thread.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class CraBrowser;

typedef NS_ENUM(NSInteger, CraDownloadState) {
    CraDownloadStateInProgress = 0,
    CraDownloadStateComplete = 1,
    CraDownloadStateCancelled = 2,
    CraDownloadStateInterrupted = 3,
};

@interface CraDownloadInfo : NSObject
@property (nonatomic) uint32_t identifier;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *fullPath;
@property (nonatomic, copy) NSString *suggestedName;
@property (nonatomic) int64_t receivedBytes;
@property (nonatomic) int64_t totalBytes;
@property (nonatomic) NSInteger percent;
@property (nonatomic) CraDownloadState state;
@end

@protocol CraBrowserDelegate <NSObject>
- (void)browser:(CraBrowser *)browser didChangeTitle:(NSString *)title;
- (void)browser:(CraBrowser *)browser didChangeURL:(NSString *)url;
- (void)browser:(CraBrowser *)browser didChangeLoading:(BOOL)loading canGoBack:(BOOL)canGoBack canGoForward:(BOOL)canGoForward;
- (void)browser:(CraBrowser *)browser didChangeProgress:(double)progress;
- (void)browser:(CraBrowser *)browser didFinishLoadingURL:(NSString *)url title:(NSString *)title statusCode:(NSInteger)statusCode;
- (void)browser:(CraBrowser *)browser didLoadFavicon:(NSImage *)image forURL:(NSString *)iconURL;
- (void)browser:(CraBrowser *)browser didChangeStatusMessage:(NSString *)message;
/// The page's theme colour (meta theme-color or body background) as "#RRGGBB", or "" when unknown.
- (void)browser:(CraBrowser *)browser didReportThemeColor:(NSString *)hex;
- (void)browser:(CraBrowser *)browser didChangeFullscreen:(BOOL)fullscreen;
/// Cmd-click, middle-click and similar: open a plain new tab.
- (void)browser:(CraBrowser *)browser requestsNewTabWithURL:(NSString *)url inBackground:(BOOL)background;
/// window.open / target=_blank: return a popup host (a CraBrowser created with
/// a nil URL) so the popup keeps its opener relationship, or nil to block it.
- (nullable CraBrowser *)browser:(CraBrowser *)browser popupHostForURL:(NSString *)url inBackground:(BOOL)background;
/// Return a view to host DevTools in (Cra docks it inside the content card);
/// nil makes CEF open its own DevTools window.
- (nullable NSView *)devToolsHostViewForBrowser:(CraBrowser *)browser;
/// DevTools was created for docking (a host view was returned): `view.window`
/// is CEF's hidden Alloy window, to be attached as a child window.
- (void)browser:(CraBrowser *)browser didCreateDevToolsView:(NSView *)view;
/// The DevTools browser closed (either mode).
- (void)browserDidCloseDevTools:(CraBrowser *)browser;
/// Chrome-style hosting: the page's window exists (also for popups).
- (void)browser:(CraBrowser *)browser didCreateHostWindow:(NSWindow *)window;
/// Reserved shortcuts, before the page sees the key. Return YES to consume.
- (BOOL)browser:(CraBrowser *)browser handleKeyEvent:(NSEvent *)event;
/// Keys the page did not handle (Chrome gives the page first chance at
/// unreserved shortcuts like ⌘F). Return YES to consume.
- (BOOL)browser:(CraBrowser *)browser handleUnhandledKeyEvent:(NSEvent *)event;
- (void)browser:(CraBrowser *)browser didUpdateDownload:(CraDownloadInfo *)download;
/// Ask the user. `kinds` is a bitmask: 1 = camera, 2 = microphone,
/// 4 = location, 8 = notifications, 16 = other.
- (void)browser:(CraBrowser *)browser requestsPermissionForOrigin:(NSString *)origin kinds:(NSUInteger)kinds completion:(void (^)(BOOL allowed))completion;
- (void)browserDidReceiveFocus:(CraBrowser *)browser;
- (void)browserDidClose:(CraBrowser *)browser;
@optional
/// A video of this page entered or left Chromium's Picture in Picture window
/// (whether the page, the user or Cra asked for it).
- (void)browser:(CraBrowser *)browser didChangePictureInPicture:(BOOL)active;
@end

@interface CraBrowser : NSObject
@property (nonatomic, weak, nullable) id<CraBrowserDelegate> delegate;
/// Embedded (Alloy) hosting: a plain NSView that owns the Chromium view. Put
/// it in your hierarchy and size it; Chromium follows.
@property (nonatomic, readonly) NSView *containerView;
/// Chrome-style hosting (see +[CraCEFRuntime setChromeHosting:]): the page
/// lives in its own frameless Chrome window, delivered through
/// -browser:didCreateHostWindow:. Attach it as a child window and size it.
@property (nonatomic, readonly, nullable) NSWindow *hostWindow;
@property (nonatomic, readonly, copy) NSString *currentURL;
@property (nonatomic, readonly, copy) NSString *currentTitle;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
@property (nonatomic, readonly) BOOL isCreated;
@property (nonatomic, readonly) BOOL isClosed;
@property (nonatomic, readonly) BOOL hasDevTools;
/// Anything you want to hang on the browser (Swift stores the tab id).
@property (nonatomic, strong, nullable) id userInfo;

/// Pass a URL to create a browser now. Pass nil to create a popup host that
/// adopts the next popup CEF gives it (see -browser:popupHostForURL:...).
- (instancetype)initWithFrame:(NSRect)frame url:(nullable NSString *)url delegate:(nullable id<CraBrowserDelegate>)delegate;

- (void)loadURL:(NSString *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
- (void)setFocused:(BOOL)focused;
- (void)showDevToolsInspectingPoint:(NSPoint)point;
- (void)showDevTools;
- (void)closeDevTools;
- (double)zoomLevel;
- (void)setZoomLevel:(double)level;
- (void)findText:(NSString *)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext;
- (void)stopFinding:(BOOL)clearSelection;
- (void)setAudioMuted:(BOOL)muted;
/// Pops the page's video out into Chromium's floating Picture in Picture
/// window. Manual requests toggle (a second call brings the video back).
/// `automatic` is the "leaving a video tab" case: only a playing video of some
/// size qualifies, and nothing happens when there is none.
- (void)requestPictureInPictureAutomatic:(BOOL)automatic;
- (void)exitPictureInPicture;
/// YES while a video of this page is in the Picture in Picture window.
@property (nonatomic, readonly) BOOL isInPictureInPicture;
- (void)print;
- (void)viewSource;
- (void)executeJavaScript:(NSString *)script;
- (void)notifyMoveOrResizeStarted;
/// Asynchronous. -browserDidClose: fires when Chromium is done.
- (void)close;
@end

@interface CraCEFRuntime : NSObject
/// Call once, after NSApplication exists, before creating browsers.
/// Experiment: a Chrome-style (extension-capable) Views window; the handler gets its NSWindow.
+ (void)spikeChromeWindowWithURL:(NSString *)url handler:(void (^)(NSWindow *))handler;
/// Host pages as Chrome-style windows (Chrome extensions, Chrome's docked
/// DevTools) instead of embedded Alloy views. Set before any browser exists.
+ (void)setChromeHosting:(BOOL)enabled;
+ (BOOL)chromeHosting;
+ (BOOL)initializeWithCachePath:(NSString *)cachePath
                 userAgentProduct:(NSString *)product
                          logPath:(NSString *)logPath
                   useChromeStyle:(BOOL)useChromeStyle;
/// Runs the Chromium-integrated AppKit run loop. Returns after -quitMessageLoop.
+ (void)runMessageLoop;
+ (void)quitMessageLoop;
+ (void)shutdown;
/// Closes every browser, then quits the message loop once they are gone.
+ (void)closeAllBrowsersAndQuit;
+ (NSInteger)liveBrowserCount;
/// YES when initialize failed because another Cra is running and was told
/// about this launch (exit quietly).
+ (BOOL)anotherInstanceWasNotified;
/// Called in the running instance when another launch is handed over.
+ (void)setRelaunchHandler:(void (^)(NSArray<NSString *> *urls))handler;
+ (NSString *)chromiumVersion;
+ (NSString *)cefVersion;
@end

/// NSApplication subclass CEF requires (CefAppProtocol). Set as
/// NSPrincipalClass and created with +sharedApplication before anything else.
@interface CraApplication : NSApplication
@end

NS_ASSUME_NONNULL_END
