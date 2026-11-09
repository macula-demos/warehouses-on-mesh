%% @doc The legacy REST client behind the gateway.
%%
%% The controller stays unmodified. The gateway holds the LAN-side path to it;
%% the internet never does. Reads use the controller's open read API; writes
%% use the gateway's own strong account, never the legacy admin default.
-module(ot_controller_client).

-export([health/0, list_freezers/0, set_target/2, start_defrost/1, stop_defrost/1]).

-define(TIMEOUT_MS, 5000).

-spec health() -> ok | {error, term()}.
health() ->
    case http_get("/api/health") of
        {ok, _Body} -> ok;
        {error, Reason} -> {error, Reason}
    end.

-spec list_freezers() -> {ok, map()} | {error, term()}.
list_freezers() ->
    case http_get("/api/freezers") of
        {ok, Body} ->
            decode_freezers(Body);
        {error, Reason} ->
            {error, Reason}
    end.

-spec set_target(binary(), number()) -> {ok, map()} | {error, term()}.
set_target(FreezerId, TargetC) ->
    Path = "/api/freezers/" ++ binary_to_list(FreezerId) ++ "/target",
    post(Path, #{<<"target_c">> => TargetC}).

-spec start_defrost(binary()) -> {ok, map()} | {error, term()}.
start_defrost(FreezerId) ->
    Path = "/api/freezers/" ++ binary_to_list(FreezerId) ++ "/defrost",
    post(Path, #{}).

-spec stop_defrost(binary()) -> {ok, map()} | {error, term()}.
stop_defrost(FreezerId) ->
    Path = "/api/freezers/" ++ binary_to_list(FreezerId) ++ "/stop",
    post(Path, #{}).

decode_freezers(Body) ->
    try jsx:decode(Body, [return_maps]) of
        #{<<"freezers">> := Freezers} when is_list(Freezers) ->
            {ok, #{<<"freezers">> => Freezers}};
        _Other ->
            {error, unexpected_response}
    catch
        _Class:_Reason ->
            {error, invalid_json}
    end.

http_get(Path) ->
    Url = base_url() ++ Path,
    case httpc:request(get, {Url, []}, [{timeout, ?TIMEOUT_MS}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            {ok, Body};
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {error, {http_status, Status, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

post(Path, BodyMap) ->
    Url = base_url() ++ Path,
    Json = jsx:encode(BodyMap),
    Headers = [auth_header(), {"content-type", "application/json"}],
    case httpc:request(post, {Url, Headers, "application/json", Json},
                       [{timeout, ?TIMEOUT_MS}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            decode_freezer(Body);
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {error, {http_status, Status, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

decode_freezer(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Map when is_map(Map) -> {ok, Map};
        _Other -> {error, unexpected_response}
    catch
        _Class:_Reason -> {error, invalid_json}
    end.

auth_header() ->
    User = env_binary("GATEWAY_USER", <<"gateway">>),
    Password = env_binary("GATEWAY_PASSWORD", <<"gateway-demo-password">>),
    Encoded = base64:encode(<<User/binary, ":", Password/binary>>),
    {"authorization", binary_to_list(<<"Basic ", Encoded/binary>>)}.

env_binary(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> unicode:characters_to_binary(Value)
    end.

base_url() ->
    case os:getenv("CONTROLLER_URL") of
        false -> "http://freezer-controller:8080";
        "" -> "http://freezer-controller:8080";
        Url -> Url
    end.
