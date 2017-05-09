##
# The pub/sub example from README.md
#

tcl::tm::path add ..
package require retcl

set forever 0

proc mycallback {obj registrationTime type pattern channel message} {
    set elapsed [expr {[clock seconds] - $registrationTime}]
    puts "After $elapsed seconds I got a message of type $type"
    puts "on my registration channel $pattern."
    puts "The actual channel was $channel. The message is $message."

    if {$type eq {pmessage}} {
        $obj destroy
        set ::forever 1
    }
}

set r [retcl new]
$r callback chan* [list mycallback $r [clock seconds]]
$r PSUBSCRIBE chan*

after 3000 {
    retcl create r2
    r2 -sync PUBLISH chan1 Hello
    r2 destroy
}

vwait forever
