%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2010-2012 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_mirror_queue_sync).

-include("rabbit.hrl").

-export([master_prepare/4, master_go/8, slave/7]).

-define(SYNC_PROGRESS_INTERVAL, 1000000).

-define(BATCH_SIZE, 20000).

%% There are three processes around, the master, the syncer and the
%% slave(s). The syncer is an intermediary, linked to the master in
%% order to make sure we do not mess with the master's credit flow or
%% set of monitors.
%%
%% Interactions
%% ------------
%%
%% '*' indicates repeating messages. All are standard Erlang messages
%% except sync_start which is sent over GM to flush out any other
%% messages that we might have sent that way already. (credit) is the
%% usual credit_flow bump message every so often.
%%
%%               Master             Syncer                 Slave(s)
%% sync_mirrors -> ||                                         ||
%% (from channel)  || -- (spawns) --> ||                      ||
%%                 || --------- sync_start (over GM) -------> ||
%%                 ||                 || <--- sync_ready ---- ||
%%                 ||                 ||         (or)         ||
%%                 ||                 || <--- sync_deny ----- ||
%%                 || <--- ready ---- ||                      ||
%%                 || <--- next* ---- ||                      ||  }
%%                 || ---- msg* ----> ||                      ||  } loop
%%                 ||                 || ---- sync_msg* ----> ||  }
%%                 ||                 || <--- (credit)* ----- ||  }
%%                 || <--- next  ---- ||                      ||
%%                 || ---- done ----> ||                      ||
%%                 ||                 || -- sync_complete --> ||
%%                 ||               (Dies)                    ||

-ifdef(use_specs).

-type(log_fun() :: fun ((string(), [any()]) -> 'ok')).
-type(bq() :: atom()).
-type(bqs() :: any()).
-type(ack() :: any()).
-type(slave_sync_state() :: {[{rabbit_types:msg_id(), ack()}], timer:tref(),
                             bqs()}).

-spec(master_prepare/4 :: (reference(), rabbit_amqqueue:name(),
                               log_fun(), [pid()]) -> pid()).
-spec(master_go/8 :: (pid(), reference(), log_fun(),
                      rabbit_mirror_queue_master:stats_fun(),
                      rabbit_mirror_queue_master:stats_fun(),
                      non_neg_integer(),
                      bq(), bqs()) ->
                          {'already_synced', bqs()} | {'ok', bqs()} |
                          {'shutdown', any(), bqs()} |
                          {'sync_died', any(), bqs()}).
-spec(slave/7 :: (non_neg_integer(), reference(), timer:tref(), pid(),
                  bq(), bqs(), fun((bq(), bqs()) -> {timer:tref(), bqs()})) ->
                      'denied' |
                      {'ok' | 'failed', slave_sync_state()} |
                      {'stop', any(), slave_sync_state()}).

-endif.

%% ---------------------------------------------------------------------------
%% Master

master_prepare(Ref, QName, Log, SPids) ->
    MPid = self(),
    spawn_link(fun () ->
                       ?store_proc_name(QName),
                       syncer(Ref, Log, MPid, SPids)
               end).

master_go(Syncer, Ref, Log, HandleInfo, EmitStats, SyncBatchSize, BQ, BQS) ->
    Args = {Syncer, Ref, Log, HandleInfo, EmitStats, rabbit_misc:get_parent()},
    receive
        {'EXIT', Syncer, normal} -> {already_synced, BQS};
        {'EXIT', Syncer, Reason} -> {sync_died, Reason, BQS};
        {ready, Syncer}          -> EmitStats({syncing, 0}),
                                    case maybe_batch(SyncBatchSize) of
                                        true  ->
                                            master_batch_go0(Args, SyncBatchSize,
                                                             BQ, BQS);
                                        false ->
                                            master_go0(Args, BQ, BQS)
                                    end
    end.

master_go0(Args, BQ, BQS) ->
    FoldFun =
        fun (Msg, MsgProps, Unacked, Acc) ->
                master_send(Msg, MsgProps, Unacked, Args, Acc)
        end,
    FoldAcc = {0, time_compat:monotonic_time()},
    bq_fold(FoldFun, FoldAcc, Args, BQ, BQS).

master_send(Msg, MsgProps, Unacked,
            {Syncer, Ref, Log, HandleInfo, EmitStats, Parent}, {I, Last}) ->
    T = maybe_emit_stats(Last, I, EmitStats, Log),
    HandleInfo({syncing, I}),
    handle_set_maximum_since_use(),
    SyncMsg = {msg, Ref, Msg, MsgProps, Unacked},
    NewAcc = {I + 1, T},
    master_send_receive(SyncMsg, NewAcc, Syncer, Ref, Parent).

master_batch_go0(Args, BatchSize, BQ, BQS) ->
    FoldFun =
        fun (Msg, MsgProps, Unacked, Acc) ->
                Acc1 = append_to_acc(Msg, MsgProps, Unacked, Acc),
                case maybe_master_batch_send(Acc1, BatchSize) of
                    true  -> master_batch_send(Args, Acc1);
                    false -> {cont, Acc1}
                end
        end,
    FoldAcc = {[], 0, {0, BQ:len(BQS)}, time_compat:monotonic_time()},
    bq_fold(FoldFun, FoldAcc, Args, BQ, BQS).

master_batch_send({Syncer, Ref, Log, HandleInfo, EmitStats, Parent},
                  {Batch, I, {Curr, Len}, Last}) ->
    T = maybe_emit_stats(Last, I, EmitStats, Log),
    HandleInfo({syncing, I}),
    handle_set_maximum_since_use(),
    SyncMsg = {msgs, Ref, Batch},
    NewAcc = {[], I + length(Batch), {Curr, Len}, T},
    master_send_receive(SyncMsg, NewAcc, Syncer, Ref, Parent).

%% Either send messages when we reach the last one in the queue or
%% whenever we have accumulated BatchSize messages.
maybe_master_batch_send({_, _, {Len, Len}, _}, _BatchSize) ->
    true;
maybe_master_batch_send({_, _, {Curr, _Len}, _}, BatchSize)
  when Curr rem BatchSize =:= 0 ->
    true;
maybe_master_batch_send(_Acc, _BatchSize) ->
    false.

bq_fold(FoldFun, FoldAcc, Args, BQ, BQS) ->
    case BQ:fold(FoldFun, FoldAcc, BQS) of
        {{shutdown,  Reason}, BQS1} -> {shutdown,  Reason, BQS1};
        {{sync_died, Reason}, BQS1} -> {sync_died, Reason, BQS1};
        {_,                   BQS1} -> master_done(Args, BQS1)
    end.

append_to_acc(Msg, MsgProps, Unacked, {Batch, I, {Curr, Len}, T}) ->
    {[{Msg, MsgProps, Unacked} | Batch], I, {Curr + 1, Len}, T}.

master_send_receive(SyncMsg, NewAcc, Syncer, Ref, Parent) ->
    receive
        {'$gen_call', From,
         cancel_sync_mirrors}    -> stop_syncer(Syncer, {cancel, Ref}),
                                    gen_server2:reply(From, ok),
                                    {stop, cancelled};
        {next, Ref}              -> Syncer ! SyncMsg,
                                    {cont, NewAcc};
        {'EXIT', Parent, Reason} -> {stop, {shutdown,  Reason}};
        {'EXIT', Syncer, Reason} -> {stop, {sync_died, Reason}}
    end.

master_done({Syncer, Ref, _Log, _HandleInfo, _EmitStats, Parent}, BQS) ->
    receive
        {next, Ref}              -> stop_syncer(Syncer, {done, Ref}),
                                    {ok, BQS};
        {'EXIT', Parent, Reason} -> {shutdown,  Reason, BQS};
        {'EXIT', Syncer, Reason} -> {sync_died, Reason, BQS}
    end.

stop_syncer(Syncer, Msg) ->
    unlink(Syncer),
    Syncer ! Msg,
    receive {'EXIT', Syncer, _} -> ok
    after 0 -> ok
    end.

maybe_emit_stats(Last, I, EmitStats, Log) ->
    Interval = time_compat:convert_time_unit(
                 time_compat:monotonic_time() - Last, native, micro_seconds),
    case Interval > ?SYNC_PROGRESS_INTERVAL of
        true  -> EmitStats({syncing, I}),
                 Log("~p messages", [I]),
                 time_compat:monotonic_time();
        false -> Last
    end.

handle_set_maximum_since_use() ->
    receive
        {'$gen_cast', {set_maximum_since_use, Age}} ->
            ok = file_handle_cache:set_maximum_since_use(Age)
    after 0 ->
            ok
    end.

maybe_batch(SyncBatchSize) when SyncBatchSize > 1 ->
    true;
maybe_batch(_SyncBatchSize) ->
    false.

%% Master
%% ---------------------------------------------------------------------------
%% Syncer

syncer(Ref, Log, MPid, SPids) ->
    [erlang:monitor(process, SPid) || SPid <- SPids],
    %% We wait for a reply from the slaves so that we know they are in
    %% a receive block and will thus receive messages we send to them
    %% *without* those messages ending up in their gen_server2 pqueue.
    case await_slaves(Ref, SPids) of
        []     -> Log("all slaves already synced", []);
        SPids1 -> MPid ! {ready, self()},
                  Log("mirrors ~p to sync", [[node(SPid) || SPid <- SPids1]]),
                  syncer_loop(Ref, MPid, SPids1)
    end.

await_slaves(Ref, SPids) ->
    [SPid || SPid <- SPids,
             rabbit_mnesia:on_running_node(SPid) andalso %% [0]
                 receive
                     {sync_ready, Ref, SPid}       -> true;
                     {sync_deny,  Ref, SPid}       -> false;
                     {'DOWN', _, process, SPid, _} -> false
                 end].
%% [0] This check is in case there's been a partition which has then
%% healed in between the master retrieving the slave pids from Mnesia
%% and sending 'sync_start' over GM. If so there might be slaves on the
%% other side of the partition which we can monitor (since they have
%% rejoined the distributed system with us) but which did not get the
%% 'sync_start' and so will not reply. We need to act as though they are
%% down.

syncer_loop(Ref, MPid, SPids) ->
    MPid ! {next, Ref},
    receive
        {msg, Ref, Msg, MsgProps, Unacked} ->
            SPids1 = wait_for_credit(SPids),
            broadcast(SPids1, {sync_msg, Ref, Msg, MsgProps, Unacked}),
            syncer_loop(Ref, MPid, SPids1);
        {msgs, Ref, Msgs} ->
            SPids1 = wait_for_credit(SPids),
            broadcast(SPids1, {sync_msgs, Ref, Msgs}),
            syncer_loop(Ref, MPid, SPids1);
        {cancel, Ref} ->
            %% We don't tell the slaves we will die - so when we do
            %% they interpret that as a failure, which is what we
            %% want.
            ok;
        {done, Ref} ->
            [SPid ! {sync_complete, Ref} || SPid <- SPids]
    end.

broadcast(SPids, Msg) ->
    [begin
         credit_flow:send(SPid),
         SPid ! Msg
     end || SPid <- SPids].

wait_for_credit(SPids) ->
    case credit_flow:blocked() of
        true  -> receive
                     {bump_credit, Msg} ->
                         credit_flow:handle_bump_msg(Msg),
                         wait_for_credit(SPids);
                     {'DOWN', _, process, SPid, _} ->
                         credit_flow:peer_down(SPid),
                         wait_for_credit(lists:delete(SPid, SPids))
                 end;
        false -> SPids
    end.

%% Syncer
%% ---------------------------------------------------------------------------
%% Slave

slave(0, Ref, _TRef, Syncer, _BQ, _BQS, _UpdateRamDuration) ->
    Syncer ! {sync_deny, Ref, self()},
    denied;

slave(_DD, Ref, TRef, Syncer, BQ, BQS, UpdateRamDuration) ->
    MRef = erlang:monitor(process, Syncer),
    Syncer ! {sync_ready, Ref, self()},
    {_MsgCount, BQS1} = BQ:purge(BQ:purge_acks(BQS)),
    slave_sync_loop({Ref, MRef, Syncer, BQ, UpdateRamDuration,
                     rabbit_misc:get_parent()}, {[], TRef, BQS1}).

slave_sync_loop(Args = {Ref, MRef, Syncer, BQ, UpdateRamDuration, Parent},
                State = {MA, TRef, BQS}) ->
    receive
        {'DOWN', MRef, process, Syncer, _Reason} ->
            %% If the master dies half way we are not in the usual
            %% half-synced state (with messages nearer the tail of the
            %% queue); instead we have ones nearer the head. If we then
            %% sync with a newly promoted master, or even just receive
            %% messages from it, we have a hole in the middle. So the
            %% only thing to do here is purge.
            {_MsgCount, BQS1} = BQ:purge(BQ:purge_acks(BQS)),
            credit_flow:peer_down(Syncer),
            {failed, {[], TRef, BQS1}};
        {bump_credit, Msg} ->
            credit_flow:handle_bump_msg(Msg),
            slave_sync_loop(Args, State);
        {sync_complete, Ref} ->
            erlang:demonitor(MRef, [flush]),
            credit_flow:peer_down(Syncer),
            {ok, State};
        {'$gen_cast', {set_maximum_since_use, Age}} ->
            ok = file_handle_cache:set_maximum_since_use(Age),
            slave_sync_loop(Args, State);
        {'$gen_cast', {set_ram_duration_target, Duration}} ->
            BQS1 = BQ:set_ram_duration_target(Duration, BQS),
            slave_sync_loop(Args, {MA, TRef, BQS1});
        {'$gen_cast', {run_backing_queue, Mod, Fun}} ->
            BQS1 = BQ:invoke(Mod, Fun, BQS),
            slave_sync_loop(Args, {MA, TRef, BQS1});
        update_ram_duration ->
            {TRef1, BQS1} = UpdateRamDuration(BQ, BQS),
            slave_sync_loop(Args, {MA, TRef1, BQS1});
        {sync_msg, Ref, Msg, Props, Unacked} ->
            credit_flow:ack(Syncer),
            Props1 = Props#message_properties{needs_confirming = false},
            {MA1, BQS1} =
                case Unacked of
                    false -> {MA,
                              BQ:publish(Msg, Props1, true, none, noflow, BQS)};
                    true  -> {AckTag, BQS2} = BQ:publish_delivered(
                                                Msg, Props1, none, noflow, BQS),
                             {[{Msg#basic_message.id, AckTag} | MA], BQS2}
                end,
            slave_sync_loop(Args, {MA1, TRef, BQS1});
        {sync_msgs, Ref, Batch} ->
            credit_flow:ack(Syncer),
            %% We need to partition the batch in messages that need to
            %% be batch_publish/2 and the ones that need to be
            %% batch_publish_delivered/2.
            %%
            %% The Batch has the messages in reverse order, but We
            %% don't need to reverse them since BatchP1 and BatchPD1
            %% will have the right order after the fold1.
            {BatchP1, BatchPD1} =
                lists:foldl(
                  fun ({Msg, Props, false}, {BatchP, BatchPD}) ->
                          Props1 = Props#message_properties{
                                     needs_confirming = false},
                          {[{Msg, Props1, true} | BatchP],
                           BatchPD};
                      ({Msg, Props, true}, {BatchP, BatchPD}) ->
                          Props1 = Props#message_properties{
                                     needs_confirming = false},
                          {BatchP,
                           [{Msg, Props1} | BatchPD]}
                  end, {[], []}, Batch),
            BQS1 = BQ:batch_publish(BatchP1, none, noflow, BQS),
            {AckTags, BQS2} = BQ:batch_publish_delivered(BatchPD1, none, noflow, BQS1),
            MA1 =
                lists:foldl(fun ({{Msg, _, _, _}, AckTag}, Acc) ->
                                    [{Msg#basic_message.id, AckTag} | Acc]
                            end, MA, lists:zip(BatchPD1, AckTags)),
            slave_sync_loop(Args, {MA1, TRef, BQS2});
        {'EXIT', Parent, Reason} ->
            {stop, Reason, State};
        %% If the master throws an exception
        {'$gen_cast', {gm, {delete_and_terminate, Reason}}} ->
            BQ:delete_and_terminate(Reason, BQS),
            {stop, Reason, {[], TRef, undefined}}
    end.
