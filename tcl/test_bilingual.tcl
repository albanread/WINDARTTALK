# WINDARTTALK — bilingual GUI regression over the ext.dartui.send extension.
# Drives the RUNNING dartui (launched with --observe) via the VM-service
# WebSocket: bilingual Do It, backend verbs, and a full-window PNG snapshot.
#
#   tclsh tcl/test_bilingual.tcl [ws://127.0.0.1:8181/ws]
source [file join [file dirname [info script]] dartui.tcl]

set ::fails 0
proc check {label got want} {
    if {[string trim $got] eq [string trim $want]} {
        puts "  ok    $label => [string trim $got]"
    } else {
        puts "  FAIL  $label => got '[string trim $got]'  want '$want'"
        set ::fails 1
    }
}

set url [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
connect $url
::dartui::resolveUi
puts "connected — ui isolate $::dartui::uiIsolate"

puts "\n== bilingual Do It (Smalltalk AND Dart, one workspace) =="
check "ping"              [ui ping]                  pong
check "ST  25 sqrt"       [ui doit {25 sqrt}]        5.0
check "ST  #(1 2 3) size" [ui doit {#(1 2 3) size}]  3
check "ST  st> 6 * 7"     [ui doit {st> 6 * 7}]      42
check "Dart (()=>6*7)()"  [ui doit {(() => 6 * 7)()}] 42

puts "\n== full-window PNG snapshot =="
ui tab 0
set snap [ui snap [outpng ui_bilingual]]
puts "  snap -> $snap"

if {$::fails} { puts "\nBILINGUAL GUI: SOME CHECKS FAILED"; exit 1 }
puts "\nBILINGUAL GUI: ALL CHECKS PASSED"
exit 0
