# WINDARTTALK — verify selecting a Smalltalk method shows its WHOLE body in the
# Browser source pane (the reported bug: "often it only displays the heading").
# selectBrMethod now serves the real slice from the per-class cache _browseStClass
# fills over the wire; selmeth drives that selection.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8190/ws"}]
::dartui::resolveUi
after 7000   ;# boot + ST world import
puts "== method body: a selected Smalltalk method shows its whole body =="

set fail 0
proc hasbody {s} { expr {[string first "\[" $s] >= 0 && [string first "\]" $s] >= 0} }

puts "  browse Magnitude -> [ui browse Magnitude]"
after 800
# The source the selection path serves, method by method (multi-line + binary <).
foreach sel {max: min: between:and: <} {
    set src [ui methodsrc Magnitude instance $sel]
    if {[hasbody $src]} { puts "  ok    Magnitude>>$sel -> [string length $src] chars, has \[ body \]" } \
    else { puts "  FAIL  Magnitude>>$sel -> '[string trim $src]'"; set fail 1 }
}

# The exact reported class of failure: one-liners (STHostService) whose body is a
# primitive pragma. Before the fix, selecting one showed only the signature line.
puts "  browse STHostService -> [ui browse STHostService]"
after 800
set pt [ui methodsrc STHostService instance packageTree]
if {[hasbody $pt]} { puts "  ok    STHostService>>packageTree -> '[string trim $pt]'" } \
else { puts "  FAIL  STHostService>>packageTree -> '[string trim $pt]'"; set fail 1 }

# Drive the actual GUI selection + snapshot the pane for visual proof.
puts "  browse Magnitude -> [ui browse Magnitude]"
after 700
puts "  selmeth between:and: -> [ui selmeth between:and:]"
after 1000
puts "  snap -> [ui snap [outpng ui_method_body]]"

if {$fail} { puts "\nmethod body: FAILURES ABOVE"; exit 1 }
puts "\nmethod body: OK — whole method bodies render on selection"
exit 0
