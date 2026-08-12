# WINDARTTALK C5 — run a Smalltalk game in the D3D11 game pane. The ST game runs
# in the language isolate and streams the SAME ['draw']/gp* frames a Dart demo
# does; we render them through _gameFrame + the pull-tick.
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8185/ws"}]
::dartui::resolveUi
after 6000
puts "== C5: run a Smalltalk game in the dartui game pane =="

set raw [ui stgames]
puts "  stgames -> $raw"
set first MandelZoom
puts "  game: '$first'  (pure-compute fractal; sound games need the deferred FFI trampoline)"

set r [ui stgame $first]
puts "  stgame $first -> $r"
after 3000
set gs [ui gpsnap [outpng ui_c5_game]]
puts "  gpsnap result: $gs"
exit 0
