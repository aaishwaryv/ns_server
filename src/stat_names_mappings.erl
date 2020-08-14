%% @author Couchbase <info@couchbase.com>
%% @copyright 2018-2019 Couchbase, Inc.
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
-module(stat_names_mappings).

-export([pre_70_stats_to_prom_query/2, prom_name_to_pre_70_name/2]).

-include("cut.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(IRATE_INTERVAL, "1m").

pre_70_stats_to_prom_query("@system", all) ->
    <<"{category=`system`}">>;
pre_70_stats_to_prom_query("@system-processes", all) ->
    <<"{category=`system-processes`}">>;
pre_70_stats_to_prom_query("@global", all) ->
    <<"{category=`audit`}">>;
pre_70_stats_to_prom_query(StatSection, all) ->
    pre_70_stats_to_prom_query(StatSection, default_stat_list(StatSection));
pre_70_stats_to_prom_query(StatSection, List) ->
    AstList = lists:filtermap(
                fun (S) ->
                    case pre_70_stat_to_prom_query(StatSection, S) of
                        {ok, R} -> {true, R};
                        {error, not_found} -> false
                    end
                end, [bin(S) || S <- List]),
    prometheus:format_promql({'or', AstList}).

pre_70_stat_to_prom_query("@system", Stat) ->
    {ok, {[{eq, <<"name">>, <<"sys_", Stat/binary>>}]}};

pre_70_stat_to_prom_query("@system-processes", Stat) ->
    case binary:split(Stat, <<"/">>) of
        [ProcName, MetricName] ->
            {ok, {[{eq, <<"name">>, <<"sysproc_", MetricName/binary>>},
                   {eq, <<"proc">>, ProcName}]}};
        _ ->
            {error, not_found}
    end;

pre_70_stat_to_prom_query("@global", Stat) ->
    {ok, {[{eq, <<"name">>, Stat}]}};

pre_70_stat_to_prom_query("@query", <<"query_", Stat/binary>>) ->
    Gauges = [<<"active_requests">>, <<"queued_requests">>],
    case lists:member(Stat, Gauges) of
        true -> {ok, {[{eq, <<"name">>, <<"n1ql_", Stat/binary>>}]}};
        false -> {ok, rate({[{eq, <<"name">>, <<"n1ql_", Stat/binary>>}]})}
    end;

pre_70_stat_to_prom_query("@fts", Stat) ->
    {ok, {[{eq, <<"name">>, Stat}]}};

pre_70_stat_to_prom_query("@fts-" ++ Bucket, <<"fts/", Stat/binary>>) ->
    map_index_stats(<<"fts">>, service_fts:get_counters(), Bucket, Stat);

pre_70_stat_to_prom_query("@index", <<"index_ram_percent">>) ->
    {ok, named(<<"index_ram_percent">>,
               {'*', [{'/', [{ignoring, [<<"name">>]}],
                       [metric(<<"index_memory_used_total">>),
                        metric(<<"index_memory_quota">>)]}, 100]})};
pre_70_stat_to_prom_query("@index", <<"index_remaining_ram">>) ->
    {ok, named(<<"index_remaining_ram">>,
               {'-', [{ignoring, [<<"name">>]}],
                [metric(<<"index_memory_quota">>),
                 metric(<<"index_memory_used_total">>)]})};
pre_70_stat_to_prom_query("@index", <<"index_memory_used">>) ->
    {ok, metric(<<"index_memory_used_total">>)};
pre_70_stat_to_prom_query("@index", Stat) ->
    {ok, metric(Stat)};

pre_70_stat_to_prom_query("@index-" ++ Bucket, <<"index/", Stat/binary>>) ->
    map_index_stats(<<"index">>, service_index:get_counters(), Bucket, Stat);

pre_70_stat_to_prom_query(_, _) ->
    {error, not_found}.

%% Works for fts and index, Prefix is the only difference
map_index_stats(Prefix, Counters, Bucket, Stat) ->
    IsCounter =
        fun (N) ->
            try
                lists:member(binary_to_existing_atom(N, latin1), Counters)
            catch
                _:_ -> false
            end
        end,
    case binary:split(Stat, <<"/">>, [global]) of
        [<<"disk_overhead_estimate">> = N] ->
              DiskSize = sumby([<<"name">>],
                               bucket_metric(<<Prefix/binary, "_disk_size">>,
                                             Bucket)),
              FragPerc = sumby([<<"name">>],
                               bucket_metric(<<Prefix/binary, "_frag_percent">>,
                                             Bucket)),
              Name = <<Prefix/binary, "_", N/binary>>,
              {ok, named(Name, {'/', [{'*', [{ignoring, [<<"name">>]}],
                                       [DiskSize, FragPerc]}, 100]})};
        [Index,  <<"disk_overhead_estimate">> = N] ->
              DiskSize = sumby([<<"name">>, <<"index">>],
                               index_metric(<<Prefix/binary, "_disk_size">>,
                                             Bucket, Index)),
              FragPerc = sumby([<<"name">>, <<"index">>],
                               index_metric(<<Prefix/binary, "_frag_percent">>,
                                             Bucket, Index)),
              Name = <<Prefix/binary, "_", N/binary>>,
              {ok, named(Name, {'/', [{'*', [{ignoring, [<<"name">>]}],
                                       [DiskSize, FragPerc]}, 100]})};
        [N] ->
            Name = <<Prefix/binary, "_", N/binary>>,
            case IsCounter(N) of
                true ->
                    {ok, sumby([<<"name">>],
                               rate(bucket_metric(Name, Bucket)))};
                false ->
                    {ok, sumby([<<"name">>], bucket_metric(Name, Bucket))}
            end;
        [Index, N] ->
            Name = <<Prefix/binary, "_", N/binary>>,
            case IsCounter(N) of
                true ->
                    {ok, sumby([<<"name">>, <<"index">>],
                               rate(index_metric(Name, Bucket, Index)))};
                false ->
                    {ok, sumby([<<"name">>, <<"index">>],
                               index_metric(Name, Bucket, Index))}
            end;
        _ ->
            {error, not_found}
    end.

rate(Ast) -> {call, irate, none, [{range_vector, Ast, ?IRATE_INTERVAL}]}.
sumby(ByFields, Ast) -> {call, sum, {by, ByFields}, [Ast]}.
metric(Name) -> {[{eq, <<"name">>, Name}]}.
bucket_metric(Name, Bucket) ->
    {[{eq, <<"name">>, Name}, {eq, <<"bucket">>, Bucket}]}.
index_metric(Name, Bucket, Index) ->
    {[{eq, <<"name">>, Name}, {eq, <<"bucket">>, Bucket}] ++
     [{eq, <<"index">>, Index} || Index =/= <<"*">>]}.
named(Name, Ast) ->
    {call, label_replace, none, [Ast, <<"name">>, Name, <<>>, <<>>]}.

bin(A) when is_atom(A) -> atom_to_binary(A, latin1);
bin(B) when is_binary(B) -> B.

prom_name_to_pre_70_name(Bucket, {JSONProps}) ->
    Res =
        case proplists:get_value(<<"name">>, JSONProps) of
            <<"n1ql_", Name/binary>> ->
                {ok, <<"query_", Name/binary>>};
            <<"sys_", Name/binary>> -> {ok, Name};
            <<"sysproc_", Name/binary>> ->
                Proc = proplists:get_value(<<"proc">>, JSONProps, <<>>),
                {ok, <<Proc/binary, "/", Name/binary>>};
            <<"audit_", _/binary>> = Name -> {ok, Name};
            <<"fts_", _/binary>> = Name when Bucket == "@fts" ->
                {ok, Name};
            <<"fts_", Name/binary>> -> %% for @fts-<bucket>
                case proplists:get_value(<<"index">>, JSONProps, <<>>) of
                    <<>> -> {ok, <<"fts/", Name/binary>>};
                    Index -> {ok, <<"fts/", Index/binary, "/", Name/binary>>}
                end;
            <<"index_memory_used_total">> when Bucket == "@index" ->
                {ok, <<"index_memory_used">>};
            <<"index_", _/binary>> = Name when Bucket == "@index" ->
                {ok, Name};
            <<"index_", Name/binary>> -> %% for @index-<bucket>
                case proplists:get_value(<<"index">>, JSONProps, <<>>) of
                    <<>> -> {ok, <<"index/", Name/binary>>};
                    Index -> {ok, <<"index/", Index/binary, "/", Name/binary>>}
                end;
            _ -> {error, not_found}
        end,
    case Res of
        {ok, BinName} ->
            %% Since pre-7.0 stats don't care much about stats name type,
            %% 7.0 stats have to convert names to correct types based on stat
            %% section.
            case key_type_by_stat_type(Bucket) of
                atom -> {ok, binary_to_atom(BinName, latin1)};
                binary -> {ok, BinName}
            end;
        {error, _} = Error ->
            Error
    end.

key_type_by_stat_type("@query") -> atom;
key_type_by_stat_type("@global") -> atom;
key_type_by_stat_type("@system") -> atom;
key_type_by_stat_type("@system-processes") -> binary;
key_type_by_stat_type("@fts") -> binary;
key_type_by_stat_type("@fts-" ++ _) -> binary;
key_type_by_stat_type("@index") -> binary;
key_type_by_stat_type("@index-" ++ _) -> binary.


%% For system stats it's simple, we can get all of them with a simple query
%% {category="system"}. For most of other stats it's not always the case.
%% For example, for query we need to request rates for some stats, so we have
%% to know which stats should be rates and which stats should be plain. This
%% leads to the fact that when we need to get all of them we have to know
%% the real list of stats being requested. It can be achieved by various
%% means. I chose to just hardcode it (should be fine as it's for backward
%% compat only).
default_stat_list("@query") ->
    [query_active_requests, query_queued_requests, query_errors,
     query_invalid_requests, query_request_time, query_requests,
     query_requests_500ms, query_requests_250ms, query_requests_1000ms,
     query_requests_5000ms, query_result_count, query_result_size,
     query_selects, query_service_time, query_warnings];
default_stat_list("@fts") ->
    Stats = service_fts:get_service_gauges() ++
            service_fts:get_service_counters(),
    [<<"fts_", (bin(S))/binary>> || S <- Stats];
default_stat_list("@fts-" ++ _) ->
    Stats = service_fts:get_gauges() ++
            service_fts:get_counters(),
    [<<"fts/", (bin(S))/binary>> || S <- Stats] ++
    [<<"fts/*/", (bin(S))/binary>> || S <- Stats];
default_stat_list("@index") ->
    Stats = service_index:get_service_gauges() ++
            service_index:get_service_counters() ++
            [ram_percent, remaining_ram],
    [<<"index_", (bin(S))/binary>> || S <- Stats];
default_stat_list("@index-" ++ _) ->
    Stats = service_index:get_gauges() ++
            service_index:get_counters() ++
            service_index:get_computed(),
    [<<"index/", (bin(S))/binary>> || S <- Stats] ++
    [<<"index/*/", (bin(S))/binary>> || S <- Stats].

-ifdef(TEST).
pre_70_to_prom_query_test_() ->
    Test = fun (Section, Stats, ExpectedQuery) ->
               Name = lists:flatten(io_lib:format("~s: ~p", [Section, Stats])),
               {Name,
                fun () ->
                    ?assertEqual(pre_70_stats_to_prom_query(Section, Stats),
                                 list_to_binary(ExpectedQuery))
                end}
           end,
    [Test("@system", all, "{category=`system`}"),
     Test("@system", [], ""),
     Test("@system-processes", all, "{category=`system-processes`}"),
     Test("@system-processes", [], ""),
     Test("@system-processes", [<<"ns_server/cpu_utilization">>,
                                <<"ns_server/mem_resident">>,
                                <<"couchdb/cpu_utilization">>],
          "{name=`sysproc_cpu_utilization`,proc=`couchdb`} or "
          "{name=~`sysproc_cpu_utilization|sysproc_mem_resident`,"
           "proc=`ns_server`}"),
     Test("@query", all,
          "{name=~`n1ql_active_requests|n1ql_queued_requests`} or "
          "irate({name=~`n1ql_errors|n1ql_invalid_requests|n1ql_request_time|"
                        "n1ql_requests|n1ql_requests_1000ms|"
                        "n1ql_requests_250ms|n1ql_requests_5000ms|"
                        "n1ql_requests_500ms|n1ql_result_count|"
                        "n1ql_result_size|n1ql_selects|n1ql_service_time|"
                        "n1ql_warnings`}["?IRATE_INTERVAL"])"),
     Test("@query", [], ""),
     Test("@query", [query_errors, query_active_requests, query_request_time],
          "{name=`n1ql_active_requests`} or "
          "irate({name=~`n1ql_errors|n1ql_request_time`}["?IRATE_INTERVAL"])"),
     Test("@fts", all, "{name=~`fts_curr_batches_blocked_by_herder|"
                               "fts_num_bytes_used_ram|"
                               "fts_total_queries_rejected_by_herder`}"),
     Test("@fts", [], ""),
     Test("@fts", [<<"fts_num_bytes_used_ram">>,
                   <<"fts_curr_batches_blocked_by_herder">>],
          "{name=~`fts_curr_batches_blocked_by_herder|"
                  "fts_num_bytes_used_ram`}"),
     Test("@fts-test", all,
          "sum by (name) ({name=~`fts_doc_count|"
                                 "fts_num_bytes_used_disk|"
                                 "fts_num_files_on_disk|"
                                 "fts_num_mutations_to_index|"
                                 "fts_num_pindexes_actual|"
                                 "fts_num_pindexes_target|"
                                 "fts_num_recs_to_persist|"
                                 "fts_num_root_filesegments|"
                                 "fts_num_root_memorysegments`,"
                          "bucket=`test`}) or "
          "sum by (name) (irate({name=~`fts_total_bytes_indexed|"
                                       "fts_total_bytes_query_results|"
                                       "fts_total_compaction_written_bytes|"
                                       "fts_total_queries|"
                                       "fts_total_queries_error|"
                                       "fts_total_queries_slow|"
                                       "fts_total_queries_timeout|"
                                       "fts_total_request_time|"
                                       "fts_total_term_searchers`,"
                                "bucket=`test`}[1m])) or "
          "sum by (name,index) ({name=~`fts_doc_count|"
                                       "fts_num_bytes_used_disk|"
                                       "fts_num_files_on_disk|"
                                       "fts_num_mutations_to_index|"
                                       "fts_num_pindexes_actual|"
                                       "fts_num_pindexes_target|"
                                       "fts_num_recs_to_persist|"
                                       "fts_num_root_filesegments|"
                                       "fts_num_root_memorysegments`,"
                                "bucket=`test`}) or "
          "sum by (name,index) (irate({name=~`fts_total_bytes_indexed|"
                                             "fts_total_bytes_query_results|"
                                             "fts_total_compaction_written_bytes|"
                                             "fts_total_queries|"
                                             "fts_total_queries_error|"
                                             "fts_total_queries_slow|"
                                             "fts_total_queries_timeout|"
                                             "fts_total_request_time|"
                                             "fts_total_term_searchers`,"
                                      "bucket=`test`}[1m]))"),
     Test("@fts-test", [], ""),
     Test("@fts-test", [<<"fts/num_files_on_disk">>,
                        <<"fts/num_pindexes_target">>,
                        <<"fts/doc_count">>,
                        <<"fts/ind1/doc_count">>,
                        <<"fts/ind1/num_pindexes_target">>,
                        <<"fts/ind2/num_files_on_disk">>,
                        <<"fts/ind2/total_queries">>],
          "sum by (name) ({name=~`fts_doc_count|"
                                 "fts_num_files_on_disk|"
                                 "fts_num_pindexes_target`,bucket=`test`}) or "
          "sum by (name,index) ({name=~`fts_doc_count|"
                                       "fts_num_pindexes_target`,"
                                "bucket=`test`,index=`ind1`}) or "
          "sum by (name,index) ({name=`fts_num_files_on_disk`,"
                                "bucket=`test`,index=`ind2`}) or "
          "sum by (name,index) (irate({name=`fts_total_queries`,"
                                      "bucket=`test`,index=`ind2`}[1m]))")].

prom_name_to_pre_70_name_test_() ->
    Test = fun (Section, Json, ExpectedRes) ->
               Name = lists:flatten(io_lib:format("~s: ~s", [Section, Json])),
               Props = ejson:decode(Json),
               {Name,
                fun () ->
                    ?assertEqual(prom_name_to_pre_70_name(Section, Props),
                                 ExpectedRes)
                end}
           end,
    [Test("@system", "{\"name\": \"sys_cpu_user_rate\"}",
          {ok, cpu_user_rate}),
     Test("@system-processes",
          "{\"name\": \"sysproc_cpu_utilization\",\"proc\": \"ns_server\"}",
          {ok, <<"ns_server/cpu_utilization">>}),
     Test("@query", "{\"name\": \"n1ql_active_requests\"}",
          {ok, query_active_requests}),
     Test("@query", "{}",
          {error, not_found}),
     Test("@query", "{\"name\": \"unknown\"}",
          {error, not_found}),
     Test("@query", "{\"proc\": \"ns_server\"}",
          {error, not_found}),
     Test("@fts", "{\"name\": \"fts_num_bytes_used_ram\"}",
          {ok, <<"fts_num_bytes_used_ram">>}),
     Test("@fts-test", "{\"name\": \"fts_doc_count\"}",
          {ok, <<"fts/doc_count">>}),
     Test("@fts-test", "{\"name\": \"fts_doc_count\", \"index\": \"ind1\"}",
          {ok, <<"fts/ind1/doc_count">>})].

-endif.
