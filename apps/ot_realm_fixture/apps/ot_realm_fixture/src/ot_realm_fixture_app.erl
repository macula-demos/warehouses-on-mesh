-module(ot_realm_fixture_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    ot_realm_fixture_sup:start_link().

stop(_State) ->
    ok.
