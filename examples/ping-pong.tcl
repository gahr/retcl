##
# Simple ping-pong game using Redis' Pub/Sub paradigm.
#
# Call the script twice, the first time giving the PONG argument, the second
# time giving the PING argument.
#
# $ tclsh ping-pong.tcl PONG &
# $ tclsh ping-pong.tcl PING &
#
# and look at the two clients sending and receiving messages.
#

tcl::tm::path add ..
package require retcl

retcl create r

proc pingpong {channel msg} {
    puts "[clock format [clock seconds]] $msg"
    after 1000
    r UNSUBSCRIBE [lindex $::chans 1]
    r PUBLISH [lindex $::chans 0] $::msg
    r SUBSCRIBE [lindex $::chans 1]
}

set isPing [expr {[lindex $argv 0] eq {PING}}]

set chans [expr {$isPing ? {chan1 chan2} : {chan2 chan1}}]
set msg   [expr {$isPing ? {PING} : {PONG}}]

r callback [lindex $chans 1] pingpong

if {$isPing} {
    r PUBLISH [lindex $chans 0] PING
}
r SUBSCRIBE [lindex $chans 1]

vwait forever
