connect -url tcp:localhost:3121
targets -set -filter {name == "PS TAP"}
rst -system
puts "KV260_SYSTEM_RESET_ISSUED"
disconnect
exit
