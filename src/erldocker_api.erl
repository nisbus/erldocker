-module(erldocker_api).
-export([get/1, get/2, post/1, post/2, post/3, delete/1, delete/2]).
-export([get_stream/1, get_stream/2, post_stream/1, post_stream/2]).
-export([proplist_from_json/1, proplists_from_json/1]).

-define(ADDR, application:get_env(erldocker, docker_http, <<"http://localhost:4243">>)).
-define(OPTIONS, [{recv_timeout, infinity}]).

get(URL)               -> call(get, <<>>, URL, []).
get(URL, Args)         -> call(get, <<>>, URL, Args).
post(URL)              -> call(post, <<>>, URL, []).
post(URL, Args)        -> call(post, <<>>, URL, Args).
post(URL, Args, Body)  -> call(post, Body, URL, Args).
delete(URL)            -> call(delete, <<>>, URL, []).
delete(URL, Args)      -> call(delete, <<>>, URL, Args).
get_stream(URL)        -> call({get, stream}, <<>>, URL, []).
get_stream(URL, Args)  -> call({get, stream}, <<>>, URL, Args).
post_stream(URL)       -> call({post, stream}, <<>>, URL, []).
post_stream(URL, Args) -> call({post, stream}, <<>>, URL, Args).

call({Method, stream}, Body, URL) when is_binary(URL) andalso is_binary(Body) ->
    error_logger:info_msg("api call: ~p ~s", [{Method, stream}, binary_to_list(URL)]),
    spawn_link(fun() -> async(URL, self()) end);

call(Method, Body, URL) when is_binary(URL) andalso is_binary(Body) ->
    error_logger:info_msg("api call: ~p ~s", [Method, binary_to_list(URL)]),
    ReqHeaders = [{<<"Content-Type">>, <<"application/json">>}],
    case hackney:request(Method, URL, ReqHeaders, Body, ?OPTIONS) of
        {ok, StatusCode, RespHeaders, Client} ->
            {ok, RespBody} = hackney:body(Client),
            case StatusCode of
                X when X == 200 orelse X == 201 orelse X == 204 ->
                    case lists:keyfind(<<"Content-Type">>, 1, RespHeaders) of
                        {_, <<"application/json">>} -> 
			    case re:split(RespBody, <<"\r\n">>) of
				[RespBody] ->				    
				    {ok, jsx:decode(RespBody)};
				_ ->
				    %% The response is a multiline response as a string
				    Replaced = re:replace(
						   RespBody, <<"\r\n">>, <<",">>, 
						   [global, {return, list}]
						  ),
				    Trimmed = string:trim(Replaced, both, ","),
				    {ok, jsx:decode(list_to_binary("["++Trimmed++"]"))}
			    end;
                        _ -> 
			    {ok, {StatusCode, RespBody}}
                    end;
                _ ->
                    {error, {StatusCode, RespBody}}
            end;
        {error, _} = E ->
            E
    end.

call(Method, Body, URL, Args) when is_binary(Body) ->
    call(Method, Body, to_url(URL, Args)).

async(Url, Receiver) ->
    Options = [{recv_timeout, infinity}, async],
    LoopFun = fun(Loop, Ref) ->
		      receive
			  {hackney_response, Ref, {status, StatusInt, Reason}} ->
			      io:format("Status update ~p, ~p~n",[StatusInt, Reason]),
			      Receiver ! {self(), {status, StatusInt, Reason}},
			      Loop(Loop, Ref);
			  {hackney_response, Ref, {headers, Headers}} ->
			      Receiver ! {self(), {headers, Headers}},
			      io:format("got headers: ~p~n", [Headers]),
			      Loop(Loop, Ref);
			  {hackney_response, Ref, done} ->
			      Receiver ! {self(), {done}},
			      ok;
			  {hackney_response, Ref, Bin} ->
			      io:format("got chunk: ~p~n", [Bin]),
			      Receiver ! {self(), {data, Bin}},
			      Loop(Loop, Ref);
			  {Pid, {status, Code, Status}} ->
			      io:format("Pid ~p returned ~p with code ~p~n", [Pid, Status, Code]),
			      Receiver ! {self(), {status, Code, Status}},
			      Loop(Loop, Ref);
			  Else ->
			      % In case this is running in a shell this breaks the loop,
			      % otherwise the loop will be endless
			      io:format("ELSE ~p~n", [Else]),
			      Receiver ! {self(), {Else}}
		      end
	      end,
    {ok, ClientRef} = hackney:post(Url, [], <<>>, Options),
    LoopFun(LoopFun, ClientRef).
    
argsencode([], Acc) ->
    hackney_bstr:join(lists:reverse(Acc), <<"&">>);
argsencode ([{_K,undefined}|R], Acc) ->
    argsencode(R, Acc);
argsencode ([{K,V}|R], Acc) ->
    K1 = hackney_url:urlencode(to_binary(K)),
    V1 = hackney_url:urlencode(to_binary(V)),
    Line = << K1/binary, "=", V1/binary >>,
    argsencode(R, [Line | Acc]);
argsencode([K|R], Acc) ->
    argsencode([{K, <<"true">>}|R], Acc).

to_binary(X) when is_list(X) -> iolist_to_binary(X);
to_binary(X) when is_atom(X) -> atom_to_binary(X, utf8);
to_binary(X) when is_integer(X) -> list_to_binary(integer_to_list(X));
to_binary(X) when is_binary(X) -> X.

convert_url_parts(Xs) when is_list(Xs) ->
    [<<"/", (to_binary(X))/binary>> || X <- Xs];
convert_url_parts(X) -> convert_url_parts([X]).

to_url(X) ->
    iolist_to_binary([?ADDR|convert_url_parts(X)]).

to_url(X, []) ->
    to_url(X);
to_url(X, Args) ->
    iolist_to_binary([?ADDR, convert_url_parts(X), <<"?">>, argsencode(Args, [])]).

proplists_from_json(L) when is_list(L) -> [proplist_from_json(E) || E <- L];
proplists_from_json(_) -> [].

proplist_from_json(PropList) when is_list(PropList) ->
    [proc_kv({K, V}) || {K, V} <- PropList];
proplist_from_json(X) -> X.

proc_kv({BinKey, {L} = Value}) when is_list(L) ->
    {binary_to_atom(BinKey, utf8), proplist_from_json(Value)};
proc_kv({BinKey, Value}) ->
    {binary_to_atom(BinKey, utf8), Value}.
