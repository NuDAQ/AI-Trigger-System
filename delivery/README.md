# DAQ delivery package

This directory describes the generated DAQ delivery package. The generated package is a small release asset for first integration testing, not a copy of the development repository.

Generate the package from the repository root:

```bash
python3 scripts/package_delivery.py --version v3.2.0-daq-test
```

The output is written under `dist/`:

```text
dist/ai-trigger-daq-v3.2.0-daq-test/
dist/ai-trigger-daq-v3.2.0-daq-test.zip
```

Upload the zip file as a GitHub Release asset. The GitHub auto-generated source archives are full repository snapshots and are not the intended DAQ handoff package.

The package contains one user-facing interface document, its image assets, all required RTL sources, the OOC constraint file, a Vivado `add_files.tcl`, and version/manifest files. The copied RTL is self-contained for Vivado integration except for vendor-provided Xilinx XPM primitives.

`scripts/add_files.tcl` imports the package RTL and constraints into the current Vivado project, but it intentionally does not set the project top. Keep the system top unchanged and instantiate `AI_TRIGGER_TOP` from that top, or set `AI_TRIGGER_TOP` manually only for standalone block-level checks.

The CNN wrapper dependency contributes one RTL source at `rtl/cnn-core-wrapper/hw/rtl/cnn_core_wrapper_top.v`. The generated HLS CNN implementation sources are copied separately under `rtl/cnn-core/`.
