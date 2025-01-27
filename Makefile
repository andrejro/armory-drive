# Copyright (c) F-Secure Corporation
# https://foundry.f-secure.com
#
# Use of this source code is governed by the license
# that can be found in the LICENSE file.

BUILD_TAGS = "linkramsize,linkprintk"
REV = $(shell git rev-parse --short HEAD 2> /dev/null)

SHELL = /bin/bash
PROTOC ?= /usr/bin/protoc

APP := armory-drive
GOENV := GO_EXTLINK_ENABLED=0 CGO_ENABLED=0 GOOS=tamago GOARM=7 GOARCH=arm
TEXT_START := 0x80010000 # ramStart (defined in imx6/imx6ul/memory.go) + 0x10000

.PHONY: proto clean

#### primary targets ####

all: $(APP) $(APP)-install

imx: $(APP).imx

imx_signed: $(APP)-signed.imx

$(APP)-install: GOFLAGS= -tags netgo -trimpath -ldflags "-linkmode external -extldflags -static -s -w"
$(APP)-install:
	@if [ "${TAMAGO}" != "" ]; then \
		cd $(CURDIR)/assets && ${TAMAGO} generate && \
		cd $(CURDIR) && ${TAMAGO} build $(GOFLAGS) cmd/$(APP)-install/*.go; \
	else \
		cd $(CURDIR)/assets && go generate && \
		cd $(CURDIR) && go build $(GOFLAGS) cmd/$(APP)-install/*.go; \
	fi

$(APP)-install.exe: BUILD_OPTS := GOOS=windows CGO_ENABLED=1 CXX=x86_64-w64-mingw32-g++ CC=x86_64-w64-mingw32-gcc
$(APP)-install.exe:
	@if [ "${TAMAGO}" != "" ]; then \
		cd $(CURDIR)/assets && ${TAMAGO} generate && \
		cd $(CURDIR) && $(BUILD_OPTS) ${TAMAGO} build cmd/$(APP)-install/*.go; \
	else \
		cd $(CURDIR)/assets && go generate && \
		cd $(CURDIR) && $(BUILD_OPTS) go build cmd/$(APP)-install/*.go; \
	fi

$(APP)-install.dmg: TMPDIR := $(shell mktemp -d)
$(APP)-install.dmg:
	cd $(CURDIR)/assets && go generate && \
	cd $(CURDIR) && GOOS=darwin GOARCH=amd64 go build -o $(TMPDIR)/armory-drive-install_darwin-amd64 cmd/$(APP)-install/*.go && \
	mkdir $(TMPDIR)/dmg && \
	lipo -create -output $(TMPDIR)/dmg/armory-drive-install $(TMPDIR)/armory-drive-install_darwin-amd64 && \
	hdiutil create $(TMPDIR)/tmp.dmg -ov -volname "Armory Drive Install" -fs HFS+ -srcfolder $(TMPDIR)/dmg && \
	hdiutil convert $(TMPDIR)/tmp.dmg -format UDZO -o $(TMPDIR)/armory-drive-install.dmg && \
	cp $(TMPDIR)/armory-drive-install.dmg $(CURDIR)

#### utilities ####

check_tamago:
	@if [ "${TAMAGO}" == "" ] || [ ! -f "${TAMAGO}" ]; then \
		echo 'You need to set the TAMAGO variable to a compiled version of https://github.com/f-secure-foundry/tamago-go'; \
		exit 1; \
	fi

check_hab_keys:
	@if [ "${HAB_KEYS}" == "" ]; then \
		echo 'You need to set the HAB_KEYS variable to the path of secure boot keys'; \
		echo 'See https://github.com/f-secure-foundry/usbarmory/wiki/Secure-boot-(Mk-II)'; \
		exit 1; \
	fi

proto:
	@echo "generating protobuf classes"
	-rm -f *.pb.go
	PATH=$(shell echo ${GOPATH} | awk -F":" '{print $$1"/bin"}') ${PROTOC} --go_out=. armory.proto

dcd:
	echo $(GOMODCACHE)
	echo $(TAMAGO_PKG)
	cp -f $(GOMODCACHE)/$(TAMAGO_PKG)/board/f-secure/usbarmory/mark-two/imximage.cfg $(APP).dcd

clean:
	@rm -fr $(APP) $(APP).bin $(APP).imx $(APP)-signed.imx $(APP).sig $(APP).ota $(APP).csf $(APP).sdp $(APP).dcd *.pb.go $(CURDIR)/assets/tmp*.go
	@rm -fr $(APP)-install $(APP)-install.exe $(APP)-install.dmg

#### dependencies ####

$(APP): GOFLAGS= -tags ${BUILD_TAGS} -trimpath -ldflags "-s -w -T $(TEXT_START) -E _rt0_arm_tamago -R 0x1000 -X 'main.Revision=${REV}'"
$(APP): check_tamago proto
	@if [ "${OTA_KEYS}" != "" ]; then \
		echo '** WARNING ** Enabling OTA verification with public key ${OTA_KEYS}/armory-drive-minisign.pub'; \
	else \
		echo '** WARNING ** OTA verification is disabled'; \
	fi
	cd $(CURDIR)/assets && ${TAMAGO} generate && \
	cd $(CURDIR) && $(GOENV) $(TAMAGO) build $(GOFLAGS) -o $(CURDIR)/${APP} || (rm -f $(CURDIR)/assets/tmp*.go && exit 1)
	rm -f $(CURDIR)/assets/tmp*.go

$(APP).dcd: check_tamago
$(APP).dcd: GOMODCACHE=$(shell ${TAMAGO} env GOMODCACHE)
$(APP).dcd: TAMAGO_PKG=$(shell grep "github.com/f-secure-foundry/tamago v" go.mod | awk '{print $$1"@"$$2}')
$(APP).dcd: dcd

$(APP).bin: $(APP)
	$(CROSS_COMPILE)objcopy -j .text -j .rodata -j .shstrtab -j .typelink \
	    -j .itablink -j .gopclntab -j .go.buildinfo -j .noptrdata -j .data \
	    -j .bss --set-section-flags .bss=alloc,load,contents \
	    -j .noptrbss --set-section-flags .noptrbss=alloc,load,contents \
	    $(APP) -O binary $(APP).bin

$(APP).imx: $(APP).bin $(APP).dcd
	mkimage -n $(APP).dcd -T imximage -e $(TEXT_START) -d $(APP).bin $(APP).imx
	# Copy entry point from ELF file
	dd if=$(APP) of=$(APP).imx bs=1 count=4 skip=24 seek=4 conv=notrunc

#### secure boot ####

$(APP)-signed.imx: check_hab_keys $(APP).imx
	${TAMAGO} install github.com/f-secure-foundry/crucible/cmd/habtool
	$(shell ${TAMAGO} env GOPATH)/bin/habtool \
		-A ${HAB_KEYS}/CSF_1_key.pem \
		-a ${HAB_KEYS}/CSF_1_crt.pem \
		-B ${HAB_KEYS}/IMG_1_key.pem \
		-b ${HAB_KEYS}/IMG_1_crt.pem \
		-t ${HAB_KEYS}/SRK_1_2_3_4_table.bin \
		-x 1 \
		-s \
		-i $(APP).imx \
		-o $(APP).sdp && \
	$(shell ${TAMAGO} env GOPATH)/bin/habtool \
		-A ${HAB_KEYS}/CSF_1_key.pem \
		-a ${HAB_KEYS}/CSF_1_crt.pem \
		-B ${HAB_KEYS}/IMG_1_key.pem \
		-b ${HAB_KEYS}/IMG_1_crt.pem \
		-t ${HAB_KEYS}/SRK_1_2_3_4_table.bin \
		-x 1 \
		-i $(APP).imx \
		-o $(APP).csf && \
	cat $(APP).imx $(APP).csf > $(APP)-signed.imx
	@if [ "${OTA_KEYS}" != "" ]; then \
		echo -e "\n" | minisign -S -s ${OTA_KEYS}/armory-drive-minisign.sec -m $(APP)-signed.imx -x $(APP).sig -c `stat -L -c %s ${APP}-signed.imx` && \
		minisign -V -p ${OTA_KEYS}/armory-drive-minisign.pub -m $(APP)-signed.imx -x $(APP).sig && \
		cat $(APP).sig $(APP)-signed.imx > $(APP).ota; \
	fi
