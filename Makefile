#!/usr/bin/make -f

PROFILE		?= alpine

-include $(PROFILE).conf.mk

BUILD_DATE	:= $(shell date +%y%m%d)
ALPINE_RELEASE	?= $(BUILD_DATE)
ALPINE_NAME	?= alpine-test
ALPINE_ARCH	?= $(shell uname -m | sed 's/^i[0-9]/x/')

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
APK_OPTS	:= $(addprefix --repository ,$(APK_REPOS)) --keys-dir $(APK_KEYS)

find_apk_ver	= $(shell $(APK_SEARCH) $(APK_OPTS) $(1) | sort | uniq)
find_apk_file	= $(addsuffix .apk,$(call find_apk_ver,$(1)))
find_apk	= $(addprefix $(ISO_PKGDIR)/,$(call find_apk_file,$(1)))

# get apk does not support wildcards
get_apk         = $(addsuffix .apk,$(shell apk fetch --simulate $(APK_OPTS) $(1) 2>&1 | sed 's:^Downloading :$(ISO_PKGDIR)/:'))
expand_apk	= $(shell $(APK_SEARCH) --quiet $(APK_OPTS) $(1) | sort | uniq)

KERNEL_FLAVOR_DEFAULT	?= grsec
KERNEL_FLAVOR	?= $(KERNEL_FLAVOR_DEFAULT)
KERNEL_PKGNAME	= linux-$*
KERNEL_APK	= $(call get_apk,$(KERNEL_PKGNAME))

KERNEL		= $(word 3,$(subst -, ,$(notdir $(KERNEL_APK))))-$(word 2,$(subst -, ,$(notdir $(KERNEL_APK))))

ALPINEBASELAYOUT_APK := $(call find_apk,alpine-baselayout)
UCLIBC_APK	:= $(call get_apk,uclibc)
BUSYBOX_APK	:= $(call get_apk,busybox)
APK_TOOLS_APK	:= $(call get_apk,apk-tools)
STRACE_APK	:= $(call get_apk,strace)

APKS_FILTER	?= | grep -v -- '-dev$$' | grep -v 'sources'

APKS		?= '*'
APK_FILES	:= $(call get_apk,$(call expand_apk,$(APKS)))

all: isofs

help:
	@echo "Alpine ISO builder"
	@echo
	@echo "Type 'make iso' to build $(ISO)"
	@echo
	@echo "I will use the following sources files:"
	@echo " 1. $(notdir $(KERNEL_APK)) (looks like $(KERNEL))"
	@echo " 2. $(notdir $(MOD_APKS))"
	@echo " 3. $(notdir $(ALPINEBASELAYOUT_APK))"
	@echo " 4. $(notdir $(UCLIBC_APK))"
	@echo " 5. $(notdir $(BUSYBOX_APK))"
ifeq ($(APK_BIN),)
	@echo " 6. $(notdir $(APK_TOOLS_APK))"
else
	@echo " 6. $(APK_BIN)"
endif
	@echo
	@echo "ALPINE_NAME:    $(ALPINE_NAME)"
	@echo "ALPINE_RELEASE: $(ALPINE_RELEASE)"
	@echo "KERNEL_FLAVOR:  $(KERNEL_FLAVOR)"
	@echo "KERNEL:         $(KERNEL)"
	@echo "APKOVL:         $(APKOVL)"
	@echo

clean: clean-modloop clean-initfs
	rm -rf $(ISO_DIR) $(ISO_REPOS_DIRSTAMP) $(ISOFS_DIRSTAMP) \
		$(ALL_ISO_KERNEL)


$(APK_FILES):
	@mkdir -p "$(dir $@)";\
	p="$(notdir $(basename $@))";\
	apk fetch $(APK_OPTS) -R -v -o "$(dir $@)" $${p%-[0-9]*}
#	apk fetch $(APK_OPTS) -R -v -o "$(dir $@)" \
#		`apk search -q $(APK_OPTS) $(APKS) | sort | uniq`

#
# Modloop
#
MODLOOP		:= $(ISO_DIR)/boot/%.modloop.squashfs
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
	@rm -rf $(MODLOOP_DIR)
	@mkdir -p $(MODLOOP_DIR)/lib/modules/
	@for i in $(MODLOOP_PKGS); do \
		apk fetch $(APK_OPTS) --stdout $$i \
			| $(TAR) -C $(MODLOOP_DIR) -xz; \
	done
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
#INITFS_NAME	:= initramfs-$(MODLOOP_KERNEL_RELEASE)
INITFS_NAME	:= %.gz
INITFS		:= $(ISO_DIR)/boot/$(INITFS_NAME)

INITFS_DIR	= $(DESTDIR)/initfs.$*
INITFS_TMP	= $(DESTDIR)/tmp.initfs.$*
INITFS_DIRSTAMP := $(DESTDIR)/stamp.initfs.%
INITFS_FEATURES	:= ata base bootchart cdrom squashfs ext2 ext3 ext4 floppy raid scsi usb virtio
INITFS_PKGS	= $(MODLOOP_PKGS) alpine-base acct

initfs-%: $(INITFS)
	@:

ALL_INITFS = $(foreach flavor,$(KERNEL_FLAVOR),$(subst %,$(flavor),$(INITFS)))

initfs: $(ALL_INITFS)

$(INITFS_DIRSTAMP):
	@rm -rf $(INITFS_DIR) $(INITFS_TMP)
	@mkdir -p $(INITFS_DIR) $(INITFS_TMP)
	@for i in `apk fetch $(APK_OPTS) --simulate -R $(INITFS_PKGS) 2>&1\
			| sed 's:^Downloading ::; s:-[0-9].*::' | sort | uniq`; do \
		apk fetch $(APK_OPTS) --stdout $$i \
			| $(TAR) -C $(INITFS_DIR) -zx || exit 1; \
	done
	@cp -r $(APK_KEYS) $(INITFS_DIR)/etc/apk/ || true
	@if ! [ -e "$(INITFS_DIR)"/etc/mdev.conf ]; then \
		cat $(INITFS_DIR)/etc/mdev.conf.d/*.conf \
			> $(INITFS_DIR)/etc/mdev.conf; \
	fi
	@touch $@

#$(INITFS):	$(shell mkinitfs -F "$(INITFS_FEATURES)" -l $(KERNEL))
$(INITFS): $(INITFS_DIRSTAMP) $(MODLOOP_DIRSTAMP)
	@mkinitfs -F "$(INITFS_FEATURES)" -t $(INITFS_TMP) \
		-b $(INITFS_DIR) -o $@ $(MODLOOP_KERNEL_RELEASE)

clean-initfs-%:
	@rm -rf $(subst %,$*,$(INITFS) $(INITFS_DIRSTAMP)) $(INITFS_DIR)

clean-initfs: $(addprefix clean-initfs-,$(KERNEL_FLAVOR))

#
# Vserver template rules
#
VSTEMPLATE	:= $(ISO_DIR)/vs-template.tar.bz2
VSTEMPLATE_DIR 	:= $(DESTDIR)/vs-template

vstemplate: $(VSTEMPLATE)
	@echo "==> vstemplate: built $(VSTEMPLATE)"

#must be run as root or in fakeroot
$(VSTEMPLATE):
	@rm -rf "$(VSTEMPLATE_DIR)"
	@mkdir -p "$(VSTEMPLATE_DIR)"
	@apk add $(APK_OPTS) --initdb --root $(VSTEMPLATE_DIR) \
		alpine-base
	@cd $(VSTEMPLATE_DIR) && $(TAR) -jcf $@ *

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
SYSLINUX_CFG	:= $(ISO_DIR)/syslinux.cfg
SYSLINUX_SERIAL	?=



$(ISOLINUX_C32):
	@echo "==> iso: install $(notdir $@)"
	@mkdir -p $(dir $@)
	@if ! apk fetch $(APK_REPO) --stdout syslinux | $(TAR) -O -zx usr/share/syslinux/$(notdir $@) > $@; then \
		rm -f $@ && exit 1;\
	fi

$(ISOLINUX_BIN):
	@echo "==> iso: install isolinux"
	@mkdir -p $(dir $(ISOLINUX_BIN))
	@if ! apk fetch $(APK_REPO) --stdout syslinux | $(TAR) -O -zx usr/share/syslinux/isolinux.bin > $@; then \
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
		echo "	append /boot/xen.gz $(XEN_PARAMS) --- /boot/$$flavor alpine_dev=cdrom:iso9660 modules=loop,squashfs,sd-mod,usb-storage,floppy,sr-mod modloop=/boot/$$flavor.modloop.squashfs $(BOOT_OPTS) --- /boot/$$flavor.gz"; \
	done >>$@
else
	@echo "default $(KERNEL_FLAVOR_DEFAULT)" >>$@
	@for flavor in $(KERNEL_FLAVOR); do \
		echo "label $$flavor"; \
		echo "	kernel /boot/$$flavor"; \
		echo "	append initrd=/boot/$$flavor.gz alpine_dev=cdrom:iso9660 modules=loop,squashfs,sd-mod,usb-storage,floppy,sr-mod quiet $(BOOT_OPTS)"; \
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
		echo "	append /boot/xen.gz $(XEN_PARAMS) --- /boot/$$flavor alpine_dev=usbdisk:vfat modules=loop,squashfs,sd-mod,usb-storage modloop=/boot/$$flavor.modloop.squashfs $(BOOT_OPTS) --- /boot/$$flavor.gz"; \
	done >>$@
else
	@echo "default $(KERNEL_FLAVOR_DEFAULT)" >>$@
	@for flavor in $(KERNEL_FLAVOR); do \
		echo "label $$flavor"; \
		echo "	kernel /boot/$$flavor"; \
		echo "	append initrd=/boot/$$flavor.gz alpine_dev=usbdisk:vfat modules=loop,squashfs,sd-mod,usb-storage quiet $(BOOT_OPTS)"; \
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

$(ISO_PKGDIR)/APKINDEX.tar.gz: $(APK_FILES)
	@echo "==> iso: generating repository index"
	@apk index --description "$(ALPINE_NAME) $(ALPINE_RELEASE)" \
		--rewrite-arch $(ALPINE_ARCH) -o $@ $(ISO_PKGDIR)/*.apk
	@abuild-sign $@

$(ISO_KERNEL_STAMP): $(MODLOOP_DIRSTAMP)
	@echo "==> iso: install kernel $(KERNEL)"
	@mkdir -p $(dir $(ISO_KERNEL))
	@apk fetch $(APK_OPTS) --stdout $(KERNEL_PKGNAME) \
		| $(TAR) -C $(ISO_DIR) -xz boot
ifeq ($(PROFILE), alpine-xen)
	@apk fetch $(APK_OPTS) --stdout xen-hypervisor \
		| $(TAR) -C $(ISO_DIR) -xz boot
endif
	@rm -f $(ISO_KERNEL)
	@ln -s vmlinuz-$(MODLOOP_KERNEL_RELEASE) $(ISO_KERNEL)
	@rm -rf $(ISO_DIR)/.[A-Z]* $(ISO_DIR)/.[a-z]* $(ISO_DIR)/lib
	@touch $@

ALL_ISO_KERNEL = $(foreach flavor,$(KERNEL_FLAVOR),$(subst %,$(flavor),$(ISO_KERNEL_STAMP)))

APKOVL_STAMP = $(DESTDIR)/stamp.isofs.apkovl

$(APKOVL_STAMP):
	@if [ "x$(APKOVL)" != "x" ]; then \
		(cd $(ISO_DIR); wget $(APKOVL)); \
	fi
	@touch $@

$(ISOFS_DIRSTAMP): $(ALL_MODLOOP) $(ALL_INITFS) $(ISOLINUX_CFG) $(ISOLINUX_BIN) $(ISOLINUX_C32) $(ALL_ISO_KERNEL) $(ISO_REPOS_DIRSTAMP) $(APKOVL_STAMP) $(SYSLINUX_CFG) $(APKOVL_DEST)
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
#
# USB image
#
USBIMG 		:= $(ALPINE_NAME)-$(ALPINE_RELEASE)-$(ALPINE_ARCH).img
USBIMG_FREE	?= 8192
USBIMG_SIZE 	= $(shell echo $$(( `du -s $(ISO_DIR) | awk '{print $$1}'` + $(USBIMG_FREE) )) )
MBRPATH 	:= /usr/share/syslinux/mbr.bin

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
profiles ?= alpine alpine-mini alpine-vserver alpine-xen
else
profiles ?= alpine alpine-mini alpine-vserver
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

edge vserver desktop mini xen: current
	@fakeroot $(MAKE) ALPINE_RELEASE=$(current) PROFILE=alpine-$@ sha1

.PRECIOUS: $(MODLOOP_KERNELSTAMP) $(MODLOOP_DIRSTAMP) $(INITFS_DIRSTAMP) $(INITFS) $(ISO_KERNEL_STAMP)
