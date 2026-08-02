# WINDARTTALK C3 backend — live Smalltalk compile. Accept a class, call it,
# redefine a method, call again: the change is live (recompiled through the
# language isolate's acceptMany -> _stReloadAll). Driven over the wire.
source [file join [file dirname [info script]] dartui.tcl]
set ::f 0
proc check {label got want} {
    if {[string trim $got] eq $want} { puts "  ok    $label => [string trim $got]" } \
    else { puts "  FAIL  $label => '[string trim $got]' want '$want'"; set ::f 1 }
}
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
after 5000
puts "== C3: live Smalltalk method compile (Accept -> recompile -> live) =="
puts "  accept v1 -> [ui accept {Object subclass: Foo3 [ bar [ ^42 ] ]}]"
check "Foo3 bar v1"       [ui doit {st> Foo3 new bar}]  42
puts "  accept v2 -> [ui accept {Object subclass: Foo3 [ bar [ ^99 ] ]}]"
check "Foo3 bar v2 (live)" [ui doit {st> Foo3 new bar}] 99
if {$::f} { puts "\nC3 BACKEND: FAILED"; exit 1 }
puts "\nC3 BACKEND: OK — live ST recompile through Accept"
exit 0
