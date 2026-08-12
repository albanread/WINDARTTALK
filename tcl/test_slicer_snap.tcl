# Visual proof: browse a previously-broken class in the C2 Browser pane and snap.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8190/ws"}]
::dartui::resolveUi
after 1500
puts "  browse STHostService -> [ui browse STHostService]"
after 1400
puts "  snap -> [ui snap [outpng ui_slicer_sthost]]"
exit 0
