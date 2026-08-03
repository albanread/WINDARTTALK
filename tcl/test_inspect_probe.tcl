# Backend smoke test for the ST inspector verbs (raw struct via passthrough).
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8190/ws"}]
::dartui::resolveUi
after 7000
puts "inspect 3/4                -> [ui inspect {3/4}]"
puts "inspect Fraction n:d:      -> [ui inspect {Fraction numerator: 3 denominator: 4}]"
puts "  inspectivar 1            -> [ui inspectivar 1]"
puts "  inspectback              -> [ui inspectback]"
puts "inspect 42 (no ivars)      -> [ui inspect {42}]"
puts "inspect 'hello' (String)   -> [ui inspect {'hello'}]"
puts "inspect OrderedCollection  -> [ui inspect {OrderedCollection withAll: #(10 20 30)}]"
exit 0
