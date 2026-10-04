#import <Foundation/Foundation.h>

// XInput button bits
enum {
    GFPadDpadUp = 0x0001, GFPadDpadDown = 0x0002, GFPadDpadLeft = 0x0004, GFPadDpadRight = 0x0008,
    GFPadStart = 0x0010, GFPadBack = 0x0020, GFPadLeftThumb = 0x0040, GFPadRightThumb = 0x0080,
    GFPadLeftShoulder = 0x0100, GFPadRightShoulder = 0x0200, GFPadGuide = 0x0400,
    GFPadA = 0x1000, GFPadB = 0x2000, GFPadX = 0x4000, GFPadY = 0x8000,
};

typedef struct {
    uint16_t buttons;
    uint8_t leftTrigger, rightTrigger;      // 0..255
    int16_t leftX, leftY, rightX, rightY;   // -32768..32767, +Y up
} GFGamepadState;

typedef struct {
    uint16_t keycode;       // Windows virtual key
    uint16_t scancode;      // PS/2 set 1
    uint16_t modifiers;     // 0x01 shift, 0x02 ctrl, 0x04 alt
} GFKeyStroke;

// The binary protocol of the NVST input data channel ("input_channel_v1"): little-endian packet type, then the
// payload the host expects (parts of which are big-endian), framed per the protocol version the server announced.
@interface GFInputProtocol : NSObject
@property (nonatomic) NSInteger protocolVersion;          // 2 = bare payloads, 3 = framed with timestamps (default 2)

- (NSData *)heartbeat;
- (NSData *)gamepadState:(GFGamepadState)state controller:(uint8_t)controller bitmap:(uint16_t)bitmap timestamp:(uint64_t)micros;
- (NSData *)mouseMoveDX:(int16_t)dx dy:(int16_t)dy timestamp:(uint64_t)micros;
- (NSData *)mouseButton:(uint8_t)button pressed:(BOOL)pressed timestamp:(uint64_t)micros;   // 1 left, 2 middle, 3 right, 4 X1, 5 X2
- (NSData *)mouseWheel:(int16_t)delta timestamp:(uint64_t)micros;
- (NSData *)key:(GFKeyStroke)key pressed:(BOOL)pressed timestamp:(uint64_t)micros;

// The server's first message on the channel announces the protocol version; -1 when the bytes are something else
+ (NSInteger)handshakeVersionFromData:(NSData *)data;
// The key press that types one character on a US layout host (NO when there is no single key for it)
+ (BOOL)keyStroke:(GFKeyStroke *)out forCharacter:(unichar)character;
+ (GFKeyStroke)keyNamed:(NSString *)name;     // "escape", "enter", "tab", "backspace", "space", "shift", "ctrl", "alt", "f1".."f12", "up"..., "win"
@end
