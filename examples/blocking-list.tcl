##
# An example showing blocking list operations. A number of consumer threads POP
# from a list in blocking mode, while a single producer PUSHes to the list.
#

package require Thread

tcl::tm::path add ..
package require retcl

# Global state
array set g  {
    the_list       mylist _ { Redis KEY for the list we'll be using     }
    message_id     0      _ { Incremental message id produced           }
    run_time       5      _ { Number of seconds to run the simulation   }
    cons_no        5      _ { Number of consumers                       }
    cons_min_wait  0.4    _ { Min seconds a consumer will simulate work }
    cons_max_wait  1.2    _ { Max seconds a consumer will simulate work }
    prod_rate      10     _ { Messages per seconds produced             }
    prod_after_id  0      _ { Producer's [after] id for the next round  }
    done           0      _ { Termination flag                          }
}

proc produce {} {

    retcl create producer

    # Produce a message, then schedule the next one to be procuded. The stop
    # signal is ::g(prod_after_id) being the empty string.
    proc push_date {} {

        # Produce a new message
        set msg "msg_[incr ::g(message_id)]"
        puts "producer  -> $msg"

        # Push the new message at the head of the list ::g(the_list)
        producer LPUSH $::g(the_list) $msg

        # Check whether we should stop
        if {$::g(prod_after_id) eq {}} {
            return
        }

        # Schedule the next message
        set ms [expr {int(1000 / $::g(prod_rate))}]
        set ::g(prod_after_id) [after $ms push_date]
    }

    # Arrange for cleanup after ::g(run_time) seconds. Cleanup is done by
    # cancelling the production of new messages and waiting for consumers to
    # catch up. Finally, the Redis store is cleaned up by DELeting the list
    # indexed by the key ::g(the_list).
    after [expr {int($::g(run_time) * 1000)}] {

        # Stop producing new messages
        after cancel $::g(prod_after_id)
        set ::g(prod_after_id) {}

        # Wait for consumers to catch up
        foreach t $::g(to_join) {
            thread::join $t
        }

        # Cleanup the Redis store
        producer DEL $::g(the_list)

        # Cleanup the Redis client
        producer destroy

        # Signal termination
        incr ::g(done)
    }

    push_date
}

proc consume {} {
    set shared_state [array get ::g]

    # Create a number of consumer threads, each with its own name. Make the
    # global data ::g available to them.
    for {set i 1} {$i <= $::g(cons_no)} {incr i} {
        set t [thread::create -joinable]
        lappend ::g(to_join) $t
        thread::send $t [list set name "consumer$i"]
        thread::send $t [list array set ::g $shared_state]
    }

    # Broadcast the consumer script to all threads
    thread::broadcast {

        # Load retcl package
        tcl::tm::path add ..
        package require retcl

        # Create retcl client
        retcl create r

        # consumer procedure
        proc consume {} {

            # Pop a message from the list
            set max_timeout [expr {int($::g(cons_no) * $::g(prod_rate) / 1000) +  3}]
            set res [r -sync BLPOP $::g(the_list) $max_timeout]

            # Terminate on timeout
            if {$res eq {(nil)}} {
                r destroy
                thread::exit
            }

            # Report the received message
            puts "$::name <- [lindex $res 1]"

            # Simulate data cruncing
            set t [apply {{min max} {
                expr {int(1000 * ($min + rand() * ($max - $min)))}
            }} $::g(cons_min_wait) $::g(cons_max_wait)]
            puts "$::name .. $t ms"
            after $t

            # Schedule next consumption
            after 0 consume
        }
        consume
    }
}

produce
consume
vwait ::g(done)
