%% -------------------------------------------------------------------
%%
%% a testing place for bigset ideas
%%
%% Copyright (c) 2007-2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(bigset_eqc).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-define(SWOT, riak_dt_delta_orswot).
-define(CLOCK, bigset_clock).
-define(SET, set).
-define(HOFF_REC, bigset_eqc_hoff_rec).

-record(state, {replicas=[], %% Actor Ids for replicas in the system
                handing_off=[], %% pid of handing-off processes
                hoff_targets=[],
                deleters=[], %% replicas that have performed remove %% TODO rename
                removed_replicas=[], %% Actor Ids for replicas that have been removed from preflist
                adds=[],      %% Elements that have been added to the set
                deltas=[], %% delta result of add/remove goes here for later replication/delivery
                delivered=[], %% track which deltas actually get delivered (for stats/funsies)
                compacted=[], %% how many keys were removed by a compaction
                is_members=[]  %% the {Element, {Element, Ctx}} pairs for a remote/client remove cos symbolic state stuff
               }).

-record(replica, {
          id,            %% The replica ID
          bigset=bigset_model:new(),%% a sort of bigset type structure
          delta_set=?SWOT:new()      %% the model delta for comparison
         }).

-record(delta, {
          bs_delta,
          dt_delta
         }).

-record(hoff_state, {
          tracker=bigset_clock:fresh(),
          sender_clock,
          sender,
          receiver,
          keys=[]}).

%% The set of possible elements in the set
-define(ELEMENTS, ['A', 'B', 'C', 'D', 'X', 'Y', 'Z']).

-define(NUMTESTS, 100).
-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) ->
                              io:format(user, Str, Args) end, P)).

eqc_test_() ->
    {timeout, 120, ?_assertEqual(true, eqc:quickcheck(eqc:testing_time(50, ?QC_OUT(prop_merge()))))}.

run() ->
    run(?NUMTESTS).

run(Count) ->
    eqc:quickcheck(eqc:numtests(Count, prop_merge())).

check() ->
    eqc:check(prop_merge()).

check(File) ->
    {ok, Bytes} = file:read_file(File),
    CE = binary_to_term(Bytes),
    eqc:check(prop_merge(), CE).

initial_state() ->
    #state{}.

%% @doc <i>Optional callback</i>, Invariant, checked for each visited
%% state during test execution.
-spec invariant(S :: eqc_statem:dynamic_state()) -> boolean().
invariant(_S) ->
    Hoffs = ets:tab2list(?HOFF_REC),
    eq(lists:foldl(fun(#replica{id=ID, bigset=BS, delta_set=DT}=Rep, Bads) ->
                           case lists:keymember(ID, 2, Hoffs) of
                               false ->
                                   case sets_equal(BS, DT) of
                                       true ->
                                           Bads;
                                       Res ->
                                           [{Res, Rep} | Bads]
                                   end;
                               _ ->
                                   []
                           end
                   end,
                   [],
                   ets:tab2list(?MODULE)),
       []).

%% ------ Grouped operator: create_replica
create_replica_pre(#state{replicas=Replicas, removed_replicas=DeadReps}) ->
    length(Replicas++DeadReps) < 10.

%% @doc create_replica_command - Command generator
create_replica_args(S) ->
    %% Don't waste time shrinking the replicas ID number
    ?SUCHTHAT(Args, [noshrink(choose(1, 20))], create_replica_pre(S, Args)).

%% @doc create_replica_pre - don't create a replica that already
%% exists
-spec create_replica_pre(S :: eqc_statem:symbolic_state(),
                         Args :: [term()]) -> boolean().
create_replica_pre(#state{replicas=Replicas, removed_replicas=DeadReps}, [Id]) ->
    not lists:member(Id, Replicas) andalso not lists:member(Id, DeadReps).

%% @doc create a new replica
create_replica(Id) ->
    ets:insert(?MODULE, #replica{id=Id}). %% @TODO use process_id in key for parallel eqc

%% @doc create_replica_next - Add the new replica ID to state
-spec create_replica_next(S :: eqc_statem:symbolic_state(),
                          V :: eqc_statem:var(),
                          Args :: [term()]) -> eqc_statem:symbolic_state().
create_replica_next(S=#state{replicas=R0}, _Value, [Id]) ->
    S#state{replicas=R0++[Id]}.

create_replica_post(_S, [Replica], _) ->
    post_equals(Replica).

%% ------ Grouped operator: add
%% @doc add_pre - Don't add to a set until we have a replica
-spec add_pre(S :: eqc_statem:symbolic_state()) -> boolean().
add_pre(#state{replicas=Replicas}) ->
    Replicas /= [].

add_args(#state{replicas=Replicas}) ->
    [elements(Replicas),
     %% Start of with earlier/fewer elements
     growingelements(?ELEMENTS)].

%% @doc add_pre - Ensure correct shrinking, only select a replica that
%% is in the state
-spec add_pre(S :: eqc_statem:symbolic_state(),
              Args :: [term()]) -> boolean().
add_pre(#state{replicas=Replicas}, [Replica, _]) ->
    lists:member(Replica, Replicas).

%% @doc add the `Element' to the sets at `Replica'
add(Replica, Element) ->
    [#replica{id=Replica,
              bigset=BS,
              delta_set=ORSWOT}=Rep] = ets:lookup(?MODULE, Replica),

    %% In the absence of a client and AAAD, use the clock at the
    %% coordinating replica as the context of the add operation, any
    %% 'X' seen at this node will be removed by an add of an 'X'
    {BSDelta, BS2} = bigset_model:add(Element, Replica, BS),
    {ok, Delta} = ?SWOT:delta_update({add, Element}, Replica, ORSWOT),
    ORSWOT2 = ?SWOT:merge(Delta, ORSWOT),

    ets:insert(?MODULE, Rep#replica{bigset=BS2, delta_set=ORSWOT2}),
    #delta{bs_delta=BSDelta, dt_delta=Delta}.

%% @doc add_next - Add the `Element' to the `adds' list so we can
%% select from it when we come to remove. This increases the liklihood
%% of a remove actually being meaningful. Add to the delta
%% buffer too.
-spec add_next(S :: eqc_statem:symbolic_state(),
               V :: eqc_statem:var(),
               Args :: [term()]) -> eqc_statem:symbolic_state().
add_next(S=#state{adds=Adds, deltas=Deltas}, Delta, [_Replica, Element]) ->
    S#state{adds=lists:umerge(Adds, [Element]),
            deltas=[Delta | Deltas]}.

%% @doc add_post - Postcondition for add
-spec add_post(S, Args, Res) -> true | term()
    when S    :: eqc_state:dynamic_state(),
         Args :: [term()],
         Res  :: term().
add_post(_S, [Replica, _Element], _) ->
    post_equals(Replica).

%% ------ Grouped operator: remove
remove_args(#state{replicas=Replicas, adds=Adds}) ->
    [elements(Replicas),
     elements(Adds)].

%% @doc remove_pre - As for `remove/1'
-spec remove_pre(S :: eqc_statem:symbolic_state()) -> boolean().
remove_pre(#state{replicas=Replicas, adds=Adds}) ->
    Replicas /= [] andalso Adds /= [].

%% @TODO add a client/ctx remove
%% @doc remove_pre - Ensure correct shrinking
-spec remove_pre(S :: eqc_statem:symbolic_state(),
                         Args :: [term()]) -> boolean().
remove_pre(#state{replicas=Replicas, adds=Adds}, [From, Element]) ->
    lists:member(From, Replicas)
        andalso lists:member(Element, Adds).

%% @doc a dynamic precondition uses concrete state, check that the
%% `From' set contains `Element'
remove_dynamicpre(_S, [From, Element]) ->
    [#replica{id=From, delta_set=Set}] = ets:lookup(?MODULE, From),
    lists:member(Element, ?SWOT:value(Set)).

%% @doc perform a context remove using the context+element at `From'
%% and removing from From.
remove(From, Element) ->
    [Rep=#replica{id=From,
                  bigset=BS,
                  delta_set=ORSWOT=Set}] = ets:lookup(?MODULE, From),


    {ok, Delta} = ?SWOT:delta_update({remove, Element}, From, Set),
    ORSWOT2 = ?SWOT:merge(Delta, ORSWOT),
    {BSDelta, BS2} = bigset_model:remove(Element, From, BS),
    ets:insert(?MODULE, Rep#replica{bigset=BS2, delta_set=ORSWOT2}),

    #delta{bs_delta=BSDelta, dt_delta=Delta}.

%% @doc remove_next - Add remove keys to the delta
%% buffer.
-spec remove_next(S :: eqc_statem:symbolic_state(),
                               V :: eqc_statem:var(),
                               Args :: [term()]) -> eqc_statem:symbolic_state().
remove_next(S=#state{deltas=Deltas}, Delta, [_From, _RemovedElement]) ->
    S#state{deltas=[Delta | Deltas]}.

remove_post(_S, [Replica, _E], _) ->
    post_equals(Replica).

%% ------ Grouped operator: replicate @doc replicate_args - Choose
%% delta batch and target for replication. We pick a subset of the
%% delta to simulate dropped, re-ordered, repeated messages.
replicate_args(#state{replicas=Replicas, deltas=Deltas}) ->
    [subset(Deltas),
     elements(Replicas)].

%% @doc replicate_pre - There must be at least one replica to replicate
-spec replicate_pre(S :: eqc_statem:symbolic_state()) -> boolean().
replicate_pre(#state{replicas=Replicas, deltas=Deltas}) ->
    Replicas /= [] andalso Deltas /= [].

%% @doc replicate_pre - Ensure correct shrinking
-spec replicate_pre(S :: eqc_statem:symbolic_state(),
                    Args :: [term()]) -> boolean().
replicate_pre(#state{replicas=Replicas, deltas=Deltas}, [Delta, To]) ->
    sets:is_subset(sets:from_list(Delta), sets:from_list(Deltas))
        andalso lists:member(To, Replicas).

%% @doc simulate replication by merging state at `To' with the delta
replicate(Deltas, To) ->
    [#replica{id=To, delta_set=Set,
              bigset=BS}=ToRep] = ets:lookup(?MODULE, To),

    {BS2, Set2} = lists:foldl(fun(#delta{bs_delta=BSD, dt_delta=DT}, {B, D}) ->
                                               {bigset_model:delta_join(BSD, B),
                                                ?SWOT:merge(DT, D)}
                                       end,
                                       {BS, Set},
                                       Deltas),

    ets:insert(?MODULE, ToRep#replica{bigset=BS2,
                                      delta_set=Set2}).

replicate_next(S=#state{delivered=Delivered}, _, [Deltas, _To]) ->
    S#state{delivered=[Deltas | Delivered]}.

replicate_post(_S, [_Delta, Replica], _) ->
    post_equals(Replica).

%% --- Operation: compact ---
%% @doc compact_pre/1 - Precondition for generation
-spec compact_pre(S :: eqc_statem:symbolic_state()) -> boolean().
compact_pre(#state{replicas=Replicas}) ->
    Replicas /= [].

%% @doc compact_args - Argument generator
-spec compact_args(S :: eqc_statem:symbolic_state()) -> eqc_gen:gen([term()]).
compact_args(#state{replicas=Replicas}) ->
    [elements(Replicas)].

%% @doc compact_pre/2 - Precondition for compact
-spec compact_pre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
compact_pre(#state{replicas=Replicas}, [Replica]) ->
    lists:member(Replica, Replicas).

%% @doc compact - Remove superseded adds, and redundant tombstones.
compact(Replica) ->
    [#replica{bigset=BS}=Rep] = ets:lookup(?MODULE, Replica),

    {BS2, NumCompactedElems} = compact_bigset(BS),

    ets:insert(?MODULE, Rep#replica{bigset=BS2}),
    {NumCompactedElems, BS, BS2}.

%% @doc compact_next - Next state function
compact_next(S=#state{compacted=Compacted}, Value, [_Replica]) ->
    S#state{compacted=[Value | Compacted]}.

%% @doc compact_post - Postcondition for compact
-spec compact_post(S, Args, Res) -> true | term()
    when S    :: eqc_state:dynamic_state(),
         Args :: [term()],
         Res  :: term().
compact_post(_S, [_Replica], {Diff, Before, After}) ->
    case {replica_value(Before) == replica_value(After), Diff >= 0} of
        {true, true} ->
            true;
        {false, _} ->
            {post_compaction_not_eq, {before, replica_value(Before), Before}, '/=', {aft, replica_value(After), After}};
        {true, false} ->
            {post_compaction_bigger, Diff}
    end.

%% --- Operation: start_handoff ---
%% @doc start_handoff_pre/1 - Precondition for generation
-spec start_handoff_pre(S :: eqc_statem:symbolic_state()) -> boolean().
start_handoff_pre(#state{replicas=Replicas}) ->
    length(Replicas) > 1.

%% @doc start_handoff_args - Argument generator
-spec start_handoff_args(S :: eqc_statem:symbolic_state()) -> eqc_gen:gen([term()]).
start_handoff_args(#state{replicas=Replicas, hoff_targets=HoffTargets, deleters=Deleters}) ->
    %% prejudice in favour of handing off removed keys
    [oneof([elements(Replicas)] ++ [elements(Deleters) || Deleters /= []]),
     %% we want to test multiple concurrent handoffs
     oneof([elements(Replicas)] ++ [elements(HoffTargets) || HoffTargets /= []])].

%% @doc start_handoff_pre/2 - Precondition for start_handoff
-spec start_handoff_pre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
start_handoff_pre(#state{replicas=Replicas}, [Sender, Receiver]) ->
    Sender /= Receiver andalso
        lists:member(Sender, Replicas) andalso
        lists:member(Receiver, Replicas).

%% @doc start_handoff_dynamicpre - Dynamic precondition for start_handoff
-spec start_handoff_dynamicpre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
start_handoff_dynamicpre(_S, [Sender, Receiver]) ->
    %% A handing off node can never be a receiver, nor a receiver be a
    %% handoffer
    ets:match_object(?HOFF_REC, {'_', Sender}) == [] andalso
        ets:match_object(?HOFF_REC, {Receiver, '_'})  == [] andalso
        ets:match_object(?HOFF_REC, {Sender, Receiver}) == [].

%% @doc start_handoff - The actual operation
start_handoff(Sender, Receiver) ->
    [#replica{id=Sender,
              bigset=FromBS}] = ets:lookup(?MODULE, Sender),
    ets:insert(?HOFF_REC, {Sender, Receiver}),
    spawn_link(fun() ->
                       Clock =  bigset_model:clock(FromBS),
                       Keys = bigset_model:handoff_keys(FromBS) ++ [end_key],
                       bigset_handoff_worker(#hoff_state{sender_clock=Clock,
                                                         sender=Sender, receiver=Receiver, keys=Keys})
               end).

%% @doc start_handoff_next - Next state function
-spec start_handoff_next(S, Var, Args) -> NewS
    when S    :: eqc_statem:symbolic_state() | eqc_state:dynamic_state(),
         Var  :: eqc_statem:var() | term(),
         Args :: [term()],
         NewS :: eqc_statem:symbolic_state() | eqc_state:dynamic_state().
start_handoff_next(S=#state{removed_replicas=DeadReps,
                            replicas=Replicas,
                            hoff_targets=HoffTargets,
                            handing_off=HOFF}, Value, [Sender, Receiver]) ->
    S#state{
      replicas=lists:delete(Sender, Replicas),
      handing_off=HOFF++[Value],
      hoff_targets=HoffTargets++[Receiver],
      removed_replicas=[Sender | DeadReps]}.

%% @doc start_handoff_features - Collects a list of features of this call with these arguments.
-spec start_handoff_features(S, Args, Res) -> list(any())
    when S    :: eqc_statem:dynmic_state(),
         Args :: [term()],
         Res  :: term().
start_handoff_features(_S, [_Sender, Receiver], _Res) ->
    Res = length(ets:match_object(?HOFF_REC, {'_', Receiver})),
    [{{?MODULE, start_handoff, 2}, Res}].


%% --- Operation: proceed_handoff ---
%% @doc proceed_handoff_pre/1 - Precondition for generation
-spec proceed_handoff_pre(S :: eqc_statem:symbolic_state()) -> boolean().
proceed_handoff_pre(#state{handing_off=Hoffs}) ->
    Hoffs /= [].

%% @doc proceed_handoff_args - Argument generator
-spec proceed_handoff_args(S :: eqc_statem:symbolic_state()) -> eqc_gen:gen([term()]).
proceed_handoff_args(#state{handing_off=Hoffs}) ->
    [elements(Hoffs)].

%% @doc proceed_handoff_pre/2 - Precondition for proceed_handoff
-spec proceed_handoff_pre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
proceed_handoff_pre(#state{handing_off=Hoffs}, [Pid]) ->
    lists:member(Pid, Hoffs).

%% @doc proceed_handoff - The actual operation
proceed_handoff(Pid) ->
    Pid ! {proceed, self()},
    receive
        {ok, HoffComplete, Pid} ->
            HoffComplete
    end.

%% @doc proceed_handoff_features - Collects a list of features of this call with these arguments.
-spec proceed_handoff_features(S, Args, Res) -> list(any())
    when S    :: eqc_statem:dynmic_state(),
         Args :: [term()],
         Res  :: term().
proceed_handoff_features(_S, [_Pid], {_, Res}) ->
    [{{?MODULE, proceed_handoff, 1}, Res}].

%% --- Operation: handoff ---
%% @doc handoff_pre/1 - Precondition for generation
-spec handoff_pre(S :: eqc_statem:symbolic_state()) -> boolean().
handoff_pre(#state{replicas=Replicas}) ->
    length(Replicas) > 1.

%% @doc handoff_args - Argument generator
-spec handoff_args(S :: eqc_statem:symbolic_state()) -> eqc_gen:gen([term()]).
handoff_args(#state{replicas=Replicas}) ->
    [elements(Replicas), %% Handing Off
     elements(Replicas)]. %% Handed off to

%% @doc handoff_pre/2 - Precondition for handoff
-spec handoff_pre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
handoff_pre(#state{replicas=Replicas}, [From, To]) ->
    lists:member(From, Replicas)
        andalso lists:member(To, Replicas)
    %% When handoff is complete we delete the replica, so don't hand
    %% off to yourself, ever
        andalso From /= To.

%% @doc handoff - The actual operation For now hand off everything and
%% delete yourself that is that, @TODO(rdb) handoff some, then stop,
%% then start again from the beginning, etc, like real riak
handoff(From, To) ->
    [#replica{id=From, delta_set=FromSet,
              bigset=FromBS}] = ets:lookup(?MODULE, From),
    [#replica{id=To, delta_set=ToSet,
              bigset=ToBS}=ToRep] = ets:lookup(?MODULE, To),

    ToBS2 = bigset_model:handoff(FromBS, ToBS),
    ToSet2 = ?SWOT:merge(FromSet, ToSet),
    ets:insert(?MODULE, ToRep#replica{bigset=ToBS2,
                                      delta_set=ToSet2}),
    ets:delete(?MODULE, From),
    From.

%% @doc handoff_next - Next state function
-spec handoff_next(S, Var, Args) -> NewS
    when S    :: eqc_statem:symbolic_state() | eqc_state:dynamic_state(),
         Var  :: eqc_statem:var() | term(),
         Args :: [term()],
         NewS :: eqc_statem:symbolic_state() | eqc_state:dynamic_state().
handoff_next(S=#state{replicas=Replicas, removed_replicas=DeadReplicas}, _ID, [From, _To]) ->
    S#state{replicas=lists:delete(From, Replicas), removed_replicas=[From | DeadReplicas]}.

%% @doc handoff_post - Postcondition for handoff
-spec handoff_post(S, Args, Res) -> true | term()
    when S    :: eqc_state:dynamic_state(),
         Args :: [term()],
         Res  :: term().
handoff_post(_S, [_From, _To], _Res) ->
    true.

%% --- Operation: client_remove ---
%% @doc client_remove_pre/1 - Precondition for generation
-spec client_remove_pre(S :: eqc_statem:symbolic_state()) -> boolean().
client_remove_pre(#state{is_members=IsMembers}) ->
    IsMembers /= [].

%% @doc client_remove_args - Argument generator
-spec client_remove_args(S :: eqc_statem:symbolic_state()) -> eqc_gen:gen([term()]).
client_remove_args(#state{replicas=Replicas, is_members=IsMembers, adds=Adds}) -> 
    AddedMembers = [IsMember || IsMember={Element,_} <- IsMembers, lists:member(Element, Adds)],
    [frequency([{1, empty_ok}, {6, empty_nok}]),
     elements(Replicas),
     frequency([{1, elements(IsMembers)}] ++ [{10, elements(AddedMembers)} || AddedMembers /= []])
    ].

%% @doc client_remove_pre/2 - Precondition for client_remove
-spec client_remove_pre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
client_remove_pre(#state{is_members=IsMembers, replicas=Replicas}, [_EmptyOk, Replica, IsMember]) ->
    lists:member(IsMember, IsMembers) andalso lists:member(Replica, Replicas).

%% @doc client_remove_dynamicpre - Dynamic precondition for client_remove
-spec client_remove_dynamicpre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
client_remove_dynamicpre(_S, [empty_ok, _To, _]) ->
    true;
client_remove_dynamicpre(_S, [empty_nok, _To, {_, {_, []}}]) ->
    false;
client_remove_dynamicpre(_S, [empty_nok, _to, _]) ->
    true.

%% @doc client_remove - The actual operation
client_remove(_EmptyOk, Replica, {Element, {Element, Ctx}}) ->
    [#replica{id=Replica, delta_set=Set,
              bigset=BS}=Rep] = ets:lookup(?MODULE, Replica),

    {BSDelta, BS2} = bigset_model:remove(Element, Replica, Ctx, BS),
    {ok, Delta} = ?SWOT:delta_update({remove, Element, Ctx}, Replica, Set),
    Set2 = ?SWOT:merge(Delta, Set),

    ets:insert(?MODULE, Rep#replica{delta_set=Set2,
                                      bigset=BS2}),
    #delta{bs_delta=BSDelta, dt_delta=Delta}.

%% @doc client_remove_next - Next state function
-spec client_remove_next(S, Var, Args) -> NewS
    when S    :: eqc_statem:symbolic_state() | eqc_state:dynamic_state(),
         Var  :: eqc_statem:var() | term(),
         Args :: [term()],
         NewS :: eqc_statem:symbolic_state() | eqc_state:dynamic_state().
client_remove_next(S=#state{deltas=Deltas, deleters=Deleters}, Delta, [_EmptyOk, Replica, _RemovedElement]) ->
    S#state{deltas=[Delta | Deltas],
           deleters=Deleters++[Replica]}.

%% @doc client_remove_features - Collects a list of features of this call with these arguments.
-spec client_remove_features(S, Args, Res) -> list(any())
    when S    :: eqc_statem:dynmic_state(),
         Args :: [term()],
         Res  :: term().
client_remove_features(_S, [_EmptyOk, _To, {_Element, {_Element, []}}], _Res) ->
    [{{?MODULE, client_remove, 2}, empty}];
client_remove_features(_S, [_EmptyOk, _To, {_Element, {_Element, _Ctx}}], _Res) ->
    [{{?MODULE, client_remove, 2}, non_empty}].

%% --- Operation: client_remove ---
%% @doc client_add_pre/1 - Precondition for generation
-spec client_add_pre(S :: eqc_statem:symbolic_state()) -> boolean().
client_add_pre(#state{is_members=IsMembers}) ->
    IsMembers /= [].

%% @doc client_add_args - Argument generator
-spec client_add_args(S :: eqc_statem:symbolic_state()) -> eqc_gen:gen([term()]).
client_add_args(#state{replicas=Replicas, is_members=IsMembers}) ->
    [elements(Replicas),
     elements(IsMembers)].

%% @doc client_add_pre/2 - Precondition for client_remove
-spec client_add_pre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
client_add_pre(#state{is_members=IsMembers, replicas=Replicas}, [Replica, IsMember]) ->
    lists:member(IsMember, IsMembers) andalso lists:member(Replica, Replicas).

%% @doc client_add - The actual operation
client_add(To, {Element, {Element, Ctx}}) ->
    [#replica{id=To, delta_set=Set,
              bigset=BS}=ToRep] = ets:lookup(?MODULE, To),

    {BSDelta, BS2} = bigset_model:add(Element, To, Ctx, BS),
    {ok, Delta} = ?SWOT:delta_update({add, Element, Ctx}, To, Set),
    Set2 = ?SWOT:merge(Delta, Set),

    ets:insert(?MODULE, ToRep#replica{delta_set=Set2,
                                      bigset=BS2}),
    #delta{bs_delta=BSDelta, dt_delta=Delta}.

%% @doc client_add_next - Next state function
-spec client_add_next(S, Var, Args) -> NewS
    when S    :: eqc_statem:symbolic_state() | eqc_state:dynamic_state(),
         Var  :: eqc_statem:var() | term(),
         Args :: [term()],
         NewS :: eqc_statem:symbolic_state() | eqc_state:dynamic_state().
client_add_next(S=#state{adds=Adds, deltas=Deltas}, Delta, [_Replica, {Element, _}]) ->
    S#state{adds=lists:umerge(Adds, [Element]),
            deltas=[Delta | Deltas]}.

%% @doc client_add_features - Collects a list of features of this call with these arguments.
-spec client_add_features(S, Args, Res) -> list(any())
    when S    :: eqc_statem:dynmic_state(),
         Args :: [term()],
         Res  :: term().
client_add_features(_S, [_To, {_Element, {_Element, []}}], _Res) ->
    [{{?MODULE, client_add, 2}, empty}];
client_add_features(_S, [_To, {_Element, {_Element, _Ctx}}], _Res) ->
    [{{?MODULE, client_add, 2}, non_empty}].


%% @TODO do we need two is_member? One for removes (with a high-prob
%% of having a ctx And one without, so we can _always_ add?

%% --- Operation: is_member ---
%% %% @doc is_member_pre/1 - Precondition for generation
-spec is_member_pre(S :: eqc_statem:symbolic_state()) -> boolean().
is_member_pre(#state{replicas=Replicas}) ->
    Replicas /= [].

%% @doc is_member_args - Argument generator
-spec is_member_args(S :: eqc_statem:symbolic_state()) -> eqc_gen:gen([term()]).
is_member_args(#state{replicas=Replicas}) ->
    [elements(Replicas),
     growingelements(?ELEMENTS)].

%% @doc is_member_pre/2 - Precondition for is_member
-spec is_member_pre(S, Args) -> boolean()
    when S    :: eqc_statem:symbolic_state(),
         Args :: [term()].
is_member_pre(#state{replicas=Replicas}, [From, _Element]) ->
    lists:member(From, Replicas).

%% @doc is_member - The actual operation
is_member(Replica, Element) ->
    [#replica{id=Replica,
              bigset=BS}] = ets:lookup(?MODULE, Replica),

    {_Bool, Ctx} = bigset_model:is_member(Element, BS),
    {Element, Ctx}.

%% @doc is_member_next - Next state function
-spec is_member_next(S, Var, Args) -> NewS
    when S    :: eqc_statem:symbolic_state() | eqc_state:dynamic_state(),
         Var  :: eqc_statem:var() | term(),
         Args :: [term()],
         NewS :: eqc_statem:symbolic_state() | eqc_state:dynamic_state().
is_member_next(S=#state{is_members=IsMembers}, Value, [_Replica, Element]) ->
    S#state{is_members=IsMembers ++ [{Element, Value}]}.

%% @doc is_member_features - Collects a list of features of this call with these arguments.
-spec is_member_features(S, Args, Res) -> list(any())
    when S    :: eqc_statem:dynmic_state(),
         Args :: [term()],
         Res  :: term().
is_member_features(_S, [_Replica, _Element], {_Element, []}) ->
    [{{?MODULE, is_member, 2}, empty}];
is_member_features(_S, _, _) ->
    [{{?MODULE, is_member, 2}, non_empty}].

%% @doc weights for commands. Don't create too many replicas, but
%% prejudice in favour of creating more than 1. Try and balance
%% removes with adds. But favour adds so we have something to
%% remove. See the aggregation output.
weight(S, create_replica) when length(S#state.replicas) > 6 ->
    1;
weight(_S, create_replica) ->
    5;
weight(_S, remove) ->
    0;
weight(_S, add) ->
    0;
weight(_S, client_remove) ->
    10;
weight(_S, client_add) ->
    8;
weight(_S, is_member) ->
    10;
weight(_S, replicate) ->
    4;
weight(_S, compaction) ->
    4;
weight(_S, handoff) ->
    0;
weight(S, start_handoff) when length(S#state.replicas) > 5 ->
    4;
weight(S, start_handoff) when length(S#state.replicas) < 5 ->
    1;
weight(S, proceed_handoff) when length(S#state.handing_off) > 0 ->
    16;
weight(_S, _) ->
    1.

%% @doc check that the implementation of the ORSWOT is equivalent to
%% the OR-Set impl.
-spec prop_merge() -> eqc:property().
prop_merge() ->
    ?FORALL(Cmds, more_commands(100, commands(?MODULE)),
            ?TRAPEXIT(begin
                          %% Store the state external to the statem for correct
                          %% shrinking. This is best practice.
                          (catch ets:delete(?MODULE)),
                          (catch ets:delete(?HOFF_REC)),
                          ets:new(?MODULE, [public, named_table, set, {keypos, #replica.id}]),
                          ets:new(?HOFF_REC, [public, named_table, set]),
                          {H, S=#state{delivered=Delivered0, deltas=Deltas, handing_off=HOFFs}, Res} = run_commands(?MODULE,Cmds),

                          {FSMergedBigset, MergedBigset, MergedSwot, BigsetLength} =
                              lists:foldl(fun(#replica{bigset=Bigset, delta_set=ORSWOT}, {FSBS, MBS, MOS, BSLen}) ->
                                                  FSMergedBigset = bigset_model:merge(Bigset, FSBS),
                                                  BigsetCompacted = bigset_model:compact(Bigset),
                                                  ReadBigset = bigset_model:read(Bigset),
                                                  {FSMergedBigset,
                                                   bigset_model:read_merge(ReadBigset, MBS),
                                                   ?SWOT:merge(ORSWOT, MOS),
                                                   bigset_length(BigsetCompacted, BSLen)}
                                          end,
                                          {bigset_model:new(), bigset_model:new_mbs(), ?SWOT:new(), 0},
                                          ets:tab2list(?MODULE)),

                          [begin
                               unlink(Pid),
                               exit(Pid, kill)
                           end || Pid <- HOFFs],

                          Delivered = lists:flatten(Delivered0),
                          Compacted = [begin
                                           case element(1, V) of
                                               N when N == 0 ->
                                                   same;
                                               N when N < 0 ->
                                                   worse;
                                               N when N > 0 ->
                                                   better
                                           end
                                       end || V <- S#state.compacted],

                          FSCompacted = bigset_model:compact(FSMergedBigset),

                          ets:delete(?MODULE),
                          ets:delete(?HOFF_REC),
                          Completed = length([complete || {_, complete} <- call_features(proceed_handoff, H)]),
                          pretty_commands(?MODULE, Cmds, {H, S, Res},
                                          aggregate(
                                            command_names(Cmds),
                                            aggregate(
                                              with_title('Compaction Effect'), Compacted,
                                              aggregate(
                                                with_title('Context'), call_features(is_member, H),
                                                aggregate(
                                                  with_title('Context Remove'), call_features(client_remove, H),
                                                  aggregate(
                                                    with_title('Context Add'), call_features(client_add, H),
                                                    aggregate(
                                                      with_title('Complete Handoff'), call_features(proceed_handoff, H),
                                                      aggregate(
                                                        with_title('Concurrent Handoff'), call_features(start_handoff, H),
                                                        collect(with_title('Completed Hoffs'), Completed,
                                                                measure(
                                                                  deltas, length(Deltas),
                                                                  measure(
                                                                    commands, length(H),
                                                                    measure(
                                                                      delivered, length(Delivered),
                                                                      measure(
                                                                        undelivered, length(Deltas) - length(Delivered),
                                                                        measure(
                                                                          replicas, length(S#state.replicas),
                                                                          measure(
                                                                            removed_replicas, length(S#state.removed_replicas),
                                                                            measure(
                                                                              adds, length(S#state.adds),
                                                                              measure(
                                                                                bs_ln, BigsetLength,
                                                                                measure(
                                                                                  elements, length(?SWOT:value(MergedSwot)),
                                                                                  conjunction([
                                                                                               {result, Res == ok},
                                                                                               {equal, equals(sets_equal(MergedBigset, MergedSwot), true)},
                                                                                               {ts_emty, equals(bigset_model:tombstone(FSCompacted),
                                                                                                                bigset_clock:fresh())}
                                                                                              ]
                                                                                             )))))))))))))))))))


                      end)).

lmax([]) ->
    0;
lmax(L) ->
    lists:max(L).

%% calculates the lenth as if it were a bigset, basically
%% Elements*Dots
orswot_length(ORSWOT) ->
    E = ?SWOT:value(pec, ORSWOT),
    orddict:fold(fun(_E, D, Acc) ->
                         length(D) + Acc
                 end,
                 0,
                 E).

-spec compact_bigset(bigset_model:bigset()) ->
                            {integer(), bigset_model:bigset()}.
compact_bigset(BS) ->
    Before = bigset_model:size(BS),
    CompactedBigset = bigset_model:compact(BS),
    After = bigset_model:size(CompactedBigset),
    {CompactedBigset, Before-After}.

bigset_length(BS, BSLen) ->
    max(bigset_model:size(BS), BSLen).

%% @doc common precondition and property, do SWOT and Set have the
%% same elements?
sets_equal(Bigset, ORSWOT) ->
    %% What matters is that both types have the exact same results.
    BSVal = bigset_model:value(Bigset),
    ORVal = ?SWOT:value(ORSWOT),
    case lists:sort(BSVal) == lists:sort(ORVal) of
        true ->
            true;
        _ ->
            {bs, BSVal, Bigset, '/=', dt, ORVal, ORSWOT}
    end.

%% @private the value at a single replica (no need to merge, just
%% accumulate the keys)
replica_value(BS) ->
    bigset_model:value(BS).

%% @private subset generator, takes a random subset of the given set,
%% in our case a delta buffer, that some, none, or all of, will be
%% flushed.
subset(Set) ->
    ?LET(Keep, vector(length(Set), bool()), %%frequency([{1, false}, {2, true}])),
         return([ X || {X, true}<-lists:zip(Set, Keep)])).

post_equals(_Replica) ->
    true.

%% Helper functions

%% @private bigset_handoff_worker
bigset_handoff_worker(HoffState=#hoff_state{receiver=To,
                                            keys=Keys,
                                            sender_clock=SenderClock,
                                            sender=Sender,
                                            tracker=Tracker}) ->
    receive
        {proceed, Pid} ->
            [#replica{id=To, delta_set=ToSet,
                      bigset=ToBS}=ToRep] = ets:lookup(?MODULE, To),
            [#replica{id=Sender, delta_set=FromSet}] = ets:lookup(?MODULE, Sender),

            {HoffComplete, HoffState2} = case Keys of
                             [] ->
                                 {{undefined, empty}, HoffState};
                             [end_key] ->
                                 ToBS2 = bigset_model:receive_end_key(SenderClock, Tracker, ToBS),
                                 ToSet2 = ?SWOT:merge(ToSet, FromSet),

                                 ets:insert(?MODULE, ToRep#replica{bigset=ToBS2, delta_set=ToSet2}),
                                 ets:delete(?HOFF_REC, Sender),
                                 {{end_key, complete}, HoffState#hoff_state{keys=[]}};
                             [{_E, A, C}=K | T] ->
                                 Dot = {A, C},
                                 T2 = bigset_clock:add_dot(Dot, Tracker),
                                 ToBS2 = bigset_model:receive_handoff_key(K, ToBS),
                                 ets:insert(?MODULE, ToRep#replica{bigset=ToBS2}),
                                 {{K, incomplete}, HoffState#hoff_state{tracker=T2, keys=T}}
                         end,

            Pid ! {ok, HoffComplete,  self()},
            bigset_handoff_worker(HoffState2);
        {restart, Pid} ->
            Pid ! {ok, self()},
            bigset_handoff_worker(HoffState)
    after 60000 ->
            ok
    end.

-endif.
