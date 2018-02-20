
retcl
=====

Tcl client library for Redis

Retcl (read *reticle*, not *ridicule*) is an event-driven, object-oriented,
[Redis](http://redis.io) client library targetting the [Tcl](http://tcl.tk)
scripting language.  The library consists of a single
[Tcl Module](http://tcl.tk/man/tcl8.6/TclCmd/tm.htm#M9) file, which makes it
extremely easy to deploy or integrate into existing projects. 

* [retcl](#retcl)
* [Commands identifiers and retrieving results](#commands)
* [The results cache](#cache)
* [Commands pipelining](#pipelining)
* [Publish / Subscribe and callbacks](#pubsub)
* [Handling errors](#errors)
* [Handling reconnections](#reconnect)
* [Reference](#reference)


<a name="retcl"></a>
### Creating a `retcl` command

First off, require the `retcl` package and create an instance of the `retcl`
class:

    % package require retcl
    0.1.0
    % retcl create r
    ::r

Optionally, the constructor accepts the `host` (defaults to localhost) and
`port` (defaults to 6379) arguments:

    % set red [retcl new 192.168.1.1 6379]
    ::oo::Obj43

The `r` command (or the `red` variable in the second example) can now be used
to issue commands to a Redis server.

The lifetime of the `r` command must be managed by the caller. The object must
be explicitely destroyed via a call to `r destroy` (or `$red destroy`) to avoid
resource leaks.

<a name="commands"></a>
### Command identifiers and retrieving results

Redis commands can be invoked as if they were methods of the `retcl` class
instance. Commands are issued asynchronously to the Redis server and return
immediately.

    % r SET myKey {Some value}
    rds:1

The return value is a **command identifier**, such as `rds:1`, which can be
used at any time to retrieve the result of the command.

    % r result rds:1
    OK
    
Obviously, the two can be concatenated.

    % r result [r GET myKey]
    Some value
    
A shortcut to this pattern is provided via the `-sync` switch. This switch
must be used as the first argument, before the Redis command. The above is
thus better rewritten as:

    % r -sync GET myKey
    Some value

The `result` method might wait if no result is available:

    % r CLIENT PAUSE 10000
    rds:3
    % set cmdId [r SET otherKey secondValue]
    rds:4
    % r result $cmdId
    # after ten seconds
     OK

If this is not the wanted behaviour, the `-async` argument might be used. In
this case, if no result is available, the `result` method returns the empty
string:

    % r CLIENT PAUSE 10000
    rds:5
    % set cmdId [r SET otherKey {second value}]
    rds:6
    % r result -async $cmdId
    # immediately

The readyness of a result can be query with the `resultReady` method, which
returns a boolean indicating whether a response for the result is available:

    % r PING
    rds:1
    % r resultReady rds:1
    0
    % set done 0
    % after 100 { set done 1 }
    % vwait done
    % r resultReady rds:1
    1

The type of a result can also be queried with the `resultType` method. If a
result is not ready, the method returns the empty string. Otherwise, it returns
one of `SimpleString`, `Error`, `Integer`, `BulkString`, `Array`.

    % r PING
    rds:1
    % r resultType rds:1
    SimpleString

Another way to handle the result of a command is by using the `-cb cmdPrefix`
switch. In this case, the result identifier is returned immediately as if the
`-sync` switch was not specified and the `cmdPrefix` is arranged to be called
when the result is available. The appended arguments are the **command
identifier**, the result type, and the body.

    % proc mycb {resVar args} {
          upvar $resVar res
          set res $args
      }
    % set res {}
    % r SET a 42
    rds:1
    % r -cb [list mycb [namespace current]::res] GET a
    % vwait res
    % set res
    rds:2 BulkString 42

The asynchronous operation mode can be turned off (and back on) using the pair
of methods `-async` and `+async`. When the asynchronous mode is disabled,
Redis commands are executed and their results returned as soon as they are
available.

    % r -async
    % r GET mykey
    Some value

The `allResults` method allows to inspect the results cache by returning a
dictionary of all available results. The dictionary containes two types of
entries that provide information about the result values and their types.
Values are associated with keys in the form **command identifier**, while
types are associated with keys in the form **command identifier**:type.
values are **results**:

    % r SET key val
    rds:1
    % r GET key
    rds:2
    % r allResults
    rds:1 OK rds1:type SimpleString rds:2 val rds:2:type SimpleString


<a name="cache"></a>
### The results cache

By default, results are kept in a cache and are *not* deleted after having
been retrieved, so it's always possible to query for results of previous
commands with the `result` method (this of course doesn't work for commands
issued with the `-sync` argument, which do not return a command identifier).

It is possible to change this behaviour and have the library delete a result
from the cache as soon as it's retrieved by using the `-keepCache` method:

    % r -keepCache
    
Of course, its companion `+keepCache` is used to enable the results cache:

    % r +keepCache
    
Additionally, results in the cache can be removed selectively by using the
`clearResult` method. This method might be given a specific `cmdId` argument,
in which case it clears that result. If no argument is given, the whole cache
is flushed.  Commands still waiting for a response from the server are *not*
removed.

**Note:** the `clearResult` method does not care whether the client has
retrieved the result, it just checks whether a result has actually been
received from the server.


<a name="pipelining"></a>
### Commands pipelining

`retcl` supports the [pipelining](http://redis.io/topics/pipelining) of Redis
requests. The `pipeline` method accepts a script which is run with pipelining
enabled:

    % r pipeline {
        r INCR i
        r INCR i
        puts "almost done..."
        r INCR i
      }
    almost done...

As shown, the script might contain whatever command is available at the caller
scope. Results can then be retrieved with the `allResults` method:

    % r allResults
    rds:1 1 rds:2 2 rds:3 3


<a name="pubsub"></a>
### Publish / subscribe and callbacks

`retcl` exposes the powerful [publish / subscribe](http://redis.io/topics/pubsub)
semantics in Redis through the `callback` method. The method takes two arguments.

1. a *subscription item*, matching either a `channel` argument to `SUBSCRIBE`
   or a `pattern` argument to `PSUBSCRIBE`
2. a *command prefix*

Upon reception of a message matching `channel` / `pattern`, the *command
prefix* will be appended the message type, *subscription item*, actual
channel, and the message data received and will be invoked in the global
namespace.

    % proc mycallback {registrationTime type pattern channel message} {
         set elapsed [expr {[clock seconds] - $registrationTime}]
         puts "After $elapsed seconds I got a message of type $type"
         puts "on my registration channel $pattern."
         puts "The actual channel was $channel. The message is $message."
     }
    % r callback chan* [list mycallback [clock seconds]]
    % r PSUBSCRIBE chan*
    After 3 seconds I got a message of type psubscribe
    on my registration channel chan*.
    The actual channel was chan*. The message is 1.
    
Some time later somebody sends "Hello!" on chan1.

    After 29 seconds I got a message of type pmessage
    on my registration channel chan*.
   The actual channel was chan1. The message is Hello!.
    
**Note:** as shown in the previous code snipped, registering a callback does
*not* automatically send a (P)SUBSCRIBE request to the Redis server.

To disable a callback, just call `callback` with an empty *command prefix*.
The previously registered *command prefix*, if any, is returned.

    % r callback chan1
    mycallback 1399644509


<a name="errors"></a>
### Handling errors

By default, errors are handled by calling the standard Tcl `error` command.
However, errors might be intercepted by setting up an error handler, using the
method `errorHandler`. The method accepts a *command prefix* which is called
appending to the list of arguments an error message. In the following example,
an error handler is setup to disconnect the client whenever an error occurs:

    % proc errcb {obj msg} {
         puts "ERROR -- $msg"
         $obj disconnect
      }
    % r errorHandler [list errcb r]

The `errorHandler` method might be called without any additional arguments to
restore the default error handler.


<a name="reconnect"><a>
### Handling reconnections

When a command fails to send because of a lost connection, the pipeline is not
flushed. This allows the client to reconnect and resume the pipeline by invoking
any command (like `PING`). This is demonstrated in the following example:

    % r SET a 1
    rds:1
    % r GET a
    rds:2
    % r QUIT ;# Simulate a disconnection
    rds:3
    % r SET a 2
    Disconnected
    while evaluating r set a 2
    % r connect ;# Ok, we're back on track
    % r PING
    rds:5 ;# rds:4 has not been lost, it's tracking the result of the resumed "SET a 2"
    % r GET a
    rds:6
    % r allResults
    rds:1 OK rds:2 1 rds:3 OK rds:4 OK rds:5 PONG rds:6 2
    % r result rds:6
    2 ;# 'a' == 2, as would have been the case without disconnections

It is also possible to manage the connection to the Redis server manually,
possibly constructing the retcl object in disconnected mode and using the
`connect`, `disconnect` and `reconnect` methods. The latter returns
immediately, tries to reconnect to the server for as much as 10 seconds, and
calls the error handler on failure.

    % retcl create r -noconnect
    ::r
    % r connected
    0
    % r connect
    % r disconnect
    % r reconnect

<a name="reference"></a>
### Reference

    rectl create r ?host? ?port?
or
  
    set r [retcl new ?host? ?port?]

or

    set r [rectl new -noconnect]

Create a retcl object. 

The rest of the Reference assumes that an `r` command exists, as created by
`retcl create r`.

    r disconnect
    
Disconnect from the server.

    r connect ?host? ?port?
    
Connect to the server `host` on port `port`.

    r connected
    
Returns 1 if the client is connected, 0 otherwise.

    r reconnect

Returns immediately, try to reconnect for 10 seconds before giving up.

    r errorHandler ?cmdPrefix?

Setup an error handler to be called whenever an error occurs in the library.
If no `cmdPrefix` argumet is given, the default error handler `[error]` is
restored.

    r ?-sync? REDIS COMMAND WORDS
    
Send REDIS COMMAND WORDS over to the Redis server. If the `-sync` argument is
specified, wait until a response is available and return it. Otherwise, return
a ***command identifier***.

    r result ?-async? cmdId
    
Retrieve the result of the command identified by the ***command identifier***
`cmdId`. If the result is not yet available, either wait or return the empty
string if `-async` was specified.

    r resultReady cmdId

Return a boolean indicating whether the result for `cmdId` is ready for
retrieval.

    r resultType cmdId

Retrieve the type of the result `cmdId` or the empty string if `cmdId` is not
ready for retrieval.

    r allResults
    
Retrieve a dictionary where ***command identifiers*** are keys and
***responses*** are values.

    r clearResult ?cmdId?
    
Either remove the result of the command identified by ***command identifier***
`cmdId` from the cache, or flush the whole cache if no `cmdId` is specified.

    r +keepCache
    r -keepCache
    
Switch on or off keeping results in the cache after the client has retrieven
them using the `result` method. By default, the results cache is enabled.

    r +async
    r -async

Switch on or off the asynchronous operation mode. By default, asynchronous
operation is enabled.

    r pipeline script
    
Execute `script` in the caller scope while holding a Redis pipeline. All Redis
commands issued within the `script` are sent over to the server at the end of
the script.

    r callback item ?cmdPrefix?
    
If `cmdPrefix` is specified, setup a command to be called whenever a message
arrives on the subscription item `item`. If no `cmdPrefix` is specified, clear
a previously setup callback on the same `item`. `cmdPrefix` is appended the
following arguments:

1. message type (message, pmessage, subscribe, unsubscribe, ...)
2. subscription item (channel or pattern subscribed / unsubscribed to)
3. actual channel (channel or pattern where the message was sent)
4. body
