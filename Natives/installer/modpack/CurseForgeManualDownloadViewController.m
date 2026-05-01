#include <CommonCrypto/CommonDigest.h>

#import <WebKit/WebKit.h>
#import "CurseForgeManualDownloadViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface CurseForgeManualDownloadViewController ()<WKNavigationDelegate, WKUIDelegate>
@property(nonatomic) NSArray<NSDictionary *> *downloads;
@property(nonatomic, copy) void (^completion)(void);
@property(nonatomic) NSString *introTitle;
@property(nonatomic) NSString *introMessage;
@property(nonatomic) WKWebView *webView;
@property(nonatomic) UIProgressView *progressView;
@property(nonatomic) NSURLSessionDownloadTask *downloadTask;
@property(nonatomic) NSUInteger currentIndex;
@property(nonatomic) BOOL shownIntro;
@property(nonatomic) BOOL preparingDownload;
@property(nonatomic) BOOL finished;
@end

@implementation CurseForgeManualDownloadViewController

- (instancetype)initWithDownloads:(NSArray<NSDictionary *> *)downloads completion:(void (^)(void))completion {
    return [self initWithDownloads:downloads
        introTitle:@"CurseForge Downloads"
        introMessage:@"We are downloading the final few mods. Please do not close the app or this webpage."
        completion:completion];
}

- (instancetype)initWithDownloads:(NSArray<NSDictionary *> *)downloads
    introTitle:(NSString *)introTitle
    introMessage:(NSString *)introMessage
    completion:(void (^)(void))completion {
    self = [super init];
    self.downloads = downloads ?: @[];
    self.introTitle = introTitle ?: @"CurseForge Downloads";
    self.introMessage = introMessage ?: @"We are downloading the final few mods. Please do not close the app or this webpage.";
    self.completion = completion;
    self.modalPresentationStyle = UIModalPresentationFormSheet;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    [self.view addSubview:self.webView];

    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.frame = CGRectMake(0, self.view.safeAreaInsets.top, self.view.bounds.size.width, 2);
    self.progressView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.progressView];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:localize(@"Cancel", nil)
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(actionCancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Skip"
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(actionSkip)];

    [self loadCurrentDownload];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.shownIntro || self.downloads.count == 0) {
        return;
    }
    self.shownIntro = YES;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.introTitle
        message:self.introMessage
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSDictionary *)currentDownload {
    if (self.currentIndex >= self.downloads.count) {
        return nil;
    }
    NSDictionary *download = self.downloads[self.currentIndex];
    return [download isKindOfClass:NSDictionary.class] ? download : nil;
}

- (NSString *)stagingDestinationPathForDownload:(NSDictionary *)download {
    NSString *path = download[@"destinationPath"];
    return [path isKindOfClass:NSString.class] && path.length > 0 ? path : nil;
}

- (NSString *)finalDestinationPathForDownload:(NSDictionary *)download {
    NSString *path = download[@"finalDestinationPath"];
    if ([path isKindOfClass:NSString.class] && path.length > 0) {
        return path;
    }
    return [self stagingDestinationPathForDownload:download];
}

- (void)loadCurrentDownload {
    NSDictionary *download = [self currentDownload];
    if (!download) {
        [self finishManualDownloads];
        return;
    }

    NSString *title = download[@"title"];
    if (![title isKindOfClass:NSString.class] || title.length == 0) {
        title = download[@"fileName"];
    }
    if (![title isKindOfClass:NSString.class] || title.length == 0) {
        title = @"CurseForge File";
    }
    self.title = [NSString stringWithFormat:@"%lu/%lu %@", (unsigned long)self.currentIndex + 1, (unsigned long)self.downloads.count, title];

    NSString *urlString = download[@"url"];
    NSURL *url = [urlString isKindOfClass:NSString.class] ? [NSURL URLWithString:urlString] : nil;
    if (!url) {
        [self showDownloadError:[NSString stringWithFormat:@"Missing manual download page for %@.", title]];
        return;
    }

    self.progressView.progress = 0;
    self.navigationItem.rightBarButtonItem.enabled = YES;
    [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (BOOL)shouldHandleDownloadURL:(NSURL *)url suggestedFilename:(NSString *)suggestedFilename MIMEType:(NSString *)MIMEType {
    NSDictionary *download = [self currentDownload];
    NSString *expectedFileName = download[@"fileName"];
    if (![expectedFileName isKindOfClass:NSString.class] || expectedFileName.length == 0) {
        expectedFileName = [self finalDestinationPathForDownload:download].lastPathComponent;
    }

    NSString *urlFileName = url.lastPathComponent;
    if ([expectedFileName isEqualToString:urlFileName] || [expectedFileName isEqualToString:suggestedFilename]) {
        return YES;
    }

    NSString *expectedExtension = expectedFileName.pathExtension.lowercaseString;
    NSString *urlExtension = url.pathExtension.lowercaseString;
    NSString *suggestedExtension = suggestedFilename.pathExtension.lowercaseString;
    if (expectedExtension.length > 0 &&
        ([expectedExtension isEqualToString:urlExtension] || [expectedExtension isEqualToString:suggestedExtension])) {
        return YES;
    }

    NSString *lowerMIMEType = MIMEType.lowercaseString;
    if ([expectedExtension isEqualToString:@"jar"]) {
        return [lowerMIMEType containsString:@"java-archive"] || [lowerMIMEType containsString:@"octet-stream"];
    }
    if ([expectedExtension isEqualToString:@"zip"]) {
        return [lowerMIMEType containsString:@"zip"] || [lowerMIMEType containsString:@"octet-stream"];
    }
    return NO;
}

- (void)startDownloadWithRequest:(NSURLRequest *)request {
    if (self.finished || self.downloadTask || self.preparingDownload) {
        return;
    }

    NSDictionary *download = [self currentDownload];
    NSString *destinationPath = [self stagingDestinationPathForDownload:download];
    NSString *finalDestinationPath = [self finalDestinationPathForDownload:download];
    if (![destinationPath isKindOfClass:NSString.class] || destinationPath.length == 0) {
        [self showDownloadError:@"Manual download destination is missing."];
        return;
    }

    self.preparingDownload = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.progressView.progress = 0.25;
    self.title = [NSString stringWithFormat:@"Downloading %@", finalDestinationPath.lastPathComponent ?: destinationPath.lastPathComponent];

    NSMutableURLRequest *downloadRequest = request.mutableCopy;
    [self.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        if (self.finished) {
            self.preparingDownload = NO;
            return;
        }
        NSURL *url = downloadRequest.URL;
        NSMutableArray<NSHTTPCookie *> *matchingCookies = [NSMutableArray new];
        for (NSHTTPCookie *cookie in cookies) {
            NSString *domain = [cookie.domain hasPrefix:@"."] ? [cookie.domain substringFromIndex:1] : cookie.domain;
            if ([url.host hasSuffix:domain]) {
                [matchingCookies addObject:cookie];
            }
        }
        NSDictionary *cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies:matchingCookies];
        for (NSString *header in cookieHeaders) {
            [downloadRequest setValue:cookieHeaders[header] forHTTPHeaderField:header];
        }
        [self beginDownloadWithRequest:downloadRequest destinationPath:destinationPath finalDestinationPath:finalDestinationPath];
    }];
}

- (void)beginDownloadWithRequest:(NSURLRequest *)request destinationPath:(NSString *)destinationPath finalDestinationPath:(NSString *)finalDestinationPath {
    self.preparingDownload = NO;
    __weak CurseForgeManualDownloadViewController *weakSelf = self;
    self.downloadTask = [NSURLSession.sharedSession downloadTaskWithRequest:request
    completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        CurseForgeManualDownloadViewController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.finished) {
            return;
        }
        NSError *storeError = error;
        if (!storeError) {
            storeError = [strongSelf storeDownloadedFile:location toPath:destinationPath finalPath:finalDestinationPath];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.downloadTask = nil;
            strongSelf.preparingDownload = NO;
            if (storeError) {
                [strongSelf showDownloadError:storeError.localizedDescription];
                return;
            }

            strongSelf.progressView.progress = 1;
            strongSelf.currentIndex++;
            [strongSelf loadCurrentDownload];
        });
    }];
    [self.downloadTask resume];
}

- (NSError *)storeDownloadedFile:(NSURL *)location toPath:(NSString *)destinationPath finalPath:(NSString *)finalDestinationPath {
    if (!location) {
        return [NSError errorWithDomain:@"CurseForgeManualDownload"
            code:2
            userInfo:@{NSLocalizedDescriptionKey: @"The downloaded file was not provided by the browser session."}];
    }

    NSError *error = nil;
    NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
    [NSFileManager.defaultManager createDirectoryAtURL:destinationURL.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES
        attributes:nil
        error:&error];
    if (error) {
        return error;
    }

    [NSFileManager.defaultManager removeItemAtURL:destinationURL error:nil];
    BOOL moved = [NSFileManager.defaultManager moveItemAtURL:location toURL:destinationURL error:&error];
    if (!moved) {
        return error;
    }

    NSString *validationPath = destinationPath;
    if ([finalDestinationPath isKindOfClass:NSString.class] &&
        finalDestinationPath.length > 0 &&
        ![finalDestinationPath isEqualToString:destinationPath]) {
        NSURL *finalURL = [NSURL fileURLWithPath:finalDestinationPath];
        [NSFileManager.defaultManager createDirectoryAtURL:finalURL.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES
            attributes:nil
            error:&error];
        if (error) {
            [NSFileManager.defaultManager removeItemAtPath:destinationPath error:nil];
            return error;
        }
        [NSFileManager.defaultManager removeItemAtURL:finalURL error:nil];
        if (![NSFileManager.defaultManager moveItemAtURL:destinationURL toURL:finalURL error:&error]) {
            [NSFileManager.defaultManager removeItemAtPath:destinationPath error:nil];
            return error;
        }
        validationPath = finalDestinationPath;
    }

    NSString *sha = [self currentDownload][@"sha"];
    if ([sha isKindOfClass:NSString.class] && sha.length > 0 && ![self validateSHA:sha forFile:validationPath]) {
        [NSFileManager.defaultManager removeItemAtPath:validationPath error:nil];
        return [NSError errorWithDomain:@"CurseForgeManualDownload"
            code:1
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"SHA1 mismatch for %@.", validationPath.lastPathComponent]}];
    }

    return nil;
}

- (BOOL)validateSHA:(NSString *)sha forFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        return NO;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }
    return [localSHA isEqualToString:sha];
}

- (void)showDownloadError:(NSString *)message {
    self.navigationItem.rightBarButtonItem.enabled = YES;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"Error", nil)
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Retry" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self loadCurrentDownload];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Skip" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        self.currentIndex++;
        [self loadCurrentDownload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)finishManualDownloads {
    self.finished = YES;
    [self dismissViewControllerAnimated:YES completion:self.completion];
}

- (void)actionSkip {
    self.currentIndex++;
    [self loadCurrentDownload];
}

- (void)actionCancel {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Skip CurseForge Downloads?"
        message:@"The install may be incomplete until the missing downloads are added."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Skip Remaining" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self.downloadTask cancel];
        [self finishManualDownloads];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if ([self shouldHandleDownloadURL:navigationAction.request.URL suggestedFilename:nil MIMEType:nil]) {
        [self startDownloadWithRequest:navigationAction.request];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    NSURLResponse *response = navigationResponse.response;
    if ([self shouldHandleDownloadURL:response.URL suggestedFilename:response.suggestedFilename MIMEType:response.MIMEType]) {
        [self startDownloadWithRequest:[NSURLRequest requestWithURL:response.URL]];
        decisionHandler(WKNavigationResponsePolicyCancel);
        return;
    }
    decisionHandler(WKNavigationResponsePolicyAllow);
}

- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
forNavigationAction:(WKNavigationAction *)navigationAction
windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (!navigationAction.targetFrame.isMainFrame) {
        [webView loadRequest:navigationAction.request];
    }
    return nil;
}

@end
