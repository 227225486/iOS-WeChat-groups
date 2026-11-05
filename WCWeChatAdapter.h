#import <UIKit/UIKit.h>
#import "WCGroupBarView.h"

/**
 * 微信内部会话模型的适配层。
 *
 * 微信不同版本会改类名和属性名，所以这里不直接链接私有类，而是：
 * - 优先用 MMSessionListViewController / NewMainFrameViewController 的公开选择器；
 * - 再用 KVC 探测 m_nsUserName 等常见会话属性；
 * - 都失败时按“私聊”处理，不影响列表继续显示。
 */
@interface WCWeChatAdapter : NSObject

/// 从一个 SessionInfo / CContact / cell 对象里取出会话 username。
+ (NSString *)usernameForSessionInfo:(id)info;

/// 根据 username（以及能查到的 CContact）判断会话分组。
+ (WCGroupKind)kindForUsername:(NSString *)username;

/// 列出来自 MMNewSessionMgr 的完整会话数组，失败返回 nil。
+ (NSArray *)allSessions;

/// 通过 typed 数据源取第 row 行的会话对象。
+ (id)sessionInfoForRow:(NSInteger)row section:(NSInteger)section dataSource:(id)dataSource;

/// 通过 typed 数据源取第 row 行的会话 username，失败返回 nil。
+ (NSString *)usernameForRow:(NSInteger)row section:(NSInteger)section dataSource:(id)dataSource;

/// 在 typed 数据源对象里查找会话数组（m_arrSession / m_sessionArray / sessionArray ...）。
+ (NSArray *)sessionArrayFromDataSource:(id)dataSource;

@end
