## set debug_rtd_standalone true, to enable debugging
##   of this rtd, in standalone mode ... 
###################################################
set debug_rtd_standalone false


if { $debug_rtd_standalone } {
  set rt::partid xcku5p-ffvb676-2-e
  if { ! [info exists ::env(RT_TMP)] } {
    set ::env(RT_TMP) [pwd]
  } 
  source $::env(SYNTH_COMMON)/task_worker.tcl
} 
set genomeRtd $env(RT_TMP)/56AB88E0.rtd
set parallel_map_command "stitch_original_genomes"
set rt::parallelMoreOptions "set rt::bannerSuppress true"
puts "this genome's name is [subst -nocommands -novariables {cnn_core_dense_latency_wrapper_ap_fixed_ap_fixed_17_9_5_3_0_config10_s__GB9}]"
puts "this genome's rtd file is $genomeRtd"
source $::env(HRT_TCL_PATH)/rtSynthPrep.tcl
source $::env(RT_TMP)/parameters.tcl
set genomeName [subst -nocommands -novariables {cnn_core_dense_latency_wrapper_ap_fixed_ap_fixed_17_9_5_3_0_config10_s__GB9}]
source $::env(SYNTH_COMMON)/synthesizeAGenome.tcl 
set rt::parallelMoreOptions "set rt::bannerSuppress false"
