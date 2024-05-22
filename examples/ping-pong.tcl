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

proc run {use_tls id} {

    set r [retcl new -noconnect]
    if {$use_tls} {
        $r +tls -cafile   /usr/local/etc/redis/ca.crt \
                -certfile /usr/local/etc/redis/redis.crt \
                -keyfile  /usr/local/etc/redis/redis.key
    }
    $r connect
    $r callback [lindex $::chans $id] [list pingpong $r $id]

    if {$id == 0} {
        $r PUBLISH [lindex $::chans [expr {!$id}]] [lindex $::texts $id]
    }

    $r SUBSCRIBE [lindex $::chans $id]
}

set use_tls [expr {[lindex $::argv 0] eq {--tls}}]
run $use_tls 1
after 1000
run $use_tls 0

vwait forever
