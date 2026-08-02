# WINDARTTALK C2 UI — browse a Smalltalk class in the live dartui Browser tab,
# then snapshot it. The ST world imports on boot; we wait, browse, and capture.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
puts "== C2 UI: browse Smalltalk in the dartui Browser =="

after 6000   ;# let the 97-file ST world import into the language isolate
set r [ui browse OrderedCollection]
puts "  browse OrderedCollection -> $r"
after 1200
set snap [ui snap e:/windart-talk/build/ui_c2_browser.png]
puts "  snap -> $snap"

if {[string match "*browsed ST*" $r]} {
    puts "\nC2 UI: OK — Smalltalk class browsed in the GUI"
    exit 0
}
puts "\nC2 UI: FAIL — fell to the mirror path (ST world not loaded yet?)"
exit 1
