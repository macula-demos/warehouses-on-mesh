-module(ot_gateway_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        worker(ot_command_guard),
        worker(ot_gateway_audit)
    ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Children}}.

worker(Module) ->
    #{
        id => Module,
        start => {Module, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [Module]
    }.
