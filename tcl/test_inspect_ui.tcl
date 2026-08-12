# WINDARTTALK C6 — the Smalltalk object Inspector tab. Inspect an expression,
# select a slot, dive into it, come back; snapshot the pane at each step.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8190/ws"}]
::dartui::resolveUi
after 7000
puts "== C6: Smalltalk object Inspector =="

puts "  uinspect Fraction   -> [ui uinspect {Fraction numerator: 22 denominator: 7}]"
after 900
puts "  snap                -> [ui snap [outpng ui_inspect_fraction]]"

puts "  uinspsel 1 (numer.) -> [ui uinspsel 1]"
after 400
puts "  uinspdive           -> [ui uinspdive]"
after 700
puts "  snap                -> [ui snap [outpng ui_inspect_dive]]"
puts "  uinspback           -> [ui uinspback]"
after 400

puts "  uinspect OrderedColl -> [ui uinspect {OrderedCollection withAll: #(10 20 30)}]"
after 900
puts "  snap                -> [ui snap [outpng ui_inspect_oc]]"
exit 0
