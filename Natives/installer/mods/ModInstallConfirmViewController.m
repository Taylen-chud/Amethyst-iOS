#import "ModInstallConfirmViewController.h"
#import "ModManagerAPI.h"
#import "ModManagerStore.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSUInteger, ModInstallConfirmSection) {
    ModInstallConfirmSectionMain,
    ModInstallConfirmSectionRequired,
    ModInstallConfirmSectionOptional,
    ModInstallConfirmSectionCount
};

@interface ModInstallConfirmViewController ()
@property(nonatomic) ModManagerStore *store;
@property(nonatomic) NSDictionary *mainFile;
@property(nonatomic) NSArray<NSDictionary *> *requiredFiles;
@property(nonatomic) NSArray<NSDictionary *> *optionalFiles;
@property(nonatomic) NSMutableSet<NSNumber *> *selectedOptionalIndexes;
@end

@implementation ModInstallConfirmViewController

- (instancetype)initWithStore:(ModManagerStore *)store
                         main:(NSDictionary *)mainFile
                     required:(NSArray<NSDictionary *> *)requiredFiles
                     optional:(NSArray<NSDictionary *> *)optionalFiles {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    self.store = store;
    self.mainFile = mainFile;
    self.requiredFiles = requiredFiles ?: @[];
    self.optionalFiles = optionalFiles ?: @[];
    self.selectedOptionalIndexes = [NSMutableSet new];
    self.title = @"Install Mod";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(actionCancel)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Install" style:UIBarButtonItemStyleDone target:self action:@selector(actionInstall)];
}

- (void)actionCancel {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (NSArray<NSDictionary *> *)selectedFiles {
    NSMutableArray *files = [NSMutableArray arrayWithObject:self.mainFile];
    [files addObjectsFromArray:self.requiredFiles];
    for (NSNumber *index in self.selectedOptionalIndexes) {
        NSUInteger i = index.unsignedIntegerValue;
        if (i < self.optionalFiles.count) {
            [files addObject:self.optionalFiles[i]];
        }
    }
    return files;
}

- (void)actionInstall {
    self.navigationItem.rightBarButtonItem.enabled = NO;
    NSArray *selectedFiles = [self selectedFiles];
    NSArray *selectedOptionalIndexes = self.selectedOptionalIndexes.allObjects;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSMutableArray *expandedFiles = selectedFiles.mutableCopy;
        NSMutableSet *seen = [NSMutableSet new];
        for (NSDictionary *file in expandedFiles.copy) {
            [seen addObject:[NSString stringWithFormat:@"%@:%@", file[@"source"], file[@"projectId"] ?: file[@"versionId"] ?: file[@"fileName"]]];
        }

        ModManagerAPI *api = [ModManagerAPI new];
        for (NSNumber *index in selectedOptionalIndexes) {
            NSUInteger i = index.unsignedIntegerValue;
            if (i >= self.optionalFiles.count) {
                continue;
            }
            NSArray *required = nil;
            NSDictionary *optionalFile = self.optionalFiles[i];
            BOOL ok = [api resolveDependenciesForVersion:optionalFile
                                             profileInfo:self.store.profileInfo
                                                   store:self.store
                                                required:&required
                                                optional:nil
                                                   error:&error];
            if (!ok) {
                break;
            }
            for (NSDictionary *requiredFile in required) {
                NSString *key = [NSString stringWithFormat:@"%@:%@", requiredFile[@"source"], requiredFile[@"projectId"] ?: requiredFile[@"versionId"] ?: requiredFile[@"fileName"]];
                if (![seen containsObject:key]) {
                    [seen addObject:key];
                    [expandedFiles addObject:requiredFile];
                }
            }
        }

        NSDictionary *plan = error ? nil : [self.store installPlanForFiles:expandedFiles error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.navigationItem.rightBarButtonItem.enabled = YES;
            if (!plan) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
                return;
            }
            [self.navigationController dismissViewControllerAnimated:YES completion:^{
                [NSNotificationCenter.defaultCenter postNotificationName:@"InstallMods" object:self.store userInfo:plan];
            }];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ModInstallConfirmSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == ModInstallConfirmSectionMain) return 1;
    if (section == ModInstallConfirmSectionRequired) return self.requiredFiles.count;
    if (section == ModInstallConfirmSectionOptional) return self.optionalFiles.count;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == ModInstallConfirmSectionMain) return @"Selected Mod";
    if (section == ModInstallConfirmSectionRequired) return self.requiredFiles.count > 0 ? @"Required Dependencies" : nil;
    if (section == ModInstallConfirmSectionOptional) return self.optionalFiles.count > 0 ? @"Optional Dependencies" : nil;
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == ModInstallConfirmSectionOptional && self.optionalFiles.count > 0) {
        return @"Optional dependencies are off by default. Enable only the ones you want installed with this mod.";
    }
    return nil;
}

- (NSDictionary *)fileForIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == ModInstallConfirmSectionMain) return self.mainFile;
    if (indexPath.section == ModInstallConfirmSectionRequired) return self.requiredFiles[indexPath.row];
    if (indexPath.section == ModInstallConfirmSectionOptional) return self.optionalFiles[indexPath.row];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    }

    NSDictionary *file = [self fileForIndexPath:indexPath];
    NSString *title = file[@"title"] ?: file[@"fileName"] ?: @"Mod";
    NSString *versionName = file[@"versionName"] ?: @"";
    NSString *source = [file[@"source"] isEqualToString:@"curseforge"] ? @"CurseForge" : @"Modrinth";
    cell.textLabel.text = title;
    cell.detailTextLabel.text = versionName.length > 0 ? [NSString stringWithFormat:@"%@ - %@", source, versionName] : source;
    cell.selectionStyle = indexPath.section == ModInstallConfirmSectionOptional ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.section == ModInstallConfirmSectionRequired || indexPath.section == ModInstallConfirmSectionMain) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else if (indexPath.section == ModInstallConfirmSectionOptional) {
        UISwitch *toggle = [UISwitch new];
        toggle.tag = indexPath.row;
        toggle.on = [self.selectedOptionalIndexes containsObject:@(indexPath.row)];
        [toggle addTarget:self action:@selector(optionalSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    return cell;
}

- (void)optionalSwitchChanged:(UISwitch *)sender {
    NSNumber *index = @(sender.tag);
    if (sender.isOn) {
        [self.selectedOptionalIndexes addObject:index];
    } else {
        [self.selectedOptionalIndexes removeObject:index];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != ModInstallConfirmSectionOptional) {
        return;
    }

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UISwitch *toggle = (id)cell.accessoryView;
    if ([toggle isKindOfClass:UISwitch.class]) {
        [toggle setOn:!toggle.isOn animated:YES];
        [self optionalSwitchChanged:toggle];
    }
}

@end
