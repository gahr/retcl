##
# Copyright (C) 2014-2026 Pietro Cerutti <gahr@gahr.ch>
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright
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
#

package require Tcl 8.6 9.0
package require TclOO

package provide retcl 0.7.1

catch {retcl destroy}

namespace eval ::retcl {

    ##
    # Default Redis endpoint address
    variable defaultHost 127.0.0.1

    ##
    # Default Redis endpoint port
    variable defaultPort 6379

    ##
    # Prefix for command ids
    variable cmdIdPrefix "rds:"

    ##
    # Mapping of RESP data types to symbolic names.
    # See http://redis.io/topics/protocol.
    variable typeNames {
        +   SimpleString
        -   Error
        :   Integer
        $   BulkString
        *   Array
    }

    ##
    # Commands (outgoing) related to pub-sub
    variable pubSubCommands [list psubscribe punsubscribe subscribe unsubscribe]

    ##
    # Messages (incoming) related to pub-sub
    variable pubSubMessages [concat message pmessage $pubSubCommands]
}

oo::class create retcl {

    ##
    # Keep a cache of the commands sent and results received. Each command sent
    # to the server is assigned a unique identifier, which can be then used by
    # the user to retrieve the result (see [result] method).  The resultsCache
    # variable is a dictionary where unique identifiers are the keys, with
    # further keys for a possible callback, status, type, and response.  A
    # callback is defined by the -cb cmdPrefix argument to any command and is
    # invoked whenever a result is made available. Status is either 0 (not
    # replied) or 1 (replied). Type is one of the values of the typeNames list.
    # New commands are appended at the tail of the list; responses are inserted
    # at the first command with a status 0.
    #
    # rds:1 {
    #    status   (0|1)
    #    callback (cmdPrefix)
    #    type     (SimpleString|...)
    #    response (RESPONSE)
    # }
    variable resultsCache

    ##
    # Read buffer. This is appended to incrementally to handle partial reads
    # from the server.
    variable readBuf

    ##
    # Boolean to indicate whether a result should be kept in the results cache
    # indefinitely or automatically removed as soon as it's retrieved by the
    # client(0) (see +keepCache and -keepCache methods)
    variable keepCache

    ##
    # Boolean to indicate whether commands are to be sent out in an
    # asynchronous way (see +async and -async methods).
    variable async

    ##
    # This variable contains the arguments passed to the +tls method, or 0 if
    # TLS is disabled. TLS requires the tcltls extension available at
    # https://core.tcl-lang.org/tcltls.
    variable tls

    ##
    # Boolean to indicate whether data to be sent to Redis is checked for
    # characters above 0xFF. The socket is binary, so non-binary strings will
    # cause a write error and leave the socket in an inconsistent state,
    # forcing us to close the connection.
    # This flag forces a check and triggers an error earlier, before the data
    # hits the socket, which might be more desirable than closing the
    # connection.
    variable binaryCheck

    ##
    # An incremental integer to track requests / responses.
    variable cmdIdNumber

    ##
    # The Redis server host and port, as used in the constructor or in the
    # connect method.
    variable host
    variable port

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
    # After Id for the period event that checks whether the connection is still
    # valid.
    variable checkEventId

    ##
    # After Id for the automatic reconnection.
    variable reconnectEventId

    ##
    # Simple sentinel that's set whenever there's activity
    variable activity

    ##
    # Constructor -- connect to a Retcl server.
    constructor {args} {
        set resultsCache [dict create]
        set keepCache 1
        set async 1
        set tls 0
        set binaryCheck 0
        set cmdIdNumber 0
        set host $::retcl::defaultHost
        set port $::retcl::defaultPort
        set sock {}
        set callbacks [dict create]
        set errorCallback error
        set pipeline {}
        set isPipelined 0
        set checkEventId {}
        set reconnectEventId {}
        set activity 0

        set optRegex {^[+-]}
        # gather all methods that can be used as options
        set methods [lsort [lmap m [info object methods [self object] -all] {
            if {![regexp $optRegex $m]} {
                continue
            }
            set m
        }]]
        
        # apply all options and re-gather non-option arguments
        set args [lmap a $args {
            set opt [lindex $a 0]
            if {$opt in $methods} {
                my $opt {*}[lrange $a 1 end]
                continue
            } elseif {[regexp $optRegex $a] && $a ne {-noconnect}} {
                my Error "bad option \"$opt\": must be any of -noconnect $methods"
            }
            set a
        }]

        switch -- [llength $args] {
            0 {
                # connect to default host and port
                my connect
            }
            1 {
                if {[lindex $args 0] eq {-noconnect}} {
                    # disconnected mode - nothing to do
                } else {
                    my Error "bad option \"[lindex $args 0]\": must be -noconnect"
                }
            }
            2 {
                lassign $args host port
                my connect
            }
            default {
                my Error "wrong # args: must be \"?host port?\" or \"-noconnect\""
            }
        }
    }

    ##
    # Destructor -- disconnect.
    destructor {
        my disconnect
    }

    ##
    # Connect to a Redis server.
    method connect {{a_host {}} {a_port {}}} {
        if {$sock ne {}} {
            my Error "Already connected"
        }

        if {$a_host ne {}} {
            set host $a_host
        }
        if {$a_port ne {}} {
            set port $a_port
        }

        if {$tls ne {0}} {
            if {[catch {package require tls} res]} {
                my Error "Cannot load TLS extension: $res"
            }
            set socket_cmd [concat tls::socket [expr {$tls eq {1} ? "" : $tls}]]
        } else {
            set socket_cmd [list socket]

        }
        if {[catch {{*}$socket_cmd $host $port} res]} {
            my Error "Cannot connect: $res"
        }

        set sock $res
        chan configure $sock -blocking 0 -translation binary
        chan event $sock readable [list [self object] readEvent]
        set checkEventId [after 500 [list [self object] checkConnection]]
        return {}
    }

    ##
    # Reconnect to the Redis server. This tries to reconnect waiting up to 10
    # seconds in total.
    method reconnect {{i 0}} {
        my disconnect
        set maxAttempts 20
        set waitMillis 500
        if {$i == $maxAttempts} {
            my Error {Could not reconnect to Redis server}
        }
        set saveErrorCallback $errorCallback
        my errorHandler {}
        set err [catch {my connect $host $port} msg]
        my errorHandler $saveErrorCallback
        if {$err} {
            set reconnectEventId \
                [after $waitMillis [list [self object] reconnect [incr i]]]
        }
        return {}
    }

    ##
    # Periodically check whether a connection has been interrupted.
    method checkConnection {} {
        if {$sock ne {} && ![catch {chan eof $sock} err] && !$err} {
            set checkEventId [after 500 [list [self object] checkConnection]]
        } else {
            my disconnect
            set activity 1
        }
    }

    ##
    # Check whether we're currently connected to a Retcl server.
    method connected {} {
        expr {$sock ne {}}
    }

    ##
    # Disconnect from the Redis server.
    method disconnect {} {
        catch {close $sock}
        set sock {}
        after cancel $checkEventId
        after cancel $reconnectEventId
        my clearResult pending
    }

    ##
    # Turn on asynchronous operation
    method +async {} {
        set async 1
    }
    export +async

    ##
    # Turn off asynchronous operation.
    method -async {} {
        set async 0
    }
    export -async

    ##
    # Query the current asynchronous operation mode.
    method ?async {} {
        set async
    }
    export ?async

    ##
    # Turn on TLS connections. If args is specified, it will be passed to
    # tls::socket on connection.
    method +tls {{args 1}} {
        set tls $args
        return 1
    }
    export +tls

    ##
    # Turn off TLS connections.
    method -tls {} {
        set tls 0
    }
    export -tls

    ##
    # Query the current TLS connection mode.
    method ?tls {} {
        expr {$tls ne {0}}
    }
    export ?tls

    ##
    # Turn on keeping results in the cache.
    method +keepCache {} {
        set keepCache 1
    }
    export +keepCache

    ##
    # Turn off keeping results in the cache.
    method -keepCache {} {
        set keepCache 0
    }
    export -keepCache

    ##
    # Query the current cache keeping mode.
    method ?keepCache {} {
        set keepCache
    }
    export ?keepCache

    ##
    # Turn on binary checks.
    method +binaryCheck {} {
        set binaryCheck 1
    }
    export +binaryCheck

    ##
    # Turn off binary checks.
    method -binaryCheck {} {
        set binaryCheck 0
    }
    export -binaryCheck

    ##
    # Query the current binary check mode.
    method ?binaryCheck {} {
        set binaryCheck
    }
    export ?binaryCheck

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
    # yet arrived, the command waits until it's available, or returns the empty
    # string if -async is given.
    method result {args} {

        switch -- [llength $args] {
            1 {
                set asyncArg 0
                set cmdId $args
            }
            2 {
                if {[lindex $args 0] ne {-async}} {
                    my Error {wrong # args: should be "result ?-async? cmdId"}
                }
                set asyncArg 1
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
                if {!$keepCache} {
                    dict unset resultsCache $cmdId
                }
                return $res
            }

            if {$asyncArg} {
                return {}
            }

            vwait [self namespace]::activity

            if {![my connected]} {
                my Error {Disconnected}
            }
        }
    }

    ##
    # Check whether a result is ready for retrieval.
    method resultReady {cmdId} {
        if {![dict exists $resultsCache $cmdId]} {
            my Error "Invalid command id: $cmdId"
        }
        dict get $resultsCache $cmdId status
    }

    ##
    # Retrieve the type of a result, or the empty string if the result is not
    # ready.
    method resultType {cmdId} {
        if {[catch {dict get $resultsCache $cmdId type} res]} {
            set res {}
        }
        set res
    }

    ##
    # Return a dictionary of the reuslts in form of cmdId => result.
    method allResults {} {

        set res [dict create]

        dict for {cmdId state} $resultsCache {
            dict with state {
                if {$status == 1} {
                    dict set res $cmdId $response
                    dict set res $cmdId:type $type
                }
            }
        }

        return $res
    }

    ##
    # Clear results from the cache.
    method clearResult {{clearCmdId {}}} {
        switch -glob -- $clearCmdId {
            {} {
                set resultsCache [dict filter $resultsCache script {cmdId _} {
                    expr {![dict get $resultsCache $cmdId status]}
                }]
            }
            pending {
                set resultsCache [dict filter $resultsCache script {cmdId _} {
                    dict get $resultsCache $cmdId status
                }]
            }
            default {
                set resultsCache [dict filter $resultsCache script {cmdId _} {
                    expr {$clearCmdId ne $cmdId ||
                          ![dict get $resultsCache $cmdId status]}
                }]
            }
        }
        return {}
    }

    ##
    # Execute all Redis commands inside a script within a single pipeline.
    method pipeline {script} {

        if {!$async} {
            my Error "pipelining is only supported in async mode"
        }

        my LockPipeline
        try {
            uplevel [list eval $script]
        } on error msg {
            my Error $msg
        } finally {
            if {[catch {my ReleasePipeline} err]} {
                my Error $err
            }
        }
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

        if {![llength $args]} {
            return
        }

        set sendAsync $async
        set callback {}

        switch [lindex $args 0] {
            {-sync} {
                if {$isPipelined} {
                    my Error "sync mode is not supported in a pipeline"
                }
                # Send synchronously and return the result, when available
                set sendAsync 0
                set args [lrange $args 1 end]
            }
            {-cb} {
                # Be notified via a callback
                set callback [lindex $args 1]
                set args [lrange $args 2 end]
            }
        }

        if {![llength $args]} {
            return
        }

        if {[catch {my Send $args} err]} {
            my Error $err
        }

        if {[string tolower [lindex $args 0]] in $::retcl::pubSubCommands} {
            # These messages are part of the Pub/Sub protocol; we don't expect
            # a response.
            set cmdId {}
        } else {
            set cmdId "$::retcl::cmdIdPrefix[incr cmdIdNumber]"
            dict set resultsCache $cmdId status 0
            dict set resultsCache $cmdId callback $callback
        }

        if {$sendAsync || $callback ne {} || $cmdId eq {}} {
            # Asynchronous send, return the command identifier
            return $cmdId
        } else {
            # Synchronous send, wait for the result and return it
            set res [my result $cmdId]
            my clearResult $cmdId
            return $res
        }
    }

    ##########################################################################
    # The following methods are private to the retcl library and not intended
    # to be used by consumers.
    ##########################################################################

    ##
    # Handle a read event from the socket.
    #
    # Must be public (starts with a lower case letter) because it's used in the
    # event loop.
    method readEvent {} {
        set activity 1
        if {[chan eof $sock]} {
            my disconnect
            return
        }

        append readBuf [read $sock]

        set idx 0
        while {$idx < [string length $readBuf]} {
            set result [my ParseBuf $readBuf $idx]
            if {$result eq {}} {
                break
            }

            lassign $result idx type data
            if {[catch {my HandleResult $type $data} err]} {
                my Error $err
            }
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
                if {[string length $buffer] < [expr {$endIdx+2}]} {
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
        # We have to handle two distinct cases:
        # - a pushed message (can be message, subscribe, or ubsubscribe)
        # - a command response
        #
        # The first case is handled by forwarding the message contents to a
        # registered callback, if any exists. For message types we're done. For
        # subscribe / unsubscribe types we also have to locate the
        # corresponding request and clear it.
        #
        # The second case is handled by locating the corresponding request and
        # filling in the result.

        # If the response is a pushed message
        if {$type eq {Array} && [lindex $body 0] in $::retcl::pubSubMessages} {
            if {[lindex $body 0] eq {pmessage}} {
                lassign $body type pattern item data
            } else {
                lassign $body type item data
                set pattern $item
            }
            try {
                dict get $callbacks $pattern
            } on ok callback {
                namespace eval :: [list {*}$callback $type $pattern $item $data]
            } finally {
                # It's a subscribe / unsubscribe. Clear the corresponding
                # request, if any.
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
            error "No request found for response $body"
        }
        set cmdId [lindex $cmdIds 0]
        set cb [dict get $resultsCache $cmdId callback]
        if {$cb ne {}} {
            {*}$cb $cmdId $type $body
            dict unset resultsCache $cmdId
        } else {
            dict set resultsCache $cmdId type $type
            dict set resultsCache $cmdId response $body
            dict set resultsCache $cmdId status 1
        }
    }

    ##
    # Get a return type string by its byte.
    method TypeName {byte} {
        if {[catch {dict get $::retcl::typeNames $byte} name]} {
            error "Invalid type byte: $byte"
        }
        set name
    }

    ##
    # Build the RESP representation of a command.
    method BuildResp {args} {
        set msg "*[llength $args]\r\n"
        foreach word $args {
            if {$binaryCheck && [regexp {[^\x00-\xff]} $word]} {
                error "non-binary data detected"
            }
            append msg "\$[string length $word]\r\n$word\r\n"
        }
        set msg
    }

    ##
    # Send command(s) over to the Redis server. Each
    # argument is a list of words composing the command.
    method Send {args} {
        if {[llength $args] > 1} {
            error "Too many args: $args"
        }
        foreach cmd $args {
            append pipeline "[my BuildResp {*}$cmd]\r\n"
        }

        if {!$isPipelined} {
            my Flush
        }
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

        set allPending
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
        set buf $pipeline
        set isPipelined 0
        set pipeline [list]

        if {![my connected]} {
            # nothing can answer the commands still waiting for a result:
            # they were queued while disconnected and are dropped with the
            # buffer
            my clearResult pending
            error Disconnected
        }

        if {[catch {puts -nonewline $sock $buf} err]} {
            my disconnect
            error $err
        }
        chan flush $sock
    }

    ##
    # Error handler.
    method Error {msg} {
        {*}$errorCallback $msg
        return -level 2
    }
}

# vim: set ft=tcl ts=4 expandtab:
