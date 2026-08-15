#import <UIKit/UIKit.h>

@interface ModManagerViewController : UITableViewController<UISearchResultsUpdating>

- (instancetype)initWithProfileName:(NSString *)profileName profile:(NSMutableDictionary *)profile;

@end
