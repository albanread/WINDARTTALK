# WINDARTTALK C6 — bilingual Find + Senders. Find searches the Dart VM AND the
# Smalltalk world; Senders lists every class whose source references the name.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8190/ws"}]
::dartui::resolveUi
after 7000
puts "== C6: bilingual Find + Senders =="
puts "  ufind sqrt          -> [ui ufind sqrt]"
after 400
puts "  snap                -> [ui snap [outpng ui_find]]"
puts "  usenders Fraction   -> [ui usenders Fraction]"
after 400
puts "  snap                -> [ui snap [outpng ui_senders]]"
puts "  ufindopen 0 (-> Browser) -> [ui ufindopen 0]"
after 400
puts "  snap                -> [ui snap [outpng ui_find_opened]]"
exit 0
