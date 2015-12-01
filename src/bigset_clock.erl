%%% @author Russell Brown <russelldb@basho.com>
%%% @copyright (C) 2015, Russell Brown
%%% @doc
%%%
%%% @end
%%% Created :  8 Jan 2015 by Russell Brown <russelldb@basho.com>

-module(bigset_clock).

-compile(export_all).

-export_type([clock/0]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% lazy inefficient dot cloud of dict Actor->[count()]
-type clock() :: {riak_dt_vclock:vclock(), [riak_dt:dot()]}.

-define(DICT, orddict).

-spec fresh() -> clock().
fresh() ->
    {riak_dt_vclock:fresh(), ?DICT:new()}.

%% @doc increment the entry in `Clock' for `Actor'. Return the new
%% Clock, and the `Dot' of the event of this increment. Works because
%% for any actor in the clock, the assumed invariant is that all dots
%% for that actor are contiguous and contained in this clock (assumed
%% therefore that `Actor' stores this clock durably after increment,
%% see riak_kv#679 for some real world issues, and mitigations that
%% can be added to this code.)
-spec increment(riak_dt_vclock:actor(), clock()) ->
                       {riak_dt_vclock:dot(), clock()}.
increment(Actor, {Clock, Seen}) ->
    Clock2 = riak_dt_vclock:increment(Actor, Clock),
    Cnt = riak_dt_vclock:get_counter(Actor, Clock2),
    {{Actor, Cnt}, {Clock2, Seen}}.

get_dot(Actor, {Clock, _Dots}) ->
    {Actor, riak_dt_vclock:get_counter(Actor, Clock)}.

all_nodes({Clock, Dots}) ->
    %% NOTE the riak_dt_vclock:all_nodes/1 returns a sorted list
    lists:umerge(riak_dt_vclock:all_nodes(Clock),
                 ?DICT:fetch_keys(Dots)).

-spec merge(clock(), clock()) -> clock().
merge({VV1, Seen1}, {VV2, Seen2}) ->
    VV = riak_dt_vclock:merge([VV1, VV2]),
    Seen = ?DICT:merge(fun(_Key, S1, S2) ->
                               lists:umerge(S1, S2)
                       end,
                       Seen1,
                       Seen2),
    compress_seen(VV, Seen).

%% @doc make a bigset clock from a version vector
-spec from_vv(riak_dt_vclock:vclock()) -> clock().
from_vv(Clock) ->
    {Clock, ?DICT:new()}.

%% @doc given a `Dot :: riak_dt_vclock:dot()' and a `Clock::clock()',
%% add the dot to the clock. If the dot is contiguous with events
%% summerised by the clocks VV it will be added to the VV, if it is an
%% exception (see DVV, or CVE papers) it will be added to the set of
%% gapped dots. If adding this dot closes some gaps, the seen set is
%% compressed onto the clock.
-spec strip_dots(riak_dt_vclock:dot(), clock()) -> clock().
strip_dots({Actor, Cnt}, {Clock, Seen}) ->
    Seen2 = ?DICT:update(Actor,
                         fun(Dots) ->
                                 lists:umerge([Cnt], Dots)
                         end,
                         [Cnt],
                         Seen),
    compress_seen(Clock, Seen2).

seen({Clock, Seen}, {Actor, Cnt}=Dot) ->
    (riak_dt_vclock:descends(Clock, [Dot]) orelse
     lists:member(Cnt, fetch_dot_list(Actor, Seen))).

fetch_dot_list(Actor, Seen) ->
    case ?DICT:find(Actor, Seen) of
        error ->
            [];
        {ok, L} ->
            L
    end.

subtract_seen(Clock, Dots) ->
    %% @TODO(rdb|optimise) this is maybe a tad inefficient.
    lists:filter(fun(Dot) ->
                         not seen(Clock, Dot)
                 end,
                 Dots).

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

-spec contiguous_seen(clock(), riak_dt_vclock:dot()) -> boolean().
contiguous_seen({VV, _Seen}, Dot) ->
    riak_dt_vclock:descends(VV, [Dot]).

compress_seen(Clock, Seen) ->
    ?DICT:fold(fun(Node, Cnts, {ClockAcc, SeenAcc}) ->
                        Cnt = riak_dt_vclock:get_counter(Node, Clock),
                        case compress(Cnt, Cnts) of
                            {Cnt, Cnts} ->
                                {ClockAcc, ?DICT:store(Node, lists:sort(Cnts), SeenAcc)};
                            {Cnt2, []} ->
                                {riak_dt_vclock:merge([[{Node, Cnt2}], ClockAcc]),
                                 SeenAcc};
                            {Cnt2, Cnts2} ->
                                {riak_dt_vclock:merge([[{Node, Cnt2}], ClockAcc]),
                                 ?DICT:store(Node, lists:sort(Cnts2), SeenAcc)}
                        end
                end,
               {Clock, ?DICT:new()},
               Seen).

compress(Cnt, []) ->
    {Cnt, []};
compress(Cnt, [Cntr | Rest]) when Cnt >= Cntr ->
    compress(Cnt, Rest);
compress(Cnt, [Cntr | Rest]) when Cntr - Cnt == 1 ->
    compress(Cnt+1, Rest);
compress(Cnt, Cnts) ->
    {Cnt, Cnts}.

%% true if A descends B, false otherwise
descends({ClockA, _DotsA}=A, {ClockB, DotsB}) ->
    riak_dt_vclock:descends(ClockA, ClockB)
        andalso
        (subtract_seen(A, orddict_to_proplist(DotsB)) == []).

equal(A, B) ->
    descends(A, B) andalso descends(B, A).

dominates(A, B) ->
    descends(A, B) andalso not descends(B, A).

%% efficiency be damned!
orddict_to_proplist(Dots) ->
    orddict:fold(fun(K, V, Acc) ->
                         Acc ++ [{K, C} || C <- V]
                 end,
                 [],
                 Dots).

-ifdef(TEST).

%% @TODO EQC of bigset_clock properties (at least
%% descends/merge/dominates/equal)

descends_test() ->
    A = B = {[{a, 1}, {b, 1}, {c, 1}], []},
    ?assert(descends(A, B)),
    ?assert(descends(B, A)),
    ?assert(descends(A, fresh())),
    C = {[{a, 1}], [{b, [3]}]},
    ?assert(not descends(A, C) andalso not descends(C, A)),
    ?assert(descends(merge(A, C), C)),
    D = {[{a, 1}, {b, 1}, {c, 1}], [{b, [3]}]},
    ?assert(descends(D, C)).

fresh_test() ->
    ?assertEqual({[], []}, fresh()).

increment_test() ->
    Clock = fresh(),
    {Dot1, Clock2} = increment(a, Clock),
    {Dot2, Clock3} = increment(b, Clock2),
    {Dot3, Clock4} = increment(a, Clock3),
    ?assertEqual({a, 1}, Dot1),
    ?assertEqual({b, 1}, Dot2),
    ?assertEqual({a, 2}, Dot3),
    ?assertEqual({[{a, 2}, {b, 1}], []}, Clock4).

get_dot_test() ->
    Clock = fresh(),
    ?assertEqual({a, 0}, get_dot(a, Clock)),
    {Dot, Clock2} = increment(a, Clock),
    ?assertEqual(Dot, get_dot(a, Clock2)).

from_vv_test() ->
    VV = [{a, 4}, {c, 45}, {z, 1}],
    ?assertEqual({VV, []}, from_vv(VV)).

all_nodes_test() ->
    Clock = from_vv([{a, 4}, {c, 45}, {z, 1}]),
    ?assertEqual([a, c, z], all_nodes(Clock)).


strip_dots_test() ->
    Clock = fresh(),
    Dot = {a, 1},
    ?assertEqual({[{a,1}], []}, strip_dots(Dot, Clock)),
    Clock1 = fresh(),
    Dot1 = {a, 34},
    ?assertEqual({[], [{a, [34]}]}, strip_dots(Dot1, Clock1)),
    Clock2 = {[{a, 3}, {b, 1}], []},
    Dot2 = {c, 2},
    Clock3 = strip_dots(Dot2, Clock2),
    ?assertEqual({[{a, 3}, {b, 1}], [{c, [2]}]}, Clock3),
    Dot3 = {a, 5},
    Clock4 = strip_dots(Dot3, Clock3),
    ?assertEqual({[{a, 3}, {b, 1}], [{a, [5]}, {c, [2]}]}, Clock4),
    Dot4 = {a, 4},
    Clock5 = strip_dots(Dot4, Clock4),
    ?assertEqual({[{a, 5}, {b, 1}], [{c, [2]}]}, Clock5),
    Dot5 = {c, 1},
    Clock6 = strip_dots(Dot5, Clock5),
    ?assertEqual({[{a, 5}, {b, 1},{c, 2}], []}, Clock6),
    Clock7 = {[{a, 1}], [{a, [3, 4, 9]}]},
    Dot6 = {a, 2},
    Clock8 = strip_dots(Dot6, Clock7),
    ?assertEqual({[{a, 4}], [{a, [9]}]}, Clock8).

%% in the case where seen dots are lower than the actual actors in the
%% VV (Say after a merge)
strip_dots_low_dot_test() ->
    Clock = {[{a, 4}, {b, 9}], [{a, [1]}, {b, [7]}]},
    Clock2 = strip_dots({a, 3}, Clock),
    ?assertEqual({[{a, 4}, {b, 9}], []}, Clock2).

seen_test() ->
    Clock = {[{a, 2}, {b, 9}, {z, 4}], [{a, [7]}, {c, [99]}]},
    ?assert(seen(Clock, {a, 1})),
    ?assert(seen(Clock, {z, 4})),
    ?assert(seen(Clock, {c, 99})),
    ?assertNot(seen(Clock, {a, 5})),
    ?assertNot(seen(Clock, {x, 1})),
    ?assertNot(seen(Clock, {c, 1})).

contiguous_counter_test() ->
    Clock = {[{a, 2}, {b, 9}, {z, 4}], [{a, [7]}, {c, [99]}]},
    ?assertEqual(2, get_contiguous_counter(a, Clock)),
    ?assertError({badarg, actor_not_in_clock}, get_contiguous_counter(c, Clock)).

merge_test() ->
    Clock = {[{a, 2}, {b, 9}, {z, 4}], [{a, [7]}, {c, [99]}]},
    Clock2 = fresh(),
    %% Idempotent
    ?assertEqual(Clock, merge(Clock, Clock)),
    ?assertEqual(Clock, merge(Clock, Clock2)),
    Clock3 = {[], [{a, [3, 4, 5, 6]}, {d, [2]}, {z, [6]}]},
    Clock4 = merge(Clock3, Clock),
    ?assertEqual({[{a, 7}, {b, 9}, {z, 4}], [{c, [99]}, {d, [2]}, {z, [6]}]},
                 Clock4),
    Clock5 = {[{a, 5}, {c, 100}, {d, 1}], [{d, [3]}, {z, [5]}]},
    ?assertEqual({[{a, 7}, {b, 9}, {c, 100}, {d, 3}, {z, 6}], []}, merge(Clock4, Clock5)),
    %% commute
    ?assertEqual(merge(Clock3, Clock), merge(Clock, Clock3)),
    %% assoc
    ?assertEqual(merge(merge(Clock3, Clock), Clock5),
                 merge(merge(Clock, Clock5), Clock3)).


-endif.
