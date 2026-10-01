#!/bin/zsh
# Relaunch the overlay after choosing "Quit Agent Snake" from the menu bar.
launchctl kickstart "gui/$(id -u)/com.agentsnake.overlay"
