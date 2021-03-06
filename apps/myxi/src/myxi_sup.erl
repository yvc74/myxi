%% This Source Code Form is subject to the terms of
%% the Mozilla Public License, v. 2.0.
%% A copy of the MPL can be found in the LICENSE file or
%% you can obtain it at http://mozilla.org/MPL/2.0/.
%%
%% @author Brendan Hay
%% @copyright (c) 2012 Brendan Hay <brendan@soundcloud.com>
%% @doc
%%

-module(myxi_sup).

-behaviour(supervisor).

-include("include/myxi.hrl").

%% API
-export([start_link/0]).

%% Callbacks
-export([init/1]).

%%
%% API
%%

-spec start_link() -> {ok, pid()} | ignore | {error, _}.
%% @doc
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%
%% Callbacks
%%

-spec init([]) -> {ok, {{one_for_all, 3, 20}, [supervisor:child_spec()]}}.
%% @hidden
init([]) ->
    %% Ensure the listeners are linked against the supervisor process
    ok = myxi_listener:start_link(),
    Registry = {registry, {myxi_registry, start_link, []},
                permanent, 2000, worker, [myxi_registry]},
    Topology = {topology, {myxi_topology, start_link, []},
                permanent, 2000, worker, [myxi_topology]},
    Balancers = {balancer_sup, {myxi_balancer_sup, start_link, []},
                 permanent, 2000, worker, [myxi_balancer_sup]},
    {ok, {{one_for_all, 3, 20}, [Registry, Topology, Balancers]}}.
