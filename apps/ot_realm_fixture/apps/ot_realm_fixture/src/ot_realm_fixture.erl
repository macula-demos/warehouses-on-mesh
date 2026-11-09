%% @doc Lab-only realm fixture.
%%
%% This is NOT macula-realm. It exists to make the demo self-contained:
%% it mints a realm key, publishes the signed D25 chain the gateway needs,
%% and answers the gateway's boot claim with a delegation for the verified
%% caller. A real deployment uses macula-realm membership, roles, and an
%% operator's approval instead.
-module(ot_realm_fixture).

-behaviour(gen_server).

-export([start_link/0, issue_ot_delegation/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(REALM_NAME, <<"io.macula.otlab">>).
-define(CLAIM_PROCEDURE,
        <<"io.macula/_realm/_realm/identity/request_provider_authorization_v1">>).
-define(STATION_HOST, <<"station">>).
-define(STATION_PORT, 4433).

-record(state, {
    pool :: pid(),
    realm :: <<_:256>>,
    ot_org_key :: term(),
    claim_sup :: pid() | undefined
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Called by the claim handler with the wire-authenticated caller.
-spec issue_ot_delegation(map(), <<_:256>>) -> ok | {error, term()}.
issue_ot_delegation(#{pool := Pool, ot_org_key := OrgKey}, Caller) ->
    publish_record(Pool, sign_delegation(OrgKey, Caller)).

%%%===================================================================
%%% gen_server
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    case setup() of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pool, Reason}, #state{pool = Pool} = State) ->
    {stop, {pool_down, Reason}, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #state{claim_sup = undefined}) ->
    ok;
terminate(_Reason, #state{claim_sup = Sup}) when is_pid(Sup) ->
    exit(Sup, shutdown),
    ok.

%%%===================================================================
%%% Setup
%%%===================================================================

setup() ->
    StationNodeId = read_station_node_id(),
    DataDir = "/data",
    ok = filelib:ensure_dir(filename:join(DataDir, "x")),

    RealmKey = load_or_generate(filename:join(DataDir, "realm.key"), realm),
    OtOrgKey = load_or_generate(filename:join(DataDir, "ot_org.key"), org),
    IoOrgKey = load_or_generate(filename:join(DataDir, "io_org.key"), org),
    {ok, IdentityKey} = macula_node_keys:node_identity(
                           filename:join(DataDir, "identity.key"), pq_hybrid),
    {ok, FixtureNodeId} = macula_node_keys:node_id(IdentityKey),

    Realm = crypto:hash(sha256, ?REALM_NAME),
    RealmPub = macula_node_keys:public_key(RealmKey),

    case connect(IdentityKey, Realm, RealmPub, StationNodeId) of
        {ok, Pool} ->
            _ = erlang:monitor(process, Pool),
            case wait_healthy(Pool, 100) of
                ok ->
                    publish_chain(Pool, Realm, RealmKey, IoOrgKey, FixtureNodeId,
                                  OtOrgKey, IdentityKey, StationNodeId);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

connect(IdentityKey, Realm, RealmPub, StationNodeId) ->
    Seeds = [#{host => ?STATION_HOST,
               port => ?STATION_PORT,
               expected_node_id => StationNodeId}],
    Opts = #{node_identity => IdentityKey,
             realm_trust => #{Realm => RealmPub}},
    macula_client:connect(Seeds, Opts).

publish_chain(Pool, Realm, RealmKey, IoOrgKey, FixtureNodeId, OtOrgKey, IdentityKey,
              StationNodeId) ->
    {ok, IoDirectory} =
        publish_org_directory(Pool, Realm, RealmKey, <<"io.macula">>, IoOrgKey),
    {ok, _OtDirectory} =
        publish_org_directory(Pool, Realm, RealmKey, <<"ot">>, OtOrgKey),

    IoDelegation = sign_delegation(IoOrgKey, FixtureNodeId),
    ok = publish_record(Pool, IoDelegation),

    Authorization = #{
        org_directory => macula_record:encode(IoDirectory),
        procedure_delegation => macula_record:encode(IoDelegation)
    },
    HandlerState = #{pool => Pool, ot_org_key => OtOrgKey},

    case macula_response:advertise_direct(
           Pool, Realm, ?CLAIM_PROCEDURE, ot_realm_claim_handler,
           HandlerState, IdentityKey, #{auth => open, authorization => Authorization}) of
        {ok, ClaimSup} ->
            ok = write_realm_file(Realm, realm_public_key(RealmKey), StationNodeId),
            logger:notice("ot_realm_fixture ready: realm=~s station=~s",
                          [hex(Realm), hex(StationNodeId)]),
            {ok, #state{pool = Pool,
                        realm = Realm,
                        ot_org_key = OtOrgKey,
                        claim_sup = ClaimSup}};
        {error, Reason} ->
            {error, {advertise_failed, Reason}}
    end.

realm_public_key(RealmKey) ->
    macula_node_keys:public_key(RealmKey).

publish_org_directory(Pool, Realm, RealmKey, OrgName, OrgKey) ->
    OrgKeyId = macula_node_keys:key_id(OrgKey),
    Directory = macula_record:sign(
                  macula_record:org_directory(Realm, OrgName, OrgKeyId), RealmKey),
    ok = publish_record(Pool, Directory),
    {ok, Directory}.

sign_delegation(OrgKey, ProviderNodeId) ->
    OrgKeyId = macula_node_keys:key_id(OrgKey),
    macula_record:sign(
      macula_record:procedure_delegation(OrgKeyId, ProviderNodeId), OrgKey).

publish_record(Pool, Record) ->
    macula:put_record(Pool, macula_record:encode(Record)).

wait_healthy(_Pool, 0) ->
    {error, station_unhealthy};
wait_healthy(Pool, Attempts) ->
    case macula_client:status(Pool) of
        {ok, #{healthy_links := Links}} when Links > 0 ->
            ok;
        _Other ->
            timer:sleep(100),
            wait_healthy(Pool, Attempts - 1)
    end.

%%%===================================================================
%%% Keys and files
%%%===================================================================

load_or_generate(Path, Purpose) ->
    case macula_node_keys:load(Path, Purpose, pq_hybrid) of
        {ok, Key} ->
            Key;
        {error, enoent} ->
            {ok, Key} = macula_node_keys:generate(Purpose, pq_hybrid),
            ok = macula_node_keys:save(Path, Key),
            Key;
        {error, Reason} ->
            error({key_load_failed, Path, Reason})
    end.

read_station_node_id() ->
    Path = "/mesh/station-node-id",
    case wait_for_file(Path, 120) of
        ok ->
            {ok, Bin} = file:read_file(Path),
            hex_to_bin(string:trim(binary_to_list(Bin)));
        {error, Reason} ->
            error(Reason)
    end.

wait_for_file(_Path, 0) ->
    {error, missing_station_node_id};
wait_for_file(Path, Attempts) ->
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            timer:sleep(1000),
            wait_for_file(Path, Attempts - 1)
    end.

write_realm_file(Realm, RealmPub, StationNodeId) ->
    Json = jsx:encode(#{
        <<"realm">> => hex(Realm),
        <<"realm_key">> => hex(RealmPub),
        <<"station_node_id">> => hex(StationNodeId)
    }),
    Tmp = "/mesh/realm.json.tmp",
    ok = file:write_file(Tmp, Json),
    ok = file:rename(Tmp, "/mesh/realm.json").

hex(Bin) ->
    binary:encode_hex(Bin, lowercase).

hex_to_bin(Hex) ->
    << <<(list_to_integer([A, B], 16))>> || <<A:8, B:8>> <= list_to_binary(Hex) >>.
