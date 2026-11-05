#import "WCGroupBarView.h"

static const CGFloat WCGroupBarHeight = 44.0;

static UIColor *WCAccentColor(void) {
    return [UIColor colorWithRed:0.027 green:0.757 blue:0.376 alpha:1.0];
}

static UIColor *WCNormalTextColor(void) {
    return [UIColor colorWithRed:0.102 green:0.102 blue:0.102 alpha:1.0];
}

@interface WCGroupBarView ()
@property (nonatomic, strong) UIStackView *stackView;
@property (nonatomic, strong) NSArray<UIButton *> *chips;
@property (nonatomic, strong) NSArray<UIView *> *underlines;
@property (nonatomic, assign, readwrite) WCGroupKind selectedKind;
@end

@implementation WCGroupBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    self.backgroundColor = [UIColor whiteColor];
    self.selectedKind = WCGroupKindAll;

    _stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stackView.translatesAutoresizingMaskIntoConstraints = NO;
    _stackView.axis = UILayoutConstraintAxisHorizontal;
    _stackView.alignment = UIStackViewAlignmentFill;
    _stackView.distribution = UIStackViewDistributionFillEqually;
    _stackView.spacing = 0.0;
    [self addSubview:_stackView];

    NSArray<NSString *> *titles = @[@"全部", @"群聊", @"私聊", @"企业号", @"公众号"];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray arrayWithCapacity:titles.count];
    NSMutableArray<UIView *> *underlines = [NSMutableArray arrayWithCapacity:titles.count];

    [titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger idx, BOOL *stop) {
        UIButton *chip = [UIButton buttonWithType:UIButtonTypeCustom];
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        chip.tag = (NSInteger)idx;
        chip.contentEdgeInsets = UIEdgeInsetsZero;
        [chip setTitle:title forState:UIControlStateNormal];
        [chip addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        chip.accessibilityTraits = UIAccessibilityTraitButton;

        UIView *underline = [[UIView alloc] initWithFrame:CGRectZero];
        underline.translatesAutoresizingMaskIntoConstraints = NO;
        underline.backgroundColor = WCAccentColor();
        underline.layer.cornerRadius = 1.5;
        underline.userInteractionEnabled = NO;
        underline.hidden = (idx != 0);

        [_stackView addArrangedSubview:chip];
        [self addSubview:underline];

        // 选中态下划线：按钮底部居中，宽 18、高 3。
        [NSLayoutConstraint activateConstraints:@[
            [underline.centerXAnchor constraintEqualToAnchor:chip.centerXAnchor],
            [underline.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4.0],
            [underline.widthAnchor constraintEqualToConstant:18.0],
            [underline.heightAnchor constraintEqualToConstant:3.0],
        ]];

        [buttons addObject:chip];
        [underlines addObject:underline];
    }];

    _chips = [buttons copy];
    _underlines = [underlines copy];

    [NSLayoutConstraint activateConstraints:@[
        [_stackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8.0],
        [_stackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8.0],
        [_stackView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_stackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    [self updateChipStylesAnimated:NO];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, WCGroupBarHeight);
}

- (void)chipTapped:(UIButton *)sender {
    WCGroupKind kind = (WCGroupKind)sender.tag;
    if (kind == self.selectedKind) {
        return;
    }
    [self setSelectedKind:kind animated:YES];
    [self.delegate groupBarView:self didSelectKind:kind];
}

- (void)setSelectedKind:(WCGroupKind)kind animated:(BOOL)animated {
    if (kind < WCGroupKindAll || kind > WCGroupKindOfficial) {
        return;
    }
    if (_selectedKind == kind) {
        [self updateChipStylesAnimated:animated];
        return;
    }
    _selectedKind = kind;
    [self updateChipStylesAnimated:animated];
}

- (void)updateChipStylesAnimated:(BOOL)animated {
    void (^updates)(void) = ^{
        [self.chips enumerateObjectsUsingBlock:^(UIButton *chip, NSUInteger idx, BOOL *stop) {
            BOOL selected = ((WCGroupKind)idx == self.selectedKind);
            chip.titleLabel.font = [UIFont systemFontOfSize:15.0
                                                       weight:selected ? UIFontWeightSemibold : UIFontWeightRegular];
            [chip setTitleColor:selected ? WCAccentColor() : WCNormalTextColor()
                        forState:UIControlStateNormal];
        }];
        [self.underlines enumerateObjectsUsingBlock:^(UIView *line, NSUInteger idx, BOOL *stop) {
            line.hidden = ((WCGroupKind)idx != self.selectedKind);
        }];
    };

    if (animated) {
        [UIView animateWithDuration:0.15 animations:updates];
    } else {
        updates();
    }
}

- (void)handleTapAtPoint:(CGPoint)point {
    for (UIButton *chip in self.chips) {
        CGRect frame = [chip convertRect:chip.bounds toView:self];
        if (CGRectContainsPoint(frame, point)) {
            [self chipTapped:chip];
            return;
        }
    }
}

@end
