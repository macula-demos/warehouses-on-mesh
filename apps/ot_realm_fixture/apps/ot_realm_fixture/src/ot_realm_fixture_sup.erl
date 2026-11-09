-module(ot_realm_fixture_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => ot_realm_fixture,
          start => {ot_realm_fixture, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [ot_realm_fixture]}
    ],
    {ok, {#{strategy => one_for_one, intensity => 100, period => 10}, Children}}.
