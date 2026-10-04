#import "GFVideoView.h"
#import "GFCommon.h"
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <OpenGLES/EAGL.h>
#import <CoreVideo/CVOpenGLESTextureCache.h>

static const char *kVertexShader =
    "attribute vec2 position;\n"
    "attribute vec2 texcoord;\n"
    "uniform vec2 scale;\n"
    "varying vec2 v_tex;\n"
    "void main() { gl_Position = vec4(position * scale, 0.0, 1.0); v_tex = texcoord; }\n";

static const char *kFragmentShader =
    "precision mediump float;\n"
    "varying vec2 v_tex;\n"
    "uniform sampler2D tex;\n"
    "void main() { gl_FragColor = texture2D(tex, v_tex); }\n";

@interface GFVideoView ()
@property (nonatomic) uint64_t framesDrawn;
@property (nonatomic) CGSize frameSize;
@end

@implementation GFVideoView {
    EAGLContext *_context;
    GLuint _framebuffer, _renderbuffer;
    GLint _backingWidth, _backingHeight;
    GLuint _program;
    GLint _positionAttr, _texcoordAttr, _scaleUniform, _texUniform;
    CVOpenGLESTextureCacheRef _textureCache;
    CADisplayLink *_displayLink;
    CVPixelBufferRef _lastBuffer;
    BOOL _ready;
}

+ (Class)layerClass
{
    return [CAEAGLLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
        layer.opaque = YES;
        layer.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking: @NO, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8 };
        self.contentScaleFactor = [UIScreen mainScreen].scale;
        self.backgroundColor = [UIColor blackColor];
        _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        if (!_context || ![EAGLContext setCurrentContext:_context]) {
            GFLog(@"GL: no OpenGL ES 2 context");
            return self;
        }
        if (![self buildProgram]) return self;
        CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_textureCache);
        if (err != kCVReturnSuccess) { GFLog(@"GL: texture cache failed (%d)", (int)err); return self; }
        _ready = YES;
    }
    return self;
}

- (void)dealloc
{
    [self stopDisplayLink];
    if ([EAGLContext currentContext] == _context) [EAGLContext setCurrentContext:nil];
    if (_lastBuffer) CVBufferRelease(_lastBuffer);
    if (_textureCache) CFRelease(_textureCache);
}

- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type source:(const char *)source
{
    *shader = glCreateShader(type);
    glShaderSource(*shader, 1, &source, NULL);
    glCompileShader(*shader);
    GLint status = 0;
    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (!status) {
        char log[512];
        glGetShaderInfoLog(*shader, sizeof(log), NULL, log);
        GFLog(@"GL: shader failed: %s", log);
        return NO;
    }
    return YES;
}

- (BOOL)buildProgram
{
    GLuint vs, fs;
    if (![self compileShader:&vs type:GL_VERTEX_SHADER source:kVertexShader]) return NO;
    if (![self compileShader:&fs type:GL_FRAGMENT_SHADER source:kFragmentShader]) return NO;
    _program = glCreateProgram();
    glAttachShader(_program, vs);
    glAttachShader(_program, fs);
    glLinkProgram(_program);
    GLint status = 0;
    glGetProgramiv(_program, GL_LINK_STATUS, &status);
    glDeleteShader(vs);
    glDeleteShader(fs);
    if (!status) { GFLog(@"GL: program link failed"); return NO; }
    _positionAttr = glGetAttribLocation(_program, "position");
    _texcoordAttr = glGetAttribLocation(_program, "texcoord");
    _scaleUniform = glGetUniformLocation(_program, "scale");
    _texUniform = glGetUniformLocation(_program, "tex");
    return YES;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    if (!_ready) return;
    [EAGLContext setCurrentContext:_context];
    if (_framebuffer) { glDeleteFramebuffers(1, &_framebuffer); _framebuffer = 0; }
    if (_renderbuffer) { glDeleteRenderbuffers(1, &_renderbuffer); _renderbuffer = 0; }
    glGenFramebuffers(1, &_framebuffer);
    glGenRenderbuffers(1, &_renderbuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _renderbuffer);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) GFLog(@"GL: framebuffer incomplete");
    [self clear];
    if (_lastBuffer) [self drawBuffer:_lastBuffer];
}

- (void)startDisplayLink
{
    if (_displayLink) return;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _displayLink.frameInterval = 1;
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDisplayLink
{
    [_displayLink invalidate];
    _displayLink = nil;
}

- (void)tick:(CADisplayLink *)link
{
    CVPixelBufferRef (^source)(void) = self.frameSource;
    if (!source || !_ready || !_framebuffer) return;
    CVPixelBufferRef buffer = source();
    if (!buffer) return;
    if (_lastBuffer) CVBufferRelease(_lastBuffer);
    _lastBuffer = buffer;
    [self drawBuffer:buffer];
}

- (void)clear
{
    if (!_ready || !_framebuffer) return;
    [EAGLContext setCurrentContext:_context];
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glViewport(0, 0, _backingWidth, _backingHeight);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER];
}

- (void)drawBuffer:(CVPixelBufferRef)buffer
{
    size_t w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer);
    if (!w || !h) return;
    self.frameSize = CGSizeMake(w, h);
    [EAGLContext setCurrentContext:_context];
    CVOpenGLESTextureRef texture = NULL;
    CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _textureCache, buffer, NULL, GL_TEXTURE_2D, GL_RGBA,
                                                                (GLsizei)w, (GLsizei)h, GL_BGRA, GL_UNSIGNED_BYTE, 0, &texture);
    if (err != kCVReturnSuccess || !texture) {
        static int logged;
        if (logged++ < 5) GFLog(@"GL: texture from image failed (%d)", (int)err);
        return;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, _framebuffer);
    glViewport(0, 0, _backingWidth, _backingHeight);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(_program);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(CVOpenGLESTextureGetTarget(texture), CVOpenGLESTextureGetName(texture));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glUniform1i(_texUniform, 0);

    // aspect: scale the unit quad so the picture keeps its proportions inside (or over) the view
    float viewAspect = (float)_backingWidth / (float)_backingHeight;
    float frameAspect = (float)w / (float)h;
    float sx = 1, sy = 1;
    if (self.aspectFill ? frameAspect < viewAspect : frameAspect > viewAspect) sy = viewAspect / frameAspect;
    else sx = frameAspect / viewAspect;
    glUniform2f(_scaleUniform, sx, sy);

    static const GLfloat quad[] = { -1, -1, 0, 1,   1, -1, 1, 1,   -1, 1, 0, 0,   1, 1, 1, 0 };
    glVertexAttribPointer((GLuint)_positionAttr, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), quad);
    glEnableVertexAttribArray((GLuint)_positionAttr);
    glVertexAttribPointer((GLuint)_texcoordAttr, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(GLfloat), quad + 2);
    glEnableVertexAttribArray((GLuint)_texcoordAttr);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glBindRenderbuffer(GL_RENDERBUFFER, _renderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER];
    glBindTexture(GL_TEXTURE_2D, 0);
    CFRelease(texture);
    CVOpenGLESTextureCacheFlush(_textureCache, 0);
    self.framesDrawn++;
}

@end
