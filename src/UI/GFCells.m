#import "GFCells.h"
#import "GFTheme.h"
#import "GFUtils.h"
#import "GFCommon.h"

@interface GFGameCell ()
@property (nonatomic, strong) GFImageView *coverView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UIImageView *cardView;
@end

@implementation GFGameCell

+ (CGSize)cellSizeForWidth:(CGFloat)width
{
    // box art is 3:4; columns by width
    NSInteger columns = width >= 1000 ? 6 : width >= 700 ? 5 : width >= 460 ? 4 : 3;
    CGFloat spacing = 10;
    CGFloat w = floor((width - spacing * (columns + 1)) / columns);
    return CGSizeMake(w, floor(w * 4 / 3) + 40);
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        GFTheme *theme = [GFTheme shared];
        _cardView = [[UIImageView alloc] initWithFrame:self.bounds];
        _cardView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cardView.image = [theme cardBackgroundImage];
        [self.contentView addSubview:_cardView];
        _coverView = [[GFImageView alloc] initWithFrame:CGRectZero];
        _coverView.contentMode = UIViewContentModeScaleAspectFill;
        _coverView.clipsToBounds = YES;
        _coverView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
        [self.contentView addSubview:_coverView];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont boldSystemFontOfSize:GFIsPad() ? 13 : 12];
        _titleLabel.numberOfLines = 2;
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.textColor = [theme primaryTextColor];
        [self.contentView addSubview:_titleLabel];
        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _badgeLabel.font = [theme tinyBoldFont];
        _badgeLabel.textColor = [UIColor whiteColor];
        _badgeLabel.backgroundColor = [UIColor clearColor];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.hidden = YES;
        [self.contentView addSubview:_badgeLabel];
        self.selectedBackgroundView = [[UIImageView alloc] initWithImage:[theme cardBackgroundImageHighlighted]];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    CGFloat coverH = b.size.height - 40;
    self.coverView.frame = CGRectMake(4, 4, b.size.width - 8, coverH - 8);
    self.titleLabel.frame = CGRectMake(6, coverH - 2, b.size.width - 12, 36);
    CGSize badge = [self.badgeLabel.text sizeWithFont:self.badgeLabel.font];
    self.badgeLabel.frame = CGRectMake(8, 8, badge.width + 12, 18);
}

- (void)showGame:(GFGame *)game
{
    GFTheme *theme = [GFTheme shared];
    self.cardView.image = [theme cardBackgroundImage];
    self.titleLabel.textColor = [theme primaryTextColor];
    self.titleLabel.text = [GFUtils displayText:game.title];
    [self.coverView setImageURL:game.coverURL placeholder:[theme boxArtPlaceholder]];
    NSString *badge = nil;
    if ([game.status isEqualToString:@"MAINTENANCE"]) badge = L(@"MAINTENANCE");
    else if ([game.status isEqualToString:@"PATCHING"]) badge = L(@"UPDATING");
    else if (game.freeToPlay && !game.owned) badge = L(@"FREE");
    self.badgeLabel.text = badge;
    self.badgeLabel.hidden = badge == nil;
    UIColor *color = [game.status isEqualToString:@"MAINTENANCE"] ? [UIColor colorWithRed:0.75 green:0.2 blue:0.2 alpha:1] : [theme accentColor];
    UIImage *pill = [theme pillImageWithColor:color];
    self.badgeLabel.layer.contents = (id)pill.CGImage;
    self.badgeLabel.layer.contentsCenter = CGRectMake(0.45, 0.45, 0.1, 0.1);
    [self setNeedsLayout];
}

- (void)prepareForReuse
{
    [super prepareForReuse];
    [self.coverView setImageURL:nil placeholder:nil];
    self.badgeLabel.hidden = YES;
}

@end
