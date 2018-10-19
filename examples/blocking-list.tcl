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
    # Produce the current date every 5 seconds
    retcl create producer
    proc push_date {} {
        set msg "msg_[incr ::g(message_id)]"
        puts "producer  -> $msg"
        producer LPUSH $::g(the_list) $msg
        if {$::g(prod_after_id) ne {}} {
            set ::g(prod_after_id) \
                [after [expr {int(1000 / $::g(prod_rate))}] push_date]
        }
    }

    after [expr {int($::g(run_time) * 1000)}] {
        after cancel $::g(prod_after_id)
        set ::g(prod_after_id) {}
        foreach t $::g(to_join) {
            thread::join $t
        }
        producer DEL $::g(the_list)
        producer destroy
        incr ::g(done)
    }

    push_date
}

proc consume {} {
    set shared_state [array get ::g]
    for {set i 1} {$i <= $::g(cons_no)} {incr i} {
        set t [thread::create -joinable]
        lappend ::g(to_join) $t
        thread::send $t [list set name "consumer$i"]
        thread::send $t [list array set ::g $shared_state]
    }
    thread::broadcast {
        # Load retcl package
        tcl::tm::path add ..
        package require retcl

        proc rand_range {min max} {
            expr {int(1000 * ($min + rand() * ($max - $min)))}
        }

        # Create retcl client
        retcl create r

        # consumer procedure
        proc consume {i} {
            set max_timeout [expr {int($::g(cons_no) * $::g(prod_rate) / 1000) +  3}]
            set res [r -sync BLPOP $::g(the_list) $max_timeout]
            if {$res eq {(nil)}} {
                r destroy
                thread::exit
            }
            puts "$::name <- [lindex $res 1]"
            # Simulate data cruncing
            set t [rand_range $::g(cons_min_wait) $::g(cons_max_wait)]
            puts "$::name .. $t ms"
            after $t
            after 0 [list consume [incr i]]
        }
        consume 0
    }
}

produce
consume
vwait ::g(done)
