#import "GFGamepadOverlayView.h"
#import "GFCommon.h"

typedef enum {
    CtlNone = 0, CtlLeftStick, CtlRightStick, CtlDpad, CtlA, CtlB, CtlX, CtlY, CtlLB, CtlRB, CtlLT, CtlRT, CtlBack, CtlStart, CtlCount
} GFControl;

typedef struct {
    CGRect frame;          // hit area
    CGPoint center;
    CGFloat radius;        // for round controls
} GFControlGeometry;

@interface GFGamepadOverlayView ()
@property (nonatomic) GFGamepadState state;
@property (nonatomic, strong) NSMutableDictionary *touchControl;   // touch pointer -> @(control)
@end

@implementation GFGamepadOverlayView {
    GFControlGeometry _geom[CtlCount];
    CGPoint _leftKnob, _rightKnob;      // offsets from the stick centers
    CGFloat _scale;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = YES;
        self.opaque = NO;
        self.contentMode = UIViewContentModeRedraw;
        _controlOpacity = 0.45;
        _touchControl = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)setControlOpacity:(CGFloat)controlOpacity
{
    _controlOpacity = controlOpacity;
    [self setNeedsDisplay];
}

#pragma mark - Layout

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _scale = MIN(1.0, MIN(w, h) / 700.0);
    if (_scale < 0.55) _scale = 0.55;
    CGFloat s = _scale;
    CGFloat stickR = 70 * s, knobR = 30 * s;
    (void)knobR;
    // sticks in the bottom corners
    _geom[CtlLeftStick].center = CGPointMake(120 * s, h - 120 * s);
    _geom[CtlLeftStick].radius = stickR;
    _geom[CtlRightStick].center = CGPointMake(w - 120 * s, h - 120 * s);
    _geom[CtlRightStick].radius = stickR;
    for (int c = CtlLeftStick; c <= CtlRightStick; c++) {
        _geom[c].frame = CGRectMake(_geom[c].center.x - stickR * 1.4, _geom[c].center.y - stickR * 1.4, stickR * 2.8, stickR * 2.8);
    }
    // D-pad above the left stick, ABXY above the right stick
    CGFloat dpadR = 62 * s;
    _geom[CtlDpad].center = CGPointMake(120 * s, h - 300 * s);
    _geom[CtlDpad].radius = dpadR;
    _geom[CtlDpad].frame = CGRectMake(_geom[CtlDpad].center.x - dpadR, _geom[CtlDpad].center.y - dpadR, dpadR * 2, dpadR * 2);
    CGPoint cluster = CGPointMake(w - 120 * s, h - 300 * s);
    CGFloat br = 28 * s, gap = 50 * s;
    CGPoint centers[4] = { CGPointMake(cluster.x, cluster.y + gap), CGPointMake(cluster.x + gap, cluster.y), CGPointMake(cluster.x - gap, cluster.y), CGPointMake(cluster.x, cluster.y - gap) };
    GFControl buttons[4] = { CtlA, CtlB, CtlX, CtlY };
    for (int i = 0; i < 4; i++) {
        _geom[buttons[i]].center = centers[i];
        _geom[buttons[i]].radius = br;
        _geom[buttons[i]].frame = CGRectMake(centers[i].x - br * 1.2, centers[i].y - br * 1.2, br * 2.4, br * 2.4);
    }
    // bumpers and triggers in the top corners
    CGFloat bw = 100 * s, bh = 38 * s;
    _geom[CtlLB].frame = CGRectMake(24 * s, 70 * s, bw, bh);
    _geom[CtlLT].frame = CGRectMake(24 * s, 24 * s, bw, bh);
    _geom[CtlRB].frame = CGRectMake(w - 24 * s - bw, 70 * s, bw, bh);
    _geom[CtlRT].frame = CGRectMake(w - 24 * s - bw, 24 * s, bw, bh);
    // back / start at the bottom middle
    CGFloat pw = 72 * s, ph = 32 * s;
    _geom[CtlBack].frame = CGRectMake(w / 2 - pw - 12 * s, h - 20 * s - ph, pw, ph);
    _geom[CtlStart].frame = CGRectMake(w / 2 + 12 * s, h - 20 * s - ph, pw, ph);
    for (int c = CtlLB; c < CtlCount; c++) {
        _geom[c].center = CGPointMake(CGRectGetMidX(_geom[c].frame), CGRectGetMidY(_geom[c].frame));
        _geom[c].radius = 0;
    }
    [self setNeedsDisplay];
}

- (GFControl)controlAtPoint:(CGPoint)p
{
    // buttons first (they overlap the stick hit areas less, but to be safe check them before the big round areas)
    for (int c = CtlA; c < CtlCount; c++) if (CGRectContainsPoint(_geom[c].frame, p)) return (GFControl)c;
    for (int c = CtlLeftStick; c <= CtlDpad; c++) if (CGRectContainsPoint(_geom[c].frame, p)) return (GFControl)c;
    return CtlNone;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
    return [self controlAtPoint:point] != CtlNone;
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect
{
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat a = self.controlOpacity;
    UIColor *fill = [UIColor colorWithWhite:1 alpha:a * 0.35];
    UIColor *stroke = [UIColor colorWithWhite:1 alpha:a];
    UIColor *pressed = [UIColor colorWithRed:0.47 green:0.8 blue:0.09 alpha:a];
    UIFont *font = [UIFont boldSystemFontOfSize:15 * _scale + 1];
    CGContextSetLineWidth(ctx, 2);

    // sticks
    GFControl sticks[2] = { CtlLeftStick, CtlRightStick };
    CGPoint knobs[2] = { _leftKnob, _rightKnob };
    for (int i = 0; i < 2; i++) {
        GFControlGeometry g = _geom[sticks[i]];
        CGRect ring = CGRectMake(g.center.x - g.radius, g.center.y - g.radius, g.radius * 2, g.radius * 2);
        [fill setFill]; [stroke setStroke];
        CGContextFillEllipseInRect(ctx, ring);
        CGContextStrokeEllipseInRect(ctx, ring);
        CGFloat kr = g.radius * 0.45;
        CGRect knob = CGRectMake(g.center.x + knobs[i].x - kr, g.center.y + knobs[i].y - kr, kr * 2, kr * 2);
        [[UIColor colorWithWhite:1 alpha:a * 0.8] setFill];
        CGContextFillEllipseInRect(ctx, knob);
    }
    // d-pad
    {
        GFControlGeometry g = _geom[CtlDpad];
        CGFloat arm = g.radius * 0.36, len = g.radius;
        [fill setFill]; [stroke setStroke];
        CGRect horizontal = CGRectMake(g.center.x - len, g.center.y - arm, len * 2, arm * 2);
        CGRect vertical = CGRectMake(g.center.x - arm, g.center.y - len, arm * 2, len * 2);
        CGContextFillRect(ctx, horizontal);
        CGContextFillRect(ctx, vertical);
        CGContextStrokeRect(ctx, horizontal);
        CGContextStrokeRect(ctx, vertical);
        uint16_t b = self.state.buttons;
        [pressed setFill];
        if (b & GFPadDpadUp) CGContextFillRect(ctx, CGRectMake(g.center.x - arm, g.center.y - len, arm * 2, len - arm));
        if (b & GFPadDpadDown) CGContextFillRect(ctx, CGRectMake(g.center.x - arm, g.center.y + arm, arm * 2, len - arm));
        if (b & GFPadDpadLeft) CGContextFillRect(ctx, CGRectMake(g.center.x - len, g.center.y - arm, len - arm, arm * 2));
        if (b & GFPadDpadRight) CGContextFillRect(ctx, CGRectMake(g.center.x + arm, g.center.y - arm, len - arm, arm * 2));
    }
    // face buttons
    struct { GFControl c; uint16_t bit; NSString *label; } face[4] = { { CtlA, GFPadA, @"A" }, { CtlB, GFPadB, @"B" }, { CtlX, GFPadX, @"X" }, { CtlY, GFPadY, @"Y" } };
    for (int i = 0; i < 4; i++) {
        GFControlGeometry g = _geom[face[i].c];
        CGRect r = CGRectMake(g.center.x - g.radius, g.center.y - g.radius, g.radius * 2, g.radius * 2);
        [(self.state.buttons & face[i].bit) ? pressed : fill setFill];
        [stroke setStroke];
        CGContextFillEllipseInRect(ctx, r);
        CGContextStrokeEllipseInRect(ctx, r);
        [stroke setFill];
        CGSize ts = [face[i].label sizeWithFont:font];
        [face[i].label drawAtPoint:CGPointMake(g.center.x - ts.width / 2, g.center.y - ts.height / 2) withFont:font];
    }
    // rectangular buttons
    struct { GFControl c; BOOL on; NSString *label; } rects[6] = {
        { CtlLB, (self.state.buttons & GFPadLeftShoulder) != 0, @"LB" }, { CtlRB, (self.state.buttons & GFPadRightShoulder) != 0, @"RB" },
        { CtlLT, self.state.leftTrigger > 0, @"LT" }, { CtlRT, self.state.rightTrigger > 0, @"RT" },
        { CtlBack, (self.state.buttons & GFPadBack) != 0, L(@"Back") }, { CtlStart, (self.state.buttons & GFPadStart) != 0, L(@"Start") } };
    for (int i = 0; i < 6; i++) {
        CGRect r = _geom[rects[i].c].frame;
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:8];
        [rects[i].on ? pressed : fill setFill];
        [stroke setStroke];
        [path fill];
        [path stroke];
        [stroke setFill];
        CGSize ts = [rects[i].label sizeWithFont:font];
        [rects[i].label drawAtPoint:CGPointMake(CGRectGetMidX(r) - ts.width / 2, CGRectGetMidY(r) - ts.height / 2) withFont:font];
    }
}

#pragma mark - Touches

- (NSNumber *)keyForTouch:(UITouch *)touch { return @((uintptr_t)touch); }

- (void)applyStick:(GFControl)control touch:(UITouch *)touch
{
    GFControlGeometry g = _geom[control];
    CGPoint p = [touch locationInView:self];
    CGFloat dx = p.x - g.center.x, dy = p.y - g.center.y;
    CGFloat dist = sqrt(dx * dx + dy * dy);
    CGFloat maxDist = g.radius;
    if (dist > maxDist) { dx *= maxDist / dist; dy *= maxDist / dist; }
    GFGamepadState s = self.state;
    int16_t x = (int16_t)(dx / maxDist * 32767), y = (int16_t)(-dy / maxDist * 32767);
    if (control == CtlLeftStick) { s.leftX = x; s.leftY = y; _leftKnob = CGPointMake(dx, dy); }
    else { s.rightX = x; s.rightY = y; _rightKnob = CGPointMake(dx, dy); }
    self.state = s;
}

- (void)applyDpad:(UITouch *)touch
{
    GFControlGeometry g = _geom[CtlDpad];
    CGPoint p = [touch locationInView:self];
    CGFloat dx = p.x - g.center.x, dy = p.y - g.center.y;
    GFGamepadState s = self.state;
    s.buttons &= ~(GFPadDpadUp | GFPadDpadDown | GFPadDpadLeft | GFPadDpadRight);
    CGFloat dead = g.radius * 0.2;
    if (dy < -dead && fabs(dy) >= fabs(dx) * 0.5) s.buttons |= GFPadDpadUp;
    if (dy > dead && fabs(dy) >= fabs(dx) * 0.5) s.buttons |= GFPadDpadDown;
    if (dx < -dead && fabs(dx) >= fabs(dy) * 0.5) s.buttons |= GFPadDpadLeft;
    if (dx > dead && fabs(dx) >= fabs(dy) * 0.5) s.buttons |= GFPadDpadRight;
    self.state = s;
}

- (void)setControl:(GFControl)control pressed:(BOOL)pressed
{
    GFGamepadState s = self.state;
    uint16_t bit = 0;
    switch (control) {
        case CtlA: bit = GFPadA; break;
        case CtlB: bit = GFPadB; break;
        case CtlX: bit = GFPadX; break;
        case CtlY: bit = GFPadY; break;
        case CtlLB: bit = GFPadLeftShoulder; break;
        case CtlRB: bit = GFPadRightShoulder; break;
        case CtlBack: bit = GFPadBack; break;
        case CtlStart: bit = GFPadStart; break;
        case CtlLT: s.leftTrigger = pressed ? 255 : 0; break;
        case CtlRT: s.rightTrigger = pressed ? 255 : 0; break;
        case CtlLeftStick: if (!pressed) { s.leftX = s.leftY = 0; _leftKnob = CGPointZero; } break;
        case CtlRightStick: if (!pressed) { s.rightX = s.rightY = 0; _rightKnob = CGPointZero; } break;
        case CtlDpad: if (!pressed) s.buttons &= ~(GFPadDpadUp | GFPadDpadDown | GFPadDpadLeft | GFPadDpadRight); break;
        default: break;
    }
    if (bit) { if (pressed) s.buttons |= bit; else s.buttons &= ~bit; }
    self.state = s;
}

- (void)changed
{
    if (self.onChange) self.onChange(self.state);
    [self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    for (UITouch *t in touches) {
        GFControl c = [self controlAtPoint:[t locationInView:self]];
        if (c == CtlNone) continue;
        self.touchControl[[self keyForTouch:t]] = @(c);
        if (c == CtlLeftStick || c == CtlRightStick) [self applyStick:c touch:t];
        else if (c == CtlDpad) [self applyDpad:t];
        else [self setControl:c pressed:YES];
    }
    [self changed];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    BOOL any = NO;
    for (UITouch *t in touches) {
        NSNumber *c = self.touchControl[[self keyForTouch:t]];
        if (!c) continue;
        GFControl control = (GFControl)[c intValue];
        if (control == CtlLeftStick || control == CtlRightStick) { [self applyStick:control touch:t]; any = YES; }
        else if (control == CtlDpad) { [self applyDpad:t]; any = YES; }
        else {
            // sliding off a button releases it; sliding onto a neighbour presses that one (A->B rolls)
            GFControl now = [self controlAtPoint:[t locationInView:self]];
            if (now != control && now >= CtlA) {
                [self setControl:control pressed:NO];
                [self setControl:now pressed:YES];
                self.touchControl[[self keyForTouch:t]] = @(now);
                any = YES;
            }
        }
    }
    if (any) [self changed];
}

- (void)endTouches:(NSSet *)touches
{
    for (UITouch *t in touches) {
        NSNumber *c = self.touchControl[[self keyForTouch:t]];
        if (!c) continue;
        [self setControl:(GFControl)[c intValue] pressed:NO];
        [self.touchControl removeObjectForKey:[self keyForTouch:t]];
    }
    [self changed];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }

@end
