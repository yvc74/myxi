%% This Source Code Form is subject to the terms of
%% the Mozilla Public License, v. 2.0.
%%
%% A copy of the MPL can be found in the LICENSE file or
%% you can obtain it at http://mozilla.org/MPL/2.0/.
%%
%% @author Brendan Hay
%% @copyright (c) 2012 Brendan Hay <brendan@soundcloud.com>
%% @doc
%%

-module(poxy_connection).

-behaviour(gen_server).
-behaviour(cowboy_protocol).

-include("include/poxy.hrl").

%% API
-export([start_link/4,
         reply/2,
         reply/4,
         replay/4,
         forward/5]).

%% Callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(s, {router   :: router(),
            backend  :: pid(),
            frontend :: pid(),
            client   :: inet:socket(),
            server   :: inet:socket(),
            policies :: [policy()]}).

%%
%% API
%%

-spec start_link(pid(), client(), cowboy_tcp_transport, frontend())
                -> {ok, pid()} | ignore | {error, _}.
%% @doc
start_link(Listener, Client, cowboy_tcp_transport, Config) ->
    case gen_server:start_link(?MODULE, {Client, Config}, []) of
        {ok, Pid} ->
            ok = cowboy:accept_ack(Listener),
            {ok, Pid};
        Error ->
            Error
    end.

reply(Conn, Raw) ->
    gen_server:cast(Conn, {reply, Raw}).

reply(Conn, Channel, Method, Protocol) ->
    gen_server:cast(Conn, {reply, Channel, Method, Protocol}).

replay(Conn, StartOk, Replay, Protocol) ->
    gen_server:call(Conn, {replay, StartOk, Replay, Protocol}).

forward(Conn, Raw, Channel, Method, Protocol) ->
    gen_server:cast(Conn, {forward, Raw, Channel, Method, Protocol}).

%%
%% Callbacks
%%

-spec init(_) -> {ok, #s{}}.
%% @hidden
init({Client, Config}) ->
    process_flag(trap_exit, true),
    lager:info("CONN-INIT ~p", [self()]),
    {ok, Frontend} = poxy_frontend:start_link(self(), Client),
    {ok, #s{router   = poxy_router:new(Config),
            frontend = Frontend,
            client   = Client}}.

-spec handle_call(_, _, #s{}) -> {reply, ok, #s{}}.
%% @hidden
handle_call({replay, StartOk, Replay, Protocol}, {Frontend, _Ref},
            State = #s{router = Router, frontend = Frontend}) ->
    {Addr, Policies} = poxy_router:route(Router, StartOk, Protocol),
    {ok, Backend, Server} = poxy_backend:start_link(self(), Addr, Replay),
    {reply, ok, State#s{backend  = Backend,
                        server   = Server,
                        policies = Policies}}.

-spec handle_cast(_, #s{}) -> {noreply, #s{}}.
%% @hidden
handle_cast({reply, Raw}, State = #s{client = Client})
  when is_port(Client) ->
    ok = send(Client, Raw),
    {noreply, State};

handle_cast({reply, Channel, Method, Protocol}, State = #s{client = Client})
  when is_port(Client) ->
    ok = send(Client, Channel, Method, Protocol),
    {noreply, State};

handle_cast({forward, Raw, Channel, Method, Protocol},
            State = #s{server = Server, policies = Policies})
  when is_port(Server) ->
    ok = intercept(Server, Raw, Channel, Method, Protocol, Policies),
    {noreply, State}.

-spec handle_info(_, #s{}) -> {noreply, #s{}} | {stop, normal, #s{}}.
%% @hidden
handle_info({'EXIT', Pid, _Msg}, State = #s{frontend = Pid}) ->
    {stop, normal, State};
handle_info({'EXIT', Pid, _Msg}, State = #s{backend = Pid}) ->
    {stop, normal, State}.

-spec terminate(_, #s{}) -> ok.
%% @hidden
terminate(_Reason, #s{backend = Backend,
                      frontend = Frontend,
                      server = Server,
                      client = Client}) ->
    catch gen_tcp:close(Server),
    catch gen_tcp:close(Client),
    case Backend of
        undefined -> ok;
        _Pid      -> exit(Backend, kill)
    end,
    exit(Frontend, kill),
    lager:info("CONN-EXIT"),
    ok.

-spec code_change(_, #s{}, _) -> {ok, #s{}}.
%% @hidden
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%
%% Private
%%

-spec send(inet:socket(), binary()) -> ok | {error, _}.
%% @private
send(Sock, Data) ->
    case gen_tcp:send(Sock, Data) of
        ok    -> ok;
        Error -> lager:error("~p", [Error])
    end.

-spec send(inet:socket(), non_neg_integer(), method(), protocol()) -> ok.
%% @doc
send(Sock, 0, Method, Protocol) ->
    rabbit_writer:internal_send_command(Sock, 0, Method, Protocol);
send(Sock, Channel, Method, Protocol) ->
    Frame =
        rabbit_binary_generator:build_simple_method_frame(Channel, Method, Protocol),
    send(Sock, Frame).

-spec intercept(inet:socket(), iolist(), non_neg_integer(),
                ignore | passthrough | method(), protocol(), [policy()]) -> ok.
%% @doc
intercept(_Sock, _Data, _Channel, ignore, _Protocol, _Policies) ->
    ok;
intercept(Sock, Data, _Channel, passthrough, _Protocol, _Policies) ->
    send(Sock, Data);
intercept(Sock, Data, Channel, Method, Protocol, Policies) ->
    case poxy_policy:thrush(Method, Policies) of
        {modified, NewMethod} ->
            lager:info("MODIFIED ~p", [NewMethod]),
            send(Sock, Channel, NewMethod, Protocol);
        {unmodified, Method} ->
            send(Sock, Data)
    end.
