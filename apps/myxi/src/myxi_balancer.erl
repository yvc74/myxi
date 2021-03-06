%% This Source Code Form is subject to the terms of
%% the Mozilla Public License, v. 2.0.
%% A copy of the MPL can be found in the LICENSE file or
%% you can obtain it at http://mozilla.org/MPL/2.0/.
%%
%% @author Brendan Hay
%% @copyright (c) 2012 Brendan Hay <brendan@soundcloud.com>
%% @doc
%%

-module(myxi_balancer).

-include("include/myxi.hrl").

-behaviour(gen_server).

%% API
-export([start_link/5,
         stop/1,
         next/1]).

%% Callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-type check() :: check_up | check_down.
-type next()  :: {ok, {#endpoint{}, [mware()]}} | {error, down}.

-export_types([next/0]).

-record(s, {mod       :: module(),
            name      :: atom(),
            up        :: [#endpoint{}],
            down = [] :: [#endpoint{}],
            mware     :: [mware()]}).

-define(UP,         check_up).
-define(UP_INTER,   5000).
-define(DOWN,       check_down).
-define(DOWN_INTER, 12000).

%%
%% Behaviour
%%

-callback next([#endpoint{}]) -> {#endpoint{} | down, [#endpoint{}]}.

%%
%% API
%%

-spec start_link(atom(), module(), [#endpoint{}], [mware()], pos_integer())
                -> {ok, pid()} | {error, _} | ignore.
%% @doc
start_link(Name, Mod, Endpoints, MW, Delay) ->
    lager:info("BALANCE-START ~s:~s ~p", [Name, Mod, node_names(Endpoints)]),
    State = #s{name = Name, mod = Mod, up = Endpoints, mware = MW},
    gen_server:start_link({local, Name}, ?MODULE, {State, Delay}, []).

-spec stop(atom() | pid()) -> ok.
stop(Pid) -> gen_server:cast(Pid, stop).

-spec next(atom() | pid()) -> next().
%% @doc
next(Pid) -> gen_server:call(Pid, next).

%%
%% Callbacks
%%

-spec init({#s{}, pos_integer()}) -> {ok, #s{}}.
%% @hidden
init({State, Delay}) ->
    process_flag(trap_exit, true),
    %% Notify topology of new endpoints
    myxi_topology:add_endpoints(State#s.up),
    init_timers(Delay),
    ok = myxi_registry:add_balancer(State#s.name),
    {ok, State}.

-spec handle_call(next, {pid(), _}, #s{}) -> {reply, next(), #s{}}.
%% @hidden
handle_call(next, _From, State = #s{mod = Mod, up = Up, mware = MW}) ->
    {Next, Shuffled} = Mod:next(Up),
    Selected =
        case Next of
            Endpoint = #endpoint{} -> {ok, {Endpoint, MW}};
            down                   -> {error, down}
        end,
    {reply, Selected, State#s{up = Shuffled}}.

-spec handle_cast(stop, #s{}) -> {stop, normal, #s{}}.
%% @hidden
handle_cast(stop, State) -> {stop, normal, State}.

-spec handle_info(check(), #s{}) -> {noreply, #s{}}.
%% @hidden
handle_info(Check, State) ->
    NewState = health_check(Check, State),
    set_timer(Check),
    {noreply, NewState}.

-spec terminate(_, #s{}) -> ok.
%% @hidden
terminate(_Reason, _State) -> ok.

-spec code_change(_, #s{}, _) -> {ok, #s{}}.
%% @hidden
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%
%% Private
%%

-spec init_timers(pos_integer()) -> ok.
%% @private
init_timers(Delay) ->
    set_timer(Delay, ?UP),
    set_timer(Delay + ?DOWN_INTER, ?DOWN),
    ok.

-spec set_timer(check()) -> reference().
%% @private
set_timer(?UP)   -> set_timer(?UP_INTER, ?UP);
set_timer(?DOWN) -> set_timer(?DOWN_INTER, ?DOWN).

-spec set_timer(pos_integer(), check()) -> reference().
%% @private Since a pid is used, the timer doesn't need to be canceled
set_timer(Interval, Check) -> erlang:send_after(Interval, self(), Check).

-spec health_check(check(), #s{}) -> #s{}.
%% @private
health_check(?UP, State = #s{up = []}) ->
    State;
health_check(?UP, State = #s{up = Up, down = Down}) ->
    {NewUp, AddDown} = check(Up),
    State#s{up = NewUp, down = Down ++ AddDown};
health_check(?DOWN, State = #s{down = []}) ->
    State;
health_check(?DOWN, State = #s{mod = Mod, name = Name, up = Up, down = Down}) ->
    {AddUp, NewDown} = check(Down),
    lager:info("NODE-DOWN ~s:~s ~p", [Name, Mod, node_names(NewDown)]),
    %% Add endpoints for backends that have just come up
    ok = myxi_topology:add_endpoints(AddUp),
    State#s{up = Up ++ AddUp, down = NewDown}.

-spec check([#endpoint{}]) -> {[#endpoint{}], [#endpoint{}]}.
%% @private
check(Endpoints) -> check(Endpoints, [], []).

-spec check([#endpoint{}], [#endpoint{}], [#endpoint{}])
           -> {[#endpoint{}], [#endpoint{}]}.
%% @private
check([], Up, Down) ->
    {lists:reverse(Up), lists:reverse(Down)};
check([H|T], Up, Down) ->
    case net_adm:ping(H#endpoint.node) of
        pong -> check(T, [H|Up], Down);
        pang -> check(T, Up, [H|Down])
    end.

-spec node_names([#endpoint{}]) -> [node()].
%% @private
node_names(Endpoints) -> [N || #endpoint{node = N} <- Endpoints].
