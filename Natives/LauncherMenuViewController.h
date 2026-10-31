#import <UIKit/UIKit.h>

#define sidebarNavController ((UINavigationController *)self.splitViewController.viewControllers[0])
#define sidebarViewController ((LauncherMenuViewController *)sidebarNavController.viewControllers[0])

@interface LauncherMenuViewController : UITableViewController

@property NSString *listPath;
@property(nonatomic) UIButton *accountButton;
@property(nonatomic) UIBarButtonItem *accountBtnItem;
@property(nonatomic) BOOL isInitialVc;

- (void)restoreHighlightedSelection;
- (void)selectAccount:(UIView *)sender;
- (void)updateAccountInfo;
- (UIBarButtonItem *)drawAccountButton;

@end
