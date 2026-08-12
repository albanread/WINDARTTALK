# WINDARTTALK C3 UI — the Smalltalk editor: load a class (real .mst source), and
# a live edit->Accept->run cycle THROUGH the editor UI (Accept routes to the
# language isolate, recompiles, morphs).
source [file join [file dirname [info script]] dartui.tcl]
set ::f 0
proc check {label got want} {
    if {[string trim $got] eq $want} { puts "  ok    $label => [string trim $got]" } \
    else { puts "  FAIL  $label => '[string trim $got]' want '$want'"; set ::f 1 }
}
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
after 6000
puts "== C3 UI: Smalltalk editor (real source + live Accept) =="

puts "  edclass OrderedCollection -> [ui edclass OrderedCollection]"
after 1000
puts "  snap -> [ui snap [outpng ui_c3_editor]]"

ui edclass Widget9
ui edset {Object subclass: Widget9 [ area [ ^10 ] ]}
puts "  edaccept v1 -> [ui edaccept]"
after 700
check "Widget9 area v1"        [ui doit {st> Widget9 new area}]  10
ui edset {Object subclass: Widget9 [ area [ ^77 ] ]}
puts "  edaccept v2 -> [ui edaccept]"
after 700
check "Widget9 area v2 (live)" [ui doit {st> Widget9 new area}]  77

if {$::f} { puts "\nC3 UI: some checks failed (editor snapshot still captured)"; exit 1 }
puts "\nC3 UI: OK — live Smalltalk editing in the GUI"
exit 0
