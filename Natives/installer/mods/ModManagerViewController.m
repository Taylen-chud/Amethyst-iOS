#import "ModManagerAPI.h"
#import "ModManagerStore.h"
#import "ModManagerViewController.h"
#import "ModInstallConfirmViewController.h"
#import "ModSearchViewController.h"
#import "UIKit+AFNetworking.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSUInteger, ModManagerSection) {
    ModManagerSectionInstalled,
    ModManagerSectionCount
};

@interface ModManagerViewController ()
@property(nonatomic) ModManagerStore *store;
@property(nonatomic) ModManagerAPI *api;
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) NSArray<NSMutableDictionary *> *mods;
@property(nonatomic) BOOL checkingUpdates;
@property(nonatomic) BOOL checkingDependencies;
@end

@implementation ModManagerViewController

- (instancetype)initWithProfileName:(NSString *)profileName profile:(NSMutableDictionary *)profile {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.store = [[ModManagerStore alloc] initWithProfileName:profileName profile:profile];
    self.api = [ModManagerAPI new];
    self.title = @"Manage Mods";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Filter installed mods";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(actionAddMod)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] style:UIBarButtonItemStylePlain target:self action:@selector(actionCheckUpdates)]
    ];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadMods) name:@"ModManagerModsChanged" object:nil];
    [self reloadMods];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadMods];
}

- (void)reloadMods {
    self.mods = [self.store installedModsMatchingQuery:self.searchController.searchBar.text ?: @""];
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self reloadMods];
}

- (void)actionAddMod {
    if (![ModManagerStore profileInfoSupportsModInstall:self.store.profileInfo]) {
        showDialog(localize(@"Error", nil), @"This profile does not use Fabric, Quilt, Forge, or NeoForge. Create or select a mod loader profile before installing mods.");
        return;
    }
    ModSearchViewController *vc = [[ModSearchViewController alloc] initWithStore:self.store];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)setCheckingUpdates:(BOOL)checkingUpdates {
    _checkingUpdates = checkingUpdates;
    UIBarButtonItem *updateItem = self.navigationItem.rightBarButtonItems.lastObject;
    updateItem.enabled = !checkingUpdates;
    if (checkingUpdates) {
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [indicator startAnimating];
        updateItem.customView = indicator;
    } else {
        updateItem.customView = nil;
        updateItem.image = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
    }
}

- (void)setCheckingDependencies:(BOOL)checkingDependencies {
    _checkingDependencies = checkingDependencies;
    self.tableView.userInteractionEnabled = !checkingDependencies;
    self.navigationItem.prompt = checkingDependencies ? @"Checking dependencies..." : nil;
}

- (void)actionCheckUpdates {
    if (self.checkingUpdates) {
        return;
    }
    NSArray *mods = [self.store installedMods];
    self.checkingUpdates = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *updatedMods = [NSMutableArray new];
        for (NSMutableDictionary *mod in mods) {
            NSError *error = nil;
            NSDictionary *update = [self.api latestVersionForInstalledMod:mod profileInfo:self.store.profileInfo error:&error];
            NSMutableDictionary *copy = mod.mutableCopy;
            if (update) {
                copy[@"availableUpdate"] = update;
            }
            [updatedMods addObject:copy];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.checkingUpdates = NO;
            self.mods = updatedMods;
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ModManagerSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.mods.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"Installed Mods";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.mods.count == 0) {
        return @"No mods are installed in this profile.";
    }
    NSString *loader = [ModManagerStore displayNameForLoader:self.store.profileInfo[@"loader"]];
    NSString *mcVersion = self.store.profileInfo[@"minecraftVersion"] ?: @"";
    return [NSString stringWithFormat:@"Profile: %@ %@. Disabled mods stay in the mods folder with a .disabled suffix.", mcVersion, loader];
}

- (NSString *)sourceDisplayNameForMod:(NSDictionary *)mod {
    NSString *source = mod[@"source"];
    if ([source isEqualToString:@"modrinth"]) return @"Modrinth";
    if ([source isEqualToString:@"curseforge"]) return @"CurseForge";
    return @"Manual";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
    }

    NSDictionary *mod = self.mods[indexPath.row];
    BOOL enabled = [mod[@"enabled"] boolValue];
    BOOL missing = [mod[@"missing"] boolValue];
    NSDictionary *update = mod[@"availableUpdate"];
    NSString *title = mod[@"title"] ?: mod[@"fileName"] ?: @"Mod";
    NSString *state = missing ? @"Missing" : (enabled ? @"Enabled" : @"Disabled");
    NSString *source = [self sourceDisplayNameForMod:mod];
    NSString *fileName = mod[@"fileName"] ?: @"";
    cell.textLabel.text = title;
    cell.textLabel.enabled = !missing;
    cell.detailTextLabel.enabled = !missing;
    if (update) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ - Update available: %@", source, update[@"versionName"] ?: update[@"fileName"] ?: @""];
        cell.accessoryType = UITableViewCellAccessoryDetailButton;
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ - %@ - %@", source, state, fileName];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:mod[@"iconUrl"]] placeholderImage:fallbackImage];
    return cell;
}

- (void)presentError:(NSError *)error {
    showDialog(localize(@"Error", nil), error.localizedDescription ?: @"The mod operation failed.");
}

- (NSString *)displayTitleForMod:(NSDictionary *)mod {
    NSString *title = mod[@"title"];
    if ([title isKindOfClass:NSString.class] && title.length > 0) {
        return title;
    }
    title = mod[@"fileName"];
    return [title isKindOfClass:NSString.class] && title.length > 0 ? title : @"Mod";
}

- (NSArray<NSDictionary *> *)operationModsForMod:(NSDictionary *)mod dependents:(NSArray<NSDictionary *> *)dependents {
    NSMutableArray *mods = [NSMutableArray arrayWithObject:mod];
    [mods addObjectsFromArray:dependents ?: @[]];
    return mods;
}

- (NSString *)dependentMessageForMod:(NSDictionary *)mod dependents:(NSArray<NSDictionary *> *)dependents action:(NSString *)action {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSUInteger limit = MIN(dependents.count, 8);
    for (NSUInteger i = 0; i < limit; i++) {
        [names addObject:[NSString stringWithFormat:@"- %@", [self displayTitleForMod:dependents[i]]]];
    }
    if (dependents.count > limit) {
        [names addObject:[NSString stringWithFormat:@"- %lu more", (unsigned long)(dependents.count - limit)]];
    }
    return [NSString stringWithFormat:@"These mods depend on %@ and will also be %@:\n\n%@",
        [self displayTitleForMod:mod],
        action,
        [names componentsJoinedByString:@"\n"]];
}

- (void)disableMods:(NSArray<NSDictionary *> *)mods completion:(void (^)(BOOL success))completion {
    NSError *error = nil;
    BOOL ok = YES;
    for (NSDictionary *mod in mods) {
        if (![self.store disableMod:mod error:&error]) {
            ok = NO;
            break;
        }
    }
    if (!ok) {
        [self presentError:error];
    }
    [self reloadMods];
    if (completion) completion(ok);
}

- (void)removeMods:(NSArray<NSDictionary *> *)mods completion:(void (^)(BOOL success))completion {
    NSError *error = nil;
    BOOL ok = YES;
    for (NSDictionary *mod in mods) {
        if (![self.store removeMod:mod error:&error]) {
            ok = NO;
            break;
        }
    }
    if (!ok) {
        [self presentError:error];
    }
    [self reloadMods];
    if (completion) completion(ok);
}

- (NSDictionary *)currentInstalledModMatchingMod:(NSDictionary *)mod {
    NSString *fileName = mod[@"fileName"];
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
        return mod;
    }
    for (NSDictionary *installed in [self.store installedMods]) {
        if ([installed[@"fileName"] isEqualToString:fileName]) {
            return installed;
        }
    }
    return mod;
}

- (void)refreshProviderMetadataForMod:(NSDictionary *)mod completion:(void (^)(NSDictionary *currentMod))completion {
    NSArray *installedMods = [self.store installedMods];
    self.checkingDependencies = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *records = [self.api refreshedMetadataForInstalledMods:installedMods profileInfo:self.store.profileInfo];
        NSError *error = self.api.lastError;
        if (records.count > 0) {
            NSError *saveError = [self.store saveMetadataRecords:records replacingFileNames:@[] replacements:@[]];
            if (saveError) {
                error = saveError;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.checkingDependencies = NO;
            if (error) {
                [self presentError:error];
                if (completion) {
                    completion(nil);
                }
                return;
            }
            [self reloadMods];
            if (completion) {
                completion([self currentInstalledModMatchingMod:mod]);
            }
        });
    });
}

- (void)confirmDisableModWithDependents:(NSDictionary *)mod completion:(void (^)(BOOL success))completion {
    NSArray *dependents = [self.store dependentModsForMod:mod includeDisabled:NO];
    NSArray *mods = [self operationModsForMod:mod dependents:dependents];
    if (dependents.count == 0) {
        [self disableMods:mods completion:completion];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Disable Dependent Mods?"
        message:[self dependentMessageForMod:mod dependents:dependents action:@"disabled"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if (completion) completion(NO);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Disable All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self disableMods:mods completion:completion];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)disableModWithDependents:(NSDictionary *)mod completion:(void (^)(BOOL success))completion {
    [self refreshProviderMetadataForMod:mod completion:^(NSDictionary *currentMod) {
        if (!currentMod) {
            if (completion) completion(NO);
            return;
        }
        [self confirmDisableModWithDependents:currentMod completion:completion];
    }];
}

- (void)confirmRemoveModWithDependents:(NSDictionary *)mod completion:(void (^)(BOOL success))completion {
    NSArray *dependents = [self.store dependentModsForMod:mod includeDisabled:YES];
    NSArray *mods = [self operationModsForMod:mod dependents:dependents];
    if (dependents.count == 0) {
        [self removeMods:mods completion:completion];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Remove Dependent Mods?"
        message:[self dependentMessageForMod:mod dependents:dependents action:@"removed"]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        if (completion) completion(NO);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Remove All" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self removeMods:mods completion:completion];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)removeModWithDependents:(NSDictionary *)mod completion:(void (^)(BOOL success))completion {
    [self refreshProviderMetadataForMod:mod completion:^(NSDictionary *currentMod) {
        if (!currentMod) {
            if (completion) completion(NO);
            return;
        }
        [self confirmRemoveModWithDependents:currentMod completion:completion];
    }];
}

- (void)installUpdateForMod:(NSDictionary *)mod {
    NSDictionary *update = mod[@"availableUpdate"];
    if (!update) {
        return;
    }
    self.checkingUpdates = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *required = nil;
        NSArray *optional = nil;
        NSError *error = nil;
        BOOL success = [self.api resolveDependenciesForVersion:update
                                                   profileInfo:self.store.profileInfo
                                                         store:self.store
                                                      required:&required
                                                      optional:&optional
                                                         error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.checkingUpdates = NO;
            if (!success) {
                [self presentError:error];
                return;
            }
            ModInstallConfirmViewController *vc = [[ModInstallConfirmViewController alloc]
                initWithStore:self.store
                main:update
                required:required
                optional:optional];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [self presentViewController:nav animated:YES completion:nil];
        });
    });
}

- (void)showActionsForMod:(NSDictionary *)mod fromCell:(UITableViewCell *)cell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:mod[@"title"] ?: mod[@"fileName"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    sheet.popoverPresentationController.sourceView = cell;
    sheet.popoverPresentationController.sourceRect = cell.bounds;

    if (mod[@"availableUpdate"]) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Install Update" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self installUpdateForMod:mod];
        }]];
    }

    BOOL enabled = [mod[@"enabled"] boolValue];
    BOOL missing = [mod[@"missing"] boolValue];
    if (!missing) {
        [sheet addAction:[UIAlertAction actionWithTitle:(enabled ? @"Disable" : @"Enable") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (enabled) {
                [self disableModWithDependents:mod completion:nil];
            } else {
                NSError *error = nil;
                BOOL ok = [self.store enableMod:mod error:&error];
                if (!ok) {
                    [self presentError:error];
                }
                [self reloadMods];
            }
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self removeModWithDependents:mod completion:nil];
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [self showActionsForMod:self.mods[indexPath.row] fromCell:cell];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *mod = self.mods[indexPath.row];
    if ([mod[@"missing"] boolValue]) {
        return nil;
    }
    BOOL enabled = [mod[@"enabled"] boolValue];
    UIContextualAction *toggle = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:(enabled ? @"Disable" : @"Enable") handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        if (enabled) {
            completionHandler(YES);
            [self disableModWithDependents:mod completion:nil];
        } else {
            NSError *error = nil;
            BOOL ok = [self.store enableMod:mod error:&error];
            if (!ok) {
                [self presentError:error];
            }
            [self reloadMods];
            completionHandler(ok);
        }
    }];
    toggle.backgroundColor = UIColor.systemBlueColor;

    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove" handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        completionHandler(YES);
        [self removeModWithDependents:mod completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove, toggle]];
}

@end
