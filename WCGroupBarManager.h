#import <Foundation/Foundation.h>

@interface WCGroupBarManager : NSObject

+ (instancetype)sharedManager;

/// 安装微信会话列表的运行时 hook，并给主会话列表挂上分组栏。
- (void)install;

@end
