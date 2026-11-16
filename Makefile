TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = StayLowPowerMode
StayLowPowerMode_FILES = StayLowPowerMode/Tweak.xm
StayLowPowerMode_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
