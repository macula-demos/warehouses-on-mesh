%% Phase 0 spike module. Not part of the demo app.
%%
%% provider/2: connect to a station, mint an identity and a realm, advertise
%% a bare (non-org) procedure, and write the provider node id and realm public
%% key where the caller can read them.
%%
%% caller/2: connect to another station, resolve the provider through the
%% federated DHT, then make the same call twice:
%%   1. the SDK's normal direct-dial path (caller -> serving station B);
%%   2. call_station to station A with the provider named as the target, which
%%      asks station A to forward the CALL to station B (station-to-station).
%%
%% The call is sealed (`confidential => required`) so the call report can
%% prove `sealed => 1` across the relayed path. This spike is about routing,
%% not policy; the app lab adds the gateway's auth rules.
-module(spike).

-behaviour(macula_response).

-export([provider/1, provider/2, caller/1, caller/2, dump/1, dump/2]).
-export([init/1, handle_request/2]).

-define(PROCEDURE, <<"phase0/echo_v1">>).
-define(ORG, <<"phase0">>).
-define(SPIKE_DIR, "/spike").

%%--------------------------------------------------------------------
%% provider
%%--------------------------------------------------------------------

provider([Host0, Port0]) ->
    provider(Host0, Port0).

provider(Host0, Port0) ->
    Host = to_bin(Host0),
    Port = to_int(Port0),
    {ok, _} = application:ensure_all_started(macula),
    Realm = realm_id(),
    RealmKey = realm_key(),
    Identity = identity(provider),
    {ok, NodeId} = macula_node_keys:node_id(Identity),
    StationId = station_node_id(Host),
    Seed = seed(Host, Port, StationId),
    {ok, Pool} = macula_client:connect([Seed], #{node_identity => Identity,
                                                 realm_trust => #{Realm => macula_node_keys:public_key(RealmKey)}}),
    ok = wait_healthy(Pool, 100),
    OrgKey = org_key(),
    OrgDir = macula_record:sign(
               macula_record:org_directory(Realm, ?ORG, macula_node_keys:key_id(OrgKey)),
               RealmKey),
    Delegation = macula_record:sign(
                   macula_record:procedure_delegation(
                     macula_node_keys:key_id(OrgKey), NodeId),
                   OrgKey),
    ok = macula:put_record(Pool, macula_record:encode(OrgDir)),
    ok = macula:put_record(Pool, macula_record:encode(Delegation)),
    Authorization = #{org_directory => macula_record:encode(OrgDir),
                      procedure_delegation => macula_record:encode(Delegation)},
    {ok, _Sup} = macula_response:advertise_direct(
                   Pool, Realm, ?PROCEDURE, ?MODULE, [], Identity,
                   #{auth => open, authorization => Authorization,
                     confidential => required}),
    write(<<"provider-node-id">>, hex(NodeId)),
    write(<<"realm.pub">>, hex(macula_node_keys:public_key(RealmKey))),
    io:format("provider ~s advertised ~s on ~s:~p~n", [hex(NodeId), ?PROCEDURE, Host, Port]),
    sleep_forever().

%%--------------------------------------------------------------------
%% caller
%%--------------------------------------------------------------------

caller([Host0, Port0]) ->
    caller(Host0, Port0, <<"both">>);
caller([Host0, Port0, Mode]) ->
    caller(Host0, Port0, Mode).

caller(Host0, Port0) ->
    caller(Host0, Port0, <<"both">>).

caller(Host0, Port0, Mode0) ->
    Mode = to_bin(Mode0),
    Host = to_bin(Host0),
    Port = to_int(Port0),
    {ok, _} = application:ensure_all_started(macula),
    Realm = realm_id(),
    RealmPub = binary:decode_hex(read(<<"realm.pub">>)),
    Target = binary:decode_hex(read(<<"provider-node-id">>)),
    Identity = identity(caller),
    ANode = station_node_id(Host),
    StationA = <<"quic://", Host/binary, ":", (integer_to_binary(Port))/binary>>,
    Seed = seed(Host, Port, ANode),
    {ok, Pool} = macula_client:connect([Seed], #{node_identity => Identity,
                                                 realm_trust => #{Realm => RealmPub}}),
    io:format("caller connected to ~s (~s)~n", [Host, hex(ANode)]),
    ok = wait_healthy(Pool, 100),

    wait_providers(Pool, Realm, 30),
    io:format("providers: ~p~n",
              [macula_direct_dial:providers(Pool, Realm, ?PROCEDURE, 5000)]),

    io:format("~nlinks before calls: ~p~n", [macula_client:links(Pool)]),

    case Mode of
        <<"relay">> ->
            ok;
        _ ->
            Direct = macula:call(Pool, Realm, ?PROCEDURE, #{<<"via">> => <<"direct">>}, 8000,
                                 #{provider => Target, report => true}),
            io:format("~nDIRECT (SDK resolves serving station)~n~p~n", [Direct]),
            io:format("links after direct: ~p~n", [macula_client:links(Pool)])
    end,

    Relay = macula:call_station(Pool, StationA, Target, Realm, ?PROCEDURE,
                                #{<<"via">> => <<"station-a-forwarded">>}, 8000,
                                #{expected_node_id => ANode, report => true,
                                  confidential => required}),
    io:format("~nRELAY (call sent to station A, target is the provider on B)~n~p~n", [Relay]),
    io:format("~nlinks after relay: ~p~n", [macula_client:links(Pool)]),

    timer:sleep(1000),
    halt(0).

wait_healthy(_Pool, 0) ->
    {error, station_unhealthy};
wait_healthy(Pool, N) ->
    case macula_client:status(Pool) of
        {ok, #{healthy_links := Links}} when Links > 0 -> ok;
        _ -> timer:sleep(100), wait_healthy(Pool, N - 1)
    end.

wait_providers(_Pool, _Realm, 0) ->
    ok;
wait_providers(Pool, Realm, N) ->
    case macula_direct_dial:providers(Pool, Realm, ?PROCEDURE, 2000) of
        {ok, [_ | _]} -> ok;
        _ -> timer:sleep(1000), wait_providers(Pool, Realm, N - 1)
    end.

%%--------------------------------------------------------------------
%% macula_response callbacks
%%--------------------------------------------------------------------

init(_Args) ->
    {ok, []}.

handle_request(Payload, State) ->
    {reply, #{<<"echo">> => Payload, <<"served_by">> => <<"phase0-provider">>}, State}.

%%--------------------------------------------------------------------
%% diagnostic
%%--------------------------------------------------------------------

dump([Host0, Port0]) ->
    dump(Host0, Port0).

dump(Host0, Port0) ->
    Host = to_bin(Host0),
    Port = to_int(Port0),
    {ok, _} = application:ensure_all_started(macula),
    Realm = realm_id(),
    RealmPub = binary:decode_hex(read(<<"realm.pub">>)),
    StationId = station_node_id(Host),
    {ok, Pool} = macula_client:connect([seed(Host, Port, StationId)],
                                       #{node_identity => identity(diag),
                                         realm_trust => #{Realm => RealmPub}}),
    ok = wait_healthy(Pool, 100),
    timer:sleep(2000),
    io:format("advertisement records: ~p~n",
              [macula:find_records(Pool, macula_record:procedure_key(Realm, ?PROCEDURE))]),
    BNode = binary:decode_hex(read(<<"station-b-node-id">>)),
    Eps = macula:find_records(Pool, macula_record:station_endpoint_key(BNode)),
    io:format("station-b endpoint records: ~p~n", [Eps]),
    case Eps of
        {ok, Recs} ->
            [io:format("read endpoint ~p: ~p~n",
                       [i, macula_record:read_station_endpoint(R)])
             || {i, R} <- lists:zip(lists:seq(1, length(Recs)), Recs)];
        _ -> ok
    end,
    halt(0).

%%--------------------------------------------------------------------
%% helpers
%%--------------------------------------------------------------------

realm_id() ->
    crypto:hash(sha256, <<"phase0-relay-spike">>).

realm_key() ->
    load_or_generate(filename:join(?SPIKE_DIR, "realm.key"), realm).

org_key() ->
    load_or_generate(filename:join(?SPIKE_DIR, "org.key"), org).

identity(Who) ->
    load_or_generate(filename:join(?SPIKE_DIR, atom_to_list(Who) ++ "-identity.key"), identity).

load_or_generate(Path, Purpose) ->
    case macula_node_keys:load(Path, Purpose, pq_hybrid) of
        {ok, Key} ->
            Key;
        {error, enoent} ->
            {ok, Key} = macula_node_keys:generate(Purpose, pq_hybrid),
            ok = macula_node_keys:save(Path, Key),
            Key
    end.

station_node_id(Host) ->
    File = filename:join(?SPIKE_DIR, <<Host/binary, "-node-id">>),
    case file:read_file(File) of
        {ok, Hex} -> binary:decode_hex(string:trim(Hex));
        {error, _} -> undefined
    end.

seed(Host, Port, undefined) ->
    #{host => Host, port => Port};
seed(Host, Port, NodeId) ->
    #{host => Host, port => Port, expected_node_id => NodeId}.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L).

to_int(I) when is_integer(I) -> I;
to_int(A) when is_atom(A) -> list_to_integer(atom_to_list(A));
to_int(L) when is_list(L) -> list_to_integer(L).

write(Name, Bin) ->
    Path = filename:join(?SPIKE_DIR, Name),
    ok = file:write_file(Path, Bin).

read(Name) ->
    {ok, Bin} = file:read_file(filename:join(?SPIKE_DIR, Name)),
    string:trim(Bin).

hex(undefined) -> <<"none">>;
hex(Bin) -> binary:encode_hex(Bin, lowercase).

sleep_forever() ->
    receive stop -> ok after infinity -> ok end.
