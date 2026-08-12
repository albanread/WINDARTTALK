# WINDARTARM triage — is a SECOND `stimport` of an already-loaded ST world safe?
#
# The TCL battery aborted dartui with
#   runtime/vm/intermediate_language.h: 3345: expected: !function.IsNull()
# immediately after test_c2_browser.tcl issued `ui stimport`, on an IDE that had
# already imported the same world at startup (WINDART_ST_WORLD). This isolates
# that one action: import, then import again, then evaluate.
#
#   tclsh test_reimport.tcl ?ws-url? ?world-dir?
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
after 6000

if {$argc > 1} {
    set stworld [lindex $argv 1]
} elseif {[info exists ::env(WINDART_ST_WORLD)] && [string trim $::env(WINDART_ST_WORLD)] ne ""} {
    set stworld [string trim $::env(WINDART_ST_WORLD)]
} else {
    set work [file dirname [file dirname $::WINDART_TCLDIR]]
    set stworld [file join $work MACDARTV1 macdart st world]
}

puts "== reimport probe =="
puts "  world: $stworld"
puts "  alive before      : [ui ping]"
puts "  ST doit before     : [ui doit {st> 6*7}]"

puts "  stimport #1 -> [ui stimport $stworld]"
after 1500
puts "  alive after #1    : [ui ping]"
puts "  ST doit after #1   : [ui doit {st> 6*7}]"

puts "  stimport #2 -> [ui stimport $stworld]"
after 1500
puts "  alive after #2    : [ui ping]"
puts "  ST doit after #2   : [ui doit {st> 6*7}]"
puts "  ST class browse    : [ui doit {st> OrderedCollection new add: 1; yourself}]"

puts "REIMPORT_OK"
exit 0
