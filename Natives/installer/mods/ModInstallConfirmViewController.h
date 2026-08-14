#import <UIKit/UIKit.h>

@class ModManagerStore;

@interface ModInstallConfirmViewController : UITableViewController

- (instancetype)initWithStore:(ModManagerStore *)store
                         main:(NSDictionary *)mainFile
                     required:(NSArray<NSDictionary *> *)requiredFiles
                     optional:(NSArray<NSDictionary *> *)optionalFiles;

@end
