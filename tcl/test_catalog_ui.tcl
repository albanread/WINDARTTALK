# WINDARTTALK C6 — the rolling catalog. Enumerate runnable apps/games/demos,
# load a NEW .mst at runtime, watch it appear, and run it.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8190/ws"}]
::dartui::resolveUi
after 7000
puts "== C6: rolling catalog =="

puts "  ucatalog             -> [ui ucatalog]"
after 500
puts "  snap                 -> [ui snap [outpng ui_catalog]]"

set mst [file normalize [file join [file dirname [info script]] rolling_hello.mst]]
puts "  ucatload rolling_hello.mst -> [ui ucatload $mst]"
after 800
puts "  snap                 -> [ui snap [outpng ui_catalog_rolled]]"

puts "  ucatapp RollingHello -> [ui ucatapp RollingHello]"
after 900
puts "  snap                 -> [ui snap [outpng ui_catalog_app]]"
exit 0
