# GFN6 - unofficial GeForce NOW client for jailbroken iOS 6.x (armv7) with its own TLS/DTLS/WebRTC stack.
# Built with Theos. Deployment target iOS 6.0, compiled against the iOS 9.3 SDK.

TARGET := iphone:clang:9.3:6.0
ARCHS := armv7
DEBUG ?= 0

# Device used by `make install` (Theos) - overridden by tools/ipad.ps1 anyway
THEOS_DEVICE_IP ?= 192.168.137.17
THEOS_DEVICE_USER ?= root

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := GFN6

# libopus (fixed point, plain C - no ARM assembly), fetched by CI into vendor/opus
OPUS_SRC := $(filter-out vendor/opus/src/opus_demo.c vendor/opus/src/repacketizer_demo.c vendor/opus/src/opus_compare.c vendor/opus/src/mlp_train.c, $(wildcard vendor/opus/src/*.c)) \
            $(filter-out vendor/opus/celt/opus_custom_demo.c, $(wildcard vendor/opus/celt/*.c)) \
            $(wildcard vendor/opus/silk/*.c) \
            $(wildcard vendor/opus/silk/fixed/*.c)

GFN6_FILES := $(wildcard src/*.m) $(wildcard src/*/*.m) $(wildcard src/*/*.c) \
               vendor/mbedtls_glue.c \
               $(wildcard vendor/mbedtls/library/*.c) \
               $(OPUS_SRC) \
               $(wildcard vendor/qrcodegen/*.c)

GFN6_FRAMEWORKS := UIKit Foundation CoreGraphics QuartzCore CoreText Security ImageIO CoreMedia CoreVideo OpenGLES AudioToolbox AVFoundation

# Flags for every C-family file (also the vendored mbedTLS and opus sources)
GFN6_CFLAGS := -Isrc -Isrc/Net -Isrc/GFN -Isrc/RTC -Isrc/Media -Isrc/UI -Isrc/Util \
                -Ivendor -Ivendor/mbedtls/include -Ivendor/mbedtls/library \
                -Ivendor/opus/include -Ivendor/opus/celt -Ivendor/opus/silk -Ivendor/opus/silk/fixed -Ivendor/opus -Ivendor/qrcodegen \
                -DOPUS_BUILD -DFIXED_POINT=1 -DDISABLE_FLOAT_API -DUSE_ALLOCA -DHAVE_LRINT -DHAVE_LRINTF \
                -Os -fvisibility=hidden \
                -Wall -Wno-unused-variable -Wno-unused-function -Wno-unused-but-set-variable \
                -Wno-deprecated-declarations -Wno-unknown-warning-option -Wno-unused-parameter -Wno-sign-compare \
                -Wno-nullability-completeness -Wno-nullability-completeness-on-arrays -Wno-error

# Objective-C only: ARC; APIs newer than iOS 6.0 are warnings here and turned into errors for our own
# sources by the pragma in src/GFCommon.h (vendored code only warns).
GFN6_OBJCFLAGS := -fobjc-arc -Wunguarded-availability

GFN6_LDFLAGS := -lz

include $(THEOS)/makefiles/application.mk

# The iOS 9.3 SDK places the NSURL* loading classes in CFNetwork; on iOS 6 they live in Foundation and dyld aborts at
# launch when the binary asks CFNetwork for them. The app avoids those classes, but should the linker still record
# CFNetwork, the load command is pointed at Foundation (harmless when there is none), then the binary is signed again.
GFN6_STAGED_BIN := $(THEOS_STAGING_DIR)/Applications/GFN6.app/GFN6
after-stage::
	install_name_tool -change /System/Library/Frameworks/CFNetwork.framework/CFNetwork /System/Library/Frameworks/Foundation.framework/Foundation "$(GFN6_STAGED_BIN)" || true
	ldid -S"$(THEOS_PROJECT_DIR)/entitlements.xml" "$(GFN6_STAGED_BIN)"
