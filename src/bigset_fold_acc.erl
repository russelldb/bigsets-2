-module(bigset_fold_acc).

-compile([export_all]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(fold_acc,
        {
          not_found = true,
          partition :: pos_integer(),
          set :: binary(),
          sender :: riak_core:sender(),
          buffer_size :: pos_integer(),
          size=0 :: pos_integer(),
          monitor :: reference(),
          me = self() :: pid(),
          current_elem :: binary(),
          current_actor :: binary(),
          current_cnt :: pos_integer(),
          current_tsb :: <<_:1>>,
          elements = []
        }).

-define(ADD, <<0:1>>).
-define(REM, <<1:1>>).

send(Message, Acc) ->
    #fold_acc{sender=Sender, me=Me, monitor=Mon, partition=Partition} = Acc,
    riak_core_vnode:reply(Sender, {Message, Partition, {Me, Mon}}).

new(Set, Sender, BufferSize, Partition) ->
    Monitor = riak_core_vnode:monitor(Sender),
    #fold_acc{set=Set,
              sender=Sender,
              monitor=Monitor,
              buffer_size=BufferSize-1,
              partition=Partition}.

%% @doc called by eleveldb:fold per key read. Uses `throw({break,
%% Acc})' to break out of fold when last key is read.
fold({Key, Value}, Acc) ->
    #fold_acc{set=Set} = Acc,
    case bigset:decode_key(Key) of
        {s, Set, clock} ->
            %% Set clock, send at once!
            Clock = bigset:from_bin(Value),
            send({clock, Clock}, Acc),
            Acc#fold_acc{not_found=false};
        {s, Set, Element, Actor, Cnt, TSB} ->
            add(Element, Actor, Cnt, TSB, Acc);
        _ ->
            %% Can finalise here, you know?!
            throw({break, Acc})
    end.

%% @private leveldb compaction will do this too, but since we may
%% always have lower `Cnt' writes for any `Actor' or a tombstone for
%% any write, we only accumulate writes for an `Element' that are the
%% highst `Cnt' for that `Element' and `Actor' and that are not
%% deleted, which is shown as a `TSB' (Tombstone Bit) of `1'
add(Element, Actor, Cnt, TSB, Acc=#fold_acc{current_elem=Element,
                                            current_actor=Actor}) ->
    %% If this Element is the same as current and this actor is the
    %% same as the current the count is greater or the TSB is set, add
    %% current cnt, and tsb.
    Acc#fold_acc{current_cnt=Cnt, current_tsb=TSB};
add(Element, Actor, Cnt, TSB, Acc=#fold_acc{current_tsb=?ADD}) ->

    %% If this element or actor is different look at TSB. TSB is 0 add
    %% {element, {Actor, Cnt} to elements and set current actor,
    %% current cnt, current tsb
    Acc2 = store_element(Acc),
    Acc3 = maybe_flush(Acc2),
    Acc3#fold_acc{current_cnt=Cnt, current_elem=Element,
                  current_actor=Actor, current_tsb=TSB};

add(Element, NewActor, Cnt, TSB, Acc=#fold_acc{current_tsb=?REM}) ->

    %% If this element or the actor is different look at TSB. TSB is
    %% 1, do not add to Elements.
    Acc#fold_acc{current_cnt=Cnt, current_elem=Element,
                 current_actor=NewActor, current_tsb=TSB};
add(Element, Actor, Cnt, TSB, Acc=#fold_acc{}) ->
    Acc#fold_acc{current_elem=Element,
                 current_actor=Actor,
                 current_cnt=Cnt,
                 current_tsb=TSB}.

%% @private add an element to the accumulator.
store_element(Acc) ->
    #fold_acc{current_actor=Actor,
              current_cnt=Cnt,
              current_elem=Elem,
              elements=Elements,
              size=Size} = Acc,
    Elements2 = case Elements of
                    [{Elem, Dots} | Rest] ->
                        [{Elem, lists:umerge([{Actor, Cnt}], Dots)}
                         | Rest];
                    L ->
                        [{Elem, [{Actor, Cnt}]} | L]
                end,
    Acc#fold_acc{elements=Elements2, size=Size+1}.

%% @private if the buffer is full, flush!
maybe_flush(Acc=#fold_acc{size=Size, buffer_size=Size}) ->
    flush(Acc);
maybe_flush(Acc) ->
    Acc.

%% @private send the accumulated elements
flush(Acc) ->
    %% send the message, but only if our last message was acked, or
    %% the reciever is still there!

    %% @TODO bikeshed this. Should we 1. not continue folding until
    %% last message is acked (saves cluster resources maybe) or
    %% 2. continue fold, but do not send result until message is
    %% acked, seems to me this gives us time to fold while message is
    %% in flight, read, acknowledged)
    #fold_acc{elements=Elements, monitor=Monitor, partition=Partition} = Acc,
    receive
        {Monitor, ok} ->
            send({elements, lists:reverse(Elements)}, Acc),
            Acc#fold_acc{size=0, elements=[]};
        {Monitor, stop_fold} ->
            lager:debug("told to stop~p~n", [Partition]),
            close(Acc),
            throw(stop_fold);
        {'DOWN', Monitor, process, _Pid, _Reson} ->
            lager:debug("got down~p~n", [Partition]),
            close(Acc),
            throw(receiver_down)
    end.

%% @private folding is over (if it ever really began!), call this with
%% the final Accumulator.
finalise(Acc=#fold_acc{not_found=true}) ->
    send(not_found, Acc),
    done(Acc);
finalise(Acc=#fold_acc{current_tsb=?REM}) ->
    done(Acc);
finalise(Acc=#fold_acc{current_tsb=?ADD}) ->
    AccFinal = store_element(Acc),
    done(AccFinal).

%% @private let the caller know we're done.
done(Acc0) ->
    Acc = flush(Acc0),
    send(done, Acc),
    close(Acc).

%% @private demonitor
close(Acc) ->
    #fold_acc{monitor=Monitor} = Acc,
    erlang:demonitor(Monitor, [flush]).

-ifdef(TEST).
%% add_test() ->
%%     Acc2 = add(<<"A">>, <<"b">>, 1, <<0:1>>, new()),
%%     ?assertEqual(#fold_acc{current_elem= <<"A">>,
%%                            current_actor= <<"b">>,
%%                            current_cnt= 1,
%%                            current_tsb= <<0:1>>}, Acc2),
%%     Acc3 = add(<<"A">>, <<"b">>, 4, <<0:1>>, Acc2),
%%     ?assertEqual(#fold_acc{current_elem= <<"A">>,
%%                            current_actor= <<"b">>,
%%                            current_cnt= 4,
%%                            current_tsb= <<0:1>>}, Acc3),
%%     Acc4 = add(<<"A">>, <<"c">>, 99, <<0:1>>, Acc3),
%%     ?assertEqual(#fold_acc{current_elem= <<"A">>,
%%                            current_actor= <<"c">>,
%%                            current_cnt= 99,
%%                            current_tsb= <<0:1>>,
%%                            elements=[{<<"A">>, [{<<"b">>, 4}]}]}, Acc4),
%%     Acc5 = add(<<"A">>, <<"c">>, 99, <<1:1>>, Acc4),
%%     ?assertEqual(#fold_acc{current_elem= <<"A">>,
%%                            current_actor= <<"c">>,
%%                            current_cnt= 99,
%%                            current_tsb= <<1:1>>,
%%                            elements=[{<<"A">>, [{<<"b">>, 4}]}]}, Acc5),
%%     Acc6 = add(<<"A">>, <<"c">>, 100, <<0:1>>, Acc5),
%%     ?assertEqual(#fold_acc{current_elem= <<"A">>,
%%                            current_actor= <<"c">>,
%%                            current_cnt= 100,
%%                            current_tsb= <<0:1>>,
%%                            elements=[{<<"A">>, [{<<"b">>, 4}]}]}, Acc6),
%%     Acc7 = add(<<"A">>, <<"c">>, 103, <<1:1>>, Acc6),
%%     ?assertEqual(#fold_acc{current_elem= <<"A">>,
%%                            current_actor= <<"c">>,
%%                            current_cnt= 103,
%%                            current_tsb= <<1:1>>,
%%                            elements=[{<<"A">>, [{<<"b">>, 4}]}]}, Acc7),
%%     Acc8 = add(<<"A">>, <<"d">>, 3, <<0:1>>, Acc7),
%%     ?assertEqual(#fold_acc{current_elem= <<"A">>,
%%                            current_actor= <<"d">>,
%%                            current_cnt= 3,
%%                            current_tsb= <<0:1>>,
%%                            elements=[{<<"A">>, [{<<"b">>, 4}]}]}, Acc8),
%%     Acc9 = add(<<"Z">>, <<"a">>, 12, <<0:1>>, Acc8),
%%     ?assertEqual(#fold_acc{current_elem= <<"Z">>,
%%                            current_actor= <<"a">>,
%%                            current_cnt= 12,
%%                            current_tsb= <<0:1>>,
%%                            elements=[{<<"A">>, [{<<"b">>, 4},
%%                                                 {<<"d">>, 3}]}]}, Acc9),
%%     Acc10 = add(<<"ZZ">>, <<"b">>, 19, <<1:1>>, Acc9),
%%     ?assertEqual(#fold_acc{current_elem= <<"ZZ">>,
%%                            current_actor= <<"b">>,
%%                            current_cnt= 19,
%%                            current_tsb= <<1:1>>,
%%                            elements=[{<<"Z">>, [{<<"a">>, 12}]},
%%                                      {<<"A">>, [{<<"b">>, 4},
%%                                                 {<<"d">>, 3}]}
%%                                     ]}, Acc10),
%%     ?assertEqual([{<<"A">>, [{<<"b">>, 4},
%%                              {<<"d">>, 3}]},
%%                   {<<"Z">>, [{<<"a">>, 12}]}],
%%                  finalise(Acc10)),
%%     Acc11 = add(<<"ZZ">>, <<"b">>, 19, <<0:1>>, Acc9),
%%     ?assertEqual([{<<"A">>, [{<<"b">>, 4},
%%                              {<<"d">>, 3}]},
%%                   {<<"Z">>, [{<<"a">>, 12}]},
%%                   {<<"ZZ">>, [{<<"b">>, 19}]}],
%%                  finalise(Acc11)).

-endif.