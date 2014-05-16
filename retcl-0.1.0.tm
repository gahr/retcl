##
# Copyright (C) 2014 Pietro Cerutti <gahr@gahr.ch>
# 
# Retcltribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Retcltributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
# 2. Retcltributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#/

package require Tcl 8.6
package require TclOO

package provide retcl 0.1.0

catch {retcl destroy}

proc DEBUG {args} {
    puts "$args"
}

oo::class create retcl {

    ##
    # Mapping of RESP data types to symbolic names, see
    # http://redis.io/topics/protocol
    variable typeNames 

    ##
    # Keep a cache of the commands sent and results received. Each command sent
    # to the server is assigned a unique identifier, which can be then used by
    # the user to retrieve the result (see [result] method).  The resultsCache
    # variable is a dictionary where unique identifiers are the keys, with
    # further keys for status, request, and response.  Status is either 0 (not
    # replied) or 1 (replied). New requests are appended at the tail of the
    # list; responses are inserted at the first request with a status 0.
    #
    # (cmd1 {status (0|1) request (COMMAND) response (RESPONSE)})
    #
    variable resultsCache

    ##
    # Read buffer
    variable readBuf

    ##
    # Boolean to indicate whether a result should be kept in the results cache
    # indefinitely (1, default) or automatically removed as soon as it's
    # retrieved by the client (0)
    variable keepCache

    ##
    # An incremental integer to track requests / responses.
    variable cmdIdNumber

    ##
    # The socket used to connect to the server
    variable sock

    ##
    # A dictionary with channels / patterns subscribed to and callbacks.
    # Callbacks are scripts that will be evaluated at the global level.
    variable callbacks

    ##
    # Command prefix to be invoked whenever an error occurs. Defaults to
    # [error].
    variable errorCallback

    ##
    # A list of commands inside a pipeline.
    variable pipeline
    variable isPipelined

    ##
    # Constructor -- connect to a Retcl server.
    constructor {{host 127.0.0.1} {port 6379}} {
        set typeNames {
            +   SimpleString
            -   Error
            :   Integer
            $   BulkString
            *   Array
        }
        set resultsCache [dict create]
        set keepCache 1
        set cmdIdNumber 0
        set sock {}
        set opMode interactive
        set callbacks [dict create]
        set pipeline {}
        set isPipelined 0

        my errorHandler
        my connect $host $port
    }

    ##
    # Destructor -- disconnect.
    destructor {
        catch {close $sock}
    }

    ##
    # Connect to a Retcl server.
    method connect {host port} {
        if {$sock ne {}} {
            my Error "Already connected"
        }

        set sock [socket $host $port]
        #chan configure $sock -blocking 0 -buffering line -encoding binary -translation binary
        chan configure $sock -blocking 0 -translation binary
        chan event $sock readable [list [self object] readEvent]
    }

    ##
    # Disconnect from the Retcl server.
    method disconnect {} {
        if {$sock eq {}} {
            my Error "Not connected"
        }

        # Cleanup the socket
        catch {close $sock}
        set sock {}

        # Cleanup the resultsCache: all requests without a response
        # will be filled with an "Error: disconnected" response.
        foreach cmdId [my FindPendingRequest] {
            dict set resultsCache $cmdId status 1
            dict set resultsCache $cmdId response "Error: disconnected"
        }
    }

    ##
    # Check whether we're currently connected to a Retcl server.
    method connected {} {
        return [expr {$sock ne {}}]
    }

    ##
    # Setup and error callback or restore the default one ([error]). The
    # cmdPrefix is passed an additional argument containing the error message.
    method errorHandler {{cmdPrefix {}}} {
        if {$cmdPrefix eq {}} {
            set errorCallback error
        } else {
            set errorCallback $cmdPrefix
        }
    }

    ##
    # Get the result of a previously issued command. If the response has not
    # yet arrived, the command waits until it's available, or returns the
    # empty string if -async is given.
    method result {args} {

        switch [llength $args] {
            1 {
                set async 0
                set cmdId $args
            }
            2 {
                if {[lindex $args 0] ne {-async}} {
                    my Error {wrong # args: should be "result ?-async? cmdId"}
                }
                set async 1
                set cmdId [lindex $args 1]
            }
            default {
                my Error {wrong # args: should be "result ?-async? cmdId"}
            }
        }

        if {![dict exists $resultsCache $cmdId]} {
            my Error "Invalid command id: $cmdId"
        }

        while {1} {
            if {[dict get $resultsCache $cmdId status] == 1} {
                set res [dict get $resultsCache $cmdId response]
                if {[string is false $keepCache]} {
                    dict unset resultsCache $cmdId
                }
                return $res
            }

            if {$async} {
                return {}
            }
            vwait [self namespace]::resultsCache
        }
    }

    ##
    # Return a dictionary of the reuslts in form
    # of cmdId =>  result.
    method allResults {} {

        set res [dict create]

        dict for {cmdId state} $resultsCache {
            dict with state {
                if {$status == 1} {
                    dict set res $cmdId $response
                }
            }
        }

        return $res
    }

    ##
    # Clear results from the cache.
    method clearResult {{clearCmdId {}}} {

        if {$clearCmdId eq {}} {
            set resultsCache [dict filter $resultsCache script {cmdId cmdStatus} {
                expr {![dict get $resultsCache $cmdId status]}
            }]
        } else {
            set resultsCache [dict filter $resultsCache script {cmdId cmdStatus} {
                expr {$clearCmdId ne $cmdId || ![dict get $resultsCache $cmdId status]}
            }]
        }
        return {}
    }

    ##
    # Change the keep cache mode. By default, it turns cache keeping on.
    method keepCache {{keep {true}}} {
        if {![string is boolean $keep]} {
            my Error "setKeepCache: invalid argument, must be true or false."
        }
        set keepCache $keep
    }

    ##
    # Execute all Redis commands inside a script within a single pipeline.
    method pipeline {script} {

        my LockPipeline
        uplevel [list eval $script]
        my ReleasePipeline
    }

    ##
    # Set a callback to be called when a message is pushed from the server
    # because of a PUBLISH command issued by some other client. Item can be a
    # channel (see SUBSCRIBE) or a pattern (see PSUBSCRIBE). An empty callback
    # removes the callback previously set on the same item, if any. This
    # method returns the previously set callback, if any.  This method does
    # not automatically send a (P)SUBSCRIBE message to the Redis server.
    #
    # See http://redis.io/topics/pubsub.
    method callback {item {callback {}}} {
        try {
            dict get $callbacks $item
        } on error {} {
            set prev {}
        } on ok prev {}

        if {$callback eq {}} {
            dict unset callbacks $item
        } else {
            dict set callbacks $item $callback
        }

        return $prev
    }

    ##
    # The unknown handler handles unknown methods as Redis commands
    method unknown {args} {
        set cmdId "rds:[incr cmdIdNumber]"
        dict set resultsCache $cmdId status 0

        if {[lindex $args 0] eq {-sync}} {
            # Send synchronously and return the result, when available
            my Send [lrange $args 1 end]
            set res [my result $cmdId]
            r clearResult $cmdId
            return $res
        } else {
            # Send asynchronously and return the cmdId
            my Send $args
            return $cmdId
        }
    }


    ##########################################################################
    # The following methods are private to the retcl library and not intended
    # to be used by consumers.
    ##########################################################################

    ##
    # Read a BulkString from the server. Might be partial.
    method GetBulkString {len} {
        set buf [read $sock $toRead]

        if {[string length $buf] == $toRead} {
            gets $sock ;# Consumje the final newline
        }

        return $buf
    }

    ##
    # Handle a read event from the socket.
    method readEvent {} {
        if {[chan eof $sock]} {
            my disconnect
            my Error "Connection lost"
        }

        append readBuf [read $sock]

        set idx 0
        while {$idx < [string length $readBuf]} {
            set result [my ParseBuf $readBuf $idx]
            if {$result eq {}} {
                break
            }

            lassign $result idx type data
            my HandleResult $type $data
        }

        if {$idx != 0} {
            set readBuf [string range $readBuf $idx end]
        }
    }

    ##
    # Parse the read buffer. starting at index startIdx. Returns a list
    # consisting of:
    #
    # idx   : index up to which the buffer has been parsed
    # type  : type of the object found
    # value : value of the object
    #
    # or the empty string if no complete object could be parsed.
    method ParseBuf {buffer startIdx} {

        if {![string length $buffer]} {
            return
        }

        set respCode [string index $buffer $startIdx]
        set respType [my TypeName $respCode]

        switch -- $respCode {

            "+" -
            "-" -
            ":" {
                # Simple Strings, Errors, and Integers are handled
                # straight forward
                lassign [my ParseLine $buffer $startIdx+1] eol line
                if {$eol == -1} {
                    return
                }
                return [list [expr {$eol+2}] $respType $line]
            }

            "$" {
                # Bulk Strings, the number of characters is specified in the
                # first line. We handle Null values and empty strings right
                # away.
                lassign [my ParseLine $buffer $startIdx+1] eol bulkLen
                if {$eol == -1} {
                    return
                }

                # Null Bulk String
                if {$bulkLen eq {-1}} {
                    return [list [expr {$eol+2}] $respType (nil)]
                }
                
                # Empty Bulk String
                if {$bulkLen eq {0}} {
                    return [list [expr {$eol+4}] $respType {}]
                }

                # Non-empty Bulk String
                incr eol 2
                set endIdx [expr {$eol+$bulkLen-1}]
                if {[string length $buffer] < $endIdx} {
                    # Need to wait for more input
                    return
                }
                return [list [expr {$endIdx+3}] $respType [string range $buffer $eol $endIdx]]
            }

            "*" {
                # Arrays, the number of elements is specified in the first
                # line.
                lassign [my ParseLine $buffer $startIdx+1] eol arrLen
                if {$eol == -1} {
                    return
                }

                # Null Array
                if {$arrLen eq {-1}} {
                    return [list [expr {$eol+2}] $respType (nil)]
                } 
                
                # Empty array
                if {$arrLen eq {0}} {
                    return [list [expr {$eol+2}] $respType {}]
                }

                # Non-empty Array
                set idx [expr {$eol+2}]
                set elems [list]
                while {$arrLen} {
                    set elem [my ParseBuf $buffer $idx]
                    if {$elem eq {}} {
                        return {}
                    }

                    lappend elems [lindex $elem 2]
                    set idx [lindex $elem 0]
                    incr arrLen -1
                }

                return [list $idx $respType $elems]
            }

            default {
                puts "Unhandled type: $buffer"
            }
        }
    }

    method ParseLine {buffer startIdx} {
        set eol [string first "\r" $buffer $startIdx]
        if {$eol == -1} {
            return -1
        }
        set line [string range $buffer $startIdx $eol-1]
        return [list $eol $line]
    }


    ##
    # Handle a complete result read from the server.
    method HandleResult {type body} {
        # If the response is a message (pub/sub), deliver it to the
        # relevant callback, if any.
        if {$type eq {Array} && [lindex $body 0] eq {message}} {
            lassign $body _ item data
            try {
                dict get $callbacks $item
            } on error {} {
                # no callback defined, just ignore this message
                return
            } on ok callback {
                namespace eval :: $callback $item $data
            } finally {
                return
            }
        }

        #
        # If we get here, the response wasn't a pushed message
        #

        # Look for the first command without a result
        set cmdIds [my FindPendingRequest]
        if {$cmdIds eq {}} {
            # All requests already have a response, something went bad
            my Error "No request found for response $body"
        }
        set cmdId [lindex $cmdIds 0]
        dict set resultsCache $cmdId response $body
        dict set resultsCache $cmdId status 1
    }

    ##
    # Get a return type string by its byte.
    method TypeName {byte} {
        try {
            return [dict get $typeNames $byte]
        } on error message {
            my Error "Invalid type byte: $byte"
        }
    }

    ##
    # Build the RESP representation of a command.
    method BuildResp {args} {
        set msg "*[llength $args]\r\n"
        foreach word $args {
            append msg "\$[string length $word]\r\n$word\r\n"
        }
        set msg
    }

    ##
    # Send command(s) over to the Redis server. Each
    # argument is a list of words composing the command.
    method Send {args} {
        foreach cmd $args {
            append pipeline "[my BuildResp {*}$cmd]\r\n"
        }

        if {!$isPipelined} {
            my Flush
        }
    }

    ## 
    # Return a list of responses from the server. A maximum number
    # of results might be specified. This is mostly used internally
    # to recursively call [my Recv] to receive Array elements.
    method Recv {{includeTypes 1} {maxResults -1}} {
        if {$maxResults == 0} {
            return {}
        }

        set result [list]

        while {[gets $sock line] > 0} {
            set respCode [string index $line 0]
            set respName [my TypeName $respCode]
            set respData [string range $line 1 end]

            switch $respCode {
                + -
                - -
                : {
                    # Simple Strings, Errors, and Integers are handled
                    # straight forward
                    if {$includeTypes} {
                        lappend result [list $respName $respData]
                    } else {
                        lappend result $respData
                    }
                }
                $ {
                    # Bulk Strings, read the number of char specified in the
                    # first line.
                    # If it's -1, it's a (nil).
                    if {$respData eq {-1}} {
                        if {$includeTypes} {
                            lappend result [list BulkString (nil)]
                        } else {
                            lappend result (nil)
                        }
                    } else {
                        set bulk [read $sock $respData]
                        if {$includeTypes} {
                            lappend result [list $respName $bulk]
                        } else {
                            lappend result $bulk
                        }
                        gets $sock ;# consume the final end of line
                    }
                }
                * {
                    # Arrays, call [my Recv] recursively to get the number of
                    # elements
                    if {$includeTypes} {
                        lappend result [list Array [my Recv 0 $respData]]
                    } else {
                        lappend result [my Recv 0 $respData]
                    }
                }
            }

            if {$maxResults != -1 && [incr maxResults -1] == 0} {
                break
            }
        }

        return $result
    }

    ##
    # Return a list of pending command ids.
    method FindPendingRequest {} {
        set allPending [list]

        foreach cmdId [dict keys $resultsCache] {
            if {[dict get $resultsCache $cmdId status] == 0} {
                lappend allPending $cmdId
            }
        }

        return $allPending
    }

    ##
    # Lock the pipeline. Redis commands are buffered and only sent to the
    # server when ReleasePipeline is called.
    method LockPipeline {} {
        if {$isPipelined} {
            my Error "Cannot nest pipelines"
        }
        set isPipelined 1
    }

    ##
    # Release a pipeline and flush all buffered commands.
    method ReleasePipeline {} {
        if {!$isPipelined} {
            my Error "No pipeline to release"
        }
        my Flush
    }

    ##
    # Flush the output buffer
    method Flush {} {
        if {[catch {puts -nonewline $sock $pipeline} err]} {
            my Error $err
        }
        chan flush $sock

        set isPipelined 0
        set pipeline [list]
    }

    ##
    # Error handler.
    # TODO -- let the client specify a custom error handler.
    method Error {msg} {
        {*}$errorCallback $msg
    }
}
