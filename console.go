// Copyright (c) F-Secure Corporation
// https://foundry.f-secure.com
//
// Use of this source code is governed by the license
// that can be found in the LICENSE file.

package main

import (
	"io/ioutil"
	"log"
	"os"
	"time"
	_ "unsafe"

	"github.com/f-secure-foundry/tamago/board/f-secure/usbarmory/mark-two"
	"github.com/f-secure-foundry/tamago/soc/imx6"
)

// The USB armory Mk II serial console is exposed through a debug accessory
// which requires an I2C command to the receptacle port controller to be
// accessed. While such an explicit initialization is required, a malicious
// party could inject I2C commands externally, by tampering with the board bus
// and therefore forcibly enabling serial logging.
//
// This firmware does not log any sensitive information to the serial console,
// however it is desirable to silence any potential stack trace or runtime
// errors to avoid unwanted information leaks. To this end the following steps
// are required to disable the serial console securely.
//
// The TamaGo board support for the USB armory Mk II enables the serial console
// (UART2) at runtime initialization, which therefore invokes imx6.UART2.Init()
// before init().
//
// To this end the runtime printk function, responsible for all console logging
// operations (i.e. stdout/stderr), is overridden with a NOP. Secondarily UART2
// is disabled at the first opportunity (init()).

// by default any serial output is supressed before UART2 disabling
var serialTx = func(c byte) {
}

func init() {
	if imx6.SNVS() {
		// disable console
		imx6.UART2.Disable()

		// silence logging
		log.SetOutput(ioutil.Discard)
		return
	}

	log.SetOutput(os.Stdout)

	serialTx = func(c byte) {
		imx6.UART2.Tx(c)
	}

	debugConsole, _ := usbarmory.DetectDebugAccessory(250 * time.Millisecond)
	<-debugConsole
}

//go:linkname printk runtime.printk
func printk(c byte) {
	serialTx(c)
}
