%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2012 VMware, Inc.  All rights reserved.
%%
-module(eager_synchronization_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("systest/include/systest.hrl").

-include_lib("amqp_client/include/amqp_client.hrl").

-define(QNAME, <<"ha.two.test">>).
-define(MESSAGE_COUNT, 500).

-export([suite/0, all/0, init_per_suite/1, end_per_suite/1,
         eager_sync_test/1, eager_sync_cancel_test/1]).

%% NB: it can take almost a minute to start and cluster 3 nodes,
%% and then we need time left over to run the actual tests...
suite() -> [{timetrap, systest:settings("time_traps.ha_cluster_SUITE")}].

all() ->
    systest_suite:export_all(?MODULE).

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

eager_sync_test(Config) ->
    %% Queue is on AB but not C.
    {_Cluster, [{{A, _ARef}, {_AConn, ACh}},
                {{B, _BRef}, {_BConn, _BCh}},
                {{C, _CRef}, {Conn, Ch}}]} =
        rabbit_ha_test_utils:cluster_members(Config),

    amqp_channel:call(ACh, #'queue.declare'{queue   = ?QNAME,
                                            durable = true}),
    amqp_channel:call(Ch, #'confirm.select'{}),

    %% Don't sync, lose messages
    publish(Ch, ?MESSAGE_COUNT),
    lose(A),
    lose(B),
    consume(Ch, 0),

    %% Sync, keep messages
    publish(Ch, ?MESSAGE_COUNT),
    lose(A),
    ok = sync(C),
    lose(B),
    consume(Ch, ?MESSAGE_COUNT),

    %% Check the no-need-to-sync path
    publish(Ch, ?MESSAGE_COUNT),
    ok = sync(C),
    consume(Ch, ?MESSAGE_COUNT),

    %% messages_unacknowledged > 0, fail to sync
    publish(Ch, ?MESSAGE_COUNT),
    lose(A),
    {ok, Ch2} = amqp_connection:open_channel(Conn),
    {#'basic.get_ok'{}, _} = amqp_channel:call(
                               Ch2, #'basic.get'{queue = ?QNAME}),
    {error, pending_acks} = sync(C),
    amqp_channel:close(Ch2),
    consume(Ch, ?MESSAGE_COUNT),

    ok.

eager_sync_cancel_test(Config) ->
    %% Queue is on AB but not C.
    {_Cluster, [{{A, _ARef}, {_AConn, ACh}},
                {{B, _BRef}, {_BConn, _BCh}},
                {{C, _CRef}, {_Conn, Ch}}]} =
        rabbit_ha_test_utils:cluster_members(Config),

    amqp_channel:call(ACh, #'queue.declare'{queue   = ?QNAME,
                                            durable = true}),
    amqp_channel:call(Ch, #'confirm.select'{}),

    %% Sync then cancel
    publish(Ch, ?MESSAGE_COUNT),
    lose(A),
    spawn_link(fun() -> sync_nowait(C) end),
    wait_for_syncing(C),
    sync_cancel(C),
    wait_for_running(C),
    lose(B),
    consume(Ch, 0),
    ok.


publish(Ch, Count) ->
    [amqp_channel:call(Ch,
                       #'basic.publish'{routing_key = ?QNAME},
                       #amqp_msg{props   = #'P_basic'{delivery_mode = 2},
                                 payload = list_to_binary(integer_to_list(I))})
     || I <- lists:seq(1, Count)],
    amqp_channel:wait_for_confirms(Ch).

consume(Ch, Count) ->
    amqp_channel:subscribe(Ch, #'basic.consume'{queue = ?QNAME, no_ack = true},
                           self()),
    CTag = receive #'basic.consume_ok'{consumer_tag = C} -> C end,
    [begin
         Exp = list_to_binary(integer_to_list(I)),
         receive {#'basic.deliver'{consumer_tag = CTag},
                  #amqp_msg{payload = Exp}} ->
                 ok
         after 500 ->
                 exit(timeout)
         end
     end|| I <- lists:seq(1, Count)],
    #'queue.declare_ok'{message_count = 0}
        = amqp_channel:call(Ch, #'queue.declare'{queue   = ?QNAME,
                                                 durable = true}),
    amqp_channel:call(Ch, #'basic.cancel'{consumer_tag = CTag}),
    ok.

lose(Node) ->
    rabbit_ha_test_utils:stop_app(Node),
    rabbit_ha_test_utils:start_app(Node).

sync(Node) ->
    case sync_nowait(Node) of
        ok -> slave_synchronization_SUITE:wait_for_sync_status(
                true, Node, ?QNAME),
              ok;
        R  -> R
    end.

sync_nowait(Node) -> action(Node, sync_queue).
sync_cancel(Node) -> action(Node, cancel_sync_queue).

action(Node, Action) ->
    rabbit_ha_test_utils:control_action(
      Action, Node, [binary_to_list(?QNAME)], [{"-p", "/"}]).

queue(Node) ->
    QName = rabbit_misc:r(<<"/">>, queue, ?QNAME),
    {ok, Q} = rpc:call(Node, rabbit_amqqueue, lookup, [QName]),
    Q.

wait_for_syncing(Node) ->
    case status(Node) of
        {syncing, _} -> ok;
        _            -> timer:sleep(100),
                        wait_for_syncing(Node)
    end.

wait_for_running(Node) ->
    case status(Node) of
        running -> ok;
        _       -> timer:sleep(100),
                   wait_for_running(Node)
    end.

status(Node) ->
    [{status, Status}] =
        rpc:call(Node, rabbit_amqqueue, info, [queue(Node), [status]]),
    Status.
