-module(ot_gateway_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    mcl_om:boot(ot_gateway_service).

stop(_State) ->
    ok.
