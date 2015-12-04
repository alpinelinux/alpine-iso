ALPINE_NAME     := alpine-rpi
KERNEL_FLAVOR   := rpi rpi2
MODLOOP_EXTRA   := 
BOOT_OPTS	:= dwc_otg.lpm_enable=0 console=ttyAMA0,115200 console=tty1
INITFS_FEATURES := base bootchart squashfs ext2 ext3 ext4 f2fs kms mmc raid scsi usb
