retcl
=====

Tcl client library for Redis

Retcl (read *reticle*, not *ridicule*) is an event-driven, object-oriented, <a href="http://redis.io">Redis</a> client library targetting the <a href="http://tcl.tk">Tcl</a> scripting language.
The library consists of a single <a href="http://tcl.tk/man/tcl8.6/TclCmd/tm.htm#M9">Tcl Module</a> file, which makes it extremely easy to deploy or integrate into existing projects. 

* [retcl] (#retcl)
* [Commands identifiers and retrieving results] (#commands)
* [The results cache] (#cache)
* [Commands pipelining] (#pipelining)
* [Publish / Subscribe and callbacks] (#pubsub)
* [Handling errors] (#errors)
* [Reference] (#reference)

<a name="retcl"></a>
### Creating a `retcl` command

First off, require the `retcl` package and create an instance of the `retcl`
class:

    % package require retcl
    0.1.0
    % retcl create r
    ::r

Optionally, the constructor accepts the `host` (defaults to localhost) and `port`
(defaults to 6379) arguments:

    % set red [retcl new 192.168.1.1 6379]
    ::oo::Obj43

The `r` command (or the `red` variable in the second example) can now be used to issue commands to a Redis server.


<a name="commands"></a>
### Command identifiers and retrieving results

Redis commands can be invoked as if they were methods of the `retcl` class instance. Commands are issued asynchronously to the Redis server and return immediately.

    % r SET myKey {Some value}
    rds:1

The return value is a **command identifier**, such as `rds:1`, which can be used at any time to retrieve the result of the command.

    % r result rds:1
    OK
    
Obviously, the two can be concatenated.

    % r result [r GET myKey]
    Some value
    
A shortcut to this pattern is provided via the `-sync` switch. This switch must be used as the first argument, before the Redis command. The above is thus better rewritten as:

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

If this is not the wanted behaviour, the `-async` argument might be used. In this case, if no result is available, the `result` method returns the empty string:

    % r CLIENT PAUSE 10000
    rds:5
    % set cmdId [r SET otherKey {second value}]
    rds:6
    % r result -async $cmdId
    # immediately

Synchronous mode might be turned on by calling the `async` method with a
`false` argument. This turns off the default asynchronous mode, so redis
commands are invoked as if the `-sync` option was always specified:

    % r async false
    false
    % r GET mykey
    Some value

To restore default asynchronous operation, call the `async` method either
without arguments or with a `true` argument:

    % r async
    true


The third method available is `allResults`, which returns a dictionary of all available results where keys are **command identifiers** and values are **results**:

    % r SET key val
    rds:1
    % r GET key
    rds:2
    % r allResults
    rds:1 OK rds:2 val


<a name="cache"></a>
### The results cache

By default, results are kept in a cache and are *not* deleted after having been retrieved, so it's always possible to query for results of previous commands with the `result` method (this of course doesn't work for commands issued with the `-sync` argument, which do not return a command identifier).

It is possible to change this behaviour and have the library delete a result from the cache
as soon as it's retrieved:


    % r keepCache false
    
The `keepCache` method accepts an optional boolean argument, which defaults to true. Thus,

    % r keepCache
    
enables the results cache.

Additionally, the cache can be modified by issuing the `clearResult` method. This method might be given a specific a `cmdId` argument, in which case it clears that result. If no argument is given, the whole cache is flushed. Commands still waiting for a response from the server are *not* removed.

**Note:** the `clearResults` method does not care whether the client has retrieved the result, it just checks whether a result has actually been received from the server.


<a name="pipelining"></a>
### Commands pipelining

`retcl` supports the <a href="http://redis.io/topics/pipelining">pipelining</a> of Redis requests. The `pipeline` method accepts a script which is run with pipelining enabled:

    % r pipeline {
        r INCR i
        r INCR i
        puts "almost done..."
        r INCR i
      }
    almost done...

As shown, the script might contain whatever command is available at the caller scope. Results can the be retrieved with the `allResults` method:

    % r allResults
    rds:1 1 rds:2 2 rds:3 3


<a name="pubsub"></a>
### Publish / subscribe and callbacks

`retcl` exposes the powerful <a href="http://redis.io/topics/pubsub">publish / subscribe semantics</a> in Redis through the `callback` method. The method takes two arguments.

1. a *subscription item*, matching either a `channel` argument to `SUBSCRIBE` or a `pattern` argument to `PSUBSCRIBE`
2. a *command prefix*

Upon reception of a message matching `channel` / `pattern`, the *command prefix* will be appended the *subscription item* and the message data received and will be invoked in the global namespace.

    % proc mycallback {registrationTime channel message} {
          set elapsed [expr {[clock seconds] - $registrationTime}]
          puts "It took $elapsed seconds to get $message on channel $channel"
      }
    % r callback chan1 [list mycallback [clock seconds]]
    % r -sync SUBSCRIBE chan1
    subscribe chan1 1
    
Some time later somebody sends "Hello!" on chan1.

    It took 35 seconds to get Hello! on channel chan1
    
**Note:** as shown in the previous code snipped, registering a callback does *not* automatically send a (P)SUBSCRIBE request to the Redis server.

To disable a callback, just call `callback` with an empty *command prefix*. The previously registered *command prefix*, if any, is returned.

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

<a name="reference"></a>
### Reference

    rectl create r
or

    set red [retcl new ?host? ?port?]

Create an instance of the retcl class in the command r.

    r disconnect
    
Disconnect from the server.

    r connect host port
    
Connect to the server `host` on port `port`.

    r connected
    
Returns 1 if the client is connected, 0 otherwise.

    r errorHandler ?cmdPrefix?

Setup an error handler to be called whenever an error occurs in the library. If
no `cmdPrefix` argumet is given, the default error handler `[error]` is
restored.

    r ?-sync? REDIS COMMAND WORDS
    
Send REDIS COMMAND WORDS over to the Redis server. If the `-sync` argument is specified, wait until a response is available and return it. Otherwise, return a ***command identifier***.

    r result ?-async? cmdId
    
Retrieve the result of the command identified by the ***command identifier*** `cmdId`. If the result is not yet available, either wait or return the empty string if `-async` was specified.

    r allResults
    
Retrieve a dictionary where ***command identifiers*** are keys and ***responses*** are values.

    r clearResult ?cmdId?
    
Either remove the result of the command identified by ***command identifier*** `cmdId` from the cache. If no `cmdId` is specified, flush the whole cache.

    r keepCache ?keep?
    
Switch on or off keeping results in the cache after the client has retrieven them using the `result` method. If no argument is given, true is assumed. The `keep` argument can take any form accepted by `[string is boolean]`.

    r async ?async?

Switch on or off the default asynchronous operation mode. If no argument is
given, true is assumed. The `async` argument can take any form accepted by `[string is boolean]`.

    r pipeline script
    
Execute `script` in the caller scope while holding a Redis pipeline. All Redis commands issued within the `script` are sent over to the server at the end of the script.

    r callback item ?cmdPrefix?
    
If `cmdPrefix` is specified, setup a command to be called whenever a message arrives on the subscription item `item`. If no `cmdPrefix` is specified, clear a previously setup callback on the same `item`.



