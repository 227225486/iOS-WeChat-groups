#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, WCGroupKind) {
    WCGroupKindAll = 0,
    WCGroupKindChatRoom,
    WCGroupKindDirect,
    WCGroupKindEnterprise,
    WCGroupKindOfficial,
};

@class WCGroupBarView;

@protocol WCGroupBarViewDelegate <NSObject>
- (void)groupBarView:(WCGroupBarView *)barView didSelectKind:(WCGroupKind)kind;
@end

/**
 * 微信会话列表顶部的横向分组栏。
 * 视觉参考微信的浅灰底 + 白色胶囊选中态 + 微信绿文字。
 */
@interface WCGroupBarView : UIView

@property (nonatomic, weak) id<WCGroupBarViewDelegate> delegate;
@property (nonatomic, assign, readonly) WCGroupKind selectedKind;

- (void)setSelectedKind:(WCGroupKind)kind animated:(BOOL)animated;

// 供窗口级兜底手势使用：按坐标模拟点击某个胶囊。
- (void)handleTapAtPoint:(CGPoint)point;

@end
