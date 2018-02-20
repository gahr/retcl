# vim: ft=tcl ts=4 sw=4 expandtab:

package require Tcl 8.6
package require tcltest 2.3

tcl::tm::path add [file join [file dirname [info script]] .. ]
package require retcl

tcltest::configure {*}$argv -singleproc 1 -testdir [file dir [info script]] \
    -load {
        proc runEvents {} {
            set done 0
            after 50 { set done 1 }
            vwait done
        }
    }

# Check that the server is up and running
if {[catch {socket localhost 6379} fd]} {
    tcltest::testConstraint serverIsRunning 0
} else {
    tcltest::testConstraint serverIsRunning 1
    close $fd
}

tcltest::runAllTests
