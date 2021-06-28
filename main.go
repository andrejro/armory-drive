// Copyright (c) F-Secure Corporation
// https://foundry.f-secure.com
//
// Use of this source code is governed by the license
// that can be found in the LICENSE file.

package main

import (
	"fmt"
	"log"
	"runtime"
	"time"

	"github.com/f-secure-foundry/tamago/soc/imx6"
	"github.com/f-secure-foundry/tamago/soc/imx6/usb"

	"github.com/f-secure-foundry/armory-drive/api"
	"github.com/f-secure-foundry/armory-drive/internal/ble"
	"github.com/f-secure-foundry/armory-drive/internal/crypto"
	"github.com/f-secure-foundry/armory-drive/internal/hab"
	"github.com/f-secure-foundry/armory-drive/internal/pairing"
	"github.com/f-secure-foundry/armory-drive/internal/ums"

	"github.com/f-secure-foundry/tamago/board/f-secure/usbarmory/mark-two"
)

// initialized at compile time (see Makefile)
var Revision string

func init() {
	if err := imx6.SetARMFreq(900); err != nil {
		panic(fmt.Sprintf("WARNING: error setting ARM frequency: %v\n", err))
	}

	log.SetFlags(0)
}

func main() {
	usbarmory.LED("blue", false)
	usbarmory.LED("white", false)

	if err := usbarmory.MMC.Detect(); err != nil {
		panic(err)
	}

	keyring := &crypto.Keyring{}

	err := keyring.Init(false)

	if err != nil {
		panic(err)
	}

	drive := &ums.Drive{
		Keyring: keyring,
		Mult:    ums.BLOCK_SIZE_MULTIPLIER,
		Lock: func() {
			keyring.SetCipher(api.Cipher_NONE, nil)
			usbarmory.LED("white", false)
		},
	}

	drive.Init()
	drive.Detect(usbarmory.SD)

	b := ble.Start()

	b.Drive = drive
	b.Keyring = keyring

	if drive.Card == nil {
		// provision Secure Boot as required
		hab.Init()

		code, err := b.PairingMode()

		if err != nil {
			panic(err)
		}

		pairingMode(drive, code)

		drive.Keyring = nil
		drive.Mult = 1
	}

	device := drive.ConfigureUSB()

	usb.USB1.Init()
	usb.USB1.DeviceMode()

	// To further reduce the attack surface, start the USB stack only when
	// the card is unlocked (or in pairing mode).
	if !drive.Ready {
		usb.USB1.Stop()

		for !drive.Ready {
			runtime.Gosched()
			time.Sleep(10 * time.Millisecond)
		}

		usb.USB1.Run()
	}

	usb.USB1.Reset()

	// never returns
	usb.USB1.Start(device)
}

func pairingMode(d *ums.Drive, code []byte) {
	d.Card = pairing.Disk(code, Revision)
	d.Ready = true

	go func() {
		var on bool

		for {
			select {
			case <-d.PairingComplete:
				usbarmory.LED("blue", false)
				return
			default:
			}

			on = !on
			usbarmory.LED("blue", on)

			runtime.Gosched()
			time.Sleep(1 * time.Second)
		}
	}()
}
