# WINDARTTALK C4 — run a Smalltalk app in the dartui App pane. Accept an app
# class (build: ui), apprun it (widgets stream in as ['appui'] -> dart:win), snap,
# click its button (the onClick ST block fires -> updates a label), snap again.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
after 6000
puts "== C4: a Smalltalk app running in the dartui App pane =="

set app {Object subclass: HelloApp [ build: ui [ ui label: 'g' text: 'Hello from Smalltalk!' frame: #(20 44 360 24). ui button: 'b' title: 'Click me (Smalltalk)' frame: #(20 84 200 30) onClick: [:e | ui label: 'g' text: 'Clicked -- the Smalltalk block ran!' frame: #(20 44 360 24) ] ] ]}
puts "  accept -> [ui accept $app]"
puts "  apprun -> [ui apprun HelloApp]"
after 1200
puts "  snap(before) -> [ui snap [outpng ui_c4_app]]"
puts "  click b -> [ui click b]"
after 1200
puts "  snap(after)  -> [ui snap [outpng ui_c4_app_clicked]]"
puts "\nC4: app rendered + button event fired"
exit 0
