# WINDARTTALK — verify MACDART 47e07fb ST method-slicer fix in OUR browser.
# The slicer that turns a class's .mst source into per-method slices lives in
# language.dart (_stMembers/_stMemberIndex). Before the fix it had drifted from
# the parser: one-liner classes listed NO methods, `<`/`<=`/`<<` selectors were
# lost + replaced by a phantom named after the arg, and type-annotated headers
# truncated to just the header. We probe the fix through the browser's own
# control verbs: `selectors <Cls>` and `methodsrc <Cls>`.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8190/ws"}]
::dartui::resolveUi
after 7000   ;# boot + ST world import (stimport populates _decls)
puts "== slicer fix: does OUR browser show whole Smalltalk methods? =="

set fail 0
proc selcount {cls} {
    set n 0
    foreach ln [split [ui selectors $cls] "\n"] {
        if {[string trim $ln] ne ""} { incr n }
    }
    return $n
}

# Defect 2 in the report: one-liner classes (bodies not starting on the header
# line) listed ZERO methods. STHostService / AppUI / Accel are written entirely
# in one-liners, so each proves the fix by going 0 -> many.
puts "\n-- one-liner classes (were 0 methods before the fix) --"
foreach cls {STHostService AppUI Accel} {
    set n [selcount $cls]
    if {$n > 0} { puts "  ok    $cls -> $n methods" } \
    else        { puts "  FAIL  $cls -> $n methods (still zero)"; set fail 1 }
}

# Defect 3: the binary selector `<` (and `<=`, `<<`) was mistaken for a type
# annotation and dropped, with a phantom method named after the argument added.
puts "\n-- Magnitude: the '<' selector family --"
set mag [ui selectors Magnitude]
foreach ln [split $mag "\n"] { if {[string trim $ln] ne ""} { puts "      $ln" } }
if {[regexp {(^|\n)\s*\S+\s+<(=|<)?\s*(\n|$)} "\n$mag\n"]} {
    puts "  ok    Magnitude lists a '<' family selector"
} else {
    puts "  WARN  no bare '<' selector seen (inspect list above)"
}

# Defect 1: a type-annotated header truncated to the header with no body.
# Magnitude class>>defaultSort is the named case:  defaultSort ^ <[...]> [ ... ]
puts "\n-- Magnitude class>>defaultSort: header WITH a body? --"
set src [ui methodsrc Magnitude]
set blocks [split $src "\x1d"]
puts "  methodsrc Magnitude -> [expr {[llength $blocks]-1}] method blocks"
set found 0
foreach b $blocks {
    if {[string match {*defaultSort*} $b]} {
        set found 1
        set open [regexp -all {\[} $b]
        set close [regexp -all {\]} $b]
        puts "      defaultSort block: [string length $b] chars, \[=$open \]=$close"
        if {$open >= 1 && $close >= 1} { puts "  ok    defaultSort shows a body" } \
        else { puts "  FAIL  defaultSort truncated (no body)"; set fail 1 }
        break
    }
}
if {!$found} { puts "  note  defaultSort not on Magnitude (may be another class) — skipped" }

if {$fail} { puts "\nslicer fix: FAILURES ABOVE"; exit 1 }
puts "\nslicer fix: OK — browser shows whole methods"
exit 0
