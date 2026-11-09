%% @doc The gateway service contract.
%%
%% The read path is open; the write path is authorized by the operator's
%% node identity. Every write carries a command id and a timestamp, checked by
%% `ot_command_guard', and is recorded by `ot_gateway_audit'.
-module(ot_gateway_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{
        name => <<"mcl-ot-gateway">>,
        version => <<"0.1.0">>,
        description => <<"Cold-chain REST to Macula RPC gateway">>
    }.

start(_Opts) ->
    ot_gateway_sup:start_link().

stop(_State) ->
    ok.

health() ->
    case ot_controller_client:health() of
        ok -> ok;
        {error, Reason} -> {down, Reason}
    end.

capabilities() ->
    [read_capability() | write_capabilities(operator_nodes())].

read_capability() ->
    #{
        name => <<"list_freezers">>,
        version => 1,
        handler => {mcl_om_simple_handler, {ot_gateway_handler, list_freezers}},
        %% Reads are open in this slice; the controller's read API is open too.
        auth => open,
        %% The gateway names a KEM key, so the caller seals the payload and the
        %% station relays ciphertext. The raw macula_bridge cannot carry this.
        confidential => required,
        limits => limits()
    }.

write_capabilities([]) ->
    [];
write_capabilities(Nodes) ->
    Auth = {callers, {nodes, Nodes}},
    [
        write_capability(<<"set_freezer_target">>, set_freezer_target, Auth),
        write_capability(<<"start_freezer_defrost">>, start_freezer_defrost, Auth),
        write_capability(<<"stop_freezer_defrost">>, stop_freezer_defrost, Auth),
        write_capability(<<"list_freezer_commands">>, list_freezer_commands, Auth)
    ].

write_capability(Name, Handler, Auth) ->
    #{
        name => Name,
        version => 1,
        handler => {mcl_om_simple_handler, {ot_gateway_handler, Handler}},
        auth => Auth,
        confidential => required,
        limits => limits()
    }.

limits() ->
    #{
        max_payload_external_size => 65536,
        window_ms => 10000,
        per_caller_max => 60,
        global_max => 600
    }.

identity_spec() ->
    #{
        scope => <<"ot">>,
        actions => [],
        resources => [],
        ttl_days => 30
    }.

%% The operator node ids the UI wrote to /mesh/operator-node-id before this
%% service started. No operator means no write capabilities are advertised;
%% the read path still serves.
operator_nodes() ->
    case os:getenv("OPERATOR_NODE_IDS") of
        false -> [];
        "" -> [];
        Csv -> lists:filtermap(fun hex_node/1, string:split(Csv, ",", all))
    end.

hex_node(Part) ->
    case string:trim(Part) of
        "" ->
            false;
        Hex ->
            try
                {true, hex_to_bin(Hex)}
            catch
                _Class:_Reason -> false
            end
    end.

hex_to_bin(Hex) ->
    << <<(list_to_integer([A, B], 16))>> || <<A:8, B:8>> <= list_to_binary(Hex) >>.
