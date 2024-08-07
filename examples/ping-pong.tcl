##
# Simple ping-pong game using Redis' Pub/Sub paradigm. Look at PING and PONG
# messages go around over the chon and chin channels, respectively.
#
tcl::tm::path add ..
package require retcl

set chans {chin chon}
set texts {PING PONG}

proc pingpong {r id type pattern channel msg} {
    if {$type ne {message}} {
        return
    }
    puts "[clock format [clock seconds]] $channel/$msg"

    after 1000
    $r UNSUBSCRIBE [lindex $::chans $id]
    $r PUBLISH [lindex $::chans [expr {!$id}]] [lindex $::texts $id]
    $r SUBSCRIBE [lindex $::chans $id]
}

proc run {opts id} {

    set r [retcl new {*}$opts]
    $r callback [lindex $::chans $id] [list pingpong $r $id]

    if {$id == 0} {
        $r PUBLISH [lindex $::chans [expr {!$id}]] [lindex $::texts $id]
    }

    $r SUBSCRIBE [lindex $::chans $id]
}

set opts [expr {[lindex $::argv 0] eq {--tls} ? {+tls} : {}}]
run $opts 1
after 1000
run $opts 0

vwait forever
