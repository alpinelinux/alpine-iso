ALPINE_NAME     := alpine-edge
KERNEL_FLAVOR   := grsec
MODLOOP_EXTRA   := xtables-addons-$(KERNEL_FLAVOR)
BOOT_OPTS := nomodeset
#BOOT_OPTS := nomodeset console=ttyS0
