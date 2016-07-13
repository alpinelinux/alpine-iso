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
GENISO		= xorrisofs
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
CUR_KERNEL_FLAVOR	= $*
CUR_KERNEL_PKGNAME	= linux-$*

all: isofs

help:
	@echo "Alpine ISO builder"
	@echo
	@echo "Type 'make iso' to build $(ISO)"
	@echo
	@echo "ALPINE_NAME:    $(ALPINE_NAME)"
	@echo "ALPINE_RELEASE: $(ALPINE_RELEASE)"
	@echo "KERNEL_FLAVOR:  $(KERNEL_FLAVOR)"
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
MODLOOP_PKGS	= $(CUR_KERNEL_PKGNAME) $(MODLOOP_EXTRA) $(MODLOOP_FIRMWARE)
ifeq ($(ALPINE_NAME),alpine-uboot)
UBOOT_PKGS = u-boot
endif

modloop-%: $(MODLOOP)
	@:

ALL_MODLOOP = $(foreach flavor,$(KERNEL_FLAVOR),$(subst %,$(flavor),$(MODLOOP)))
ALL_MODLOOP_DIRSTAMP = $(foreach flavor,$(KERNEL_FLAVOR),$(subst %,$(flavor),$(MODLOOP_DIRSTAMP)))

modloop: $(ALL_MODLOOP)

$(MODLOOP_KERNELSTAMP):
	@echo "==> modloop: Unpacking kernel modules";
	@rm -rf $(MODLOOP_DIR) && mkdir -p $(MODLOOP_DIR)/tmp $(MODLOOP_DIR)/lib/modules
	@apk add $(APK_OPTS) \
		--initdb \
		--update \
		--no-script \
		--root $(MODLOOP_DIR)/tmp \
		$(MODLOOP_PKGS) $(UBOOT_PKGS)
	@mv "$(MODLOOP_DIR)"/tmp/lib/modules/* "$(MODLOOP_DIR)"/lib/modules/
	@if [ -d "$(MODLOOP_DIR)"/tmp/lib/firmware ]; then \
		find "$(MODLOOP_DIR)"/lib/modules -type f -name "*.ko" | xargs modinfo -F firmware | sort -u | while read FW; do \
			if [ -e "$(MODLOOP_DIR)/tmp/lib/firmware/$${FW}" ]; then \
				install -pD "$(MODLOOP_DIR)/tmp/lib/firmware/$${FW}" "$(MODLOOP_DIR)/lib/modules/firmware/$${FW}"; \
			fi \
		done \
	fi
	@cp $(MODLOOP_DIR)/tmp/usr/share/kernel/$*/kernel.release $@

MODLOOP_KERNEL_RELEASE = $(shell cat $(subst %,$*,$(MODLOOP_KERNELSTAMP)))

$(MODLOOP_DIRSTAMP): $(MODLOOP_KERNELSTAMP)
	@rm -rf $(addprefix $(MODLOOP_DIR)/modules/*/, source build)
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
INITFS_FEATURES	?= ata base bootchart cdrom squashfs ext2 ext3 ext4 mmc raid scsi usb virtio
INITFS_PKGS	= $(MODLOOP_PKGS) alpine-base acct mdadm

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
SYSLINUX_CFG	:= $(ISOLINUX)/syslinux.cfg
SYSLINUX_SERIAL	?=
SYSLINUX_TIMEOUT ?= 20
SYSLINUX_PROMPT ?= 1


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

# strip trailing -vanilla on kernel name
VMLINUZ_NAME = $$(echo vmlinuz-$(1) | sed 's/-vanilla//')

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
		echo "	append /boot/xen.gz $(XEN_PARAMS) --- /boot/$(call VMLINUZ_NAME,$$flavor) modloop=/boot/modloop-$$flavor modules=loop,squashfs,sd-mod,usb-storage $(BOOT_OPTS) --- /boot/initramfs-$$flavor"; \
	done >>$@
else
	@echo "default $(KERNEL_FLAVOR_DEFAULT)" >>$@
	@for flavor in $(KERNEL_FLAVOR); do \
		echo "label $$flavor"; \
		echo "	kernel /boot/$(call VMLINUZ_NAME,$$flavor)";\
		echo "	append initrd=/boot/initramfs-$$flavor modloop=/boot/modloop-$$flavor modules=loop,squashfs,sd-mod,usb-storage quiet $(BOOT_OPTS)"; \
	done >>$@
endif

clean-syslinux:
	@rm -f $(SYSLINUX_CFG) $(ISOLINUX_BIN)

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
			--recursive || { rm $(ISO_PKGDIR)/*.apk; exit 1; }
	@apk index --description "$(ALPINE_NAME) $(ALPINE_RELEASE)" \
		--rewrite-arch $(ALPINE_ARCH) -o $@ $(ISO_PKGDIR)/*.apk
	@abuild-sign $@

repo: $(ISO_PKGDIR)/APKINDEX.tar.gz

$(ISO_KERNEL_STAMP): $(MODLOOP_DIRSTAMP)
	@echo "==> iso: install kernel $(CUR_KERNEL_PKGNAME)"
	@mkdir -p $(dir $(ISO_KERNEL))
	@echo "Fetching $(CUR_KERNEL_PKGNAME)"
	@$(APK_FETCH_STDOUT) $(CUR_KERNEL_PKGNAME) \
		| $(TAR) -C $(ISO_DIR) -xz boot
ifeq ($(PROFILE), alpine-xen)
	@echo "Fetching xen-hypervisor"
	@$(APK_FETCH_STDOUT) xen-hypervisor \
		| $(TAR) -C $(ISO_DIR) -xz boot
endif
	@rm -f $(ISO_KERNEL)
	@if [ "$(CUR_KERNEL_FLAVOR)" = "vanilla" ]; then \
		ln -s vmlinuz $(ISO_KERNEL);\
	else \
		ln -s vmlinuz-$(CUR_KERNEL_FLAVOR) $(ISO_KERNEL);\
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

$(ISOFS_DIRSTAMP): $(ALL_MODLOOP) $(ALL_INITFS) $(ISO_REPOS_DIRSTAMP) $(ISOLINUX_BIN) $(ISOLINUX_C32) $(ALL_ISO_KERNEL) $(APKOVL_STAMP) $(SYSLINUX_CFG) $(APKOVL_DEST)
	@echo "$(ALPINE_NAME)-$(ALPINE_RELEASE) $(BUILD_DATE)" \
		> $(ISO_DIR)/.alpine-release
	@touch $@

$(ISO): $(ISOFS_DIRSTAMP)
	@echo "==> iso: building $(notdir $(ISO))"
	@$(GENISO) -o $(ISO) -l -J -R \
		-b $(ISOLINUX_DIR)/isolinux.bin \
		-c $(ISOLINUX_DIR)/boot.cat	\
		-no-emul-boot		\
		-boot-load-size 4	\
		-boot-info-table	\
		-quiet			\
		-follow-links		\
		-V "$(ALPINE_NAME) $(ALPINE_RELEASE) $(ALPINE_ARCH)" \
		$(ISO_OPTS)		\
		$(ISO_DIR) && isohybrid $(ISO)
	@ln -fs $@ $(ISO_LINK)

isofs: $(ISOFS_DIRSTAMP)
iso: $(ISO)

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

all-release: previous

endif

ifeq ($(ALPINE_NAME),alpine-uboot)

#
# U-Boot image
#

UBOOT_TAR_GZ	?= $(ALPINE_NAME)-$(ALPINE_RELEASE)-$(ALPINE_ARCH).tar.gz
UBOOT_TEMP	:= $(DESTDIR)/tmp.uboot
UBOOT_CFG	:= $(UBOOT_TEMP)/extlinux/extlinux.conf

$(UBOOT_TAR_GZ): $(ALL_MODLOOP) $(ALL_INITFS) $(ALL_ISO_KERNEL) $(ISO_REPOS_DIRSTAMP)
	@echo "== Generating $@"
	@rm -rf $(UBOOT_TEMP)
	@mkdir -p $(UBOOT_TEMP) $(UBOOT_TEMP)/boot/dtbs $(dir $(UBOOT_CFG))

	@echo "LABEL grsec" > $(UBOOT_CFG)
	@echo "  MENU DEFAULT" >> $(UBOOT_CFG)
	@echo "  MENU LABEL Linux grsec" >> $(UBOOT_CFG)
	@echo "  LINUX /boot/vmlinuz-grsec" >> $(UBOOT_CFG)
	@echo "  INITRD /boot/initramfs-grsec" >> $(UBOOT_CFG)
	@echo "  DEVICETREEDIR /boot/dtbs" >> $(UBOOT_CFG)
	@echo "  APPEND BOOT_IMAGE=/boot/vmlinuz-grsec modules=loop,squashfs,sd-mod,usb-storage modloop=/boot/modloop-grsec console=\$${console}" >> $(UBOOT_CFG)

	for flavor in $(KERNEL_FLAVOR); do \
		cp $(ISO_DIR)/boot/vmlinuz-$$flavor $(UBOOT_TEMP)/boot ; \
		cp $(subst %,$$flavor,$(INITFS)) $(UBOOT_TEMP)/boot ; \
		cp $(subst %,$$flavor,$(MODLOOP)) $(UBOOT_TEMP)/boot ; \
	done
	cp -r $(ISO_DIR)/apks $(UBOOT_TEMP)/
	cp -a $(DESTDIR)/modloop.*/tmp/usr/lib/linux-*-grsec/*.dtb $(UBOOT_TEMP)/boot/dtbs
	cp -a $(DESTDIR)/modloop.*/tmp/usr/share/u-boot $(UBOOT_TEMP)/
	tar czf $(UBOOT_TAR_GZ) -C "$(UBOOT_TEMP)" .


release_targets := $(UBOOT_TAR_GZ)
SHA1	:= $(UBOOT_TAR_GZ).sha1
SHA256	:= $(UBOOT_TAR_GZ).sha256
SHA512	:= $(UBOOT_TAR_GZ).sha512

$(SHA1) $(SHA256) $(SHA512): $(UBOOT_TAR_GZ)

else ifeq ($(ALPINE_NAME),alpine-rpi)

#
# Raspberry Pi image
#
RPI_TAR_GZ      ?= $(ALPINE_NAME)-$(ALPINE_RELEASE)-$(ALPINE_ARCH).rpi.tar.gz

RPI_FW_COMMIT	:= 4bf906cdd221c4f6815d0da7dda0cd59d25d945b
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
	@mkdir -p $(RPI_TEMP) $(RPI_TEMP)/boot
	cp $(RPI_BLOBS_DIR)/* $(RPI_TEMP)/
	for flavor in $(KERNEL_FLAVOR); do \
		cp $(ISO_DIR)/boot/vmlinuz-$$flavor $(RPI_TEMP)/boot/ ; \
		cp $(subst %,$$flavor,$(INITFS)) $(RPI_TEMP)/boot ; \
		cp $(subst %,$$flavor,$(MODLOOP)) $(RPI_TEMP)/boot/ ; \
	done
	echo -en "modules=loop,squashfs,sd-mod,usb-storage quiet $(BOOT_OPTS)" > $(RPI_TEMP)/cmdline.txt
	echo -en "disable_splash=1\nboot_delay=0\n" > $(RPI_TEMP)/config.txt
	echo -en "gpu_mem=256\ngpu_mem_256=64\n" > $(RPI_TEMP)/config.txt
	echo -en "[pi0]\nkernel=boot/vmlinuz-rpi\ninitramfs boot/initramfs-rpi 0x08000000\n" >> $(RPI_TEMP)/config.txt
	echo -en "[pi1]\nkernel=boot/vmlinuz-rpi\ninitramfs boot/initramfs-rpi 0x08000000\n" >> $(RPI_TEMP)/config.txt
	echo -en "[pi2]\nkernel=boot/vmlinuz-rpi2\ninitramfs boot/initramfs-rpi2 0x08000000\n" >> $(RPI_TEMP)/config.txt
	echo -en "[pi3]\nkernel=boot/vmlinuz-rpi2\ninitramfs boot/initramfs-rpi2 0x08000000\n" >> $(RPI_TEMP)/config.txt
	echo -en "[all]\n" >> $(RPI_TEMP)/config.txt
	echo -en "include usercfg.txt\n" >> $(RPI_TEMP)/config.txt
	cp -r $(ISO_DIR)/apks $(RPI_TEMP)/
	cp -a $(DESTDIR)/modloop.*/tmp/usr/lib/linux-*-rpi*/*.dtb $(RPI_TEMP)/
	for i in $(DESTDIR)/modloop.*/tmp/usr/lib/linux-*-rpi*/overlays; do \
		if [ -e "$$i" ]; then \
			cp -a "$$i" $(RPI_TEMP)/; \
		fi; \
	done
	tar czf $(RPI_TAR_GZ) -C "$(RPI_TEMP)" .

release_targets := $(RPI_TAR_GZ)
SHA1	:= $(RPI_TAR_GZ).sha1
SHA256	:= $(RPI_TAR_GZ).sha256
SHA512	:= $(RPI_TAR_GZ).sha512

$(SHA1) $(SHA256) $(SHA512): $(RPI_TAR_GZ)

else

release_targets := $(ISO)
SHA1	:= $(ISO).sha1
SHA256	:= $(ISO).sha256
SHA512	:= $(ISO).sha512

$(SHA1) $(SHA256) $(SHA512): $(ISO)

endif

#
# rules for generating checksum
#
target_filetype = $(subst .,,$(suffix $@))

CHECKSUMS := $(SHA1) $(SHA256) $(SHA512)
$(CHECKSUMS):
	@echo "==> $(target_filetype): Generating $@"
	@$(target_filetype)sum $(basename $@) > $@.tmp \
		&& mv $@.tmp $@

sha1: $(SHA1)
sha256: $(SHA256)
sha512: $(SHA512)

#
# releases
#

release_targets += $(CHECKSUMS)
release: $(release_targets)


ifeq ($(ALPINE_ARCH),armhf)
profiles ?= alpine-rpi alpine-uboot
else
ifeq ($(ALPINE_ARCH),x86_64)
profiles ?= alpine alpine-extended alpine-vanilla alpine-virt alpine-xen
else
profiles ?= alpine alpine-extended alpine-vanilla alpine-virt
endif
endif


current = $(shell cat current 2>/dev/null)

current:
	@test -n "$(ALPINE_RELEASE)"
	@echo $(ALPINE_RELEASE) > $@

all-release: current $(addsuffix .conf.mk, $(profiles))
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

edge desktop extended xen vanilla rpi uboot virt: current
	@fakeroot $(MAKE) ALPINE_RELEASE=$(current) PROFILE=alpine-$@ sha1

.PRECIOUS: $(MODLOOP_KERNELSTAMP) $(MODLOOP_DIRSTAMP) $(INITFS_DIRSTAMP) $(INITFS) $(ISO_KERNEL_STAMP)

