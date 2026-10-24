// Objective-C++ bridge between Swift and CEF. See include/CraCEF.h.
#import "CraCEF.h"

#include <crt_externs.h>
#include <atomic>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

// MARK: - Globals

static CefScopedLibraryLoader* g_libraryLoader = nullptr;
static std::atomic<bool> g_contextInitialized{false};
static std::atomic<int> g_liveBrowsers{0};
static bool g_quitting = false;
static bool g_useChromeStyle = false;
static NSMutableArray<CraBrowser*>* g_pendingCreation = nil;
static void (^g_relaunchHandler)(NSArray<NSString*>*) = nil;
static BOOL g_alreadyRunning = NO;
static NSHashTable<CraBrowser*>* g_allBrowsers = nil;

static NSString* NSStringFromCef(const CefString& s) {
    std::string utf8 = s.ToString();
    NSString* r = [[NSString alloc] initWithBytes:utf8.data() length:utf8.size() encoding:NSUTF8StringEncoding];
    return r ?: @"";
}

static CefString CefStringFromNS(NSString* s) {
    return CefString(std::string(s.UTF8String ?: ""));
}

enum CraMenuCommand {
    kMenuOpenLinkInNewTab = MENU_ID_USER_FIRST + 1,
    kMenuOpenLinkInBackgroundTab,
    kMenuCopyLink,
    kMenuInspectElement,
    kMenuOpenImageInNewTab,
    kMenuCopyImageURL,
};

// MARK: - Downloads

@implementation CraDownloadInfo
@end

// MARK: - CraBrowser private interface

class CraClient;

@interface CraBrowser ()
@property (nonatomic, strong) NSView* containerView;
@property (nonatomic, copy) NSString* currentURL;
@property (nonatomic, copy) NSString* currentTitle;
@property (nonatomic) BOOL isLoading;
@property (nonatomic) BOOL canGoBack;
@property (nonatomic) BOOL canGoForward;
@property (nonatomic) BOOL isCreated;
@property (nonatomic) BOOL isClosed;
- (void)adoptBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)browserClosed;
- (CefRefPtr<CefBrowser>)cefBrowser;
- (CefRefPtr<CefClient>)cefClient;
- (void)createNow;
@end

// MARK: - CEF app

class CraApp : public CefApp, public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    void OnBeforeCommandLineProcessing(const CefString& process_type,
                                       CefRefPtr<CefCommandLine> command_line) override {
        if (!process_type.empty()) return;
        // Avoid the "wants to use your confidential information stored in
        // Chromium Safe Storage" keychain prompt. Cookies are still encrypted,
        // just with a key that is not in the user's keychain.
        command_line->AppendSwitch("use-mock-keychain");
        command_line->AppendSwitchWithValue("autoplay-policy", "document-user-activation-required");
    }

    // Another Cra process started (LaunchServices, `open -n`). Chromium's
    // process singleton hands its command line to us. Without this CEF opens
    // a stock Chrome-style window.
    bool OnAlreadyRunningAppRelaunch(CefRefPtr<CefCommandLine> command_line,
                                     const CefString& current_directory) override {
        CEF_REQUIRE_UI_THREAD();
        std::vector<CefString> args;
        command_line->GetArguments(args);
        NSMutableArray<NSString*>* urls = [NSMutableArray array];
        for (const auto& a : args) {
            NSString* str = NSStringFromCef(a);
            if ([str hasPrefix:@"http://"] || [str hasPrefix:@"https://"] || [str hasPrefix:@"cra://"] || [str hasPrefix:@"file://"]) {
                [urls addObject:str];
            }
        }
        if (g_relaunchHandler) g_relaunchHandler(urls);
        return true;
    }

    void OnContextInitialized() override {
        CEF_REQUIRE_UI_THREAD();
        g_contextInitialized = true;
        NSArray<CraBrowser*>* pending = [g_pendingCreation copy];
        [g_pendingCreation removeAllObjects];
        for (CraBrowser* b in pending) {
            [b createNow];
        }
    }

private:
    IMPLEMENT_REFCOUNTING(CraApp);
};

// MARK: - Favicon download

class FaviconCallback : public CefDownloadImageCallback {
public:
    explicit FaviconCallback(CraBrowser* owner) : owner_(owner) {}

    void OnDownloadImageFinished(const CefString& image_url, int http_status_code,
                                 CefRefPtr<CefImage> image) override {
        CraBrowser* owner = owner_;
        if (!owner || !image || image->IsEmpty()) return;
        int w = 0, h = 0;
        CefRefPtr<CefBinaryValue> png = image->GetAsPNG(2.0f, true, w, h);
        if (!png || png->GetSize() == 0) png = image->GetAsPNG(1.0f, true, w, h);
        if (!png || png->GetSize() == 0) return;
        size_t n = png->GetSize();
        std::vector<uint8_t> bytes(n);
        png->GetData(bytes.data(), n, 0);
        NSData* data = [NSData dataWithBytes:bytes.data() length:n];
        NSImage* img = [[NSImage alloc] initWithData:data];
        if (!img) return;
        [owner.delegate browser:owner didLoadFavicon:img forURL:NSStringFromCef(image_url)];
    }

private:
    __weak CraBrowser* owner_;
    IMPLEMENT_REFCOUNTING(FaviconCallback);
};

// MARK: - DevTools client (minimal, just keeps the live count honest)

class DevToolsClient : public CefClient, public CefLifeSpanHandler, public CefLoadHandler, public CefDisplayHandler {
public:
    DevToolsClient(NSRect frame, CraBrowser* owner, NSView* host) : frame_(frame), owner_(owner), host_(host) {}
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

    // Docked mode. CEF runs the frontend with can_dock=false (Chrome's docked
    // variant reserves a page placeholder and loses the target in CEF), which
    // hides Chrome's close button, so a close button is added to the main
    // toolbar; it and closeWindow() come back to us as a console message.
    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
        if (!host_ || !frame->IsMain()) return;
        std::string url = frame->GetURL().ToString();
        if (url.rfind("devtools://", 0) != 0) return;
        std::string js =
            "(function(){var h=window.InspectorFrontendHost;if(h){h.closeWindow=function(){console.log('__cra_devtools_close');};}"
            "function find(root,sel){var r=root.querySelector(sel);if(r)return r;var all=root.querySelectorAll('*');"
            "for(var i=0;i<all.length;i++){if(all[i].shadowRoot){var f=find(all[i].shadowRoot,sel);if(f)return f;}}return null;}"
            "function make(){var b=document.createElement('button');b.id='cra-close';b.title='Close DevTools';b.setAttribute('aria-label','Close DevTools');"
            "b.style.cssText='all:unset;box-sizing:border-box;cursor:pointer;width:26px;height:26px;margin:0 2px;display:inline-flex;align-items:center;justify-content:center;border-radius:4px;color:var(--icon-default,#9aa0a6)';"
            "b.innerHTML='<svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\"><path d=\"M2 2l10 10M12 2L2 12\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linecap=\"round\" fill=\"none\"/></svg>';"
            "b.onmouseenter=function(){b.style.background='var(--sys-color-state-hover-on-subtle,rgba(128,128,128,.25))';};"
            "b.onmouseleave=function(){b.style.background='';};b.onclick=function(){console.log('__cra_devtools_close');};return b;}"
            "function install(){if(find(document,'#cra-close'))return true;var bar=find(document,'.tabbed-pane-right-toolbar');"
            "if(!bar||!bar.parentNode)return false;var b=make();b.style.alignSelf='center';b.style.margin='0 4px 0 2px';b.style.order='9999';"
            "bar.parentNode.appendChild(b);return true;}"
            "var n=0;var t=setInterval(function(){if(install()){clearInterval(t);return;}if(++n>60){clearInterval(t);"
            "var b=make();b.style.position='fixed';b.style.top='1px';b.style.right='4px';b.style.zIndex='2147483647';document.body.appendChild(b);}},150);})();";
        frame->ExecuteJavaScript(js, frame->GetURL(), 0);
    }

    bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level, const CefString& message,
                          const CefString& source, int line) override {
        if (message.ToString() == "__cra_devtools_close") {
            if (CraBrowser* o = owner_) [o closeDevTools];
            return true;
        }
        return false;
    }
    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        g_liveBrowsers++;
        NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
        if (host_) {
            // Docked mode: CEF owns a hidden Alloy window; the shell attaches it
            // as a child window over the dock area. (A child *browser* for
            // DevTools trips a CHECK in CEF 154, and re-parenting the view is
            // unsafe because CEF closes `view.window` when DevTools closes.)
            if (CraBrowser* o = owner_) [o.delegate browser:o didCreateDevToolsView:view];
            return;
        }
        // CEF sizes its own DevTools window with a default; put it where we want it.
        NSWindow* w = view.window;
        if (w && frame_.size.width > 0) {
            [w setFrame:frame_ display:YES];
            [w makeKeyAndOrderFront:nil];
        }
    }
    bool DoClose(CefRefPtr<CefBrowser> browser) override { return false; }
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        g_liveBrowsers--;
        if (CraBrowser* o = owner_) [o.delegate browserDidCloseDevTools:o];
        if (g_quitting && g_liveBrowsers <= 0) CefQuitMessageLoop();
    }
private:
    NSRect frame_;
    __weak CraBrowser* owner_;
    NSView* host_;
    IMPLEMENT_REFCOUNTING(DevToolsClient);
};

// MARK: - Browser client

class CraClient : public CefClient,
                  public CefLifeSpanHandler,
                  public CefLoadHandler,
                  public CefDisplayHandler,
                  public CefRequestHandler,
                  public CefContextMenuHandler,
                  public CefKeyboardHandler,
                  public CefDownloadHandler,
                  public CefFocusHandler,
                  public CefPermissionHandler {
public:
    explicit CraClient(CraBrowser* owner) : owner_(owner) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

    // Life span -----------------------------------------------------------

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        g_liveBrowsers++;
        if (CraBrowser* o = owner_) [o adoptBrowser:browser];
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override { return false; }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        g_liveBrowsers--;
        if (CraBrowser* o = owner_) [o browserClosed];
        if (g_quitting && g_liveBrowsers <= 0) CefQuitMessageLoop();
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                       const CefString& target_url, const CefString& target_frame_name,
                       WindowOpenDisposition target_disposition, bool user_gesture,
                       const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info, bool* no_javascript_access) override {
        CEF_REQUIRE_UI_THREAD();
        CraBrowser* o = owner_;
        if (!o || !o.delegate) return true;
        BOOL background = (target_disposition == CEF_WOD_NEW_BACKGROUND_TAB);
        CraBrowser* host = [o.delegate browser:o popupHostForURL:NSStringFromCef(target_url) inBackground:background];
        if (!host) return true;  // blocked
        NSView* view = host.containerView;
        NSRect b = view.bounds;
        windowInfo.SetAsChild((__bridge void*)view, CefRect(0, 0, (int)b.size.width, (int)b.size.height));
        if (g_useChromeStyle) windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
        client = [host cefClient];
        return false;  // allow, CEF creates it into our view with the opener kept
    }

    // Load ----------------------------------------------------------------

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack,
                              bool canGoForward) override {
        CraBrowser* o = owner_;
        if (!o) return;
        o.isLoading = isLoading;
        o.canGoBack = canGoBack;
        o.canGoForward = canGoForward;
        [o.delegate browser:o didChangeLoading:isLoading canGoBack:canGoBack canGoForward:canGoForward];
    }

    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
        if (!frame->IsMain()) return;
        CraBrowser* o = owner_;
        if (!o) return;
        [o.delegate browser:o didFinishLoadingURL:NSStringFromCef(frame->GetURL()) title:o.currentTitle
                 statusCode:httpStatusCode];
        // Ask the page for its theme colour; the answer comes back through OnConsoleMessage.
        frame->ExecuteJavaScript(
            "(function(){function probe(){try{var c='';var ms=document.querySelectorAll('meta[name=\"theme-color\"]');"
            "for(var i=0;i<ms.length;i++){if(!ms[i].getAttribute('media')){c=ms[i].getAttribute('content')||'';if(c)break;}}"
            "if(!c){c='__none__';}"
            "if(!c){var b=getComputedStyle(document.body).backgroundColor;if(b&&b!=='rgba(0, 0, 0, 0)'&&b!=='transparent'){c=b;}}"
            "if(!c){var h=getComputedStyle(document.documentElement).backgroundColor;if(h&&h!=='rgba(0, 0, 0, 0)'){c=h;}}"
            "if(c==='__none__'){console.log('__cra_theme:none');return;}"
            "var d=document.createElement('div');d.style.color=c;document.body.appendChild(d);"
            "var rgb=getComputedStyle(d).color;d.remove();console.log('__cra_theme:'+rgb);}catch(e){}}"
            "probe();setTimeout(probe,1500);})();",
            frame->GetURL(), 0);
    }

    bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level, const CefString& message,
                          const CefString& source, int line) override {
        std::string m = message.ToString();
        const std::string prefix = "__cra_theme:";
        if (m.compare(0, prefix.size(), prefix) != 0) return false;
        CraBrowser* o = owner_;
        if (!o) return true;
        std::string rgb = m.substr(prefix.size());  // "rgb(r, g, b)", "rgba(…)" or "none"
        int r = 0, g = 0, b = 0; float a = 1;
        NSString* hex = @"";
        if (rgb == "none") hex = @"none";
        if (sscanf(rgb.c_str(), "rgba(%d, %d, %d, %f)", &r, &g, &b, &a) == 4 || sscanf(rgb.c_str(), "rgb(%d, %d, %d)", &r, &g, &b) == 3) {
            if (a > 0.5f) hex = [NSString stringWithFormat:@"#%02X%02X%02X", r, g, b];
        }
        [o.delegate browser:o didReportThemeColor:hex];
        return true;  // keep it out of the console
    }

    void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode errorCode,
                     const CefString& errorText, const CefString& failedUrl) override {
        if ((int)errorCode == -3 /* ERR_ABORTED */ || !frame->IsMain()) return;
        std::string url = failedUrl.ToString();
        std::string err = errorText.ToString();
        std::string html =
            "<!doctype html><html><head><meta charset=utf-8><title>Can’t reach this page</title>"
            "<style>html{background:#f5f5f7;color:#1d1d1f;font:15px -apple-system,system-ui}"
            "@media(prefers-color-scheme:dark){html{background:#1c1c1e;color:#f5f5f7}}"
            "body{display:flex;min-height:90vh;align-items:center;justify-content:center;margin:0}"
            "main{max-width:420px;padding:32px}h1{font-size:22px;margin:0 0 8px}p{opacity:.7;margin:0 0 6px}"
            "code{font:13px ui-monospace,Menlo;opacity:.6;word-break:break-all}</style></head><body><main>"
            "<h1>Cra can’t reach this page</h1><p>" + err + " (" + std::to_string((int)errorCode) + ")</p>"
            "<code>" + url + "</code></main></body></html>";
        CefString encoded = CefBase64Encode(html.data(), html.size());
        frame->LoadURL("data:text/html;base64," + encoded.ToString());
    }

    // Display -------------------------------------------------------------

    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override {
        if (!frame->IsMain()) return;
        CraBrowser* o = owner_;
        if (!o) return;
        o.currentURL = NSStringFromCef(url);
        [o.delegate browser:o didChangeURL:o.currentURL];
    }

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
        CraBrowser* o = owner_;
        if (!o) return;
        o.currentTitle = NSStringFromCef(title);
        [o.delegate browser:o didChangeTitle:o.currentTitle];
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& icon_urls) override {
        CraBrowser* o = owner_;
        if (!o || icon_urls.empty()) return;
        // Prefer PNG/ICO-looking URLs over SVG, which CEF can't decode.
        CefString chosen = icon_urls.front();
        for (const auto& u : icon_urls) {
            std::string s = u.ToString();
            if (s.find(".svg") == std::string::npos) { chosen = u; break; }
        }
        std::string chosenStr = chosen.ToString();
        if (chosenStr == last_icon_url_) return;
        last_icon_url_ = chosenStr;
        browser->GetHost()->DownloadImage(chosen, true, 64, false, new FaviconCallback(o));
    }

    void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser, bool fullscreen) override {
        if (CraBrowser* o = owner_) [o.delegate browser:o didChangeFullscreen:fullscreen];
    }

    void OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString& value) override {
        if (CraBrowser* o = owner_) [o.delegate browser:o didChangeStatusMessage:NSStringFromCef(value)];
    }

    void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
        if (CraBrowser* o = owner_) [o.delegate browser:o didChangeProgress:progress];
    }

    // Request -------------------------------------------------------------

    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& target_url,
                          WindowOpenDisposition target_disposition, bool user_gesture) override {
        CraBrowser* o = owner_;
        if (!o) return false;
        BOOL background = (target_disposition == CEF_WOD_NEW_BACKGROUND_TAB);
        [o.delegate browser:o requestsNewTabWithURL:NSStringFromCef(target_url) inBackground:background];
        return true;
    }

    // Context menu --------------------------------------------------------

    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model) override {
        size_t index = 0;
        if (!params->GetLinkUrl().empty()) {
            model->InsertItemAt(index++, kMenuOpenLinkInNewTab, "Open Link in New Tab");
            model->InsertItemAt(index++, kMenuOpenLinkInBackgroundTab, "Open Link in Background Tab");
            model->InsertItemAt(index++, kMenuCopyLink, "Copy Link");
            model->InsertSeparatorAt(index++);
        }
        if ((params->GetTypeFlags() & CM_TYPEFLAG_MEDIA) && !params->GetSourceUrl().empty()) {
            model->InsertItemAt(index++, kMenuOpenImageInNewTab, "Open Image in New Tab");
            model->InsertItemAt(index++, kMenuCopyImageURL, "Copy Image Address");
            model->InsertSeparatorAt(index++);
        }
        if (model->GetCount() > 0) model->AddSeparator();
        model->AddItem(kMenuInspectElement, "Inspect Element");
    }

    bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefContextMenuParams> params, int command_id,
                              EventFlags event_flags) override {
        CraBrowser* o = owner_;
        if (!o) return false;
        switch (command_id) {
            case kMenuOpenLinkInNewTab:
                [o.delegate browser:o requestsNewTabWithURL:NSStringFromCef(params->GetLinkUrl()) inBackground:NO];
                return true;
            case kMenuOpenLinkInBackgroundTab:
                [o.delegate browser:o requestsNewTabWithURL:NSStringFromCef(params->GetLinkUrl()) inBackground:YES];
                return true;
            case kMenuOpenImageInNewTab:
                [o.delegate browser:o requestsNewTabWithURL:NSStringFromCef(params->GetSourceUrl()) inBackground:NO];
                return true;
            case kMenuCopyLink:
            case kMenuCopyImageURL: {
                NSString* s = NSStringFromCef(command_id == kMenuCopyLink ? params->GetUnfilteredLinkUrl()
                                                                           : params->GetSourceUrl());
                NSPasteboard* pb = [NSPasteboard generalPasteboard];
                [pb clearContents];
                [pb setString:s forType:NSPasteboardTypeString];
                return true;
            }
            case kMenuInspectElement:
                [o showDevToolsInspectingPoint:NSMakePoint(params->GetXCoord(), params->GetYCoord())];
                return true;
            default:
                return false;
        }
    }

    // Keyboard ------------------------------------------------------------

    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle os_event,
                       bool* is_keyboard_shortcut) override {
        if (event.type != KEYEVENT_RAWKEYDOWN || !os_event) return false;
        CraBrowser* o = owner_;
        if (!o) return false;
        NSEvent* e = (__bridge NSEvent*)os_event;
        if (e.type != NSEventTypeKeyDown) return false;  // modifier-only presses arrive as flagsChanged
        return [o.delegate browser:o handleKeyEvent:e] ? true : false;
    }

    bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle os_event) override {
        if (event.type != KEYEVENT_RAWKEYDOWN || !os_event) return false;
        CraBrowser* o = owner_;
        if (!o) return false;
        NSEvent* e = (__bridge NSEvent*)os_event;
        if (e.type != NSEventTypeKeyDown) return false;
        return [o.delegate browser:o handleUnhandledKeyEvent:e] ? true : false;
    }

    // Downloads -----------------------------------------------------------

    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                          const CefString& suggested_name, CefRefPtr<CefBeforeDownloadCallback> callback) override {
        NSString* name = NSStringFromCef(suggested_name);
        if (name.length == 0) name = @"download";
        NSString* dir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
        NSString* path = [dir stringByAppendingPathComponent:name];
        NSFileManager* fm = [NSFileManager defaultManager];
        NSString* base = [name stringByDeletingPathExtension];
        NSString* ext = [name pathExtension];
        int n = 1;
        while ([fm fileExistsAtPath:path]) {
            NSString* candidate = ext.length ? [NSString stringWithFormat:@"%@ (%d).%@", base, n, ext]
                                             : [NSString stringWithFormat:@"%@ (%d)", base, n];
            path = [dir stringByAppendingPathComponent:candidate];
            n++;
        }
        callback->Continue(CefStringFromNS(path), false);
        return true;
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        CraBrowser* o = owner_;
        if (!o) return;
        CraDownloadInfo* info = [CraDownloadInfo new];
        info.identifier = item->GetId();
        info.url = NSStringFromCef(item->GetURL());
        info.fullPath = NSStringFromCef(item->GetFullPath());
        info.suggestedName = NSStringFromCef(item->GetSuggestedFileName());
        info.receivedBytes = item->GetReceivedBytes();
        info.totalBytes = item->GetTotalBytes();
        info.percent = item->GetPercentComplete();
        if (item->IsComplete()) info.state = CraDownloadStateComplete;
        else if (item->IsCanceled()) info.state = CraDownloadStateCancelled;
        else if (item->IsInterrupted()) info.state = CraDownloadStateInterrupted;
        else info.state = CraDownloadStateInProgress;
        [o.delegate browser:o didUpdateDownload:info];
    }

    // Focus ---------------------------------------------------------------

    void OnGotFocus(CefRefPtr<CefBrowser> browser) override {
        if (CraBrowser* o = owner_) [o.delegate browserDidReceiveFocus:o];
    }

    // Permissions ---------------------------------------------------------

    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                        const CefString& requesting_origin, uint32_t requested_permissions,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        CraBrowser* o = owner_;
        if (!o || !o.delegate) return false;
        NSUInteger kinds = 0;
        if (requested_permissions & (CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE)) kinds |= 1;
        if (requested_permissions & (CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) kinds |= 2;
        CefRefPtr<CefMediaAccessCallback> cb = callback;
        uint32_t requested = requested_permissions;
        [o.delegate browser:o requestsPermissionForOrigin:NSStringFromCef(requesting_origin) kinds:kinds
                 completion:^(BOOL allowed) {
            cb->Continue(allowed ? requested : CEF_MEDIA_PERMISSION_NONE);
        }];
        return true;
    }

    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                                const CefString& requesting_origin, uint32_t requested_permissions,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        CraBrowser* o = owner_;
        if (!o || !o.delegate) return false;
        NSUInteger kinds = 0;
        if (requested_permissions & (CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM)) kinds |= 1;
        if (requested_permissions & CEF_PERMISSION_TYPE_MIC_STREAM) kinds |= 2;
        if (requested_permissions & CEF_PERMISSION_TYPE_GEOLOCATION) kinds |= 4;
        if (requested_permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) kinds |= 8;
        if (kinds == 0) kinds = 16;
        CefRefPtr<CefPermissionPromptCallback> cb = callback;
        [o.delegate browser:o requestsPermissionForOrigin:NSStringFromCef(requesting_origin) kinds:kinds
                 completion:^(BOOL allowed) {
            cb->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
        }];
        return true;
    }

private:
    __weak CraBrowser* owner_;
    std::string last_icon_url_;
    IMPLEMENT_REFCOUNTING(CraClient);
};

// MARK: - CraBrowser

@implementation CraBrowser {
    CefRefPtr<CefBrowser> _browser;
    CefRefPtr<CraClient> _client;
    NSString* _pendingURL;
    BOOL _pendingFocus;
    BOOL _isPopupHost;
}

- (instancetype)initWithFrame:(NSRect)frame url:(NSString*)url delegate:(id<CraBrowserDelegate>)delegate {
    self = [super init];
    if (!self) return nil;
    _delegate = delegate;
    _currentURL = url ?: @"";
    _currentTitle = @"";
    _pendingURL = url;
    _isPopupHost = (url == nil);
    _containerView = [[NSView alloc] initWithFrame:frame];
    _containerView.wantsLayer = YES;
    _containerView.autoresizesSubviews = YES;
    _client = new CraClient(self);
    if (!g_allBrowsers) g_allBrowsers = [NSHashTable weakObjectsHashTable];
    [g_allBrowsers addObject:self];
    if (!_isPopupHost) {
        if (g_contextInitialized) {
            [self createNow];
        } else {
            if (!g_pendingCreation) g_pendingCreation = [NSMutableArray array];
            [g_pendingCreation addObject:self];
        }
    }
    return self;
}

- (void)createNow {
    if (_isClosed || _browser) return;
    CefWindowInfo windowInfo;
    NSRect b = _containerView.bounds;
    windowInfo.SetAsChild((__bridge void*)_containerView,
                          CefRect(0, 0, (int)MAX(b.size.width, 1), (int)MAX(b.size.height, 1)));
    if (g_useChromeStyle) windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    CefBrowserSettings settings;
    CefBrowserHost::CreateBrowser(windowInfo, _client, CefStringFromNS(_pendingURL ?: @"about:blank"), settings,
                                  nullptr, nullptr);
}

- (CefRefPtr<CefBrowser>)cefBrowser { return _browser; }
- (CefRefPtr<CefClient>)cefClient { return _client; }

- (void)adoptBrowser:(CefRefPtr<CefBrowser>)browser {
    _browser = browser;
    self.isCreated = YES;
    if (_pendingFocus) {
        _pendingFocus = NO;
        browser->GetHost()->SetFocus(true);
    }
}

- (void)browserClosed {
    _browser = nullptr;
    self.isClosed = YES;
    [g_allBrowsers removeObject:self];
    id<CraBrowserDelegate> d = self.delegate;
    [d browserDidClose:self];
}

- (BOOL)hasDevTools { return _browser ? _browser->GetHost()->HasDevTools() : NO; }

- (void)loadURL:(NSString*)url {
    if (_browser) {
        _browser->GetMainFrame()->LoadURL(CefStringFromNS(url));
    } else {
        _pendingURL = url;
    }
}

- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)reloadIgnoringCache { if (_browser) _browser->ReloadIgnoreCache(); }
- (void)stopLoading { if (_browser) _browser->StopLoad(); }

- (void)setFocused:(BOOL)focused {
    if (_browser) _browser->GetHost()->SetFocus(focused);
    else if (focused) _pendingFocus = YES;
}

- (void)showDevToolsInspectingPoint:(NSPoint)point {
    if (!_browser) return;
    if (_browser->GetHost()->HasDevTools()) {
        _browser->GetHost()->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(),
                                          CefPoint((int)point.x, (int)point.y));
        return;
    }
    NSView* host = [self.delegate devToolsHostViewForBrowser:self];
    CefWindowInfo windowInfo;
    NSRect target = NSZeroRect;
    if (host) {
        NSRect b = host.bounds;
        windowInfo.bounds = CefRect(0, 0, (int)MAX(b.size.width, 1), (int)MAX(b.size.height, 1));
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        windowInfo.hidden = true;
        CefString(&windowInfo.window_name) = "DevTools";
    } else {
        // No parent view: CEF creates its own top-level DevTools window (what
        // cefclient does on macOS); we resize it once it exists.
        NSWindow* w = _containerView.window;
        NSRect f = w ? w.frame : NSMakeRect(100, 100, 1100, 760);
        CGFloat width = MIN(1100, MAX(700, f.size.width * 0.8));
        CGFloat height = MIN(800, MAX(500, f.size.height * 0.8));
        target = NSMakeRect(NSMidX(f) - width / 2 + 40, NSMidY(f) - height / 2 - 20, width, height);
        CefString(&windowInfo.window_name) = "DevTools";
    }
    CefBrowserSettings settings;
    _browser->GetHost()->ShowDevTools(windowInfo, new DevToolsClient(target, self, host), settings,
                                      CefPoint((int)point.x, (int)point.y));
}

- (void)showDevTools { [self showDevToolsInspectingPoint:NSZeroPoint]; }
- (void)closeDevTools { if (_browser) _browser->GetHost()->CloseDevTools(); }

- (double)zoomLevel { return _browser ? _browser->GetHost()->GetZoomLevel() : 0; }
- (void)setZoomLevel:(double)level { if (_browser) _browser->GetHost()->SetZoomLevel(level); }

- (void)findText:(NSString*)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)findNext {
    if (_browser) _browser->GetHost()->Find(CefStringFromNS(text), forward, matchCase, findNext);
}
- (void)stopFinding:(BOOL)clearSelection { if (_browser) _browser->GetHost()->StopFinding(clearSelection); }
- (void)setAudioMuted:(BOOL)muted { if (_browser) _browser->GetHost()->SetAudioMuted(muted); }
- (void)print { if (_browser) _browser->GetHost()->Print(); }
- (void)viewSource { if (_browser) _browser->GetMainFrame()->ViewSource(); }
- (void)executeJavaScript:(NSString*)script {
    if (_browser) _browser->GetMainFrame()->ExecuteJavaScript(CefStringFromNS(script), _browser->GetMainFrame()->GetURL(), 0);
}
- (void)notifyMoveOrResizeStarted { if (_browser) _browser->GetHost()->NotifyMoveOrResizeStarted(); }

- (void)close {
    if (_isClosed) return;
    if (_browser) {
        _browser->GetHost()->CloseBrowser(true);
    } else {
        // Never created; drop it from the pending list and report closed.
        [g_pendingCreation removeObject:self];
        [self browserClosed];
    }
}

@end

// MARK: - Runtime

@implementation CraCEFRuntime

+ (BOOL)initializeWithCachePath:(NSString*)cachePath
               userAgentProduct:(NSString*)product
                        logPath:(NSString*)logPath
                 useChromeStyle:(BOOL)useChromeStyle {
    if (g_libraryLoader) return YES;
    g_useChromeStyle = useChromeStyle;
    g_libraryLoader = new CefScopedLibraryLoader();
    if (!g_libraryLoader->LoadInMain()) {
        NSLog(@"CraCEF: failed to load Chromium Embedded Framework");
        return NO;
    }
    // Make sure the CefAppProtocol NSApplication exists before CefInitialize.
    [CraApplication sharedApplication];

    CefMainArgs mainArgs(*_NSGetArgc(), *_NSGetArgv());
    CefSettings settings;
    settings.no_sandbox = true;
    CefString(&settings.cache_path) = CefStringFromNS(cachePath);
    CefString(&settings.root_cache_path) = CefStringFromNS(cachePath);
    settings.persist_session_cookies = true;
    CefString(&settings.user_agent_product) = CefStringFromNS(product);
    CefString(&settings.log_file) = CefStringFromNS(logPath);
    settings.log_severity = LOGSEVERITY_WARNING;
    settings.background_color = CefColorSetARGB(255, 255, 255, 255);

    CefRefPtr<CraApp> app(new CraApp());
    if (!CefInitialize(mainArgs, settings, app.get(), nullptr)) {
        int code = CefGetExitCode();
        g_alreadyRunning = (code == CEF_RESULT_CODE_NORMAL_EXIT_PROCESS_NOTIFIED);
        NSLog(@"CraCEF: CefInitialize failed (exit code %d%@)", code, g_alreadyRunning ? @", another instance is running" : @"");
        return NO;
    }
    return YES;
}

+ (BOOL)anotherInstanceWasNotified { return g_alreadyRunning; }
+ (void)setRelaunchHandler:(void (^)(NSArray<NSString*>*))handler { g_relaunchHandler = [handler copy]; }

+ (void)runMessageLoop { CefRunMessageLoop(); }
+ (void)quitMessageLoop { CefQuitMessageLoop(); }
+ (void)shutdown { CefShutdown(); }

+ (void)closeAllBrowsersAndQuit {
    g_quitting = true;
    NSArray<CraBrowser*>* all = [g_allBrowsers allObjects];
    if (all.count == 0 || g_liveBrowsers <= 0) {
        CefQuitMessageLoop();
        return;
    }
    for (CraBrowser* b in all) [b close];
}

+ (NSInteger)liveBrowserCount { return g_liveBrowsers; }
+ (NSString*)chromiumVersion {
    return [NSString stringWithFormat:@"%d.%d.%d.%d", CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR,
            CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
}
+ (NSString*)cefVersion { return @CEF_VERSION; }

@end

// MARK: - NSApplication subclass

@interface CraApplication () <CefAppProtocol>
@end

@implementation CraApplication {
    BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent { _handlingSendEvent = handlingSendEvent; }

// Chrome's rule: when a web view has focus, ⌘-shortcuts go to the page
// first and only reach the menu bar if the page leaves them alone (so ⌘F in
// Google Docs or ⌘← in a text field keep working). Reserved shortcuts are
// taken in OnPreKeyEvent, the rest in OnKeyEvent.
- (void)sendEvent:(NSEvent*)event {
    CefScopedSendingEvent sendingEventScoper;
    if (event.type == NSEventTypeKeyDown && (event.modifierFlags & NSEventModifierFlagCommand)) {
        NSWindow* key = self.keyWindow;
        NSResponder* fr = key.firstResponder;
        if ([fr isKindOfClass:[NSView class]]) {
            NSView* v = (NSView*)fr;
            for (CraBrowser* b in [g_allBrowsers allObjects]) {
                if ([v isDescendantOf:b.containerView]) {
                    [key sendEvent:event];
                    return;
                }
            }
        }
    }
    [super sendEvent:event];
}

// Cmd-Q, the Dock, logout: give the delegate a say, then tear Chromium down
// in order (browsers first, then the message loop, then CefShutdown in main).
- (void)terminate:(id)sender {
    id<NSApplicationDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(applicationShouldTerminate:)]) {
        NSApplicationTerminateReply reply = [delegate applicationShouldTerminate:self];
        if (reply == NSTerminateCancel) return;
    }
    [CraCEFRuntime closeAllBrowsersAndQuit];
}

@end
