# Crucible for Linux

A Plex client in the Apple TV design, with Liquid Glass and HDR video, for Wayland desktops with Vulkan.

Install for your user (into `~/.local`):

    ./install.sh

or somewhere else with `./install.sh --prefix DIR`. Crucible then appears in your application launcher, and **You → About
Crucible → Software Update** installs each new release in place.

It needs the libraries a desktop already has (Wayland, Vulkan, Pango, FFmpeg, PipeWire, libsecret, SDL 3); on Arch the
`crucible` AUR package pulls them in. Source, issues and the licence (GPL-3.0): https://github.com/guitaripod/Crucible
