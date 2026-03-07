# AI Trigger System

## Pre-requisites

```
cargo install bender
```

## Initialize
```
bender update
```

## Generate Scripts
```
bender script vivado -t vivado > add_sources.tcl
```

```
bender script vivado-sim -t sim > add_sim_files.tcl
```