#import "ModInstallConfirmViewController.h"
#import "ModManagerAPI.h"
#import "ModManagerStore.h"
#import "ModSearchViewController.h"
#import "UIKit+AFNetworking.h"
#import "utils.h"

@interface ModSearchViewController ()
@property(nonatomic) ModManagerStore *store;
@property(nonatomic) ModManagerAPI *api;
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) UISegmentedControl *sourceControl;
@property(nonatomic) NSArray<NSMutableDictionary *> *results;
@property(nonatomic) BOOL loading;
@property(nonatomic) NSUInteger searchGeneration;
@end

@implementation ModSearchViewController

- (instancetype)initWithStore:(ModManagerStore *)store {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.store = store;
    self.api = [ModManagerAPI new];
    self.results = @[];
    self.title = @"Add Mods";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.sourceControl = [[UISegmentedControl alloc] initWithItems:@[@"All", @"Modrinth", @"CurseForge"]];
    self.sourceControl.selectedSegmentIndex = 0;
    [self.sourceControl addTarget:self action:@selector(actionSourceChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.sourceControl;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search mods";
    self.navigationItem.searchController = self.searchController;

    [self loadSearchResults];
}

- (NSString *)selectedSource {
    if (self.sourceControl.selectedSegmentIndex == 1) return @"modrinth";
    if (self.sourceControl.selectedSegmentIndex == 2) return @"curseforge";
    return @"all";
}

- (void)actionSourceChanged:(UISegmentedControl *)sender {
    [self loadSearchResults];
}

- (void)setLoading:(BOOL)loading {
    _loading = loading;
    if (loading) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
        self.tableView.allowsSelection = NO;
    } else {
        self.navigationItem.rightBarButtonItem = nil;
        self.tableView.allowsSelection = YES;
    }
}

- (void)loadSearchResults {
    NSUInteger generation = ++self.searchGeneration;
    NSString *query = self.searchController.searchBar.text ?: @"";
    NSString *source = [self selectedSource];
    NSDictionary *profileInfo = self.store.profileInfo;
    self.loading = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *results = [self.api searchModsWithQuery:query source:source profileInfo:profileInfo];
        NSError *error = self.api.lastError;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) {
                return;
            }
            self.loading = NO;
            if (!results) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
                return;
            }
            self.results = results;
            [self.tableView reloadData];
        });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(loadSearchResults) object:nil];
    [self performSelector:@selector(loadSearchResults) withObject:nil afterDelay:0.4];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.results.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *loader = [ModManagerStore displayNameForLoader:self.store.profileInfo[@"loader"]];
    NSString *mcVersion = self.store.profileInfo[@"minecraftVersion"] ?: @"";
    if (self.results.count == 0 && !self.loading) {
        return [NSString stringWithFormat:@"No compatible %@ mods found for %@.", loader, mcVersion];
    }
    return [NSString stringWithFormat:@"Showing mods compatible with %@ %@.", mcVersion, loader];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    NSDictionary *project = self.results[indexPath.row];
    NSString *source = [project[@"source"] isEqualToString:@"curseforge"] ? @"CurseForge" : @"Modrinth";
    cell.textLabel.text = project[@"title"];
    NSString *summary = project[@"summary"] ?: @"";
    cell.detailTextLabel.text = summary.length > 0 ? [NSString stringWithFormat:@"%@ - %@", source, summary] : source;
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:project[@"iconUrl"]] placeholderImage:fallbackImage];
    return cell;
}

- (void)showVersionMenuForProject:(NSDictionary *)project versions:(NSArray<NSDictionary *> *)versions atIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:project[@"title"] message:@"Select a compatible version to install." preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;

    NSUInteger count = MIN(versions.count, 12);
    for (NSUInteger i = 0; i < count; i++) {
        NSDictionary *version = versions[i];
        NSString *versionName = version[@"versionName"] ?: version[@"fileName"] ?: @"Version";
        NSString *gameVersion = version[@"gameVersion"] ?: @"";
        NSString *title = gameVersion.length > 0 ? [NSString stringWithFormat:@"%@ - %@", versionName, gameVersion] : versionName;
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self prepareInstallForVersion:version];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)prepareInstallForVersion:(NSDictionary *)version {
    self.loading = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *required = nil;
        NSArray *optional = nil;
        NSError *error = nil;
        BOOL success = [self.api resolveDependenciesForVersion:version
                                                   profileInfo:self.store.profileInfo
                                                         store:self.store
                                                      required:&required
                                                      optional:&optional
                                                         error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            if (!success) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
                return;
            }
            ModInstallConfirmViewController *vc = [[ModInstallConfirmViewController alloc]
                initWithStore:self.store
                main:version
                required:required
                optional:optional];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [self presentViewController:nav animated:YES completion:nil];
        });
    });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *project = self.results[indexPath.row];
    self.loading = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *versions = [self.api versionsForProject:project profileInfo:self.store.profileInfo];
        NSError *error = self.api.lastError;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            if (versions.count == 0) {
                showDialog(localize(@"Error", nil), error.localizedDescription ?: @"No compatible files were found for this mod.");
                return;
            }
            [self showVersionMenuForProject:project versions:versions atIndexPath:indexPath];
        });
    });
}

@end
