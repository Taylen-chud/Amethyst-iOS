#import <UIKit/UIKit.h>

@interface CurseForgeManualDownloadViewController : UIViewController

- (instancetype)initWithDownloads:(NSArray<NSDictionary *> *)downloads completion:(void (^)(void))completion;
- (instancetype)initWithDownloads:(NSArray<NSDictionary *> *)downloads
    introTitle:(NSString *)introTitle
    introMessage:(NSString *)introMessage
    completion:(void (^)(void))completion;

@end
