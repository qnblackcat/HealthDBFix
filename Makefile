TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = healthd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HealthDBFix

HealthDBFix_FILES = Tweak.x
HealthDBFix_FRAMEWORKS = Foundation
HealthDBFix_CFLAGS = -fobjc-arc

ifeq ($(HEALTHDBFIX_DEBUG),1)
HealthDBFix_CFLAGS += -DHEALTHDBFIX_DEBUG=1
HealthDBFix_FILES += CloudSyncDebug.x
HealthDBFix_CFLAGS += -DHEALTHDBFIX_VERSION='"$(shell awk '/^Version:/ {print $$2}' control)"'
endif

include $(THEOS_MAKE_PATH)/tweak.mk
