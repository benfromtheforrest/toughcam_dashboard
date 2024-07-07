#!/bin/bash

# Replace '1-1' with the correct USB bus-port for your GPS device
USB_PORT="1-2"

# Unbind the USB device
echo "$USB_PORT" > /sys/bus/usb/drivers/usb/unbind
sleep 2

# Bind the USB device
echo "$USB_PORT" > /sys/bus/usb/drivers/usb/bind
