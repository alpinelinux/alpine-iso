#!/usr/bin/make -f

PROFILE		?= alpine

-include $(PROFILE).conf.mk

BUILD_DATE	:= $(shell date +%y%m%d)
ALPINE_RELEASE	?= $(BUILD_DATE)
ALPINE_NAME	?= alpine-test
ALPINE_ARCH	?= $(shell abuild -A)

DESTDIR		?= $(shell pwd)/isotmp.$(PROFILE)

MKSQUASHFS	= mksquashfs
SUDO		= sudo
TAR		= busybox tar
APK_SEARCH	= apk search --exact

ISO		?= $(ALPINE_NAME)-$(ALPINE_RELEASE)-$(ALPINE_ARCH).iso
ISO_LINK	?= $(ALPINE_NAME).iso
ISO_DIR		:= $(DESTDIR)/isofs
ISO_PKGDIR	:= $(ISO_DIR)/apks/$(ALPINE_ARCH)

APKS		?= $(shell sed 's/\#.*//; s/\*/\\*/g' $(PROFILE).packages)

APK_KEYS	?= /etc/apk/keys
APK_OPTS	:= $(addprefix --repository ,$(APK_REPOS)) --keys-dir $(APK_KEYS) --repositories-file /etc/apk/repositories

APK_FETCH_STDOUT := apk fetch $(APK_OPTS) --stdout --quiet

KERNEL_FLAVOR_DEFAULT	?= grsec
KERNEL_FLAVOR	?= $(KERNEL_FLAVOR_DEFAULT)
KERNEL_PKGNAME	= linux-$*

all: isofs

help:
	@echo "Alpine ISO builder"
	@echo
	@echo "Type 'make iso' to build $(ISO)"
	@echo
	@echo "ALPINE_NAME:    $(ALPINE_NAME)"
	@echo "ALPINE_RELEASE: $(ALPINE_RELEASE)"
	@echo "KERNEL_FLAVOR:  $(KERNEL_FLAVOR)"
	@echo "KERNEL_PKGNAME: $(KERNEL_PKGNAME)"
	@echo "APKOVL:         $(APKOVL)"
	@echo

clean: clean-modloop clean-initfs
	rm -rf $(ISO_DIR) $(ISO_REPOS_DIRSTAMP) $(ISOFS_DIRSTAMP) \
		$(ALL_ISO_KERNEL)


$(APK_FILES):
	@mkdir -p "$(dir $@)";\
	p="$(notdir $(basename $@))";\
	apk fetch $(APK_OPTS) -R -v -o "$(dir $@)" $${p%-[0-9]*}

#
# Modloop
#
MODLOOP		:= $(ISO_DIR)/boot/modloop-%
MODLOOP_DIR	= $(DESTDIR)/modloop.$*
MODLOOP_KERNELSTAMP := $(DESTDIR)/stamp.modloop.kernel.%
MODLOOP_DIRSTAMP := $(DESTDIR)/stamp.modloop.%
MODLOOP_EXTRA	?= $(addsuffix -$*, dahdi-linux xtables-addons)
MODLOOP_FIRMWARE ?= linux-firmware dahdi-linux
MODLOOP_PKGS	= $(KERNEL_PKGNAME) $(MODLOOP_EXTRA) $(MODLOOP_FIRMWARE)

modloop-%: $(MODLOOP)
	@:

ALL_MODLOOP = $(foreach flavor,$(KERNEL_FLAVOR),$(subst %,$(flavor),$(MODLOOP)))
ALL_MODLOOP_DIRSTAMP = $(foreach flavor,$(KERNEL_FLAVOR),$(subst %,$(flavor),$(MODLOOP_DIRSTAMP)))

modloop: $(ALL_MODLOOP)

$(MODLOOP_KERNELSTAMP):
	@echo "==> modloop: Unpacking kernel modules";
	@rm -rf $(MODLOOP_DIR) && mkdir -p $(MODLOOP_DIR)
	@apk add $(APK_OPTS) \
		--initdb \
		--update \
		--no-script \
		--root $(MODLOOP_DIR) \
		$(MODLOOP_PKGS)
	@if [ -d "$(MODLOOP_DIR)"/lib/firmware ]; then \
		mv "$(MODLOOP_DIR)"/lib/firmware "$(MODLOOP_DIR)"/lib/modules/;\
	fi
	@cp $(MODLOOP_DIR)/usr/share/kernel/$*/kernel.release $@

MODLOOP_KERNEL_RELEASE = $(shell cat $(subst %,$*,$(MODLOOP_KERNELSTAMP)))

$(MODLOOP_DIRSTAMP): $(MODLOOP_KERNELSTAMP)
	@rm -rf $(addprefix $(MODLOOP_DIR)/lib/modules/*/, source build)
	@depmod $(MODLOOP_KERNEL_RELEASE) -b $(MODLOOP_DIR)
	@touch $@

$(MODLOOP): $(MODLOOP_DIRSTAMP)
	@echo "==> modloop: building image $(notdir $@)"
	@mkdir -p $(dir $@)
	@$(MKSQUASHFS) $(MODLOOP_DIR)/lib $@ -comp xz

clean-modloop-%:
	@rm -rf $(MODLOOP_DIR) $(subst %,$*,$(MODLOOP_DIRSTAMP) $(MODLOOP_KERNELSTAMP) $(MODLOOP))

clean-modloop: $(addprefix clean-modloop-,$(KERNEL_FLAVOR))

#
# Initramfs rules
#

# isolinux cannot handle - in filenames
INITFS_NAME	:= initramfs-%
INITFS		:= $(ISO_DIR)/boot/$(INITFS_NAME)

INITFS_DIR	= $(DESTDIR)/initfs.$*
INITFS_TMP	= $(DESTDIR)/tmp.initfs.$*
INITFS_DIRSTAMP := $(DESTDIR)/stamp.initfs.%
INITFS_FEATURES	?= ata base bootchart cdrom squashfs ext2 ext3 ext4 floppy mmc raid scsi usb virtio
INITFS_PKGS	= $(MODLOOP_PKGS) alpine-base acct

initfs-%: $(INITFS)
	@:

ALL_INITFS = $(foreach flavor,$(KERNEL_FLAVOR),$(subst %,$(flavor),$(INITFS)))

initfs: $(ALL_INITFS)

$(INITFS_DIRSTAMP):
	@rm -rf $(INITFS_DIR) $(INITFS_TMP)
	@mkdir -p $(INITFS_DIR) $(INITFS_TMP)
	@apk add $(APK_OPTS) \
		--initdb \
		--update \
		--no-script \
		--root $(INITFS_DIR) \
		$(INITFS_PKGS)
	@cp -r $(APK_KEYS) $(INITFS_DIR)/etc/apk/ || true
	@if ! [ -e "$(INITFS_DIR)"/etc/mdev.conf ]; then \
		cat $(INITFS_DIR)/etc/mdev.conf.d/*.conf \
			> $(INITFS_DIR)/etc/mdev.conf; \
	fi
	@touch $@

$(INITFS): $(INITFS_DIRSTAMP) $(MODLOOP_DIRSTAMP)
	@mkinitfs -F "$(INITFS_FEATURES)" -t $(INITFS_TMP) \
		-b $(INITFS_DIR) -o $@ $(MODLOOP_KERNEL_RELEASE)

clean-initfs-%:
	@rm -rf $(subst %,$*,$(INITFS) $(INITFS_DIRSTAMP)) $(INITFS_DIR)

clean-initfs: $(addprefix clean-initfs-,$(KERNEL_FLAVOR))

#
# apkovl rules
#

ifdef BUILD_APKOVL
APKOVL_DEST	:= $(ISO_DIR)/$(BUILD_APKOVL).apkovl.tar.gz
APKOVL_DIR	:= $(DESTDIR)/apkovl_$(BUILD_APKOVL)
endif

# Helper function to link a script to runlevel

rc_add = \
	@mkdir -p "$(APKOVL_DIR)"/etc/runlevels/"$(2)"; \
	ln -sf /etc/init.d/"$(1)" "$(APKOVL_DIR)"/etc/runlevels/"$(2)"/"$(1)";

$(ISO_DIR)/xen.apkovl.tar.gz:
	@rm -rf "$(APKOVL_DIR)"
	@mkdir -p "$(APKOVL_DIR)"
	@mkdir -p "$(APKOVL_DIR)"/etc/apk
	@echo "xen" >> "$(APKOVL_DIR)"/etc/apk/world
	@echo "xen_netback" >> "$(APKOVL_DIR)"/etc/modules
	@echo "xen_blkback" >> "$(APKOVL_DIR)"/etc/modules
	@echo "xenfs" >> "$(APKOVL_DIR)"/etc/modules
	@echo "xen-platform-pci" >> "$(APKOVL_DIR)"/etc/modules
	@echo "xen_wdt" >> "$(APKOVL_DIR)"/etc/modules
	@echo "tun" >> "$(APKOVL_DIR)"/etc/modules
	$(call rc_add,devfs,sysinit)
	$(call rc_add,dmesg,sysinit)
	$(call rc_add,hwclock,boot)
	$(call rc_add,modules,boot)
	$(call rc_add,sysctl,boot)
	$(call rc_add,hostname,boot)
	$(call rc_add,bootmisc,boot)
	$(call rc_add,syslog,boot)
	$(call rc_add,mount-ro,shutdown)
	$(call rc_add,killprocs,shutdown)
	$(call rc_add,savecache,shutdown)
	$(call rc_add,udev,sysinit)
	$(call rc_add,udev-postmount,default)
	$(call rc_add,xenstored,default)
	$(call rc_add,xenconsoled,default)
	@cd $(APKOVL_DIR) && $(TAR) -zcf $@ *
	@echo "==> apkovl: built $@"
#
# ISO rules
#

ISOLINUX_DIR	:= boot/syslinux
ISOLINUX	:= $(ISO_DIR)/$(ISOLINUX_DIR)
ISOLINUX_BIN	:= $(ISOLINUX)/isolinux.bin
ISOLINUX_C32	:= $(ISOLINUX)/ldlinux.c32 $(ISOLINUX)/libutil.c32 \
			$(ISOLINUX)/libcom32.c32 $(ISOLINUX)/mboot.c32
ISOLINUX_CFG	:= $(ISOLINUX)/isolinux.cfg
SYSLINUX_CFG	:= $(ISOLINUX)/syslinux.cfg
SYSLINUX_SERIAL	?=



$(ISOLINUX_C32):
	@echo "==> iso: install $(notdir $@)"
	@mkdir -p $(dir $@)
	@if ! $(APK_FETCH_STDOUT) syslinux \
		| $(TAR) -O -zx usr/share/syslinux/$(notdir $@) > $@; then \
		rm -f $@ && exit 1;\
	fi

$(ISOLINUX_BIN):
	@echo "==> iso: install isolinux"
	@mkdir -p $(dir $(ISOLINUX_BIN))
	@if ! $(APK_FETCH_STDOUT) syslinux \
		| $(TAR) -O -zx usr/share/syslinux/isolinux.bin > $@; then \
		rm -f $@ && exit 1;\
	fi

$(ISOLINUX_CFG):
	@echo "==> iso: configure isolinux"
	@mkdir -p $(dir $(ISOLINUX_BIN))
	@echo "$(SYSLINUX_SERIAL)" >$@
	@echo "timeout 20" >>$@
	@echo "prompt 1" >>$@
ifeq ($(PROFILE), alpine-xen)
	@echo "default xen-$(KERNEL_FLAVOR_DEFAULT)" >>$@
	@for flavor in $(KERNEL_FLAVOR); do \
		echo "label xen-$$flavor"; \
		echo "	kernel /$(ISOLINUX_DIR)/mboot.c32"; \
		echo "	append /boot/xen.gz $(XEN_PARAMS) --- /boot/vmlinuz-$$flavor alpine_dev=cdrom:iso9660 modules=loop,squashfs,sd-mod,usb-storage,sr-mod $(BOOT_OPTS) --- /boot/initramfs-$$flavor"; \
	done >>$@
else
	@echo "default $(KERNEL_FLAVOR_DEFAULT)" >>$@
	@for flavor in $(KERNEL_FLAVOR); do \
		echo "label $$flavor"; \
		echo "	kernel /boot/vmlinuz-$$flavor"; \
		echo "	append initrd=/boot/initramfs-$$flavor alpine_dev=cdrom:iso9660 modules=loop,squashfs,sd-mod,usb-storage,sr-mod quiet $(BOOT_OPTS)"; \
	done >>$@
endif

$(SYSLINUX_CFG): $(ALL_MODLOOP_DIRSTAMP)
	@echo "==> iso: configure syslinux"
	@echo "$(SYSLINUX_SERIAL)" >$@
	@echo "timeout 20" >>$@
	@echo "prompt 1" >>$@
ifeq ($(PROFILE), alpine-xen)
	@echo "default xen-$(KERNEL_FLAVOR_DEFAULT)" >>$@
	@for flavor in $(KERNEL_FLAVOR); do \
		echo "label xen-$$flavor"; \
		echo "	kernel /$(ISOLINUX_DIR)/mboot.c32"; \
		echo "	append /boot/xen.gz $(XEN_PARAMS) --- /boot/vmlinuz-$$flavor alpine_dev=usbdisk:vfat modules=loop,squashfs,sd-mod,usb-storage $(BOOT_OPTS) --- /boot/initramfs-$$flavor"; \
	done >>$@
else
	@echo "default $(KERNEL_FLAVOR_DEFAULT)" >>$@
	@for flavor in $(KERNEL_FLAVOR); do \
		echo "label $$flavor"; \
		echo "	kernel /boot/vmlinuz-$$flavor"; \
		echo "	append initrd=/boot/initramfs-$$flavor alpine_dev=usbdisk:vfat modules=loop,squashfs,sd-mod,usb-storage quiet $(BOOT_OPTS)"; \
	done >>$@
endif

clean-syslinux:
	@rm -f $(SYSLINUX_CFG) $(ISOLINUX_CFG) $(ISOLINUX_BIN)

ISO_KERNEL_STAMP	:= $(DESTDIR)/stamp.kernel.%
ISO_KERNEL	= $(ISO_DIR)/boot/$*
ISO_REPOS_DIRSTAMP := $(DESTDIR)/stamp.isorepos
ISOFS_DIRSTAMP	:= $(DESTDIR)/stamp.isofs

$(ISO_REPOS_DIRSTAMP): $(ISO_PKGDIR)/APKINDEX.tar.gz
	@touch $(ISO_PKGDIR)/../.boot_repository
	@rm -f $(ISO_PKGDIR)/.SIGN.*
	@touch $@

$(ISO_PKGDIR)/APKINDEX.tar.gz: $(PROFILE).packages
	@echo "==> iso: generating repository"
	mkdir -p "$(ISO_PKGDIR)"
	sed -e 's/\#.*//' $< \
		| xargs apk fetch $(APK_OPTS) \
			--output $(ISO_PKGDIR) \
			--recursive
	@apk index --description "$(ALPINE_NAME) $(ALPINE_RELEASE)" \
		--rewrite-arch $(ALPINE_ARCH) -o $@ $(ISO_PKGDIR)/*.apk
	@abuild-sign $@

repo: $(ISO_PKGDIR)/APKINDEX.tar.gz

$(ISO_KERNEL_STAMP): $(MODLOOP_DIRSTAMP)
	@echo "==> iso: install kernel $(KERNEL_PKGNAME)"
	@mkdir -p $(dir $(ISO_KERNEL))
	@echo "Fetching $(KERNEL_PKGNAME)"
	@$(APK_FETCH_STDOUT) $(KERNEL_PKGNAME) \
		| $(TAR) -C $(ISO_DIR) -xz boot
ifeq ($(PROFILE), alpine-xen)
	@echo "Fetching xen-hypervisor"
	@$(APK_FETCH_STDOUT) xen-hypervisor \
		| $(TAR) -C $(ISO_DIR) -xz boot
endif
	@rm -f $(ISO_KERNEL)
	@if [ "$(KERNEL_FLAVOR)" = "vanilla" ]; then \
		ln -s vmlinuz $(ISO_KERNEL);\
	else \
		ln -s vmlinuz-$(KERNEL_FLAVOR) $(ISO_KERNEL);\
	fi
	@rm -rf $(ISO_DIR)/.[A-Z]* $(ISO_DIR)/.[a-z]* $(ISO_DIR)/lib
	@touch $@

ALL_ISO_KERNEL = $(foreach flavor,$(KERNEL_FLAVOR),$(subst %,$(flavor),$(ISO_KERNEL_STAMP)))

APKOVL_STAMP = $(DESTDIR)/stamp.isofs.apkovl

$(APKOVL_STAMP):
	@if [ "x$(APKOVL)" != "x" ]; then \
		(cd $(ISO_DIR); wget $(APKOVL)); \
	fi
	@touch $@

$(ISOFS_DIRSTAMP): $(ALL_MODLOOP) $(ALL_INITFS) $(ISO_REPOS_DIRSTAMP) $(ISOLINUX_CFG) $(ISOLINUX_BIN) $(ISOLINUX_C32) $(ALL_ISO_KERNEL) $(APKOVL_STAMP) $(SYSLINUX_CFG) $(APKOVL_DEST)
	@echo "$(ALPINE_NAME)-$(ALPINE_RELEASE) $(BUILD_DATE)" \
		> $(ISO_DIR)/.alpine-release
	@touch $@

$(ISO): $(ISOFS_DIRSTAMP)
	@echo "==> iso: building $(notdir $(ISO))"
	@genisoimage -o $(ISO) -l -J -R \
		-b $(ISOLINUX_DIR)/isolinux.bin \
		-c $(ISOLINUX_DIR)/boot.cat	\
		-no-emul-boot		\
		-boot-load-size 4	\
		-boot-info-table	\
		-quiet			\
		-follow-links		\
		$(ISO_OPTS)		\
		$(ISO_DIR)
	@ln -fs $@ $(ISO_LINK)

isofs: $(ISOFS_DIRSTAMP)
iso: $(ISO)

#
# SHA1 sum of ISO
#
ISO_SHA1	:= $(ISO).sha1
ISO_SHA256	:= $(ISO).sha256

$(ISO_SHA1):	$(ISO)
	@echo "==> Generating sha1 sum"
	@sha1sum $(ISO) > $@ || rm -f $@

$(ISO_SHA256):	$(ISO)
	@echo "==> Generating sha256 sum"
	@sha256sum $(ISO) > $@ || rm -f $@

#
# .pkgdiff
#
previous	:= $(shell cat previous 2>/dev/null)
release_diff	:= $(previous)-$(ALPINE_RELEASE)
PREV_ISO	:= $(ALPINE_NAME)-$(previous)-$(ALPINE_ARCH).iso

ifneq ($(wildcard $(PREV_ISO)),)
pkgdiff		:= $(ALPINE_NAME)-$(release_diff).pkgdiff
$(pkgdiff): cmp-apks-iso previous $(PREV_ISO) $(ISO)
	@echo "==> Generating $@"
	@./cmp-apks-iso $(PREV_ISO) $(ISO) > $@

diff: $(pkgdiff)


#
# xdelta
#
xdelta	:= $(ALPINE_NAME)-$(release_diff).xdelta
$(xdelta): $(PREV_ISO) $(ISO)
	@echo "==> Generating $@"
	@xdelta3 -f -e -s $(PREV_ISO) $(ISO) $@

xdelta: $(xdelta)

endif

ifeq ($(ALPINE_ARCH),armhf)

#
# Raspberry Pi image
#
RPI_TAR_GZ      ?= $(ALPINE_NAME)-$(ALPINE_RELEASE)-$(ALPINE_ARCH).rpi.tar.gz

RPI_FW_COMMIT	:= f56e48c00b30a985ed68306348fc493bf6050f6b
RPI_URL		:= https://raw.githubusercontent.com/raspberrypi/firmware/$(RPI_FW_COMMIT)/boot/
RPI_BOOT_FILES	:= bootcode.bin fixup.dat start.elf
RPI_TEMP	:= $(DESTDIR)/tmp.rpi

RPI_BLOBS_DIR	:= $(DESTDIR)/rpi.blobs
RPI_BLOBS_STAMP	:= $(DESTDIR)/stamp.rpi.blobs

$(RPI_BLOBS_STAMP):
	@rm -rf $(RPI_BLOBS_DIR)
	@mkdir -p $(RPI_BLOBS_DIR)
	@cd $(RPI_BLOBS_DIR) ; curl -k --remote-name-all $(addprefix $(RPI_URL),$(RPI_BOOT_FILES)) && touch $(RPI_BLOBS_STAMP)

$(RPI_TAR_GZ): $(ALL_MODLOOP) $(ALL_INITFS) $(ALL_ISO_KERNEL) $(ISO_REPOS_DIRSTAMP) $(RPI_BLOBS_STAMP)
	@echo "== Generating $@"
	@rm -rf $(RPI_TEMP)
	@mkdir -p $(RPI_TEMP)
	cp $(RPI_BLOBS_DIR)/* $(RPI_TEMP)/
	cp $(ISO_DIR)/boot/vmlinuz-$(KERNEL_FLAVOR) $(RPI_TEMP)/
	cp $(subst %,$(KERNEL_FLAVOR),$(INITFS)) $(RPI_TEMP)/
	cp $(subst %,$(KERNEL_FLAVOR),$(MODLOOP)) $(RPI_TEMP)/
	cp -r $(ISO_DIR)/apks $(RPI_TEMP)/
	echo -e "BOOT_IMAGE=/vmlinuz-$(KERNEL_FLAVOR) alpine_dev=mmcblk0p1 quiet $(BOOT_OPTS)" > $(RPI_TEMP)/cmdline.txt
	echo -en "kernel=vmlinuz-$(KERNEL_FLAVOR)\ninitramfs $(subst %,$(KERNEL_FLAVOR),$(INITFS_NAME)) 0x00a00000\n" > $(RPI_TEMP)/config.txt
	tar czf $(RPI_TAR_GZ) -C "$(RPI_TEMP)" .

rpi: $(RPI_TAR_GZ)

endif

#
# USB image
#
USBIMG		:= $(ALPINE_NAME)-$(ALPINE_RELEASE)-$(ALPINE_ARCH).img
USBIMG_FREE	?= 8192
USBIMG_SIZE	= $(shell echo $$(( `du -s $(ISO_DIR) | awk '{print $$1}'` + $(USBIMG_FREE) )) )
MBRPATH		:= /usr/share/syslinux/mbr.bin

$(USBIMG): $(ISOFS_DIRSTAMP)
	@echo "==> Generating $@"
	@mformat -C -v 'ALPINE' -c 16 -h 64 -n 32 -i $(USBIMG) \
		-t $$(($(USBIMG_SIZE) / 1000)) ::
	@syslinux $(USBIMG)
	@mcopy -i $(USBIMG) $(ISO_DIR)/* $(ISO_DIR)/.[a-z]* ::
	@mcopy -i $(USBIMG) /dev/zero ::/zero 2>/dev/null || true
	@mdel -i $(USBIMG) ::/zero

USBIMG_SHA1	:= $(USBIMG).sha1
$(USBIMG_SHA1):	$(USBIMG)
	@echo "==> Generating sha1 sum"
	@sha1sum $(USBIMG) > $@ || rm -f $@

$(ALPINE_NAME).img:	$(USBIMG)
	@ln -sf $(USBIMG) $@

img:	$(ALPINE_NAME).img

sha1: $(ISO_SHA1)
sha256: $(ISO_SHA256)

release: $(ISO_SHA1) $(ISO_SHA256) $(xdelta) $(pkgdiff)


ifeq ($(ALPINE_ARCH),x86_64)
profiles ?= alpine alpine-mini alpine-vanilla alpine-xen
else
profiles ?= alpine alpine-mini alpine-vanilla
endif


current = $(shell cat current 2>/dev/null)

current:
	@test -n "$(ALPINE_RELEASE)"
	@echo $(ALPINE_RELEASE) > $@

all-release: current previous $(addsuffix .conf.mk, $(profiles))
	@echo "*"
	@echo "* Making $(current) releases"
	@echo "*"
	@echo
	@for i in $(profiles); do\
		echo "*";\
		echo "* Release $$i $(current)"; \
		echo "*"; \
		fakeroot $(MAKE) ALPINE_RELEASE=$(current) \
			PROFILE=$$i release || break; \
	done

edge desktop mini xen vanilla: current
	@fakeroot $(MAKE) ALPINE_RELEASE=$(current) PROFILE=alpine-$@ sha1

.PRECIOUS: $(MODLOOP_KERNELSTAMP) $(MODLOOP_DIRSTAMP) $(INITFS_DIRSTAMP) $(INITFS) $(ISO_KERNEL_STAMP)
