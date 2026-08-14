#import <UIKit/UIKit.h>

@class ModManagerStore;

@interface ModSearchViewController : UITableViewController<UISearchResultsUpdating>

- (instancetype)initWithStore:(ModManagerStore *)store;

@end
