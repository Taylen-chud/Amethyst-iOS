#import <UIKit/UIKit.h>

@interface CurseForgeManualDownloadViewController : UIViewController

- (instancetype)initWithDownloads:(NSArray<NSDictionary *> *)downloads completion:(void (^)(void))completion;

@end
