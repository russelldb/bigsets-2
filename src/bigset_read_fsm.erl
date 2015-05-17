%%%-------------------------------------------------------------------
%%% @author Russell Brown <russelldb@basho.com>
%%% @copyright (C) 2015, Russell Brown
%%% @doc
%%%
%%% @end
%%% Created : 12 Jan 2015 by Russell Brown <russelldb@basho.com>
%%%-------------------------------------------------------------------
-module(bigset_read_fsm).

-behaviour(gen_fsm).

-include("bigset.hrl").

%% API
-export([start_link/4]).

%% gen_fsm callbacks
-export([init/1, prepare/2,  validate/2, read/2,
         await_clocks/2, await_elements/2, reply/2, handle_event/3,
         handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-define(SERVER, ?MODULE).

-record(state, {req_id :: reqid(),
                from :: pid(),
                set :: binary(),
                preflist :: riak_core_apl:preflist(),
                %% default to r=2 for demo/proto, defaults to
                %% basic_quorum=false and notfound_ok=true, too
                logic = bigset_read_core:new(2),
                options=[] :: list(),
                timer=undefined :: reference() | undefined,
                reply = undefined,
                encoder %% for encoding context and dots
               }).

-type state() :: #state{}.
-type result() :: {message(), partition(), from()}.
-type message() :: not_found | {clock, clock()} |
                   done | {elements, elements()}.
-type from() :: {pid(), reference()}.
-type elements() :: [{Member :: binary(), [Dot :: riak_dt_vclock:dot()]}].
-type clock() :: bigset_clock:clock().
-type partition() :: non_neg_integer().
-type reqid() :: term().

-define(DEFAULT_TIMEOUT, 60000).

%%%===================================================================
%%% API
%%%===================================================================

start_link(ReqId, From, Set, Options) ->
    gen_fsm:start_link(?MODULE, [ReqId, From, Set, Options], []).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================
init([ReqId, From, Set, Options]) ->
    {ok, prepare, #state{req_id=ReqId, from=From, set=Set, options=Options}, 0}.

-spec prepare(timeout, state()) -> {next_state, validate, state(), 0}.
prepare(timeout, State) ->
    #state{options=Options, set=Set} = State,
    Hash = riak_core_util:chash_key({bigset, Set}),
    PL = riak_core_apl:get_apl(Hash, 3, bigset),
    Timeout = proplists:get_value(timeout, Options, ?DEFAULT_TIMEOUT),
    TRef = schedule_timeout(Timeout),
    {next_state, validate, State#state{preflist=PL, timer=TRef}, 0}.

-spec validate(timeout | request_timeout, state()) ->
                      {next_state, coordinate | reply, state(), 0}.
validate(request_timeout, State) ->
        {next_state, reply, State#state{reply={error, timeout}}};
validate(timeout, State) ->
    #state{preflist=PL} = State,
    case length(PL) of
        N when N < 2 ->
            {next_state, reply, State#state{reply={error, too_few_vnodes}}, 0};
        _ ->
            {next_state, read, State, 0}
    end.

-spec read(timeout, state()) -> {next_state, await_clocks, state()}.
read(request_timeout, State) ->
    {next_state, reply, State#state{reply={error, timeout}}, 0};
read(timeout, State) ->
    #state{preflist=PL, set=Set} = State,
    Req = ?READ_REQ{set=Set},
    bigset_vnode:read(PL, Req),
    {next_state, await_clocks, State}.

-spec await_clocks(result(), state()) -> {next_state, reply, state(), 0} |
                                         {next_state, await_clocks, state()} |
                                         {next_state, await_elements, state()}.
await_clocks(request_timeout, State) ->
    {next_state, reply, State#state{reply={error, timeout}}, 0};
await_clocks({{clock, Clock}, Partition, From}, State) ->
    ack(From),
    #state{logic=Core} = State,
    Core2 = bigset_read_core:clock(Partition, Clock, Core),
    lager:debug("ac::: got clock from ~p~n", [Partition]),
    case bigset_read_core:r_clocks(Core2) of
        true ->
            lager:debug("ac::: nuff clocks, moving to elements~n"),
            {CtxClock, Core3} = bigset_read_core:get_clock(Core2),
            CtxDict = bigset_ctx_codec:new_encoder(CtxClock),
            ReplyCtx = bigset_ctx_codec:dict_ctx(CtxDict),
            send_reply({ok, {ctx, ReplyCtx}}, State),
            {next_state, await_elements, State#state{logic=Core3, encoder=CtxDict}};
        false ->
            lager:debug("ac::: need more clocks~n"),
            {next_state, await_clocks, State#state{logic=Core2}}
    end;
await_clocks({{elements, Elements}, Partition, From}, State) ->
    lager:debug("ac::: got ~p elements from ~p~n", [length(Elements), Partition]),
    ack(From),
    #state{logic=Core} = State,
    {undefined, Core2} = bigset_read_core:elements(Partition, Elements, Core),
    {next_state, await_clocks, State#state{logic=Core2}};
await_clocks({done, Partition, _From}, State) ->
    #state{logic=Core} = State,
    Core2 = bigset_read_core:done(Partition, Core),
    lager:debug("ac::: done ~p~n", [Partition]),
    {next_state, await_clocks, State#state{logic=Core2}};
await_clocks({not_found, Partition, _From}, State) ->
    lager:debug("ac::: notfound  ~p~n", [Partition]),
    #state{logic=Core} = State,
    Core2 = bigset_read_core:not_found(Partition, Core),
    %% @TODO(rdb|ugly) eugh, maybe read_core should return the state,
    %% eh?
    case {bigset_read_core:not_found(Core2),
          bigset_read_core:r_clocks(Core2)} of
        {true, false} ->
            {next_state, reply, State#state{reply={error, not_found}}, 0};
        {false, false} ->
            {next_state, await_clocks, State#state{logic=Core2}};
        {false, true} ->
            {next_state, await_elements, State#state{logic=Core2}}
    end.

-spec await_elements(result(), state()) ->
                        {next_state, reply, state(), 0} |
                        {next_state, await_elements, state()}.
await_elements(request_timeout, State) ->
    {next_state, reply, State#state{reply={error, timeout}}, 0};
await_elements({not_found, Partition, _From}, State) ->
    %% quite literally do not care!
    lager:debug("ae::: notfound  ~p~n", [Partition]),
    {next_state, await_elements, State};
await_elements({{clock, _Clock}, Partition, From}, State) ->
    %% Too late to take part in R, stop folding, buddy!
    lager:debug("ae::: got clock from ~p~n", [Partition]),
    stop_fold(From),
    {next_state, await_elements, State};
await_elements({{elements, Elements}, Partition, From}, State) ->
    ack(From),
    lager:debug("ae::: got ~p elements from ~p~n", [length(Elements), Partition]),
    #state{logic=Core} = State,
    {Send, Core2} = bigset_read_core:elements(Partition, Elements, Core),
    lager:debug("ae:: I can send ~p~n", [message_length(Send)]),
    maybe_send_results(Send, State),
    State2 = State#state{logic=Core2},
    {next_state, await_elements, State2};
await_elements({done, Partition, _From}, State) ->
    #state{logic=Core} = State,
    lager:debug("ae::: done ~p~n", [Partition]),
    Core2 = bigset_read_core:done(Partition, Core),
    State2 = State#state{logic=Core2},
    case bigset_read_core:is_done(Core2) of
        true ->
            FinalElements = bigset_read_core:finalise(Core2),
            lager:debug("sending final elements ~p~n",[FinalElements]),
            maybe_send_results(FinalElements, State),
            Reply = done,
            {next_state, reply, State2#state{reply=Reply}, 0};
        false ->
            {next_state, await_elements, State2}
    end.

message_length(undefined) ->
    0;
message_length(L) when is_list(L) ->
    length(L).

maybe_send_results(undefined, _State) ->
    ok;
maybe_send_results([], _State) ->
    ok;
maybe_send_results(Results, State) ->
    %% @TODO(rdb|optimise) It's a shame to have to iterate the list of
    %% elements AGAIN here to encode the per element ctx
    #state{encoder=Dict} = State,
    lager:debug("fsm:: encoding results"),
    Encoded = lists:map(fun({E, Dots}) ->
                                %% We have a complete encoder dict
                                %% from the clock, so we do not need
                                %% to keep the updated state,
                                %% otherwise would use a fold
                                lager:debug("encoding ~p", [{E, Dots}]),
                                {DotsBin, _NewEncoder} = bigset_ctx_codec:encode_dots(Dots, Dict),
                                lager:debug("encoded ~p", [{E, DotsBin}]),
                                {E, DotsBin}
                        end,
                        Results),
    lager:debug("fsm::: send encoded elems"),
    send_reply({ok, {elems, Encoded}}, State).

send_reply(Reply, State) ->
    #state{from=From, req_id=ReqId} = State,
    From ! {ReqId, Reply}.

-spec reply(timeout, State) -> {stop, normal, State}.
reply(_, State) ->
    #state{from=From, req_id=ReqId, reply=Reply} = State,
    lager:debug("reply::: sending"),
    From ! {ReqId, Reply},
    {stop, normal, State}.

handle_event(_Event, _StateName, State) ->
    {stop, badmsg, State}.

handle_sync_event(_Event, _From, _StateName, State) ->
    {stop, badmsg, State}.

handle_info(request_timeout, StateName, StateData) ->
    ?MODULE:StateName(request_timeout, StateData);
handle_info(_Info, _StateName, State) ->
    {stop, badmsg, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
schedule_timeout(infinity) ->
    undefined;
schedule_timeout(Timeout) ->
    erlang:send_after(Timeout, self(), request_timeout).

-spec ack(From::{pid(), reference()}) -> term().
ack({Pid, Ref}) ->
    Pid ! {Ref, ok}.

stop_fold({Pid, Ref}) ->
    Pid ! {Ref, stop_fold}.