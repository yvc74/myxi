%% @doc
-module(poxy_backend).

%% API
-export([start_link/3]).

%% Callbacks
-export([init/4]).

-include("include/poxy.hrl").

-record(s, {connection :: pid(),
            server     :: inet:socket()}).

%%
%% API
%%

%-spec start_link(inet:socket()) -> {ok, pid()}.
%% @doc
start_link(Conn, Addr, Replay) ->
    proc_lib:start_link(?MODULE, init, [self(), Conn, Addr, Replay]).

%%
%% Callbacks
%%

%-spec init(pid(), inet:socket()) -> no_return().
%% @hidden
init(Parent, Conn, {Ip, Port}, Replay) ->
    Server = connect(Ip, Port, 3),
    gen_tcp:controlling_process(Server, Conn),
    lager:info("BACKEND-INIT ~p", [Server]),
    proc_lib:init_ack(Parent, {ok, self(), Server}),
    ok = replay(Server, Replay),
    read(#s{connection = Conn, server = Server}).

%%
%% States
%%

-spec read(#s{}) -> no_return().
%% @private
read(State = #s{connection = Conn, server = Server}) ->
    case gen_tcp:recv(Server, 0) of
        {ok, Data} ->
            poxy_connection:reply(Conn, Data),
            read(State);
        {error, closed} ->
            exit(normal);
        Error ->
            exit(Error)
    end.

%%
%% Private
%%

-spec replay(inet:socket(), iolist()) -> ok.
%% @doc
replay(Server, [Payload, Header, Handshake]) ->
    ok = gen_tcp:send(Server, Handshake),
    ok = case gen_tcp:recv(Server, 0) of
             {ok, _Data} -> ok
         end,
    gen_tcp:send(Server, [Header, Payload]).

%-spec connect(addr(), #s{}, non_neg_integer()) -> inet:socket().
%% @private
connect(Ip, Port, 0) ->
    exit({backend_timeout, Ip, Port});
connect(Ip, Port, Retries) ->
    Tcp = [binary, {active, false}, {packet, raw}|poxy:config(tcp)],
    case gen_tcp:connect(Ip, Port, Tcp) of
        {ok, Server} ->
            Server;
        Error ->
            lager:error("BACKEND-ERR ~p", [{Error, Ip, Port}]),
            timer:sleep(500),
            connect(Ip, Port, Retries - 1)
    end.
