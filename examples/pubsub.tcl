##
# The pub/sub example from README.md
#

tcl::tm::path add ..
package require retcl

proc mycallback {registrationTime type pattern channel message} {
    set elapsed [expr {[clock seconds] - $registrationTime}]
    puts "After $elapsed seconds I got a message of type $type"
    puts "on my registration channel $pattern."
    puts "The actual channel was $channel. The message is $message."
}

retcl create r
r callback chan* [list mycallback [clock seconds]]
r PSUBSCRIBE chan*

after 3000 {
    retcl create r2
    r2 -sync PUBLISH chan1 Hello
}

after 3200 {
    set forever 1
}

vwait forever
r destroy
r2 destroy
