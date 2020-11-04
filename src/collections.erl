%% @author Couchbase <info@couchbase.com>
%% @copyright 2017-2020 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%

%% @doc methods for handling collections

-module(collections).

-include("cut.hrl").
-include("ns_common.hrl").
-include("ns_test.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([start_link/0,
         enabled/0,
         enabled/1,
         default_manifest/0,
         uid/1,
         uid/2,
         manifest_json/2,
         manifest_json/3,
         create_scope/2,
         create_collection/4,
         drop_scope/2,
         drop_collection/3,
         wait_for_manifest_uid/5,
         convert_uid_from_memcached/1,
         convert_uid_to_memcached/1,
         get_manifest/1,
         get_manifest/2,
         set_manifest/4,
         get_scope/2,
         get_collection/2,
         get_max_supported/1,
         get_uid/1,
         get_collection_uid/3,
         get_scopes/1,
         get_collections/1]).

%% rpc from other nodes
-export([wait_for_manifest_uid/4]).

-define(SERVER, {via, leader_registry, ?MODULE}).

start_link() ->
    misc:start_singleton(work_queue, start_link, [?SERVER]).

enabled() ->
    cluster_compat_mode:is_enabled(?VERSION_CHESHIRECAT).

enabled(BucketConfig) ->
    enabled() andalso ns_bucket:bucket_type(BucketConfig) =:= membase.

key(Bucket) ->
    ns_bucket:sub_key(Bucket, collections).

default_manifest() ->
    [{uid, 0},
     {next_uid, 0},
     {next_scope_uid, 7},
     {next_coll_uid, 7},
     {num_scopes, 0},
     {num_collections, 0},
     {scopes,
      [{"_default",
        [{uid, 0},
         {collections,
          [{"_default",
            [{uid, 0}]}]}]}]}].

with_scope(Fun, ScopeName, Manifest) ->
    Scopes = get_scopes(Manifest),
    case find_scope(ScopeName, Scopes) of
        undefined ->
            {error, {scope_not_found, ScopeName}};
        Scope ->
            Fun(Scope)
    end.

with_collection(Fun, ScopeName, CollectionName, Manifest) ->
    with_scope(
      fun (Scope) ->
              Collections = get_collections(Scope),
              case find_collection(CollectionName, Collections) of
                  undefined ->
                      {error,
                       {collection_not_found, ScopeName, CollectionName}};
                  Props ->
                      Fun(Props)
              end
      end, ScopeName, Manifest).

get_collection_uid(Bucket, ScopeName, CollectionName) ->
    {ok, BucketConfig} = ns_bucket:get_bucket(Bucket),
    with_collection(?cut({ok, get_uid(_)}), ScopeName,
                    CollectionName, get_manifest(BucketConfig)).

uid(BucketCfg) ->
    case enabled(BucketCfg) of
        true ->
            get_uid_in_memcached_format(get_manifest(BucketCfg));
        false ->
            undefined
    end.

uid(Bucket, Snapshot) ->
    case get_manifest(Bucket, Snapshot) of
        undefined ->
            undefined;
        Manifest ->
            get_uid_in_memcached_format(Manifest)
    end.

get_uid(Props) ->
    proplists:get_value(uid, Props).

convert_uid_to_memcached(V) ->
    list_to_binary(string:to_lower(integer_to_list(V, 16))).

convert_uid_from_memcached(V) when is_list(V) ->
    list_to_integer(V, 16);
convert_uid_from_memcached(V) when is_binary(V) ->
    convert_uid_from_memcached(binary_to_list(V)).

get_uid_in_memcached_format(Props) ->
    convert_uid_to_memcached(get_uid(Props)).

collection_prop_to_memcached(uid, V) ->
    convert_uid_to_memcached(V);
collection_prop_to_memcached(_, V) ->
    V.

default_collection_props() ->
    [{maxTTL, 0}].

collection_to_memcached(Name, Props, WithDefaults) ->
    AdjustedProps =
        case WithDefaults of
            true ->
                misc:update_proplist(default_collection_props(), Props);
            false ->
                Props
        end,
    {[{name, list_to_binary(Name)} |
      [{K, collection_prop_to_memcached(K, V)} || {K, V} <- AdjustedProps]]}.

filter_scopes_with_roles(Bucket, Scopes, Roles) ->
    lists:filter(
      fun ({ScopeName, _Scope}) ->
              menelaus_roles:is_allowed(
                {[{collection, [Bucket, ScopeName, all]}, collections], write},
                Roles)
      end, Scopes).

filter_collections_with_roles(Bucket, Scopes, Roles) ->
    lists:filtermap(
      fun ({ScopeName, Scope}) ->
              case menelaus_roles:is_allowed(
                     {[{collection, [Bucket, ScopeName, any]},
                       collections], read}, Roles) of
                  false ->
                      false;
                  true ->
                      Filtered = lists:filter(
                                   fun ({CName, _Props}) ->
                                           menelaus_roles:is_allowed(
                                             {[{collection,
                                                [Bucket, ScopeName, CName]},
                                               collections], read}, Roles)
                                   end, get_collections(Scope)),
                      {true, {ScopeName, update_collections(Filtered, Scope)}}
              end
      end, Scopes).

manifest_json(Bucket, Snapshot) ->
    Manifest = get_manifest(Bucket, Snapshot),
    jsonify_manifest(Manifest, false).

manifest_json(Identity, Bucket, BucketCfg) ->
    Roles = menelaus_roles:get_compiled_roles(Identity),
    Manifest = get_manifest(BucketCfg),
    FilteredManifest = on_scopes(
                         filter_collections_with_roles(Bucket, _, Roles),
                         Manifest),
    jsonify_manifest(FilteredManifest, true).

jsonify_manifest(Manifest, WithDefaults) ->
    ScopesJson =
        lists:map(
          fun ({ScopeName, Scope}) ->
                  {[{name, list_to_binary(ScopeName)},
                    {uid, get_uid_in_memcached_format(Scope)},
                    {collections,
                     [collection_to_memcached(CollName, Coll, WithDefaults) ||
                         {CollName, Coll} <- get_collections(Scope)]}]}
          end, get_scopes(Manifest)),

    {[{uid, get_uid_in_memcached_format(Manifest)},
      {scopes, ScopesJson}]}.

get_max_supported(num_scopes) ->
    ns_config:read_key_fast(max_scopes_count, ?MAX_SCOPES_SUPPORTED);
get_max_supported(num_collections) ->
    ns_config:read_key_fast(max_collections_count, ?MAX_COLLECTIONS_SUPPORTED).

total_in_cluster_with_modified_manifest(Counter, Bucket, Manifest) ->
    Buckets = ns_bucket:get_buckets(),
    lists:foldl(
      fun ({B, _}, Acc) when B =:= Bucket ->
              Acc + get_counter(Manifest, Counter);
          ({_Name, BucketCfg}, Acc) ->
              case enabled(BucketCfg) of
                  true ->
                      Acc + get_counter(get_manifest(BucketCfg), Counter);
                  false ->
                      Acc
              end
      end, 0, Buckets).

create_scope(Bucket, Name) ->
    update(Bucket, {create_scope, Name}).

create_collection(Bucket, Scope, Name, Props) ->
    update(Bucket, {create_collection, Scope, Name,
                    remove_defaults(Props)}).

drop_scope(Bucket, Name) ->
    update(Bucket, {drop_scope, Name}).

drop_collection(Bucket, Scope, Name) ->
    update(Bucket, {drop_collection, Scope, Name}).

update(Bucket, Operation) ->
    work_queue:submit_sync_work(
      ?SERVER, ?cut(do_update(Bucket, Operation))).

do_update(Bucket, Operation) ->
    ?log_debug("Performing operation ~p on bucket ~p", [Operation, Bucket]),
    RV =
        case leader_activities:run_activity(
               {?MODULE, Bucket}, {?MODULE, Bucket}, majority,
               fun () ->
                       do_update_as_leader(Bucket, Operation)
               end, []) of
            {leader_activities_error, _, Err} ->
                {unsafe, Err};
            Res ->
                Res
        end,
    case RV of
        {ok, _} ->
            RV;
        {user_error, Error} ->
            ?log_debug("Operation ~p for bucket ~p failed with ~p",
                       [Operation, Bucket, RV]),
            Error;
        {Error, Details} ->
            ?log_error("Operation ~p for bucket ~p failed with ~p (~p)",
                       [Operation, Bucket, Error, Details]),
            Error
    end.

do_update_as_leader(Bucket, Operation) ->
    OtherNodes = ns_node_disco:nodes_actual_other(),
    case pull_config(OtherNodes) of
        ok ->
            {ok, BucketCfg} = ns_bucket:get_bucket(Bucket),
            Manifest = get_manifest(BucketCfg),

            ?log_debug("Perform operation ~p on manifest ~p of bucket ~p",
                       [Operation, Manifest, Bucket]),
            case perform_operations(
                   Manifest, compile_operation(Operation, Bucket, Manifest)) of
                {ok, Manifest} ->
                    {ok, convert_uid_to_memcached(proplists:get_value(
                                                    uid, Manifest))};
                {ok, NewManifest} ->
                    case ensure_cluster_limits(Bucket, NewManifest) of
                        ok ->
                            commit(Bucket, Manifest,
                                   bump_manifest_uid(NewManifest), OtherNodes);
                        Error ->
                            {user_error, Error}
                    end;
                Error ->
                    {user_error, Error}
            end;
        Error ->
            {pull_config, Error}
    end.

commit(Bucket, Manifest, NewManifest, OtherNodes) ->
    ?log_debug("Resulting manifest ~p", [NewManifest]),
    ok = update_manifest_next_ids(Bucket, Manifest, NewManifest),
    case ns_config_rep:ensure_config_seen_by_nodes(OtherNodes) of
        ok ->
            ok = update_manifest(Bucket, NewManifest),
            Uid = proplists:get_value(uid, NewManifest),
            ?log_debug("Committed manifest with Uid ~p", [Uid]),
            {ok, convert_uid_to_memcached(Uid)};
        Error ->
            {push_config, Error}
    end.

perform_operations(_Manifest, {error, Error}) ->
    Error;
perform_operations(Manifest, []) ->
    {ok, Manifest};
perform_operations(Manifest, [Operation | Rest]) ->
    case verify_oper(Operation, Manifest) of
        ok ->
            perform_operations(handle_oper(Operation, Manifest), Rest);
        Error ->
            ?log_debug("Operation ~p failed with error ~p", [Operation, Error]),
            Error
    end.

update_manifest_next_ids(Bucket, CurrentManifest, NewManifest) ->
    NextIDs = [next_uid, next_scope_uid, next_coll_uid],
    Interim = lists:foldl(
                fun (ID, ManifestAcc) ->
                        Val = proplists:get_value(ID, NewManifest),
                        lists:keystore(ID, 1, ManifestAcc, {ID, Val})
                end, CurrentManifest, NextIDs),
    update_manifest(Bucket, Interim).

update_manifest(Bucket, Manifest) ->
    ns_bucket:set_property(Bucket, collections_manifest, Manifest).

bump_id(Manifest, ID) ->
    misc:key_update(ID, Manifest, _ + 1).

bump_manifest_uid(Manifest) ->
    NewManifest = bump_id(Manifest, next_uid),
    Uid = proplists:get_value(next_uid, NewManifest),
    lists:keystore(uid, 1, NewManifest, {uid, Uid}).

ensure_cluster_limits(Bucket, Manifest) ->
    case check_limit(num_scopes, Bucket, Manifest) of
        ok ->
            check_limit(num_collections, Bucket, Manifest);
        Error ->
            Error
    end.

check_limit(Counter, Bucket, Manifest) ->
    case total_in_cluster_with_modified_manifest(Counter, Bucket, Manifest) >
        get_max_supported(Counter) of
        false ->
            ok;
        true ->
            {max_number_exceeded, Counter}
    end.

remove_defaults(Props) ->
    Props -- default_collection_props().

get_operations(Fun, Current, Required) ->
    MapCurrent = maps:from_list(Current),
    MapRequired = maps:from_list(Required),
    FoldFun = ?cut([Fun(_) | _]),

    Deletes = maps:without(maps:keys(MapRequired), MapCurrent),
    DeleteOpers = maps:fold(?cut(FoldFun({delete, _, _}, _)), [], Deletes),

    lists:flatten(
      maps:fold(
        fun (Key, Value, Acc) ->
                case maps:find(Key, MapCurrent) of
                    {ok, CurrentValue} ->
                        FoldFun({modify, Key, Value, CurrentValue}, Acc);
                    error ->
                        FoldFun({add, Key, Value}, Acc)
                end
        end, DeleteOpers, MapRequired)).

get_operations(CurrentScopes, RequiredScopes) ->
    get_operations(
      fun ({delete, ScopeName, _}) ->
              {drop_scope, ScopeName};
          ({add, ScopeName, ScopeProps}) ->
              [{create_scope, ScopeName} |
               [{create_collection, ScopeName, CollectionName,
                 remove_defaults(CollectionProps)} ||
                   {CollectionName, CollectionProps}
                       <- get_collections(ScopeProps)]];
          ({modify, ScopeName, ScopeProps, CurrentScopeProps}) ->
              get_operations(
                fun ({delete, CollectionName, _}) ->
                        {drop_collection, ScopeName, CollectionName};
                    ({add, CollectionName, CollectionProps}) ->
                        {create_collection, ScopeName, CollectionName,
                         remove_defaults(CollectionProps)};
                    ({modify, CollectionName, CollectionProps,
                      CurrentCollectionProps}) ->
                        case lists:sort(remove_defaults(CollectionProps)) =:=
                            lists:sort(lists:keydelete(
                                         uid, 1, CurrentCollectionProps)) of
                            false ->
                                {modify_collection, ScopeName, CollectionName};
                            true ->
                                []
                        end
                end, get_collections(CurrentScopeProps),
                get_collections(ScopeProps))
      end, CurrentScopes, RequiredScopes).

compile_operation({set_manifest, Identity, RequiredScopes, CheckUid},
                  Bucket, Manifest) ->
    Roles = menelaus_roles:get_compiled_roles(Identity),
    case filter_scopes_with_roles(Bucket, RequiredScopes, Roles) of
        RequiredScopes ->
            FilteredCurScopes = filter_scopes_with_roles(
                                  Bucket, get_scopes(Manifest), Roles),
            %% scope admin can delete it's own scope.
            [{check_uid, CheckUid} |
             get_operations(FilteredCurScopes, RequiredScopes)];
        _ ->
            %% Trying to create/delete scopes we don't have permissions to.
            {error, forbidden}
    end;
compile_operation(Oper, _Bucket, _Manifest) ->
    [Oper].

verify_oper({check_uid, CheckUid}, Manifest) ->
    ManifestUid = proplists:get_value(uid, Manifest),
    case CheckUid =:= ManifestUid orelse CheckUid =:= undefined of
        true ->
            ok;
        false ->
            uid_mismatch
    end;
verify_oper({create_scope, Name}, Manifest) ->
    Scopes = get_scopes(Manifest),
    case find_scope(Name, Scopes) of
        undefined ->
            ok;
        _ ->
            {scope_already_exists, Name}
    end;
verify_oper({drop_scope, "_default"}, _Manifest) ->
    cannot_drop_default_scope;
verify_oper({drop_scope, Name}, Manifest) ->
    with_scope(fun (_) -> ok end, Name, Manifest);
verify_oper({create_collection, ScopeName, "_default", _}, _Manifest) ->
    {cannot_create_default_collection, ScopeName};
verify_oper({create_collection, ScopeName, Name, _}, Manifest) ->
    with_scope(
      fun (Scope) ->
              Collections = get_collections(Scope),
              case find_collection(Name, Collections) of
                  undefined ->
                      ok;
                  _ ->
                      {collection_already_exists, ScopeName, Name}
              end
      end, ScopeName, Manifest);
verify_oper({drop_collection, ScopeName, Name}, Manifest) ->
    with_collection(fun (_) -> ok end, ScopeName, Name, Manifest);
verify_oper({modify_collection, ScopeName, Name}, _Manifest) ->
    {cannot_modify_collection, ScopeName, Name}.

handle_oper({check_uid, _CheckUid}, Manifest) ->
    Manifest;
handle_oper({create_scope, Name}, Manifest) ->
    functools:chain(
      Manifest,
      [bump_id(_, next_scope_uid),
       add_scope(_, Name),
       update_counter(_, num_scopes, 1)]);
handle_oper({drop_scope, Name}, Manifest) ->
    NumCollections = length(get_collections(get_scope(Name, Manifest))),
    functools:chain(
      Manifest,
      [delete_scope(_, Name),
       update_counter(_, num_scopes, -1),
       update_counter(_, num_collections, -NumCollections)]);
handle_oper({create_collection, Scope, Name, Props}, Manifest) ->
    functools:chain(
      Manifest,
      [bump_id(_, next_coll_uid),
       add_collection(_, Name, Scope, Props),
       update_counter(_, num_collections, 1)]);
handle_oper({drop_collection, Scope, Name}, Manifest) ->
    NumCollections = case Name of
                         "_default" -> 0;
                         _ -> 1
                     end,
    functools:chain(
      Manifest,
      [delete_collection(_, Name, Scope),
       update_counter(_, num_collections, -NumCollections)]).

get_counter(Manifest, Counter) ->
    proplists:get_value(Counter, Manifest).

update_counter(Manifest, Counter, Amount) ->
    lists:keystore(Counter, 1, Manifest,
                   {Counter, get_counter(Manifest, Counter) + Amount}).

get_manifest(BucketCfg) ->
    proplists:get_value(collections_manifest, BucketCfg, default_manifest()).

get_manifest(Bucket, Snapshot) ->
    {Manifest, _} = maps:get(key(Bucket), Snapshot, {undefined, no_rev}),
    Manifest.

get_scope(Name, Manifest) ->
    find_scope(Name, get_scopes(Manifest)).

get_scopes(Manifest) ->
    proplists:get_value(scopes, Manifest).

find_scope(Name, Scopes) ->
    proplists:get_value(Name, Scopes).

add_scope(Manifest, Name) ->
    Uid = proplists:get_value(next_scope_uid, Manifest),
    on_scopes([{Name, [{uid, Uid}, {collections, []}]} | _], Manifest).

delete_scope(Manifest, Name) ->
    on_scopes(lists:keydelete(Name, 1, _), Manifest).

update_scopes(Scopes, Manifest) ->
    lists:keystore(scopes, 1, Manifest, {scopes, Scopes}).

on_scopes(Fun, Manifest) ->
    Scopes = get_scopes(Manifest),
    NewScopes = Fun(Scopes),
    update_scopes(NewScopes, Manifest).

get_collections(Scope) ->
    proplists:get_value(collections, Scope, []).

get_collection(Name, Scope) ->
    find_collection(Name, get_collections(Scope)).

find_collection(Name, Collections) ->
    proplists:get_value(Name, Collections).

add_collection(Manifest, Name, ScopeName, Props) ->
    Uid = proplists:get_value(next_coll_uid, Manifest),
    on_collections([{Name, [{uid, Uid} | Props]} | _], ScopeName, Manifest).

delete_collection(Manifest, Name, ScopeName) ->
    on_collections(lists:keydelete(Name, 1, _), ScopeName, Manifest).

update_collections(Collections, Scope) ->
    lists:keystore(collections, 1, Scope, {collections, Collections}).

on_collections(Fun, ScopeName, Manifest) ->
    on_scopes(
      fun (Scopes) ->
              Scope = find_scope(ScopeName, Scopes),
              Collections = get_collections(Scope),
              NewCollections = Fun(Collections),
              NewScope = update_collections(NewCollections, Scope),
              lists:keystore(ScopeName, 1, Scopes, {ScopeName, NewScope})
      end, Manifest).

pull_config(Nodes) ->
    ?log_debug("Attempting to pull config from nodes:~n~p", [Nodes]),

    Timeout = ?get_timeout(pull_config, 5000),
    case ns_config_rep:pull_remotes(Nodes, Timeout) of
        ok ->
            ?log_debug("Pulled config successfully."),
            ok;
        Error ->
            ?log_error("Failed to pull config from some nodes: ~p.",
                       [Error]),
            Error
    end.

wait_for_manifest_uid(Bucket, BucketUuid, Uid, Timeout) ->
    case async:run_with_timeout(
           ?cut(wait_for_manifest_uid(Bucket, BucketUuid, Uid)), Timeout) of
        {ok, R} ->
            R;
        {error, timeout} ->
            timeout
    end.

wait_for_manifest_uid(Bucket, BucketUuid, Uid) ->
    Ref = erlang:make_ref(),
    Parent = self(),
    Subscription =
        ns_pubsub:subscribe_link(
          buckets_events,
          fun ({set_collections_manifest, B, U}) when U >= Uid,
                                                      B =:= BucketUuid ->
                  Parent ! {Ref, ok};
              ({stopped, B}) when B =:= Bucket ->
                  Parent ! {Ref, stopped};
              (_) ->
                  ok
          end),
    try
        case ns_memcached:get_collections_uid(Bucket) of
            U when U >= Uid ->
                ok;
            _ ->
                receive
                    {Ref, Ret} ->
                        Ret
                end
        end
    after
        (catch ns_pubsub:unsubscribe(Subscription))
    end.

wait_for_manifest_uid(Nodes, Bucket, BucketUuid, Uid, Timeout) ->
    {Ret, [], BadNodes} =
        misc:rpc_multicall_with_plist_result(
          Nodes, ?MODULE, wait_for_manifest_uid,
          [Bucket, BucketUuid, Uid, Timeout], Timeout),
    case BadNodes of
        [] ->
            case lists:all(fun ({_, ok}) -> true; (_) -> false end, Ret) of
                true ->
                    ok;
                false ->
                    check_for_stopped_bucket(Ret)
            end;
        _ ->
            check_for_stopped_bucket(Ret)
    end.

check_for_stopped_bucket(Ret) ->
    case lists:any(fun ({_, stopped}) -> true; (_) -> false end, Ret) of
        true ->
            stopped;
        false ->
            timeout
    end.

extract_name(Props) ->
    {value, {name, Name}, NewProps} = lists:keytake(name, 1, Props),
    {Name, NewProps}.

convert_manifest_uid(undefined) ->
    undefined;
convert_manifest_uid(Uid) ->
    try
        convert_uid_from_memcached(Uid)
    catch
        _:_ ->
            invalid_uid
    end.

set_manifest(Bucket, Identity, RequiredScopes, RequestedUid) ->
    case convert_manifest_uid(RequestedUid) of
        invalid_uid ->
            invalid_uid;
        Uid ->
            Scopes =
                [{proplists:get_value(name, Scope),
                  [{collections, [extract_name(Props) ||
                                     {Props} <- get_collections(Scope)]}]} ||
                    {Scope} <- RequiredScopes],
            update(Bucket, {set_manifest, Identity, Scopes, Uid})
    end.

-ifdef(TEST).
get_operations_test_() ->
    {foreach, fun () -> ok end,
     [{"Create scopes and collections commands in the correct order",
       fun () ->
               ?assertEqual(
                  [{create_scope, "s1"},
                   {create_collection, "s1", "c1", []},
                   {create_collection, "s1", "c2", [{maxTTL, 8}]}],
                  get_operations(
                    [],
                    [{"s1", [{collections, [{"c1", []},
                                            {"c2", [{maxTTL, 8}]}]}]}]))
       end},
      {"Drop/create collections",
       fun () ->
               ?assertListsEqual(
                  [{create_collection, "s2", "c3", []},
                   {create_collection, "s1", "c2", []},
                   {drop_collection, "s1", "c1"},
                   {drop_collection, "_default", "_default"}],
                  get_operations(
                    [{"_default", [{collections, [{"_default", []}]}]},
                     {"s1", [{collections, [{"c1", []}]}]},
                     {"s2", [{collections, [{"c1", []}, {"c2", []}]}]}],
                    [{"_default", [{collections, []}]},
                     {"s1", [{collections, [{"c2", []}]}]},
                     {"s2", [{collections, [{"c1", []}, {"c2", []},
                                            {"c3", []}]}]}]))
       end},
      {"Drop scope with collection present.",
       fun () ->
               ?assertListsEqual(
                  [{create_collection, "s1", "c2", []},
                   {drop_scope, "s2"}],
                  get_operations(
                    [{"s1", [{collections, [{"c1", []}]}]},
                     {"s2", [{collections, [{"c1", []},
                                            {"c2", []}]}]}],
                    [{"s1", [{collections, [{"c1", []},
                                            {"c2", []}]}]}]))
       end},
      {"Modify collection.",
       fun () ->
               ?assertListsEqual(
                  [{modify_collection, "s3", "ic2"},
                   {create_collection, "s1", "c2", []},
                   {drop_scope, "s2"}],
                  get_operations(
                    [{"s1", [{collections, [{"c1", []}]}]},
                     {"s2", [{collections, [{"c1", []}, {"c2", []}]}]},
                     {"s3", [{collections, [{"ic1", []},
                                            {"ic2", [{maxTTL, 10}]}]}]}],
                    [{"s1", [{collections, [{"c1", []}, {"c2", []}]}]},
                     {"s3", [{collections, [{"ic1", [{maxTTL, 0}]},
                                            {"ic2", [{maxTTL, 0}]}]}]}]))
       end}]}.
-endif.
