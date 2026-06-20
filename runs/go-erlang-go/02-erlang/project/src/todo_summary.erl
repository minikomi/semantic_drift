-module(todo_summary).
-export([main/1]).

main([Url]) ->
    case run(Url) of
        ok ->
            ok;
        {error, Message} ->
            io:format(standard_error, "~s~n", [Message]),
            halt(1)
    end;
main(_) ->
    Script = filename:basename(escript:script_name()),
    io:format(standard_error, "usage: ~s <todos-url>~n", [Script]),
    halt(1).

run(Url) ->
    application:ensure_all_started(hackney),
    Options = [{connect_timeout, 10000}, {recv_timeout, 10000}],
    case hackney:get(Url, [], <<>>, Options) of
        {ok, Status, _Headers, ClientRef} when Status >= 200, Status < 300 ->
            case hackney:body(ClientRef) of
                {ok, Body} ->
                    handle_body(Body);
                {error, Reason} ->
                    {error, format_reason(Reason)}
            end;
        {ok, Status, ReasonPhrase, ClientRef} ->
            _ = hackney:body(ClientRef),
            {error, "bad status: " ++ integer_to_list(Status) ++ " " ++ reason_phrase(ReasonPhrase)};
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

handle_body(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Todos when is_list(Todos) ->
            Today = today(),
            Rows = summarize(Todos, Today),
            print_rows(Rows),
            ok
    catch
        error:Reason ->
            {error, format_reason(Reason)};
        throw:Reason ->
            {error, format_reason(Reason)}
    end.

today() ->
    {Date, _Time} = calendar:local_time(),
    Date.

summarize(Todos, Today) ->
    ByUser = lists:foldl(fun(Todo, Acc) -> add_todo(Todo, Today, Acc) end, #{}, Todos),
    Rows = maps:values(ByUser),
    lists:sort(fun row_before/2, Rows).

add_todo(Todo, Today, Acc) ->
    UserID = maps:get(<<"userId">>, Todo),
    Completed = maps:get(<<"completed">>, Todo),
    Current = maps:get(UserID, Acc, #{user_id => UserID, completed => 0, missed => 0}),
    Updated =
        case Completed of
            true ->
                Current#{completed := maps:get(completed, Current) + 1};
            false ->
                DueDate = parse_date(maps:get(<<"dueDate">>, Todo)),
                case DueDate < Today of
                    true ->
                        Current#{missed := maps:get(missed, Current) + 1};
                    false ->
                        Current
                end
        end,
    Acc#{UserID => Updated}.

parse_date(Bin) when is_binary(Bin), byte_size(Bin) =:= 10 ->
    try
        <<YBin:4/binary, "-", MBin:2/binary, "-", DBin:2/binary>> = Bin,
        Y = binary_to_integer(YBin),
        M = binary_to_integer(MBin),
        D = binary_to_integer(DBin),
        case calendar:valid_date({Y, M, D}) of
            true -> {Y, M, D};
            false -> erlang:error({bad_date, Bin})
        end
    catch
        _:_ -> erlang:error({bad_date, Bin})
    end;
parse_date(Bin) ->
    erlang:error({bad_date, Bin}).

row_before(A, B) ->
    ACompleted = maps:get(completed, A),
    BCompleted = maps:get(completed, B),
    AMissed = maps:get(missed, A),
    BMissed = maps:get(missed, B),
    AUser = maps:get(user_id, A),
    BUser = maps:get(user_id, B),
    case ACompleted =/= BCompleted of
        true -> ACompleted > BCompleted;
        false ->
            case AMissed =/= BMissed of
                true -> AMissed > BMissed;
                false -> AUser =< BUser
            end
    end.

print_rows(Rows) ->
    io:format("USER  COMPLETED  MISSED~n"),
    lists:foreach(
      fun(Row) ->
          io:format("~-5w ~-10w ~w~n",
                    [maps:get(user_id, Row), maps:get(completed, Row), maps:get(missed, Row)])
      end,
      Rows).

reason_phrase(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
reason_phrase(List) when is_list(List) ->
    List;
reason_phrase(Other) ->
    format_reason(Other).

format_reason(Reason) ->
    lists:flatten(io_lib:format("~p", [Reason])).

