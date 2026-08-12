# WINDARTARM — drive the LIVE IDE over the vm-service control plane, on arm64.
#
# Proves the whole remote-control path works on Windows-on-ARM: the Observatory
# WebSocket, dartui.tcl's own JSON parser + WS framing, the ext.dartui.send
# extension, and the bilingual (Dart + Smalltalk) verbs behind it.
#
#   tclsh test_arm64_smoke.tcl ?ws-url?          (default ws://127.0.0.1:8181/ws)
#
# Requires a running:  dartui.exe --observe workspace.dart
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
after 6000

set fails 0
proc check {label expected actual} {
    global fails
    if {[string match $expected $actual]} {
        puts [format "  %-26s OK    %s" $label $actual]
    } else {
        incr fails
        puts [format "  %-26s FAIL  expected '%s' got '%s'" $label $expected $actual]
    }
}

puts "== WINDARTARM: live IDE over the wire =="

# 1. the control plane itself
check "ping"            "pong"  [ui ping]

# 2. Dart evaluation in the live workspace
check "doit (Dart)"     "*35*"  [ui doit {(2 + 3) * 7}]

# 3. Smalltalk evaluation through the SAME wire — the bilingual claim
check "doit (Smalltalk)" "*5.0*" [ui doit {st> 25 sqrt}]
check "doit (ST arith)"  "*42*"  [ui doit {st> 6*7}]

# 4. drive the UI: switch tabs and browse a class.
# NB these assert on real content: an earlier draft used "*" as the expected
# pattern, which `string match` satisfies with ANYTHING — including an error
# reply — so the checks could never fail and were worse than no test.
check "tab -> Browser"  "ok"          [ui tab 1]
after 300
check "browse Duration" "*Duration*"  [ui browse Duration]
after 300

# 5. bilingual Find: searches the Dart VM AND the Smalltalk world
check "ufind sqrt"      "*matches*"   [ui ufind sqrt]
after 300

# 6. capture through the de-pinned output helper (was a hardcoded E: path)
set png [outpng arm64_smoke]
check "snap -> outpng"  "*arm64_smoke.png*" [ui snap $png]
puts "  capture written to: $png"

puts ""
if {$fails == 0} { puts "ARM64_SMOKE_OK" } else { puts "ARM64_SMOKE_FAIL ($fails)" }
exit [expr {$fails == 0 ? 0 : 1}]
