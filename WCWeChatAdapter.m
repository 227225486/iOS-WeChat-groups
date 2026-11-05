#import "WCWeChatAdapter.h"
#import <objc/runtime.h>
#import <objc/message.h>

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

static BOOL WCBoolMethod(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) {
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) {
        return NO;
    }
    IMP imp = [object methodForSelector:selector];
    if (!imp) {
        return NO;
    }
    BOOL (*function)(id, SEL) = (BOOL (*)(id, SEL))imp;
    return function(object, selector);
}

static NSString *WCUsernameFromObject(id object, NSUInteger depth) {
    if (!object || depth > 6 || object == [NSNull null]) {
        return nil;
    }
    if ([object isKindOfClass:[NSString class]]) {
        NSString *string = (NSString *)object;
        return string.length > 0 ? string : nil;
    }
    if ([object isKindOfClass:[NSNumber class]]) {
        return nil;
    }

    static NSArray<NSString *> *keys;
    static dispatch_once_t keysOnceToken;
    dispatch_once(&keysOnceToken, ^{
        keys = @[
            @"m_nsUserName",
            @"m_nsUsrName",
            @"m_nsUsername",
            @"m_nsUserNameString",
            @"m_nsSessionUserName",
            @"sessionUserName",
            @"sessionUsername",
            @"userName",
            @"username",
        ];
    });

    for (NSString *key in keys) {
        id value = WCSafeValue(object, key);
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            return (NSString *)value;
        }
    }

    static NSArray<NSString *> *relatedKeys;
    static dispatch_once_t relatedOnceToken;
    dispatch_once(&relatedOnceToken, ^{
        relatedKeys = @[
            @"m_oSessionInfo",
            @"m_sessionInfo",
            @"sessionInfo",
            @"m_oCellData",
            @"m_cellData",
            @"cellData",
            @"m_oSession",
            @"m_session",
            @"m_oContact",
            @"m_contact",
            @"contact",
        ];
    });

    for (NSString *key in relatedKeys) {
        id value = WCSafeValue(object, key);
        if (value && value != object) {
            NSString *username = WCUsernameFromObject(value, depth + 1);
            if (username.length > 0) {
                return username;
            }
        }
    }

    return nil;
}

@interface WCWeChatAdapter ()
+ (id)serviceCenter;
+ (id)serviceFromCenter:(id)center class:(Class)serviceClass;
+ (id)contactForUsername:(NSString *)username;
+ (NSInteger)scoreForSessionArray:(NSArray *)array key:(NSString *)key;
@end

@implementation WCWeChatAdapter

+ (NSString *)usernameForSessionInfo:(id)info {
    return WCUsernameFromObject(info, 0);
}

+ (NSArray *)allSessions {
    static NSArray<NSString *> *managerClasses;
    static dispatch_once_t managerOnceToken;
    dispatch_once(&managerOnceToken, ^{
        managerClasses = @[@"MMNewSessionMgr", @"MainSessionMgr"];
    });

    id center = [self serviceCenter];
    if (!center) {
        return nil;
    }

    static NSArray<NSString *> *listSelectors;
    static dispatch_once_t listOnceToken;
    dispatch_once(&listOnceToken, ^{
        listSelectors = @[
            @"GetUserNamesOnSessionList",
            @"GetSessionList",
            @"getSessionList",
            @"GetSessionInfoList",
            @"getSessionArray",
            @"getAllSession",
            @"allSessions",
        ];
    });

    for (NSString *className in managerClasses) {
        Class managerClass = objc_getClass(className.UTF8String);
        if (!managerClass) {
            continue;
        }
        id manager = [self serviceFromCenter:center class:managerClass];
        if (!manager) {
            continue;
        }
        for (NSString *selectorName in listSelectors) {
            SEL selector = NSSelectorFromString(selectorName);
            if (![manager respondsToSelector:selector]) {
                continue;
            }
            IMP imp = [manager methodForSelector:selector];
            id (*function)(id, SEL) = (id (*)(id, SEL))imp;
            id value = function(manager, selector);
            if ([value isKindOfClass:[NSArray class]]) {
                return (NSArray *)value;
            }
        }
    }
    return nil;
}

+ (id)sessionInfoForRow:(NSInteger)row section:(NSInteger)section dataSource:(id)dataSource {
    if (!dataSource || row < 0) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"getSessionInfoAtIndexPath:");
    if ([dataSource respondsToSelector:selector]) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
        IMP imp = [dataSource methodForSelector:selector];
        id (*function)(id, SEL, id) = (id (*)(id, SEL, id))imp;
        id info = function(dataSource, selector, indexPath);
        if (info) {
            return info;
        }
    }

    NSArray *sessions = [self sessionArrayFromDataSource:dataSource];
    if (row < (NSInteger)sessions.count) {
        return sessions[(NSUInteger)row];
    }
    return nil;
}

+ (NSString *)usernameForRow:(NSInteger)row section:(NSInteger)section dataSource:(id)dataSource {
    id info = [self sessionInfoForRow:row section:section dataSource:dataSource];
    NSString *username = WCUsernameFromObject(info, 0);
    if (username.length > 0) {
        return username;
    }
    return nil;
}

+ (NSArray *)sessionArrayFromDataSource:(id)dataSource {
    if (!dataSource) {
        return nil;
    }

    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"m_arrSession",
            @"m_arrSessions",
            @"m_arrSessionList",
            @"m_sessionArray",
            @"sessionArray",
            @"sessionList",
            @"m_arrFilteredSession",
            @"m_arrDisplayedSession",
            @"allSessions",
        ];
    });

    NSArray *bestArray = nil;
    NSInteger bestScore = NSIntegerMin;

    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if (![dataSource respondsToSelector:selector]) {
            continue;
        }
        id value = WCSafeValue(dataSource, key);
        if (![value isKindOfClass:[NSArray class]]) {
            continue;
        }
        NSInteger score = [self scoreForSessionArray:value key:key];
        if (score > bestScore) {
            bestScore = score;
            bestArray = (NSArray *)value;
        }
    }

    if (bestArray) {
        return bestArray;
    }

    // 有些版本会把会话数组放在一个不起眼的 ivar 里，最后再做一次 ivar 扫描。
    Class currentClass = [dataSource class];
    while (currentClass && currentClass != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(currentClass, &count);
        if (ivars) {
            for (unsigned int i = 0; i < count; i++) {
                Ivar ivar = ivars[i];
                const char *typeEncoding = ivar_getTypeEncoding(ivar);
                if (!typeEncoding || typeEncoding[0] != '@') {
                    continue;
                }
                id value = object_getIvar(dataSource, ivar);
                if (![value isKindOfClass:[NSArray class]]) {
                    continue;
                }
                NSString *name = [NSString stringWithUTF8String:ivar_getName(ivar)] ?: @"";
                NSInteger score = [self scoreForSessionArray:value key:name];
                if (score > bestScore) {
                    bestScore = score;
                    bestArray = (NSArray *)value;
                }
            }
            free(ivars);
        }
        currentClass = class_getSuperclass(currentClass);
    }

    return bestArray;
}

+ (NSInteger)scoreForSessionArray:(NSArray *)array key:(NSString *)key {
    NSInteger score = 0;
    NSString *lowercaseKey = key.lowercaseString;
    if ([lowercaseKey containsString:@"session"] || [lowercaseKey containsString:@"arrsession"]) {
        score += 20;
    }
    if ([lowercaseKey containsString:@"filter"] || [lowercaseKey containsString:@"search"]) {
        score -= 15;
    }

    NSUInteger probeCount = MIN(array.count, 3);
    for (NSUInteger i = 0; i < probeCount; i++) {
        if (WCUsernameFromObject(array[i], 0).length > 0) {
            score += 10;
        }
    }
    if (array.count > 0) {
        score += MIN((NSInteger)array.count, 200) / 10;
    }
    return score;
}

#pragma mark - WeChat private services

+ (id)serviceCenter {
    static id center;
    if (center) {
        return center;
    }
    Class centerClass = objc_getClass("MMServiceCenter");
    if (!centerClass) {
        return nil;
    }
    for (NSString *selectorName in @[@"defaultCenter", @"sharedInstance", @"sharedCenter"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![centerClass respondsToSelector:selector]) {
            continue;
        }
        IMP imp = [centerClass methodForSelector:selector];
        id (*function)(id, SEL) = (id (*)(id, SEL))imp;
        center = function((id)centerClass, selector);
        if (center) {
            break;
        }
    }
    return center;
}

+ (id)serviceFromCenter:(id)center class:(Class)serviceClass {
    if (!center || !serviceClass) {
        return nil;
    }
    SEL selector = NSSelectorFromString(@"getService:");
    if (![center respondsToSelector:selector]) {
        return nil;
    }
    IMP imp = [center methodForSelector:selector];
    id (*function)(id, SEL, id) = (id (*)(id, SEL, id))imp;
    return function(center, selector, (id)serviceClass);
}

+ (id)contactForUsername:(NSString *)username {
    if (username.length == 0) {
        return nil;
    }

    static NSCache<NSString *, id> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 2000;
    });

    id cached = [cache objectForKey:username];
    if (cached) {
        return cached;
    }

    Class contactManagerClass = objc_getClass("CContactMgr");
    id center = [self serviceCenter];
    id manager = [self serviceFromCenter:center class:contactManagerClass];
    if (!manager) {
        return nil;
    }

    static NSArray<NSString *> *selectors;
    static dispatch_once_t selectorsOnceToken;
    dispatch_once(&selectorsOnceToken, ^{
        selectors = @[
            @"getContactByName:",
            @"getContactByUsername:",
            @"getContactWithUserName:",
            @"getContact:",
        ];
    });

    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![manager respondsToSelector:selector]) {
            continue;
        }
        IMP imp = [manager methodForSelector:selector];
        id (*function)(id, SEL, id) = (id (*)(id, SEL, id))imp;
        id contact = function(manager, selector, username);
        if (contact) {
            [cache setObject:contact forKey:username];
            return contact;
        }
    }
    return nil;
}

+ (WCGroupKind)kindForUsername:(NSString *)username {
    if (username.length == 0) {
        return WCGroupKindDirect;
    }

    if ([username hasSuffix:@"@chatroom"] || [username hasPrefix:@"@@"]) {
        return WCGroupKindChatRoom;
    }

    id contact = [self contactForUsername:username];
    if (contact) {
        if (WCBoolMethod(contact, @"isChatRoomContact")) {
            return WCGroupKindChatRoom;
        }
        if (WCBoolMethod(contact, @"isEnterpriseContact") ||
            WCBoolMethod(contact, @"isWeComContact") ||
            WCBoolMethod(contact, @"isWecomContact")) {
            return WCGroupKindEnterprise;
        }
        if (WCBoolMethod(contact, @"isBrandContact")) {
            return WCGroupKindOfficial;
        }
    }

    // 企业号 / 企业微信相关账号的常见 username 特征。
    if ([username hasPrefix:@"wm"] ||
        [username hasPrefix:@"wo"] ||
        [username hasPrefix:@"wb"] ||
        [username hasPrefix:@"@"]) {
        return WCGroupKindEnterprise;
    }

    if ([username hasPrefix:@"gh_"]) {
        return WCGroupKindOfficial;
    }

    return WCGroupKindDirect;
}

@end
