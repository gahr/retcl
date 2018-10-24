##
# An example using the new STREAMS feature of Redis 5. A producer pushes data
# onto a stream at fixed intervals. A consumer fetches data in chunks, works
# for a random period of time, then checks back and reads another chunk.
#
# See https://redis.io/topics/streams-intro.
#

tcl::tm::path add ..
package require retcl

# Global state
array set g {
    the_stream      mystream _ { Redis KEY for the stream we'll be using    }
    run_time        5        _ { Number of seconds to run the simulation    }
    prod_wait       0.15     _ { Number of seconds between productions      }
    prod_after_id   0        _ { Producer's [after] id for the next round   }
    cons_number     4        _ { Number of consumers                        }
    cons_chunk_size 3        _ { Number of messages to read at once         }
    cons_min_wait   0.4      _ { Minimum number of seconds between consumes }
    cons_max_wait   1.2      _ { Maximum number of seconds between consumes }
    produced        {}       _ { List of tuples produced                    }
    done            {}       _ { Termination flags list                     }
}

proc produce {} {
    retcl create producer

    proc push_data {} {
        # Produce a tuple with hour, minute, second, and millisecond
        set now  [clock milliseconds]
        set ms [expr {$now % 1000}]
        set now [expr {$now / 1000}]
        set h [clock format $now -format %H]
        set m [clock format $now -format %M]
        set s [clock format $now -format %S]
        set tuple [list h $h m $m s $s ms $ms]

        # Add it to the list of produced tuples
        lappend ::g(produced) $tuple

        # Stream it
        puts "producer --> $tuple"
        producer XADD $::g(the_stream) * {*}$tuple

        # Schedule the next production
        set ms [expr {int(1000 * $::g(prod_wait))}]
        set ::g(prod_after_id) [after $ms push_data]
    }

    push_data

    # Schedule the termination
    after [expr {int($::g(run_time) * 1000)}] {
        after cancel $::g(prod_after_id)
        producer destroy
    }
}

proc consume {wid} {
    retcl create consumer_$wid

    # Helper to produce a bounded random number of milliseconds
    proc random_wait {} {
        apply {{min max} {
            expr {int(1000 * ($min + rand() * ($max - $min)))}
        }} $::g(cons_min_wait) $::g(cons_max_wait)
    }

    proc read_chunk {wid last_id} {
        # Read 
        set res [consumer_$wid -sync \
            XRANGE $::g(the_stream) $last_id + COUNT $::g(cons_chunk_size)]

        if {$res eq {}} {
            # Everything was consumed
            puts "consumer_$wid done"
            lappend ::g(done) 1

            # I am the last one, cleanup Redis
            if {[expr {[llength $::g(done)] == $::g(cons_number)}]} {
                consumer_$wid DEL $::g(the_stream)
            }

            # Cleanup myself
            consumer_$wid destroy
            return
        }

        # Report the result
        puts "consumer_$wid <-- $res"
        foreach tuple $res {
            lappend ::g(consumed_$wid) [lindex $tuple 1]
        }

        # Compute the next id to start at, by incrementing the milliseconds of
        # the current id
        regexp {(\d+)-(\d+)} $[lindex [lindex $res end] 0] _ msec seq
        set last_id "$msec-[incr $seq]"


        # Schedule the next read
        after [random_wait] [list read_chunk $wid $last_id]
    }

    after [random_wait] [list read_chunk $wid -]
}

produce
for {set wid 0} {$wid < $::g(cons_number)} {incr wid} {
    consume $wid
}

# Wait for everybody to be done
while {[llength $::g(done)] ne $::g(cons_number)} {
    vwait ::g(done)
}

# Check that all consumers have received all the messages
for {set wid 0} {$wid < $::g(cons_number)} {incr wid} {
    if {$::g(produced) ne $::g(consumed_$wid)} {
        puts "Ooops..."
        puts "produced: $::g(produced)"
        puts "consumed: $::g(consumed_$wid)"
    }
}
