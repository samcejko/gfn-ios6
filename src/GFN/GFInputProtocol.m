#import "GFInputProtocol.h"

enum { kHeartbeat = 2, kKeyDown = 3, kKeyUp = 4, kMouseMoveRel = 7, kMouseButtonDown = 8, kMouseButtonUp = 9, kMouseWheel = 10, kGamepad = 12 };
enum { kWrapperLegacy = 0x21, kWrapperSingle = 0x22, kWrapperVersion = 0x23 };

static void le16(NSMutableData *d, uint16_t v) { uint8_t b[2] = { (uint8_t)v, (uint8_t)(v >> 8) }; [d appendBytes:b length:2]; }
static void le32(NSMutableData *d, uint32_t v) { uint8_t b[4] = { (uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24) }; [d appendBytes:b length:4]; }
static void le64(NSMutableData *d, uint64_t v) { for (int i = 0; i < 8; i++) { uint8_t b = (uint8_t)(v >> (8 * i)); [d appendBytes:&b length:1]; } }
static void be16(NSMutableData *d, uint16_t v) { uint8_t b[2] = { (uint8_t)(v >> 8), (uint8_t)v }; [d appendBytes:b length:2]; }
static void be32(NSMutableData *d, uint32_t v) { uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v }; [d appendBytes:b length:4]; }
static void be64(NSMutableData *d, uint64_t v) { for (int i = 7; i >= 0; i--) { uint8_t b = (uint8_t)(v >> (8 * i)); [d appendBytes:&b length:1]; } }

@implementation GFInputProtocol

- (instancetype)init
{
    if ((self = [super init])) _protocolVersion = 2;
    return self;
}

// v3 frames every event as [0x23][u64 BE timestamp][0x21][u16 BE len][payload]; v2 sends the bare payload
- (NSData *)wrapLegacy:(NSData *)payload timestamp:(uint64_t)micros
{
    if (self.protocolVersion < 3) return payload;
    NSMutableData *d = [NSMutableData dataWithCapacity:payload.length + 12];
    uint8_t marker = kWrapperVersion;
    [d appendBytes:&marker length:1];
    be64(d, micros);
    uint8_t legacy = kWrapperLegacy;
    [d appendBytes:&legacy length:1];
    be16(d, (uint16_t)payload.length);
    [d appendData:payload];
    return d;
}

// [0x23][u64 BE timestamp][0x22][payload] - no length field
- (NSData *)wrapSingle:(NSData *)payload timestamp:(uint64_t)micros
{
    if (self.protocolVersion < 3) return payload;
    NSMutableData *d = [NSMutableData dataWithCapacity:payload.length + 10];
    uint8_t marker = kWrapperVersion;
    [d appendBytes:&marker length:1];
    be64(d, micros);
    uint8_t single = kWrapperSingle;
    [d appendBytes:&single length:1];
    [d appendData:payload];
    return d;
}

- (NSData *)heartbeat
{
    NSMutableData *d = [NSMutableData dataWithCapacity:4];
    le32(d, kHeartbeat);
    return d;
}

- (NSData *)gamepadState:(GFGamepadState)s controller:(uint8_t)controller bitmap:(uint16_t)bitmap timestamp:(uint64_t)micros
{
    NSMutableData *d = [NSMutableData dataWithCapacity:38];
    le32(d, kGamepad);
    le16(d, 26);                         // payload size
    le16(d, controller);
    le16(d, bitmap);
    le16(d, 20);                         // inner size
    le16(d, s.buttons);
    le16(d, (uint16_t)(s.leftTrigger | ((uint16_t)s.rightTrigger << 8)));
    le16(d, (uint16_t)s.leftX);
    le16(d, (uint16_t)s.leftY);
    le16(d, (uint16_t)s.rightX);
    le16(d, (uint16_t)s.rightY);
    le16(d, 0);
    le16(d, 85);                         // reserved marker
    le16(d, 0);
    le64(d, micros);
    return [self wrapLegacy:d timestamp:micros];
}

- (NSData *)mouseMoveDX:(int16_t)dx dy:(int16_t)dy timestamp:(uint64_t)micros
{
    if (dx > 4096) dx = 4096; if (dx < -4096) dx = -4096;
    if (dy > 4096) dy = 4096; if (dy < -4096) dy = -4096;
    NSMutableData *d = [NSMutableData dataWithCapacity:22];
    le32(d, kMouseMoveRel);
    be16(d, (uint16_t)dx);
    be16(d, (uint16_t)dy);
    be16(d, 0);
    be32(d, 0);
    be64(d, micros);
    return [self wrapLegacy:d timestamp:micros];
}

- (NSData *)mouseButton:(uint8_t)button pressed:(BOOL)pressed timestamp:(uint64_t)micros
{
    NSMutableData *d = [NSMutableData dataWithCapacity:18];
    le32(d, pressed ? kMouseButtonDown : kMouseButtonUp);
    [d appendBytes:&button length:1];
    uint8_t zero = 0;
    [d appendBytes:&zero length:1];
    be32(d, 0);
    be64(d, micros);
    return [self wrapSingle:d timestamp:micros];
}

- (NSData *)mouseWheel:(int16_t)delta timestamp:(uint64_t)micros
{
    NSMutableData *d = [NSMutableData dataWithCapacity:18];
    le32(d, kMouseWheel);
    be16(d, (uint16_t)delta);
    be32(d, 0);
    be64(d, micros);
    return [self wrapSingle:d timestamp:micros];
}

- (NSData *)key:(GFKeyStroke)key pressed:(BOOL)pressed timestamp:(uint64_t)micros
{
    NSMutableData *d = [NSMutableData dataWithCapacity:18];
    le32(d, pressed ? kKeyDown : kKeyUp);
    be16(d, key.keycode);
    be16(d, key.modifiers);
    be16(d, key.scancode);
    be64(d, micros);
    return [self wrapSingle:d timestamp:micros];
}

+ (NSInteger)handshakeVersionFromData:(NSData *)data
{
    const uint8_t *b = data.bytes;
    if (data.length < 2) return -1;
    uint16_t first = (uint16_t)(b[0] | (b[1] << 8));
    if (first == 526) return data.length >= 4 ? (b[2] | (b[3] << 8)) : 2;
    if (b[0] == 0x0e) return first;
    return -1;
}

static const uint16_t kDigitScancodes[10] = { 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };   // 1..9, 0
static const uint16_t kLetterScancodes[26] = { 0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
                                               0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C };

+ (BOOL)keyStroke:(GFKeyStroke *)out forCharacter:(unichar)c
{
    GFKeyStroke k = { 0, 0, 0 };
    if (c == ' ') { k.keycode = 0x20; k.scancode = 0x39; *out = k; return YES; }
    if (c == '\n' || c == '\r') { *out = [self keyNamed:@"enter"]; return YES; }
    if (c == '\t') { *out = [self keyNamed:@"tab"]; return YES; }
    if (c >= '0' && c <= '9') {
        int digit = c - '0';
        k.keycode = (uint16_t)c;
        k.scancode = kDigitScancodes[digit == 0 ? 9 : digit - 1];
        *out = k;
        return YES;
    }
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
        unichar lower = (unichar)((c >= 'A' && c <= 'Z') ? c + 32 : c);
        k.keycode = (uint16_t)(lower - 32);
        k.scancode = kLetterScancodes[lower - 'a'];
        if (c >= 'A' && c <= 'Z') k.modifiers = 0x01;
        *out = k;
        return YES;
    }
    static const struct { unichar shifted, base; } shifted[] = {
        {'!','1'},{'@','2'},{'#','3'},{'$','4'},{'%','5'},{'^','6'},{'&','7'},{'*','8'},{'(','9'},{')','0'},{'_','-'},{'+','='},
        {'{','['},{'}',']'},{'|','\\'},{':',';'},{'"','\''},{'<',','},{'>','.'},{'?','/'},{'~','`'} };
    for (size_t i = 0; i < sizeof(shifted) / sizeof(shifted[0]); i++) {
        if (shifted[i].shifted == c) {
            if (![self keyStroke:&k forCharacter:shifted[i].base]) return NO;
            k.modifiers |= 0x01;
            *out = k;
            return YES;
        }
    }
    static const struct { unichar ch; uint16_t vk, sc; } punct[] = {
        {'-',0xBD,0x0C},{'=',0xBB,0x0D},{'[',0xDB,0x1A},{']',0xDD,0x1B},{'\\',0xDC,0x2B},{';',0xBA,0x27},{'\'',0xDE,0x28},
        {',',0xBC,0x33},{'.',0xBE,0x34},{'/',0xBF,0x35},{'`',0xC0,0x29} };
    for (size_t i = 0; i < sizeof(punct) / sizeof(punct[0]); i++) {
        if (punct[i].ch == c) { k.keycode = punct[i].vk; k.scancode = punct[i].sc; *out = k; return YES; }
    }
    return NO;
}

+ (GFKeyStroke)keyNamed:(NSString *)name
{
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{ @"escape": @[@0x1B, @0x01], @"enter": @[@0x0D, @0x1C], @"tab": @[@0x09, @0x0F], @"backspace": @[@0x08, @0x0E],
                   @"space": @[@0x20, @0x39], @"shift": @[@0xA0, @0x2A], @"ctrl": @[@0xA2, @0x1D], @"alt": @[@0xA4, @0x38],
                   @"f1": @[@0x70, @0x3B], @"f2": @[@0x71, @0x3C], @"f3": @[@0x72, @0x3D], @"f4": @[@0x73, @0x3E], @"f5": @[@0x74, @0x3F],
                   @"f6": @[@0x75, @0x40], @"f7": @[@0x76, @0x41], @"f8": @[@0x77, @0x42], @"f9": @[@0x78, @0x43], @"f10": @[@0x79, @0x44],
                   @"f11": @[@0x7A, @0x57], @"f12": @[@0x7B, @0x58], @"left": @[@0x25, @0x4B], @"right": @[@0x27, @0x4D],
                   @"up": @[@0x26, @0x48], @"down": @[@0x28, @0x50], @"home": @[@0x24, @0x47], @"end": @[@0x23, @0x4F],
                   @"pageup": @[@0x21, @0x49], @"pagedown": @[@0x22, @0x51], @"delete": @[@0x2E, @0x53], @"insert": @[@0x2D, @0x52],
                   @"capslock": @[@0x14, @0x3A], @"win": @[@0x5B, @0x5B], @"menu": @[@0x5D, @0x5D] };
    });
    NSArray *v = table[[name lowercaseString]];
    GFKeyStroke k = { 0, 0, 0 };
    if (v) { k.keycode = [v[0] unsignedShortValue]; k.scancode = [v[1] unsignedShortValue]; }
    return k;
}

@end
