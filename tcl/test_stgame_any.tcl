# WINDARTARM — run a NAMED Smalltalk game and capture it.
#
# test_c5_game.tcl hardcodes MandelZoom, which is one of the two `'direct': true`
# games (language.dart:408,410). Direct-framebuffer mode is deferred on this port
# (Win_gpBackbuffer returns null, S6b), so stGpDirectBlit silently no-ops and the
# pane stays black — nothing to do with the ST wiring. This variant lets an
# INDEXED game be picked instead, which is what actually exercises the stGp*
# path end to end.
#
#   tclsh test_stgame_any.tcl ?ws-url? ?GameName?
source [file join [file dirname [info script]] dartui.tcl]
connect [expr {$argc > 0 ? [lindex $argv 0] : "ws://127.0.0.1:8181/ws"}]
::dartui::resolveUi
after 6000

set game [expr {$argc > 1 ? [lindex $argv 1] : "Galaxigans"}]
puts "== ST game: $game =="
puts "  stgame -> [ui stgame $game]"
after 4000
set png [outpng "stgame_$game"]
puts "  gpsnap -> [ui gpsnap $png]"
puts "  file   -> $png"
exit 0
