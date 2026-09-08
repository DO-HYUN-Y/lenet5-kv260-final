set alexnet_root [file normalize [file join [file dirname [info script]] ..]]
# Read the real integration hierarchy, never simulation adapters, for synthesis.
set rtl_sources [lsort [glob [file join $alexnet_root rtl * *.sv]]]
