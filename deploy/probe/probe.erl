%% Lab probe, not part of the demo app.
%%
%% check/1: connect to one station, call the provider that station serves,
%% through that station. The two-site gate uses it to check each local path.
%%
%% relay/1: connect to station A, resolve the provider whose serving station
%% is site B, and call it through station A. The call is forwarded A -> B.
%% The payload carries a unique marker so a packet capture can show the relay
%% saw no plaintext.
%%
%% write/1: use the dashboard's operator identity to write a site B freezer
%% through station A, replay the same command id, then try the same write as
%% a fresh stranger identity. Prints the three outcomes for the Phase 4 gate.
-module(probe).

-export([check/1, relay/1, write/1, clear/1]).

-define(READ, <<"ot/list_freezers">>).
-define(WRITE, <<"ot/set_freezer_target">>).

check([Station0, Site0]) ->
    Station = to_bin(Station0),
    Site = to_bin(Site0),
    {Pool, Realm, _RealmPub, StationId} = connect(Station, Site),
    {ok, Providers} = providers(Pool, Realm, ?READ),
    case provider_for(Providers, StationId) of
        {ok, Provider} ->
            Result = call(Pool, Station, StationId, Provider, Realm, ?READ, #{}, 10000),
            print(binary_to_list(Site), StationId, Provider, Result, none),
            halt(0);
        none ->
            io:format("site=~s station=~s RESULT no_local_provider providers=~p~n",
                      [Site, hex(StationId), Providers]),
            halt(2)
    end.

relay([Station0, TargetSite0]) ->
    Station = to_bin(Station0),
    TargetSite = to_bin(TargetSite0),
    {Pool, Realm, _RealmPub, StationId} = connect(Station, <<"A">>),
    {_TR, _TRP, TargetStationId} = read_config(TargetSite),
    {ok, Providers} = providers(Pool, Realm, ?READ),
    case provider_for(Providers, TargetStationId) of
        {ok, Provider} ->
            Marker = iolist_to_binary(io_lib:format("relay-capture-marker-~b",
                                                     [erlang:system_time(millisecond)])),
            Payload = #{<<"marker">> => Marker},
            Result = call(Pool, Station, StationId, Provider, Realm, ?READ, Payload, 10000),
            print("relay=A->" ++ binary_to_list(TargetSite), StationId, Provider, Result, Marker),
            halt(0);
        none ->
            io:format("relay=~s RESULT no_target_provider providers=~p~n",
                      [TargetSite, Providers]),
            halt(2)
    end.

write([Station0, TargetSite0]) ->
    Station = to_bin(Station0),
    TargetSite = to_bin(TargetSite0),
    Key = identity(),
    {ok, OperatorNodeId} = macula_node_keys:node_id(Key),
    io:format("operator=~s~n", [hex(OperatorNodeId)]),
    {Pool, Realm, RealmPub, StationId} = connect(Station, <<"A">>),
    {_TR, _TRP, TargetStationId} = read_config(TargetSite),
    {ok, Providers} = providers(Pool, Realm, ?WRITE),
    case provider_for(Providers, TargetStationId) of
        {ok, Provider} ->
            Payload = command_payload(<<"FZ-B1">>, 5.0),
            Write = call(Pool, Station, StationId, Provider, Realm, ?WRITE, Payload, 12000),
            print("write=" ++ binary_to_list(TargetSite), StationId, Provider, Write, none),
            Replay = call(Pool, Station, StationId, Provider, Realm, ?WRITE, Payload, 12000),
            print("replay", StationId, Provider, Replay, none),
            StrangerKey = new_identity("/tmp/stranger.key"),
            {ok, StrangerPool} = connect_with(StrangerKey, Station, Realm, RealmPub, StationId),
            Stranger = call(StrangerPool, Station, StationId, Provider, Realm, ?WRITE, Payload, 12000),
            print("stranger", StationId, Provider, Stranger, none),
            halt(0);
        none ->
            io:format("write=~s RESULT no_target_provider providers=~p~n",
                      [TargetSite, Providers]),
            halt(2)
    end.

clear([Station0, Site0]) ->
    Station = to_bin(Station0),
    Site = to_bin(Site0),
    {Pool, Realm, _RealmPub, StationId} = connect(Station, Site),
    {ok, Providers} = providers(Pool, Realm, ?READ),
    case provider_for(Providers, StationId) of
        {ok, Provider} ->
            Url = <<"quic://", Station/binary, ":4433">>,
            Result = macula:call_station(
                       Pool, Url, Provider, Realm, ?READ, #{}, 8000,
                       #{expected_node_id => StationId, report => true, confidential => off}),
            case Result of
                {error, Reason} ->
                    io:format("clear station=~s provider=~s result=~s~n",
                              [hex(StationId), hex(Provider), reason_text(Reason)]);
                _ ->
                    io:format("clear station=~s provider=~s result=~p~n",
                              [hex(StationId), hex(Provider), Result])
            end,
            halt(0);
        none ->
            io:format("clear RESULT no_local_provider providers=~p~n", [Providers]),
            halt(2)
    end.

provider_for(Providers, StationId) ->
    case [P || #{provider := _} = P <- Providers, maps:get(station, P) =:= StationId] of
        [#{provider := Provider} | _] -> {ok, Provider};
        [] -> none
    end.

providers(Pool, Realm, Procedure) ->
    macula_direct_dial:providers(Pool, Realm, Procedure, 8000).

call(Pool, Station, StationId, Provider, Realm, Procedure, Payload, Timeout) ->
    Url = <<"quic://", Station/binary, ":4433">>,
    macula:call_station(Pool, Url, Provider, Realm, Procedure, Payload, Timeout,
                        #{expected_node_id => StationId,
                          report => true,
                          confidential => required}).

print(Label, StationId, Provider, {ok, Reply, Report}, Marker) ->
    Sealed = maps:get(sealed, Report, 0),
    case Label of
        "write=" ++ _ ->
            Map = wire_map(Reply),
            io:format("~s station=~s provider=~s result=ok sealed=~p freezer=~s target=~p~n",
                      [Label, hex(StationId), hex(Provider), Sealed,
                       maps:get(<<"id">>, Map, <<"?">>), maps:get(<<"target_c">>, Map, none)]);
        "relay=" ++ _ ->
            Count = length(maps:get(<<"freezers">>, wire_map(Reply), [])),
            io:format("~s station=~s provider=~s freezers=~p sealed=~p marker=~s~n",
                      [Label, hex(StationId), hex(Provider), Count, Sealed, Marker]);
        _ ->
            Count = length(maps:get(<<"freezers">>, wire_map(Reply), [])),
            io:format("site=~s station=~s provider=~s freezers=~p sealed=~p~n",
                      [Label, hex(StationId), hex(Provider), Count, Sealed])
    end,
    ok;
print(Label, StationId, Provider, {error, Reason}, _Marker) ->
    io:format("~s station=~s provider=~s result=~s~n",
              [Label, hex(StationId), hex(Provider), reason_text(Reason)]),
    ok;
print(Label, StationId, Provider, Other, _Marker) ->
    io:format("~s station=~s provider=~s RESULT ~p~n",
              [Label, hex(StationId), hex(Provider), Other]),
    ok.

reason_text(command_replayed) -> "command_replayed";
reason_text({call_error, Code, _Detail}) -> reason_text(Code);
reason_text({call_error, Code, _Detail, _}) -> reason_text(Code);
reason_text({error, Reason}) -> reason_text(Reason);
reason_text({text, Bin}) when is_binary(Bin) -> binary_to_list(Bin);
reason_text(Bin) when is_binary(Bin) -> binary_to_list(Bin);
reason_text(Other) -> lists:flatten(io_lib:format("~p", [Other])).

%% The reply may be binary-keyed or the SDK's {text, Key} shape.
wire_map(Reply) when is_map(Reply) ->
    maps:fold(fun(K, V, Acc) ->
                  Key = case K of
                          {text, B} -> B;
                          B when is_binary(B) -> B;
                          _ -> K
                        end,
                  Acc#{Key => V}
              end, #{}, Reply);
wire_map(_Other) -> #{}.

connect(Station, Site) ->
    {Realm, RealmPub, StationId} = read_config(Site),
    {ok, _} = application:ensure_all_started(macula),
    Key = identity(),
    {ok, Pool} = connect_with(Key, Station, Realm, RealmPub, StationId),
    {Pool, Realm, RealmPub, StationId}.

connect_with(Key, Station, Realm, RealmPub, StationId) ->
    Seed = #{host => Station, port => 4433, expected_node_id => StationId},
    case macula_client:connect([Seed], #{node_identity => Key,
                                         realm_trust => #{Realm => RealmPub}}) of
        {ok, Pool} ->
            case wait_healthy(Pool, 100) of
                ok -> {ok, Pool};
                Error -> Error
            end;
        Error -> Error
    end.

read_config(Site) ->
    RealmFile = filename:join("/mesh",
                              "realm-" ++ string:lowercase(binary_to_list(Site)) ++ ".json"),
    {ok, Body} = file:read_file(RealmFile),
    #{<<"realm">> := RealmHex, <<"realm_key">> := RealmKeyHex,
      <<"station_node_id">> := StationHex} = jsx:decode(Body, [return_maps]),
    {binary:decode_hex(RealmHex), binary:decode_hex(RealmKeyHex),
     binary:decode_hex(StationHex)}.

identity() ->
    Path = case filelib:is_regular("/operator/operator.key") of
               true -> "/operator/operator.key";
               false -> "/tmp/probe-identity.key"
           end,
    case macula_node_keys:load(Path, identity, pq_hybrid) of
        {ok, Key} -> Key;
        {error, enoent} -> new_identity(Path)
    end.

new_identity(Path) ->
    case macula_node_keys:load(Path, identity, pq_hybrid) of
        {ok, Key} -> Key;
        {error, enoent} ->
            {ok, Key} = macula_node_keys:generate(identity, pq_hybrid),
            ok = macula_node_keys:save(Path, Key),
            Key
    end.

command_payload(FreezerId, TargetC) ->
    #{<<"freezer_id">> => FreezerId,
      <<"target_c">> => TargetC,
      <<"command_id">> => binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
      <<"requested_at_ms">> => erlang:system_time(millisecond)}.

wait_healthy(_Pool, 0) -> {error, station_unhealthy};
wait_healthy(Pool, N) ->
    case macula_client:status(Pool) of
        {ok, #{healthy_links := Links}} when Links > 0 -> ok;
        _ -> timer:sleep(100), wait_healthy(Pool, N - 1)
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L).

hex(Bin) -> binary:encode_hex(Bin, lowercase).
