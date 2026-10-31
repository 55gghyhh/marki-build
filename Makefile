TARGET = iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MarkiFake

MarkiFake_FILES = Tweak.x
MarkiFake_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-unused-variable \
                   -Wno-deprecated-declarations -Wno-format -Wno-unused-but-set-variable
MarkiFake_FRAMEWORKS = UIKit Foundation CoreLocation CoreVideo CoreImage CoreGraphics ImageIO Photos AVFoundation QuartzCore MapKit PhotosUI
MarkiFake_LIBRARIES = z
MarkiFake_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
