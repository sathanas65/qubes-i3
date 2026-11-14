#!/bin/bash
xrandr --size 1920x1080 --output eDP-1 --primary --mode 1920x1080 --pos 0x0 --set TearFree on --output DisplayPort-1 --off --output HDMI-A-0 --off
sh scripts/background.sh
