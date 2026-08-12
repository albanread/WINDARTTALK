# WINDARTTALK C2 UI — browse a Smalltalk class in the live dartui Browser tab,
# then snapshot it. The ST world imports on boot; we wait, browse, and capture.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
puts "== C2 UI: browse Smalltalk in the dartui Browser =="

# WINDARTARM: wait for the CONDITION, not a fixed interval. The ST world import
# lands in two async stages — "imported N classes" (loader done) and only then
# "N Smalltalk classes browsable" (the library becomes visible to the Browser).
# A flat `after 6000` passed standalone but failed in a full battery run, where
# this test starts immediately after test_c2_browser.tcl's own 97-file stimport
# and the second stage has not landed yet. Retry until the ST path is taken.
set r ""
for {set i 0} {$i < 20} {incr i} {
    set r [ui browse OrderedCollection]
    if {[string match "*browsed ST*" $r]} break
    after 1000
}
puts "  browse OrderedCollection -> $r  (after [expr {$i + 1}] attempt(s))"
after 1200
set snap [ui snap [outpng ui_c2_browser]]
puts "  snap -> $snap"

if {[string match "*browsed ST*" $r]} {
    puts "\nC2 UI: OK — Smalltalk class browsed in the GUI"
    exit 0
}
puts "\nC2 UI: FAIL — fell to the mirror path (ST world not loaded yet?)"
exit 1
