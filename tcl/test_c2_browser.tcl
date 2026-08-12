# WINDARTTALK C2 — the Smalltalk world is browsable over the wire. Imports the
# world into the language isolate's image, then queries the browser backend
# verbs (classes / members / classsrc) the dartui browser tab will render.
source [file join [file dirname [info script]] dartui.tcl]

set ::f 0
proc has {label got want} {
    if {[string match "*$want*" $got]} {
        puts "  ok    $label  (contains '$want')"
    } else {
        puts "  FAIL  $label => '[string range $got 0 140]'  (want '$want')"
        set ::f 1
    }
}

connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
puts "== C2: the Smalltalk world is browsable over the wire =="

# The ST world corpus is a SEPARATE repo (MACDARTV1, obtained from github) and
# may be absent — stimport degrades gracefully. Override with WINDART_ST_WORLD;
# otherwise look beside this checkout: <workRoot>/MACDARTV1/macdart/st/world.
if {[info exists ::env(WINDART_ST_WORLD)] && [string trim $::env(WINDART_ST_WORLD)] ne ""} {
    set stworld [string trim $::env(WINDART_ST_WORLD)]
} else {
    # The corpus is vendored at <repo>/st/world (see st/PROVENANCE.md) — same
    # default test/workspace.dart uses, so a fresh clone needs no configuration.
    set stworld [file join [file dirname $::WINDART_TCLDIR] st world]
}
set imp [ui stimport $stworld]
puts "  stimport -> [string range $imp 0 110]"
has "classes"    [ui classes {}]                 OrderedCollection
has "members OC" [ui members OrderedCollection]  {do:}
set src [ui classsrc OrderedCollection]
has "classsrc"   $src                            {subclass: OrderedCollection}
puts "  classsrc\[0..150\]: [string range $src 0 150]"

if {$::f} { puts "\nC2 BACKEND: FAILED"; exit 1 }
puts "\nC2 BACKEND: OK — the ST world is browsable"
exit 0
