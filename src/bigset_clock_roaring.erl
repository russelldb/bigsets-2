%%% @author Russell Brown <russelldb@basho.com>
%%% @copyright (C) 2015, Russell Brown
%%% @doc
%%%
%%% @end
%%% Created :  8 Jan 2015 by Russell Brown <russelldb@basho.com>

-module(bigset_clock_roaring).

-behaviour(bigset_gen_clock).

-export([add_dot/2,
         add_dots/2,
         all_nodes/1,
         complement/2,
         descends/2,
         dominates/2,
         equal/2,
         fresh/0,
         fresh/1,
         get_dot/2,
         increment/2,
         intersection/2,
         is_compact/1,
         merge/1,
         merge/2,
         seen/2,
         subtract_seen/2,
         to_bin/1
        ]).

-compile(export_all).

-export_type([clock/0, dot/0]).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([make_dotcloud_entry/3]).
-endif.

%% lazy inefficient dot cloud of dict Actor->[count()]
-type actor() :: riak_dt_vclock:actor().
-type clock() :: {riak_dt_vclock:vclock(), [riak_dt:dot()]}.
-type dot() :: riak_dt:dot().
-type dotcloud() :: [{riak_dt_vclock:actor(), [pos_integer()]}].

-define(DICT, orddict).

-spec to_bin(clock()) -> binary().
to_bin({Base, DC}) ->
    BaseBin = term_to_binary(Base),
    Len = byte_size(BaseBin),
    Bin = <<Len:32/integer, BaseBin/binary>>,
    orddict:fold(fun(Actor, Dots, BinAcc) ->
                         Compressed = Dots, %%bigset_roaring:compress(Dots),
                         io:format("~p is it me crasher?~n", [?LINE]),
                         RoaringBin =  term_to_binary(bigset_roaring:serialize(Compressed), [ compressed ]),
                         io:format("~p is it me crasher?~n", [?LINE]),
                         RLen = byte_size(RoaringBin),
                         io:format("~p is it me crasher?~n", [?LINE]),
                         ActorLen = byte_size(Actor),
                         <<BinAcc/binary, ActorLen:32/integer, Actor:ActorLen/binary,
                           Len:32/integer, RoaringBin:RLen/binary>>
                 end,
                 Bin,
                 DC).

-spec fresh() -> clock().
fresh() ->
    {riak_dt_vclock:fresh(), ?DICT:new()}.

fresh({Actor, Cnt}) ->
    {riak_dt_vclock:fresh(Actor, Cnt), ?DICT:new()}.

%% @doc increment the entry in `Clock' for `Actor'. Return the new
%% Clock, and the `Dot' of the event of this increment. Works because
%% for any actor in the clock, the assumed invariant is that all dots
%% for that actor are contiguous and contained in this clock (assumed
%% therefore that `Actor' stores this clock durably after increment,
%% see riak_kv#679 for some real world issues, and mitigations that
%% can be added to this code.)
-spec increment(actor(), clock()) ->
                       {dot(), clock()}.
increment(Actor, {Clock, Seen}) ->
    Clock2 = riak_dt_vclock:increment(Actor, Clock),
    Cnt = riak_dt_vclock:get_counter(Actor, Clock2),
    {{Actor, Cnt}, {Clock2, Seen}}.

get_dot(Actor, {Clock, _Dots}) ->
    {Actor, riak_dt_vclock:get_counter(Actor, Clock)}.

all_nodes({Clock, Dots}) ->
    %% NOTE the riak_dt_vclock:all_nodes/1 returns a sorted list
    lists:usort(lists:merge(riak_dt_vclock:all_nodes(Clock),
                 ?DICT:fetch_keys(Dots))).

-spec merge(clock(), clock()) -> clock().
merge({VV1, Seen1}, {VV2, Seen2}) ->
    VV = riak_dt_vclock:merge([VV1, VV2]),
    Seen = ?DICT:merge(fun(_Key, S1, S2) ->
                               bigset_roaring:union(S1, S2)
                       end,
                       Seen1,
                       Seen2),
    compress_seen(VV, Seen).

merge(Clocks) ->
    lists:foldl(fun merge/2,
                fresh(),
                Clocks).

%% @doc make a bigset clock from a version vector
-spec from_vv(riak_dt_vclock:vclock()) -> clock().
from_vv(Clock) ->
    {Clock, ?DICT:new()}.

%% @doc given a `Dot :: riak_dt:dot()' and a `Clock::clock()',
%% add the dot to the clock. If the dot is contiguous with events
%% summerised by the clocks VV it will be added to the VV, if it is an
%% exception (see DVV, or CVE papers) it will be added to the set of
%% gapped dots. If adding this dot closes some gaps, the seen set is
%% compressed onto the clock.
-spec add_dot(dot(), clock()) -> clock().
add_dot(Dot, {Clock, Seen}) ->
    Seen2 = add_dot_to_cloud(Dot, Seen),
    compress_seen(Clock, Seen2).

add_dot_to_cloud({Actor, Cnt}, Cloud) ->
    ?DICT:update(Actor,
                 fun(Dots) ->
                         bigset_roaring:add(Cnt, Dots)
                 end,
                 [Cnt],
                 Cloud).

%% @doc given a list of `dot()' and a `Clock::clock()',
%% add the dots from `Dots' to the clock. All dots contiguous with
%% events summerised by the clocks VV it will be added to the VV, any
%% exceptions (see DVV, or CVE papers) will be added to the set of
%% gapped dots. If adding a dot closes some gaps, the seen set is
%% compressed onto the clock.
-spec add_dots([dot()], clock()) -> clock().
add_dots(Dots, {Clock, Seen}) ->
    Seen2 = lists:foldl(fun add_dot_to_cloud/2,
                        Seen,
                        Dots),
    compress_seen(Clock, Seen2).

-spec seen(dot(), clock()) -> boolean().
seen({Actor, Cnt}=Dot, {Clock, Seen}) ->
    (riak_dt_vclock:descends(Clock, [Dot]) orelse
     bigset_roaring:member(Cnt, fetch_dot_list(Actor, Seen))).

fetch_dot_list(Actor, Seen) ->
    case ?DICT:find(Actor, Seen) of
        error ->
            bigset_roaring:new();
        {ok, L} ->
            L
    end.

%% Remove dots seen by `Clock' from `Dots'. Return a list of `dot()'
%% unseen by `Clock'. Return `[]' if all dots seens.
subtract_seen(Clock, Dots) ->
    %% @TODO(rdb|optimise) this is maybe a tad inefficient.
    lists:filter(fun(Dot) ->
                         not seen(Dot, Clock)
                 end,
                 Dots).

%% Remove `Dots' from `Clock'. Any `dot()' in `Dots' that has been
%% seen by `Clock' is removed from `Clock', making the `Clock' un-see
%% the event.
subtract(Clock, Dots) ->
    lists:foldl(fun(Dot, Acc) ->
                        subtract_dot(Acc, Dot) end,
                Clock,
                Dots).

%% Remove an event `dot()' `Dot' from the clock() `Clock', effectively
%% un-see `Dot'.
subtract_dot(Clock, Dot) ->
    {VV, DotCloud} = Clock,
    {Actor, Cnt} = Dot,
    DotList = fetch_dot_list(Actor, DotCloud),
    case bigset_roaring:member(Cnt, DotList) of
        %% Dot in the dot cloud, remove it
        true ->
            {VV, delete_dot(Dot, DotList, DotCloud)};
        false ->
            %% Check the clock
            case riak_dt_vclock:get_counter(Actor, VV) of
                N when N >= Cnt ->
                    %% Dot in the contiguous counter Remove it by
                    %% adding > cnt to the Dot Cloud, and leaving
                    %% less than cnt in the base
                    NewBase = Cnt-1,
                    NewDots = lists:seq(Cnt+1, N),
                    NewVV = riak_dt_vclock:set_counter(Actor, NewBase, VV),
                    NewDC = case NewDots of
                                [] ->
                                    DotCloud;
                                _ ->
                                    orddict:store(Actor, bigset_roaring:add_all(NewDots, DotList), DotCloud)
                            end,
                    {NewVV, NewDC};
                _ ->
                    %% NoOp
                    Clock
            end
    end.

delete_dot({Actor, Cnt}, DotList, DotCloud) ->
    DL2 = bigset_roaring:remove(Cnt, DotList),
    case bigset_roaring:cardinality(DL2) of
        0 ->
            orddict:erase(Actor, DotCloud);
        _ ->
            orddict:store(Actor, DL2, DotCloud)
    end.

%% @doc get the counter for `Actor' where `counter' is the maximum
%% _contiguous_ event sent by this clock (i.e. not including
%% exceptions.)
-spec get_contiguous_counter(riak_dt_vclock:actor(), clock()) ->
                                    pos_integer() | no_return().
get_contiguous_counter(Actor, {Clock, _Dots}=C) ->
    case riak_dt_vclock:get_counter(Actor, Clock) of
        0 ->
            error({badarg, actor_not_in_clock}, [Actor, C]);
        Cnt ->
            Cnt
    end.

-spec contiguous_seen(clock(), dot()) -> boolean().
contiguous_seen({VV, _Seen}, Dot) ->
    riak_dt_vclock:descends(VV, [Dot]).

compress_seen(Clock, Seen) ->
    ?DICT:fold(fun(Node, Cnts, {ClockAcc, SeenAcc}) ->
                       Cnt = riak_dt_vclock:get_counter(Node, Clock),
                       case compress(Cnt, Cnts) of
                           {Cnt, Cnts} ->
                               {ClockAcc, ?DICT:store(Node, Cnts, SeenAcc)};
                           {Cnt2, []} ->
                               {riak_dt_vclock:merge([[{Node, Cnt2}], ClockAcc]),
                                SeenAcc};
                           {Cnt2, Cnts2} ->
                               {riak_dt_vclock:merge([[{Node, Cnt2}], ClockAcc]),
                                ?DICT:store(Node, Cnts2, SeenAcc)}
                       end
               end,
               {Clock, ?DICT:new()},
               Seen).

compress(Base, BitArray) ->
    case bigset_roaring:member(Base+1, BitArray) of
        true ->
            compress(Base+1, bigset_roaring:remove(Base+1, BitArray));
        false ->
            {Base, bigset_roaring:compress(BitArray)}
    end.

%% true if A descends B, false otherwise
-spec descends(clock(), clock()) -> boolean().
descends(_, _) ->
    ok.

equal(A, B) ->
    A == B.

dominates(A, B) ->
    A == B.


%% @doc intersection is all the dots in A that are also in B. A is an
%% orddict of {actor, [dot()]} as returned by `complement/2'
-spec intersection(dotcloud(), clock()) -> clock().
intersection(_DotCloud, _Clock) ->
    ok.

%% @doc complement like in sets, only here we're talking sets of
%% events. Generates a dict that represents all the events in A that
%% are not in B. We actually assume that B is a subset of A, so we're
%% talking about B's complement in A.
%% Returns a dot-cloud
-spec complement(clock(), clock()) -> dotcloud().
complement(_, _) ->
    ok.

%% @doc Is this clock compact, i.e. no gaps/no dot-cloud entries
-spec is_compact(clock()) -> boolean().
is_compact({_Base, DC}) ->
    is_compact_dc(DC).

is_compact_dc([]) ->
    true;
is_compact_dc([{_A, DC} | Rest]) ->
    case bigset_roaring:cardinality(DC) of
        0 ->
            is_compact_dc(Rest);
        _ ->
            false
    end.

-ifdef(TEST).

%% API for comparing clock impls

%% @doc given a clock,actor and list of events, return a clock where
%% the dotcloud for the actor contains the events
-spec make_dotcloud_entry(clock(), actor(), [pos_integer()]) -> clock().
make_dotcloud_entry({Base, Seen}=_Clock, Actor, Events) ->
    {Base, orddict:store(Actor, eroaring:new(Events), Seen)}.

%% How big are clocks?
clock_size_test() ->
    bigset_gen_clock:clock_size_test(?MODULE).

crasher() ->
    Actors = [crypto:rand_bytes(24) || _ <- lists:seq(1, 1)],
    C = bigset_clock_roaring:fresh(),
    C2 =lists:foldl(fun(Actor, ClockAcc) -> {_, C2} = bigset_clock_roaring:increment(Actor, ClockAcc), C2 end, C, Actors),
    FP = bigset_gen_clock:fencepost(1000*1000),
    io:format("len ~p max ~p~n", [length(FP), lists:max(FP)]),
    C3 = lists:foldl(fun(Actor, ClockAcc) -> bigset_clock_roaring:make_dotcloud_entry(ClockAcc, Actor, FP) end, C2, Actors),
    io:format("~p is it me crasher?~n", [?LINE]),
    Bytes = bigset_clock_roaring:to_bin(C3),
    Bytes.

-endif.

