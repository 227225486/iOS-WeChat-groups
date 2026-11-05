#import "WCGroupBarManager.h"
#import "WCGroupBarView.h"
#import "WCWeChatAdapter.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>

static NSString *const WCSelectedKindDefaultsKey = @"com.wcgroupbar.selectedKind";
static const CGFloat WCGroupBarContainerHeight = 44.0;

static NSInteger WCUsernameBuilderDepth = 0;
static BOOL WCIsBuildingCells(void) { return WCUsernameBuilderDepth > 0; }

/// 临时诊断日志，定位后删除。
static void WCLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSData *data = [[NSString stringWithFormat:@"%@ %@\n", [NSDate date], line] dataUsingEncoding:NSUTF8StringEncoding];
    NSString *path = @"/var/tmp/wcgroupbar.log";
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:path]) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}
static const void *WCBaseInsetKey = &WCBaseInsetKey;

#pragma mark - 原始 IMP 登记表

static NSMutableDictionary<NSString *, NSValue *> *WCOriginalIMPs(void) {
    static NSMutableDictionary *dictionary;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dictionary = [NSMutableDictionary dictionary];
    });
    return dictionary;
}

static NSMutableSet<NSString *> *WCHookedKeys(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static NSString *WCKeyForMethod(Class cls, SEL selector) {
    if (!cls || !selector) {
        return nil;
    }
    const char *className = class_getName(cls);
    const char *selectorName = sel_getName(selector);
    if (!className || !selectorName) {
        return nil;
    }
    return [NSString stringWithFormat:@"%s-%s", className, selectorName];
}

static void WCInstallHook(Class cls, SEL selector, IMP hook) {
    if (!cls || !selector || !hook) {
        return;
    }
    NSString *key = WCKeyForMethod(cls, selector);
    if (!key || [WCHookedKeys() containsObject:key]) {
        return;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }

    const char *types = method_getTypeEncoding(method);
    IMP original = NULL;
    if (class_addMethod(cls, selector, hook, types)) {
        // 该类本身没有实现这个方法，原实现来自父类；父类也没有时不要伪造 IMP。
        Class superClass = class_getSuperclass(cls);
        if (superClass && class_respondsToSelector(superClass, selector)) {
            original = class_getMethodImplementation(superClass, selector);
        }
    } else {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        original = method_getImplementation(ownMethod);
        method_setImplementation(ownMethod, hook);
    }

    if (original) {
        WCOriginalIMPs()[key] = [NSValue valueWithPointer:(void *)original];
    }
    [WCHookedKeys() addObject:key];
}

static void WCUninstallHook(Class cls, SEL selector) {
    if (!cls || !selector) {
        return;
    }
    NSString *key = WCKeyForMethod(cls, selector);
    if (!key) {
        return;
    }
    NSValue *stored = WCOriginalIMPs()[key];
    if (!stored || ![WCHookedKeys() containsObject:key]) {
        return;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (method) {
        method_setImplementation(method, [stored pointerValue]);
    }
    [WCOriginalIMPs() removeObjectForKey:key];
    [WCHookedKeys() removeObject:key];
}

static IMP WCGetOriginalIMP(Class cls, SEL selector) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        NSString *key = WCKeyForMethod(current, selector);
        NSValue *value = key ? WCOriginalIMPs()[key] : nil;
        if (value) {
            return (IMP)[value pointerValue];
        }
    }
    return NULL;
}

#pragma mark - 选择器

static SEL WCRowsSelector(void) { return NSSelectorFromString(@"tableView:numberOfRowsInSection:"); }
static SEL WCCellSelector(void) { return NSSelectorFromString(@"tableView:cellForRowAtIndexPath:"); }
static SEL WCHeightSelector(void) { return NSSelectorFromString(@"tableView:heightForRowAtIndexPath:"); }
static SEL WCEstimatedHeightSelector(void) { return NSSelectorFromString(@"tableView:estimatedHeightForRowAtIndexPath:"); }
static SEL WCDidSelectSelector(void) { return NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:"); }

static id WCSafeValue(id object, NSString *key) {
    if (!object || key.length == 0) {
        return nil;
    }
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

@interface WCGroupBarManager () <WCGroupBarViewDelegate>

@property (nonatomic, weak) UIViewController *hostController;
@property (nonatomic, weak) UITableView *sessionTableView;
@property (nonatomic, strong) WCGroupBarView *barView;

@property (nonatomic, assign) WCGroupKind selectedKind;
@property (nonatomic, assign) BOOL didInstallHooks;

@property (nonatomic, weak) UITapGestureRecognizer *barTapGesture;

@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *> *usernameCache;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *> *mappingCache;

@property (nonatomic, assign) Class hookedDataSourceClass;
@property (nonatomic, assign) Class hookedAccessorClass;
@property (nonatomic, assign) BOOL barConstraintsInstalled;

@property (nonatomic, strong) UIView *headerContainer;
@property (nonatomic, weak) UIView *headerOriginalView;
@property (nonatomic, assign) CGFloat headerOriginalHeight;
@property (nonatomic, assign) BOOL adjustingHeaderHeight;
@property (nonatomic, strong) NSMutableArray<NSString *> *headerHookedClassNames;
@property (nonatomic, assign) BOOL headerQuerying;

@property (nonatomic, assign) BOOL filteringEnabled;
@property (nonatomic, assign) BOOL getterMode;
@property (nonatomic, assign) NSInteger sessionSection;
@property (nonatomic, copy) NSArray<NSString *> *accessorSelectors;
@property (nonatomic, copy) NSArray<NSString *> *usernames;
@property (nonatomic, strong) NSMutableArray<NSString *> *heightHookedClassNames;

@property (nonatomic, weak) UIViewController *pendingHostController;
@property (nonatomic, weak) UITableView *pendingSessionTableView;
@property (nonatomic, assign) BOOL layoutScheduled;

- (void)hostControllerWillAppear:(UIViewController *)controller;
- (void)hostControllerWillDisappear:(UIViewController *)controller;
- (void)hostControllerDidLayout:(UIViewController *)controller;
- (void)handleBarAreaTap:(UITapGestureRecognizer *)gesture;
- (void)tableViewDidReload:(UITableView *)tableView;
- (BOOL)shouldFilterTableView:(UITableView *)tableView;
- (NSInteger)filteredRowCountForDataSource:(id)dataSource
                                 tableView:(UITableView *)tableView
                                   section:(NSInteger)section
                             originalCount:(NSInteger)originalCount;
- (NSIndexPath *)mappedIndexPathForIndexPath:(NSIndexPath *)indexPath
                                  dataSource:(id)dataSource
                                   tableView:(UITableView *)tableView;
- (NSIndexPath *)displayIndexPathForOriginalIndexPath:(NSIndexPath *)indexPath
                                            dataSource:(id)dataSource
                                             tableView:(UITableView *)tableView;
- (void)installHostLifecycleHooks;
- (void)installTableReloadHook;
- (void)installFilterHooksForTable:(UITableView *)tableView;
- (void)uninstallFilterHooksForTable;
- (void)installAccessorHooksForDataSource:(id)dataSource;
- (void)uninstallAccessorHooks;
- (NSArray<NSString *> *)currentUsernames;
- (BOOL)shouldHideRowAtIndexPath:(NSIndexPath *)indexPath;
- (NSInteger)originalRowForDisplayRow:(NSInteger)row;
- (NSInteger)visibleRowCount;
- (NSInteger)originalRowCountForTableView:(UITableView *)tableView section:(NSInteger)section;
- (NSInteger)sessionSectionForTableView:(UITableView *)tableView;
- (NSArray<NSString *> *)usernamesFromCellsForTableView:(UITableView *)tableView
                                                section:(NSInteger)section
                                                   rows:(NSInteger)rows
                                             dataSource:(id)dataSource;
- (void)showDiagnostics;
- (void)handleDiagnosticsPress:(UILongPressGestureRecognizer *)gesture;
- (void)installGetterHooksForDataSource:(id)dataSource;
- (void)installFilterHooksForObject:(id)object;
- (void)hookHeightSelectorsForObject:(id)object;
- (id)originalSessionInfoForRow:(NSInteger)row
                         section:(NSInteger)section
                      dataSource:(id)dataSource;
- (void)scheduleApplyLayout;
- (BOOL)shouldUseController:(UIViewController *)controller tableView:(UITableView *)tableView;
- (void)switchToController:(UIViewController *)controller tableView:(UITableView *)tableView;
- (void)ensureLayout;
- (void)attachBarToTableView:(UITableView *)tableView;
- (void)detachBarFromTableViewHeader;
- (void)installHeaderBarHooksForTableView:(UITableView *)tableView;
- (void)installHeaderHooksForObject:(id)object;
- (BOOL)shouldShowBarInTableView:(UITableView *)tableView section:(NSInteger)section;
- (UIView *)barHeaderViewForTableView:(UITableView *)tableView section:(NSInteger)section;
- (void)installHeaderFrameHookForView:(UIView *)view;
- (BOOL)isGuardedHeaderView:(id)view;
- (void)layoutBarInGuardedHeader;
- (void)sizeHeaderContainerForTableView:(UITableView *)tableView;
- (void)applyContentInset;
- (void)restoreCurrentLayout;
- (UITableView *)sessionTableViewForController:(UIViewController *)controller;
- (BOOL)isUsableSessionTable:(UITableView *)tableView;
- (NSInteger)totalRowCountForTableView:(UITableView *)tableView;
- (CGFloat)scoreForSessionTable:(UITableView *)tableView controller:(UIViewController *)controller;
- (void)resetCaches;
- (NSArray<NSNumber *> *)mappingForDataSource:(id)dataSource
                                     tableView:(UITableView *)tableView
                                       section:(NSInteger)section
                                 originalCount:(NSInteger)originalCount;

@end

#pragma mark - Hook 函数

static void WCHookViewWillAppear(id self, SEL _cmd, BOOL animated) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (original) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }
    if ([self isKindOfClass:[UIViewController class]]) {
        [[WCGroupBarManager sharedManager] hostControllerWillAppear:(UIViewController *)self];
    }
}

static void WCHookViewWillDisappear(id self, SEL _cmd, BOOL animated) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (original) {
        ((void (*)(id, SEL, BOOL))original)(self, _cmd, animated);
    }
    if ([self isKindOfClass:[UIViewController class]]) {
        [[WCGroupBarManager sharedManager] hostControllerWillDisappear:(UIViewController *)self];
    }
}

static void WCHookViewDidLayoutSubviews(id self, SEL _cmd) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (original) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
    if ([self isKindOfClass:[UIViewController class]]) {
        [[WCGroupBarManager sharedManager] hostControllerDidLayout:(UIViewController *)self];
    }
}

static void WCHookReloadData(id self, SEL _cmd) {
    if ([self isKindOfClass:[UITableView class]]) {
        [[WCGroupBarManager sharedManager] tableViewDidReload:(UITableView *)self];
    }
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (original) {
        ((void (*)(id, SEL))original)(self, _cmd);
    }
}

static NSInteger WCHookNumberOfRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return 0;
    }
    NSInteger originalCount = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))original)(self, _cmd, tableView, section);
    WCGroupBarManager *manager = [WCGroupBarManager sharedManager];
    if (![manager shouldFilterTableView:tableView] || tableView.dataSource != self) {
        return originalCount;
    }
    if (section == manager.sessionSection) {
        return [manager visibleRowCount];
    }
    return originalCount;
}

static id WCHookSessionInfoAtIndexPath(id self, SEL _cmd, NSIndexPath *indexPath) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return nil;
    }
    WCGroupBarManager *manager = [WCGroupBarManager sharedManager];
    // 把“展示行”换回微信自己的“原始行”，微信据此正常构建 cell；
    // cellForRowAtIndexPath 本身保持 UIKit 传入的 index path，避免解复用断言。
    NSIndexPath *mapped = [manager mappedIndexPathForIndexPath:indexPath
                                                    dataSource:self
                                                     tableView:manager.sessionTableView];
    return ((id (*)(id, SEL, NSIndexPath *))original)(self, _cmd, mapped ?: indexPath);
}

static CGFloat WCHookHeightForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return UITableViewAutomaticDimension;
    }
    NSIndexPath *mapped = [[WCGroupBarManager sharedManager] mappedIndexPathForIndexPath:indexPath
                                                                              dataSource:self
                                                                               tableView:tableView];
    if (!mapped) {
        return 0.0;
    }
    return ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))original)(self, _cmd, tableView, mapped);
}

static CGFloat WCHookEstimatedHeightForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return UITableViewAutomaticDimension;
    }
    NSIndexPath *mapped = [[WCGroupBarManager sharedManager] mappedIndexPathForIndexPath:indexPath
                                                                              dataSource:self
                                                                               tableView:tableView];
    if (!mapped) {
        return 0.0;
    }
    return ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))original)(self, _cmd, tableView, mapped);
}

static UITableViewCell *WCHookCellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return nil;
    }
    NSIndexPath *mapped = [[WCGroupBarManager sharedManager] mappedIndexPathForIndexPath:indexPath
                                                                              dataSource:self
                                                                               tableView:tableView];
    return ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))original)(self, _cmd, tableView, mapped ?: indexPath);
}

static void WCHookDidSelectRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return;
    }
    NSIndexPath *mapped = [[WCGroupBarManager sharedManager] mappedIndexPathForIndexPath:indexPath
                                                                              dataSource:self
                                                                               tableView:tableView];
    if (!mapped) {
        return;
    }
    ((void (*)(id, SEL, UITableView *, NSIndexPath *))original)(self, _cmd, tableView, mapped);
}

static void WCHookWillDisplayCell(id self, SEL _cmd, UITableView *tableView, UITableViewCell *cell, NSIndexPath *indexPath) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return;
    }
    NSIndexPath *mapped = [[WCGroupBarManager sharedManager] mappedIndexPathForIndexPath:indexPath
                                                                              dataSource:self
                                                                               tableView:tableView];
    ((void (*)(id, SEL, UITableView *, UITableViewCell *, NSIndexPath *))original)(self, _cmd, tableView, cell, mapped ?: indexPath);
}

#pragma mark - 分组栏作为 section header（与 AFN 同机制）

static UIView *WCHookViewForHeader(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    UIView *bar = [[WCGroupBarManager sharedManager] barHeaderViewForTableView:tableView section:section];
    if (bar) {
        return bar;
    }
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (original) {
        return ((UIView * (*)(id, SEL, UITableView *, NSInteger))original)(self, _cmd, tableView, section);
    }
    return nil;
}

static CGFloat WCHookHeightForHeader(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    if ([[WCGroupBarManager sharedManager] shouldShowBarInTableView:tableView section:section]) {
        return WCGroupBarContainerHeight;
    }
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (original) {
        return ((CGFloat (*)(id, SEL, UITableView *, NSInteger))original)(self, _cmd, tableView, section);
    }
    return 0.0;
}

static CGFloat WCHookEstimatedHeightForHeader(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    if ([[WCGroupBarManager sharedManager] shouldShowBarInTableView:tableView section:section]) {
        return WCGroupBarContainerHeight;
    }
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (original) {
        return ((CGFloat (*)(id, SEL, UITableView *, NSInteger))original)(self, _cmd, tableView, section);
    }
    return 0.0;
}

// 微信在点击搜索栏等时机直接把表头高度设回自己需要的高度，
// 分组栏会被挤出表头范围，表现为标题栏下面只剩一条白边。
// 这里拦住表头的 setFrame:，只要高度不够就补回分组栏那 44pt。
static void WCHookHeaderSetFrame(id self, SEL _cmd, CGRect frame) {
    WCGroupBarManager *manager = [WCGroupBarManager sharedManager];
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return;
    }

    if (!manager.adjustingHeaderHeight && [manager isGuardedHeaderView:self]) {
        CGFloat wanted = manager.headerOriginalHeight + WCGroupBarContainerHeight;
        if (wanted > 1.0 && frame.size.height < wanted) {
            frame.size.height = wanted;
            manager.adjustingHeaderHeight = YES;
            ((void (*)(id, SEL, CGRect))original)(self, _cmd, frame);
            manager.adjustingHeaderHeight = NO;
            [manager layoutBarInGuardedHeader];
            return;
        }
    }

    ((void (*)(id, SEL, CGRect))original)(self, _cmd, frame);
}

static id WCHookGetSessionInfo(id self, SEL _cmd, NSIndexPath *indexPath) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return nil;
    }
    WCGroupBarManager *manager = [WCGroupBarManager sharedManager];
    NSIndexPath *target = indexPath;
    if (manager.getterMode && manager.filteringEnabled && indexPath) {
        NSInteger row = [manager originalRowForDisplayRow:indexPath.row];
        if (row >= 0 && row != indexPath.row) {
            target = [NSIndexPath indexPathForRow:row inSection:indexPath.section];
        }
    }
    return ((id (*)(id, SEL, NSIndexPath *))original)(self, _cmd, target);
}

static void WCHookReloadRows(id self, SEL _cmd, NSArray<NSIndexPath *> *indexPaths, UITableViewRowAnimation animation) {
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (!original) {
        return;
    }
    if (![self isKindOfClass:[UITableView class]]) {
        ((void (*)(id, SEL, NSArray *, UITableViewRowAnimation))original)(self, _cmd, indexPaths, animation);
        return;
    }

    UITableView *tableView = (UITableView *)self;
    WCGroupBarManager *manager = [WCGroupBarManager sharedManager];
    if (![manager shouldFilterTableView:tableView]) {
        ((void (*)(id, SEL, NSArray *, UITableViewRowAnimation))original)(self, _cmd, indexPaths, animation);
        return;
    }

    // 微信传的是原始行号，需要换成过滤后的展示行号；被过滤掉的行直接忽略。
    NSMutableArray<NSIndexPath *> *displayPaths = [NSMutableArray array];
    for (NSIndexPath *indexPath in indexPaths) {
        NSIndexPath *display = [manager displayIndexPathForOriginalIndexPath:indexPath
                                                                   dataSource:tableView.dataSource
                                                                    tableView:tableView];
        if (display) {
            [displayPaths addObject:display];
        }
    }
    if (displayPaths.count == 0) {
        return;
    }
    ((void (*)(id, SEL, NSArray *, UITableViewRowAnimation))original)(self, _cmd, displayPaths, animation);
}

static void WCHookBatchUpdateRows(id self, SEL _cmd, NSArray<NSIndexPath *> *indexPaths, UITableViewRowAnimation animation) {
    if ([self isKindOfClass:[UITableView class]] &&
        [[WCGroupBarManager sharedManager] shouldFilterTableView:(UITableView *)self]) {
        // 过滤态下行的可见性由分组决定，插入/删除的批量动画会与过滤后的行数冲突，改为整体刷新。
        UITableView *tableView = (UITableView *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [tableView reloadData];
        });
        return;
    }
    IMP original = WCGetOriginalIMP(object_getClass(self), _cmd);
    if (original) {
        ((void (*)(id, SEL, NSArray *, UITableViewRowAnimation))original)(self, _cmd, indexPaths, animation);
    }
}

#pragma mark - 工具

static void WCCollectTableViews(UIView *view, NSMutableArray<UITableView *> *tables) {
    if (!view) {
        return;
    }
    if ([view isKindOfClass:[UITableView class]]) {
        [tables addObject:(UITableView *)view];
    }
    for (UIView *subview in view.subviews) {
        WCCollectTableViews(subview, tables);
    }
}

static BOOL WCViewControllerIsAncestor(UIViewController *ancestor, UIViewController *controller) {
    if (!ancestor || !controller) {
        return NO;
    }
    for (UIViewController *parent = controller.parentViewController; parent; parent = parent.parentViewController) {
        if (parent == ancestor) {
            return YES;
        }
    }
    return NO;
}

@implementation WCGroupBarManager

+ (instancetype)sharedManager {
    static WCGroupBarManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[WCGroupBarManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _selectedKind = WCGroupKindAll;
        _sessionSection = -1;
        _usernameCache = [NSMutableDictionary dictionary];
        _mappingCache = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 安装

- (void)install {
    @synchronized (self) {
        if (self.didInstallHooks) {
            return;
        }
        self.didInstallHooks = YES;

        NSInteger storedKind = [[NSUserDefaults standardUserDefaults] integerForKey:WCSelectedKindDefaultsKey];
        if (storedKind >= WCGroupKindAll && storedKind <= WCGroupKindOfficial) {
            self.selectedKind = (WCGroupKind)storedKind;
        }

        [self installHostLifecycleHooks];
        [self installTableReloadHook];
    }
}

- (void)installHostLifecycleHooks {
    NSArray<NSString *> *classNames = @[
        @"NewMainFrameViewController",
        @"MMSessionListViewController",
        @"MainFrameAggregationViewController",
    ];

    SEL layoutSelector = NSSelectorFromString(@"viewDidLayoutSubviews");
    SEL appearSelector = NSSelectorFromString(@"viewWillAppear:");
    SEL disappearSelector = NSSelectorFromString(@"viewWillDisappear:");

    for (NSString *className in classNames) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) {
            continue;
        }
        WCInstallHook(cls, layoutSelector, (IMP)WCHookViewDidLayoutSubviews);
        WCInstallHook(cls, appearSelector, (IMP)WCHookViewWillAppear);
        WCInstallHook(cls, disappearSelector, (IMP)WCHookViewWillDisappear);
    }
}

- (void)installTableReloadHook {
    Class tableViewClass = objc_getClass("UITableView");
    if (tableViewClass) {
        // 只保留 reloadData：用于失效缓存。行数不再改动，插入/删除等批量更新必须原样放行。
        WCInstallHook(tableViewClass, NSSelectorFromString(@"reloadData"), (IMP)WCHookReloadData);
    }
}

- (void)installFilterHooksForTable:(UITableView *)tableView {
    if (!tableView || self.selectedKind == WCGroupKindAll) {
        return;
    }
    NSArray<NSString *> *names = [self currentUsernames];
    NSInteger rows = [self originalRowCountForTableView:tableView section:self.sessionSection];
    WCLog(@"enable? section=%ld rows=%ld users=%lu ds=%@",
          (long)self.sessionSection, (long)rows, (unsigned long)names.count,
          NSStringFromClass([tableView.dataSource class]));

    if (!names || names.count != (NSUInteger)rows || rows <= 0) {
        // 会话顺序必须和列表一一对应，否则宁可不过滤。
        self.filteringEnabled = NO;
        return;
    }

    [self installFilterHooksForObject:tableView.dataSource];
    [self installFilterHooksForObject:tableView.delegate];
    self.filteringEnabled = YES;
    WCLog(@"enabled kind=%ld section=%ld", (long)self.selectedKind, (long)self.sessionSection);
}

- (void)installFilterHooksForObject:(id)object {
    Class cls = object ? object_getClass(object) : Nil;
    if (!cls) {
        return;
    }
    if (!self.heightHookedClassNames) {
        self.heightHookedClassNames = [NSMutableArray array];
    }
    NSString *className = NSStringFromClass(cls);
    if ([self.heightHookedClassNames containsObject:className]) {
        return;
    }
    WCLog(@"hook %@ rows=%d cell=%d height=%d didSelect=%d willDisplay=%d",
          className,
          class_getInstanceMethod(cls, WCRowsSelector()) != NULL,
          class_getInstanceMethod(cls, WCCellSelector()) != NULL,
          class_getInstanceMethod(cls, WCHeightSelector()) != NULL,
          class_getInstanceMethod(cls, WCDidSelectSelector()) != NULL,
          class_getInstanceMethod(cls, NSSelectorFromString(@"tableView:willDisplayCell:forRowAtIndexPath:")) != NULL);

    WCInstallHook(cls, WCRowsSelector(), (IMP)WCHookNumberOfRows);
    WCInstallHook(cls, WCCellSelector(), (IMP)WCHookCellForRow);
    WCInstallHook(cls, WCHeightSelector(), (IMP)WCHookHeightForRow);
    WCInstallHook(cls, WCEstimatedHeightSelector(), (IMP)WCHookEstimatedHeightForRow);
    WCInstallHook(cls, WCDidSelectSelector(), (IMP)WCHookDidSelectRow);
    WCInstallHook(cls, NSSelectorFromString(@"tableView:willDisplayCell:forRowAtIndexPath:"), (IMP)WCHookWillDisplayCell);
    [self.heightHookedClassNames addObject:className];
}

- (void)installGetterHooksForDataSource:(id)dataSource {
    Class cls = dataSource ? object_getClass(dataSource) : Nil;
    if (!cls) {
        return;
    }
    if (!self.heightHookedClassNames) {
        self.heightHookedClassNames = [NSMutableArray array];
    }
    NSString *className = NSStringFromClass(cls);
    if (![self.heightHookedClassNames containsObject:className]) {
        WCInstallHook(cls, WCRowsSelector(), (IMP)WCHookNumberOfRows);
        WCInstallHook(cls, NSSelectorFromString(@"getSessionInfoAtIndexPath:"), (IMP)WCHookGetSessionInfo);
        WCInstallHook(cls, NSSelectorFromString(@"logicGetSessionAtIndexPath:"), (IMP)WCHookGetSessionInfo);
        [self.heightHookedClassNames addObject:className];
    }
    self.getterMode = YES;
    self.filteringEnabled = YES;
}

- (void)hookHeightSelectorsForObject:(id)object {
    Class cls = object ? object_getClass(object) : Nil;
    if (!cls) {
        return;
    }
    if (!self.heightHookedClassNames) {
        self.heightHookedClassNames = [NSMutableArray array];
    }
    NSString *className = NSStringFromClass(cls);
    if ([self.heightHookedClassNames containsObject:className]) {
        return;
    }
    BOOL hasHeight = class_getInstanceMethod(cls, WCHeightSelector()) != NULL;
    BOOL hasEstimated = class_getInstanceMethod(cls, WCEstimatedHeightSelector()) != NULL;
    WCLog(@"hook %@ height=%d estimated=%d", className, hasHeight, hasEstimated);
    WCInstallHook(cls, WCHeightSelector(), (IMP)WCHookHeightForRow);
    WCInstallHook(cls, WCEstimatedHeightSelector(), (IMP)WCHookEstimatedHeightForRow);
    [self.heightHookedClassNames addObject:className];
}

- (void)uninstallFilterHooksForTable {
    for (NSString *className in [self.heightHookedClassNames copy]) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) {
            continue;
        }
        WCUninstallHook(cls, WCHeightSelector());
        WCUninstallHook(cls, WCEstimatedHeightSelector());
        WCUninstallHook(cls, WCRowsSelector());
        WCUninstallHook(cls, WCCellSelector());
        WCUninstallHook(cls, WCDidSelectSelector());
        WCUninstallHook(cls, NSSelectorFromString(@"tableView:willDisplayCell:forRowAtIndexPath:"));
    }
    [self.heightHookedClassNames removeAllObjects];
    self.getterMode = NO;
    self.filteringEnabled = NO;
    // 注意：sessionSection 是“分组栏显示在哪个 section”的定位信息，与过滤无关，
    // 切回“全部”时不能清掉，否则分组栏会跟着消失。
    self.usernames = nil;
    [self resetCaches];
}

- (void)uninstallAccessorHooks {
    if (!self.hookedAccessorClass) {
        return;
    }
    for (NSString *name in self.accessorSelectors ?: @[]) {
        WCUninstallHook(self.hookedAccessorClass, NSSelectorFromString(name));
    }
    self.hookedAccessorClass = Nil;
}

- (void)installAccessorHooksForDataSource:(id)dataSource {
    if (!dataSource) {
        return;
    }

    static NSArray<NSString *> *aliases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        aliases = @[
            @"getSessionInfoAtIndexPath:",
            @"sessionInfoAtIndexPath:",
            @"getSessionInfoWithIndexPath:",
            @"sessionInfoForIndexPath:",
        ];
    });

    Class cls = object_getClass(dataSource);
    if (cls != self.hookedAccessorClass && self.hookedAccessorClass) {
        [self uninstallAccessorHooks];
    }

    NSMutableArray<NSString *> *installed = [NSMutableArray array];
    for (NSString *name in aliases) {
        SEL selector = NSSelectorFromString(name);
        if (![dataSource respondsToSelector:selector]) {
            continue;
        }
        WCInstallHook(cls, selector, (IMP)WCHookSessionInfoAtIndexPath);
        [installed addObject:name];
    }
    if (installed.count > 0) {
        self.hookedAccessorClass = cls;
    }

    // 只有真正拿到会话取数方法时才能安全过滤；否则退化为不过滤，宁可不生效也不猜行号。
    self.accessorSelectors = [installed copy];
    self.filteringEnabled = installed.count > 0;
}

- (id)originalSessionInfoForRow:(NSInteger)row
                         section:(NSInteger)section
                      dataSource:(id)dataSource {
    if (!dataSource || row < 0 || self.accessorSelectors.count == 0) {
        return nil;
    }
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
    for (NSString *name in self.accessorSelectors) {
        SEL selector = NSSelectorFromString(name);
        IMP imp = WCGetOriginalIMP(object_getClass(dataSource), selector);
        if (!imp) {
            continue;
        }
        id info = ((id (*)(id, SEL, NSIndexPath *))imp)(dataSource, selector, indexPath);
        if (info) {
            return info;
        }
    }
    return nil;
}

#pragma mark - 生命周期 / 布局

- (void)hostControllerWillAppear:(UIViewController *)controller {
    if (![controller isKindOfClass:[UIViewController class]]) {
        return;
    }
    [self resetCaches];
    [self hostControllerDidLayout:controller];
}

- (void)hostControllerWillDisappear:(UIViewController *)controller {
    if (controller != self.hostController) {
        return;
    }
    [self.barView removeFromSuperview];
    self.barConstraintsInstalled = NO;
}

- (void)handleBarAreaTap:(UITapGestureRecognizer *)gesture {
    UIViewController *host = self.hostController;
    WCGroupBarView *bar = self.barView;
    UIView *window = gesture.view;
    if (!host || !host.isViewLoaded || !bar || !bar.superview || !window) {
        return;
    }

    CGPoint pointInBar = [gesture locationInView:bar];
    if (!CGRectContainsPoint(bar.bounds, pointInBar)) {
        return;
    }

    // 只有点击位置命中的是分组栏或会话列表所在的视图树时才处理，
    // 避免进入聊天页、切到“通讯录”等界面时误触。
    UIView *hit = [window hitTest:[gesture locationInView:window] withEvent:nil];
    if (!hit) {
        return;
    }
    if (hit != bar && ![hit isDescendantOfView:bar] &&
        hit != host.view && ![hit isDescendantOfView:host.view]) {
        return;
    }
    [bar handleTapAtPoint:pointInBar];
}

- (void)hostControllerDidLayout:(UIViewController *)controller {
    if (![controller isKindOfClass:[UIViewController class]] || !controller.isViewLoaded) {
        return;
    }
    if (!controller.view.window) {
        return;
    }

    UITableView *tableView = [self sessionTableViewForController:controller];
    if (!tableView) {
        return;
    }
    if (![self shouldUseController:controller tableView:tableView]) {
        return;
    }

    // 不在 layoutSubviews 里直接改子视图/inset/offset，避免 UIKit 重入导致可见 cell 断言。
    self.pendingHostController = controller;
    self.pendingSessionTableView = tableView;
    [self scheduleApplyLayout];
}

- (void)scheduleApplyLayout {
    if (self.layoutScheduled) {
        return;
    }
    self.layoutScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf.layoutScheduled = NO;
        UIViewController *host = strongSelf.pendingHostController;
        UITableView *table = strongSelf.pendingSessionTableView;
        if (!host || !table) {
            return;
        }
        [strongSelf switchToController:host tableView:table];
        [strongSelf ensureLayout];
    });
}

- (BOOL)shouldUseController:(UIViewController *)controller tableView:(UITableView *)tableView {
    if (!controller || !tableView) {
        return NO;
    }
    if (CGRectGetWidth(tableView.bounds) < 120.0 || CGRectGetHeight(tableView.bounds) < 120.0) {
        return NO;
    }

    if (!self.hostController) {
        return YES;
    }
    if (self.hostController == controller) {
        return YES;
    }
    if (!self.hostController.view.window) {
        return YES;
    }
    if (WCViewControllerIsAncestor(self.hostController, controller)) {
        // 新 controller 是当前 host 的子级，优先使用更贴近会话列表的那一层。
        return YES;
    }
    if (WCViewControllerIsAncestor(controller, self.hostController)) {
        // 新 controller 是当前 host 的父级，保留当前更深的 host。
        return NO;
    }

    NSString *newName = NSStringFromClass([controller class]) ?: @"";
    NSString *oldName = NSStringFromClass([self.hostController class]) ?: @"";
    if ([newName containsString:@"NewMainFrame"] && ![oldName containsString:@"NewMainFrame"]) {
        return YES;
    }
    return NO;
}

- (void)switchToController:(UIViewController *)controller tableView:(UITableView *)tableView {
    if (self.hostController == controller && self.sessionTableView == tableView) {
        return;
    }

    if (self.hostController != controller) {
        [self restoreCurrentLayout];
        self.hostController = controller;
        self.sessionTableView = tableView;
        self.barConstraintsInstalled = NO;
        [self resetCaches];
    } else if (self.sessionTableView != tableView) {
        [self restoreCurrentLayout];
        self.sessionTableView = tableView;
        [self resetCaches];
    }
}

- (void)ensureLayout {
    UIViewController *host = self.hostController;
    UITableView *tableView = self.sessionTableView;
    if (!host || !host.isViewLoaded || !tableView) {
        return;
    }
    if (![tableView isDescendantOfView:host.view]) {
        UITableView *replacement = [self sessionTableViewForController:host];
        if (!replacement) {
            return;
        }
        [self restoreCurrentLayout];
        self.sessionTableView = replacement;
        [self resetCaches];
        tableView = replacement;
    }

    if (!self.barView) {
        WCGroupBarView *bar = [[WCGroupBarView alloc] initWithFrame:CGRectZero];
        bar.delegate = self;
        [bar setSelectedKind:self.selectedKind animated:NO];
        self.barView = bar;

        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleDiagnosticsPress:)];
        press.minimumPressDuration = 1.0;
        [bar addGestureRecognizer:press];
    }

    // 1.1.0 的表头方案在点搜索时会被微信把表头高度改小，分组栏随之被挤掉；
    // 改用 AFN 的做法：搜索框保持原样，分组栏作为会话 section 的 header 返回。
    [self detachBarFromTableViewHeader];
    // 只在布局阶段算一次区段，并置位 headerQuerying，防止 header 回调里再查行数造成递归。
    self.headerQuerying = YES;
    self.sessionSection = [self sessionSectionForTableView:tableView];
    self.headerQuerying = NO;
    [self installHeaderBarHooksForTableView:tableView];
    WCLog(@"layout host=%@ rows=%ld sections=%ld kind=%ld",
          NSStringFromClass([host class]), (long)[tableView numberOfRowsInSection:0],
          (long)tableView.numberOfSections, (long)self.selectedKind);

    if (self.selectedKind == WCGroupKindAll) {
        // “全部”必须是微信原样：一个过滤 hook 都不留。
        if (self.filteringEnabled) {
            [self uninstallFilterHooksForTable];
        }
        return;
    }

    BOOL wasFiltering = self.filteringEnabled;
    [self installFilterHooksForTable:tableView];

    // 首次启用过滤时重新布局一次，让高度 hook 生效。
    if (!wasFiltering && self.filteringEnabled) {
        [tableView reloadData];
    }
}

- (void)handleDiagnosticsPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self showDiagnostics];
    }
}

- (void)showDiagnostics {
    UITableView *tableView = self.sessionTableView;
    id dataSource = tableView.dataSource;
    NSArray<NSString *> *names = [self currentUsernames];

    NSMutableString *text = [NSMutableString stringWithFormat:
        @"v1.1.0+fix6\nhost: %@\ntable: %@\nds: %@\nsection: %ld  rows: %ld  users: %lu\nsections: %ld\nfiltering: %d  kind: %ld",
        NSStringFromClass([self.hostController class]),
        NSStringFromClass([tableView class]),
        NSStringFromClass([dataSource class]),
        (long)self.sessionSection,
        (long)(self.sessionSection >= 0 ? [self originalRowCountForTableView:tableView section:self.sessionSection] : 0),
        (unsigned long)names.count,
        (long)tableView.numberOfSections,
        (int)self.filteringEnabled,
        (long)self.selectedKind];

    for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
        [text appendFormat:@"\ns%ld: %ld", (long)section,
                           (long)[self originalRowCountForTableView:tableView section:section]];
    }

    NSUInteger limit = MIN(names.count, (NSUInteger)4);
    for (NSUInteger i = 0; i < limit; i++) {
        NSString *username = names[i];
        [text appendFormat:@"\n%lu: %@ -> %ld", (unsigned long)i, username,
                           (long)[WCWeChatAdapter kindForUsername:username]];
    }

    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    WCCollectTableViews(self.hostController.view, tables);
    NSUInteger tableLimit = MIN(tables.count, (NSUInteger)5);
    for (NSUInteger i = 0; i < tableLimit; i++) {
        UITableView *each = tables[i];
        id eachDataSource = each.dataSource;
        [text appendFormat:@"\n[t%lu] %@ ds=%@ rows=%ld sec=%ld getter=%d score=%.0f",
                           (unsigned long)i, NSStringFromClass([each class]),
                           NSStringFromClass([eachDataSource class]),
                           (long)[self totalRowCountForTableView:each],
                           (long)each.numberOfSections,
                           (int)[eachDataSource respondsToSelector:NSSelectorFromString(@"getSessionInfoAtIndexPath:")],
                           (double)[self scoreForSessionTable:each controller:self.hostController]];
    }
    UIView *header = self.sessionTableView.tableHeaderView;
    [text appendFormat:@"\nheader: %@ h=%.0f orig=%.0f barIn=%@",
        NSStringFromClass([header class]), (double)CGRectGetHeight(header.frame),
        (double)self.headerOriginalHeight, NSStringFromClass([self.barView.superview class])];

    WCLog(@"diagnostics %@", text);

    UIViewController *presenter = self.hostController;
    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"WCGroupBar 诊断"
                                                                  message:text
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)detachBarFromTableViewHeader {
    UIView *header = self.headerOriginalView;
    if (header && self.barView.superview == header) {
        [self.barView removeFromSuperview];
    }
    self.headerContainer = nil;
    self.headerOriginalView = nil;
    self.headerOriginalHeight = 0;
}

- (void)installHeaderBarHooksForTableView:(UITableView *)tableView {
    if (!tableView) {
        return;
    }
    [self installHeaderHooksForObject:tableView.dataSource];
    [self installHeaderHooksForObject:tableView.delegate];
}

- (void)installHeaderHooksForObject:(id)object {
    Class cls = object ? object_getClass(object) : Nil;
    if (!cls) {
        return;
    }
    if (!self.headerHookedClassNames) {
        self.headerHookedClassNames = [NSMutableArray array];
    }
    NSString *className = NSStringFromClass(cls);
    if ([self.headerHookedClassNames containsObject:className]) {
        return;
    }
    WCInstallHook(cls, NSSelectorFromString(@"tableView:viewForHeaderInSection:"), (IMP)WCHookViewForHeader);
    WCInstallHook(cls, NSSelectorFromString(@"tableView:heightForHeaderInSection:"), (IMP)WCHookHeightForHeader);
    WCInstallHook(cls, NSSelectorFromString(@"tableView:estimatedHeightForHeaderInSection:"), (IMP)WCHookEstimatedHeightForHeader);
    [self.headerHookedClassNames addObject:className];
    WCLog(@"header hook %@", className);
}

- (BOOL)shouldShowBarInTableView:(UITableView *)tableView section:(NSInteger)section {
    if (!tableView || tableView != self.sessionTableView || !self.barView) {
        return NO;
    }
    // 这里会被 UITableView 在布局过程中高频调用，绝对不能再去查行数/区段数，
    // 否则会和微信自己的布局互相触发，表现为启动卡死。只用 ensureLayout 缓存的结果。
    if (self.headerQuerying) {
        return NO;
    }
    return self.sessionSection >= 0 && section == self.sessionSection;
}

- (UIView *)barHeaderViewForTableView:(UITableView *)tableView section:(NSInteger)section {
    if (![self shouldShowBarInTableView:tableView section:section]) {
        return nil;
    }
    return self.barView;
}

- (void)attachBarToTableView:(UITableView *)tableView {
    if (!tableView || !self.barView) {
        return;
    }

    UIView *current = tableView.tableHeaderView;

    // 微信自己的表头（搜索框）不换父视图，分组栏直接加在它内部底部。
    // 这样搜索框的约束和父视图完全不变，不会被重排压成 0。
    if (current && current != self.headerContainer) {
        CGFloat height = CGRectGetHeight(current.frame);
        if (height > 1.0) {
            self.headerOriginalHeight = height;
        } else {
            CGFloat fitting = [current systemLayoutSizeFittingSize:UILayoutFittingCompressedSize].height;
            if (fitting > 1.0) {
                self.headerOriginalHeight = fitting;
            }
        }
        [self.barView removeFromSuperview];
        [current addSubview:self.barView];
        self.headerOriginalView = current;
        self.headerContainer = nil;
        [self installHeaderFrameHookForView:current];
        [self sizeHeaderContainerForTableView:tableView];
        tableView.tableHeaderView = current;
        return;
    }

    if (current == self.headerContainer) {
        if (self.barView.superview != self.headerContainer) {
            [self.barView removeFromSuperview];
            [self.headerContainer addSubview:self.barView];
        }
        [self sizeHeaderContainerForTableView:tableView];
        return;
    }

    // 微信可能自己重设过表头：旧容器里的原始表头要先还回去，避免丢失搜索框。
    if (self.headerContainer && self.headerOriginalView &&
        self.headerOriginalView.superview == self.headerContainer) {
        [self.headerOriginalView removeFromSuperview];
    }

    UIView *originalHeader = current ?: nil;
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(tableView.bounds), 0)];
    container.backgroundColor = [UIColor clearColor];
    container.clipsToBounds = YES;
    self.headerContainer = container;

    if (originalHeader) {
        [container addSubview:originalHeader];
        originalHeader.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    }
    self.headerOriginalView = originalHeader;

    [self.barView removeFromSuperview];
    [container addSubview:self.barView];
    tableView.tableHeaderView = container;
    [self sizeHeaderContainerForTableView:tableView];
}

- (void)installHeaderFrameHookForView:(UIView *)view {
    Class cls = view ? object_getClass(view) : Nil;
    if (!cls) {
        return;
    }
    WCInstallHook(cls, NSSelectorFromString(@"setFrame:"), (IMP)WCHookHeaderSetFrame);
}

- (BOOL)isGuardedHeaderView:(id)view {
    return view && view == self.headerOriginalView && self.headerOriginalHeight > 1.0;
}

- (void)layoutBarInGuardedHeader {
    UIView *header = self.headerOriginalView;
    if (!header || self.barView.superview != header) {
        return;
    }
    CGFloat width = CGRectGetWidth(header.bounds);
    if (width <= 0) {
        width = CGRectGetWidth(self.sessionTableView.bounds);
    }
    self.barView.frame = CGRectMake(0, self.headerOriginalHeight, width, WCGroupBarContainerHeight);
}

- (void)sizeHeaderContainerForTableView:(UITableView *)tableView {
    UIView *target = self.headerContainer ?: self.headerOriginalView;
    if (!target) {
        return;
    }
    CGFloat width = CGRectGetWidth(tableView.bounds);
    if (width <= 0) {
        width = CGRectGetWidth(target.frame);
    }

    CGFloat measured = self.headerOriginalView ? CGRectGetHeight(self.headerOriginalView.frame) : 0;
    if (self.headerOriginalHeight <= 1.0 && measured > 1.0) {
        // 第一次测量到的是搜索框自身高度；若已经包含分组栏，减去 44。
        self.headerOriginalHeight = (measured > WCGroupBarContainerHeight + 1.0)
            ? measured - WCGroupBarContainerHeight
            : measured;
    }
    CGFloat originalHeight = self.headerOriginalHeight > 1.0 ? self.headerOriginalHeight : 0;

    self.barView.frame = CGRectMake(0, originalHeight, width, WCGroupBarContainerHeight);
    target.frame = CGRectMake(0, 0, width, originalHeight + WCGroupBarContainerHeight);

    // tableHeaderView 只有重新赋值才会重新测量高度。
    if (tableView.tableHeaderView == target) {
        tableView.tableHeaderView = target;
    }
    [self.barView setNeedsLayout];
}

- (void)applyContentInset {
    UITableView *tableView = self.sessionTableView;
    if (!tableView) {
        return;
    }

    // 基准 inset 只在第一次接触这张表时记录，并挂在表上；
    // 之后无论布局跑多少次都不重新取基准，避免 44pt 被反复叠加、列表上下抖。
    NSNumber *stored = objc_getAssociatedObject(tableView, WCBaseInsetKey);
    CGFloat baseTop = stored ? stored.doubleValue : tableView.contentInset.top;
    if (!stored) {
        objc_setAssociatedObject(tableView, WCBaseInsetKey, @(baseTop), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat expectedTop = baseTop + WCGroupBarContainerHeight;
    UIEdgeInsets current = tableView.contentInset;
    if (fabs(current.top - expectedTop) <= 0.5) {
        return;
    }

    BOOL atTop = tableView.contentOffset.y <= -current.top + 0.5;
    current.top = expectedTop;
    tableView.contentInset = current;

    // 只在第一次撑开时把停在顶部的内容下移一次；不做每帧强制修正。
    if (atTop) {
        CGPoint offset = tableView.contentOffset;
        offset.y = -expectedTop;
        tableView.contentOffset = offset;
    }
}

- (void)restoreCurrentLayout {
    UITableView *tableView = self.sessionTableView;

    // 还回微信自己的表头，避免搜索栏被我们带走。
    if (self.headerContainer) {
        if (tableView && tableView.tableHeaderView == self.headerContainer) {
            UIView *original = self.headerOriginalView;
            [self.barView removeFromSuperview];
            if (original) {
                [original removeFromSuperview];
                original.frame = CGRectMake(0, 0, CGRectGetWidth(tableView.bounds),
                                            CGRectGetHeight(original.frame));
                tableView.tableHeaderView = original;
            } else {
                tableView.tableHeaderView = nil;
            }
        } else {
            [self.barView removeFromSuperview];
        }
        self.headerContainer = nil;
        self.headerOriginalView = nil;
    }
    self.barConstraintsInstalled = NO;

    NSNumber *stored = tableView ? objc_getAssociatedObject(tableView, WCBaseInsetKey) : nil;
    if (!tableView || !stored) {
        return;
    }

    UIEdgeInsets inset = tableView.contentInset;
    CGFloat baseTop = stored.doubleValue;
    if (fabs(inset.top - baseTop) <= 0.5) {
        return;
    }
    BOOL atTop = tableView.contentOffset.y <= -inset.top + 0.5;
    inset.top = baseTop;
    tableView.contentInset = inset;
    if (atTop) {
        CGPoint offset = tableView.contentOffset;
        offset.y = -baseTop;
        tableView.contentOffset = offset;
    }
}

- (UITableView *)sessionTableViewForController:(UIViewController *)controller {
    if (!controller || !controller.isViewLoaded) {
        return nil;
    }

    if (self.hostController == controller) {
        UITableView *cached = self.sessionTableView;
        if (cached && [cached isDescendantOfView:controller.view] && [self isUsableSessionTable:cached]) {
            return cached;
        }
    }

    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"m_tableView", @"_tableView", @"tableView", @"m_mainTableView"];
    });

    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if (![controller respondsToSelector:selector]) {
            continue;
        }
        @try {
            id value = [controller valueForKey:key];
            if ([value isKindOfClass:[UITableView class]]) {
                UITableView *tableView = (UITableView *)value;
                if ([tableView isDescendantOfView:controller.view] && [self isUsableSessionTable:tableView]) {
                    return tableView;
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }

    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    WCCollectTableViews(controller.view, tables);
    if (tables.count == 0) {
        return nil;
    }

    UITableView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UITableView *tableView in tables) {
        if (tableView.hidden || tableView.alpha < 0.01) {
            continue;
        }
        CGFloat score = [self scoreForSessionTable:tableView controller:controller];
        if (score > bestScore) {
            bestScore = score;
            best = tableView;
        }
    }
    return best;
}

- (BOOL)isUsableSessionTable:(UITableView *)tableView {
    if (!tableView) {
        return NO;
    }
    id dataSource = tableView.dataSource;
    if (![dataSource respondsToSelector:@selector(getSessionInfoAtIndexPath:)]) {
        return NO;
    }
    return [self totalRowCountForTableView:tableView] > 0;
}

- (NSInteger)totalRowCountForTableView:(UITableView *)tableView {
    NSInteger total = 0;
    NSInteger sections = tableView.numberOfSections;
    for (NSInteger section = 0; section < sections; section++) {
        total += [tableView numberOfRowsInSection:section];
    }
    return total;
}

- (CGFloat)scoreForSessionTable:(UITableView *)tableView controller:(UIViewController *)controller {
    CGRect frame = [tableView convertRect:tableView.bounds toView:controller.view];
    // 完全在屏幕外的不算。
    CGRect visible = CGRectIntersection(frame, controller.view.bounds);
    if (CGRectIsNull(visible) || CGRectGetHeight(visible) < 100) {
        return -CGFLOAT_MAX;
    }

    CGFloat score = MIN(CGRectGetHeight(visible), 2000.0);
    id dataSource = tableView.dataSource;
    NSString *dataSourceName = dataSource ? NSStringFromClass([dataSource class]) : @"";
    NSInteger rows = [self totalRowCountForTableView:tableView];

    if ([dataSource respondsToSelector:@selector(getSessionInfoAtIndexPath:)]) {
        score += 1e7;   // 会话列表的决定性特征
    } else {
        score -= 1e7;
    }
    if ([dataSourceName containsString:@"Session"]) {
        score += 1e6;
    }
    if (rows > 0) {
        score += 1e6;
    } else {
        score -= 1e6;
    }
    if (tableView.numberOfSections <= 1) {
        score += 1e5;
    }
    if (dataSource == controller) {
        score -= 5e6;   // 根控制器自己的脚手架表，不是会话列表
    }
    return score;
}

#pragma mark - WCGroupBarViewDelegate

- (void)groupBarView:(WCGroupBarView *)barView didSelectKind:(WCGroupKind)kind {
    if (kind == self.selectedKind) {
        return;
    }
    self.selectedKind = kind;
    [[NSUserDefaults standardUserDefaults] setInteger:kind forKey:WCSelectedKindDefaultsKey];
    [self resetCaches];

    UITableView *tableView = self.sessionTableView;
    if (!tableView) {
        return;
    }

    if (kind == WCGroupKindAll) {
        [self uninstallFilterHooksForTable];
    } else {
        [self installFilterHooksForTable:tableView];
    }
    [tableView reloadData];
}

#pragma mark - 过滤

- (BOOL)shouldFilterTableView:(UITableView *)tableView {
    return self.filteringEnabled &&
           self.selectedKind != WCGroupKindAll &&
           tableView &&
           tableView == self.sessionTableView;
}

- (NSInteger)filteredRowCountForDataSource:(id)dataSource
                                 tableView:(UITableView *)tableView
                                   section:(NSInteger)section
                             originalCount:(NSInteger)originalCount {
    NSArray<NSNumber *> *mapping = [self mappingForDataSource:dataSource
                                                      tableView:tableView
                                                        section:section
                                                  originalCount:originalCount];
    return mapping ? mapping.count : originalCount;
}

- (NSIndexPath *)mappedIndexPathForIndexPath:(NSIndexPath *)indexPath
                                  dataSource:(id)dataSource
                                   tableView:(UITableView *)tableView {
    if (![self shouldFilterTableView:tableView] || !indexPath) {
        return indexPath;
    }
    if (indexPath.section != self.sessionSection) {
        return indexPath;
    }
    NSInteger originalRow = [self originalRowForDisplayRow:indexPath.row];
    if (originalRow < 0) {
        return nil;
    }
    if (originalRow == indexPath.row) {
        return indexPath;
    }
    return [NSIndexPath indexPathForRow:originalRow inSection:indexPath.section];
}

- (NSIndexPath *)displayIndexPathForOriginalIndexPath:(NSIndexPath *)indexPath
                                           dataSource:(id)dataSource
                                            tableView:(UITableView *)tableView {
    if (![self shouldFilterTableView:tableView] || !indexPath) {
        return indexPath;
    }

    SEL rowsSelector = WCRowsSelector();
    IMP rowsIMP = WCGetOriginalIMP(object_getClass(dataSource), rowsSelector);
    if (!rowsIMP) {
        return indexPath;
    }
    NSInteger originalCount = ((NSInteger (*)(id, SEL, UITableView *, NSInteger))rowsIMP)(dataSource,
                                                                                           rowsSelector,
                                                                                           tableView,
                                                                                           indexPath.section);
    NSArray<NSNumber *> *mapping = [self mappingForDataSource:dataSource
                                                      tableView:tableView
                                                        section:indexPath.section
                                                  originalCount:originalCount];
    if (!mapping) {
        return indexPath;
    }

    NSUInteger displayRow = [mapping indexOfObject:@(indexPath.row)];
    if (displayRow == (NSUInteger)NSNotFound) {
        return nil;
    }
    return [NSIndexPath indexPathForRow:(NSInteger)displayRow inSection:indexPath.section];
}

- (NSArray<NSNumber *> *)mappingForDataSource:(id)dataSource
                                     tableView:(UITableView *)tableView
                                       section:(NSInteger)section
                                 originalCount:(NSInteger)originalCount {
    if (originalCount <= 0) {
        return @[];
    }

    NSNumber *key = @(section);
    NSDictionary *cachedUsernameEntry = self.usernameCache[key];
    NSArray *usernames = nil;
    if (cachedUsernameEntry && [cachedUsernameEntry[@"count"] integerValue] == originalCount) {
        usernames = cachedUsernameEntry[@"usernames"];
    }

    if (!usernames) {
        // 这里必须取“原始行”的会话，不能走被 hook 的取数方法，否则会被二次重映射。
        NSMutableArray *built = [NSMutableArray arrayWithCapacity:(NSUInteger)originalCount];
        NSArray *sessions = nil;
        for (NSInteger row = 0; row < originalCount; row++) {
            id info = [self originalSessionInfoForRow:row section:section dataSource:dataSource];
            NSString *username = [WCWeChatAdapter usernameForSessionInfo:info];
            if (username.length == 0) {
                if (!sessions) {
                    sessions = [WCWeChatAdapter sessionArrayFromDataSource:dataSource] ?: @[];
                }
                if (row < (NSInteger)sessions.count) {
                    username = [WCWeChatAdapter usernameForSessionInfo:sessions[(NSUInteger)row]];
                }
            }
            [built addObject:username.length > 0 ? username : [NSNull null]];
        }
        usernames = [built copy];
        self.usernameCache[key] = @{@"count": @(originalCount), @"usernames": usernames};
        [self.mappingCache removeObjectForKey:key];
    }

    NSInteger resolvableCount = 0;
    for (id username in usernames) {
        if (username != [NSNull null]) {
            resolvableCount++;
        }
    }
    if (resolvableCount == 0) {
        // 该分区一行 username 都解析不出（非会话分区或版本差异），退化为不过滤。
        return nil;
    }

    NSDictionary *cachedMappingEntry = self.mappingCache[key];
    if (cachedMappingEntry &&
        [cachedMappingEntry[@"count"] integerValue] == originalCount &&
        [cachedMappingEntry[@"kind"] integerValue] == self.selectedKind) {
        return cachedMappingEntry[@"rows"];
    }

    NSMutableArray<NSNumber *> *rows = [NSMutableArray arrayWithCapacity:usernames.count];
    for (NSInteger row = 0; row < (NSInteger)usernames.count; row++) {
        id username = usernames[(NSUInteger)row];
        BOOL include = YES;
        if (username != [NSNull null]) {
            include = ([WCWeChatAdapter kindForUsername:(NSString *)username] == self.selectedKind);
        }
        if (include) {
            [rows addObject:@(row)];
        }
    }

    NSArray<NSNumber *> *result = [rows copy];
    self.mappingCache[key] = @{@"count": @(originalCount),
                               @"kind": @(self.selectedKind),
                               @"rows": result};
    return result;
}

- (NSArray<NSString *> *)currentUsernames {
    if (self.usernames) {
        return self.usernames;
    }

    UITableView *tableView = self.sessionTableView;
    id dataSource = tableView.dataSource;
    NSInteger section = [self sessionSectionForTableView:tableView];
    NSInteger rows = section >= 0 ? [self originalRowCountForTableView:tableView section:section] : 0;
    if (section < 0 || rows <= 0) {
        WCLog(@"no session section section=%ld rows=%ld", (long)section, (long)rows);
        return nil;
    }
    self.sessionSection = section;

    // 1) 列表控制器自己的取数方法
    NSArray<NSString *> *names = [self usernamesFromObject:dataSource
                                                   section:section
                                                      rows:rows
                                                dataSource:dataSource];
    // 2) 根控制器 / logic controller
    if (!names && self.hostController) {
        id logic = WCSafeValue(self.hostController, @"m_mainFrameLogicController");
        if (!logic) {
            logic = WCSafeValue(self.hostController, @"mainFrameLogicController");
        }
        if (logic) {
            names = [self usernamesFromObject:logic section:section rows:rows dataSource:logic];
            WCLog(@"logic %@ -> %lu", NSStringFromClass([logic class]), (unsigned long)names.count);
        }
    }
    // 3) 微信的会话管理器
    if (!names) {
        NSArray *sessions = [WCWeChatAdapter allSessions];
        if (sessions.count == (NSUInteger)rows) {
            NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:sessions.count];
            for (id info in sessions) {
                NSString *username = [WCWeChatAdapter usernameForSessionInfo:info];
                [list addObject:username.length > 0 ? username : @""];
            }
            if (list.count == (NSUInteger)rows) {
                names = [list copy];
            }
        }
        WCLog(@"manager sessions=%lu rows=%ld", (unsigned long)sessions.count, (long)rows);
    }

    // 4) 最后手段：让列表自己造 cell，从 cell 里读出 username。
    if (!names && !WCIsBuildingCells()) {
        names = [self usernamesFromCellsForTableView:tableView
                                             section:section
                                                rows:rows
                                          dataSource:dataSource];
        WCLog(@"cells -> %lu", (unsigned long)names.count);
    }

    if (!names || names.count != (NSUInteger)rows) {
        WCLog(@"usernames unresolved rows=%ld count=%lu", (long)rows, (unsigned long)names.count);
        return nil;
    }

    self.usernames = names;
    WCLog(@"users section=%ld rows=%ld head=%@", (long)section, (long)rows,
          [names subarrayWithRange:NSMakeRange(0, MIN(names.count, (NSUInteger)4))]);
    return self.usernames;
}

/// 兜底：直接让 dataSource 造出每一行的 cell，再从 cell 里递归找 username。
- (NSArray<NSString *> *)usernamesFromCellsForTableView:(UITableView *)tableView
                                                section:(NSInteger)section
                                                   rows:(NSInteger)rows
                                             dataSource:(id)dataSource {
    if (!tableView || !dataSource || rows <= 0) {
        return nil;
    }
    Class cls = object_getClass(dataSource);
    IMP imp = WCGetOriginalIMP(cls, WCCellSelector());
    if (!imp && [dataSource respondsToSelector:WCCellSelector()]) {
        imp = [dataSource methodForSelector:WCCellSelector()];
    }
    if (!imp) {
        return nil;
    }

    NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:(NSUInteger)rows];
    WCUsernameBuilderDepth++;
    @try {
        for (NSInteger row = 0; row < rows; row++) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
            UITableViewCell *cell = ((UITableViewCell * (*)(id, SEL, UITableView *, NSIndexPath *))imp)(
                dataSource, WCCellSelector(), tableView, indexPath);
            NSString *username = [WCWeChatAdapter usernameForSessionInfo:cell];
            [list addObject:username.length > 0 ? username : @""];
        }
    } @finally {
        WCUsernameBuilderDepth--;
    }

    NSUInteger resolved = 0;
    for (NSString *name in list) {
        if (name.length > 0) {
            resolved++;
        }
    }
    WCLog(@"cells resolved=%lu/%ld", (unsigned long)resolved, (long)rows);
    return resolved == (NSUInteger)rows ? [list copy] : nil;
}

/// 依次尝试 getSessionInfoAtIndexPath: / logicGetSessionAtIndexPath:，取不到返回 nil。
- (NSArray<NSString *> *)usernamesFromObject:(id)object
                                     section:(NSInteger)section
                                        rows:(NSInteger)rows
                                  dataSource:(id)dataSource {
    if (!object || rows <= 0) {
        return nil;
    }
    for (NSString *name in @[@"getSessionInfoAtIndexPath:", @"logicGetSessionAtIndexPath:"]) {
        SEL selector = NSSelectorFromString(name);
        Class cls = object_getClass(object);
        IMP imp = WCGetOriginalIMP(cls, selector);
        if (!imp && [object respondsToSelector:selector]) {
            imp = [object methodForSelector:selector];
        }
        if (!imp) {
            continue;
        }
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:(NSUInteger)rows];
        BOOL complete = YES;
        for (NSInteger i = 0; i < rows; i++) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:i inSection:section];
            id info = ((id (*)(id, SEL, NSIndexPath *))imp)(object, selector, indexPath);
            NSString *username = [WCWeChatAdapter usernameForSessionInfo:info];
            if (username.length == 0) {
                complete = NO;
                break;
            }
            [names addObject:username];
        }
        WCLog(@"object %@ %@ complete=%d count=%lu",
              NSStringFromClass([object class]), name, complete, (unsigned long)names.count);
        if (complete && names.count == (NSUInteger)rows) {
            return [names copy];
        }
    }
    return nil;
}

- (NSInteger)sessionSectionForTableView:(UITableView *)tableView {
    if (!tableView) {
        return -1;
    }
    NSInteger sections = tableView.numberOfSections;
    if (sections <= 0) {
        return -1;
    }
    if (sections == 1) {
        return 0;
    }
    NSInteger bestSection = -1;
    NSInteger bestCount = 0;
    for (NSInteger section = 0; section < sections; section++) {
        NSInteger count = [self originalRowCountForTableView:tableView section:section];
        if (count > bestCount) {
            bestCount = count;
            bestSection = section;
        }
    }
    return bestSection;
}

- (NSInteger)originalRowCountForTableView:(UITableView *)tableView section:(NSInteger)section {
    if (!tableView) {
        return 0;
    }
    id dataSource = tableView.dataSource;
    Class dataSourceClass = dataSource ? object_getClass(dataSource) : Nil;
    IMP rowsIMP = dataSourceClass ? WCGetOriginalIMP(dataSourceClass, WCRowsSelector()) : NULL;
    if (rowsIMP) {
        return ((NSInteger (*)(id, SEL, UITableView *, NSInteger))rowsIMP)(dataSource, WCRowsSelector(), tableView, section);
    }
    return [tableView numberOfRowsInSection:section];
}

- (BOOL)shouldHideRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.section != 0) {
        return NO;
    }
    UITableView *tableView = self.sessionTableView;
    if (!tableView || tableView.numberOfSections != 1) {
        return NO;
    }
    NSArray<NSString *> *names = [self currentUsernames];
    if (!names || indexPath.row < 0 || indexPath.row >= (NSInteger)names.count) {
        return NO;
    }
    // 顺序必须和列表完全对齐，否则宁可不过滤，避免错位。
    if ([tableView numberOfRowsInSection:0] != (NSInteger)names.count) {
        return NO;
    }
    NSString *username = names[(NSUInteger)indexPath.row];
    if (username.length == 0) {
        return NO;
    }
    return [WCWeChatAdapter kindForUsername:username] != self.selectedKind;
}

- (NSInteger)visibleRowCount {
    NSArray<NSString *> *names = [self currentUsernames];
    NSInteger count = 0;
    for (NSString *username in names) {
        if (username.length > 0 && [WCWeChatAdapter kindForUsername:username] == self.selectedKind) {
            count++;
        }
    }
    return count;
}

- (NSInteger)originalRowForDisplayRow:(NSInteger)row {
    NSArray<NSString *> *names = [self currentUsernames];
    if (!names || row < 0) {
        return -1;
    }
    NSInteger display = 0;
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        NSString *username = names[(NSUInteger)i];
        if (username.length == 0 || [WCWeChatAdapter kindForUsername:username] != self.selectedKind) {
            continue;
        }
        if (display == row) {
            return i;
        }
        display++;
    }
    return -1;
}

- (void)resetCaches {
    [self.usernameCache removeAllObjects];
    [self.mappingCache removeAllObjects];
    self.usernames = nil;
}

- (void)tableViewDidReload:(UITableView *)tableView {
    if (tableView != self.sessionTableView) {
        return;
    }
    if (self.selectedKind != WCGroupKindAll) {
        [self installFilterHooksForTable:tableView];
    }
    [self resetCaches];
}

@end
