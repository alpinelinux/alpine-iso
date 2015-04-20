ALPINE_NAME     := alpine-uboot
KERNEL_FLAVOR   := grsec
MODLOOP_EXTRA   := xtables-addons-$(KERNEL_FLAVOR)
BOOT_OPTS	:= 
INITFS_FEATURES := base bootchart squashfs ext2 ext3 ext4 kms mmc raid scsi usb
