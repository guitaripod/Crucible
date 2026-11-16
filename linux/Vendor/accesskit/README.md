# Vendored AccessKit

Crucible for Linux reaches screen readers (Orca) through AccessKit's C API and its Unix adapter, which speaks AT-SPI over D-Bus (docs/LINUX.md, Accessibility). Kiln hands it a tree of the window's views: roles, names, values, bounds, the focus and the actions an assistive tool may ask for.

- `VERSIONS`: the accesskit-c tag and the commit it must resolve to.

`../../scripts/build-accesskit.sh` builds the static library from that tag with cargo (`Cargo.lock` pinned, about 25 s) into `.build/mpv`, next to libmpv, so the one `PKG_CONFIG_PATH` the build already sets finds `accesskit.pc`. To move to a new release: change both lines, rebuild, and check Orca still reads the focus moving through Home, a title page and Search.
