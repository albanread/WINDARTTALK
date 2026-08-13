# WINDARTARM — run a NAMED Smalltalk game and capture it.
#
# Written when direct-framebuffer mode was still deferred and test_c5_game.tcl's
# hardcoded MandelZoom could only capture black. Win_gpBackbuffer is implemented
# now (UMA Tier 2), so BOTH kinds work here: indexed games (Galaxigans) exercise
# the stGp* draw path, and `'direct': true` games (MandelZoom, MandelVM —
# language.dart:408,410) exercise directBlit into the mapped backbuffer.
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
