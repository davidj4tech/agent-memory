"""Command-line entry points.

These modules were previously loose files under `scripts/` that systemd units
invoked by absolute path out of a source checkout on the host. They are part of
the installed package now, so the units call console scripts on PATH and no
source tree needs to exist at runtime.
"""
