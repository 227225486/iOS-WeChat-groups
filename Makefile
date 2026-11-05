ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = WCGroupBar
WCGroupBar_FILES = Tweak.m WCGroupBarView.m WCWeChatAdapter.m WCGroupBarManager.m
WCGroupBar_FRAMEWORKS = UIKit Foundation
WCGroupBar_CFLAGS = -fobjc-arc -Wall -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
