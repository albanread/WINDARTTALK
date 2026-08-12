# WINDARTTALK C6 — the Smalltalk post-mortem debugger tab. Define a class whose
# method chain raises, debug it, and see the ST call stack (not Dart plumbing).
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8190/ws"}]
::dartui::resolveUi
after 7000
puts "== C6: Smalltalk post-mortem debugger =="

puts "  define DbgDemo -> [ui accept {Object subclass: DbgDemo [ outer [ ^self inner ] inner [ ^nil zork ] ]}]"
puts "  usdebug DbgDemo new outer -> [ui usdebug {DbgDemo new outer}]"
after 800
puts "  snap -> [ui snap [outpng ui_stdebug_stack]]"
puts "  usdbsel 0 (top frame) -> [ui usdbsel 0]"
after 400
puts "  snap -> [ui snap [outpng ui_stdebug_frame]]"
puts "  usdebug ok case -> [ui usdebug {6 * 7}]"
after 500
puts "  snap -> [ui snap [outpng ui_stdebug_ok]]"
exit 0
